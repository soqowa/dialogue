import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { EventEmitter } from 'node:events';
import path from 'node:path';

export const SPEECH_ENGINES = [
  { id: 'parakeet', name: 'Быстрый · ≈0,1 с — Parakeet', detail: 'Русский и английский. Тот же движок, что в SuperDictate.', model: 'FluidInference/parakeet-tdt-0.6b-v3-coreml', languages: ['ru', 'en'] },
  { id: 'gigaam', name: 'Точный для русского · ≈0,3 с — GigaAM', detail: 'Только русский. Меньше ошибок в наших коротких пробах.', model: 'v3_e2e_ctc', languages: ['ru'] },
  { id: 'whisper-turbo', name: 'Точный · ≈1,5 с — Whisper Turbo', detail: 'Русский и английский. Точнее базового Whisper в наших пробах.', model: 'mlx-community/whisper-large-v3-turbo', languages: ['ru', 'en'] },
  { id: 'whisper-base', name: 'Базовый · ≈0,3 с — Whisper Base', detail: 'Русский и английский. Небольшая модель; чаще ошибается на русском.', model: 'mlx-community/whisper-base-mlx', languages: ['ru', 'en'] },
];

export class Speech extends EventEmitter {
  constructor(root, { data = path.join(root, '.local'), spawnProcess = spawn } = {}) {
    super(); this.root = root; this.data = data; this.spawnProcess = spawnProcess;
    this.engine = 'parakeet'; this.state = 'idle'; this.queue = []; this.busy = false;
    this.selection = Promise.resolve(); this.detail = ''; this.stderr = '';
  }
  async load() {
    try { const value = JSON.parse(await readFile(path.join(this.data, 'speech.json'), 'utf8')); if (SPEECH_ENGINES.some(e => e.id === value.engine)) this.engine = value.engine; }
    catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    if (SPEECH_ENGINES.some(e => e.id === process.env.DIALOG_SPEECH_ENGINE)) this.engine = process.env.DIALOG_SPEECH_ENGINE;
  }
  snapshot() {
    return { speech: this.state, speechError: this.error || null, speechEngine: this.engine, speechEngines: SPEECH_ENGINES,
      speechModel: SPEECH_ENGINES.find(e => e.id === this.engine)?.model, speechDetail: this.detail, speechLatency: this.latency ?? null };
  }
  select(engine, force = false) {
    if (!SPEECH_ENGINES.some(e => e.id === engine)) return Promise.reject(new Error('Неизвестная модель распознавания'));
    this.selection = this.selection.catch(() => {}).then(async () => {
      if (this.engine === engine && this.state === 'ready' && !force) return;
      await this.close(); this.engine = engine; this.error = null; this.latency = null;
      await mkdir(this.data, { recursive: true });
      const file = path.join(this.data, 'speech.json');
      await writeFile(file + '.tmp', JSON.stringify({ engine }), { mode: 0o600 }); await rename(file + '.tmp', file);
      this.start();
    });
    return this.selection.then(() => this.snapshot());
  }
  start() {
    if (this.process) return;
    const python = process.env.DIALOG_PYTHON || path.join(this.root, '.venv/bin/python');
    if (!existsSync(python)) throw new Error('Установите распознавание: npm run setup:speech');
    this.state = 'loading'; this.error = null; this.detail = 'Загрузка модели…'; this.stderr = '';
    this.emit('status', { type: 'speech.loading', engine: this.engine, detail: this.detail });
    const child = this.spawnProcess(python, ['-u', path.join(this.root, 'speech/worker.py')], {
      stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, DIALOG_SPEECH_ENGINE: this.engine, HF_HUB_DISABLE_XET: '1', HF_HUB_DISABLE_PROGRESS_BARS: '1', TOKENIZERS_PARALLELISM: 'false' },
    });
    this.process = child;
    child.stderr.on('data', data => { if (this.process === child) this.stderr = (this.stderr + data).slice(-8000); });
    child.stdin.on('error', error => { if (this.process === child) this.problem(error.message); });
    child.on('error', error => { if (this.process === child) this.problem(error.message); });
    child.on('exit', () => {
      if (this.process !== child) return;
      this.process = null;
      if (this.state !== 'idle' && this.state !== 'error') this.problem('Распознавание остановилось. Нажмите «Повторить» в настройках.');
    });
    createInterface({ input: child.stdout }).on('line', line => {
      if (this.process !== child) return;
      let event; try { event = JSON.parse(line); } catch { return; }
      if (event.type === 'speech.ready') { this.state = 'ready'; this.error = null; this.detail = ''; this.emit('status', { ...event, engine: this.engine }); this.next(); }
      else if (event.type === 'speech.error') this.problem(event.message);
      else if (event.type === 'speech.warning') this.emit('status', event);
      else if (event.type === 'transcript') { this.busy = false; this.latency = event.ms; this.emit('transcript', event); this.next(); }
      else { if (event.detail) this.detail = event.detail; this.emit('status', event); }
    });
  }
  problem(message) { this.error = message; this.state = 'error'; this.busy = false; this.queue = []; this.emit('status', { type: 'speech.error', engine: this.engine, message }); }
  enqueue(job) {
    this.queue = this.queue.filter(j => !(j.owner === job.owner && j.id === job.id && !j.final));
    if (!job.final && (this.queue.length >= 8 || this.queue.some(j => j.final))) return;
    // A newer partial is expendable; a final utterance must survive backpressure.
    if (job.final && this.queue.length >= 8) this.queue = this.queue.filter(j => j.final);
    if (this.queue.length >= 32) this.emit('status', { type: 'speech.warning', message: 'Распознавание отстаёт от разговора. Попробуйте Parakeet v3.' });
    this.queue.push(job); this.next();
  }
  next() {
    if (this.busy || this.state !== 'ready' || !this.queue.length || !this.process?.stdin.writable) return;
    this.busy = true; this.process.stdin.write(JSON.stringify(this.queue.shift()) + '\n');
  }
  clear(owner) { this.queue = this.queue.filter(j => j.owner !== owner); }
  close() {
    this.state = 'idle'; this.busy = false; this.queue = [];
    const child = this.process; this.process = null;
    if (!child || child.exitCode != null || child.signalCode != null) return Promise.resolve();
    return new Promise(resolve => {
      const timer = setTimeout(() => { child.kill('SIGKILL'); resolve(); }, 4000); timer.unref();
      child.once('exit', () => { clearTimeout(timer); resolve(); });
      child.kill('SIGTERM');
    });
  }
}
