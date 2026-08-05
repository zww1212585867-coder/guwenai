#!/usr/bin/env bash
# 用途：清理 /etc/nginx/sites-enabled/ 下 guwenai.cn 的冲突配置，
#       恢复 WB 单一权威配置（含 /api/ 反代 + HTTPS 跳转）。
# 解决：
#   - https://guwenai.cn 报 NET::ERR_CERT_COMMON_NAME_INVALID
#   - 主页发送按钮无反应（API 反代未生效）
#
# 用法（在 VPS FinalShell）：
#   curl -fsSL https://raw.githubusercontent.com/zww1212585867-coder/guwenai/main/deploy/fix-nginx.sh | bash
#
# 私有仓库用户：先 export GITHUB_TOKEN=<你的token> 再跑，
# 脚本会自动检测并使用。

set -e

APP_DIR="${APP_DIR:-/root/guwenai}"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="/etc/nginx/backup-fix-$TS"

echo "=========================================="
echo " [1/6] 拉取最新代码"
echo "=========================================="
cd "$APP_DIR"
if ! git pull origin main --quiet 2>&1; then
  echo "git pull 失败。若仓库私有，先 export GITHUB_TOKEN=<token> 再跑"
  exit 1
fi
echo "已拉平到 $(git rev-parse --short HEAD)"

echo ""
echo "=========================================="
echo " [2/6] 备份 + 列出冲突"
echo "=========================================="
sudo mkdir -p "$BACKUP"
sudo cp -a /etc/nginx/sites-enabled/. "$BACKUP/sites-enabled/"
sudo cp -a /etc/nginx/sites-available/. "$BACKUP/sites-available/"
echo "备份：$BACKUP"
echo ""
echo "sites-enabled 下含 guwenai.cn 的文件："
FOUND=0
for f in /etc/nginx/sites-enabled/*; do
  if sudo grep -q "guwenai.cn" "$f" 2>/dev/null; then
    echo "  - $(basename $f)"
    FOUND=$((FOUND+1))
  fi
done
[ "$FOUND" -le 1 ] && echo "  （无冲突，无需清理）"

echo ""
echo "=========================================="
echo " [3/6] 删除冲突文件（只保留 guwenai.cn）"
echo "=========================================="
REMOVED=0
for f in /etc/nginx/sites-enabled/*; do
  fname=$(basename "$f")
  if [ "$fname" != "guwenai.cn" ] && sudo grep -q "server_name" "$f" 2>/dev/null && sudo grep -q "guwenai.cn" "$f" 2>/dev/null; then
    echo "  删 $fname（冲突源）"
    sudo rm -f "$f"
    REMOVED=$((REMOVED+1))
  fi
done
[ "$REMOVED" -eq 0 ] && echo "  （无冲突文件需删）"

echo ""
echo "=========================================="
echo " [4/6] 装回 WB 权威配置"
echo "=========================================="
sudo cp "$APP_DIR/deploy/nginx-guwenai.conf" /etc/nginx/sites-available/guwenai.cn
sudo ln -sf /etc/nginx/sites-available/guwenai.cn /etc/nginx/sites-enabled/guwenai.cn
echo "已装：sites-enabled/guwenai.cn -> $APP_DIR/deploy/nginx-guwenai.conf"

echo ""
echo "=========================================="
echo " [5/6] 证书检查"
echo "=========================================="
if [ -f /etc/letsencrypt/live/guwenai.cn/fullchain.pem ]; then
  SAN=$(sudo openssl x509 -in /etc/letsencrypt/live/guwenai.cn/fullchain.pem -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1)
  echo "证书路径：/etc/letsencrypt/live/guwenai.cn/fullchain.pem"
  echo "证书 SAN: $SAN"
  if echo "$SAN" | grep -q "guwenai.cn"; then
    echo "  [OK] 证书含 guwenai.cn"
  else
    echo "  [WARN] 证书不含 guwenai.cn，需重签："
    echo "         sudo certbot --nginx -d guwenai.cn -d www.guwenai.cn --force-renewal"
  fi
else
  echo "[WARN] 证书文件不存在：/etc/letsencrypt/live/guwenai.cn/fullchain.pem"
  echo "       需重签：sudo certbot --nginx -d guwenai.cn -d www.guwenai.cn"
fi

echo ""
echo "=========================================="
echo " [6/6] nginx 测试 + reload"
echo "=========================================="
sudo nginx -t
sudo systemctl reload nginx
echo ""
echo "=========================================="
echo " 完成。请打开 https://guwenai.cn 验证"
echo "=========================================="
echo "  1. 应看到安全锁（不是"不安全"）"
echo "  2. 应看到 Hero 文案"今天有什么想了解的呢？""
echo "  3. 输入框打字 + 点发送 / 按回车 应有反应"
echo ""
echo "若仍报证书错，跑："
echo "  sudo certbot --nginx -d guwenai.cn -d www.guwenai.cn --force-renewal"
echo ""
echo "本脚本可重跑（已设计为幂等）。冲突备份在 $BACKUP"
