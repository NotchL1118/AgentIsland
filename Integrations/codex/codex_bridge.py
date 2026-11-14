#!/usr/bin/env python3
"""Codex lifecycle hooks -> Agent Island. No API keys or transcript scraping."""
from __future__ import annotations

import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import stat
import sys
import tempfile
import time
import uuid

VERSION = 1
MAX_BYTES = 1024 * 1024
HOOKS = {
    "SessionStart": "sessionStarted",
    "UserPromptSubmit": "turnStarted",
    "PreToolUse": "toolStarted",
    "PostToolUse": "toolFinished",
    "PermissionRequest": "approvalRequested",
    "Stop": "turnCompleted",
    "Interrupt": "turnFailed",
    "SessionEnd": "sessionEnded",
}


def socket_path(environ=None):
    env = os.environ if environ is None else environ
    return env.get("AGENT_ISLAND_SOCKET") or str(
        Path(env.get("TMPDIR") or tempfile.gettempdir()) / f"agent-island-{os.getuid()}.sock"
    )


def text(value, limit=4000):
    return value[:limit] if isinstance(value, str) else ""


def terminal_metadata(environ=None):
    env = os.environ if environ is None else environ
    # The launcher captures these before the CLI daemon/hooks lose their TTY.
    # Do not inspect unrelated processes or guess a window from its title.
    try:
        supplied = json.loads(env.get("AGENT_ISLAND_TERMINAL", "{}"))
    except (ValueError, TypeError):
        supplied = {}
    if not isinstance(supplied, dict):
        supplied = {}
    fields = ("appBundleID", "tty", "windowID", "tabID", "paneID", "tmuxPane")
    result = {key: text(supplied[key], 512) for key in fields if text(supplied.get(key), 512)}
    if result:
        return result
    bundle = text(env.get("__CFBundleIdentifier"), 256)
    known_apps = {"Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2", "ghostty": "com.mitchellh.ghostty", "WezTerm": "com.github.wez.wezterm"}
    bundle = bundle or known_apps.get(env.get("TERM_PROGRAM"), "")
    if bundle:
        result["appBundleID"] = bundle
    # TTY is not inferred from stdin: hooks receive JSON through a pipe.
    for key, variable in (("tty", "AGENT_ISLAND_TTY"), ("tmuxPane", "TMUX_PANE")):
        if text(env.get(variable), 512):
            result[key] = env[variable][:512]
    # ITERM_SESSION_ID is an opaque session UUID, not an AppleScript tab id.
    return result


def event_from_hook(payload, environ=None, now=None):
    if not isinstance(payload, dict):
        return None
    name = payload.get("hook_event_name")
    session_id = text(payload.get("session_id"), 512)
    if name not in HOOKS or not session_id:
        return None
    # Subagent lifecycle hooks use the parent's session id. We do not install
    # them: treating their Stop as the parent's completion would be incorrect.
    event = {"version": VERSION, "id": str(uuid.uuid4()), "provider": "codex", "sessionID": session_id,
             "timestamp": time.time() if now is None else now, "kind": HOOKS[name]}
    if text(payload.get("turn_id"), 512):
        event["turnID"] = payload["turn_id"][:512]
    cwd = text(payload.get("cwd"), 4096)
    if cwd:
        event["cwd"] = cwd
    terminal = terminal_metadata(environ)
    if terminal:
        event["terminal"] = terminal
    tool_name = text(payload.get("tool_name"), 256) or "工具"
    tool_input = payload.get("tool_input")
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    if name == "SessionStart":
        if payload.get("source") == "compact":
            event["kind"] = "heartbeat"
            event["message"] = "上下文整理完成，继续当前任务"
        else:
            event["title"] = Path(cwd).name if cwd else "Codex"
            event["message"] = "Codex 会话已连接"
    elif name == "UserPromptSubmit":
        prompt = text(payload.get("prompt"))
        event["title"] = (prompt.splitlines()[0] if prompt else "Codex 任务")[:120]
        event["message"] = "正在处理请求"
    elif name == "PreToolUse":
        event["message"] = text(tool_input.get("description"), 500) or f"执行 {tool_name}"
    elif name == "PostToolUse":
        event["message"] = f"{tool_name} 已返回结果"
    elif name == "PermissionRequest":
        request_id = str(uuid.uuid4())
        detail = text(tool_input.get("command")) or text(json.dumps(tool_input, ensure_ascii=False))
        event["request"] = {"id": request_id, "kind": "approval", "title": text(tool_input.get("description"), 500) or f"允许 Codex 执行 {tool_name}？", "detail": detail}
        event["message"] = "等待你批准工具请求"
    elif name == "Stop":
        event["message"] = text(payload.get("last_assistant_message")) or "本轮任务已完成"
    elif name == "Interrupt":
        event["message"] = "本轮任务已被用户中断"
    else:
        event["message"] = "Codex 会话已结束"
    return event


def send_event(event, *, path=None, timeout=0.7):
    """Fail open to Codex's native approval UI, never to permission allow."""
    endpoint = path or socket_path()
    try:
        info = os.stat(endpoint, follow_symlinks=False)
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            return None
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.35)
            client.connect(endpoint)
            client.settimeout(timeout)
            client.sendall(json.dumps(event, ensure_ascii=False).encode("utf-8") + b"\n")
            buffer = bytearray()
            while b"\n" not in buffer and len(buffer) <= MAX_BYTES:
                part = client.recv(min(8192, MAX_BYTES + 1 - len(buffer)))
                if not part:
                    return None
                buffer.extend(part)
            if len(buffer) > MAX_BYTES or b"\n" not in buffer:
                return None
            reply = json.loads(bytes(buffer).split(b"\n", 1)[0])
            return reply if isinstance(reply, dict) else None
    except (OSError, ValueError, TypeError):
        return None


def permission_output(reply, request_id):
    if not isinstance(reply, dict) or reply.get("status") != "resolved" or reply.get("requestID") != request_id:
        return {}
    decision = reply.get("decision")
    if decision not in ("allow", "deny"):
        return {}
    output = {"behavior": decision}
    if decision == "deny":
        output["message"] = text(reply.get("message"), 1000) or "用户在 Agent Island 中拒绝了本次请求。"
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": output}}


def run_hook(payload, *, environ=None, transport=send_event):
    event = event_from_hook(payload, environ)
    if event is None:
        return {}
    if event["kind"] != "approvalRequested":
        transport(event, timeout=0.7)
        return {}
    env = os.environ if environ is None else environ
    try:
        wait = min(120.0, max(1.0, float(env.get("AGENT_ISLAND_APPROVAL_TIMEOUT", "120"))))
    except ValueError:
        wait = 120.0
    reply = transport(event, timeout=wait)
    result = permission_output(reply, event["request"]["id"])
    if not result:
        # The native terminal approval continues. Invalidate only this card.
        cancel = {**event, "id": str(uuid.uuid4()), "timestamp": time.time(), "kind": "requestCancelled", "message": "审批已交回 Codex 终端，请在那里处理。"}
        transport(cancel, timeout=0.35)
    return result


def generated_groups(script=None, interpreter=None):
    command = shlex.join([str(interpreter or sys.executable), str(script or Path(__file__).resolve()), "hook"])
    return {name: {"hooks": [{"type": "command", "command": command,
             "timeout": 125 if name == "PermissionRequest" else 3,
             "statusMessage": f"Agent Island: {name}"}]} for name in HOOKS}


def validate_config(config):
    if not isinstance(config, dict) or not isinstance(config.get("hooks", {}), dict):
        raise ValueError("hooks.json 必须是包含 hooks 对象的 JSON 文件；原文件未修改。")
    for groups in config.get("hooks", {}).values():
        if not isinstance(groups, list) or any(not isinstance(group, dict) or not isinstance(group.get("hooks", []), list) for group in groups):
            raise ValueError("hooks.json 中的 hook 分组格式无效；原文件未修改。")


def remove_owned(config, groups):
    result = copy.deepcopy(config)
    hooks = result.get("hooks", {})
    for event, installed in groups.items():
        current = hooks.get(event)
        if not isinstance(current, list):
            continue
        # Exact equality deliberately preserves user edits to installed hooks.
        remainder = [group for group in current if group != installed]
        if remainder:
            hooks[event] = remainder
        else:
            hooks.pop(event, None)
    if not hooks:
        result.pop("hooks", None)
    return result


def merge_config(config, groups, old_groups=None):
    validate_config(config)
    result = remove_owned(config, old_groups or {})
    hooks = result.setdefault("hooks", {})
    for event, group in groups.items():
        current = hooks.setdefault(event, [])
        if group not in current:
            current.append(copy.deepcopy(group))
    return result


def atomic_write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configuration_path(path=None):
    return Path(path).expanduser() if path else Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "hooks.json"


def change_installation(path, install):
    # Follow an existing config symlink, preserving the symlink itself.
    target = Path(path).expanduser().resolve()
    registry = target.with_name(f".{target.name}.agent-island.json")
    raw = target.read_bytes() if target.exists() else b"{}"
    config = json.loads(raw)
    validate_config(config)
    previous = {}
    if registry.exists():
        manifest = json.loads(registry.read_text())
        if not isinstance(manifest, dict) or manifest.get("version") != VERSION or not isinstance(manifest.get("groups"), dict):
            raise ValueError("Agent Island 安装记录无效；未修改配置。")
        previous = manifest["groups"]
    groups = generated_groups()
    updated = merge_config(config, groups, previous) if install else remove_owned(config, previous)
    backup = None
    if updated != config:
        if target.exists():
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
            backup = target.with_name(f"{target.name}.agent-island-backup-{stamp}")
            atomic_write(backup, raw)
        mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o600
        atomic_write(target, (json.dumps(updated, ensure_ascii=False, indent=2) + "\n").encode(), mode)
    if install:
        atomic_write(registry, (json.dumps({"version": VERSION, "groups": groups}, ensure_ascii=False, indent=2) + "\n").encode())
    elif registry.exists():
        registry.unlink()
    return {"changed": updated != config, "path": str(target), "backup": str(backup) if backup else None}


def launch(args):
    executable = shutil.which("codex")
    if not executable:
        raise ValueError("找不到 codex，请先安装 Codex CLI。")
    env = os.environ.copy()
    metadata = terminal_metadata(env)
    for fd in (0, 1, 2):
        try:
            if os.isatty(fd):
                metadata["tty"] = os.ttyname(fd)
                break
        except OSError:
            pass
    env["AGENT_ISLAND_TERMINAL"] = json.dumps(metadata)
    # Keep hook terminal metadata tied to this launch, rather than inheriting
    # the shared daemon's first terminal. All agent arguments are passed as argv.
    command = [executable, "--no-daemon", *args]
    os.execvpe(executable, command, env)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("hook", help="Codex 调用：读取 stdin 中的 hook JSON")
    for name in ("install", "uninstall"):
        item = commands.add_parser(name, help="显式安装或移除本集成的 hooks")
        item.add_argument("--config", help="hooks.json 路径；默认 $CODEX_HOME/hooks.json")
    run = commands.add_parser("launch", help="在当前终端启动 Codex 并记录终端位置")
    run.add_argument("args", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command == "hook":
        # Hook errors must not produce extra model instructions or auto-approve.
        try:
            raw = sys.stdin.buffer.read(MAX_BYTES + 1)
            result = run_hook(json.loads(raw)) if len(raw) <= MAX_BYTES else {}
        except (OSError, ValueError, TypeError, KeyError):
            result = {}
        print(json.dumps(result, ensure_ascii=False))
        return 0
    try:
        if args.command == "launch":
            launch(args.args[1:] if args.args[:1] == ["--"] else args.args)
        else:
            result = change_installation(configuration_path(args.config), args.command == "install")
            print(json.dumps(result, ensure_ascii=False))
            if args.command == "install":
                print("请在 Codex CLI 中打开 /hooks，检查并信任新增的 Agent Island hooks。安装不会自动绕过信任。", file=sys.stderr)
        return 0
    except (OSError, ValueError) as error:
        print(f"Agent Island: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
