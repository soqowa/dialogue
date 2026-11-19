import { randomUUID } from 'node:crypto';
import { WebSocket } from 'ws';
import { instructions, conversationRequest, makePrompt } from './prompts.mjs';
import { AgentTools } from './agent-tools.mjs';

export const conversationKey = (project, session) => project.id + '/' + session.id;

export function connectConversation(ws, { projects, codex, speech, getStatus, cachedStatus, jobs, sessionClients }) {
  let project = projects.get(), owner = randomUUID(), session = null, timer, closed = false;
  let questionRevision = 0, contextPendingUntil = 0, projectClient = false, opening = false;
  let settings = { ...project.preferences, auto: true };
  let operations = Promise.resolve();
  const send = event => { if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(event)); };
  const broadcast = (context, target, event) => {
    const payload = JSON.stringify({ ...event, projectId: context.id, sessionId: target.id });
    for (const client of sessionClients.get(conversationKey(context, target)) || []) if (client.readyState === WebSocket.OPEN) client.send(payload);
  };
  const activeJob = () => session && jobs.get(conversationKey(project, session));
  const detach = () => { if (session) sessionClients.get(conversationKey(project, session))?.delete(ws); };
  const save = (context, target) => context.sessions.save(target).catch(e => send({ type: 'error', message: 'История не сохранена: ' + e.message }));
  const queueAnswer = (text, options = {}) => {
    clearTimeout(timer);
    const revision = ++questionRevision, context = project, target = session, answerSettings = projectClient ? { ...project.preferences, auto: settings.auto } : { ...settings };
    activeJob()?.controller.abort();
    operations = operations.then(() => revision === questionRevision && context === project && target === session
      ? answer(text, options, context, target, answerSettings) : undefined).catch(e => send({ type: 'error', message: e.message }));
  };
  async function openSession(id, fresh = false, snapshot = true) {
    const next = id && !fresh ? project.sessions.get(id) : await project.sessions.create();
    clearTimeout(timer); contextPendingUntil = 0; speech.clear(owner); owner = randomUUID(); detach();
    session = next;
    const key = conversationKey(project, session);
    if (!sessionClients.has(key)) sessionClients.set(key, new Set());
    sessionClients.get(key).add(ws);
    if (projectClient) await project.rememberSession(session);
    if (snapshot) send({ type: 'session.snapshot', projectId: project.id, session: project.sessions.snapshot(session) });
  }
  async function openProject(id) {
    const next = projects.get(id);
    clearTimeout(timer); contextPendingUntil = 0; speech.clear(owner); owner = randomUUID(); detach();
    project = next; session = null; settings = { ...project.preferences, auto: settings.auto }; projectClient = true;
    const last = project.preferences.lastSessionId;
    await openSession(last && project.sessions.items.has(last) ? last : null, false, false);
    send({ type: 'project.snapshot', project: project.snapshot(), projects: projects.list(),
      session: project.sessions.snapshot(session), materials: project.knowledge.list() });
  }
  async function answer(question, options, context, target, answerSettings) {
    if (!target) { await openSession(); target = session; }
    const key = conversationKey(context, target), previous = jobs.get(key);
    previous?.controller.abort(); if (previous) await previous.promise;
    if (closed || project !== context || session !== target) return;
    const controller = new AbortController(), job = { controller, promise: null };
    jobs.set(key, job);
    job.promise = runAnswer(question, context, target, controller, options, answerSettings).finally(() => { if (jobs.get(key) === job) jobs.delete(key); });
    await job.promise;
  }
  async function runAnswer(question, context, target, controller, options, answerSettings) {
    const { knowledge, sessions } = context;
    const emit = event => broadcast(context, target, event);
    let exchange, lastPartialSave = 0;
    try {
      let status = cachedStatus();
      if (!status?.connected) status = await getStatus();
      if (!status.connected) throw new Error(status.error || 'Войдите в Codex через ChatGPT');
      if (controller.signal.aborted) return;
      const catalog = status.models.filter(m => m.model.startsWith('gpt-'));
      const model = catalog.find(m => m.model === answerSettings.model) || catalog.find(m => /luna|mini/.test(m.model)) || catalog.find(m => m.isDefault) || catalog[0];
      if (!model) throw new Error('Codex не вернул доступные модели');
      const efforts = model.supportedReasoningEfforts?.map(e => e.reasoningEffort) || ['low'];
      const effort = efforts.includes(answerSettings.effort) ? answerSettings.effort : ['none', 'minimal', 'low'].find(e => efforts.includes(e)) || model.defaultReasoningEffort;
      const startCursor = target.transcriptCursor;
      exchange = sessions.begin(target, question, model.model); await sessions.save(target);
      const tools = new AgentTools(knowledge, sessions, target, sources => { exchange.sources = sources; emit({ type: 'answer.sources', sources }); });
      const prompt = makePrompt(question, target, knowledge.list(), { ...options, replay: !target.threadId });
      emit({ type: 'answer.start', question, sources: [], model: model.model, exchangeId: exchange.id });
      await codex.answer({ session: target, cwd: context.work, model: model.model, effort,
        instructions: instructions(answerSettings.style, answerSettings.strict), prompt: prompt.text, signal: controller.signal,
        onThread: () => sessions.save(target),
        onAccepted: async () => { target.transcriptCursor = Math.max(startCursor, prompt.cursor); await sessions.save(target); },
        toolHandler: async (name, args) => { exchange.toolCalls.push({ tool: name, arguments: args }); const result = await tools.call(name, args); await sessions.save(target); return result; },
        onEvent: event => {
          if (event.type === 'answer.delta') {
            exchange.text += event.delta;
            if (Date.now() - lastPartialSave > 500) { lastPartialSave = Date.now(); save(context, target); }
          }
          if (event.type === 'answer.done') {
            exchange.text = event.text;
            const refs = new Set([...event.text.matchAll(/\[(\d+)\]/g)].map(m => Number(m[1])));
            const combined = new Map(exchange.sources.map(s => [s.ref, s]));
            for (const source of target.sources) if (refs.has(source.ref)) { const { key, ...safe } = source; combined.set(source.ref, safe); }
            exchange.sources = [...combined.values()]; sessions.finish(target, exchange, 'completed'); emit({ type: 'answer.sources', sources: exchange.sources });
          }
          if (!controller.signal.aborted) emit({ ...event, exchangeId: exchange.id });
        }
      });
      if (exchange.status === 'inProgress') sessions.finish(target, exchange, 'interrupted');
    } catch (error) {
      if (exchange) sessions.finish(target, exchange, controller.signal.aborted ? 'interrupted' : 'failed');
      if (!controller.signal.aborted) emit({ type: 'answer.error', message: error.message });
    } finally {
      if (exchange) { await sessions.save(target); if (exchange.status === 'interrupted') emit({ type: 'answer.cancelled', text: exchange.text }); }
    }
  }
  const transcript = event => {
    if (event.owner !== owner || !session || opening) return;
    const context = project, target = session, { owner: _, ...safe } = event;
    broadcast(context, target, safe);
    if (!event.final || !event.text) return;
    context.sessions.addTranscript(target, safe); save(context, target);
    if (event.source === 'remote' && settings.auto && Date.now() >= contextPendingUntil && event.text.length >= 6) {
      clearTimeout(timer); timer = setTimeout(() => queueAnswer(event.text), 250);
    }
  };
  const speechStatus = event => send(event);
  const notification = ({ method }) => { if (method === 'account/login/completed') getStatus().then(s => send({ type: 'connection.status', ...s })); };
  speech.on('transcript', transcript); speech.on('status', speechStatus); codex.on('notification', notification);
  send({ type: 'connected', ...speech.snapshot(), protocolVersion: 5 });
  ws.on('message', raw => {
    let event; try { event = JSON.parse(raw.toString()); } catch { return; }
    if (event.projectId && event.projectId !== project.id) return;
    if (event.sessionId && event.sessionId !== session?.id) return;
    if (event.type === 'cancel') { questionRevision++; activeJob()?.controller.abort(); clearTimeout(timer); return; }
    if (event.type === 'project.open') {
      questionRevision++; activeJob()?.controller.abort(); clearTimeout(timer); speech.clear(owner); opening = true;
      operations = operations.catch(() => {}).then(() => openProject(event.id)).catch(error => send({ type: 'project.error', message: error.message })).finally(() => { opening = false; });
      return;
    }
    if (opening) return;
    if (event.type === 'settings') {
      settings = { ...settings, auto: !!event.auto, strict: !!event.strict, style: String(event.style || '').slice(0, 12000), model: String(event.model || ''), effort: String(event.effort || 'low') };
      if (projectClient) project.updatePreferences({ ...settings, clientId: event.clientId, revision: event.revision }).catch(error => send({ type: 'error', message: error.message }));
      if (!settings.auto) clearTimeout(timer); return;
    }
    if (event.type === 'context.prepare') { clearTimeout(timer); contextPendingUntil = Date.now() + 10000; return; }
    if (event.type === 'context.cancel') { contextPendingUntil = 0; return; }
    if (event.type === 'question.context') {
      contextPendingUntil = 0;
      if (!session) { send({ type: 'error', message: 'Сначала откройте разговор.' }); return; }
      try { const { question, ...options } = conversationRequest(session, event.liveTranscript); queueAnswer(question, options); }
      catch (error) { send({ type: 'error', message: error.message }); }
      return;
    }
    if (event.type === 'audio') {
      if (speech.state !== 'ready' || !session) return;
      if (!['remote', 'mic'].includes(event.source) || typeof event.audio !== 'string' || event.audio.length > 900000) return;
      speech.enqueue({ owner, id: String(event.id).slice(0, 100), source: event.source, audio: event.audio, final: !!event.final,
        time: Number(event.time) || Date.now(), language: ['ru', 'en'].includes(event.language) ? event.language : 'ru', prompt: String(event.prompt || '').slice(0, 800) });
      return;
    }
    if (event.type === 'question') { const text = String(event.text || '').trim().slice(0, 12000); if (text) queueAnswer(text); return; }
    if (event.type === 'clear' || event.type === 'session.open') {
      questionRevision++; activeJob()?.controller.abort(); opening = true;
      operations = operations.catch(() => {}).then(() => openSession(event.id, event.type === 'clear' || event.fresh))
        .catch(error => send({ type: 'error', message: error.message })).finally(() => { opening = false; });
    }
  });
  ws.on('close', () => {
    closed = true; clearTimeout(timer); speech.clear(owner); const key = session && conversationKey(project, session); detach();
    if (key && !sessionClients.get(key)?.size) jobs.get(key)?.controller.abort();
    speech.off('transcript', transcript); speech.off('status', speechStatus); codex.off('notification', notification);
  });
}
