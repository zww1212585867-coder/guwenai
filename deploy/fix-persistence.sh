#!/usr/bin/env bash
# fix-persistence.sh — 确保 VPS 永不掉线
#   (1) pm2 开机自启 (systemd pm2-root.service)
#   (2) cron 开机自启 + crontab 里 auto-pull.sh
#   (3) 模拟重启：systemctl restart pm2-root + cron，看 navigator 和 auto-pull 是否自动恢复
#   (4) 全状态报告

set -u
cd /root/guwenai 2>/dev/null || { echo "❌ /root/guwenai 不存在"; exit 1; }

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[1;33m'; NC='\033[0m'

echo "[1/5] 检查/补强 pm2 开机自启"
if ! systemctl is-enabled pm2-root >/dev/null 2>&1; then
  sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u root --hp /root >/dev/null 2>&1
  sudo systemctl enable pm2-root >/dev/null 2>&1
  echo -e "  ${YEL}→ 已 enable pm2-root${NC}"
else
  echo -e "  ${GREEN}✅ pm2-root 已 enabled${NC}"
fi

echo "[2/5] 检查/补强 cron 开机自启"
if ! systemctl is-enabled cron >/dev/null 2>&1; then
  sudo systemctl enable --now cron >/dev/null 2>&1
  echo -e "  ${YEL}→ 已 enable cron${NC}"
else
  echo -e "  ${GREEN}✅ cron 已 enabled${NC}"
fi

echo "[3/5] 检查/补强 auto-pull.sh 在 crontab 里"
if ! crontab -l 2>/dev/null | grep -q "auto-pull.sh"; then
  (crontab -l 2>/dev/null; echo "* * * * * /root/guwenai/deploy/auto-pull.sh >> /var/log/guwenai-auto-pull.log 2>&1") | crontab -
  echo -e "  ${YEL}→ 已追加 auto-pull.sh 到 crontab${NC}"
else
  echo -e "  ${GREEN}✅ auto-pull.sh 已在 crontab${NC}"
fi

echo "[4/5] 立即跑一次 auto-pull.sh 验证链路通"
chmod +x /root/guwenai/deploy/auto-pull.sh 2>/dev/null
/root/guwenai/deploy/auto-pull.sh 2>&1 | tail -5 || true
HEAD_AFTER=$(git rev-parse --short HEAD 2>/dev/null)
echo "  当前 HEAD = ${HEAD_AFTER}"

echo "[5/5] 模拟重启（不真重启 VPS）"
echo -n "  重启 pm2-root 后 navigator 状态: "
sudo systemctl restart pm2-root
sleep 2
pm2 list 2>/dev/null | grep -q "navigator.*online" \
  && echo -e "${GREEN}✅ navigator 自动恢复了${NC}" \
  || echo -e "${RED}❌ navigator 没起来！贴 pm2 list 给我${NC}"

echo -n "  重启 cron 后 auto-pull 任务是否还在: "
sudo systemctl restart cron
sleep 1
crontab -l 2>/dev/null | grep -q "auto-pull.sh" \
  && echo -e "${GREEN}✅ auto-pull 任务还在${NC}" \
  || echo -e "${RED}❌ crontab 任务丢了！${NC}"

echo ""
echo "=========================================="
echo " 最终状态"
echo "=========================================="
echo "HTTPS 证书:"
sudo certbot certificates 2>/dev/null | grep -E "Domains|Expiry" | head -4
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
crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' || echo "  (空)"
