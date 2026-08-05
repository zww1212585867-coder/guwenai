#!/usr/bin/env bash
# fix-persistence-v2.sh — 修历史路径 bug + 确保 VPS 真正永不掉线
#   (1) 修老 auto-pull.sh 里的 /opt/cognitive-navigator 错误路径
#   (2) 拉取最新代码（含新版 auto-pull.sh）
#   (3) 确保 navigator 在 pm2 里跑
#   (4) 模拟重启 systemd pm2-root + cron
#   (5) 跑一次最新 auto-pull.sh 看是否真能同步

set -u
cd /root/guwenai 2>/dev/null || { echo "❌ /root/guwenai 不存在"; exit 1; }

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[1;33m'; NC='\033[0m'

echo "[1/7] 强制抛弃 deploy/auto-pull.sh 的本地改动（避免 git pull 冲突）+ 修老路径"
# 之前版本如果有人手改或 sed 改过，git pull 会卡住；这里强制 reset
cd /root/guwenai
git checkout -- deploy/auto-pull.sh 2>/dev/null || true
# 再保险：用脚本自定位版本覆盖
cat > /root/guwenai/deploy/auto-pull.sh <<'AUTOPULL_EOF'
#!/usr/bin/env bash
# VPS 端自动同步脚本：每 60 秒从 GitHub 拉最新代码 + pm2 重启
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
BRANCH="main"
LOG_PREFIX="[$(date '+%F %T')]"

cd "$APP_DIR"
git fetch --quiet origin
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/"$BRANCH")
if [ "$LOCAL" = "$REMOTE" ]; then
    echo "$LOG_PREFIX no-update skip" >> /var/log/cn-autopull.log
    exit 0
fi

echo "$LOG_PREFIX pulling $LOCAL -> $REMOTE" >> /var/log/cn-autopull.log
git reset --hard origin/"$BRANCH" --quiet

if ! git diff --quiet "$LOCAL" "$REMOTE" -- package.json package-lock.json 2>/dev/null; then
    echo "$LOG_PREFIX npm install" >> /var/log/cn-autopull.log
    npm install --silent
fi

if pm2 pid navigator >/dev/null 2>&1; then
    pm2 reload navigator --silent || pm2 restart navigator --silent
else
    pm2 start server/index.js --name navigator --silent
    pm2 save --silent
fi

echo "$LOG_PREFIX done" >> /var/log/cn-autopull.log
AUTOPULL_EOF
chmod +x /root/guwenai/deploy/auto-pull.sh
echo -e "  ${GREEN}✅ auto-pull.sh 已用脚本自定位版本覆盖（不会硬编码错路径）${NC}"

echo "[2/7] 拉取最新代码"
git pull --quiet 2>&1 | tail -3
HEAD=$(git rev-parse --short HEAD)
echo "  当前 HEAD = ${HEAD}"

echo "[3/7] 确保 cron 开机自启"
sudo systemctl enable --now cron >/dev/null 2>&1
systemctl is-enabled cron >/dev/null 2>&1 \
  && echo -e "  ${GREEN}✅ cron enabled${NC}" \
  || echo -e "  ${RED}❌ cron enable 失败${NC}"

echo "[4/7] 确保 crontab 里有新版 auto-pull.sh 任务"
if crontab -l 2>/dev/null | grep -q "/root/guwenai/deploy/auto-pull.sh"; then
  echo -e "  ${GREEN}✅ auto-pull.sh 已在 crontab${NC}"
else
  (crontab -l 2>/dev/null; echo "* * * * * /root/guwenai/deploy/auto-pull.sh >> /var/log/cn-autopull.log 2>&1") | crontab -
  echo -e "  ${YEL}→ 已追加${NC}"
fi

echo "[5/7] 确保 navigator 在 pm2 里跑"
if pm2 list 2>/dev/null | grep -q "navigator.*online"; then
  echo -e "  ${GREEN}✅ navigator 已 online${NC}"
else
  pm2 delete all 2>/dev/null || true
  pm2 start server/index.js --name navigator
  pm2 save --quiet
  echo -e "  ${YEL}→ 已重新启动 navigator${NC}"
fi
# 确保开机自启
if ! systemctl is-enabled pm2-root >/dev/null 2>&1; then
  sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u root --hp /root >/dev/null 2>&1
  sudo systemctl enable pm2-root >/dev/null 2>&1
fi

echo "[6/7] 模拟重启（不真重启）"
echo -n "  重启 pm2-root 后 navigator 状态: "
sudo systemctl restart pm2-root
sleep 2
pm2 list 2>/dev/null | grep -q "navigator.*online" \
  && echo -e "${GREEN}✅ 自动恢复${NC}" \
  || echo -e "${RED}❌ 没起来！贴 pm2 list 给我${NC}"

echo -n "  重启 cron 后 auto-pull 任务是否还在: "
sudo systemctl restart cron
sleep 1
crontab -l 2>/dev/null | grep -q "auto-pull.sh" \
  && echo -e "${GREEN}✅ 任务还在${NC}" \
  || echo -e "${RED}❌ 任务丢了${NC}"

echo "[7/7] 立即跑一次最新 auto-pull.sh 验证真的能同步"
echo "  before: HEAD = $(git rev-parse --short HEAD)"
/root/guwenai/deploy/auto-pull.sh
echo "  after : HEAD = $(git rev-parse --short HEAD)"
echo ""
echo "  最近 5 条 auto-pull 日志:"
tail -5 /var/log/cn-autopull.log 2>/dev/null | sed 's/^/    /'

echo ""
echo "=========================================="
echo " 最终状态"
echo "=========================================="
echo "HTTPS 证书:"
sudo certbot certificates 2>/dev/null | grep -E "Domains|Expiry" | head -4 | sed 's/^/  /'
echo ""
echo "监听端口:"
sudo ss -tlnp 2>/dev/null | grep -E ":80|:443|:3000" | awk '{print "  "$0}'
echo ""
echo "Service 状态:"
echo "  pm2-root : $(systemctl is-active pm2-root 2>/dev/null) (enable: $(systemctl is-enabled pm2-root 2>/dev/null))"
echo "  cron     : $(systemctl is-active cron 2>/dev/null) (enable: $(systemctl is-enabled cron 2>/dev/null))"
echo "  nginx    : $(systemctl is-active nginx 2>/dev/null) (enable: $(systemctl is-enabled nginx 2>/dev/null))"
echo ""
echo "pm2 navigator 进程:"
pm2 list 2>/dev/null | grep navigator || echo "  ⚠️ 无 navigator"
echo ""
echo "crontab 任务:"
crontab -l 2>/dev/null | grep auto-pull || echo "  ⚠️ 无"
echo ""
echo "auto-pull.sh 当前内容（第 17-22 行）:"
sed -n '17,25p' /root/guwenai/deploy/auto-pull.sh | sed 's/^/  /'
