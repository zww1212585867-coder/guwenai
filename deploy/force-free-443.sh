#!/usr/bin/env bash
# 用途：根治"443 端口被 xray/3x-ui 守死"。
#       现象：pgrep -f xray 杀掉后，几秒内 3x-ui/x-ui 面板又把 xray 拉起来。
#       用户已确认翻墙不要，3x-ui 面板可以一起丢（反正用不到了）。
#       本脚本：① 禁用+停 所有 xray/x-ui/3x-ui 相关 systemd 服务
#              ② 杀所有相关进程（含 3x-ui 守护）
#              ③ 等几秒查残留
#              ④ 启 nginx（如果仍失败打印 journal 看真正原因）
#              ⑤ 修 pm2/node + 全链路验证

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
echo " [1/6] 停 + 禁用 xray/x-ui/3x-ui 所有 systemd 服务（防止守护重启）"
echo "=========================================="
# 列出相关服务
echo "--- 相关 systemd 服务（启动的）---"
sudo systemctl list-units --type=service --state=running 2>/dev/null \
  | grep -iE 'xray|x-ui|3x' || echo "  （没在跑）"
echo ""
echo "--- 相关 systemd 服务（已装的）---"
sudo systemctl list-unit-files --type=service 2>/dev/null \
  | grep -iE 'xray|x-ui|3x' || echo "  （未装任何）"
echo ""

# 禁 + 停 + mask（mask 后连手动 start 都启不来，最稳）
SERVICES_FOUND=0
for svc in xray x-ui xui 3xui xray.service x-ui.service xui.service 3xui.service; do
  if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${svc}"; then
    SERVICES_FOUND=$((SERVICES_FOUND+1))
    sudo systemctl stop "$svc" 2>/dev/null && echo "  stop $svc" || true
    sudo systemctl disable "$svc" 2>/dev/null && echo "  disable $svc" || true
    sudo systemctl mask "$svc" 2>/dev/null && echo "  mask $svc" || true
  fi
done
[ "$SERVICES_FOUND" -eq 0 ] && echo "  (无 xray/x-ui systemd 服务)"

echo ""
echo "=========================================="
echo " [2/6] 杀所有相关进程（含 3x-ui 守护）"
echo "=========================================="
for pat in 'xray' 'x-ui' '3x-ui' 'xui' '3xui' 'xray-linux'; do
  for _ in 1 2 3; do
    if pgrep -f "$pat" >/dev/null 2>&1; then
      sudo pkill -9 -f "$pat" 2>/dev/null || true
      sleep 1
    else
      break
    fi
  done
  if pgrep -f "$pat" >/dev/null 2>&1; then
    echo "  ⚠️  $pat 仍残留:"
    pgrep -af "$pat" | head -3
  else
    echo "  ✅ $pat 杀干净"
  fi
done

echo ""
echo "--- 残留检查（所有 xray/x-ui 关键字）---"
if pgrep -af 'xray\|x-ui\|3x' >/dev/null 2>&1; then
  echo "  ⚠️  仍有进程残留:"
  pgrep -af 'xray\|x-ui\|3x' | head -5
else
  echo "  ✅ 一个不剩"
fi

echo ""
echo "=========================================="
echo " [3/6] 看 80/443 端口"
echo "=========================================="
sudo ss -tlnp 2>/dev/null | grep -E ':(80|443)\s' | head -5 || echo "（80/443 都空 ✅）"

echo ""
echo "=========================================="
echo " [4/6] 装回 nginx 权威配置 + 启 nginx"
echo "=========================================="
sudo rm -f /etc/nginx/sites-enabled/*le-ssl* /etc/nginx/sites-available/*le-ssl* 2>/dev/null || true
sudo cp "$APP_DIR/deploy/nginx-guwenai.conf" /etc/nginx/sites-available/guwenai.cn
sudo ln -sf /etc/nginx/sites-available/guwenai.cn /etc/nginx/sites-enabled/guwenai.cn
sudo nginx -t && echo "✅ nginx -t 通过"

# 启（用 restart 而非 start，更可靠）
sudo systemctl restart nginx
sleep 2

# 验证 443
if sudo ss -tlnp 2>/dev/null | grep -q ':443'; then
  echo "✅ 443 端口已在听"
  sudo ss -tlnp 2>/dev/null | grep ':443' | head -2
else
  echo "❌ 443 还是没起，看真正原因："
  echo ""
  echo "--- systemctl status ---"
  sudo systemctl status nginx.service --no-pager -l 2>&1 | head -25
  echo ""
  echo "--- journalctl ---"
  sudo journalctl -xeu nginx.service --no-pager -n 30 2>&1 | tail -40
  exit 1
fi

echo ""
echo "=========================================="
echo " [5/6] 修 pm2/node"
echo "=========================================="
if ! command -v pm2 >/dev/null 2>&1; then
  export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  npm install -g pm2 && echo "✅ pm2 装好: $(pm2 -v)"
else
  echo "pm2 已装: $(pm2 -v)"
fi
if pm2 pid navigator >/dev/null 2>&1; then
  pm2 reload navigator --silent && echo "✅ 已重载"
else
  pm2 start server/index.js --name navigator --silent
  pm2 save --silent && echo "✅ 已启动"
fi
sleep 2
echo "--- node 健康 ---"
HTTP_CODE=$(curl -s -o /tmp/wb-api -w "%{http_code}" http://127.0.0.1:3000/api/domains || echo "000")
echo "  /api/domains 直连 → HTTP $HTTP_CODE"
[ "$HTTP_CODE" = "200" ] && echo "  响应前 200 字: $(head -c 200 /tmp/wb-api)"

echo ""
echo "=========================================="
echo " [6/6] 全链路验证"
echo "=========================================="
echo "--- 1) HTTPS 证书主体 ---"
curl -sk -o /dev/null -w "    HTTPS: %{http_code} | 证书: %{ssl_cert_subject}\n" https://127.0.0.1/
echo ""
echo "--- 2) Hero 文案 ---"
curl -s https://127.0.0.1/ | grep -oE "今天有什么想了解的呢" | head -1 && echo "    ✅ Hero 在" || echo "    ⚠️ Hero 不在"
echo ""
echo "--- 3) /api 走 nginx 代理 ---"
curl -s https://127.0.0.1/api/domains | head -c 200
echo ""
echo ""
echo "=========================================="
echo " 全部完成 ✅"
echo "=========================================="
echo "打开 https://guwenai.cn 验证：🔒 + Hero + 发送有反应"
echo "xray/3x-ui 已 mask + 全进程杀干净（防守护重启），如要重装需先 unmask。"