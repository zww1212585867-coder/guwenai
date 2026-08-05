# 自动同步机制（WB 改 → GitHub → VPS）

目标：**WB（AI）在本地改完代码并 commit，网页就自动更新**，中间不需要你手动找文件、找仓库、覆盖。

## 链路

```
WB 本地修改
   → git commit
   → post-commit 钩子自动 git push 到 GitHub   ← 本文件说明的机制
   → VPS 上 cron 每 60 秒 git pull + pm2 reload  ← deploy/auto-pull.sh
   → 网页更新
```

你唯一可能要做的动作：**双击 `一键上传.bat`**（当 WB 没自动 commit 时兜底）。其余全自动。

## 1. 本地 → GitHub（已配置）

- `git remote origin` 的 URL 已内嵌访问令牌，推送无需手动输密码。
- `.git/hooks/post-commit` 钩子：每次 `git commit` 后自动 `git push origin main`。
- 验证：本地改一个文件 → `git commit` → 去 GitHub 网页看是否出现新 commit。

### ⚠️ 令牌安全（重要）

令牌明文只存在于本机 `.git/config`（不在仓库、不上 GitHub）。
但**令牌曾出现在聊天对话中，存在泄露风险**。建议：

1. 到 GitHub → Settings → Developer settings → Personal access tokens → 找到这个令牌 **Revoke（撤销）**。
2. 重新生成一个 **fine-grained token**，只给 `guwenai` 这一个仓库的 `Contents: Read and write` 权限。
3. 把新令牌发给我，我执行：
   ```bash
   git remote set-url origin https://<用户名>:<新令牌>@github.com/zww1212585867-coder/guwenai.git
   ```
4. 之后机制不变，但旧令牌已失效，泄露风险解除。

## 2. GitHub → VPS（已配置）

见 `deploy/auto-pull.sh`，在 VPS 上装为 cron：

```bash
# VPS 上（一次性）
sudo cp deploy/auto-pull.sh /opt/cognitive-navigator/deploy/
sudo chmod +x /opt/cognitive-navigator/deploy/auto-pull.sh
(crontab -l 2>/dev/null; echo "* * * * * /opt/cognitive-navigator/deploy/auto-pull.sh >> /var/log/cn-autopull.log 2>&1") | crontab -
```

行为：每 60 秒 `git fetch` 比对，若远程有更新则 `git reset --hard` + 按需 `npm install` + `pm2 reload`。

## 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 本地 commit 后 GitHub 没更新 | 令牌失效 / 网络断 | 双击 `一键上传.bat` 看报错；或重配令牌（见上） |
| GitHub 更新了但网页没变 | VPS cron 没装 / node 挂了 | VPS 上 `pm2 status`；`tail /var/log/cn-autopull.log` |
| 推送报 403 | 令牌无写权限或被 revoke | 重新生成令牌并重设 remote URL |
| 推送报 non-fast-forward | 远程有手动改动 | `git push -f origin main`（强制覆盖，会丢失远程手动改动） |
