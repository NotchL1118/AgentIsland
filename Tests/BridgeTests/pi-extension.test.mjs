// No model calls or user configuration: exercise the actual extension handlers
// against temporary sockets and a minimal in-memory Pi host.
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import agentIsland, { sendEvent } from '../../Integrations/pi-extension.ts';

const directory = await mkdtemp('/tmp/ai-pi-');
const socketPath = join(directory, 'socket');
process.env.AGENT_ISLAND_SOCKET = socketPath;
process.env.AGENT_ISLAND_TTY = '/dev/ttys-test';
process.env.TERM_PROGRAM = 'Apple_Terminal';
const handlers = new Map();
const flags = new Map();
const events = [];
const connections = new Set();
let fallbackCalls = 0;
const server = createServer(socket => {
  connections.add(socket);
  socket.once('close', () => connections.delete(socket));
  socket.on('error', () => {});
  let data = '';
  socket.on('data', bytes => {
    data += bytes;
    if (!data.includes('\n')) return;
    const event = JSON.parse(data.split('\n')[0]);
    events.push(event);
    // Even an old panel sending a decision cannot control the agent anymore.
    socket.end(JSON.stringify({ status: 'resolved', decision: 'deny', requestID: 'legacy' }) + '\n');
  });
});
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
const ctx = {
  cwd: '/example/project', hasUI: true, mode: 'tui', signal: undefined,
  sessionManager: { getSessionId: () => 'pi-session', getSessionName: () => undefined },
  ui: { confirm: async () => { fallbackCalls++; throw new Error('Observation must not request confirmation'); } },
};
const pi = { on: (name, handler) => handlers.set(name, handler), registerFlag: (name, options) => flags.set(name, options.default), getFlag: name => flags.get(name) };
const waitFor = async predicate => {
  const deadline = performance.now() + 2000;
  while (!predicate()) {
    assert.ok(performance.now() < deadline, 'expected event was delivered');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
};
const emit = async (name, event = {}, expectedKind) => {
  const before = events.length;
  const result = handlers.get(name)?.(event, ctx);
  assert.equal(result, undefined, `${name} returns synchronously without an execution decision`);
  if (expectedKind) {
    await waitFor(() => events.length > before);
    assert.equal(events.at(-1).kind, expectedKind);
  }
};
let hung;
try {
  agentIsland(pi);
  assert.equal(flags.get('island-approve-tools'), false);
  assert.equal(handlers.has('tool_call'), false, 'observation never intercepts tool approval');
  await emit('session_start', {}, 'sessionStarted');
  await emit('before_agent_start', { messageType: 'user', prompt: 'Fix auth' });
  await emit('agent_start', {}, 'turnStarted');
  const turn = events.at(-1).turnID;
  await emit('tool_execution_start', { toolName: 'bash', toolCallId: 'call-1' }, 'toolStarted');
  await emit('tool_execution_end', { toolName: 'bash', toolCallId: 'call-1', isError: false }, 'toolFinished');

  // Old launch commands continue to work, but the old flag cannot add a gate.
  flags.set('island-approve-tools', true);
  for (const toolName of ['bash', 'write', 'edit']) {
    await emit('tool_call', { toolName, toolCallId: toolName, input: { command: 'npm test', path: 'a.ts' } });
  }
  assert.equal(fallbackCalls, 0);
  assert.equal(events.some(event => event.kind === 'approvalRequested'), false);

  await emit('agent_end', { messages: [{ role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: 'Done.' }] }] });
  assert.equal(events.some(event => event.kind === 'turnCompleted'), false, 'agent_end is not a completion signal');
  await emit('agent_start', {}, 'turnStarted');
  assert.equal(events.at(-1).turnID, turn, 'automatic continuation belongs to the active run');
  await emit('agent_settled', { aborted: false }, 'turnCompleted');
  assert.equal(events.at(-1).message, 'Done.');
  const completedCount = events.length;
  await emit('agent_settled', { aborted: false });
  assert.equal(events.length, completedCount, 'settled completion is emitted once');

  await emit('agent_start', {}, 'turnStarted');
  assert.notEqual(events.at(-1).turnID, turn);
  await emit('ui_prompt_start', { kind: 'select', title: 'Which DB?' }, 'questionRequested');
  assert.equal(events.at(-1).request, undefined, 'native questions remain in Pi');
  await emit('ui_prompt_end', {}, 'toolFinished');
  await emit('agent_settled', { aborted: true }, 'turnFailed');
  await emit('session_shutdown', {}, 'sessionEnded');
  assert.equal(events[0].terminal.tty, '/dev/ttys-test');
  for (const socket of connections) socket.destroy();
  await new Promise(resolve => server.close(resolve));

  // An unavailable panel, no UI, and an aborted context cannot add a tool gate.
  ctx.hasUI = false;
  ctx.signal = AbortSignal.abort();
  await emit('tool_call', { toolName: 'bash', toolCallId: 'offline', input: { command: 'npm test' } });
  await emit('tool_execution_start', { toolName: 'bash', toolCallId: 'offline' });
  await emit('session_shutdown');
  assert.equal(fallbackCalls, 0);

  // A panel that never replies must not be awaited, even during shutdown.
  hung = createServer(socket => {
    connections.add(socket);
    socket.once('close', () => connections.delete(socket));
    socket.on('error', () => {});
    socket.resume();
  });
  await new Promise(resolve => hung.listen(socketPath, resolve));
  await emit('tool_execution_start', { toolName: 'bash', toolCallId: 'slow' });
  await emit('tool_execution_end', { toolName: 'bash', toolCallId: 'slow', isError: false });
  await emit('session_shutdown');
  await new Promise(resolve => setTimeout(resolve, 30));
  await waitFor(() => connections.size === 0);

  // Malformed or oversized observations are dropped without reaching Pi.
  const cyclic = {}; cyclic.self = cyclic;
  assert.doesNotThrow(() => sendEvent(cyclic));
  assert.doesNotThrow(() => sendEvent({ value: 1n }));
  assert.equal(sendEvent({ message: 'x'.repeat(1024 * 1024) }), undefined);
  assert.equal(events.some(event => event.request), false, 'no interactive requests are emitted');
  console.log('Pi extension: passive lifecycle, legacy flag compatibility, native prompts, offline operation, ignored decisions, and nonblocking shutdown passed.');
} finally {
  for (const socket of connections) socket.destroy();
  if (server.listening) await new Promise(resolve => server.close(resolve));
  if (hung?.listening) await new Promise(resolve => hung.close(resolve));
  await rm(directory, { recursive: true, force: true });
}
