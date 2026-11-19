import { mkdir, readFile, writeFile, rename, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';

export class Sessions {
  constructor(folder) { this.folder = folder; this.items = new Map(); this.writes = new Map(); }
  async load() {
    await mkdir(this.folder, { recursive: true });
    for (const file of await readdir(this.folder)) {
      if (!file.endsWith('.json')) continue;
      const session = JSON.parse(await readFile(path.join(this.folder, file), 'utf8'));
      for (const exchange of session.exchanges) if (exchange.status === 'inProgress') exchange.status = 'interrupted';
      this.items.set(session.id, session);
    }
  }
  async create() {
    const now = Date.now();
    const session = { id: randomUUID(), title: 'Новый разговор', createdAt: now, updatedAt: now, seq: 0,
      threadId: null, transcriptCursor: 0, transcript: [], exchanges: [], sources: [] };
    this.items.set(session.id, session); await this.save(session); return session;
  }
  get(id) { const session = this.items.get(id); if (!session) throw new Error('Разговор не найден'); return session; }
  list() { return [...this.items.values()].sort((a, b) => b.updatedAt - a.updatedAt).map(s => ({ id: s.id, title: s.title, updatedAt: s.updatedAt, transcriptCount: s.transcript.length, answerCount: s.exchanges.length })); }
  save(session) {
    session.updatedAt = Date.now();
    const data = JSON.stringify(session);
    const file = path.join(this.folder, session.id + '.json');
    const pending = (this.writes.get(session.id) || Promise.resolve()).catch(() => {}).then(async () => {
      await writeFile(file + '.tmp', data, { mode: 0o600 }); await rename(file + '.tmp', file);
    });
    this.writes.set(session.id, pending); return pending;
  }
  addTranscript(session, event) {
    const found = session.transcript.find(t => t.id === event.id);
    if (found) { if (found.text !== event.text) Object.assign(found, { text: event.text, time: event.time, seq: ++session.seq }); }
    else session.transcript.push({ id: event.id, source: event.source, text: event.text, time: event.time, seq: ++session.seq, final: true });
    session.transcript.sort((a, b) => a.time - b.time);
  }
  begin(session, question, model) {
    const exchange = { id: randomUUID(), question, text: '', model, time: Date.now(), seq: ++session.seq, answerSeq: null, status: 'inProgress', sources: [], toolCalls: [] };
    session.exchanges.push(exchange);
    if (session.title === 'Новый разговор') session.title = question.replace(/\s+/g, ' ').slice(0, 70);
    return exchange;
  }
  finish(session, exchange, status) { exchange.status = status; exchange.answerSeq = ++session.seq; }
  snapshot(session) {
    return { id: session.id, title: session.title, transcript: session.transcript,
      exchanges: session.exchanges, sources: session.sources, updatedAt: session.updatedAt };
  }
  history(session, { offset = 0, limit = 100, query = '', source = 'all' } = {}) {
    let events = [];
    if (source !== 'assistant') events.push(...session.transcript.map(t => ({ kind: 'transcript', seq: t.seq, time: t.time, speaker: t.source === 'mic' ? 'Я' : 'Собеседник', text: t.text })));
    if (source !== 'transcript') for (const e of session.exchanges) {
      events.push({ kind: 'question', seq: e.seq, time: e.time, speaker: 'Пользователь помощника', text: e.question });
      if (e.text) events.push({ kind: 'answer', seq: e.answerSeq ?? e.seq, time: e.time, speaker: 'Помощник', text: e.text, status: e.status });
    }
    if (query) events = events.filter(e => e.text.toLowerCase().includes(query.toLowerCase()));
    events.sort((a, b) => a.seq - b.seq);
    const result = [];
    let size = 0, index = offset;
    for (; index < events.length && result.length < limit; index++) {
      const event = events[index];
      if (size + event.text.length > 48000 && result.length) break;
      size += event.text.length; result.push(event);
    }
    return { events: result, total: events.length, nextOffset: index < events.length ? index : null };
  }
  async flush() { await Promise.all([...this.writes.values()]); }
}
