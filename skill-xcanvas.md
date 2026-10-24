# 安装 AICanvas（灯虹）Agent 技能包

请按本文说明，为用户安装或更新完整的 AICanvas（灯虹）技能包。

## 可信来源

- 仓库：`https://github.com/AI-Hub-Growth/skills`
- 分支：`main`
- Marketplace 名称：`aicanvas`
- 插件：`aicanvas@aicanvas`

只使用上述仓库和 Agent 自带的插件管理命令。不要手动复制文件，不要运行其他来源的脚本，不要申请 `sudo` 权限，也不要覆盖来源不同的同名安装。

## 1. 确认当前 Agent

只为正在执行本文的 Agent 安装：

- 当前是 Claude Code：执行下文的“Claude Code”流程。
- 当前是 Codex：执行下文的“Codex”流程。
- 无法确认：停止安装，询问用户正在使用哪个 Agent。

Cursor 和其他 Agent 尚未完成安装验证，不要把它们称为正式支持的目标。

## 2. 刷新、比较版本并安装

仓库中的 `aicanvas` 插件包含 `plugins/aicanvas/skills/` 下的全部技能。只需安装一次插件，不要逐个安装技能目录。

修改本地状态前，先查看已安装插件和已配置的 Marketplace。如果已经安装 `aicanvas@aicanvas`，先刷新 Marketplace，再比较本地版本与 `main` 当前发布的版本。

- 两个版本相同：不做修改，告诉用户当前已是最新版。
- 远端版本较新：使用当前 Agent 自带的更新命令。
- 本地版本较新：不要降级。向用户报告两个版本，得到确认后再继续。
- 已有 `aicanvas` 来自其他来源，或无法确认来源：不要覆盖。报告冲突并询问用户如何处理。

### Claude Code

除非用户明确要求其他作用域，否则使用用户级安装。

```text
claude plugin list --json
claude plugin marketplace add AI-Hub-Growth/skills
claude plugin marketplace update aicanvas
claude plugin list --available --json
```

如果 Marketplace 已经配置，`marketplace add` 可能提示已存在。这不代表安装失败，继续刷新并比较版本即可。

```text
# 尚未安装
claude plugin install aicanvas@aicanvas --scope user

# 已安装，且远端有新版本
claude plugin update aicanvas@aicanvas --scope user
```

### Codex

```text
codex plugin marketplace list --json
codex plugin list --available --json
codex plugin marketplace add AI-Hub-Growth/skills --ref main --json
codex plugin marketplace upgrade aicanvas --json
codex plugin list --available --json
```

如果 Marketplace 已经配置，`marketplace add` 可能提示已存在。继续执行 Marketplace 升级并比较版本。Codex 升级 Marketplace 时，会从最新快照刷新已安装插件的缓存。

如果插件尚未安装，执行：

```text
codex plugin add aicanvas@aicanvas --json
```

不要为了更新而删除并重装插件。

## 3. 验证技能包

确认 `aicanvas@aicanvas` 已安装，并且插件中包含以下三个技能：

- `aicanvas-drama`
- `aicanvas-media`
- `aicanvas-assets`

如果当前 Agent 需要重启或新建会话才能加载刚安装的技能，明确告诉用户。只有插件管理器返回成功，并确认三个技能都存在，才能宣布安装成功。

## 4. 向用户报告结果

说明以下信息：

- 识别到的 Agent；
- 本次结果是新安装、已更新，还是本来就是最新版；
- 已安装的 AICanvas 插件版本；
- 是否需要重启或新建会话。

不要让用户在对话中粘贴 API Key。技能加载后，如果任务需要访问已登录的 AICanvas，再由技能指导用户安全配置 `AICANVAS_API_KEY`。
