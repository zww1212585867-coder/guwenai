// 种子数据 v1.0（2026-08-04）：Protocol 版本 + Prompt 版本 + 受控字典 + 话题骨架
// 运行：npm run seed
const fs = require('fs');
const path = require('path');
const db = require('../server/db');

const root = path.join(__dirname, '..');
const promptsDir = path.join(root, 'server', 'prompts');
const PROMPT_BUNDLE = 'cos-v1.0';
const ts = Date.now();

// ---- 1. Protocol 版本（核心资产 cos.md）----
const cosContent = fs.readFileSync(path.join(promptsDir, 'cos.md'), 'utf8');
db.prepare('INSERT OR IGNORE INTO protocol_versions (version, content, created_at, active) VALUES (?,?,?,?)')
  .run(PROMPT_BUNDLE, cosContent, ts, 1);

// ---- 2. Prompt 版本快照（全套 prompt 文件）----
const promptFiles = ['cos.md', '_output.md', 'diagnose.md', 'plan.md', 'execute.md', 'continue.md', 'memory.md', 'summary.md'];
const insPrompt = db.prepare(
  'INSERT OR IGNORE INTO prompt_versions (version, name, path, content, created_at, active) VALUES (?,?,?,?,?,?)'
);
for (const p of promptFiles) {
  const content = fs.readFileSync(path.join(promptsDir, p), 'utf8');
  insPrompt.run(PROMPT_BUNDLE, p, 'server/prompts/' + p, content, ts, 1);
}

// ---- 3. 受控大类字典 domain_dict（9 类，一级统计口径）----
const domains = [
  ['content', '内容创作', '写作、短视频、图文、自媒体等表达类任务', 1],
  ['code', '编程开发', '写代码、做网站 / 工具 / 自动化、调试排错', 2],
  ['commerce', '电商经营', '开店、选品、投流、带货等经营动作', 3],
  ['finance', '投资理财', '股票、期权、基金、资产配置与风控', 4],
  ['career', '职业成长', '求职、面试、转行、晋升、副业', 5],
  ['life', '生活决策', '搬家、婚恋、消费、人际关系等生活难题', 6],
  ['health', '身心健康', '健身、饮食、睡眠、情绪管理', 7],
  ['learning', '学习成长', '考证、学语言、学技能的方法与路径', 8],
  ['other', '其他', '无法归入以上八类的任务', 9],
];
const insDomain = db.prepare(
  'INSERT OR IGNORE INTO domain_dict (domain, label_zh, description, active, sort) VALUES (?,?,?,1,?)'
);
for (const [d, zh, desc, sort] of domains) insDomain.run(d, zh, desc, sort);

// ---- 4. 话题骨架缓存 topic_cache（首页 chips 用，只存骨架）----
const skeletons = {
  options: { name: '期权', intro: '用期权表达观点、对冲与收租的策略体系', entryNodes: ['认购/认沽', '备兑看涨', '现金担保看跌', '轮动'] },
  'ai-music': { name: 'AI音乐', intro: '用 AI 工具作词 / 作曲 / 演唱 / 混音的入门路径', entryNodes: ['工具选型', '作词', '编曲', '混音'] },
  'wuhan-travel': { name: '武汉旅游', intro: '武汉吃住行游的个性化规划', entryNodes: ['季节', '必吃', '路线', '住宿'] },
  startup: { name: '创业', intro: '从 idea 到验证到营收的冷启动路径', entryNodes: ['痛点', 'MVP', '获客', '变现'] },
};
const insTopic = db.prepare('INSERT OR IGNORE INTO topic_cache (topic, skeleton, updated_at) VALUES (?,?,?)');
for (const [t, s] of Object.entries(skeletons)) insTopic.run(t, JSON.stringify(s), ts);

console.log(`Seed done: protocol ${PROMPT_BUNDLE}, ${promptFiles.length} prompts, ${domains.length} domains, ${Object.keys(skeletons).length} topic skeletons.`);
