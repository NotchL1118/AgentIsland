#!/usr/bin/env python3
"""Local, dependency-free Claude Code bridge for Agent Island.

Normal hooks never make permission decisions. Permission output is written only
after a matching, explicit answer comes back from the local app. A missing app,
invalid reply, or timeout leaves Claude Code's own permission flow in charge.
"""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import os
from pathlib import Path
import shlex
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from typing import Any

OWNER_MARKER = "--agent-island-owned-v1"
MAX_BYTES = 1024 * 1024
EVENT_TIMEOUT = 0.8
REQUEST_TIMEOUT = 120.0
HOOK_EVENTS = (
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
    "PostToolUseFailure", "PermissionRequest", "Notification", "Stop",
    "StopFailure", "SessionEnd",
)


def socket_path() -> str:
    return os.environ.get("AGENT_ISLAND_SOCKET") or str(
        Path(os.environ.get("TMPDIR") or tempfile.gettempdir()) / f"agent-island-{os.getuid()}.sock"
    )


def exchange(event: dict[str, Any], timeout: float = EVENT_TIMEOUT,
             path: str | None = None) -> dict[str, Any]:
    """One event and one reply per connection; never retry a decision."""
    fallback = {"status": "unavailable"}
    packet = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
    if len(packet) > MAX_BYTES:
        return {"status": "error", "message": "Event exceeds the local size limit"}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(min(EVENT_TIMEOUT, max(timeout, .01)))
            client.connect(path or socket_path())
            client.settimeout(max(timeout, .01))
            client.sendall(packet)
            data = bytearray()
            while b"\n" not in data:
                chunk = client.recv(min(65536, MAX_BYTES + 1 - len(data)))
                if not chunk:
                    return fallback
                data.extend(chunk)
                if len(data) > MAX_BYTES:
                    return fallback
            reply = json.loads(bytes(data).split(b"\n", 1)[0])
            return reply if isinstance(reply, dict) else fallback
    except (OSError, ValueError, UnicodeError):
        return fallback


def terminal_metadata() -> dict[str, str]:
    env = os.environ
    terminal: dict[str, str] = {}
    bundle_ids = {
        "Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty", "WezTerm": "com.github.wez.wezterm",
        "vscode": "com.microsoft.VSCode", "WarpTerminal": "dev.warp.Warp-Stable",
    }
    bundle_id = env.get("AGENT_ISLAND_TERMINAL_BUNDLE_ID") or bundle_ids.get(env.get("TERM_PROGRAM", ""))
    if bundle_id:
        terminal["appBundleID"] = bundle_id
    tty = env.get("AGENT_ISLAND_TTY") or env.get("TTY")
    if not tty:
        for fd in (2, 1, 0):
            try:
                if os.isatty(fd):
                    tty = os.ttyname(fd)
                    break
            except OSError:
                pass
    if not tty:
        # Hook stdin/stdout are usually pipes. The process's controlling TTY can
        # still identify its launching terminal without reading session files.
        try:
            lookup = subprocess.run(["/bin/ps", "-o", "tty=", "-p", str(os.getppid())],
                                    capture_output=True, text=True, timeout=.25, check=False)
            value = lookup.stdout.strip()
            if value and value not in ("?", "??"):
                tty = value if value.startswith("/dev/") else "/dev/" + value
        except (OSError, subprocess.SubprocessError):
            pass
    if tty and tty.startswith("/dev/") and tty != "/dev/tty":
        terminal["tty"] = tty
    for key, env_key in (("tmuxPane", "TMUX_PANE"), ("paneID", "ITERM_SESSION_ID"),
                         ("tabID", "TERM_SESSION_ID"), ("windowID", "WINDOWID")):
        if env.get(env_key):
            terminal[key] = env[env_key]
    return terminal


def text(value: Any, limit: int = 2000) -> str:
    if value is None:
        return ""
    result = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return result[:limit]


def event_for(payload: dict[str, Any], kind: str, **extra: Any) -> dict[str, Any]:
    sid = text(payload.get("session_id"), 500)
    if not sid:
        raise ValueError("Hook payload has no session_id")
    if payload.get("agent_id"):
        sid += "/" + text(payload["agent_id"], 300)
    event: dict[str, Any] = {
        "version": 1, "id": str(uuid.uuid4()), "provider": "claude",
        "sessionID": sid, "timestamp": time.time(), "kind": kind,
    }
    if payload.get("prompt_id"):
        event["turnID"] = text(payload["prompt_id"], 500)
    if payload.get("cwd"):
        event["cwd"] = text(payload["cwd"], 4000)
    terminal = terminal_metadata()
    if terminal:
        event["terminal"] = terminal
    event.update({key: value for key, value in extra.items() if value is not None})
    return event


def tool_detail(payload: dict[str, Any]) -> str:
    arguments = payload.get("tool_input") or {}
    if isinstance(arguments, dict):
        if arguments.get("command"):
            return text(arguments["command"], 16000)
        if arguments.get("file_path") or arguments.get("path"):
            return text(arguments.get("file_path") or arguments.get("path"), 4000)
    return text(arguments, 16000)


def claude_event(payload: dict[str, Any]) -> dict[str, Any] | None:
    hook = payload.get("hook_event_name")
    tool = text(payload.get("tool_name"), 200)
    mapping = {
        "SessionStart": "sessionStarted", "UserPromptSubmit": "turnStarted",
        "PreToolUse": "toolStarted", "PostToolUse": "toolFinished",
        "PostToolUseFailure": "toolFinished", "Stop": "turnCompleted",
        "StopFailure": "turnFailed", "SessionEnd": "sessionEnded",
    }
    if hook == "PermissionRequest":
        if tool in ("AskUserQuestion", "ExitPlanMode"):
            return event_for(payload, "questionRequested", message=f"请在 Claude Code 处理：{tool}")
        # PermissionRequest may have no tool_use_id. The UUID belongs to this
        # exact hook invocation and is never inferred from the command text.
        request = {"id": str(uuid.uuid4()), "kind": "approval",
                   "title": f"允许 {tool or '工具操作'}？", "detail": tool_detail(payload)}
        return event_for(payload, "approvalRequested", request=request, message=request["title"])
    if hook == "Notification":
        notice = payload.get("notification_type")
        if notice not in ("permission_prompt", "idle_prompt", "elicitation_dialog", "agent_needs_input"):
            return None
        return event_for(payload, "questionRequested", message="请在 Claude Code 处理：" + text(payload.get("message"), 1800))
    if hook not in mapping:
        return None
    details: dict[str, Any] = {}
    if hook == "UserPromptSubmit":
        prompt = text(payload.get("prompt"), 2000).strip()
        details.update(title=(prompt.splitlines() or ["Claude Code"])[0][:100], message="正在处理任务")
    elif hook == "SessionStart":
        details["message"] = "会话已连接"
    elif hook == "Stop":
        details["message"] = text(payload.get("last_assistant_message"), 4000) or "本轮任务已完成"
    elif hook == "StopFailure":
        details["message"] = text(payload.get("error_details") or payload.get("error"), 2000) or "本轮任务异常结束"
    elif hook == "SessionEnd":
        details["message"] = "会话已结束"
    else:
        prefix = "工具失败：" if hook == "PostToolUseFailure" else "正在执行：" if hook == "PreToolUse" else "已执行："
        details["message"] = (prefix + tool + " " + tool_detail(payload))[:2000]
    return event_for(payload, mapping[hook], **details)


def permission_output(request_id: str, reply: dict[str, Any]) -> dict[str, Any] | None:
    if reply.get("status") != "resolved" or reply.get("requestID") != request_id:
        return None
    decision = reply.get("decision")
    if decision not in ("allow", "deny"):
        return None
    result: dict[str, Any] = {"behavior": decision}
    if decision == "deny":
        result["message"] = "用户在 Agent Island 拒绝了本次请求。"
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": result}}


def answer_questions(payload: dict[str, Any], sender=exchange) -> dict[str, Any] | None:
    original = payload.get("tool_input")
    if not isinstance(original, dict) or not isinstance(original.get("questions"), list):
        return None
    questions = original["questions"]
    if not questions or len(questions) > 8:
        return None
    # Never partially rewrite the input: if any question is unanswerable, the
    # complete original tool falls back to Claude Code's own question UI.
    if any(not isinstance(q, dict) or not isinstance(q.get("question"), str) or q.get("multiSelect") for q in questions):
        sender(event_for(payload, "questionRequested", message="此问题需要在 Claude Code 终端回答（包含多选或不支持的题型）。"), timeout=EVENT_TIMEOUT)
        return None
    answers = dict(original.get("answers") or {})
    deadline = time.monotonic() + REQUEST_TIMEOUT
    call_id = text(payload.get("tool_use_id"), 500) or str(uuid.uuid4())
    for index, question in enumerate(questions):
        question_text = question["question"]
        if question_text in answers:
            continue
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        request_id = f"{call_id}:question:{index}"
        options = [{"id": text(option.get("label"), 200), "label": text(option.get("label"), 200)}
                   for option in question.get("options", [])
                   if isinstance(option, dict) and option.get("label")]
        note = "多选题：请用逗号分隔所选项，或输入自定义回答。" if question.get("multiSelect") else f"第 {index + 1}/{len(questions)} 个问题"
        request = {"id": request_id, "kind": "question", "title": text(question_text, 2000), "detail": note, "options": options}
        reply = sender(event_for(payload, "questionRequested", request=request, message=question_text[:2000]), timeout=remaining)
        if reply.get("status") != "resolved" or reply.get("requestID") != request_id or reply.get("decision") != "answer":
            if reply.get("status") != "duplicate":
                sender(event_for(payload, "requestCancelled", request=request, message="请在 Claude Code 终端回答。"), timeout=EVENT_TIMEOUT)
            return None
        answer = reply.get("answer")
        if not isinstance(answer, str) or not answer.strip():
            sender(event_for(payload, "requestCancelled", request=request, message="请在 Claude Code 终端回答。"), timeout=EVENT_TIMEOUT)
            return None
        answers[question_text] = answer.strip()[:16000]
    updated = copy.deepcopy(original)
    updated["answers"] = answers
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": updated}}


def handle_claude(payload: dict[str, Any], sender=exchange) -> dict[str, Any] | None:
    if payload.get("hook_event_name") == "PreToolUse" and payload.get("tool_name") == "AskUserQuestion":
        return answer_questions(payload, sender)
    event = claude_event(payload)
    if not event:
        return None
    is_request = event["kind"] == "approvalRequested"
    reply = sender(event, timeout=REQUEST_TIMEOUT if is_request else EVENT_TIMEOUT)
    if is_request:
        output = permission_output(event["request"]["id"], reply)
        if output is None and reply.get("status") != "duplicate":
            sender(event_for(payload, "requestCancelled", request=event["request"], message="请在 Claude Code 处理原生审批。"), timeout=EVENT_TIMEOUT)
        return output
    return None


def owned_hook(hook: Any) -> bool:
    if not isinstance(hook, dict) or hook.get("type") != "command" or not isinstance(hook.get("command"), str):
        return False
    try:
        parts = shlex.split(hook["command"])
        return (len(parts) == 4 and Path(parts[0]).name.startswith("python")
                and Path(parts[1]).name == "bridge.py" and parts[-2:] == ["claude-hook", OWNER_MARKER])
    except ValueError:
        return False


def remove_owned_hooks(settings: dict[str, Any]) -> dict[str, Any]:
    result = copy.deepcopy(settings)
    if "hooks" not in result:
        return result
    hooks = result["hooks"]
    if not isinstance(hooks, dict):
        raise ValueError("settings.hooks must be an object; configuration was not changed")
    for name, groups in list(hooks.items()):
        if not isinstance(groups, list):
            raise ValueError(f"hooks.{name} must be an array; configuration was not changed")
        kept = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept.append(group)
                continue
            filtered = [hook for hook in group["hooks"] if not owned_hook(hook)]
            if len(filtered) == len(group["hooks"]):
                kept.append(group)
            elif filtered:
                updated = copy.deepcopy(group)
                updated["hooks"] = filtered
                kept.append(updated)
        if kept:
            hooks[name] = kept
        elif groups:
            del hooks[name]
    if not hooks:
        result.pop("hooks", None)
    return result


def configured_settings(settings: dict[str, Any], script_path: Path, python_path: str) -> dict[str, Any]:
    result = remove_owned_hooks(settings)
    hooks = result.setdefault("hooks", {})
    command = shlex.join([python_path, str(script_path.resolve()), "claude-hook", OWNER_MARKER])
    for name in HOOK_EVENTS:
        handler = {"type": "command", "command": command, "timeout": 125 if name in ("PreToolUse", "PermissionRequest") else 3}
        hooks.setdefault(name, []).append({"hooks": [handler]})
    return result


def update_claude_settings(path: Path, install: bool, script_path: Path | None = None) -> dict[str, Any]:
    # Resolve a file symlink rather than replacing the symlink itself.
    path = path.expanduser().resolve()
    old = path.read_bytes() if path.exists() else None
    settings = json.loads(old) if old is not None else {}
    if not isinstance(settings, dict):
        raise ValueError("Claude settings must be a JSON object; configuration was not changed")
    updated = configured_settings(settings, script_path or Path(__file__), sys.executable) if install else remove_owned_hooks(settings)
    if updated == settings:
        return {"changed": False, "settings": str(path)}
    serialized = (json.dumps(updated, ensure_ascii=False, indent=2) + "\n").encode()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if (path.read_bytes() if path.exists() else None) != old:
        raise RuntimeError("Settings changed while being read; retry without overwriting concurrent edits")
    backup = None
    if old is not None:
        backup = path.with_name(path.name + ".agent-island-backup-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6])
        with backup.open("xb") as handle:
            os.chmod(backup, 0o600)
            handle.write(old)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, temporary = tempfile.mkstemp(prefix=".agent-island-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        if (path.read_bytes() if path.exists() else None) != old:
            raise RuntimeError("Settings changed while preparing update; retry")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {"changed": True, "settings": str(path), "backup": str(backup) if backup else None}


def read_input() -> dict[str, Any]:
    raw = sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("Hook input exceeds 1 MiB")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON object")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    hook = sub.add_parser("claude-hook", help="Run as a Claude Code command hook")
    hook.add_argument(OWNER_MARKER, action="store_true", help=argparse.SUPPRESS)
    for action in ("install-claude", "uninstall-claude"):
        command = sub.add_parser(action)
        command.add_argument("--settings", type=Path, default=Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "settings.json")
    emit = sub.add_parser("emit", help="Send an event on stdin and print the app reply")
    emit.add_argument("--timeout", type=float, default=EVENT_TIMEOUT)
    args = parser.parse_args(argv)
    try:
        if args.command == "claude-hook":
            result = handle_claude(read_input())
            if result is not None:
                print(json.dumps(result, ensure_ascii=False))
        elif args.command == "emit":
            print(json.dumps(exchange(read_input(), timeout=min(REQUEST_TIMEOUT, max(.01, args.timeout))), ensure_ascii=False))
        else:
            print(json.dumps(update_claude_settings(args.settings, args.command == "install-claude"), ensure_ascii=False))
        return 0
    except (OSError, ValueError, RuntimeError, TypeError, KeyError) as error:
        if args.command == "claude-hook":
            # Silence means "no decision", never "allow". Ordinary agent work
            # must remain usable even if the companion is stopped or outdated.
            return 0
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
