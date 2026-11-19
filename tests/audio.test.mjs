import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../public/pcm-worklet.js', import.meta.url), 'utf8');
function worklet(rate = 16000) {
  const events = []; let Processor;
  const context = vm.createContext({ sampleRate: rate, AudioWorkletProcessor: class { constructor() { this.port = { postMessage: msg => events.push(msg) }; } }, registerProcessor: (name, cls) => { Processor = cls; } });
  vm.runInContext(source, context);
  const node = new Processor({ processorOptions: { pause: 480 } });
  const feed = (seconds, amplitude) => { const input = new Float32Array(128); for (let i = 0; i < input.length; i++) input[i] = Math.sin(i * .3) * amplitude; for (let i = 0; i < seconds * rate / 128; i++) node.process([[input]]); };
  return { node, events, feed };
}
test('Silence never produces a transcription request', () => { const { events, feed } = worklet(); feed(3, 0); assert.equal(events.filter(e => e.type === 'audio').length, 0); });
test('Speech produces partial hypotheses and exactly one final after silence', () => {
  const { events, feed } = worklet(); feed(2.1, .1); feed(.7, 0);
  const audio = events.filter(e => e.type === 'audio');
  assert.ok(audio.some(e => !e.final)); assert.equal(audio.filter(e => e.final).length, 1);
  assert.ok(audio.every(e => e.seq === audio[0].seq));
  assert.ok(audio.at(-1).audio.byteLength > audio[0].audio.byteLength);
});
test('48 kHz input becomes 16 kHz PCM and flushing retains the last utterance', () => {
  const { node, events, feed } = worklet(48000); feed(1, .1); node.port.onmessage({ data: 'flush' });
  const audio = events.filter(e => e.type === 'audio'); assert.equal(audio.length, 1); assert.ok(audio[0].final);
  assert.ok(Math.abs(audio[0].audio.byteLength - 32000) < 1000);
});
