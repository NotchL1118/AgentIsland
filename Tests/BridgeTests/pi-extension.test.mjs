// No model calls or user configuration: exercise the actual extension handlers
// against a temporary socket and a minimal in-memory Pi host.
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import agentIsland from '../../Integrations/pi-extension.ts';

const directory = await mkdtemp('/tmp/ai-pi-');
const socketPath = join(directory, 'socket');
process.env.AGENT_ISLAND_SOCKET = socketPath;
process.env.AGENT_ISLAND_TTY = '/dev/ttys-test';
process.env.TERM_PROGRAM = 'Apple_Terminal';
const handlers = new Map();
const flags = new Map();
const events = [];
let approval = 'allow';
let fallbackCalls = 0;
const server = createServer(socket => {
  let data = '';
  socket.on('data', bytes => {
    data += bytes;
    if (!data.includes('\n')) return;
    const event = JSON.parse(data.split('\n')[0]);
    events.push(event);
    const reply = event.kind === 'approvalRequested'
      ? approval === 'duplicate' ? { status: 'duplicate', requestID: event.request.id }
        : { status: 'resolved', requestID: approval === 'wrong-id' ? 'wrong' : event.request.id, decision: approval }
      : { status: 'accepted' };
    socket.end(JSON.stringify(reply) + '\n');
  });
});
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
const ctx = {
  cwd: '/example/project', hasUI: true, mode: 'tui', signal: undefined,
  sessionManager: { getSessionId: () => 'pi-session', getSessionName: () => undefined },
  ui: { confirm: async () => { fallbackCalls++; return false; } },
};
const pi = { on: (name, handler) => handlers.set(name, handler), registerFlag: (name, options) => flags.set(name, options.default), getFlag: name => flags.get(name) };
// Status events are fire-and-forget; give the socket a moment to deliver them.
const emit = async (name, event = {}) => {
  const result = await handlers.get(name)(event, ctx);
  await new Promise(resolve => setTimeout(resolve, 25));
  return result;
};
try {
  agentIsland(pi);
  assert.equal(flags.get('island-approve-tools'), false);
  await emit('session_start');
  await emit('before_agent_start', { messageType: 'user', prompt: 'Fix auth' });
  await emit('agent_start');
  const turn = events.at(-1).turnID;
  await emit('tool_execution_start', { toolName: 'bash', toolCallId: 'call-1' });
  assert.equal(await emit('tool_call', { toolName: 'bash', toolCallId: 'call-1', input: { command: 'npm test' } }), undefined);
  assert.equal(events.some(event => event.kind === 'approvalRequested'), false, 'passive default does not add approvals');

  flags.set('island-approve-tools', true);
  assert.equal(await emit('tool_call', { toolName: 'bash', toolCallId: 'call-2', input: { command: 'npm test' } }), undefined);
  assert.equal(events.at(-1).kind, 'approvalRequested');
  approval = 'deny';
  assert.equal((await emit('tool_call', { toolName: 'write', toolCallId: 'call-3', input: { path: 'a.ts' } })).block, true);
  approval = 'wrong-id';
  assert.equal((await emit('tool_call', { toolName: 'edit', toolCallId: 'call-4', input: { path: 'a.ts' } })).block, true);
  assert.equal(fallbackCalls, 1, 'wrong reply identity uses fallback confirmation');
  assert.equal(events.at(-1).kind, 'requestCancelled');
  approval = 'duplicate';
  const beforeDuplicate = events.length;
  assert.equal((await emit('tool_call', { toolName: 'edit', toolCallId: 'call-duplicate', input: { path: 'a.ts' } })).block, true);
  assert.equal(events.length, beforeDuplicate + 1, 'duplicate request must not cancel its original owner');
  assert.equal(events.at(-1).kind, 'approvalRequested');

  await emit('agent_end', { messages: [{ role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: 'Done.' }] }] });
  assert.equal(events.some(event => event.kind === 'turnCompleted'), false, 'agent_end is not a completion signal');
  await emit('agent_start');
  assert.equal(events.at(-1).turnID, turn, 'automatic continuation belongs to the active run');
  await emit('agent_settled', { aborted: false });
  assert.equal(events.at(-1).kind, 'turnCompleted');
  assert.equal(events.at(-1).message, 'Done.');
  const completedCount = events.length;
  await emit('agent_settled', { aborted: false });
  assert.equal(events.length, completedCount, 'settled completion is emitted once');

  await emit('agent_start');
  assert.notEqual(events.at(-1).turnID, turn);
  await emit('ui_prompt_start', { kind: 'select', title: 'Which DB?' });
  assert.equal(events.at(-1).kind, 'questionRequested');
  assert.equal(events.at(-1).request, undefined, 'external UI questions cannot pretend to accept answers');
  await emit('ui_prompt_end');
  assert.equal(events.at(-1).kind, 'toolFinished');
  await emit('agent_settled', { aborted: true });
  assert.equal(events.at(-1).kind, 'turnFailed');
  await emit('session_shutdown');
  assert.equal(events.at(-1).kind, 'sessionEnded');
  assert.equal(events[0].terminal.tty, '/dev/ttys-test');
  await new Promise(resolve => server.close(resolve));

  ctx.hasUI = false;
  const blocked = await emit('tool_call', { toolName: 'bash', toolCallId: 'offline', input: { command: 'npm test' } });
  assert.equal(blocked.block, true, 'offline non-interactive mode never auto-approves');

  // A panel that accepts connections but never replies must not slow the agent loop.
  const hung = createServer(() => {});
  await new Promise(resolve => hung.listen(socketPath, resolve));
  const started = performance.now();
  await handlers.get('tool_execution_start')({ toolName: 'bash', toolCallId: 'slow' }, ctx);
  await handlers.get('tool_execution_end')({ toolName: 'bash', toolCallId: 'slow', isError: false }, ctx);
  assert.ok(performance.now() - started < 50, 'status handlers return without waiting for the panel');
  hung.close();
  console.log('Pi extension: lifecycle, passive mode, approval identity, rejection, UI fallback, cancellation, and completion checks passed.');
} finally {
  if (server.listening) await new Promise(resolve => server.close(resolve));
  await rm(directory, { recursive: true, force: true });
}
