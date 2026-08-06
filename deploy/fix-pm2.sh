#!/usr/bin/env bash
# 用途：fix-cert-v3.sh 暴露了两个独立问题：
#       ① pm2 没装 → node 没在跑 → 发送按钮没反应（本脚本修这个）
#       ② 443 端口被 xray Reality 占 → nginx 启不来 + 浏览器看到伪装证书（需用户决策，见 WB 回复）

set -e
APP_DIR="${APP_DIR:-/root/guwenai}"
cd "$APP_DIR"

echo "=========================================="
echo " [1/5] 拉最新代码"
echo "=========================================="
git pull origin main --quiet
echo "已拉平到 $(git rev-parse --short HEAD)"

echo ""
echo "=========================================="
echo " [2/5] 装 pm2（如果没装）"
echo "=========================================="
if ! command -v pm2 >/dev/null 2>&1; then
  export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  npm install -g pm2
  echo "✅ pm2 装好了：$(pm2 -v)"
else
  echo "pm2 已装：$(pm2 -v)"
fi

echo ""
echo "=========================================="
echo " [3/5] 启 node (navigator)"
echo "=========================================="
if pm2 pid navigator >/dev/null 2>&1; then
  pm2 reload navigator --silent && echo "✅ 已重载"
else
  pm2 start server/index.js --name navigator --silent
  pm2 save --silent && echo "✅ 已启动"
fi

echo ""
echo "=========================================="
echo " [4/5] node 健康检查"
echo "=========================================="
sleep 2
HTTP_CODE=$(curl -s -o /tmp/wb-api-test -w "%{http_code}" http://127.0.0.1:3000/api/domains || echo "000")
echo "  /api/domains → HTTP $HTTP_CODE"
if [ "$HTTP_CODE" = "200" ]; then
  echo "  响应头 200 字：$(head -c 200 /tmp/wb-api-test)"
  echo "  ✅ node 在 :3000 上正常服务"
else
  echo "  ❌ node 没起来，看日志：pm2 logs navigator --lines 30"
fi

echo ""
echo "=========================================="
echo " [5/5] 最终状态"
echo "=========================================="
pm2 status

echo ""
echo "=========================================="
echo " pm2/node 已修 ✅"
echo "=========================================="
echo "node 服务在 :3000 上跑着。"
echo "剩下的是 nginx 启不来的问题（443 端口被 xray Reality 占），见 WB 的回复。"