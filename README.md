# Codex 协作配置镜像

这是 Roy 的 Codex 协作规则的最小化、可审计、可恢复镜像。仓库只保存长期有效的协作规则与同步工具，不保存完整画像、原始报告、任务记录、附件、记忆、凭据或研究材料。

## 本轮改造结论

《Finding Your Unknowns》报告的核心不是给每个任务增加一套固定文档，而是管理 Agent 必须猜测的位置。本轮采用风险自适应方案，将高价值原则固化到现有 `AGENTS.md`，没有为普通任务强制增加 `unknowns.md`、`implementation-notes.md`、Quiz、Hook 或新 Skill。

已经固化的机制：

- L0：明确、低影响、可逆且范围内，直接完成。
- L1：常规实现，自主完成并做针对性验证。
- L2：涉及外部写入、权限、安全、数据、架构、外部契约、重大用户可见行为或不可逆影响，先确认。
- 只有未知项足以改变范围、方案或风险等级时才询问，避免把每个小歧义都变成停顿。
- 解释、自述和计划不能替代 diff、测试、运行结果、哈希或独立复核。
- 一个任务维持一个连贯目标；独立目标或上下文明显膨胀时，用短交接摘要切换任务。
- 处理画像、迁移和配置时，区分已确认事实、旧记录、推断与未知项，并分别核对全局、项目和平台层。

这套设计保留了报告中的认知闭环、执行闭环和验证闭环，同时避免给简单任务增加明显的 token 消耗与处理时间。

## 配置分层

```text
本机权威源
├─ %USERPROFILE%\.codex\AGENTS.md
│  └─ 所有工作区通用的协作、风险、文件、路由和隐私规则
└─ 仓库父目录\AGENTS.md
   └─ 本工作区的画像、迁移、证据与敏感信息边界

        字节级镜像
             ↓

本仓库
├─ config/global/AGENTS.md
└─ config/projects/gpt-use-optimization/AGENTS.md

        Git commit + push
             ↓

GitHub 私有仓库
```

本机文件是唯一权威源，GitHub 是版本化备份和审计镜像。不要直接在 GitHub 网页编辑镜像文件；远端变更不会自动覆盖本机。同步遇到分叉时会停止，而不是猜测合并方向。

## 仓库内容

- `config/global/AGENTS.md`：全局规则的逐字节镜像。
- `config/projects/gpt-use-optimization/AGENTS.md`：当前工作区规则的逐字节镜像。
- `scripts/Sync-CodexCollaborationConfig.ps1`：单次同步或持续监控。
- `scripts/Install-CodexCollaborationSync.ps1`：安装或移除当前用户的登录时自动监控任务。
- `.gitattributes`：禁止 Git 改写两个镜像文件的换行，确保仓库中的字节与源文件一致。

## 同步流程

持续监控默认每 5 秒计算两个小文件的 SHA-256，仅在内容改变后工作：

1. 等待 2 秒防抖，合并一次编辑产生的连续写入。
2. 执行 `git pull --ff-only`；远端分叉或本地冲突时立即停止。
3. 用原始字节复制两个 `AGENTS.md`，不改变编码、BOM 或换行。
4. 只暂存这两个镜像路径，不夹带仓库内其他改动。
5. 自动生成一条 `sync: update collaboration configuration ...` 提交。
6. 推送 `main`，并核对远端 `main` 与本地 `HEAD` 的提交哈希。
7. 网络失败时保留本地提交，默认 5 分钟后重试。

因此这里的“实时更新”是近实时：正常情况下在源文件保存后的数秒内开始提交和推送，实际完成时间取决于 GitHub 网络。监控本身不调用模型，不消耗 Codex token。

## 使用

首次本地镜像但暂不联网：

```powershell
.\scripts\Sync-CodexCollaborationConfig.ps1 -NoPull -NoPush
```

远端仓库和 Git 凭据可用后，执行一次联网同步：

```powershell
.\scripts\Sync-CodexCollaborationConfig.ps1
```

安装登录时自动监控：

```powershell
.\scripts\Install-CodexCollaborationSync.ps1
```

移除自动监控任务：

```powershell
.\scripts\Install-CodexCollaborationSync.ps1 -Uninstall
```

运行日志位于 `.runtime/sync.log`，已被 Git 忽略。任务计划程序中的任务名为 `Codex-Collaboration-Config-Sync`。

### 当前机器的 GitHub 网络路由

当前 Windows 环境通过本机 Clash/Mihomo 的 `127.0.0.1:7897` 访问 GitHub。该地址只写入本仓库的 `.git/config`，不会提交到 GitHub，也不会影响其他仓库。代理端口变化时执行：

```powershell
git config --local http.https://github.com.proxy http://127.0.0.1:新端口
```

恢复直连时执行：

```powershell
git config --local --unset-all http.https://github.com.proxy
```

可用以下命令检查当前仓库实际采用的路由：

```powershell
git config --local --get-urlmatch http.proxy https://github.com/roy-reed/codex-collaboration-config.git
```

## 安全边界

- GitHub 仓库必须保持 Private。
- 不提交令牌、Cookie、SSH 私钥、证书、`.env`、浏览器资料或 Git 凭据。
- 不提交 `LUCS_Master_v2.0.md`、`Roy_精简运行画像.md`、原始报告、附件、备份、Codex 记忆或任务历史。
- 不持久化单位、项目代号、敏感参数、未公开方案、人员或国防军事敏感信息。
- 私有 GitHub 仍是第三方存储；新增镜像文件前必须重新判断其敏感性。
- `AGENTS.md` 是协作规则，不是操作系统级安全边界；权限和沙箱仍需单独配置与验证。

## 恢复原则

恢复时先停止自动监控并备份现有本机文件，再从指定提交逐字节复制镜像。恢复属于覆盖本机配置的高影响操作，不由监控脚本自动执行。完成后应核对 SHA-256、编码、BOM、换行和关键规则，再重新安装监控任务。

## 维护约定

- 规则优先在本机对应的 `AGENTS.md` 中修改，由监控脚本镜像。
- README 或脚本自身的改动在本仓库内正常提交，不纳入配置监控。
- 新增项目级镜像前，先确认确有跨设备保存价值，避免把临时上下文和敏感材料带入长期仓库。
- 简单任务继续直接执行；只有高风险或方向性未知触发完整的发现、决策和验证流程。
