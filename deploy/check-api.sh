#!/usr/bin/env bash
# COS · API 自检脚本
# 用途：一次性确认「导诊层是否真的在调用大模型」，而不是在跑离线占位（stub）
# 用法：bash /tmp/check-api.sh
# 不需要 sudo。自动定位应用目录。

set -uo pipefail

# ---- 教训固化：pm2/node 装在 nvm 下，非交互 shell 拿不到 PATH ----
export PATH="/root/.nvm/versions/node/v20.20.2/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/root/guwenai"
[ -f "$SCRIPT_DIR/../package.json" ] && APP_DIR="$(dirname "$SCRIPT_DIR")"

G="\033[32m"; R="\033[31m"; Y="\033[33m"; N="\033[0m"
ok(){   echo -e "${G}  ✔ $1${N}"; }
bad(){  echo -e "${R}  ✘ $1${N}"; }
warn(){ echo -e "${Y}  ! $1${N}"; }

echo "=============================================="
echo " COS API 自检   目录: $APP_DIR"
echo "=============================================="

# ---------- 1/6 .env 是否存在、key 是否齐 ----------
echo ""
echo "[1/6] 检查 .env"
ENV_FILE="$APP_DIR/.env"
GKEY=""; DKEY=""
if [ ! -f "$ENV_FILE" ]; then
  bad ".env 不存在：$ENV_FILE"
  bad "→ 这就是产品没智慧的原因：没有 key 会走【离线占位】，永远只问那 3 个固定问题"
else
  ok ".env 存在"
  GKEY="$(grep -E '^GEMINI_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
  DKEY="$(grep -E '^DEEPSEEK_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
  mask(){ [ -z "$1" ] && echo "(空)" || echo "${1:0:6}...${1: -4}  (长度 ${#1})"; }
  echo "     GEMINI_API_KEY   = $(mask "$GKEY")"
  echo "     DEEPSEEK_API_KEY = $(mask "$DKEY")"
  [ -z "$GKEY" ] && [ -z "$DKEY" ] && bad "两个 key 都是空 → 必然走离线占位"
  # 常见错误：变量名写错
  for wrong in GOOGLE_API_KEY GEMINI_KEY API_KEY DEEPSEEK_KEY OPENAI_API_KEY; do
    grep -qE "^${wrong}=" "$ENV_FILE" && warn "发现变量名 ${wrong} —— 程序只认 GEMINI_API_KEY / DEEPSEEK_API_KEY，请改名"
  done
fi

# ---------- 2/6 pm2 进程是否拿到了环境变量 ----------
echo ""
echo "[2/6] 检查 pm2 进程环境变量"
if ! command -v pm2 >/dev/null 2>&1; then
  bad "pm2 未安装或不在 PATH"
else
  if pm2 list 2>/dev/null | grep -q navigator; then
    ok "pm2 进程 navigator 存在"
    PM2_ENV="$(pm2 env 0 2>/dev/null || true)"
    if echo "$PM2_ENV" | grep -q 'GEMINI_API_KEY'; then
      ok "进程内已加载 GEMINI_API_KEY"
    else
      warn "进程内看不到 GEMINI_API_KEY（可能是 dotenv 运行时读取，属正常；以第 5 步实测为准）"
    fi
  else
    bad "pm2 里没有 navigator 进程 → 网站根本没在跑"
  fi
fi

# ---------- 3/6 直连 Gemini ----------
echo ""
echo "[3/6] 直连测试 Gemini（主模型）"
if [ -n "$GKEY" ]; then
  RESP="$(curl -s -m 25 -w '\n__CODE__%{http_code}' \
    -X POST 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions' \
    -H "Authorization: Bearer $GKEY" -H 'Content-Type: application/json' \
    -d '{"model":"gemini-2.0-flash","messages":[{"role":"user","content":"只回复两个字：通了"}],"max_tokens":20}' 2>&1)"
  CODE="$(echo "$RESP" | tail -1 | sed 's/__CODE__//')"
  BODY="$(echo "$RESP" | sed '$d')"
  if [ "$CODE" = "200" ]; then
    ok "Gemini 连通 (HTTP 200)"
    echo "     返回：$(echo "$BODY" | grep -o '"content"[^,]*' | head -1)"
  else
    bad "Gemini 失败 HTTP $CODE"
    echo "     $(echo "$BODY" | head -c 300)"
    warn "国内 VPS 直连 Google 常被墙；若是超时/连接失败 → Gemini 用不了，需靠 DeepSeek 兜底"
  fi
else
  warn "跳过（GEMINI_API_KEY 为空）"
fi

# ---------- 4/6 直连 DeepSeek ----------
echo ""
echo "[4/6] 直连测试 DeepSeek（兜底）"
if [ -n "$DKEY" ]; then
  RESP="$(curl -s -m 25 -w '\n__CODE__%{http_code}' \
    -X POST 'https://api.deepseek.com/v1/chat/completions' \
    -H "Authorization: Bearer $DKEY" -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-chat","messages":[{"role":"user","content":"只回复两个字：通了"}],"max_tokens":20}' 2>&1)"
  CODE="$(echo "$RESP" | tail -1 | sed 's/__CODE__//')"
  BODY="$(echo "$RESP" | sed '$d')"
  if [ "$CODE" = "200" ]; then
    ok "DeepSeek 连通 (HTTP 200)"
    echo "     返回：$(echo "$BODY" | grep -o '"content"[^,]*' | head -1)"
  else
    bad "DeepSeek 失败 HTTP $CODE"
    echo "     $(echo "$BODY" | head -c 300)"
  fi
else
  warn "跳过（DEEPSEEK_API_KEY 为空）—— 强烈建议配上，Gemini 在国内 VPS 常连不上"
fi

# ---------- 5/6 重启进程并实测一次导诊 ----------
echo ""
echo "[5/6] 重启进程（--update-env 强制重读 .env）并实测一次导诊"
pm2 restart navigator --update-env >/dev/null 2>&1 && ok "已重启 navigator" || bad "重启失败"
sleep 4

VID="$(curl -s -m 10 -X POST http://127.0.0.1:3000/api/visitor -H 'Content-Type: application/json' -d '{}' | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)"
if [ -z "$VID" ]; then
  bad "拿不到 visitor id，服务可能没起来。看日志：pm2 logs navigator --lines 40"
else
  ok "服务响应正常 (visitor id=$VID)"
  OUT="$(curl -s -m 90 -X POST http://127.0.0.1:3000/api/navigation \
    -H 'Content-Type: application/json' \
    -d "{\"visitor_id\":$VID,\"message\":\"我准备拿10万玩权利金\"}")"
  echo ""
  echo "  —— 实测提问「我准备拿10万玩权利金」，返回的问题是 ——"
  echo "$OUT" | grep -o '"question":"[^"]*"' | sed 's/"question":"/     · /; s/"$//'
  echo ""
  if echo "$OUT" | grep -q '离线演示\|未配置模型 API Key'; then
    bad "★ 仍在跑【离线占位】—— key 没生效！问题永远是固定 3 连"
    echo "     排查顺序：.env 变量名 → 上面 3/4 步哪个通 → pm2 logs navigator"
  elif echo "$OUT" | grep -q '手机还是电脑'; then
    bad "★ 出现了占位问题「手机还是电脑」→ 大概率仍是离线占位"
  else
    ok "★ 已接入真实大模型，问题是现场生成的"
    echo "$OUT" | grep -o '"derived_from":"[^"]*"' | head -2 | sed 's/"derived_from":"/     溯源: /; s/"$//'
    echo "$OUT" | grep -o '"problem_type":"[^"]*"' | head -1 | sed 's/"problem_type":"/     类型: /; s/"$//'
    echo "$OUT" | grep -o '"confidence":[0-9]*' | head -1 | sed 's/"confidence":/     把握: /'
  fi
fi

# ---------- 6/6 代码版本 ----------
echo ""
echo "[6/6] 代码版本"
cd "$APP_DIR" 2>/dev/null && {
  echo "     HEAD: $(git log --oneline -1 2>/dev/null)"
  V="$(grep -E '^\s*bundleVersion:' config.yaml | head -1 | awk '{print $2}')"
  [ "$V" = "cos-v2.1" ] && ok "prompt 版本 $V（已是最新）" || warn "prompt 版本 $V（期望 cos-v2.1，等 auto-pull 同步或手动 git pull）"
}

echo ""
echo "=============================================="
echo " 自检结束"
echo "=============================================="
