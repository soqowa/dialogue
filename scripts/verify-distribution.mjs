import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawn } from 'node:child_process';

const app = path.resolve(process.argv[2]);
const resources = path.join(app, 'Contents/Resources');
const runtime = path.join(resources, 'Runtime');
const root = path.join(resources, 'Service');
const data = await mkdtemp(path.join(tmpdir(), 'dialog-distribution-data-'));
const spokenFixture = process.argv[3] ? await readFile(process.argv[3]) : null;
const report = { relocatedApp: app, developerToolsOnPath: false, engines: [] };
const env = { ...process.env, PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
  DIALOG_DATA_DIR: data,
  DIALOG_PYTHON: path.join(runtime, 'python/bin/python3.11'),
  DIALOG_CODEX_BIN: path.join(runtime, 'codex/bin/codex'),
  DIALOG_SPEECH_HELPER: path.join(app, 'Contents/MacOS/DialogSpeech'),
  DIALOG_VAD_MODEL: path.join(resources, 'Models/silero_vad.onnx'),
  PYTHONNOUSERSITE: '1', PYTHONDONTWRITEBYTECODE: '1',
  SSL_CERT_FILE: path.join(runtime, 'python/lib/python3.11/site-packages/certifi/cacert.pem'),
};
delete env.PYTHONPATH; delete env.PYTHONHOME;
Object.assign(process.env, env);
delete process.env.PYTHONPATH; delete process.env.PYTHONHOME;
let backend, backendError = '';
const { Speech } = await import(pathToFileURL(path.join(root, 'server/speech.mjs')));
const speech = new Speech(root, { data });
function waitFor(emitter, event, predicate, timeout = 120000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => done(new Error(event + ' timed out: ' + speech.stderr)), timeout);
    const handler = value => {
      if (value.type === 'speech.error') done(new Error(value.message + '\n' + speech.stderr));
      else if (predicate(value)) done(null, value);
    };
    function done(error, value) { clearTimeout(timer); emitter.off(event, handler); error ? reject(error) : resolve(value); }
    emitter.on(event, handler);
  });
}
try {
  const entries = await readdir(resources);
  assert(!entries.includes('project-root.txt'));
  assert(!entries.includes('.local'));
  await speech.load();
  for (const engine of ['parakeet', 'gigaam', 'whisper-turbo', 'whisper-base']) {
    const ready = waitFor(speech, 'status', value => value.type === 'speech.ready');
    await speech.select(engine, true); await ready;
    const transcript = waitFor(speech, 'transcript', value => value.id === engine, 30000);
    speech.enqueue({ owner: 'distribution-verification', source: 'mic', id: engine,
      audio: Buffer.alloc(32000).toString('base64'), final: true, time: 1, language: 'ru' });
    const result = await transcript;
    assert.equal(result.text, '');
    const check = { engine, ready: true, silenceSuppressed: true };
    if (spokenFixture) {
      const recognized = waitFor(speech, 'transcript', value => value.id === engine + '-speech', 60000);
      speech.enqueue({ owner: 'distribution-verification', source: 'mic', id: engine + '-speech',
        audio: spokenFixture.toString('base64'), final: true, time: 2, language: 'ru' });
      const result = await recognized;
      assert.match(result.text, /[а-яё]{3}/i, engine + ' did not recognize the Russian fixture');
      check.recognizedRussianSpeech = true;
    }
    report.engines.push(check);
    console.log('Verified bundled ' + engine);
  }
  await speech.close();
  backend = spawn(path.join(runtime, 'node/bin/node'), [path.join(root, 'server/index.mjs')], {
    cwd: tmpdir(), env: { ...env, PORT: '4324', DIALOG_DISABLE_SPEECH: '1' }, stdio: ['ignore', 'pipe', 'pipe'],
  });
  backend.stderr.on('data', chunk => { backendError = (backendError + chunk).slice(-8000); });
  const deadline = Date.now() + 60000;
  let status;
  while (Date.now() < deadline) {
    if (backend.exitCode != null) throw new Error('Bundled service exited: ' + backendError);
    try { const response = await fetch('http://127.0.0.1:4324/api/status', { signal: AbortSignal.timeout(15000) }); status = await response.json(); break; }
    catch { await new Promise(resolve => setTimeout(resolve, 200)); }
  }
  assert(status, 'Bundled service never became ready');
  assert.equal(status.protocolVersion, 5);
  assert(!status.error, status.error);
  const projects = await (await fetch('http://127.0.0.1:4324/api/projects')).json();
  assert.equal(projects.length, 1); assert.equal(projects[0].name, 'Общее');
  const materials = await (await fetch('http://127.0.0.1:4324/api/projects/general/materials')).json();
  const sessions = await (await fetch('http://127.0.0.1:4324/api/projects/general/sessions')).json();
  assert.equal(materials.length, 0); assert.equal(sessions.length, 0);
  report.backend = { ready: true, protocolVersion: status.protocolVersion, codexAccountRead: true, modelCatalogRead: true,
    modelCount: status.models.length, emptyGeneralProject: true, importedUserData: false };
  console.log(JSON.stringify(report, null, 2));
} finally {
  await speech.close();
  if (backend && backend.exitCode == null) {
    const exited = new Promise(resolve => backend.once('exit', resolve));
    backend.kill('SIGTERM');
    const timer = setTimeout(() => backend.kill('SIGKILL'), 5000);
    await exited; clearTimeout(timer);
  }
  await rm(data, { recursive: true, force: true });
}
