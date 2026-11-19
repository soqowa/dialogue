import { createHash } from 'node:crypto';
const integer = (value, fallback, max) => value !== undefined && Number.isFinite(Number(value)) ? Math.max(0, Math.min(max, Math.floor(Number(value)))) : fallback;
const objectSchema = properties => ({ type: 'object', properties, additionalProperties: false });
const str = { type: 'string' }, num = { type: 'integer', minimum: 0 };
const tool = (name, description, properties) => ({ type: 'function', name, description, inputSchema: objectSchema(properties) });

export const agentTools = [
  tool('list_materials', 'List every available material with its ID, relative folder path and size. Paginate until nextOffset is null. No material is hidden from this catalog.', { offset: num, limit: num, path: str }),
  tool('search_materials', 'Search the entire materials database using your own query. Try alternate terms, code identifiers or a file/path filter; paginate results. Returns source citations. No initial keyword selection restricts what you can search or read.', { query: str, file: str, offset: num, limit: num }),
  tool('read_material', 'Read any material by ID or exact relative path, including files with no keyword matches. Use offset and length to read the complete file page by page. Returns a citation and nextOffset.', { documentId: str, offset: num, length: num }),
  tool('conversation_history', 'Read or search the complete saved conversation: both audio speakers plus all questions and assistant answers, including older or compacted context. Pagination never discards history.', { source: { type: 'string', enum: ['all', 'transcript', 'assistant'] }, query: str, offset: num, limit: num }),
];

export class AgentTools {
  constructor(knowledge, sessions, session, onSources = () => {}) { Object.assign(this, { knowledge, sessions, session, onSources }); this.used = new Map(); }
  cite(source) {
    const key = createHash('sha256').update(source.documentId + ':' + (source.offset ?? source.line) + ':' + source.text).digest('hex');
    let found = this.session.sources.find(s => s.key === key);
    if (!found) { found = { ...source, ref: this.session.sources.length + 1, key }; this.session.sources.push(found); }
    this.used.set(found.ref, found);
    this.onSources([...this.used.values()].map(({ key, ...s }) => s));
    const { key: _, score, ...result } = found;
    return { ...result, citation: `[${result.ref}]` };
  }
  async call(name, args = {}) {
    if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error('Аргументы инструмента должны быть объектом');
    switch (name) {
      case 'list_materials': {
        const offset = integer(args.offset, 0, 1e9), limit = Math.max(1, integer(args.limit, 100, 500));
        const all = this.knowledge.list().filter(d => !args.path || d.name.toLowerCase().includes(String(args.path).toLowerCase()));
        return { materials: all.slice(offset, offset + limit), total: all.length, nextOffset: offset + limit < all.length ? offset + limit : null };
      }
      case 'search_materials': {
        if (!String(args.query || '').trim()) throw new Error('Укажите поисковый запрос или используйте list_materials/read_material');
        const result = this.knowledge.searchAll(String(args.query), { file: String(args.file || ''), offset: integer(args.offset, 0, 1e9), limit: Math.max(1, integer(args.limit, 12, 40)) });
        return { ...result, results: result.results.map(s => this.cite(s)) };
      }
      case 'read_material': {
        if (!args.documentId) throw new Error('Укажите documentId из каталога или относительный путь');
        const result = this.knowledge.read(String(args.documentId), integer(args.offset, 0, 1e9), Math.max(1, integer(args.length, 16000, 32000)));
        return this.cite(result);
      }
      case 'conversation_history': return this.sessions.history(this.session, { source: args.source || 'all', query: String(args.query || ''), offset: integer(args.offset, 0, 1e9), limit: Math.max(1, integer(args.limit, 100, 300)) });
      default: throw new Error('Этот инструмент недоступен: ' + name);
    }
  }
}
