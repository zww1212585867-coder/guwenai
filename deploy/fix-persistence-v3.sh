#!/usr/bin/env bash
# fix-persistence-v3.sh —— 不用 sudo / 强制加 npm PATH / pm2 用绝对路径
# 用户已是 root，先确保 pm2/node/npm 在 PATH 里

set -u
cd /root/guwenai 2>/dev/null || { echo "❌ /root/guwenai 不存在"; exit 1; }

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[1;33m'; NC='\033[0m'

# === 关键修复 1：手动注入 npm 全局 bin 到 PATH（避免 sudo 抢 PATH） ===
NPM_PREFIX="$(npm prefix -g 2>/dev/null || echo /usr/local)"
export PATH="$NPM_PREFIX/bin:/usr/local/bin:/usr/bin:/bin:/sbin:$PATH"

# === 关键修复 2：用绝对路径定位 pm2，找不到就装 ===
PM2="$(command -v pm2 2>/dev/null || true)"
if [ -z "$PM2" ] || [ ! -x "$PM2" ]; then
  npm install -g pm2 --silent 2>&1 | tail -3 || true
  PM2="$(command -v pm2 2>/dev/null || true)"
fi
if [ -z "$PM2" ] || [ ! -x "$PM2" ]; then
  PM2="$(find / -path /proc -prune -o -name pm2 -type f -print 2>/dev/null | grep -v /proc | head -1)"
fi
echo "[init] pm2 路径: ${PM2:-NOT-FOUND}"

echo ""
echo "[1/6] 用 heredoc 强制覆盖 deploy/auto-pull.sh（自定位 + 绝对 pm2 路径）"
cat > /root/guwenai/deploy/auto-pull.sh <<AUTOPULL_EOF
#!/usr/bin/env bash
# VPS 端自动同步脚本：每 60 秒从 GitHub 拉最新代码 + pm2 重启
set -euo pipefail
NPM_PREFIX="\$(npm prefix -g 2>/dev/null || echo /usr/local)"
export PATH="\$NPM_PREFIX/bin:/usr/local/bin:/usr/bin:/bin:/sbin:\$PATH"
PM2_CMD="\$(command -v pm2 || echo \${NPM_PREFIX}/bin/pm2)"

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="\$(dirname "\$SCRIPT_DIR")"
BRANCH="main"
LOG_PREFIX="[\$(date '+%F %T')]"

cd "\$APP_DIR"
git fetch --quiet origin
LOCAL=\$(git rev-parse HEAD)
REMOTE=\$(git rev-parse origin/"\$BRANCH")
if [ "\$LOCAL" = "\$REMOTE" ]; then
    echo "\$LOG_PREFIX no-update skip" >> /var/log/cn-autopull.log
    exit 0
fi

echo "\$LOG_PREFIX pulling \$LOCAL -> \$REMOTE" >> /var/log/cn-autopull.log
git reset --hard origin/"\$BRANCH" --quiet

if ! git diff --quiet "\$LOCAL" "\$REMOTE" -- package.json package-lock.json 2>/dev/null; then
    echo "\$LOG_PREFIX npm install" >> /var/log/cn-autopull.log
    npm install --silent
fi

if "\$PM2_CMD" pid navigator >/dev/null 2>&1; then
    "\$PM2_CMD" reload navigator --silent || "\$PM2_CMD" restart navigator --silent
else
    "\$PM2_CMD" start server/index.js --name navigator --silent
    "\$PM2_CMD" save --silent
fi

echo "\$LOG_PREFIX done" >> /var/log/cn-autopull.log
AUTOPULL_EOF
chmod +x /root/guwenai/deploy/auto-pull.sh
echo -e "  ${GREEN}✅ auto-pull.sh 已覆盖（自带 PATH 注入 + 绝对 pm2 路径）${NC}"

echo "[2/6] git pull 拉最新代码"
git pull --quiet 2>&1 | tail -3
echo "  HEAD = $(git rev-parse --short HEAD)"

echo "[3/6] 确保 cron + pm2-root 开机自启"
systemctl enable --now cron >/dev/null 2>&1
systemctl enable --now pm2-root >/dev/null 2>&1
echo "  cron     : $(systemctl is-active cron) / $(systemctl is-enabled cron)"
echo "  pm2-root : $(systemctl is-active pm2-root) / $(systemctl is-enabled pm2-root)"

echo "[4/6] 确保 crontab 里有 auto-pull.sh 任务"
if ! crontab -l 2>/dev/null | grep -q "/root/guwenai/deploy/auto-pull.sh"; then
  (crontab -l 2>/dev/null; echo "* * * * * /root/guwenai/deploy/auto-pull.sh >> /var/log/cn-autopull.log 2>&1") | crontab -
  echo -e "  ${YEL}→ 已追加${NC}"
else
  echo -e "  ${GREEN}✅ 已存在${NC}"
fi

echo "[5/6] 确保 navigator 在 pm2 里跑"
if ! "$PM2" list 2>/dev/null | grep -q "navigator.*online"; then
  "$PM2" delete all 2>/dev/null || true
  "$PM2" start server/index.js --name navigator
  "$PM2" save --quiet
  echo -e "  ${YEL}→ 已启动 navigator${NC}"
else
  echo -e "  ${GREEN}✅ navigator 已 online${NC}"
fi

echo "[6/6] 模拟重启 + 立即跑一次 auto-pull"
echo -n "  重启 pm2-root 后 navigator: "
systemctl restart pm2-root
sleep 2
"$PM2" list 2>/dev/null | grep -q "navigator.*online" \
  && echo -e "${GREEN}✅ 自动恢复${NC}" \
  || echo -e "${RED}❌ 没起来！贴 pm2 list 给我${NC}"

echo -n "  重启 cron 后 auto-pull 任务: "
systemctl restart cron
sleep 1
crontab -l 2>/dev/null | grep -q "auto-pull.sh" \
  && echo -e "${GREEN}✅ 任务还在${NC}" \
  || echo -e "${RED}❌ 任务丢了${NC}"

echo ""
echo "  立即跑一次新版 auto-pull.sh："
/root/guwenai/deploy/auto-pull.sh
echo "  最近 3 条 auto-pull 日志（应该全是 no-update skip 或 done）:"
tail -3 /var/log/cn-autopull.log | sed 's/^/    /'

echo ""
echo "=========================================="
echo " 最终状态"
echo "=========================================="
echo "pm2 navigator: $($PM2 list 2>/dev/null | grep navigator || echo 无)"
echo "npm 全局 prefix: $NPM_PREFIX"
echo "pm2 绝对路径:   $PM2"
echo "Service 状态:"
echo "  pm2-root : $(systemctl is-active pm2-root) (enable: $(systemctl is-enabled pm2-root))"
echo "  cron     : $(systemctl is-active cron) (enable: $(systemctl is-enabled cron))"
echo "  nginx    : $(systemctl is-active nginx) (enable: $(systemctl is-enabled nginx))"
