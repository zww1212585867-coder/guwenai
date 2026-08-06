// 认知导航器前端 v2.0：导诊层（一轮多问题 + 理解确认 + 分析包）
const API = '';
const $ = (s) => document.querySelector(s);
const log = $('#log');

const state = {
  visitorId: localStorage.getItem('cn_visitor') || (crypto.randomUUID()),
  conversationId: null,
  mode: 'diagnose',
  pendingQuestions: [],
  answers: {},              // qkey -> { answer, skipped, assumption }
  confirmMode: false,       // 理解确认"不对"后等待用户解释
  missContext: null,        // 理解确认点✗时暂存"原理解"，发出解释后回传后端
};
localStorage.setItem('cn_visitor', state.visitorId);

function el(tag, cls, html) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html != null) e.innerHTML = html;
  return e;
}
function scrollDown() { $('.stage').scrollTop = $('.stage').scrollHeight; }

function addMsg(role, node) {
  const m = el('div', 'msg ' + role);
  const b = el('div', 'bubble');
  b.appendChild(node);
  m.appendChild(b);
  log.appendChild(m);
  scrollDown();
}

// ---------- API ----------
async function nav(body) {
  let r;
  try {
    r = await fetch(API + '/api/navigation', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
  } catch (e) {
    throw new Error('无法连接服务器（' + (e.message || e) + '）— 请检查 VPS 上 node 服务是否在跑');
  }
  const ct = r.headers.get('content-type') || '';
  const raw = await r.text();
  if (!r.ok) throw new Error(`服务器返回 ${r.status}：${raw.slice(0, 120)}`);
  if (!ct.includes('json')) throw new Error(`服务器返回的不是 JSON（可能是 nginx 404）。前 80 字符：${raw.slice(0, 120)}`);
  try { return JSON.parse(raw); } catch (e) {
    throw new Error('JSON 解析失败：' + (e.message || e) + ' · 原文：' + raw.slice(0, 120));
  }
}

// ---------- 渲染：导诊收集态 ----------
function renderDiagnose(out) {
  const wrap = el('div');
  const cls = out.classification || {};
  wrap.appendChild(el('div', 'classification',
    `领域 <b>${cls.domain || '-'}</b> · ${cls.intent || ''}`));

  const suf = (out.confidence != null ? out.confidence : (out.sufficiency && out.sufficiency.score)) ?? 0;
  const reason = out.confidence_reason || (out.sufficiency && out.sufficiency.reason) || '';
  const round = out.round || 1, max = out.max_rounds || 2;
  wrap.appendChild(el('div', 'suff', `<i style="width:${suf}%"></i>`));
  wrap.appendChild(el('div', 'classification', `信息充足度 ${suf}/100 — ${reason}（第 ${round}/${max} 轮）`));

  // 理解确认态
  if (out.problem_reconstruction) {
    const pr = out.problem_reconstruction;
    const card = el('div', 'confirm-card');
    card.appendChild(el('div', 'confirm-title', '我理解你真正想解决的是：'));
    card.appendChild(el('div', 'confirm-b', pr.understood_as || ''));
    if (pr.original) card.appendChild(el('div', 'confirm-sub', `（你原话：${pr.original}）`));
    if (Array.isArray(pr.gpt_needs) && pr.gpt_needs.length)
      card.appendChild(el('div', 'confirm-needs', '大模型还需要：' + pr.gpt_needs.join('、')));
    const opts = el('div', 'options');
    const yes = el('span', 'opt', '✓ 对，就是这个');
    yes.onclick = () => { state.confirmMode = false; doPlan({ confirmed: true, original: pr.understood_as }); };
    const no = el('span', 'opt', '✗ 不对，我解释一下');
    no.onclick = () => {
      state.confirmMode = true;
      state.missContext = { original: pr.understood_as };
      $('#input').placeholder = '请说明哪里理解错了，或补充你的真实想法…';
      $('#input').focus();
      addMsg('ai', el('div', 'classification', '好的，请告诉我哪里理解错了，我重新帮你梳理。'));
    };
    opts.appendChild(yes); opts.appendChild(no);
    card.appendChild(opts);
    wrap.appendChild(card);
    addMsg('ai', wrap);
    showPlanActions({ plan: false, execute: false, finish: false });
    showSubmit(false); // 理解确认用卡片内 ✓/✗，不用底部按钮
    return;
  }

  // 一轮多问题
  state.pendingQuestions = out.questions || [];
  state.answers = {};
  if (!state.pendingQuestions.length) {
    wrap.appendChild(el('div', '', '（本轮无新问题，请点"提交分析"继续）'));
  }
  for (const q of state.pendingQuestions) {
    const card = el('div', 'qcard');
    if (q.derived_from) card.appendChild(el('div', 'derived', '↳ ' + q.derived_from));
    card.appendChild(el('div', 'q-q', q.question || ''));
    if (q.why) card.appendChild(el('div', 'why', '💡 ' + q.why));
    if (q.options && q.options.length) {
      const opts = el('div', 'options');
      for (const o of q.options) {
        const b = el('span', 'opt', o);
        b.onclick = () => {
          opts.querySelectorAll('.opt').forEach(x => x.classList.remove('sel'));
          b.classList.add('sel');
          state.answers[q.key] = { answer: o, skipped: false };
        };
        opts.appendChild(b);
      }
      card.appendChild(opts);
    }
    const extra = el('input', 'q-extra');
    extra.type = 'text';
    extra.placeholder = '补充说明（可选，愿意填就填）';
    extra.oninput = () => {
      if (!state.answers[q.key]) state.answers[q.key] = { skipped: false };
      state.answers[q.key].answer = (state.answers[q.key].answer && state.answers[q.key].answer.indexOf('｜补充：') >= 0
        ? state.answers[q.key].answer.split('｜补充：')[0] : (state.answers[q.key].answer || ''))
        + (extra.value.trim() ? '｜补充：' + extra.value.trim() : '');
      state.answers[q.key].skipped = false;
    };
    card.appendChild(extra);
    wrap.appendChild(card);
  }
  addMsg('ai', wrap);
  // 显示"提交分析"按钮
  showPlanActions({ plan: false, execute: false, finish: false });
  showSubmit(true);
}

// ---------- 渲染：分析态 ----------
function renderPlan(out) {
  const wrap = el('div');
  const pkg = out.analysis_package || {};
  if (pkg.reconstructed) wrap.appendChild(el('div', 'classification', `提炼后的问题：<b>${pkg.reconstructed}</b>`));
  if (pkg.context && Object.keys(pkg.context).length) {
    const ctx = Object.entries(pkg.context).map(([k, v]) => `${k}: ${v}`).join('，');
    wrap.appendChild(el('div', 'classification', '补全信息：' + ctx));
  }
  if (pkg.prompt_for_expert) {
    const cp = el('div', 'copy-handoff', '📋 复制给大模型的问题包');
    cp.onclick = () => { navigator.clipboard.writeText(pkg.prompt_for_expert); cp.textContent = '✓ 已复制'; };
    wrap.appendChild(cp);
  }
  const an = out.analysis || {};
  if (an.steps && an.steps.length) wrap.appendChild(el('div', '', '<b>分析：</b><br>' + an.steps.map(s => '· ' + s).join('<br>')));
  if (an.risks && an.risks.length) wrap.appendChild(el('div', '', '<b>风险：</b><br>' + an.risks.map(s => '· ' + s).join('<br>')));
  if (an.gains && an.gains.length) wrap.appendChild(el('div', '', '<b>可能收益：</b><br>' + an.gains.map(s => '· ' + s).join('<br>')));
  addMsg('ai', wrap);
  showPlanActions({ plan: false, execute: true, finish: true });
  showSubmit(false);
}

// ---------- 渲染：陪跑态 ----------
function renderExecute(out) {
  const wrap = el('div');
  wrap.appendChild(el('div', 'classification', `卡在第 ${out.step_ref} 步 · 类型：${out.blocker_type}`));
  wrap.appendChild(el('div', '', out.help || ''));
  if (out.expert_handoff) {
    const cp = el('div', 'copy-handoff', '📋 复制给专家 AI 的 Prompt');
    cp.onclick = () => { navigator.clipboard.writeText(out.expert_handoff.prompt); cp.textContent = '✓ 已复制'; };
    wrap.appendChild(cp);
  }
  if (out.confirm_question) wrap.appendChild(el('div', 'classification', out.confirm_question));
  addMsg('ai', wrap);
  showPlanActions({ plan: false, execute: false, finish: true });
  showSubmit(false);
}

// ---------- 渲染：完成态 ----------
function renderFinish(res) {
  const wrap = el('div');
  wrap.appendChild(el('div', '', `<b>总结：</b>${res.summary?.summary || ''}`));
  wrap.appendChild(el('div', 'classification', `下一步建议：${res.summary?.next_suggestion || ''}`));
  if (res.profile) wrap.appendChild(el('div', 'classification',
    `你的画像：水平 ${res.profile.level || '-'} · 目标 ${res.profile.goal || '-'} · 下一步节点 ${res.profile.next_node || '-'}`));
  addMsg('ai', wrap);
  $('#feedbackBox').classList.remove('hidden');
  showSubmit(false);
}

// 控制 plan/execute/finish 三个按钮（不含"提交分析"）
function showPlanActions({ plan, execute, finish }) {
  $('#planActions').classList.remove('hidden');
  $('#btnPlan').classList.toggle('hidden', !plan);
  $('#btnExecute').classList.toggle('hidden', !execute);
  $('#btnFinish').classList.toggle('hidden', !finish);
}
// 控制"提交分析"按钮显隐
function showSubmit(on) {
  $('#btnSubmitAnalysis').classList.toggle('hidden', !on);
}

// ---------- 交互 ----------
async function send() {
  const text = $('#input').value.trim();
  if (!text && Object.keys(state.answers).length === 0) return;
  if (state.confirmMode && !text) return; // 理解确认"不对"后必须输入解释
  state.confirmMode = false; // 任何发送都消费掉理解确认态
  addMsg('user', el('div', '', text || '（已回答本轮问题）'));
  $('#input').value = '';
  $('#input').placeholder = '描述你想完成的任务，或卡住的那一步…';

  const answersArr = Object.entries(state.answers).map(([qkey, v]) => ({ qkey, ...v }));
  const body = { visitor_id: state.visitorId, conversation_id: state.conversationId, message: text, answers: answersArr };
  if (state.missContext) {
    body.confirm_result = { confirmed: false, reason: text, original_understanding: state.missContext.original };
    state.missContext = null;
  }
  try {
    const res = await nav(body);
    state.conversationId = res.conversation_id;
    state.mode = res.mode;
    if (res.mode === 'diagnose') renderDiagnose(res.output);
    else if (res.mode === 'plan') renderPlan(res.output);
    else if (res.mode === 'execute') renderExecute(res.output);
  } catch (e) {
    const err = el('div', 'err', '⚠️ ' + (e.message || e));
    addMsg('ai', err);
    console.error('[navigation]', e);
  }
}

async function doPlan(confirmResult) {
  const body = { visitor_id: state.visitorId, conversation_id: state.conversationId, action: 'plan' };
  if (confirmResult) body.confirm_result = { confirmed: confirmResult.confirmed, original_understanding: confirmResult.original };
  const res = await nav(body);
  state.mode = 'plan';
  renderPlan(res.output);
}
async function doFinish() {
  const res = await nav({ visitor_id: state.visitorId, conversation_id: state.conversationId, action: 'finish' });
  state.mode = 'finish';
  renderFinish(res);
  $('#planActions').classList.add('hidden');
}
function doExecute() {
  state.mode = 'execute';
  showPlanActions({ plan: false, execute: false, finish: true });
  $('#input').focus();
  addMsg('ai', el('div', 'classification', '已进入陪跑模式，告诉我你卡在哪一步。'));
}

async function sendFeedback(score) {
  await fetch(API + '/api/feedback', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ visitor_id: state.visitorId, conversation_id: state.conversationId, score }),
  });
  document.querySelectorAll('#stars span').forEach(s => {
    s.classList.toggle('on', Number(s.dataset.score) <= score);
  });
}

// ---------- 启动 ----------
async function init() {
  await fetch(API + '/api/visitor', { method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ visitor_id: state.visitorId, consent_version: 'v1' }) }).catch(() => {});
  try {
    const d = await (await fetch(API + '/api/domains')).json();
    if (Array.isArray(d)) $('#domainChips').innerHTML = d.map(x => `<span class="chip">${x.label}</span>`).join('');
  } catch (e) { /* 字典暂时不可用不阻塞 */ }

  $('#btnSend').onclick = send;
  $('#input').addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } });
  $('#btnSubmitAnalysis').onclick = send;
  $('#btnPlan').onclick = doPlan;
  $('#btnExecute').onclick = doExecute;
  $('#btnFinish').onclick = doFinish;
  document.querySelectorAll('#stars span').forEach(s => { s.onclick = () => sendFeedback(Number(s.dataset.score)); });

  document.querySelectorAll('.hero .example').forEach(b => {
    b.onclick = () => { $('#input').value = b.textContent.trim(); $('#input').focus(); send(); };
  });

  addMsg('ai', el('div', '', '你好，我是你的认知导航员（导诊层）。说说你想完成的事——我不会急着给答案，先把关键问题问清楚，再帮你把问题提炼好交给大模型。'));
}
init();
