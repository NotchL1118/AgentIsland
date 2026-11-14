"""Bridge tests use temporary fixtures; they never inspect real user settings."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "Integrations" / "bridge.py"
spec = importlib.util.spec_from_file_location("island_bridge", SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class HookTests(unittest.TestCase):
    def payload(self, hook="PreToolUse", **values):
        return {"session_id": "session-1", "cwd": "/example/project", "hook_event_name": hook,
                "tool_name": "Bash", "tool_input": {"command": "npm test"}, **values}

    def test_normal_tool_never_grants_permission(self):
        events = []
        result = bridge.handle_claude(self.payload(), lambda event, **kw: events.append(event) or {"status": "accepted"})
        self.assertIsNone(result)
        self.assertEqual(events[0]["kind"], "toolStarted")
        self.assertNotIn("request", events[0])

    def test_lifecycle_and_subagent_identity(self):
        first = bridge.claude_event(self.payload("UserPromptSubmit", prompt="Fix auth\nMore details", prompt_id="turn-7"))
        self.assertEqual(first["title"], "Fix auth")
        self.assertEqual(first["turnID"], "turn-7")
        self.assertEqual(bridge.claude_event(self.payload("Stop"))["kind"], "turnCompleted")
        sub = bridge.claude_event(self.payload(agent_id="worker-2"))
        self.assertEqual(sub["sessionID"], "session-1/worker-2")

    def test_tool_failure_is_not_turn_failure(self):
        self.assertEqual(bridge.claude_event(self.payload("PostToolUseFailure"))["kind"], "toolFinished")
        self.assertEqual(bridge.claude_event(self.payload("StopFailure"))["kind"], "turnFailed")

    def test_explicit_allow_only(self):
        def allow(event, **kw):
            self.assertEqual(kw["timeout"], 120)
            return {"status": "resolved", "requestID": event["request"]["id"], "decision": "allow"}
        result = bridge.handle_claude(self.payload("PermissionRequest"), allow)
        self.assertEqual(result, {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})

    def test_deny_does_not_add_persistent_permissions(self):
        result = bridge.permission_output("req", {"status": "resolved", "requestID": "req", "decision": "deny"})
        decision = result["hookSpecificOutput"]["decision"]
        self.assertEqual(decision["behavior"], "deny")
        self.assertNotIn("updatedPermissions", decision)

    def test_unmatched_or_unresolved_replies_never_approve(self):
        for reply in ({"status": "resolved", "decision": "allow"},
                      {"status": "resolved", "requestID": "wrong", "decision": "allow"},
                      {"status": "accepted", "requestID": "req", "decision": "allow"},
                      {"status": "resolved", "requestID": "req", "decision": "unknown"}):
            self.assertIsNone(bridge.permission_output("req", reply))

    def test_unavailable_cancels_request_and_falls_back(self):
        events = []
        result = bridge.handle_claude(self.payload("PermissionRequest"), lambda event, **kw: events.append(event) or {"status": "unavailable"})
        self.assertIsNone(result)
        self.assertEqual([e["kind"] for e in events], ["approvalRequested", "requestCancelled"])
        self.assertEqual(events[0]["request"]["id"], events[1]["request"]["id"])

    def test_duplicate_permission_does_not_cancel_original_request(self):
        events = []
        self.assertIsNone(bridge.handle_claude(self.payload("PermissionRequest"), lambda event, **kw: events.append(event) or {"status": "duplicate"}))
        self.assertEqual([event["kind"] for event in events], ["approvalRequested"])

    def question_payload(self, multiple=False):
        return self.payload(tool_name="AskUserQuestion", tool_use_id="tool-1", tool_input={
            "questions": [{"question": "Which DB?", "multiSelect": multiple, "options": [{"label": "SQLite", "description": "Local"}]},
                          {"question": "Which tests?", "options": []}], "metadata": "keep-me"})

    def test_question_answers_preserve_entire_tool_input(self):
        original = self.question_payload()
        before = copy.deepcopy(original)
        events = []
        def answer(event, **kw):
            events.append(event)
            return {"status": "resolved", "requestID": event["request"]["id"], "decision": "answer", "answer": "SQLite" if len(events) == 1 else "Regression"}
        output = bridge.handle_claude(original, answer)
        updated = output["hookSpecificOutput"]["updatedInput"]
        self.assertEqual(updated["questions"], original["tool_input"]["questions"])
        self.assertEqual(updated["metadata"], "keep-me")
        self.assertEqual(updated["answers"], {"Which DB?": "SQLite", "Which tests?": "Regression"})
        self.assertEqual(original, before)
        self.assertNotEqual(events[0]["request"]["id"], events[1]["request"]["id"])

    def test_question_partial_failure_does_not_rewrite_input(self):
        events = []
        def answer(event, **kw):
            events.append(event)
            if len(events) == 1:
                return {"status": "resolved", "requestID": event["request"]["id"], "decision": "answer", "answer": "SQLite"}
            return {"status": "unavailable"}
        self.assertIsNone(bridge.handle_claude(self.question_payload(), answer))
        self.assertEqual(events[-1]["kind"], "requestCancelled")

    def test_duplicate_question_does_not_cancel_original_request(self):
        events = []
        self.assertIsNone(bridge.handle_claude(self.question_payload(), lambda event, **kw: events.append(event) or {"status": "duplicate"}))
        self.assertEqual([event["kind"] for event in events], ["questionRequested"])

    def test_multiselect_uses_original_ui(self):
        events = []
        self.assertIsNone(bridge.handle_claude(self.question_payload(True), lambda event, **kw: events.append(event) or {"status": "accepted"}))
        self.assertEqual(events[0]["kind"], "questionRequested")
        self.assertNotIn("request", events[0])

    def test_interactive_tools_do_not_receive_bare_allow(self):
        for name in ("AskUserQuestion", "ExitPlanMode"):
            event = bridge.claude_event(self.payload("PermissionRequest", tool_name=name))
            self.assertEqual(event["kind"], "questionRequested")
            self.assertNotIn("request", event)

    def test_missing_identity_is_rejected(self):
        with self.assertRaises(ValueError):
            bridge.claude_event({"hook_event_name": "Stop"})

    def test_terminal_metadata_is_not_invented(self):
        with patch.dict(os.environ, {"TERM_PROGRAM": "Apple_Terminal", "AGENT_ISLAND_TTY": "/dev/ttys002", "TMUX_PANE": "%3"}, clear=True):
            value = bridge.terminal_metadata()
            self.assertEqual(value["appBundleID"], "com.apple.Terminal")
            self.assertEqual(value["tty"], "/dev/ttys002")
            self.assertEqual(value["tmuxPane"], "%3")


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ai-settings-")
        self.path = Path(self.temp.name) / "settings.json"
        self.original = {"model": "keep-model", "permissions": {"deny": ["Bash(sudo *)"]}, "hooks": {
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo user-hook"}]}],
            "Stop": [{"hooks": [{"type": "command", "command": "printf 'claude-hook --agent-island-owned-v1'"}]}]}}
        self.path.write_text(json.dumps(self.original, indent=4))

    def tearDown(self): self.temp.cleanup()

    def test_install_is_idempotent_and_preserves_user_config(self):
        first = bridge.update_claude_settings(self.path, True)
        second = bridge.update_claude_settings(self.path, True)
        self.assertTrue(first["changed"])
        self.assertFalse(second["changed"])
        contents = json.loads(self.path.read_text())
        self.assertEqual(contents["model"], self.original["model"])
        self.assertEqual(contents["permissions"], self.original["permissions"])
        self.assertEqual(contents["hooks"]["PreToolUse"][0], self.original["hooks"]["PreToolUse"][0])
        self.assertEqual(json.loads(Path(first["backup"]).read_text()), self.original)

    def test_uninstall_removes_only_owned_entries_even_in_shared_group(self):
        bridge.update_claude_settings(self.path, True)
        contents = json.loads(self.path.read_text())
        contents["hooks"]["SessionStart"][0]["hooks"].append({"type": "command", "command": "user-added-later"})
        self.path.write_text(json.dumps(contents))
        bridge.update_claude_settings(self.path, False)
        updated = json.loads(self.path.read_text())
        self.assertEqual(updated["hooks"]["PreToolUse"], self.original["hooks"]["PreToolUse"])
        self.assertEqual(updated["hooks"]["Stop"], self.original["hooks"]["Stop"])
        self.assertEqual(updated["hooks"]["SessionStart"][0]["hooks"], [{"type": "command", "command": "user-added-later"}])

    def test_symlink_is_preserved(self):
        link = Path(self.temp.name) / "linked-settings.json"
        link.symlink_to(self.path)
        bridge.update_claude_settings(link, True)
        self.assertTrue(link.is_symlink())
        self.assertIn("SessionStart", json.loads(self.path.read_text())["hooks"])

    def test_invalid_settings_are_not_overwritten(self):
        self.path.write_text('{ broken JSON')
        with self.assertRaises(ValueError): bridge.update_claude_settings(self.path, True)
        self.assertEqual(self.path.read_text(), '{ broken JSON')

    def test_command_quoting_handles_shell_metacharacters(self):
        path = Path(self.temp.name) / 'space and $(touch PWNED)' / 'bridge.py'
        configured = bridge.configured_settings({}, path, '/path with spaces/python3')
        command = configured["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertEqual(bridge.shlex.split(command), ['/path with spaces/python3', str(path.resolve()), 'claude-hook', bridge.OWNER_MARKER])

    def test_non_owned_marker_text_is_preserved(self):
        self.assertFalse(bridge.owned_hook({"type": "command", "command": "echo claude-hook --agent-island-owned-v1"}))


class SocketTests(unittest.TestCase):
    def test_missing_socket(self):
        self.assertEqual(bridge.exchange({"id": "missing"}, path="/tmp/agent-island-test-nonexistent.sock"), {"status": "unavailable"})

    def test_socket_roundtrip(self):
        with tempfile.TemporaryDirectory(prefix="ai-sock-", dir="/tmp") as directory:
            path = str(Path(directory) / "s")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)
            received = []
            def serve():
                with server.accept()[0] as client:
                    packet = client.makefile("rb").readline()
                    received.append(json.loads(packet))
                    client.sendall(b'{"status":"accepted"}\n')
            thread = threading.Thread(target=serve)
            thread.start()
            try:
                self.assertEqual(bridge.exchange({"message": "中文"}, path=path), {"status": "accepted"})
                thread.join(2)
                self.assertEqual(received, [{"message": "中文"}])
            finally:
                server.close()

    def test_hook_process_stays_silent_without_app(self):
        payload = {"session_id": "test", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": {"command": "echo test"}}
        result = subprocess.run([sys.executable, str(SCRIPT), "claude-hook"], input=json.dumps(payload), capture_output=True, text=True,
                                env={**os.environ, "AGENT_ISLAND_SOCKET": "/tmp/agent-island-test-nonexistent.sock"}, timeout=3)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
