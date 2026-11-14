import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Integrations/codex/codex_bridge.py"
spec = importlib.util.spec_from_file_location("codex_bridge", SCRIPT)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def payload(event="UserPromptSubmit", **fields):
    return {"hook_event_name": event, "session_id": "session-1", "turn_id": "turn-1", "cwd": "/projects/example", **fields}


class MappingTests(unittest.TestCase):
    def test_supported_lifecycle_mapping(self):
        for source, target in bridge.HOOKS.items():
            event = bridge.event_from_hook(payload(source), {}, now=123)
            self.assertEqual(event["kind"], target)
            self.assertEqual(event["sessionID"], "session-1")
            self.assertEqual(event["turnID"], "turn-1")
            self.assertEqual(event["provider"], "codex")
            self.assertEqual(event["timestamp"], 123)

    def test_prompt_title_and_stop_summary(self):
        event = bridge.event_from_hook(payload(prompt="修复登录\n额外要求"), {})
        self.assertEqual(event["title"], "修复登录")
        event = bridge.event_from_hook(payload("Stop", last_assistant_message="所有测试通过"), {})
        self.assertEqual(event["message"], "所有测试通过")

    def test_missing_identity_and_unknown_events_are_ignored(self):
        self.assertIsNone(bridge.event_from_hook({"hook_event_name": "Stop"}, {}))
        self.assertIsNone(bridge.event_from_hook(payload("SubagentStop"), {}))
        self.assertIsNone(bridge.event_from_hook([1, 2], {}))

    def test_terminal_wrapper_metadata_is_preserved(self):
        metadata = {"appBundleID": "com.apple.Terminal", "tty": "/dev/ttys004", "tmuxPane": "%8"}
        event = bridge.event_from_hook(payload(), {"AGENT_ISLAND_TERMINAL": json.dumps(metadata)})
        self.assertEqual(event["terminal"], metadata)

    def test_iterm_opaque_session_is_not_mislabeled_as_tab(self):
        metadata = bridge.terminal_metadata({"TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:opaque"})
        self.assertEqual(metadata, {"appBundleID": "com.googlecode.iterm2"})

    def test_no_turn_id_is_fabricated(self):
        event = bridge.event_from_hook({"hook_event_name": "SessionStart", "session_id": "s"}, {})
        self.assertNotIn("turnID", event)

    def test_compaction_does_not_reset_running_session_or_title(self):
        event = bridge.event_from_hook(payload("SessionStart", source="compact"), {})
        self.assertEqual(event["kind"], "heartbeat")
        self.assertNotIn("title", event)


class ApprovalTests(unittest.TestCase):
    def test_allow_uses_documented_permission_request_shape(self):
        def transport(event, **kwargs):
            self.assertEqual(event["request"]["detail"], "npm test")
            return {"status": "resolved", "requestID": event["request"]["id"], "decision": "allow"}
        result = bridge.run_hook(payload("PermissionRequest", tool_name="Bash", tool_input={"command": "npm test"}), environ={}, transport=transport)
        self.assertEqual(result, {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})

    def test_deny_is_not_translated_to_allow(self):
        def transport(event, **kwargs):
            return {"status": "resolved", "requestID": event["request"]["id"], "decision": "deny"}
        output = bridge.run_hook(payload("PermissionRequest"), environ={}, transport=transport)
        self.assertEqual(output["hookSpecificOutput"]["decision"]["behavior"], "deny")

    def test_timeout_returns_control_to_native_approval_and_cancels_card(self):
        events = []
        def transport(event, **kwargs):
            events.append(event)
            return None
        result = bridge.run_hook(payload("PermissionRequest"), environ={}, transport=transport)
        self.assertEqual(result, {})
        self.assertEqual([event["kind"] for event in events], ["approvalRequested", "requestCancelled"])
        self.assertEqual(events[0]["request"]["id"], events[1]["request"]["id"])

    def test_mismatched_or_unconfirmed_reply_never_allows(self):
        for reply in ({"status": "accepted", "requestID": "r", "decision": "allow"}, {"status": "resolved", "requestID": "wrong", "decision": "allow"}, {"status": "resolved", "requestID": "r", "decision": "answer"}, None):
            self.assertEqual(bridge.permission_output(reply, "r"), {})

    def test_status_hook_never_returns_server_instructions(self):
        self.assertEqual(bridge.run_hook(payload(), environ={}, transport=lambda *a, **kw: {"status": "resolved", "decision": "allow", "additionalContext": "ignored"}), {})


class ConfigurationTests(unittest.TestCase):
    def test_merge_preserves_user_hooks_and_uninstall_only_ours(self):
        original = {"description": "mine", "custom": 2, "hooks": {"Stop": [{"matcher": "*", "hooks": [{"type": "command", "command": "echo custom"}]}]}}
        groups = bridge.generated_groups(script="/path with space/bridge.py", interpreter="/usr/bin/python3")
        merged = bridge.merge_config(original, groups)
        self.assertEqual(merged["hooks"]["Stop"][0], original["hooks"]["Stop"][0])
        self.assertEqual(bridge.merge_config(merged, groups, groups), merged)
        self.assertEqual(bridge.remove_owned(merged, groups), original)
        self.assertIn("'/path with space/bridge.py'", groups["Stop"]["hooks"][0]["command"])

    def test_user_edit_of_installed_hook_is_preserved(self):
        groups = bridge.generated_groups()
        config = bridge.merge_config({}, groups)
        config["hooks"]["Stop"][0]["hooks"][0]["command"] += " --user-edited"
        result = bridge.remove_owned(config, groups)
        self.assertIn("--user-edited", result["hooks"]["Stop"][0]["hooks"][0]["command"])

    def test_install_backup_idempotence_and_symlink_preservation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "actual.json"
            original = b'{"description":"my settings","hooks":{"Stop":[]}}\n'
            path.write_bytes(original)
            alias = Path(directory) / "hooks.json"
            alias.symlink_to(path)
            first = bridge.change_installation(alias, True)
            self.assertTrue(first["changed"])
            self.assertEqual(Path(first["backup"]).read_bytes(), original)
            self.assertTrue(alias.is_symlink())
            second = bridge.change_installation(alias, True)
            self.assertFalse(second["changed"])
            self.assertIsNone(second["backup"])
            third = bridge.change_installation(alias, False)
            self.assertTrue(third["changed"])
            self.assertEqual(json.loads(path.read_text()), {"description": "my settings"})
            self.assertTrue(alias.is_symlink())

    def test_invalid_config_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hooks.json"
            path.write_text('{"hooks": ["bad"]}')
            with self.assertRaises(ValueError):
                bridge.change_installation(path, True)
            self.assertEqual(path.read_text(), '{"hooks": ["bad"]}')

    def test_uninstall_without_registry_does_not_guess_ownership(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hooks.json"
            original = bridge.merge_config({}, bridge.generated_groups())
            path.write_text(json.dumps(original))
            self.assertFalse(bridge.change_installation(path, False)["changed"])
            self.assertEqual(json.loads(path.read_text()), original)

    def test_session_end_and_interrupt_respect_three_second_limit(self):
        groups = bridge.generated_groups()
        for name in ("SessionEnd", "Interrupt"):
            self.assertLessEqual(groups[name]["hooks"][0]["timeout"], 3)


class SocketTests(unittest.TestCase):
    def test_absent_socket_fails_safely(self):
        self.assertIsNone(bridge.send_event({"id": "test"}, path="/tmp/agent-island-codex-test-missing.sock"))

    def test_regular_file_is_not_connected(self):
        with tempfile.NamedTemporaryFile() as file:
            self.assertIsNone(bridge.send_event({}, path=file.name))

    def test_socket_roundtrip(self):
        with tempfile.TemporaryDirectory(prefix="ai-", dir="/tmp") as directory:
            path = str(Path(directory) / "test.sock")
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(path)
            server.listen(1)
            received = []
            def serve():
                connection, _ = server.accept()
                with connection:
                    received.append(json.loads(connection.makefile("rb").readline()))
                    connection.sendall(b'{"status":"accepted"}\n')
            thread = threading.Thread(target=serve)
            thread.start()
            try:
                reply = bridge.send_event({"id": "event-one"}, path=path)
                thread.join(timeout=2)
                self.assertEqual(reply, {"status": "accepted"})
                self.assertEqual(received, [{"id": "event-one"}])
            finally:
                server.close()


if __name__ == "__main__":
    unittest.main()
