// DB Schema v1.0（2026-08-04 锁定）
// 命名铁律：
//   domain = 受控大类字典（content/code/commerce/...），一级统计口径
//   topic  = 推荐话题（期权/武汉旅游...），仅用于首页 chips
//   AI 禁止写入的列：outcomes.completed / diagnostic_questions.affected_plan
const path = require('path');
const fs = require('fs');
const Database = require('better-sqlite3');

const dataDir = path.join(__dirname, '..', 'data');
if (!fs.existsSync(dataDir)) fs.mkdirSync(dataDir, { recursive: true });

const db = new Database(path.join(dataDir, 'app.db'));
db.pragma('journal_mode = WAL');

db.exec(`
-- ============ 主体 ============
CREATE TABLE IF NOT EXISTS visitors (
  visitor_id      TEXT PRIMARY KEY,
  created_at      INTEGER NOT NULL,
  consent_version TEXT,
  consent_at      INTEGER,
  status          TEXT DEFAULT 'active'
);

-- 一次导航任务 = 一条 conversation（不设 session 层）
CREATE TABLE IF NOT EXISTS conversations (
  id          TEXT PRIMARY KEY,
  visitor_id  TEXT NOT NULL,
  topic       TEXT,                       -- 推荐话题（可空）
  domain      TEXT,                       -- 受控大类（最新值，权威历史在 cos_snapshots）
  task_type   TEXT,
  intent      TEXT,
  mode        TEXT DEFAULT 'diagnose',    -- diagnose / execute（plan 是瞬时态）
  round_count INTEGER DEFAULT 0,          -- 已完成的诊断轮次
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER,
  status      TEXT DEFAULT 'active'
);
CREATE INDEX IF NOT EXISTS idx_conv_visitor ON conversations(visitor_id, created_at);

CREATE TABLE IF NOT EXISTS messages (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  role            TEXT NOT NULL,
  content         TEXT NOT NULL,
  token_cost      INTEGER DEFAULT 0,
  created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id, created_at);

-- ============ 思考快照：一轮 AI 思考 = 一行 ============
CREATE TABLE IF NOT EXISTS cos_snapshots (
  id                 TEXT PRIMARY KEY,
  visitor_id         TEXT NOT NULL,
  conversation_id    TEXT NOT NULL,
  created_at         INTEGER NOT NULL,
  mode               TEXT NOT NULL,       -- diagnose / plan / execute
  domain             TEXT,                -- 受控字典（一级统计）
  task_type          TEXT,                -- 半受控（二级统计）
  is_new_task_type   INTEGER DEFAULT 0,
  intent             TEXT,                -- 自由（细分意图）
  sufficiency_score  INTEGER,
  question_count     INTEGER DEFAULT 0,
  roadmap_step_count INTEGER,
  self_progress      INTEGER,             -- AI 主观进度，仅供前端进度条，禁止进 KPI
  snapshot_version   TEXT,                -- prompt bundle 版本
  snapshot_json      TEXT                 -- AI 完整思考过程
);
CREATE INDEX IF NOT EXISTS idx_snap_conv   ON cos_snapshots(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_snap_domain ON cos_snapshots(domain, created_at);
CREATE INDEX IF NOT EXISTS idx_snap_task   ON cos_snapshots(task_type, created_at);
CREATE INDEX IF NOT EXISTS idx_snap_mode   ON cos_snapshots(mode, created_at);
CREATE INDEX IF NOT EXISTS idx_snap_newtt  ON cos_snapshots(is_new_task_type);

-- ============ 护城河：问题级明细 ============
-- affected_plan 默认 NULL；服务端与 AI 均禁止写入，只允许人工/离线分析回填
CREATE TABLE IF NOT EXISTS diagnostic_questions (
  id              TEXT PRIMARY KEY,
  snapshot_id     TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  qkey            TEXT,                   -- 问题稳定键，便于跨会话聚合
  question        TEXT NOT NULL,
  criticality     TEXT,                   -- blocking / assumable
  why             TEXT,
  options         TEXT,                   -- JSON 数组
  asked           INTEGER DEFAULT 1,      -- 1=真问了 0=用户跳过
  assumption      TEXT,                   -- 跳过时采用的默认假设
  answered        INTEGER DEFAULT 0,
  answer          TEXT,
  affected_plan   INTEGER,                -- 1/0/NULL；NULL=未判定（默认且唯一合法初值）
  labeled_by      TEXT,                   -- 谁回填的：human / analysis（AI 不得出现）
  labeled_at      INTEGER,
  created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_dq_snap ON diagnostic_questions(snapshot_id);
CREATE INDEX IF NOT EXISTS idx_dq_conv ON diagnostic_questions(conversation_id);
CREATE INDEX IF NOT EXISTS idx_dq_crit ON diagnostic_questions(criticality, affected_plan);
CREATE INDEX IF NOT EXISTS idx_dq_key  ON diagnostic_questions(qkey);

-- ============ 闭环：结果（一次导航任务 = 一行）============
-- completed 只由行为信号推导，AI 与 Prompt 均无权写入
CREATE TABLE IF NOT EXISTS outcomes (
  conversation_id  TEXT PRIMARY KEY,
  visitor_id       TEXT,
  domain           TEXT,
  task_type        TEXT,
  started_at       INTEGER,
  first_plan_at    INTEGER,
  finished_at      INTEGER,
  last_activity_at INTEGER,
  completed        INTEGER,               -- 1/0/NULL（默认 NULL）
  completed_reason TEXT,                  -- 判定依据，便于审计
  total_questions  INTEGER DEFAULT 0,
  execute_rounds   INTEGER DEFAULT 0,
  handoff_count    INTEGER DEFAULT 0,
  feedback_score   INTEGER
);
CREATE INDEX IF NOT EXISTS idx_out_domain ON outcomes(domain, completed);
CREATE INDEX IF NOT EXISTS idx_out_active ON outcomes(last_activity_at);

-- ============ 行为事件 ============
CREATE TABLE IF NOT EXISTS events (
  id              TEXT PRIMARY KEY,
  visitor_id      TEXT,
  conversation_id TEXT,
  event_type      TEXT NOT NULL,
  domain          TEXT,
  topic           TEXT,
  payload         TEXT,
  token_cost      INTEGER DEFAULT 0,
  created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ev_type ON events(event_type, created_at);
CREATE INDEX IF NOT EXISTS idx_ev_conv ON events(conversation_id);

CREATE TABLE IF NOT EXISTS feedback (
  id              TEXT PRIMARY KEY,
  visitor_id      TEXT,
  domain          TEXT,
  topic           TEXT,
  conversation_id TEXT,
  score           INTEGER,
  content         TEXT,
  created_at      INTEGER NOT NULL
);

-- ============ 画像（分区键为受控大类）============
CREATE TABLE IF NOT EXISTS cognitive_profiles (
  visitor_id       TEXT NOT NULL,
  domain           TEXT NOT NULL,
  level            TEXT,
  goal             TEXT,
  motivation       TEXT,
  resources        TEXT,
  current_position TEXT,
  known_nodes      TEXT,
  unknown_nodes    TEXT,
  next_node        TEXT,
  risk             TEXT,
  last_navigation  INTEGER,
  updated_at       INTEGER,
  PRIMARY KEY (visitor_id, domain)
);

-- ============ 配置 / 字典 / 版本 ============
CREATE TABLE IF NOT EXISTS domain_dict (
  domain      TEXT PRIMARY KEY,
  label_zh    TEXT,
  description TEXT,
  active      INTEGER DEFAULT 1,
  sort        INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS topic_cache (
  topic      TEXT PRIMARY KEY,
  skeleton   TEXT,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS protocol_versions (
  version    TEXT PRIMARY KEY,
  content    TEXT,
  created_at INTEGER NOT NULL,
  active     INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS prompt_versions (
  version    TEXT NOT NULL,
  name       TEXT NOT NULL,
  path       TEXT,
  content    TEXT,
  created_at INTEGER NOT NULL,
  active     INTEGER DEFAULT 0,
  PRIMARY KEY (version, name)
);

CREATE TABLE IF NOT EXISTS schema_versions (
  version    TEXT PRIMARY KEY,
  applied_at INTEGER NOT NULL,
  note       TEXT
);
`);

// 记录 schema 版本
db.prepare('INSERT OR IGNORE INTO schema_versions (version, applied_at, note) VALUES (?,?,?)')
  .run('v1.0', Date.now(), 'COS 三态 + Ontology + Outcome 闭环，字段锁定');

module.exports = db;
