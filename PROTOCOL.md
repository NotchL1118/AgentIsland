# 本地事件协议 v1

默认端点：`$TMPDIR/agent-island-<uid>.sock`。原生应用与桥都可通过 `AGENT_ISLAND_SOCKET` 覆盖，便于隔离测试。文件权限为 0600，服务端只接受同一用户连接。

每个连接发送一个 UTF-8 JSON 行（最大 1 MiB）。应用校验后立即回复一个接收确认，审批和问题也不保持等待连接。hook 使用尽力、非阻塞写入，发送后关闭连接，不读取回复；只有显式诊断命令 `emit` 等待确认。应用从不执行事件中的命令文字，也不回传执行决策。

```json
{
  "version": 1,
  "id": "unique-event-id",
  "provider": "claude",
  "sessionID": "agent-session-id",
  "turnID": "optional-reliable-turn-id",
  "timestamp": 1794620000.0,
  "kind": "approvalRequested",
  "title": "修复登录校验",
  "cwd": "/projects/web-app",
  "message": "等待批准测试",
  "terminal": {"appBundleID": "com.apple.Terminal", "tty": "/dev/ttys005"},
  "request": {
    "id": "unique-request-id",
    "kind": "approval",
    "title": "允许执行测试？",
    "detail": "npm test"
  }
}
```

`provider`：开放字符串（1–64 字符），内置 `claude`、`codex`、`pi`；未知值也会被接受并显示，便于新增 Agent 时不必先升级应用。会话以 `provider:sessionID` 命名，不能仅按工作目录区分。

`kind`：`sessionStarted`、`turnStarted`、`toolStarted`、`toolFinished`、`approvalRequested`、`questionRequested`、`requestCancelled`、`turnCompleted`、`turnFailed`、`sessionEnded`、`heartbeat`。

问题提醒的顶层事件使用 `kind: "questionRequested"`，详情使用 `request.kind: "question"`，可附 `request.options: [{"id":"mock","label":"使用 mock"}]`。`request` 仅保存供展示的详情，所有选项均只读；上游没有详情时可省略，只显示待处理状态。审批与回答均在原 Agent 中进行。取消事件只需 `request: {"id":"..."}`。

普通确认：

```json
{"status":"accepted"}
```

确认仅表示收到有效协议包，不代表批准、拒绝或完成任何工具执行。重复或过期事件也会立即确认，由状态引擎去重或忽略。旧协议的 `decision` / `answer` 字段保留解码兼容，但应用不产生，hook 也不读取或使用。

无效事件：

```json
{"status":"error","message":"Invalid event identity, version or timestamp"}
```

观测连接结束不代表 Agent 的请求已取消，也不会删除提醒。后续工具活动、新轮次、完成、失败或会话结束会清理旧提醒；原 Agent 明确结束某个请求时可发送 `requestCancelled`。新一轮任务应先发 `turnStarted`，只在上游提供可靠标识时传 `turnID`。事件可能在面板离线或繁忙时丢失，不能作为 Agent 执行的控制通道。
