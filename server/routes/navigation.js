// 三态状态机路由：diagnose（诊断）→ plan（规划，瞬时）→ execute（陪跑）
// conversation.mode 只存 diagnose / execute；plan 由 action 触发、执行完即转入 execute
const express = require('express');
const crypto = require('crypto');
const router = express.Router();
const db = require('../db');
const { config } = require('../config');
const { runMode, extractProfile, summarize, bundleVersion } = require('../services/protocol');
const outcome = require('../services/outcome');

const THRESHOLD = (config.diagnosis && config.diagnosis.sufficiency_threshold) || 70;
const uid = () => crypto.randomUUID();
const now = () => Date.now();

// ---------- 状态决策 ----------
function decideMode(action, conv) {
  if (action === 'plan') return 'plan';
  if (action === 'execute') return 'execute';
  if (action === 'finish') return 'finish';
  if (conv && conv.mode === 'execute') return 'execute';
  return 'diagnose';
}

function loadProfile(visitorId, domain) {
  if (!domain) return null;
  return db.prepare('SELECT * FROM cognitive_profiles WHERE visitor_id=? AND domain=?').get(visitorId, domain) || null;
}

function getHistory(convId) {
  return db.prepare('SELECT role, content FROM messages WHERE conversation_id=? ORDER BY created_at ASC').all(convId);
}

// ---------- 落库：思考快照（一轮 AI 思考 = 一行）----------
function saveSnapshot(conv, output, mode, tokenCost, ts) {
  const cls = output.classification || {};
  const snapId = uid();
  const qCount = (mode === 'diagnose' && Array.isArray(output.questions)) ? output.questions.length : 0;
  const rCount = (mode === 'plan' && Array.isArray(output.roadmap)) ? output.roadmap.length : null;
  const suf = (output.sufficiency && typeof output.sufficiency.score === 'number') ? output.sufficiency.score : null;
  db.prepare(
    `INSERT INTO cos_snapshots
      (id, visitor_id, conversation_id, created_at, mode, domain, task_type, is_new_task_type, intent,
       sufficiency_score, question_count, roadmap_step_count, self_progress, snapshot_version, snapshot_json)
     VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`
  ).run(
    snapId, conv.visitor_id, conv.id, ts, mode,
    cls.domain ?? null, cls.task_type ?? null, cls.is_new_task_type ?? 0, cls.intent ?? null,
    suf, qCount, rCount,
    typeof output.self_progress === 'number' ? output.self_progress : null,
    bundleVersion(config), JSON.stringify(output)
  );
  return snapId;
}

// ---------- 落库：问题级明细（护城河）----------
function saveQuestions(snapId, convId, questions, ts) {
  if (!Array.isArray(questions) || !questions.length) return;
  const ins = db.prepare(
    `INSERT INTO diagnostic_questions
      (id, snapshot_id, conversation_id, qkey, question, criticality, why, options, asked, created_at)
     VALUES (?,?,?,?,?,?,?,?,1,?)`
  );
  for (const q of questions) {
    ins.run(uid(), snapId, convId, q.key ?? null, q.question ?? '', q.criticality ?? null, q.why ?? null,
      JSON.stringify(q.options ?? []), ts);
  }
}

// 回填用户回答：affected_plan 绝不在此写入（默认 NULL，仅人工/离线分析回填）
function applyAnswers(convId, answers) {
  const updAns = db.prepare('UPDATE diagnostic_questions SET answered=1, answer=? WHERE conversation_id=? AND qkey=?');
  const updSkip = db.prepare('UPDATE diagnostic_questions SET asked=0, assumption=? WHERE conversation_id=? AND qkey=?');
  for (const a of answers) {
    if (!a || !a.qkey) continue;
    if (a.skipped) updSkip.run(a.assumption ?? null, convId, a.qkey);
    else updAns.run(a.answer ?? null, convId, a.qkey);
  }
}

function updateConvAfterDiagnose(conv, output, ts) {
  const cls = output.classification || {};
  db.prepare(
    `UPDATE conversations SET domain=?, task_type=?, intent=?, round_count=round_count+1, updated_at=? WHERE id=?`
  ).run(
    cls.domain ?? conv.domain, cls.task_type ?? conv.task_type, cls.intent ?? conv.intent, ts, conv.id
  );
}

// ---------- 画像落库（仅 finish 时，按受控大类分区）----------
function upsertProfile(visitorId, domain, prof, ts) {
  const keys = ['level', 'goal', 'motivation', 'resources', 'current_position', 'known_nodes', 'unknown_nodes', 'next_node', 'risk'];
  const cols = ['visitor_id', 'domain', 'last_navigation', 'updated_at'];
  const vals = [visitorId, domain, ts, ts];
  const sets = [];
  for (const k of keys) {
    if (prof[k] === undefined) continue;
    cols.push(k);
    vals.push(typeof prof[k] === 'object' ? JSON.stringify(prof[k]) : prof[k]);
    sets.push(`${k}=excluded.${k}`);
  }
  sets.push('last_navigation=excluded.last_navigation', 'updated_at=excluded.updated_at');
  db.prepare(
    `INSERT INTO cognitive_profiles (${cols.join(',')}) VALUES (${cols.map(() => '?').join(',')})
     ON CONFLICT(visitor_id, domain) DO UPDATE SET ${sets.join(', ')}`
  ).run(...vals);
}

// ---------- 完成流程（提取画像 + 总结 + 行为信号闭环）----------
async function handleFinish(conv, ts) {
  const history = getHistory(conv.id);
  const prof = await extractProfile(config, { history });
  const sum = await summarize(config, { history });
  db.prepare('INSERT INTO messages (id, conversation_id, role, content, created_at) VALUES (?,?,?,?,?)')
    .run(uid(), conv.id, 'assistant', JSON.stringify({ summary: sum, profile: prof }), ts);
  db.prepare('INSERT INTO events (id, visitor_id, conversation_id, event_type, domain, payload, created_at) VALUES (?,?,?,?,?,?,?)')
    .run(uid(), conv.visitor_id, conv.id, 'finish_navigation', conv.domain || null, JSON.stringify({}), ts);
  // 行为信号 → completed（铁律：AI 无权写）
  outcome.deriveFromEvent(conv.id, 'finish_navigation', ts);
  if (prof && conv.domain) upsertProfile(conv.visitor_id, conv.domain, prof, ts);
  const oc = db.prepare('SELECT * FROM outcomes WHERE conversation_id=?').get(conv.id);
  return { conversation_id: conv.id, mode: 'finish', summary: sum, profile: prof, outcome: oc };
}

// ---------- 主路由 ----------
router.post('/', async (req, res) => {
  try {
    const body = req.body || {};
    const { visitor_id, conversation_id, message, answers, action, finish } = body;
    if (!visitor_id) return res.status(400).json({ error: 'visitor_id required' });
    const ts = now();
    const act = finish ? 'finish' : (action || null);

    // 装载 / 创建会话
    let conv = conversation_id ? db.prepare('SELECT * FROM conversations WHERE id=?').get(conversation_id) : null;
    const isNew = !conv;
    if (isNew) {
      if (!message) return res.status(400).json({ error: '新会话需要 message' });
      const id = uid();
      db.prepare(
        `INSERT INTO conversations (id, visitor_id, topic, domain, task_type, intent, mode, round_count, created_at, updated_at, status)
         VALUES (?,?,NULL,NULL,NULL,NULL,'diagnose',0,?,?,'active')`
      ).run(id, visitor_id, ts, ts);
      conv = db.prepare('SELECT * FROM conversations WHERE id=?').get(id);
      outcome.open(id, visitor_id, ts);
    } else if (decideMode(act, conv) !== 'diagnose' && decideMode(act, conv) !== 'finish') {
      // plan / execute 必须基于已存在会话
    }

    // 落用户消息
    if (message) {
      db.prepare('INSERT INTO messages (id, conversation_id, role, content, created_at) VALUES (?,?,?,?,?)')
        .run(uid(), conv.id, 'user', message, ts);
    }
    // 回填答案（不影响 affected_plan）
    if (Array.isArray(answers) && answers.length) applyAnswers(conv.id, answers);

    const mode = decideMode(act, conv);
    if (mode === 'finish') {
      const r = await handleFinish(conv, ts);
      return res.json(r);
    }

    // 诊断 / 规划 / 陪跑
    const history = getHistory(conv.id);
    const profile = mode !== 'plan' ? loadProfile(conv.visitor_id, conv.domain) : null;
    const planMsg = mode === 'plan' ? '请根据已收集的信息给出完整分析包与分析，不再提问。' : null;
    const currentRound = (conv.round_count || 0) + 1; // 本轮是第几轮诊断

    const { output, tokenCost } = await runMode(config, {
      mode,
      history,
      message: mode === 'plan' ? planMsg : message,
      profile: profile || undefined,
      round: mode === 'diagnose' ? currentRound : undefined,
    });

    // 落库：AI 消息 + 思考快照
    db.prepare('INSERT INTO messages (id, conversation_id, role, content, token_cost, created_at) VALUES (?,?,?,?,?,?)')
      .run(uid(), conv.id, 'assistant', JSON.stringify(output), tokenCost, ts);
    const snapId = saveSnapshot(conv, output, mode, tokenCost, ts);

    // 行为事件
    db.prepare('INSERT INTO events (id, visitor_id, conversation_id, event_type, domain, payload, token_cost, created_at) VALUES (?,?,?,?,?,?,?,?)')
      .run(uid(), conv.visitor_id, conv.id, 'navigation_turn',
        (output.classification && output.classification.domain) || null, JSON.stringify({ mode }), tokenCost, ts);

    // 理解确认埋点（不对率指标）：✓ confirmed:true / ✗ confirmed:false + reason
    if (body.confirm_result && typeof body.confirm_result === 'object') {
      const cr = body.confirm_result;
      db.prepare('INSERT INTO events (id, visitor_id, conversation_id, event_type, domain, payload, created_at) VALUES (?,?,?,?,?,?,?)')
        .run(uid(), conv.visitor_id, conv.id, 'understanding_confirm',
          (output.classification && output.classification.domain) || conv.domain || null,
          JSON.stringify({ confirmed: !!cr.confirmed, reason: cr.reason || null, original_understanding: cr.original_understanding || null }), ts);
    }

    // 状态分流落库
    let readyToPlan = false, sufficiency = null;
    if (mode === 'diagnose') {
      saveQuestions(snapId, conv.id, output.questions, ts);
      updateConvAfterDiagnose(conv, output, ts);
      const cls = output.classification || {};
      outcome.setClassification(conv.id, cls.domain, cls.task_type);
      outcome.addQuestions(conv.id, Array.isArray(output.questions) ? output.questions.length : 0);
      // confidence 优先（v2.0），兼容旧 sufficiency.score
      sufficiency = (typeof output.confidence === 'number') ? output.confidence
        : (output.sufficiency && typeof output.sufficiency.score === 'number') ? output.sufficiency.score : null;
      readyToPlan = !!output.ready_to_plan && sufficiency != null && sufficiency >= THRESHOLD;
    } else if (mode === 'plan') {
      db.prepare("UPDATE conversations SET mode='execute', updated_at=? WHERE id=?").run(ts, conv.id);
      outcome.markPlanned(conv.id, ts);
      const cls = output.classification || {};
      outcome.setClassification(conv.id, cls.domain, cls.task_type);
    } else if (mode === 'execute') {
      db.prepare("UPDATE conversations SET mode='execute', updated_at=? WHERE id=?").run(ts, conv.id);
      outcome.addExecuteRound(conv.id);
    }
    outcome.touch(conv.id, ts);

    const oc = db.prepare('SELECT completed, total_questions, execute_rounds, handoff_count FROM outcomes WHERE conversation_id=?').get(conv.id);

    res.json({
      conversation_id: conv.id,
      mode,
      output,
      token_cost: tokenCost,
      ready_to_plan: readyToPlan,
      sufficiency,
      outcome: oc || null,
    });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: e.message });
  }
});

// 获取会话当前状态（供前端恢复 / 调试）
router.get('/:id', (req, res) => {
  const conv = db.prepare('SELECT * FROM conversations WHERE id=?').get(req.params.id);
  if (!conv) return res.status(404).json({ error: 'not found' });
  const oc = db.prepare('SELECT * FROM outcomes WHERE conversation_id=?').get(conv.id);
  res.json({ conversation: conv, outcome: oc });
});

module.exports = router;
