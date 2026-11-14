# Agent Island 接入

接入层只读取 Agent 通过官方 hook/扩展主动交给它的事件，不读取历史对话、登录凭据或模型 API Key，也不依赖 Python 或第三方 Node 包。

## 结构

```text
Agent 配置（settings.json / hooks.json）
   └─ /bin/sh -c '<存在性检查>' … hook <agent> [--wait] --agent-island-owned
        └─ ~/Library/Application Support/AgentIsland/bin/agent-island-hook   固定转发入口（shim）
             └─ Agent Island.app/Contents/Helpers/agent-island-hook          编译好的 hook 运行时
                  └─ 本机 Unix socket → Agent Island
```

- **配置里的命令永远不变。** 它不指向应用包，而是调用固定位置的转发入口，并先检查入口是否可执行。应用移动或更新时，只需更新转发入口（应用启动时自动完成），Codex 基于内容哈希的信任也不会失效。
- **删除应用后无害。** 转发入口找不到应用、或转发入口本身不存在时，hook 读完 stdin 后以 0 退出（Codex 输出 `{}`）。Claude Code 把 exit 2 视为阻断（会拦下工具调用、提示和 Stop），这条路径永远不会产生 2。
- **只有需要结果的 hook 才同步。** Claude 的 `PermissionRequest` 与 `PreToolUse[AskUserQuestion]`、Codex 的 `PermissionRequest` 带 `--wait` 同步执行；其他 hook 均注册为 `async: true`。面板未运行时，hook 不探测终端，直接退出。
- **归属只认自己写下的完整命令形态**（转发入口路径 + 结尾标记 `--agent-island-owned`）。仅在文字里提到标记的用户 hook 不会被当成我们的。

## 能力

| Agent | 状态 / 完成 | 面板审批 | 面板回答 |
| --- | --- | --- | --- |
| Claude Code | SessionStart、UserPromptSubmit、工具事件、Notification、Stop、StopFailure、SessionEnd | PermissionRequest 单次允许/拒绝 | AskUserQuestion 单选与自定义文本，多题逐题回答 |
| Codex Desktop / CLI | SessionStart、UserPromptSubmit、PreToolUse、PostToolUse、Stop、Interrupt、SessionEnd | PermissionRequest 允许/拒绝 | 回 Codex 处理 |
| Pi 1.3+ | 生命周期、工具活动、最终 agent_settled、异常/中断 | 显式开启 `--island-approve-tools` 后，审批 bash/write/edit | 原生扩展问题显示“等待回答”，需回 Pi 处理 |

所有审批只在收到 `requestID` 匹配、`status: "resolved"` 的明确决定后才写出结果；面板不存在、断连、超时或回复不匹配时，交回 Agent 自己的审批流程，绝不默认放行。拒绝只作用于当前请求，不写入持久授权。

Claude 含多选题的 AskUserQuestion 与 ExitPlanMode 保留原生界面处理；任何一题无法回答时，整个工具调用原样交回 Claude，不做部分改写。Codex 的子 Agent 生命周期 hook 不注册：它们携带父会话 ID，会把子任务完成误报为主任务完成。

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
pi -e '…/pi-extension.ts' --island-approve-tools     # 执行 bash/write/edit 前先在面板审批
```

状态事件发送后不等待回复，面板卡住也不会拖慢 Pi。扩展只在收到匹配的显式允许后放行；面板不可用时，支持交互的 Pi 会显示自己的确认框，没有交互 UI 或用户拒绝/超时则阻止该操作。

## 新增 Agent

在 `Sources/IslandIntegrations` 中实现 `AgentAdapter` 并加入 `AdapterRegistry.all`：

- `descriptor`：显示说明、能力（status / approval / question）、注入方式（`hookConfig` 指定配置文件位置与信任存储，或 `sessionExtension`），以及要注册的 hook（是否同步、超时）。
- `handle(_:waiting:context:)`：把 Agent 的 hook 载荷映射为协议事件；需要回写时，只在收到匹配的明确决定后输出 Agent 要求的格式。

界面、安装、记账、卸载、残留扫描与 `status` 都从描述生成。协议见 [PROTOCOL.md](../PROTOCOL.md)。

## 验证

```sh
swift test
node --experimental-strip-types Tests/BridgeTests/pi-extension.test.mjs
```

测试只使用临时 HOME、临时配置与隔离 socket，不连接模型，也不读写你的真实 Agent 配置。安装测试会通过 `/bin/sh` 实际执行写入的 hook 命令，验证应用和转发入口被删除后仍以 0 退出。
