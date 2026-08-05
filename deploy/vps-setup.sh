#!/usr/bin/env bash
# ============================================================================
# guwenai / cognitive-navigator —— VPS 一键自检 + 安装脚本
# 用途：在你(VPS)的 FinalShell 里贴一次本脚本，自动完成剩下那一半同步链路：
#        检测现状 → 装缺的 → 配 nginx(反代+HTTPS跳转) → 装 cron 自动拉取 → 启 pm2
# 注意：本脚本只读/改 VPS 本地，不涉及任何密钥；.env 需你手动填 Key。
#       公开仓库 git pull 不需要令牌。
# ============================================================================
set -uo pipefail

BRANCH="main"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
CONF_NAME="guwenai.cn"
APP_DIR=""

# ---------- 0. 找项目目录 ----------
detect_app_dir() {
  # 常见位置
  for d in /opt/cognitive-navigator /opt/guwenai /root/cognitive-navigator /root/guwenai ~/cognitive-navigator ~/guwenai; do
    if [ -f "$d/server/index.js" ]; then APP_DIR="$d"; return 0; fi
  done
  # 全盘搜（限制深度，避免太慢）
  local found
  found=$(find /opt /root /home -maxdepth 4 -name index.js -path '*/server/*' 2>/dev/null | head -1)
  if [ -n "$found" ]; then APP_DIR="$(dirname "$(dirname "$found")")"; return 0; fi
  return 1
}

echo "================================================================"
echo " [1/6] 当前环境检测"
echo "================================================================"
echo "OS:            $(cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME' | cut -d= -f2 || uname -a)"
echo "node:          $(command -v node >/dev/null && node -v || echo '未安装')"
echo "npm:           $(command -v npm >/dev/null && npm -v || echo '未安装')"
echo "nginx:         $(command -v nginx >/dev/null && nginx -v 2>&1 || echo '未安装')"
echo "certbot:       $(command -v certbot >/dev/null && certbot --version 2>&1 || echo '未安装')"
echo "pm2:           $(command -v pm2 >/dev/null && pm2 -v || echo '未安装')"
echo "cron(auto-pull): $(crontab -l 2>/dev/null | grep -c 'auto-pull' || echo 0) 条"
if detect_app_dir; then
  echo "项目目录:      $APP_DIR"
  echo "  node_modules: $([ -d "$APP_DIR/node_modules" ] && echo 有 || echo 缺失)"
  echo "  .env:         $([ -f "$APP_DIR/.env" ] && echo 存在 || echo 缺失-需手动填Key)"
  echo "  data/app.db:  $([ -f "$APP_DIR/data/app.db" ] && echo 存在 || echo 缺失-需npm run seed)"
  echo "  远程:         $(cd "$APP_DIR" && git remote get-url origin 2>/dev/null)"
  echo "  本地HEAD:     $(cd "$APP_DIR" && git rev-parse --short HEAD 2>/dev/null)"
  echo "  远程HEAD:     $(cd "$APP_DIR" && git rev-parse --short origin/$BRANCH 2>/dev/null)"
else
  echo "项目目录:      未找到（将在步骤2克隆）"
fi
echo "nginx已启用站点:"
ls -1 "$NGINX_ENABLED" 2>/dev/null || echo "  (无或目录不存在)"

# ---------- 2. 确保代码最新 ----------
echo ""
echo "================================================================"
echo " [2/6] 拉取最新代码"
echo "================================================================"
if [ -z "$APP_DIR" ]; then
  echo "未找到项目，克隆到 /opt/cognitive-navigator ..."
  APP_DIR="/opt/cognitive-navigator"
  git clone "https://github.com/zww1212585867-coder/guwenai.git" "$APP_DIR" || {
    echo "克隆失败：检查 git 是否安装 / 网络是否通。手动跑：git clone https://github.com/zww1212585867-coder/guwenai.git /opt/cognitive-navigator"
    exit 1
  }
fi
cd "$APP_DIR"
git fetch --quiet origin
git reset --hard "origin/$BRANCH" --quiet
echo "已拉平到 $(git rev-parse --short HEAD)"

# ---------- 3. 依赖 + 建库 ----------
echo ""
echo "================================================================"
echo " [3/6] 安装依赖 + 初始化数据库"
echo "================================================================"
if ! command -v node >/dev/null; then
  echo "node 未安装，开始装 nvm + Node 20 ..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm install 20
  nvm use 20
  # 让非交互 shell 也能用 node
  NODE_BIN="$HOME/.nvm/versions/node/$(ls "$HOME/.nvm/versions/node" | head -1)/bin"
  echo "export PATH=$NODE_BIN:\$PATH" >> ~/.bashrc
  export PATH="$NODE_BIN:$PATH"
fi
npm install --silent
echo "npm install 完成"
if [ ! -f "data/app.db" ]; then
  echo "初始化数据库(14表+领域字典)..."
  npm run seed
fi
# .env 缺失则提示
if [ ! -f ".env" ]; then
  echo "⚠️ .env 不存在，从样例创建。请手动编辑填入真实 Key："
  cp .env.example .env
  echo "   运行: nano $APP_DIR/.env  然后写入 GEMINI_API_KEY=... 和 DEEPSEEK_API_KEY=..."
fi

# ---------- 4. nginx 反代 + HTTPS 跳转 ----------
echo ""
echo "================================================================"
echo " [4/6] 配置 nginx（反代 /api + HTTP→HTTPS 跳转）"
echo "================================================================"
if command -v nginx >/dev/null; then
  # 备份现有
  mkdir -p /etc/nginx/backup
  cp -r "$NGINX_ENABLED" /etc/nginx/backup/enabled-$(date +%s) 2>/dev/null
  # 禁用可能冲突的旧 guwenai / default 站点
  rm -f "$NGINX_ENABLED/default" "$NGINX_ENABLED/guwenai.cn" 2>/dev/null
  # 放我们的配置
  cp "$APP_DIR/deploy/nginx-guwenai.conf" "$NGINX_AVAILABLE/$CONF_NAME"
  ln -sf "$NGINX_AVAILABLE/$CONF_NAME" "$NGINX_ENABLED/$CONF_NAME"
  if nginx -t 2>&1; then
    systemctl reload nginx && echo "✅ nginx 配置生效"
  else
    echo "❌ nginx -t 失败，已回滚到备份。请贴此段输出给我排查"
    ls -1 /etc/nginx/backup/
    exit 1
  fi
else
  echo "nginx 未安装，安装中..."
  apt-get update -y && apt-get install -y nginx
  cp "$APP_DIR/deploy/nginx-guwenai.conf" "$NGINX_AVAILABLE/$CONF_NAME"
  ln -sf "$NGINX_AVAILABLE/$CONF_NAME" "$NGINX_ENABLED/$CONF_NAME"
  rm -f "$NGINX_ENABLED/default"
  nginx -t && systemctl enable nginx && systemctl reload nginx && echo "✅ nginx 安装并生效"
fi

# ---------- 5. 装 cron 自动拉取（剩下那一半） ----------
echo ""
echo "================================================================"
echo " [5/6] 安装 cron 自动拉取（每60秒同步 GitHub→VPS）"
echo "================================================================"
chmod +x "$APP_DIR/deploy/auto-pull.sh"
if ! command -v cron >/dev/null && ! command -v crond >/dev/null; then
  apt-get install -y cron && systemctl enable cron && systemctl start cron
fi
# 写入 crontab（去重）
( crontab -l 2>/dev/null | grep -v 'auto-pull.sh'; echo "* * * * * $APP_DIR/deploy/auto-pull.sh >> /var/log/cn-autopull.log 2>&1" ) | crontab -
echo "✅ cron 已写入：$(crontab -l | grep -c auto-pull) 条"

# ---------- 6. 启动服务 (pm2) ----------
echo ""
echo "================================================================"
echo " [6/6] 启动 Node 服务 (pm2)"
echo "================================================================"
if ! command -v pm2 >/dev/null; then
  npm install -g pm2
fi
# 确保 node 在 pm2 路径
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
if pm2 pid navigator >/dev/null 2>&1; then
  pm2 reload navigator --silent && echo "✅ pm2 已重载"
else
  pm2 start server/index.js --name navigator --silent && pm2 save --silent && echo "✅ pm2 已启动"
fi

# ---------- 最终报告 ----------
echo ""
echo "================================================================"
echo " 完成 ✅ 最终状态"
echo "================================================================"
echo "项目目录:   $APP_DIR"
echo "本地HEAD:    $(cd "$APP_DIR" && git rev-parse --short HEAD)"
echo "node:        $(node -v)"
echo "nginx -t:    $(nginx -t 2>&1 | tail -1)"
echo "pm2:         $(pm2 pid navigator 2>/dev/null && echo 'navigator 运行中' || echo '未运行')"
echo "cron:        $(crontab -l | grep -c auto-pull) 条"
echo "防火墙建议: sudo ufw allow 22,80,443/tcp"
echo ""
echo "请打开 https://guwenai.cn 验证：🔒安全锁 + 能输入对话 + 发送有反应"
echo "若有问题，把本段输出贴给 WB 即可。"
