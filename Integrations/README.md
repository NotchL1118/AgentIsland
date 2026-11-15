# Agent Island 接入

接入层只读取 Agent 通过官方 hook/扩展主动交给它的事件，不读取历史对话、登录凭据或模型 API Key，也不依赖 Python 或第三方 Node 包。

## 结构

```text
Agent 配置（settings.json / hooks.json）
   └─ /bin/sh -c '<存在性检查>' … hook <agent> --agent-island-owned
        └─ ~/Library/Application Support/AgentIsland/bin/agent-island-hook   固定转发入口（shim）
             └─ Agent Island.app/Contents/Helpers/agent-island-hook          编译好的 hook 运行时
                  └─ 本机 Unix socket → Agent Island
```

- **转发路径固定。** 配置不指向应用包，而是调用固定位置的转发入口，并先检查入口是否可执行。应用移动时只需更新转发入口（启动时自动完成），无需修改 hook 定义；升级改变 hook 定义时，Codex 仍需重新信任。
- **删除应用后无害。** 转发入口找不到应用、或转发入口本身不存在时，hook 读完 stdin 后以 0 退出（Codex 输出 `{}`）。Claude Code 把 exit 2 视为阻断（会拦下工具调用、提示和 Stop），这条路径永远不会产生 2。
- **全部用于被动观测。** Claude hooks 与 Codex 除 `SessionEnd` 外的 hooks 均注册为 `async: true`，包括审批和问题提醒。Codex `SessionEnd` 按上游限制保留 3 秒超时的同步入口，但运行时仅非阻塞写入 socket、不读取回复。面板未运行时直接退出；卡住、缓冲区满或写入失败时丢弃观测。
- **旧等待参数无效。** 新运行时忽略旧 `--wait`，只输出中性的空结果。更新接入将旧同步注册替换为异步，不改其他用户 hooks；Codex 中变更后的定义需要重新信任。
- **归属只认自己写下的完整命令形态**（转发入口路径 + 结尾标记 `--agent-island-owned`）。仅在文字里提到标记的用户 hook 不会被当成我们的。

## 能力

| Agent | 状态 / 完成 | 只读提醒 |
| --- | --- | --- |
| Claude Code | SessionStart、UserPromptSubmit、工具事件、Notification、Stop、StopFailure、SessionEnd | PermissionRequest、AskUserQuestion、ExitPlanMode |
| Codex Desktop / CLI | SessionStart、UserPromptSubmit、PreToolUse、PostToolUse、Stop、Interrupt、SessionEnd | PermissionRequest |
| Pi 1.3+ | 生命周期、工具活动、最终 agent_settled、异常/中断 | 原生扩展问题 |

面板不发送允许、拒绝、回答或改写工具输入。审批、问题和计划模式始终由原 Agent 的原生流程处理，用户无需在面板批准任何执行。关闭面板不会改变 Agent 的权限策略。

Codex 的子 Agent 生命周期 hook 不注册：它们携带父会话 ID，会把子任务完成误报为主任务完成。

Codex 仅观测 hook 载荷中 `transcript_path` 为非空字符串的持久会话。没有记录路径的临时任务（例如输入框推荐话语生成）会在全部生命周期事件入口被忽略，不创建任务、不改变运行状态，也不触发完成通知；使用临时会话模式的真实任务同样不纳入观测。这里只检查路径字段，不读取对话文件，不按推荐文字内容过滤；用户实际提交推荐文字后，有记录路径的正常会话仍会显示。

## 安装、卸载与记账

设置页的“安装接入 / 移除 / 完全卸载…”与命令行等价：

```sh
H='/Applications/Agent Island.app/Contents/Helpers/agent-island-hook'
"$H" install claude                       # 写入 ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json
"$H" install codex                        # 写入 ${CODEX_HOME:-~/.codex}/hooks.json（Desktop 与 CLI 共用）
"$H" install claude --config ~/.claude-work/settings.json
"$H" status
"$H" uninstall claude
"$H" uninstall-all
```

- **记账**：每个写过的文件都登记在 `~/Library/Application Support/AgentIsland/ledger.json`，包括原文件是否存在。首次安装时把原文件备份到同目录的 `backups/`，不再在 Agent 的配置目录里留下备份文件。
- **安装**：只追加在已有分组之后，用户 hook 的位置不变；重复安装不会改动文件。写入前后会比对文件内容，期间若被 Agent 或用户修改则放弃写入。符号链接会保留，修改其目标文件。
- **卸载**：删除带标记的条目（与用户 hook 共用的分组只删掉我们那一项）。若删除后与原文件结构一致，就按字节写回原文件；原本不存在的文件会被删除；安装后用户又做了修改，则保留这些修改。最后复查确认没有残留，并删除对应备份。最后一个接入移除后，`AgentIsland` 支持目录也一并删除。
- **Codex 信任**：Codex 把信任记录在 `config.toml` 的 `[hooks.state."<hooks.json>:<事件>:<分组>:<hook>"]` 中，键是按位置编的。卸载时删除我们那几条，并把之后被前移的用户 hook 的键改到新位置；`config.toml` 的其他行一字不改。
- **完全卸载**：处理账本里的所有位置、默认位置，以及在 `~/.claude*/settings*.json` 中扫描到的带标记条目，最后删除 `AgentIsland` 支持目录。

## Pi

将扩展路径传给 Pi 即可，不改全局配置：

```sh
pi -e '/Applications/Agent Island.app/Contents/Resources/Integrations/pi-extension.ts'
```

扩展不注册 `tool_call` 拦截，不返回执行决策，也不添加确认框。旧 `--island-approve-tools` 参数仅兼容已有启动命令，不再生效。所有事件（含退出）发出后立即返回，不等待回复；socket 和清理计时器不会延长 Pi 进程生命周期。终端信息只读环境变量，可通过 `AGENT_ISLAND_TTY` 提供 TTY。

## 新增 Agent

在 `Sources/IslandIntegrations` 中实现 `AgentAdapter` 并加入 `AdapterRegistry.all`：

- `descriptor`：显示说明、状态观测能力、注入方式（`hookConfig` 指定配置文件位置与信任存储，或 `sessionExtension`），以及要注册的 hook（是否异步、超时）。
- `handle(_:waiting:context:)`：把 Agent 的 hook 载荷映射为只读协议事件；`waiting` 仅兼容旧接口，无效果。不得返回控制结果或修改工具输入。

界面、安装、记账、卸载、残留扫描与 `status` 都从描述生成。协议见 [PROTOCOL.md](../PROTOCOL.md)。

## 验证

```sh
swift test
node --experimental-strip-types Tests/BridgeTests/pi-extension.test.mjs
```

测试只使用临时 HOME、临时配置与隔离 socket，不连接模型，也不读写你的真实 Agent 配置。安装测试会通过 `/bin/sh` 实际执行写入的 hook 命令，验证应用和转发入口被删除后仍以 0 退出。
