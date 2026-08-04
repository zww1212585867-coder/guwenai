# 张维维贴身顾问 · 认知导航器（Cognitive Navigator / COS）

一个帮**完全陌生的用户**以最低认知成本进入任意领域的「认知导航」网页应用（类比高德地图 / GPS）。

本仓库是**可运行的工程地基**：三态状态机（诊断 → 规划 → 陪跑）、SQLite 数据库、API、前后端全部齐备。

> **MVP 说明**：未配置模型 API Key 时返回**离线占位 JSON**（结构合法），整条链路（UI / 埋点 / KPI / `affected_plan` 标注）都能本地演示；配置 `DEEPSEEK_API_KEY` 后由 AI 实时生成导航。

---

## 1. 这是什么（COS 三态）

| 状态 | 做什么 | 禁止 |
|---|---|---|
| **诊断 diagnose** | 理解任务、建上下文、提最少问题、判信息是否够 | 不给方案、不推荐工具 |
| **规划 plan** | 信息够了，一次性输出可执行路线（含专家交接 Prompt） | 不再提问、不重回诊断 |
| **陪跑 execute** | 帮用户完成当前卡住的那一步 | 不重规划、不重诊断 |

- `affected_plan`（某个问题是否真改变了方案）：**默认 NULL，AI 与代码都禁止写入**，只能人工 / 离线分析回填 → `/api/admin/affected-plan`。
- `completed`（是否完成）：**只由行为信号推导**（点了完成 / 评分≥4 = 完成；点踩 / 评分≤2 = 未完成），AI 无权自评。
- 护城河数据：诊断问题明细、认知快照、`domain_dict` 受控字典。

---

## 2. 目录结构

```
cognitive-navigator/
├── package.json          # 依赖 + 脚本（start / dev / seed）
├── package-lock.json     # 锁定依赖版本，VPS 上 npm ci 可复现
├── config.yaml           # 所有可调参数（端口/模型/诊断阈值/缓存…）
├── .env.example          # 环境变量样例（API Key），复制为 .env 使用
├── server/
│   ├── index.js          # Express 入口，挂载路由 + 静态前端
│   ├── config.js         # 读 config.yaml + 注入 ${ENV} 环境变量
│   ├── db.js             # better-sqlite3 初始化 + 14 张表 schema（v1.0 锁定）
│   ├── routes/           # visitor / navigation / event / feedback / domains / admin / protocol
│   ├── services/
│   │   ├── model.js      # 模型调用层（DeepSeek/OpenAI 兼容）+ 离线 stub
│   │   ├── protocol.js   # COS 编排：读 prompts + 占位符注入 + 调模型 + 剥离禁写字段
│   │   └── outcome.js    # Outcome 闭环：completed 仅由行为信号推导
│   └── prompts/          # Prompt 文件（不写死在代码里，框架师可独立改）
│       ├── cos.md        # P1 核心协议（定位+三态+十原则+自我约束）
│       ├── diagnose.md   # P2 诊断态子提示词
│       ├── plan.md       # P3 规划态子提示词
│       ├── execute.md    # P_exec 陪跑态子提示词
│       └── _output.md    # JSON 输出契约（三态字段 + 禁止输出字段）
├── public/               # 前端（原生 HTML/CSS/JS，无构建步骤）
│   ├── index.html
│   ├── styles.css
│   └── app.js
├── scripts/
│   └── seed.js           # 种子数据（领域字典 9 类 + Prompt 快照 + schema 版本）
└── data/                 # SQLite 文件（运行时生成，**已 gitignore，不会进仓库**）
```

---

## 3. 本地运行

```bash
npm install
cp .env.example .env        # 可选；不填也能跑离线模式
npm run seed                # 建库 + 写 9 类领域字典
npm start                   # 或 npm run dev（热重载）
# 打开 http://localhost:3000
```

---

## 4. 数据库（14 张表，v1.0 锁定）

| 表 | 作用（关键字段） |
|---|---|
| `visitors` | 匿名访客（不登录） |
| `conversations` | 一次导航任务 = 1 行；`mode`(diagnose/execute)、`domain`/`task_type`/`intent` 三层认知树 |
| `messages` | 每条消息 |
| `cos_snapshots` | 一轮 AI 思考 = 1 行（含 `snapshot_json` 完整过程、`sufficiency_score`、`is_new_task_type`） |
| `diagnostic_questions` | 问题级明细（`criticality`、`asked`/`assumption`、`affected_plan` 默认 NULL 禁写） |
| `outcomes` | 一次任务闭环（`completed` 只由行为推导、`total_questions`、`handoff_count`） |
| `events` | 行为事件（`enter`/`click`/`finish_clicked`/`thumb_up`/`thumb_down`/`handoff_prompt_copied`…） |
| `feedback` | 用户评分 + 文字 |
| `cognitive_profiles` | 认知画像（分区键 `domain` = 受控大类） |
| `domain_dict` | 受控领域字典（content/code/commerce/finance/career/life/health/learning/other） |
| `topic_cache` | 首页推荐话题骨架缓存 |
| `protocol_versions` | Protocol 版本 |
| `prompt_versions` | Prompt 版本快照 |
| `schema_versions` | 数据库 schema 版本记录 |

---

## 5. API（三态）

`POST /api/navigation`

```jsonc
// 请求
{ "visitor_id": "uuid", "message": "用户说的话",
  "conversation_id": "可选，续接同一轮",
  "finish": false,            // true = 用户点完成，触发画像+总结
  "answers": [ {"key":"budget","skipped":true} ] }  // 用户回答/跳过回填

// 返回（diagnose 态示例）
{ "mode":"diagnose",
  "classification": {"domain":"other","task_type":"…","intent":"…"},
  "sufficiency": {"score":45,"reason":"…"},
  "questions": [ {"key":"device","question":"…","criticality":"blocking",
                  "why":"…","options":["手机","电脑"],"default_assumption":null} ] }

// 返回（plan 态）：含 assumptions[] + roadmap[]（每步 what/why/eta/done_when/next/owner/expert_handoff）
// 返回（execute 态）：含 step_ref / blocker_type / help / confirm_question
```

其他接口：`GET /api/domains`、`POST /api/visitor`、`POST /api/event`、`POST /api/feedback`、`GET /api/admin/kpi`、`POST /api/admin/affected-plan`。

---

## 6. 部署（GitHub → VPS）★

> 本仓库已由 WorkBuddy 初始化并提交（本地 commit 完成）。**密钥从不会进仓库**（`.env` 已 gitignore）。

### 第 1 步：推到你自己的 GitHub

在你自己的电脑上（仓库文件夹已就绪），执行：

```bash
git remote add origin https://github.com/你的用户名/你的仓库.git
git branch -M main
git push -u origin main
```

> 若用 **GitHub Desktop**：把空仓库克隆到本地 → 把 `cognitive-navigator` 文件夹内容复制进去 → Commit → Push。

### 第 2 步：VPS 上拉取并跑起来（FinalShell 里）

```bash
# —— 装 Node 18+（用 nvm 最稳；Ubuntu/Debian）——
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc
nvm install 20 && node -v

# —— 拉仓库 ——
git clone https://github.com/你的用户名/你的仓库.git
cd cognitive-navigator

# —— 装依赖 + 建库 ——
npm install
npm run seed

# —— 填密钥 ——
nano .env
# 写入：DEEPSEEK_API_KEY=sk-你的真实key
# Ctrl+O 保存，Ctrl+X 退出

# —— 前台启动测试（先看日志）——
npm start
# 看到 "Cognitive Navigator running on http://0.0.0.0:3000" 即成功
# 浏览器开 http://你的VPS_IP:3000
```

放行防火墙（临时用 3000 端口测试）：
```bash
sudo ufw allow 3000
```

**后台守护**（Ctrl+C 停掉前台后）：
```bash
npm install -g pm2
pm2 start server/index.js --name navigator
pm2 save
pm2 startup        # 按提示把返回的 sudo 命令再跑一次，实现开机自启
pm2 logs navigator # 看日志
```

### 第 3 步：域名 + HTTPS（推荐，可选）

1. 域名控制台把 **A 记录**指向 VPS 公网 IP。
2. 装 Nginx + Certbot 做反代 + 免费 HTTPS：
```bash
sudo apt install -y nginx certbot python3-certbot-nginx
sudo certbot --nginx -d 你的域名.com
```
Nginx 反代配置（示例 `/etc/nginx/sites-available/navigator`）：
```nginx
server {
  listen 80; server_name 你的域名.com;
  location / { proxy_pass http://127.0.0.1:3000; proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr; }
}
```
配好后访问 `https://你的域名.com`，并 `sudo ufw allow 'Nginx Full'`、关掉 3000 直连。

---

## 7. 模型切换（DeepSeek ↔ Gemini）

默认用 **DeepSeek**。想换 **Gemini 免费额度**（年费会员）只需改 `config.yaml` 的 `model` 段，不动代码：

```yaml
model:
  provider: gemini
  apiKey: ${GEMINI_API_KEY}        # 在 .env 里填 GEMINI_API_KEY=
  baseUrl: https://generativelanguage.googleapis.com/v1beta/openai   # OpenAI 兼容端点
  model: gemini-2.0-flash
  temperature: 0.7
  maxTokens: 2000
```

> 切换后 `npm start` 重启即生效。当前 `model.js` 为单模型直连（无自动兜底）；如需「DeepSeek 失败自动转 Gemini」，告诉我，我加几行 fallback 逻辑。

---

## 8. 后续（待真实用户验证后做）

- 登录 / 跨设备同步（仅当用户主动要求）
- 领域骨架异步刷新（按 `cache.topicTtlHours` 过期重建）
- 隐私政策 / 用户协议（由框架师据本工程字段起草）
