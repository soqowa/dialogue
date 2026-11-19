import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Speech } from '../server/speech.mjs';

const root = path.resolve('.');
function worker() {
  const child = new EventEmitter();
  Object.assign(child, { stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(), exitCode: null, signalCode: null, jobs: [] });
  child.stdin.on('data', line => child.jobs.push(JSON.parse(line)));
  child.reply = event => child.stdout.write(JSON.stringify(event) + '\n');
  child.kill = signal => { child.signalCode = signal; queueMicrotask(() => child.emit('exit', null, signal)); };
  return child;
}
const job = (id, final = false, owner = 'a') => ({ id, final, owner, audio: 'AA==' });

test('speech coalesces partials per owner without losing final utterances under load', async () => {
  const child = worker(), speech = new Speech(root, { spawnProcess: () => child });
  speech.start();
  speech.enqueue(job('same')); speech.enqueue(job('same')); speech.enqueue(job('same', false, 'b'));
  assert.equal(speech.queue.length, 2);
  for (let i = 0; i < 40; i++) speech.enqueue(job(String(i), true));
  assert.equal(speech.queue.filter(j => j.final).length, 40);
  child.reply({ type: 'speech.ready' });
  for (let i = 0; i < 40; i++) child.reply({ type: 'transcript', ms: 20 });
  assert.equal(child.jobs.filter(j => j.final).length, 40);
  assert.deepEqual(child.jobs.filter(j => j.final).map(j => j.id), Array.from({ length: 40 }, (_, i) => String(i)));
  await speech.close();
});

test('clearing a conversation only removes its own waiting audio', async () => {
  const child = worker(), speech = new Speech(root, { spawnProcess: () => child });
  speech.start(); speech.enqueue(job('1', true, 'a')); speech.enqueue(job('2', true, 'b'));
  speech.clear('a'); child.reply({ type: 'speech.ready' });
  assert.equal(child.jobs.length, 1); assert.equal(child.jobs[0].owner, 'b');
  await speech.close();
});

test('engine switches persist and stale worker output cannot alter the new worker', async () => {
  const data = await mkdtemp(path.join(os.tmpdir(), 'dialog-speech-'));
  const children = [], speech = new Speech(root, { data, spawnProcess: () => { const child = worker(); children.push(child); return child; } });
  try {
    speech.start(); children[0].reply({ type: 'speech.ready' });
    await speech.select('gigaam');
    assert.equal(children[0].signalCode, 'SIGTERM');
    children[0].reply({ type: 'speech.error', message: 'old model failed' });
    children[0].reply({ type: 'speech.ready' });
    assert.equal(speech.state, 'loading'); assert.equal(speech.engine, 'gigaam');
    children[1].reply({ type: 'speech.ready' }); assert.equal(speech.state, 'ready');
    const restored = new Speech(root, { data }); await restored.load();
    assert.equal(restored.engine, 'gigaam');
    assert.deepEqual(JSON.parse(await readFile(path.join(data, 'speech.json'))), { engine: 'gigaam' });
    await assert.rejects(speech.select('not-a-model'));
    assert.equal(speech.engine, 'gigaam');
  } finally { await speech.close(); await rm(data, { recursive: true, force: true }); }
});
