# 贡献与维护

本仓库是公开的 Codex 协作配置镜像。贡献应优先改善可审计性、可恢复性和跨平台复用，不把本机临时状态扩展成通用规则。

## 修改来源

- `config/global/AGENTS.md` 和 `config/projects/gpt-use-optimization/AGENTS.md` 是本机权威文件的镜像，不建议直接编辑。
- 本机源文件更新后，使用 `scripts/Sync-CodexCollaborationConfig.ps1` 生成镜像。
- README、脚本和安全文档属于仓库自身内容，可以直接修改。

## 提交前检查

在 PowerShell 7 或 Windows PowerShell 中执行：

```powershell
pwsh -NoProfile -File .\scripts\Test-CodexCollaborationConfig.ps1
git diff --check
```

检查失败时不要提交。新增文件还必须确认没有个人路径、代理端口、访问令牌、浏览器资料、研究材料或任务历史。

## 变更原则

1. 保持镜像文件的编码、BOM、换行和字节级同步要求。
2. 只修改登记过的镜像路径，避免同步脚本夹带其他工作区改动。
3. 不让脚本静默覆盖本机配置；恢复和高影响操作必须显式执行并保留验证证据。
4. 说明 Windows、Linux 和 macOS 的差异，不把驱动器字母或用户目录写成通用前提。\n
