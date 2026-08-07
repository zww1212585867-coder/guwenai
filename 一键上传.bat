@echo off
echo 正在把本地最新代码推送到 GitHub...
cd /d "D:\付\交易日志\仓库\交易日志\个人知识库\WB工作\WB工作结果\自建AI系统\cognitive-navigator"

:: 收集所有改动
git add .

:: 打标签（如果没新改动，commit 会失败，属正常）
git commit -m "WB代码更新"

:: 推送到 GitHub（remote URL 已含令牌，无需手动输密码）
:: 正常推送即可；若远程有你手动改过的内容冲突，再改用：git push -f origin main
git push origin main

echo.
echo 上传完成！VPS 会在 60 秒内自动拉取并重启。
pause
