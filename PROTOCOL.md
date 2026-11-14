# 本地事件协议 v1

默认端点：`$TMPDIR/agent-island-<uid>.sock`。原生应用与桥都可通过 `AGENT_ISLAND_SOCKET` 覆盖，便于隔离测试。文件权限为 0600，服务端只接受同一用户连接。

每个连接发送一个 UTF-8 JSON 行（最大 1 MiB），接收一个 JSON 行。正常事件立即回复；有回传通道的审批/问题保持连接，等待用户操作，最长 120 秒。应用从不执行事件中的命令文字。

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

`provider`：`claude`、`codex`、`pi`。会话以 `provider:sessionID` 命名，不能仅按工作目录区分。

`kind`：`sessionStarted`、`turnStarted`、`toolStarted`、`toolFinished`、`approvalRequested`、`questionRequested`、`requestCancelled`、`turnCompleted`、`turnFailed`、`sessionEnded`、`heartbeat`。

问题请求使用 `kind: "question"`，可附 `options: [{"id":"mock","label":"使用 mock"}]`。没有稳定回传接口的等待事件省略 `request`，只显示状态并返回终端，不提供虚假的审批或回答按钮。取消事件只需 `request: {"id":"..."}`。

普通确认：

```json
{"status":"accepted"}
```

显式用户决策：

```json
{"status":"resolved","requestID":"unique-request-id","decision":"allow"}
{"status":"resolved","requestID":"question-id","decision":"answer","answer":"使用 mock"}
```

`decision` 仅允许 `allow`、`deny`、`answer`。桥必须核对 `requestID`，不可把超时、断连、`unavailable` 或 `error` 当作允许。相同请求不可重复执行。

已有等待连接的同一请求会返回 `status: "duplicate"`。新连接应回退原 Agent，但不能因此发送 `requestCancelled`，以免撤销首条仍有效的连接。

无法处理：

```json
{"status":"unavailable","requestID":"...","message":"Return to the agent to continue"}
```

桥在自己的等候超时后发送 `requestCancelled`，服务端也会检查连接关闭以清理过期卡片。新一轮任务应先发 `turnStarted`，只在上游提供可靠标识时传 `turnID`。
