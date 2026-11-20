import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Knowledge } from '../server/knowledge.mjs';
import { Sessions } from '../server/sessions.mjs';
import { AgentTools } from '../server/agent-tools.mjs';
import { makePrompt, conversationRequest } from '../server/prompts.mjs';
import { importMaterials } from '../server/imports.mjs';

async function fixture(run) {
  const folder = await mkdtemp(path.join(os.tmpdir(), 'dialog-agent-'));
  try {
    const knowledge = new Knowledge(folder); await knowledge.load();
    const sessions = new Sessions(path.join(folder, 'sessions')); await sessions.load();
    const session = await sessions.create(); const tools = new AgentTools(knowledge, sessions, session);
    await run({ folder, knowledge, sessions, session, tools }); await sessions.flush();
  } finally { await rm(folder, { recursive: true, force: true }); }
}
test('Agent can read an unranked complete file, including the end of a very long line', async () => fixture(async ({ knowledge, tools }) => {
  const content = 'x'.repeat(70000) + '\nПоследнее слово: янтарь.';
  await knowledge.add('project/src/queue.ts', content);
  assert.equal((await tools.call('search_materials', { query: 'переполнение' })).results.length, 0);
  const catalog = await tools.call('list_materials'); assert.equal(catalog.materials[0].name, 'project/src/queue.ts');
  let offset = 0, recovered = '';
  while (offset !== null) { const page = await tools.call('read_material', { documentId: catalog.materials[0].id, offset, length: 20000 }); recovered += page.text; offset = page.nextOffset; }
  assert.equal(recovered, content);
  await assert.rejects(tools.call('read_material', { documentId: '../../.codex/auth.json' }), /не найден/);
  await assert.rejects(tools.call('exec_command', { cmd: 'pwd' }), /недоступен/);
}));
test('Full history and its Codex thread survive reload, including both speakers and earlier assistant replies', async () => fixture(async ({ folder, sessions, session, tools }) => {
  for (let i = 0; i < 100; i++) sessions.addTranscript(session, { id: 't' + i, source: i % 2 ? 'mic' : 'remote', text: i === 0 ? 'Кодовое имя — Янтарь.' : 'реплика ' + i, time: i });
  const exchange = sessions.begin(session, 'Как назвать очередь?', 'test'); exchange.text = 'Назовём её Сирень.'; sessions.finish(session, exchange, 'completed'); session.threadId = 'saved-thread'; await sessions.save(session);
  const first = await tools.call('conversation_history', { query: 'Янтарь' }); assert.equal(first.events[0].text, 'Кодовое имя — Янтарь.');
  const assistants = await tools.call('conversation_history', { source: 'assistant' }); assert.equal(assistants.events[1].text, 'Назовём её Сирень.');
  const restored = new Sessions(path.join(folder, 'sessions')); await restored.load();
  assert.equal(restored.get(session.id).threadId, 'saved-thread'); assert.equal(restored.get(session.id).transcript.length, 100);
  assert.equal(restored.get(session.id).exchanges[0].text, 'Назовём её Сирень.');
}));
test('Incremental context includes every new utterance rather than the last 24, without resending accepted turns', async () => fixture(async ({ sessions, session }) => {
  for (let i = 0; i < 80; i++) sessions.addTranscript(session, { id: 't' + i, source: 'remote', text: 'строка ' + i, time: i });
  const first = makePrompt('Вопрос', session, []); assert.equal(JSON.parse(first.text).newTranscript.length, 80);
  session.transcriptCursor = first.cursor;
  sessions.addTranscript(session, { id: 'new', source: 'mic', text: 'добавление', time: 81 });
  const next = makePrompt('Ещё вопрос', session, []); assert.equal(JSON.parse(next.text).newTranscript.length, 1);
}));
test('The catalog is compact, sent once per thread and resent only after the base changes', async () => fixture(async ({ session }) => {
  const small = [{ id: 'a', name: 'notes.md', hash: '1' }, { id: 'b', name: 'project/src/queue.ts', hash: '2' }];
  const first = makePrompt('Вопрос', session, small);
  assert.deepEqual(JSON.parse(first.text).materialsCatalog, { total: 2, files: ['notes.md', 'project/src/queue.ts'] });
  assert.ok(!first.text.includes('"hash"'));
  session.catalogDigest = first.catalogDigest;
  assert.deepEqual(JSON.parse(makePrompt('Ещё', session, small).text).materialsCatalog, { unchanged: true, total: 2 });
  assert.equal(JSON.parse(makePrompt('После восстановления', session, small, { replay: true }).text).materialsCatalog.total, 2);
  const changed = [...small, { id: 'c', name: 'new.md', hash: '3' }];
  assert.deepEqual(JSON.parse(makePrompt('После импорта', session, changed).text).materialsCatalog.files, ['new.md', 'notes.md', 'project/src/queue.ts']);
  const large = Array.from({ length: 540 }, (_, i) => ({ id: 'id' + i, hash: 'h' + i, name: `repo/services/service-${i % 12}/src/module/file-${i}.java` }));
  const summary = JSON.parse(makePrompt('Большая база', session, large).text).materialsCatalog;
  assert.equal(summary.total, 540); assert.ok(!summary.files); assert.ok(summary.folders.length <= 60);
  assert.ok(summary.folders.some(f => f.startsWith('repo/services/service-0/')));
  assert.ok(JSON.stringify(summary).length < 4000);
}));
test('Shortcut requests use both speakers and existing assistant context without requiring typed text', async () => fixture(async ({ sessions, session }) => {
  assert.throws(() => conversationRequest(session), /нет распознанных/);
  sessions.addTranscript(session, { id: 'a', source: 'remote', text: 'Чем отличаются интеграционные тесты?', time: 1 });
  sessions.addTranscript(session, { id: 'b', source: 'mic', text: 'От модульных?', time: 2 });
  const request = conversationRequest(session, [{ id: 'a', source: 'remote', text: 'устаревшая версия' }, { id: 'c', source: 'remote', text: 'И что с базой данных?', time: 3 }]);
  const prompt = JSON.parse(makePrompt(request.question, session, [{ id: 'doc', name: 'testing.md' }], { ...request, replay: true }).text);
  assert.equal(prompt.newTranscript.length, 2); assert.equal(prompt.newTranscript[1].speaker, 'Я');
  assert.equal(prompt.liveTranscript.length, 1); assert.equal(prompt.liveTranscript[0].text, 'И что с базой данных?');
  assert.equal(prompt.liveTranscript[0].provisional, true); assert.deepEqual(prompt.materialsCatalog.files, ['testing.md']);
  session.transcript = [];
  const exchange = sessions.begin(session, 'Первый вопрос', 'test'); exchange.text = 'Предыдущий ответ';
  assert.ok(conversationRequest(session).question.length > 0);
}));
test('Folder imports preserve relative paths, distinguish equal basenames, replace changed files and skip build directories', async () => fixture(async ({ knowledge }) => {
  const paths = ['project/a/index.ts', 'project/b/index.ts', 'project/node_modules/hidden.js', 'project/README', '../escape.md'];
  const files = paths.map((name, i) => ({ originalname: name, buffer: Buffer.from('export const n = ' + i) }));
  const result = await importMaterials(knowledge, files, paths);
  assert.equal(result.imported, 3); assert.equal(result.skipped, 1); assert.equal(result.errors.length, 1);
  assert.ok(knowledge.list().some(d => d.name === paths[0])); assert.ok(knowledge.list().some(d => d.name === paths[1]));
  await importMaterials(knowledge, [{ originalname: 'index.ts', buffer: Buffer.from('updated') }], [paths[0]]);
  assert.equal(knowledge.documents.length, 3); assert.equal(knowledge.read(paths[0]).text, 'updated');
}));
