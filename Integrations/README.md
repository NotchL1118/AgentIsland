# Agent Island 接入

本目录实现本地 CLI 事件接入，不读取历史对话、登录凭据或模型 API Key。正常运行不需要第三方 Python/Node 依赖。

## 当前能力

| Agent | 状态 / 完成 | 面板审批 | 面板回答 |
| --- | --- | --- | --- |
| Claude Code | SessionStart、UserPromptSubmit、工具事件、Stop、StopFailure、SessionEnd | PermissionRequest 单次允许/拒绝 | AskUserQuestion 单选与自定义文本，多题逐题回答 |
| Pi 1.3+ | 生命周期、工具活动、最终 agent_settled、异常/中断 | 显式开启 `--island-approve-tools` 后，审批 bash/write/edit | 原生扩展问题可显示“等待回答”，需回 Pi 处理 |

Claude 包含多选题的 AskUserQuestion，以及 ExitPlanMode，保留原生界面处理；不把单选按钮伪装成多选支持。这里只管理本轮任务状态，不把一次工具失败误判为整轮任务失败。

Claude 的共同 hook 字段 `prompt_id` 是可选的：有该字段时按真实轮次识别事件；没有该字段的版本只能按事件时序降级，无法保证识别跨轮次迟到的完成事件。不会用当前轮次 ID 猜测补齐旧事件。

## Claude Code

在仓库根目录执行以下命令，或使用应用内的接入按钮：

```sh
python3 Integrations/bridge.py install-claude
```

只有显式调用安装命令才会编辑 `~/.claude/settings.json`（设置了 `CLAUDE_CONFIG_DIR` 时使用对应目录）。现有配置会备份到同目录 `settings.json.agent-island-backup-*`，安装幂等，只管理带有专属标记的 hook。原文件是符号链接时，保留链接并更新其目标文件。重新启动 Claude Code 后生效。

可以指定项目级配置：

```sh
python3 Integrations/bridge.py install-claude --settings /path/to/project/.claude/settings.local.json
python3 Integrations/bridge.py uninstall-claude --settings /path/to/project/.claude/settings.local.json
```

卸载默认接入：

```sh
python3 Integrations/bridge.py uninstall-claude
```

安装命令记录 bridge 脚本的绝对路径；移动应用或仓库后应重新安装接入。卸载不会覆盖其他 hook、权限、模型或状态栏设置。

普通事件最多等待应用 0.8 秒，审批/问答总共最多等待 120 秒。面板不存在、断连、超时或返回错误请求 ID 时，hook 不输出任何允许结果，交回 Claude Code 的原生权限/问题流程；没有原生交互能力的运行模式按 Claude 自身规则处理。拒绝仅作用于当前请求，不写入持久授权规则。

## Pi

将扩展路径传给 Pi 即可，不改全局配置：

```sh
pi -e /absolute/path/to/CodeLand/Integrations/pi-extension.ts
```

默认是被动监控。要在执行 bash/write/edit 前增加审批：

```sh
pi -e /absolute/path/to/CodeLand/Integrations/pi-extension.ts --island-approve-tools
```

扩展只在收到匹配的显式允许后放行。面板不可用时，支持交互的 Pi 会显示自己的确认框；没有交互 UI 或用户拒绝/超时则阻止该操作。用户中断时取消等待。

Pi 的 `agent_end` 可能随后重试或继续，因此完成提醒由 `agent_settled` 触发。其他扩展的阻塞问题通过 `ui_prompt_start/end` 反映等待状态，但不尝试伪造答案或接管未公开的回传接口。

## 本地协议

- 默认 Socket：`$TMPDIR/agent-island-<uid>.sock`；可用 `AGENT_ISLAND_SOCKET` 指定。
- 每次连接发一个 UTF-8 JSON 行，接收一个 JSON 行。
- 版本为 `1`；时间为 Unix epoch 秒；会话 ID 在同一 Agent 内保持稳定。
- 审批/回答只接受 `status: "resolved"`，且 `requestID` 必须与发出的请求一致。
- 超时/取消可发送 `requestCancelled` 清除待处理卡片。
- 终端定位使用已有环境变量及当前进程控制 TTY，不模拟键盘输入。
- 如果终端未提供足够定位信息，应用应退回激活宿主应用。

发测试事件：

```sh
printf '%s\n' '{"version":1,"id":"example-1","provider":"claude","sessionID":"example","timestamp":1,"kind":"sessionStarted","title":"Example"}' | python3 Integrations/bridge.py emit
```

## 验证

```sh
python3 -m unittest discover -s Tests/BridgeTests -p 'test_bridge.py' -v
node --experimental-strip-types Tests/BridgeTests/pi-extension.test.mjs
```

测试使用临时目录中的配置和 Unix socket，不连接模型或修改真实用户配置。Pi 扩展还通过了本机安装的 Pi 1.3.0 扩展加载器验证。Claude Code 的实际模型回合尚需在用户启用接入后验证。

## 文档依据

- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks)：PermissionRequest、AskUserQuestion、JSON 决策及配置合并。
- [Pi extension documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)：生命周期、工具拦截、CLI flags 与 UI 上下文。
- 本机 Pi 1.3.0 的 `dist/core/extensions/types.d.ts` 用于核实具体事件字段。

文档查询日期：2026-11-14。
