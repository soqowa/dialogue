import test from 'node:test';
import assert from 'node:assert/strict';
import { Codex } from '../server/codex.mjs';

class SimulatedCodex extends Codex {
  constructor() { super('/tmp'); this.calls = []; this.sent = []; }
  send(value) { this.sent.push(value); }
  async start() {}
  async request(method) {
    this.calls.push(method);
    if (method === 'thread/start') return { thread: { id: 'isolated' } };
    if (method === 'turn/start') return { turn: { id: 'turn' } };
    return {};
  }
}
const args = (signal, events) => ({ model: 'test', effort: 'low', instructions: 'plain text', prompt: 'question', signal, onEvent: e => events.push(e) });
const tick = () => new Promise(resolve => setImmediate(resolve));
test('Streaming ignores unrelated threads and reports completion only for successful turns', async () => {
  const codex = new SimulatedCodex(), events = [], controller = new AbortController();
  const job = codex.answer(args(controller.signal, events)); await tick();
  codex.emit('notification', { method: 'item/agentMessage/delta', params: { threadId: 'another', delta: 'unrelated' } });
  codex.emit('notification', { method: 'item/agentMessage/delta', params: { threadId: 'isolated', delta: 'Ответ' } });
  codex.emit('notification', { method: 'turn/completed', params: { threadId: 'isolated', turn: { status: 'completed' } } });
  await job; assert.equal(events.length, 2); assert.equal(events[1].text, 'Ответ');
  assert.equal(codex.listenerCount('notification'), 0); assert.equal(codex.listenerCount('offline'), 0);
});
test('A second turn reuses the same thread and a new Codex process resumes it', async () => {
  const session = { threadId: null };
  const complete = async codex => {
    const job = codex.answer({ ...args(new AbortController().signal, []), session }); await tick();
    codex.emit('notification', { method: 'turn/completed', params: { threadId: 'isolated', turn: { status: 'completed' } } }); await job;
  };
  const c = new SimulatedCodex(); await complete(c); await complete(c);
  assert.equal(c.calls.filter(m => m === 'thread/start').length, 1);
  const restarted = new SimulatedCodex(); await complete(restarted);
  assert.equal(restarted.calls.filter(m => m === 'thread/resume').length, 1);
  assert.equal(restarted.calls.filter(m => m === 'thread/start').length, 0);
});
test('Dynamic tool requests go only to their owning thread and return proper protocol content', async () => {
  const c = new SimulatedCodex(); let called = false;
  c.handlers.set('owner', async p => { called = true; return { text: p.arguments.id }; });
  await c.handleToolRequest({ id: 'call', method: 'item/tool/call', params: { threadId: 'owner', arguments: { id: 'value' } } });
  assert.equal(called, true); assert.equal(c.sent[0].result.contentItems[0].type, 'inputText');
  assert.equal(JSON.parse(c.sent[0].result.contentItems[0].text).text, 'value');
  called = false; await c.handleToolRequest({ id: 'other', method: 'item/tool/call', params: { threadId: 'another' } });
  assert.equal(called, false); assert.ok(c.sent[1].error);
});
test('Cancel interrupts generation and releases the waiter even without a completion event', async () => {
  const codex = new SimulatedCodex(), controller = new AbortController(), events = [];
  const job = codex.answer(args(controller.signal, events)); await tick(); controller.abort(); await job;
  assert.ok(codex.calls.includes('turn/interrupt')); assert.equal(events.length, 0); assert.equal(codex.listenerCount('notification'), 0);
});
test('A disconnected Codex rejects an active answer and cleans up its listeners', async () => {
  const codex = new SimulatedCodex(), controller = new AbortController();
  const job = codex.answer(args(controller.signal, [])); await tick();
  codex.emit('offline', 'Connection lost'); await assert.rejects(job, /Connection lost/);
  assert.equal(codex.listenerCount('notification'), 0); assert.equal(codex.listenerCount('offline'), 0);
});
