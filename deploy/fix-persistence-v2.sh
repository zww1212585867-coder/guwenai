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

echo "[1/7] 修老 auto-pull.sh 里的错误路径（如有）"
if [ -f /root/guwenai/deploy/auto-pull.sh ]; then
  if grep -q "/opt/cognitive-navigator" /root/guwenai/deploy/auto-pull.sh; then
    sed -i 's|/opt/cognitive-navigator|/root/guwenai|g' /root/guwenai/deploy/auto-pull.sh
    echo -e "  ${YEL}→ 已修：/opt/cognitive-navigator → /root/guwenai${NC}"
  else
    echo -e "  ${GREEN}✅ 路径已正确${NC}"
  fi
else
  echo -e "  ${RED}❌ auto-pull.sh 不存在！${NC}"
fi

# 也修一份在 /opt/cognitive-navigator 的（以防有遗留）
if [ -f /opt/cognitive-navigator/deploy/auto-pull.sh ]; then
  sed -i 's|/opt/cognitive-navigator|/root/guwenai|g' /opt/cognitive-navigator/deploy/auto-pull.sh
  echo -e "  ${YEL}→ /opt/cognitive-navigator 的副本也修了${NC}"
fi

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
