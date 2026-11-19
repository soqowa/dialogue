import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Knowledge, chunkText, rank } from '../server/knowledge.mjs';

test('Russian word forms find the correct material; unrelated queries return no evidence', () => {
  const chunks = [...chunkText('Очередь обрабатывает элементы в порядке поступления. Для очередей используется FIFO.', 'queue.md', 'a'), ...chunkText('Стек извлекает последний добавленный элемент. LIFO.', 'stack.md', 'b')];
  assert.equal(rank(chunks, 'Как работает очередь?')[0].documentId, 'a');
  assert.equal(rank(chunks, 'стека')[0].documentId, 'b');
  assert.deepEqual(rank(chunks, 'погода на Марсе'), []);
});
test('Code search splits camelCase and preserves original source and line locations', () => {
  const code = Array.from({ length: 150 }, (_, i) => `// line ${i + 1}`).join('\n') + '\nfunction fetchUserProfile() { return cache.get(userId); }';
  const found = rank(chunkText(code, 'profile.ts', 'code'), 'fetch user profile');
  assert.match(found[0].text, /fetchUserProfile/);
  assert.equal(found[0].text.split('\n')[0], code.split('\n')[found[0].line - 1]);
});
test('Materials survive reload, deduplicate by content, and removal updates retrieval', async () => {
  const folder = await mkdtemp(path.join(os.tmpdir(), 'dialog-test-'));
  try {
    const store = new Knowledge(folder); await store.load();
    await store.add('конспект.md', 'Стек работает по принципу LIFO.');
    await store.add('конспект.md', 'Стек работает по принципу LIFO.');
    assert.equal(store.list().length, 1);
    const restored = new Knowledge(folder); await restored.load();
    assert.equal(restored.search('LIFO')[0].name, 'конспект.md');
    await restored.remove(restored.list()[0].id); assert.deepEqual(restored.search('LIFO'), []);
  } finally { await rm(folder, { recursive: true, force: true }); }
});

test('A whole folder can be removed in one call', async () => {
  const folder = await mkdtemp(path.join(os.tmpdir(), 'dialog-test-'));
  try {
    const store = new Knowledge(folder); await store.load();
    await store.add('project/src/a.md', 'Очередь работает по принципу FIFO.');
    await store.add('project/src/b.md', 'Дек поддерживает обе стороны.');
    await store.add('notes.md', 'Стек работает по принципу LIFO.');
    const ids = store.list().filter(d => d.name.startsWith('project/')).map(d => d.id);
    await store.removeMany(ids);
    const restored = new Knowledge(folder); await restored.load();
    assert.deepEqual(restored.list().map(d => d.name), ['notes.md']);
    assert.deepEqual(restored.search('FIFO'), []);
    assert.equal(restored.search('LIFO')[0].name, 'notes.md');
  } finally { await rm(folder, { recursive: true, force: true }); }
});
