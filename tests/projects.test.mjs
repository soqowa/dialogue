import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { EventEmitter } from 'node:events';
import { WebSocket } from 'ws';
import { Projects } from '../server/projects.mjs';
import { Knowledge } from '../server/knowledge.mjs';
import { Sessions } from '../server/sessions.mjs';
import { AgentTools } from '../server/agent-tools.mjs';
import { connectConversation } from '../server/live.mjs';

async function fixture(run) {
  const folder = await mkdtemp(path.join(os.tmpdir(), 'dialog-projects-'));
  try { const projects = new Projects(folder); await projects.load(); await run(projects, folder); await projects.flush(); }
  finally { await rm(folder, { recursive: true, force: true }); }
}
test('Existing data becomes General without losing files, instructions, sessions or Codex threads', async () => {
  const folder = await mkdtemp(path.join(os.tmpdir(), 'dialog-project-migration-'));
  try {
    const knowledge = new Knowledge(folder); await knowledge.load(); await knowledge.add('old.md', 'Старый материал');
    const sessions = new Sessions(path.join(folder, 'sessions')); await sessions.load();
    const session = await sessions.create(); session.threadId = 'existing-codex-thread'; await sessions.save(session);
    const projects = new Projects(folder); await projects.load();
    await projects.initializeGeneral({ style: 'Моя манера', strict: true, model: 'old-model', effort: 'low', sessionID: session.id });
    await projects.initializeGeneral({ style: 'Do not overwrite' });
    const general = projects.get(); assert.equal(general.preferences.style, 'Моя манера');
    assert.equal(general.preferences.lastSessionId, session.id); assert.equal(general.sessions.get(session.id).threadId, 'existing-codex-thread');
    assert.equal(general.knowledge.documents.length, 1);
    const restored = new Projects(folder); await restored.load();
    assert.equal(restored.get().preferences.style, 'Моя манера'); assert.equal(restored.get().sessions.get(session.id).threadId, 'existing-codex-thread');
    await projects.flush(); await restored.flush();
  } finally { await rm(folder, { recursive: true, force: true }); }
});

test('New projects snapshot General files and settings, start with empty history, and never sync later changes', async () => fixture(async (projects, folder) => {
  const general = projects.get(); await general.knowledge.add('folder/notes.md', 'Исходный конспект');
  await general.updatePreferences({ style: 'Кратко', strict: true, model: 'gpt-test', effort: 'low' });
  const old = await general.sessions.create(); old.threadId = 'general-thread'; await general.sessions.save(old); await general.rememberSession(old);
  const created = await projects.create('Проект А'), child = projects.get(created.id);
  assert.equal(child.preferences.style, 'Кратко'); assert.equal(child.preferences.model, 'gpt-test');
  assert.equal(child.preferences.lastSessionId, null); assert.equal(child.sessions.list().length, 0);
  assert.equal(child.knowledge.read('folder/notes.md').text, 'Исходный конспект');
  assert.notEqual(child.knowledge.documents, general.knowledge.documents); assert.notEqual(child.knowledge.documents[0], general.knowledge.documents[0]);
  await general.knowledge.add('folder/notes.md', 'Изменённое общее'); await general.updatePreferences({ style: 'Подробно' });
  assert.equal(child.preferences.style, 'Кратко'); assert.equal(child.knowledge.read('folder/notes.md').text, 'Исходный конспект');
  await child.updatePreferences({ style: 'Только примеры' }); await child.knowledge.remove(child.knowledge.list()[0].id);
  assert.equal(general.preferences.style, 'Подробно'); assert.equal(general.knowledge.read('folder/notes.md').text, 'Изменённое общее');
  const second = projects.get((await projects.create('Проект Б')).id);
  assert.equal(second.preferences.style, 'Подробно'); assert.equal(second.knowledge.read('folder/notes.md').text, 'Изменённое общее');
  const fresh = await child.sessions.create(); assert.equal(fresh.threadId, null);
  await child.rememberSession(fresh); await projects.flush();
  const restored = new Projects(folder); await restored.load();
  assert.equal(restored.get(child.id).preferences.style, 'Только примеры'); assert.equal(restored.get(child.id).knowledge.documents.length, 0);
  assert.equal(restored.get(child.id).preferences.lastSessionId, fresh.id);
  assert.throws(() => restored.get(child.id).sessions.get(old.id), /не найден/);
  const tools = new AgentTools(child.knowledge, child.sessions, fresh);
  await assert.rejects(tools.call('read_material', { documentId: general.knowledge.list()[0].id }), /не найден/);
  await restored.flush();
}));

test('General cannot be renamed, names are validated, and stale settings cannot overwrite a newer snapshot', async () => fixture(async projects => {
  await assert.rejects(projects.rename('general', 'Другое'), /нельзя/);
  await assert.rejects(projects.create('общее'), /уже есть/); await assert.rejects(projects.create('   '), /Название/);
  assert.throws(() => projects.get('../../other'), /не найден/);
  const results = await Promise.allSettled([projects.create('А'), projects.create('А')]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  const child = results.find(r => r.status === 'fulfilled').value;
  await projects.rename(child.id, 'Переименован'); assert.equal(projects.get(child.id).metadata.name, 'Переименован');
  const general = projects.get();
  await general.updatePreferences({ clientId: 'client', revision: 3, style: 'Новое' });
  await general.updatePreferences({ clientId: 'client', revision: 2, style: 'Опоздавшее старое' });
  assert.equal(projects.get((await projects.create('Свежий')).id).preferences.style, 'Новое');
}));

class Socket extends EventEmitter {
  readyState = WebSocket.OPEN;
  events = [];
  send(raw) { this.events.push(JSON.parse(raw)); }
  receive(event) { this.emit('message', Buffer.from(JSON.stringify(event))); }
}
class Speech extends EventEmitter {
  state = 'ready'; queue = [];
  snapshot() { return { speech: 'ready' }; }
  clear(owner) { this.queue = this.queue.filter(j => j.owner !== owner); }
  enqueue(job) { this.queue.push(job); }
}
const tick = () => new Promise(resolve => setImmediate(resolve));
async function until(test) { for (let i = 0; i < 100; i++) { if (test()) return; await new Promise(r => setTimeout(r, 2)); } assert.fail('Timed out'); }
test('Switching projects cancels generation, rejects late audio, scopes tools, and restores the correct conversation', async () => fixture(async projects => {
  const general = projects.get(); await general.updatePreferences({ style: 'Стиль Общего' });
  const child = projects.get((await projects.create('Рабочий')).id); await child.updatePreferences({ style: 'Стиль проекта' });
  await general.knowledge.add('general-only.md', 'Только Общее'); await child.knowledge.add('child-only.md', 'Только проект');
  class Codex extends EventEmitter {
    requests = [];
    async answer(args) {
      this.requests.push(args); args.session.threadId = 'thread-' + args.session.id; await args.onThread();
      await args.onAccepted();
      if (this.requests.length === 1) {
        if (!args.signal.aborted) await new Promise(resolve => args.signal.addEventListener('abort', resolve, { once: true }));
      }
      else args.onEvent({ type: 'answer.done', text: 'Ответ проекта', firstToken: 1 });
    }
  }
  const ws = new Socket(), speech = new Speech(), codex = new Codex(), jobs = new Map();
  const status = { connected: true, models: [{ model: 'gpt-test', supportedReasoningEfforts: [{ reasoningEffort: 'low' }] }] };
  connectConversation(ws, { projects, speech, codex, jobs, sessionClients: new Map(), getStatus: async () => status, cachedStatus: () => status });
  ws.receive({ type: 'project.open', id: 'general' }); await until(() => ws.events.some(e => e.type === 'project.snapshot'));
  const oldSession = ws.events.find(e => e.type === 'project.snapshot').session.id;
  ws.receive({ type: 'settings', projectId: 'general', style: 'Стиль Общего', model: 'gpt-test', auto: false });
  ws.receive({ type: 'audio', projectId: 'general', sessionId: oldSession, id: 'old', source: 'remote', audio: 'AA==', final: true });
  const oldOwner = speech.queue[0].owner;
  ws.receive({ type: 'question', projectId: 'general', text: 'Первый' }); await until(() => codex.requests.length === 1);
  ws.events = []; ws.receive({ type: 'project.open', id: child.id });
  await until(() => ws.events.some(e => e.type === 'project.snapshot' && e.project.id === child.id));
  assert.equal(codex.requests[0].signal.aborted, true);
  const childSession = ws.events.find(e => e.type === 'project.snapshot').session;
  assert.equal(childSession.transcript.length, 0); assert.equal(childSession.exchanges.length, 0);
  speech.emit('transcript', { owner: oldOwner, id: 'late', source: 'remote', text: 'Чужая реплика', final: true, time: 1 });
  ws.receive({ type: 'audio', projectId: 'general', sessionId: oldSession, id: 'wrong', source: 'remote', audio: 'AA==', final: true });
  assert.equal(speech.queue.length, 0); assert.equal(child.sessions.get(childSession.id).transcript.length, 0);
  ws.receive({ type: 'question', projectId: child.id, text: 'Второй' });
  await until(() => ws.events.some(e => e.type === 'answer.done'));
  const request = codex.requests[1]; assert.match(request.instructions, /Стиль проекта/); assert.equal(request.cwd, child.work);
  const catalog = await request.toolHandler('list_materials', {}); assert.deepEqual(catalog.materials.map(m => m.name), ['child-only.md']);
  await assert.rejects(request.toolHandler('read_material', { documentId: general.knowledge.list()[0].id }), /не найден/);
  const newAnswer = ws.events.find(e => e.type === 'answer.done'); assert.equal(newAnswer.projectId, child.id);
  ws.events = []; ws.receive({ type: 'project.open', id: 'general' });
  await until(() => ws.events.some(e => e.type === 'project.snapshot'));
  assert.equal(ws.events.find(e => e.type === 'project.snapshot').session.id, oldSession);
  assert.equal(general.sessions.get(oldSession).exchanges[0].status, 'interrupted');
  ws.emit('close'); await tick();
}));
