const express = require('express');
const router = express.Router();
const db = require('../db');

// 简化版 AI 日报（MVP：用 SQL 聚合，不调用模型）
// 真实版后续由 AI 读取事件生成产品日报 + Protocol 建议
router.get('/daily', (req, res) => {
  const since = Date.now() - 86400000;
  const visitors = db.prepare('SELECT COUNT(DISTINCT visitor_id) c FROM events WHERE created_at>?').get(since).c;
  const domains = db.prepare(
    "SELECT domain, COUNT(*) c FROM events WHERE event_type='navigation_turn' AND created_at>? GROUP BY domain"
  ).all(since);
  const drops = db.prepare(
    "SELECT domain, COUNT(*) c FROM events WHERE event_type='drop' AND created_at>? GROUP BY domain"
  ).all(since);
  const likes = db.prepare("SELECT COUNT(*) c FROM events WHERE event_type='thumb_up' AND created_at>?").get(since).c;
  const dislikes = db.prepare("SELECT COUNT(*) c FROM events WHERE event_type='thumb_down' AND created_at>?").get(since).c;
  const feedback = db.prepare('SELECT score, COUNT(*) c FROM feedback WHERE created_at>? GROUP BY score').all(since);
  res.json({ since, visitors, domains, drops, likes, dislikes, feedback });
});

// 核心 KPI 面板（护城河数据产品）
// 1) 平均建档问题数趋势（按天）2) 可省问题 Top20 3) 字典健康度 4) 待归并新类型
router.get('/kpi', (req, res) => {
  // 1. 平均建档问题数趋势（最近 14 天）
  const qTrend = db.prepare(`
    SELECT date(started_at/1000, 'unixepoch') d, AVG(total_questions) avg_q, COUNT(*) n
    FROM outcomes WHERE total_questions > 0
    GROUP BY d ORDER BY d DESC LIMIT 14
  `).all();

  // 2. 可省问题 Top20（被跳过 asked=0 的高频问题）
  const skippable = db.prepare(`
    SELECT qkey, question, COUNT(*) c
    FROM diagnostic_questions WHERE asked=0
    GROUP BY qkey ORDER BY c DESC LIMIT 20
  `).all();

  // 3. 字典健康度
  const totalSnap = db.prepare('SELECT COUNT(*) c FROM cos_snapshots WHERE task_type IS NOT NULL').get().c;
  const newType = db.prepare('SELECT COUNT(*) c FROM cos_snapshots WHERE is_new_task_type=1').get().c;
  const distinctType = db.prepare('SELECT COUNT(DISTINCT task_type) c FROM cos_snapshots WHERE task_type IS NOT NULL').get().c;
  const dictHealth = {
    total_classified: totalSnap,
    new_task_type: newType,
    new_type_ratio: totalSnap ? +(newType / totalSnap).toFixed(3) : 0,
    distinct_task_types: distinctType,
  };

  // 4. 待归并新类型（is_new_task_type=1 且尚未进入受控候选的 task_type）
  const pendingMerge = db.prepare(`
    SELECT task_type, COUNT(*) c FROM cos_snapshots
    WHERE is_new_task_type=1 GROUP BY task_type ORDER BY c DESC LIMIT 30
  `).all();

  res.json({ qTrend, skippable, dictHealth, pendingMerge });
});

// affected_plan 人工 / 离线分析回填接口
// 铁律：AI 不得写入 affected_plan；本接口仅允许 labeled_by = human / analysis
router.post('/affected-plan', (req, res) => {
  const { conversation_id, qkey, affected_plan, labeled_by } = req.body || {};
  if (!conversation_id || !qkey) return res.status(400).json({ error: 'conversation_id & qkey required' });
  if (![0, 1].includes(affected_plan)) return res.status(400).json({ error: 'affected_plan must be 0 or 1' });
  if (!['human', 'analysis'].includes(labeled_by)) return res.status(400).json({ error: 'labeled_by must be human or analysis' });
  const r = db.prepare(
    `UPDATE diagnostic_questions SET affected_plan=?, labeled_by=?, labeled_at=? WHERE conversation_id=? AND qkey=?`
  ).run(affected_plan, labeled_by, Date.now(), conversation_id, qkey);
  if (r.changes === 0) return res.status(404).json({ error: 'no matching question row' });
  res.json({ ok: true, affected_plan, labeled_by });
});

module.exports = router;
