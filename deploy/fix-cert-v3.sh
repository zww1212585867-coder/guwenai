#!/usr/bin/env bash
# 用途：fix-nginx-v2.sh 修好了 nginx 冲突（sites-enabled 唯一），但浏览器还报
#       NET::ERR_CERT_COMMON_NAME_INVALID。根因是：证书本身就不对（要么没装、
#       要么是 snakeoil 默认证书、要么是别的域名的）。
#       本脚本：① 看现状 ② 停 nginx 释放 80 端口 ③ standalone 强制重签证书
#              ④ 启 nginx + 重启 node ⑤ 全链路验证

set -e

APP_DIR="${APP_DIR:-/root/guwenai}"
DOMAIN="guwenai.cn"
WWW="www.guwenai.cn"

cd "$APP_DIR"

echo "=========================================="
echo " [1/7] 拉取最新代码"
echo "=========================================="
git pull origin main --quiet
echo "已拉平到 $(git rev-parse --short HEAD)"

echo ""
echo "=========================================="
echo " [2/7] 看现状（证书 / 80 端口 / node）"
echo "=========================================="
echo "--- certbot certificates ---"
sudo certbot certificates 2>&1 | head -30 || echo "（无证书）"
echo ""
echo "--- 80/443 端口占用 ---"
sudo ss -tlnp 2>/dev/null | grep -E ':(80|443)\s' || echo "（80/443 未监听）"
echo ""
echo "--- pm2 ---"
pm2 status 2>&1 | head -10 || echo "（pm2 未装）"

echo ""
echo "=========================================="
echo " [3/7] DNS 自检（certbot 验证前提）"
echo "=========================================="
RESOLVED=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
if [ -z "$RESOLVED" ]; then
  echo "❌ $DOMAIN 没有解析记录。请先去域名服务商加 A 记录 → VPS IP"
  exit 1
fi
VPS_IP=$(curl -s ifconfig.me || curl -s icanhazip.com)
echo "  $DOMAIN 解析到: $RESOLVED"
echo "  本机外网 IP:    $VPS_IP"
if [ "$RESOLVED" != "$VPS_IP" ]; then
  echo "⚠️  解析的 IP 和本机 IP 不一致。certbot 验证会失败。"
  echo "    继续吗？按 Ctrl+C 中止，或等 5 秒自动继续..."
  sleep 5
fi

echo ""
echo "=========================================="
echo " [4/7] 停 nginx 释放 80 端口（certbot standalone 验证需要）"
echo "=========================================="
sudo systemctl stop nginx
echo "✅ nginx 已停"

echo ""
echo "=========================================="
echo " [5/7] certbot standalone 强制重签证书"
echo "=========================================="
# 删掉旧证书目录（如果有），强制完全重签
sudo rm -rf /etc/letsencrypt/live/$DOMAIN /etc/letsencrypt/archive/$DOMAIN /etc/letsencrypt/renewal/$DOMAIN.conf 2>/dev/null || true
echo "已清理旧证书（如有）"
echo ""
echo "开始 certbot 申请...（80 端口会临时被 certbot 占用）"
sudo certbot certonly --standalone \
  -d "$DOMAIN" -d "$WWW" \
  --non-interactive --agree-tos \
  -m "admin@$DOMAIN" \
  --keep-until-expiring 2>&1 | tail -25

echo ""
echo "--- 新证书信息 ---"
sudo certbot certificates 2>&1 | head -25

echo ""
echo "=========================================="
echo " [6/7] 启 nginx + 重启 node"
echo "=========================================="
sudo systemctl start nginx
sudo nginx -t
sudo systemctl reload nginx
echo "✅ nginx 已起"
echo ""
# 确保 node 在 pm2 路径
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
if pm2 pid navigator >/dev/null 2>&1; then
  pm2 reload navigator --silent && echo "✅ pm2 已重载"
else
  pm2 start server/index.js --name navigator --silent && pm2 save --silent && echo "✅ pm2 已启动"
fi

echo ""
echo "=========================================="
echo " [7/7] 全链路验证"
echo "=========================================="
echo "--- 1) 本地 HTTPS（看证书主体）---"
curl -sk -o /dev/null -w "    HTTPS: %{http_code} | 证书主体: %{ssl_cert_subject}\n" https://127.0.0.1/
echo ""
echo "--- 2) 浏览器入口（hero 文本）---"
curl -s https://127.0.0.1/ | grep -oE "今天有什么想了解的呢" | head -1 && echo "    ✅ Hero 文案在" || echo "    ⚠️ Hero 文案不在（看 app.js 是否部署）"
echo ""
echo "--- 3) /api/domains（node 是否在 3000）---"
API_RESP=$(curl -s http://127.0.0.1:3000/api/domains)
echo "    返回前 200 字: ${API_RESP:0:200}"
echo ""
echo "--- 4) /api 走 nginx 代理（核心：发送按钮靠这个）---"
PROXY_RESP=$(curl -s https://127.0.0.1/api/domains)
echo "    返回前 200 字: ${PROXY_RESP:0:200}"
echo ""
echo "=========================================="
echo " 修复完成"
echo "=========================================="
echo "打开 https://guwenai.cn 验证："
echo "  1. 🔒 安全锁（证书主体应是 guwenai.cn）"
echo "  2. Hero 文案 '今天有什么想了解的呢？'"
echo "  3. 输入框 + 点发送 / 按回车 有反应"
echo ""
echo "若 [7/7] 第 3 步返回空或非 JSON：cd /root/guwenai && pm2 logs navigator 看报错"
