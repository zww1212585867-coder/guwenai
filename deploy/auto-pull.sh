#!/usr/bin/env bash
# VPS 端自动同步脚本：每 60 秒从 GitHub 拉最新代码 + pm2 重启
# 安装：crontab -e → 追加下面这一行
#   * * * * * /root/guwenai/deploy/auto-pull.sh >> /var/log/cn-autopull.log 2>&1
#
# 行为：
#   - cd 到脚本所在目录的上一级（项目根目录，路径无关）
#   - git fetch + git reset --hard origin/main（无视冲突、自动追平）
#   - npm install 仅在 package.json 变更时跑
#   - pm2 重启 node 服务
#
# 你只需在我改完代码后，在自己电脑上跑：
#   git add -A && git commit -m "..." && git push
# 然后一分钟内 VPS 自动追上。

set -euo pipefail
# 自动定位脚本所在目录的上一级，避免硬编码错误路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
BRANCH="main"
LOG_PREFIX="[$(date '+%F %T')]"

cd "$APP_DIR"

# 1) 拉取
git fetch --quiet origin
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/"$BRANCH")
if [ "$LOCAL" = "$REMOTE" ]; then
    echo "$LOG_PREFIX no-update, skip" >> /var/log/cn-autopull.log
    exit 0
fi

echo "$LOG_PREFIX pulling $LOCAL -> $REMOTE" >> /var/log/cn-autopull.log
git reset --hard origin/"$BRANCH" --quiet

# 2) 依赖变化才装
if ! git diff --quiet "$LOCAL" "$REMOTE" -- package.json package-lock.json 2>/dev/null; then
    echo "$LOG_PREFIX npm install" >> /var/log/cn-autopull.log
    npm install --silent
fi

# 3) 重启
if pm2 pid navigator >/dev/null 2>&1; then
    pm2 reload navigator --silent || pm2 restart navigator --silent
else
    pm2 start server/index.js --name navigator --silent
    pm2 save --silent
fi

echo "$LOG_PREFIX done" >> /var/log/cn-autopull.log
