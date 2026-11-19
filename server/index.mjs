import express from 'express';
import multer from 'multer';
import { WebSocketServer, WebSocket } from 'ws';
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { Codex } from './codex.mjs';
import { Speech } from './speech.mjs';
import { defaultStyle } from './prompts.mjs';
import { Projects } from './projects.mjs';
import { connectConversation } from './live.mjs';
import { importMaterials } from './imports.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const data = process.env.DIALOG_DATA_DIR || path.join(root, '.local');
const work = path.join(data, 'codex-workspace');
await mkdir(work, { recursive: true });
const projects = new Projects(data); await projects.load();
const { knowledge, sessions } = projects.get();
const codex = new Codex(work), speech = new Speech(root, { data }); await speech.load();
const jobs = new Map();
const sessionClients = new Map();
const port = Number(process.env.PORT || 4317);
const app = express(); app.disable('x-powered-by');
const origins = new Set([`http://localhost:${port}`, `http://127.0.0.1:${port}`]);
app.use((req, res, next) => {
  if (!['localhost', '127.0.0.1'].includes((req.headers.host || '').split(':')[0])) return res.sendStatus(403);
  if (req.headers.origin && !origins.has(req.headers.origin)) return res.sendStatus(403);
  if (req.headers['sec-fetch-site'] === 'cross-site') return res.sendStatus(403);
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' ws://localhost:" + port + ' ws://127.0.0.1:' + port + "; media-src 'self' blob:; frame-ancestors 'none'");
  next();
});
app.use(express.json({ limit: '1mb' }));
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 20 * 1024 * 1024, files: 40 } });
let statusCache = null;
async function getStatus() {
  try { const info = await codex.status(); statusCache = info; return { ...info, protocolVersion: 5, ...speech.snapshot(), defaultStyle }; }
  catch (error) { return { connected: false, protocolVersion: 5, error: error.message, models: [], ...speech.snapshot(), defaultStyle }; }
}
app.get('/api/status', async (req, res) => res.json(await getStatus()));
app.post('/api/login', async (req, res, next) => { try { await codex.start(); const r = await codex.request('account/login/start', { type: 'chatgpt' }); res.json({ url: r.authUrl }); } catch (e) { next(e); } });
app.post('/api/speech/retry', async (req, res, next) => { try { res.json(await speech.select(speech.engine, true)); } catch (e) { next(e); } });
app.post('/api/speech/engine', async (req, res, next) => { try { res.json(await speech.select(req.body.engine)); } catch (e) { next(e); } });
app.get('/api/projects', (req, res) => res.json(projects.list()));
app.get('/api/projects/:projectId', (req, res, next) => { try { res.json(projects.get(req.params.projectId).snapshot()); } catch (e) { next(e); } });
app.post('/api/projects/general/initialize', async (req, res, next) => { try { res.json(await projects.initializeGeneral(req.body)); } catch (e) { next(e); } });
app.post('/api/projects', async (req, res, next) => { try { res.json(await projects.create(req.body.name)); } catch (e) { next(e); } });
app.patch('/api/projects/:projectId', async (req, res, next) => { try { res.json(await projects.rename(req.params.projectId, req.body.name)); } catch (e) { next(e); } });
app.patch('/api/projects/:projectId/settings', async (req, res, next) => {
  try { const project = projects.get(req.params.projectId); await project.updatePreferences(req.body); res.json(project.snapshot()); } catch (e) { next(e); }
});
app.get('/api/projects/:projectId/materials', (req, res, next) => { try { res.json(projects.get(req.params.projectId).knowledge.list()); } catch (e) { next(e); } });
app.post('/api/projects/:projectId/materials', upload.array('files'), async (req, res, next) => {
  try {
    const project = projects.get(req.params.projectId);
    if (!req.files?.length) throw new Error('Выберите файлы');
    const paths = req.body.relativePaths ? JSON.parse(req.body.relativePaths) : null;
    if (paths && (!Array.isArray(paths) || paths.length !== req.files.length)) throw new Error('Пути файлов не совпадают с загрузкой');
    res.json(await importMaterials(project.knowledge, req.files, paths));
  } catch (e) { next(e); }
});
app.delete('/api/projects/:projectId/materials/:id', async (req, res, next) => {
  try { const { knowledge } = projects.get(req.params.projectId); await knowledge.remove(req.params.id); res.json(knowledge.list()); } catch (e) { next(e); }
});
app.get('/api/projects/:projectId/sessions', (req, res, next) => { try { res.json(projects.get(req.params.projectId).sessions.list()); } catch (e) { next(e); } });
app.get('/api/projects/:projectId/sessions/:id', (req, res, next) => {
  try { const { sessions } = projects.get(req.params.projectId); res.json(sessions.snapshot(sessions.get(req.params.id))); } catch (e) { next(e); }
});
app.get('/api/materials', (req, res) => res.json(knowledge.list()));
app.post('/api/materials', upload.array('files'), async (req, res, next) => {
  try {
    if (!req.files?.length) throw new Error('Выберите файлы');
    const paths = req.body.relativePaths ? JSON.parse(req.body.relativePaths) : null;
    if (paths && (!Array.isArray(paths) || paths.length !== req.files.length)) throw new Error('Пути файлов не совпадают с загрузкой');
    res.json(await importMaterials(knowledge, req.files, paths));
  } catch (e) { next(e); }
});
app.delete('/api/materials/:id', async (req, res, next) => { try { await knowledge.remove(req.params.id); res.json(knowledge.list()); } catch (e) { next(e); } });
app.get('/api/sessions', (req, res) => res.json(sessions.list()));
app.get('/api/sessions/:id', (req, res, next) => { try { res.json(sessions.snapshot(sessions.get(req.params.id))); } catch (e) { next(e); } });
app.use(express.static(path.join(root, 'public')));
app.use((err, req, res, next) => { res.status(400).json({ error: err.message || 'Ошибка запроса' }); });
const server = createServer(app);
const wss = new WebSocketServer({ noServer: true, maxPayload: 2 * 1024 * 1024 });
server.on('upgrade', (req, socket, head) => {
  if (req.url !== '/live' || !origins.has(req.headers.origin)) return socket.destroy();
  wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws));
});
wss.on('connection', ws => connectConversation(ws, { projects, codex, speech, getStatus, cachedStatus: () => statusCache, jobs, sessionClients }));
server.listen(port, '127.0.0.1', () => {
  console.log(`Диалог открыт: http://localhost:${port}`);
  getStatus().catch(() => {});
  try { if (process.env.DIALOG_DISABLE_SPEECH !== '1') speech.start(); } catch (error) { speech.problem(error.message); }
});
async function shutdown() {
  for (const job of jobs.values()) job.controller.abort();
  for (const ws of wss.clients) ws.close();
  await speech.close(); codex.close();
  await Promise.allSettled([...jobs.values()].map(job => job.promise));
  await projects.flush(); server.close(); setTimeout(() => process.exit(0), 700).unref();
}
process.on('SIGINT', shutdown); process.on('SIGTERM', shutdown);
