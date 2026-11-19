import { createHash, randomUUID } from 'node:crypto';
import { readFile, writeFile, mkdir, rename } from 'node:fs/promises';
import path from 'node:path';
import stemmers from 'snowball-stemmers';

const ru = stemmers.newStemmer('russian');
const en = stemmers.newStemmer('english');
const stop = new Set('и в во на с со по к ко о об а но или что это как для из за от до не да то мы вы он она они я ты the a an of to is are and or in for with'.split(' '));
export function tokens(text) {
  const words = text.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase().replaceAll('ё', 'е').match(/[\p{L}\p{N}_]+/gu) || [];
  return words.filter(w => w.length > 1 && !stop.has(w)).map(w => /[а-я]/.test(w) ? ru.stem(w) : en.stem(w));
}
export function chunkText(text, name, id) {
  const lines = text.replaceAll('\r\n', '\n').split('\n'); const chunks = [];
  let start = 0;
  while (start < lines.length) {
    let end = start, size = 0;
    while (end < lines.length && (size < 1700 || end === start)) { size += lines[end].length + 1; end++; }
    const content = lines.slice(start, end).join('\n').slice(0, 12000);
    if (content.trim()) chunks.push({ documentId: id, name, line: start + 1, text: content, terms: tokens(name + ' ' + content) });
    if (end === lines.length) break;
    start = Math.max(start + 1, end - 3);
  }
  return chunks;
}
export function rank(chunks, query, limit = 6, offset = 0) {
  const q = [...new Set(tokens(query))]; if (!q.length || !chunks.length) return [];
  const average = chunks.reduce((n, c) => n + c.terms.length, 0) / chunks.length || 1;
  const df = new Map(q.map(t => [t, chunks.filter(c => c.terms.includes(t)).length]));
  return chunks.map(chunk => {
    let score = 0;
    for (const t of q) {
      const tf = chunk.terms.filter(v => v === t).length;
      const idf = Math.log(1 + (chunks.length - df.get(t) + 0.5) / (df.get(t) + 0.5));
      score += idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * chunk.terms.length / average));
    }
    return { ...chunk, score };
  }).filter(c => c.score > 0).sort((a, b) => b.score - a.score).slice(offset, offset + limit).map(({ terms, ...c }, index) => ({ ...c, ref: offset + index + 1 }));
}
export class Knowledge {
  constructor(folder) { this.folder = folder; this.documents = []; this.chunks = []; this.saving = Promise.resolve(); }
  async load() {
    await mkdir(this.folder, { recursive: true });
    try { this.documents = JSON.parse(await readFile(path.join(this.folder, 'knowledge.json'), 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    this.reindex();
  }
  reindex() { this.chunks = this.documents.flatMap(d => chunkText(d.text, d.name, d.id)); }
  list() { return this.documents.map(({ text, ...d }) => ({ ...d, characters: text.length, lines: text.split('\n').length, chunks: this.chunks.filter(c => c.documentId === d.id).length })); }
  async add(name, text, { persist = true } = {}) {
    if (!text.trim()) throw new Error('В файле нет текста. PDF со сканами нужно сначала распознать.');
    const hash = createHash('sha256').update(text).digest('hex');
    if (this.documents.some(d => d.hash === hash && d.name === name)) return;
    const removed = new Set(this.documents.filter(d => d.name === name).map(d => d.id));
    this.documents = this.documents.filter(d => d.name !== name);
    const document = { id: randomUUID(), name, text, hash, createdAt: new Date().toISOString() };
    this.documents.push(document);
    this.chunks = this.chunks.filter(c => !removed.has(c.documentId));
    this.chunks.push(...chunkText(text, name, document.id));
    if (persist) await this.save();
  }
  async remove(id) { this.documents = this.documents.filter(d => d.id !== id); this.chunks = this.chunks.filter(c => c.documentId !== id); await this.save(); }
  async save() {
    const data = JSON.stringify(this.documents);
    this.saving = this.saving.catch(() => {}).then(async () => {
      const file = path.join(this.folder, 'knowledge.json');
      await writeFile(file + '.tmp', data, { mode: 0o600 }); await rename(file + '.tmp', file);
    });
    await this.saving;
  }
  search(query) { return rank(this.chunks, query); }
  searchAll(query, { offset = 0, limit = 12, file = '' } = {}) {
    const chunks = file ? this.chunks.filter(c => c.name.toLowerCase().includes(file.toLowerCase())) : this.chunks;
    const page = rank(chunks, query, limit + 1, offset);
    return { results: page.slice(0, limit), nextOffset: page.length > limit ? offset + limit : null };
  }
  read(id, offset = 0, length = 16000) {
    const document = this.documents.find(d => d.id === id || d.name === id);
    if (!document) throw new Error('Материал не найден. Обновите список материалов.');
    offset = Math.max(0, Math.min(document.text.length, Math.floor(offset)));
    length = Math.max(1, Math.min(32000, Math.floor(length)));
    const text = document.text.slice(offset, offset + length);
    return { documentId: document.id, name: document.name, line: document.text.slice(0, offset).split('\n').length,
      offset, text, totalCharacters: document.text.length, nextOffset: offset + text.length < document.text.length ? offset + text.length : null };
  }
}
