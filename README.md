# AgentIsland

macOS 原生 AI 编程助手任务面板。支持 Claude Code、Codex CLI 和 Pi，使用 SwiftUI + AppKit；运行状态与审批通过本机 Unix socket 传递。

在菜单栏、屏幕顶部刘海或自由浮条中集中查看多个编程会话，处理支持的审批请求，并跳转回对应终端。应用显示名称为 **Agent Island**。

## 获取源码

```sh
git clone https://github.com/NotchL1118/AgentIsland.git
cd AgentIsland
```

## 构建与运行

要求 macOS 14+、Xcode/Command Line Tools（Swift 5.9+）；Claude/Codex hooks 需要 Python 3。无需安装 Swift 第三方依赖。

```sh
zsh scripts/build-app.sh
open 'dist/Agent Island.app'
```

先把应用放到打算长期保留的位置，再安装 Agent 接入。接入脚本记录绝对路径，移动应用后需重新安装接入。

点击菜单栏图标展开/收起，右键打开设置或切换显示方式。默认不会申请通知权限，设置中可按需启用。

- **顶部刘海**：贴合屏幕顶部，为摄像头留出空白；鼠标移入展开。
- **自由浮条**：鼠标移入展开；拖动名称区域移动，点击名称或右侧箭头展开/收起；自动记住显示器和位置，靠近边缘展开时会避让。快捷设置中可重置位置。
- **仅菜单栏**：平时只显示菜单栏图标，待处理任务显示数量；点击图标展开任务面板，点击外部收起。后台事件不会自动弹出面板，点击完成通知仍可打开对应会话。

三种形态均在点击外部后自动收回；顶部刘海和自由浮条也会在鼠标移出后收回，不受展开方式或键盘焦点影响。自动收回默认等待 0.3 秒，可在设置的“自动收回延迟”中调整为立即至 2 秒。等待期间移回面板会取消鼠标移出的收回，外部点击的收回仍会执行。拖动浮条时暂停自动收回；手动点击收起按钮和 Esc 仍立即响应。

浮窗中的齿轮只显示快捷设置：任务完成自动展开、显示方式、位置重置、收回延迟和通知。“Agent 接入与更多设置…”打开独立设置窗口，分为“通用”和“Agent 接入”，可调整开机启动、安装或移除接入、复制启动命令、查看操作结果；菜单栏图标右键也可打开。该窗口可移动、缩放，鼠标移出不会关闭；打开期间后台任务不会自动展开浮窗打断设置。

体验原生演示（不连接真实 Agent、不安装 hooks）：

```sh
open -n 'dist/Agent Island.app' --args --demo
```

## 连接 Agent

在设置中点击“安装接入”才会改动对应配置。安装前备份，卸载只移除本工具负责的条目。构建和测试不会修改你的 Agent 配置。

| Agent | 监控与完成 | 面板审批 | 面板问答 |
| --- | --- | --- | --- |
| Claude Code | 支持 | 支持单次允许/拒绝 | AskUserQuestion 单选、自定义文本；多选和计划模式回终端 |
| Codex CLI | 支持官方 hooks | 支持 PermissionRequest | 回终端处理 |
| Pi 1.3+ | 扩展接入 | 可选，需 `--island-approve-tools` | 显示待回答，回 Pi 处理 |

- **Claude Code**：设置中安装后重新启动 CLI。也可执行 `python3 Integrations/bridge.py install-claude`。
- **Codex**：设置中安装后，在 Codex `/hooks` 中检查并信任新定义。使用“启动命令”复制包装命令，可更可靠地保留终端身份。不会绕过 Codex 的信任设置。
- **Pi**：设置中复制启动命令，使用 `pi -e /绝对路径/pi-extension.ts` 加载扩展，不需要改全局配置。

详细说明：[Claude/Pi 接入](Integrations/README.md)、[Codex 接入](Integrations/codex/README.md)。

## 已实现

- 原生菜单栏与刘海/浮条面板，多会话列表、状态与结果摘要。
- 最大 800pt 宽的横向会话列表，行内审批与终端跳转；轮廓从刘海中心液态展开，文字保持原尺寸，连续开合保留动画速度。
- 透明区域鼠标穿透，收起时结束输入焦点；遵循 macOS 的“减少动态效果”设置。
- 本地事件接收、会话/轮次分离、重复和过期事件处理、多个待处理请求。
- 审批/回答沿原连接回传，仅明确点击后发送；断连和超时撤销卡片，回到 Agent 自身流程。
- 完成通知与开机启动（按需开启）、无回传能力的待处理状态提示。
- Terminal 与 iTerm2 通过 TTY 精确定位，其他已识别终端激活应用。
- 应用退出释放所有等待中的请求，普通状态 hook 在面板不运行时迅速返回。

## 当前边界

- 本版对接 CLI；不接管 Codex Desktop 的现有聊天。没有远程 SSH、额度统计、手机推送、子 Agent 分组或 tmux 精确分屏。
- 会话状态保存在内存中，重启后由新的 Agent 事件重新发现；不会扫描你的历史聊天。正在等待的审批回到原 Agent，不伪装恢复失效的回传连接。
- 跨轮次隔离依赖上游提供可靠轮次 ID。旧版 Claude 未提供 `prompt_id` 时按事件时序降级，不伪造轮次身份。
- Terminal/iTerm2 精确跳转可能触发 macOS“自动化”授权；拒绝后降级到激活应用。未提供应用身份时明确提示手动返回。
- 应用目前是本机构建、临时签名，尚未做 Developer ID 签名、公证或自动更新。
- 已通过合成 hook、真实本地 Socket 及 Pi 扩展加载验证；真实模型回合仍需启用接入后实际使用验证。没有为测试启动付费推理。

## 验证

```sh
swift test
python3 -m unittest discover -s Tests/BridgeTests -p 'test_bridge.py' -v
python3 -m unittest discover -s Tests/CodexTests -v
node --experimental-strip-types Tests/BridgeTests/pi-extension.test.mjs
```

测试仅使用合成事件、临时配置和隔离 Socket。核心测试覆盖乱序、旧轮次、审批排队、取消、断连及完成通知去重。

## 源码布局

```text
Sources/IslandCore/       事件协议、会话模型、状态引擎
Sources/AgentIsland/      原生界面、窗口、Socket、导航与接入设置
Integrations/             Claude/Codex hooks 与 Pi 扩展
Tests/                    状态、接入脚本、应用通信验证
Resources/Info.plist       macOS 应用信息
scripts/build-app.sh       构建与本机打包
```

新增 Agent 时实现事件映射和回传逻辑，主界面不需要复制一套。协议见 [PROTOCOL.md](PROTOCOL.md)。
