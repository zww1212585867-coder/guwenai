// Outcome（结果闭环）服务
// 铁律：outcomes.completed 只能由行为信号推导，AI / Prompt 一律无权写入
const db = require('../db');

function open(conversationId, visitorId, now) {
  db.prepare(
    `INSERT OR IGNORE INTO outcomes (conversation_id, visitor_id, started_at, last_activity_at, completed)
     VALUES (?,?,?,?,NULL)`
  ).run(conversationId, visitorId, now, now);
}

function touch(conversationId, now) {
  db.prepare('UPDATE outcomes SET last_activity_at=? WHERE conversation_id=?').run(now, conversationId);
}

function setClassification(conversationId, domain, taskType) {
  db.prepare(
    'UPDATE outcomes SET domain=COALESCE(?,domain), task_type=COALESCE(?,task_type) WHERE conversation_id=?'
  ).run(domain || null, taskType || null, conversationId);
}

function addQuestions(conversationId, n) {
  if (!n) return;
  db.prepare('UPDATE outcomes SET total_questions=total_questions+? WHERE conversation_id=?').run(n, conversationId);
}

function markPlanned(conversationId, now) {
  db.prepare('UPDATE outcomes SET first_plan_at=COALESCE(first_plan_at,?) WHERE conversation_id=?').run(now, conversationId);
}

function addExecuteRound(conversationId) {
  db.prepare('UPDATE outcomes SET execute_rounds=execute_rounds+1 WHERE conversation_id=?').run(conversationId);
}

function addHandoff(conversationId) {
  db.prepare('UPDATE outcomes SET handoff_count=handoff_count+1 WHERE conversation_id=?').run(conversationId);
}

// ---- 行为信号 → completed 判定（规则写死在代码，不给 AI）----
// 1  ← 点击"完成导航" / 评分>=4
// 0  ← 点踩 / 评分<=2
// null 保持（放弃由查询时懒判定，不落列）
function deriveFromEvent(conversationId, eventType, now) {
  if (!conversationId) return;
  if (eventType === 'finish_clicked' || eventType === 'finish_navigation') {
    db.prepare("UPDATE outcomes SET completed=1, completed_reason='finish_clicked', finished_at=? WHERE conversation_id=?")
      .run(now, conversationId);
  } else if (eventType === 'thumb_down') {
    db.prepare("UPDATE outcomes SET completed=0, completed_reason='thumb_down' WHERE conversation_id=? AND completed IS NULL")
      .run(conversationId);
  } else if (eventType === 'handoff_prompt_copied') {
    addHandoff(conversationId);
  }
  touch(conversationId, now);
}

function deriveFromFeedback(conversationId, score, now) {
  if (!conversationId || score == null) return;
  db.prepare('UPDATE outcomes SET feedback_score=? WHERE conversation_id=?').run(score, conversationId);
  if (score >= 4) {
    db.prepare("UPDATE outcomes SET completed=1, completed_reason='feedback>=4', finished_at=COALESCE(finished_at,?) WHERE conversation_id=? AND completed IS NULL")
      .run(now, conversationId);
  } else if (score <= 2) {
    db.prepare("UPDATE outcomes SET completed=0, completed_reason='feedback<=2' WHERE conversation_id=? AND completed IS NULL")
      .run(conversationId);
  }
  touch(conversationId, now);
}

module.exports = {
  open, touch, setClassification, addQuestions, markPlanned,
  addExecuteRound, addHandoff, deriveFromEvent, deriveFromFeedback,
};
