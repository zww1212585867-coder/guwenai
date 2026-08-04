// COS 编排层：装载 prompt bundle、注入占位符、按三态调用模型
// 分层铁律：cos.md = 核心资产（只谈思考）；_output.md = 输出契约（只谈格式）
const fs = require('fs');
const path = require('path');
const { chat, buildMessages } = require('./model');
const db = require('../db');

const PROMPT_DIR = path.join(__dirname, '..', 'prompts');
const read = (name) => fs.readFileSync(path.join(PROMPT_DIR, name), 'utf8');

// ---------- 占位符注入 ----------
function domainDictText() {
  const rows = db.prepare('SELECT domain, label_zh, description FROM domain_dict WHERE active=1 ORDER BY sort').all();
  if (!rows.length) return '（字典未初始化，请先运行 npm run seed）';
  return rows.map((r) => `- ${r.domain}（${r.label_zh}）：${r.description}`).join('\n');
}

function taskTypeCandidates(limit) {
  const rows = db.prepare(
    'SELECT task_type, COUNT(*) n FROM cos_snapshots WHERE task_type IS NOT NULL GROUP BY task_type ORDER BY n DESC LIMIT ?'
  ).all(limit || 30);
  if (!rows.length) return '（暂无历史记录，本次可自行新建并标记为新建）';
  return rows.map((r) => `${r.task_type}(${r.n})`).join('、');
}

function inject(text, cfg) {
  const d = cfg.diagnosis || {};
  return text
    .replace(/\{\{SUFFICIENCY_THRESHOLD\}\}/g, d.sufficiency_threshold ?? 70)
    .replace(/\{\{MAX_QUESTIONS_PER_ROUND\}\}/g, d.max_questions_per_round ?? 6)
    .replace(/\{\{MAX_ROUNDS\}\}/g, d.max_rounds ?? 2)
    .replace(/\{\{DOMAIN_DICT\}\}/g, domainDictText())
    .replace(/\{\{TASK_TYPE_CANDIDATES\}\}/g, taskTypeCandidates(d.task_type_candidates));
}

const MODE_FILE = { diagnose: 'diagnose.md', plan: 'plan.md', execute: 'execute.md' };

// 最终 System Prompt = 核心资产 + 状态子提示词 + 输出契约（顺序固定）
function systemPrompt(cfg, mode) {
  const parts = [read('cos.md'), read(MODE_FILE[mode] || 'diagnose.md'), read('_output.md')];
  return inject(parts.join('\n\n---\n\n'), cfg);
}

function bundleVersion(cfg) {
  return (cfg.prompt && cfg.prompt.bundleVersion) || 'cos-v1.0';
}

// ---------- JSON 解析（容错）----------
function parseJson(content) {
  try { return JSON.parse(content); } catch (_) { /* fallthrough */ }
  const m = content.match(/\{[\s\S]*\}/);
  if (m) { try { return JSON.parse(m[0]); } catch (_) { /* fallthrough */ } }
  return null;
}

// AI 越权字段一律剥离（防止污染 KPI）
const FORBIDDEN = ['roadmap_success', 'completed', 'affected_plan', 'success_rate'];
function stripForbidden(obj) {
  if (Array.isArray(obj)) return obj.map(stripForbidden);
  if (obj && typeof obj === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(obj)) {
      if (FORBIDDEN.includes(k)) continue;
      out[k] = stripForbidden(v);
    }
    return out;
  }
  return obj;
}

// ---------- 主调用 ----------
async function runMode(cfg, { mode, history, message, profile }) {
  let sys = systemPrompt(cfg, mode);
  if (profile) sys += '\n\n---\n\n' + inject(read('continue.md'), cfg).replace('{profile}', JSON.stringify(profile));

  const messages = buildMessages(sys, history || [], message);
  const { content, tokenCost } = await chat(cfg, messages, { json: true, mode });

  let output = parseJson(content);
  let parseFailed = false;
  if (!output) { parseFailed = true; output = { mode, parse_error: true, raw: content }; }
  output = stripForbidden(output);
  output.mode = mode;
  return { output, tokenCost, parseFailed };
}

// 完成导航时提取认知画像（一次会话只跑一次，省成本）
async function extractProfile(cfg, { history }) {
  const sys = inject(read('memory.md'), cfg);
  const messages = buildMessages(sys, history || [], '请提取用户认知画像，只输出 JSON。');
  const { content } = await chat(cfg, messages, { json: true, mode: 'memory' });
  return parseJson(content);
}

async function summarize(cfg, { history }) {
  const sys = inject(read('summary.md'), cfg);
  const messages = buildMessages(sys, history || [], '请生成本次导航总结。');
  const { content } = await chat(cfg, messages, { json: true, mode: 'summary' });
  return parseJson(content) || { summary: content };
}

module.exports = { runMode, extractProfile, summarize, bundleVersion, systemPrompt, domainDictText };
