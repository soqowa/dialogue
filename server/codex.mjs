import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { EventEmitter } from 'node:events';
import { agentTools } from './agent-tools.mjs';

export function codexBinary() {
  const bundled = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex';
  return process.env.DIALOG_CODEX_BIN || (existsSync(bundled) ? bundled : 'codex');
}
export class Codex extends EventEmitter {
  constructor(cwd) { super(); Object.assign(this, { cwd, pending: new Map(), handlers: new Map(), loaded: new Map(), serial: 0, process: null }); }
  async start() {
    if (!this.starting) this.starting = this.initialize().catch(error => { this.starting = null; throw error; });
    return this.starting;
  }
  async initialize() {
    const child = spawn(codexBinary(), ['app-server', '-c', 'features.shell_tool=false', '-c', 'features.multi_agent=false', '-c', 'web_search="disabled"', '-c', 'project_doc_max_bytes=0', '-c', 'mcp_servers={}'], { cwd: this.cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    this.process = child;
    child.on('error', error => this.fail(error));
    child.on('exit', () => { if (this.process !== child) return; this.starting = null; this.loaded.clear(); this.fail(new Error('Соединение с Codex закрыто. Повторите вопрос для восстановления сессии.')); });
    child.stderr.on('data', () => {});
    createInterface({ input: child.stdout }).on('line', line => { let msg; try { msg = JSON.parse(line); } catch { return; } this.handleMessage(msg); });
    await this.request('initialize', { clientInfo: { name: 'dialog_local', title: 'Диалог', version: '0.2.0' }, capabilities: { experimentalApi: true } });
    this.send({ method: 'initialized', params: {} });
  }
  handleMessage(msg) {
    if (msg.id !== undefined && this.pending.has(msg.id)) {
      const p = this.pending.get(msg.id); this.pending.delete(msg.id); clearTimeout(p.timer);
      msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
    } else if (msg.method && msg.id !== undefined) this.handleToolRequest(msg).catch(() => {});
    else if (msg.method) this.emit('notification', msg);
  }
  async handleToolRequest(msg) {
    const handler = this.handlers.get(msg.params?.threadId);
    if (msg.method !== 'item/tool/call' || !handler) { this.send({ id: msg.id, error: { code: -32601, message: 'Only material and conversation tools are available.' } }); return; }
    let result;
    try { result = { success: true, contentItems: [{ type: 'inputText', text: JSON.stringify(await handler(msg.params)) }] }; }
    catch (e) { result = { success: false, contentItems: [{ type: 'inputText', text: JSON.stringify({ error: e.message }) }] }; }
    this.send({ id: msg.id, result });
  }
  fail(error) { for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(error); } this.pending.clear(); this.emit('offline', error.message); }
  send(msg) { if (!this.process?.stdin.writable) throw new Error('Codex не подключён'); this.process.stdin.write(JSON.stringify(msg) + '\n'); }
  request(method, params = {}, timeout = 45000) {
    const id = ++this.serial;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`Codex: превышено время ожидания ${method}`)); }, timeout);
      this.pending.set(id, { resolve, reject, timer });
      try { this.send({ id, method, params }); } catch (e) { clearTimeout(timer); this.pending.delete(id); reject(e); }
    });
  }
  async status() {
    await this.start();
    const [auth, catalog] = await Promise.all([this.request('account/read', { refreshToken: false }), this.request('model/list', { limit: 100, includeHidden: false })]);
    return { connected: auth.account?.type === 'chatgpt', authType: auth.account?.type || null, plan: auth.account?.planType || null, models: catalog.data || [] };
  }
  async ensureThread(session, model, instructions, cwd = this.cwd) {
    await this.start();
    if (session.threadId && this.loaded.get(session.threadId) === instructions) return;
    const config = { 'features.shell_tool': false, 'features.multi_agent': false, web_search: 'disabled', project_doc_max_bytes: 0 };
    const options = { model, modelProvider: 'openai', cwd, approvalPolicy: 'never', sandbox: 'read-only', baseInstructions: instructions, config, dynamicTools: agentTools };
    if (session.threadId) await this.request('thread/resume', { ...options, threadId: session.threadId, excludeTurns: true });
    else { const result = await this.request('thread/start', { ...options, ephemeral: false }); session.threadId = result.thread.id; }
    this.loaded.set(session.threadId, instructions);
  }
  async answer({ session = { threadId: null }, cwd = this.cwd, model, effort, instructions, prompt, toolHandler, onThread = async () => {}, onAccepted = async () => {}, onEvent, signal }) {
    let threadId, turnId, listener, offline, timer, finish, interrupting;
    let text = '', firstToken = null, ended = false;
    const started = performance.now();
    const abort = () => {
      if (!turnId || interrupting) return;
      interrupting = this.request('turn/interrupt', { threadId, turnId }, 10000).catch(() => {}).finally(() => { if (signal.aborted) finish?.('interrupted'); });
    };
    try {
      if (signal.aborted) return;
      await this.ensureThread(session, model, instructions, cwd); threadId = session.threadId; await onThread(threadId);
      if (signal.aborted) return;
      this.handlers.set(threadId, async p => {
        if (signal.aborted || (turnId && p.turnId !== turnId)) throw new Error('Этот ответ уже остановлен');
        if (!toolHandler) throw new Error('Инструменты не подключены');
        onEvent({ type: 'agent.tool', tool: p.tool });
        return toolHandler(p.tool, typeof p.arguments === 'string' ? JSON.parse(p.arguments) : p.arguments);
      });
      const phases = new Map();
      const completed = new Promise((resolve, reject) => {
        finish = resolve;
        offline = message => reject(new Error(message)); this.on('offline', offline);
        timer = setTimeout(() => { reject(new Error('Codex не завершил ответ за 180 секунд')); abort(); }, 180000);
        listener = ({ method, params: p }) => {
          if (p?.threadId !== threadId) return;
          if (method === 'turn/started') { turnId = p.turn.id; if (signal.aborted) abort(); }
          if (method === 'item/started' && p.item?.type === 'agentMessage') phases.set(p.item.id, p.item.phase);
          if (method === 'item/started' && p.item?.type === 'contextCompaction') onEvent({ type: 'agent.compacting' });
          if (method === 'item/agentMessage/delta' && phases.get(p.itemId) !== 'commentary') {
            if (firstToken === null) firstToken = Math.round(performance.now() - started);
            text += p.delta; if (!signal.aborted) onEvent({ type: 'answer.delta', delta: p.delta, firstToken });
          }
          if (method === 'turn/completed') { ended = true; if (p.turn.status === 'failed') reject(new Error(p.turn.error?.message || 'Codex не смог завершить ответ')); else resolve(p.turn.status); }
          if (method === 'error' && p.willRetry === false) reject(new Error(p.error?.message || 'Ошибка Codex'));
        };
        this.on('notification', listener);
      });
      completed.catch(() => {}); signal.addEventListener('abort', abort, { once: true });
      const result = await this.request('turn/start', { threadId, model, effort, input: [{ type: 'text', text: prompt }], summary: 'none' });
      turnId = result.turn.id; await onAccepted(); if (signal.aborted) abort();
      const status = await completed;
      if (!signal.aborted && status === 'completed') onEvent({ type: 'answer.done', text, firstToken, totalMs: Math.round(performance.now() - started) });
      else if (!signal.aborted) throw new Error('Ответ Codex прерван');
    } finally {
      clearTimeout(timer); signal.removeEventListener('abort', abort);
      if (!ended && signal.aborted) { abort(); if (interrupting) await interrupting; }
      if (offline) this.off('offline', offline); if (listener) this.off('notification', listener);
      if (threadId) this.handlers.delete(threadId);
    }
  }
  close() { this.process?.kill(); }
}
