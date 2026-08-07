@echo off
echo 正在把本地最新代码强制覆盖到 GitHub...
cd /d "D:\付\交易日志\仓库\交易日志\个人知识库\WB工作\WB工作结果\自建AI系统\cognitive-navigator"

:: 收集所有被 WB 修改过的新文件
git add .

:: 给这次上传打个标签
git commit -m "WB代码更新，本地强制覆盖"

:: 核心命令：-f 代表 force（强制），无视网上的任何冲突，直接用本地覆盖网上
git push -f origin main

echo.
echo 上传和覆盖完成！你可以去 VPS 跑拉取命令了。
pause