# Codex CLI integration

Uses Codex's documented lifecycle hooks and a local Unix socket. It does not read
credentials, scrape session transcripts, start a second agent, or call an AI API.
Implementation checked against the installed `codex-cli 0.163.0` and the current
[official hooks documentation](https://learn.chatgpt.com/docs/hooks).

## Connect

Start Agent Island, then explicitly install this integration:

```sh
python3 Integrations/codex/codex_bridge.py install
```

The installer merges only its own groups into `$CODEX_HOME/hooks.json` (default
`~/.codex/hooks.json`), creates a timestamped backup before changing an existing
file, and leaves `config.toml` alone. Repeated installs are idempotent. An existing
symlink is preserved. Use `--config /path/to/hooks.json` to choose another target.

In Codex, open **`/hooks`**, inspect and trust the new Agent Island definitions.
Codex requires this review; the installer never changes trust settings or passes
the hook-trust bypass flag. Restart/resume the CLI after installing if needed.
Managed policy may disable user hooks; this integration does not override it.

For reliable terminal identity, launch the CLI through:

```sh
python3 Integrations/codex/codex_bridge.py launch --
python3 Integrations/codex/codex_bridge.py launch -- -C /path/to/project
```

The launcher records the current TTY and runs `codex --no-daemon` in the same
terminal. This avoids using a shared daemon's stale terminal environment. It
passes remaining arguments without shell interpolation. Installed hooks also
work for ordinary `codex` launches, but terminal metadata from a shared daemon
may be incomplete; precise jump-back is not guaranteed in that mode.

## Capabilities

| Capability | Supported |
| --- | --- |
| Session and turn lifecycle | SessionStart, UserPromptSubmit, Stop, SessionEnd |
| Current tool activity | PreToolUse, PostToolUse |
| Interrupted turns | Interrupt, displayed as interrupted/failed |
| Permission approval | PermissionRequest, allow once / deny via the panel |
| Question answering | Return to the Codex terminal; no question-answer hook is assumed |
| Terminal identity | TTY and app identity captured by the launcher; tmux pane when available |

Permission requests wait up to 120 seconds for a matching, explicit decision.
If the app is unavailable, disconnects, or times out, the hook returns `{}` and
Codex presents its ordinary approval prompt. It **never approves by default**.
`AGENT_ISLAND_APPROVAL_TIMEOUT` can shorten the wait (1–120 seconds).
Other hooks use a short connection/ack timeout and do not affect agent output.

The protocol endpoint defaults to `${TMPDIR}/agent-island-${uid}.sock` and accepts
`AGENT_ISLAND_SOCKET` as an override. A returned approval must match the original
request id and have `status: "resolved"` with `decision: "allow"` or `"deny"`.
Expired requests produce `requestCancelled` so the panel can remove stale cards.

Subagent lifecycle hooks are intentionally not registered: their session id can
refer to the parent, so reporting their completion as a main-turn completion
would be inaccurate. Full subagent grouping is a future extension.

## Remove

```sh
python3 Integrations/codex/codex_bridge.py uninstall
```

Uninstall removes only exact hook groups recorded by this integration. It keeps
other hooks, other JSON fields, and any installed group that you subsequently
edited. Backups are retained for manual recovery.

## Verify without model calls

```sh
python3 -m unittest discover -s Tests/CodexTests -v
```

Tests cover event mapping, approval response correlation and fallback, safe
configuration merging/removal, symlinks, malformed input, and local socket IO.
They use synthetic hook payloads and temporary configuration files, not your
existing conversations or settings.
