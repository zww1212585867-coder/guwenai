#!/usr/bin/env bash
# 用途：fix-cert-v3.sh 已确认证书是对的（guwenai.cn + www.guwenai.cn，89天），
#       但 xray(Reality) 占着 443 端口 → nginx 启不来 + 浏览器看到 xray 的伪装证书。
#       用户已确认"以网站为主、翻墙不用"。
#       本脚本：① 停 xray(让出443) ② 装回 nginx 权威配置 ③ 启 nginx ④ 修 pm2+node ⑤ 全链路验证

set -e
APP_DIR="${APP_DIR:-/root/guwenai}"
cd "$APP_DIR"

echo "=========================================="
echo " [0/6] 拉最新代码"
echo "=========================================="
git pull origin main --quiet
echo "已拉平到 $(git rev-parse --short HEAD)"

echo ""
echo "=========================================="
echo " [1/6] 停 xray（让出 443 端口，用户已同意以网站为主）"
echo "=========================================="
# systemd 管理的
sudo systemctl stop xray 2>/dev/null && echo "✅ systemctl 停了 xray" || echo "  (xray 非 systemd 管理，试手动)"
sudo systemctl disable xray 2>/dev/null || true
# 手动启动的也杀掉
if pgrep -f 'xray' >/dev/null 2>&1; then
  sudo pkill -f 'xray' && echo "✅ 已杀掉手动启动的 xray 进程" || true
  sleep 2
else
  echo "  无 xray 进程在跑"
fi

echo ""
echo "=========================================="
echo " [2/6] 装回 nginx 权威配置（清掉任何 -le-ssl.conf 冲突）"
echo "=========================================="
sudo rm -f /etc/nginx/sites-enabled/*le-ssl* /etc/nginx/sites-available/*le-ssl* 2>/dev/null || true
sudo cp "$APP_DIR/deploy/nginx-guwenai.conf" /etc/nginx/sites-available/guwenai.cn
sudo ln -sf /etc/nginx/sites-available/guwenai.cn /etc/nginx/sites-enabled/guwenai.cn
sudo nginx -t && echo "✅ nginx -t 通过"

echo ""
echo "=========================================="
echo " [3/6] 启 nginx"
echo "=========================================="
sudo systemctl enable nginx
sudo systemctl restart nginx
sleep 2
echo "✅ nginx 已启"

echo ""
echo "--- 443 端口检查 ---"
sudo ss -tlnp 2>/dev/null | grep -E ':443' | head -3 && echo "✅ 443 在听 (nginx)" || echo "❌ 443 还是没起来"

echo ""
echo "=========================================="
echo " [4/6] 修 pm2 + node（之前 pm2 没装 → 发送按钮没反应）"
echo "=========================================="
if ! command -v pm2 >/dev/null 2>&1; then
  export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  npm install -g pm2
  echo "✅ pm2 装好: $(pm2 -v)"
else
  echo "pm2 已装: $(pm2 -v)"
fi
if pm2 pid navigator >/dev/null 2>&1; then
  pm2 reload navigator --silent && echo "✅ 已重载 navigator"
else
  pm2 start server/index.js --name navigator --silent
  pm2 save --silent && echo "✅ 已启动 navigator"
fi
sleep 2

echo ""
echo "--- node 健康检查 ---"
HTTP_CODE=$(curl -s -o /tmp/wb-api -w "%{http_code}" http://127.0.0.1:3000/api/domains || echo "000")
echo "  /api/domains 直连 → HTTP $HTTP_CODE"
if [ "$HTTP_CODE" = "200" ]; then
  echo "  响应前 200 字: $(head -c 200 /tmp/wb-api)"
  echo "  ✅ node 正常"
else
  echo "  ❌ node 没起，看: pm2 logs navigator --lines 30"
fi

echo ""
echo "=========================================="
echo " [5/6] 全链路验证（绕开外网，直连本机）"
echo "=========================================="
echo "--- 1) HTTPS 证书主体（关键：应显示 guwenai.cn）---"
curl -sk -o /dev/null -w "    HTTPS: %{http_code} | 证书: %{ssl_cert_subject}\n" https://127.0.0.1/
echo ""
echo "--- 2) Hero 文案 ---"
curl -s https://127.0.0.1/ | grep -oE "今天有什么想了解的呢" | head -1 && echo "    ✅ Hero 在" || echo "    ⚠️ Hero 不在"
echo ""
echo "--- 3) /api 走 nginx 代理（发送按钮靠这个）---"
curl -s https://127.0.0.1/api/domains | head -c 200
echo ""

echo ""
echo "=========================================="
echo " [6/6] 最终状态"
echo "=========================================="
echo "--- 进程 ---"
pm2 status 2>&1 | head -6
echo "--- nginx 端口 ---"
sudo ss -tlnp 2>/dev/null | grep -E ':(80|443)\s' | head -5
echo ""
echo "=========================================="
echo " 全部完成 ✅"
echo "=========================================="
echo "现在打开 https://guwenai.cn 验证："
echo "  1. 🔒 安全锁（证书主体 = guwenai.cn）"
echo "  2. Hero 文案 '今天有什么想了解的呢？'"
echo "  3. 输入框 + 发送/回车 有反应"
echo "  4. xray 已停（如需翻墙，之后重装到其它端口）"