#!/usr/bin/env bash
# 用途：fix-nginx.sh 的 v2 版。
#       你跑完 certbot --force-renewal 后，certbot 又重新生成了 -le-ssl.conf，
#       和我装的 443 SSL 段再次冲突 → /api/ 反代没生效 → 发送按钮没反应。
#       本脚本：① 删 -le-ssl.conf ② 装回 WB 权威配置 ③ reload
#              ④ 装 certbot 续期钩子（让以后自动续期不再冲突）

set -e

APP_DIR="${APP_DIR:-/root/guwenai}"
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="/etc/nginx/backup-fix2-$TS"

echo "=========================================="
echo " [1/6] 拉取最新代码"
echo "=========================================="
cd "$APP_DIR"
git pull origin main --quiet
echo "已拉平到 $(git rev-parse --short HEAD)"

echo ""
echo "=========================================="
echo " [2/6] 备份 + 删 certbot 自动生成的 -le-ssl.conf"
echo "=========================================="
sudo mkdir -p "$BACKUP"
sudo cp -a /etc/nginx/sites-enabled/. "$BACKUP/sites-enabled/"
sudo cp -a /etc/nginx/sites-available/. "$BACKUP/sites-available/"
echo "备份：$BACKUP"

REMOVED=0
for d in /etc/nginx/sites-enabled /etc/nginx/sites-available; do
  for f in "$d"/*; do
    fname=$(basename "$f")
    if [[ "$fname" == *le-ssl* ]]; then
      echo "  删 $d/$fname"
      sudo rm -f "$f"
      REMOVED=$((REMOVED+1))
    fi
  done
done
[ "$REMOVED" -eq 0 ] && echo "  （无 -le-ssl.conf 文件需删）"

echo ""
echo "=========================================="
echo " [3/6] 装回 WB 权威配置"
echo "=========================================="
sudo cp "$APP_DIR/deploy/nginx-guwenai.conf" /etc/nginx/sites-available/guwenai.cn
sudo ln -sf /etc/nginx/sites-available/guwenai.cn /etc/nginx/sites-enabled/guwenai.cn
echo "已装：sites-enabled/guwenai.cn -> $APP_DIR/deploy/nginx-guwenai.conf"

echo ""
echo "=========================================="
echo " [4/6] nginx -t + reload"
echo "=========================================="
sudo nginx -t
sudo systemctl reload nginx

echo ""
echo "=========================================="
echo " [5/6] 装 certbot 续期钩子（防止以后再冲突）"
echo "=========================================="
HOOK="/etc/letsencrypt/renewal-hooks/deploy/guwenai-nginx-cleanup.sh"
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo tee "$HOOK" > /dev/null <<'EOF'
#!/usr/bin/env bash
# certbot 自动续期后跑：删 -le-ssl.conf + 装回 WB 权威配置
set -e
APP_DIR="${APP_DIR:-/root/guwenai}"
for f in /etc/nginx/sites-enabled/*le-ssl* /etc/nginx/sites-available/*le-ssl*; do
  [ -e "$f" ] && sudo rm -f "$f"
done
sudo cp "$APP_DIR/deploy/nginx-guwenai.conf" /etc/nginx/sites-available/guwenai.cn
sudo ln -sf /etc/nginx/sites-available/guwenai.cn /etc/nginx/sites-enabled/guwenai.cn
sudo nginx -t && sudo systemctl reload nginx
echo "[certbot-hook] guwenai.cn 续期后清理完成"
EOF
sudo chmod +x "$HOOK"
echo "钩子：$HOOK"

echo ""
echo "=========================================="
echo " [6/6] 最终状态"
echo "=========================================="
echo "sites-enabled 下含 guwenai.cn 的文件（应只有 1 个）："
FOUND=0
for f in /etc/nginx/sites-enabled/*; do
  if sudo grep -q "guwenai.cn" "$f" 2>/dev/null; then
    echo "  - $(basename $f)"
    FOUND=$((FOUND+1))
  fi
done
[ "$FOUND" -gt 1 ] && echo "  ⚠️ 仍有冲突，重跑本脚本" || echo "  ✅ 唯一"

echo ""
echo "=========================================="
echo " 修复完成"
echo "=========================================="
echo "打开 https://guwenai.cn 验证："
echo "  1. 安全锁"
echo "  2. Hero 文案"今天有什么想了解的呢？""
echo "  3. 输入框 + 点发送 / 按回车 有反应"
echo ""
echo "以后 certbot 自动续期（每 60 天）不会再冲突：续期钩子已装。"
