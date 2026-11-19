import { CallAudio } from './audio.js';

const $ = id => document.getElementById(id);
const transcriptEmptyMarkup = $('transcript').innerHTML;
const paths = {
  radio:'<circle cx="12" cy="12" r="2"/><path d="M7 7a7 7 0 0 0 0 10M17 7a7 7 0 0 1 0 10M4 4a11 11 0 0 0 0 16M20 4a11 11 0 0 1 0 16"/>',
  layers:'<path d="m12 3 9 5-9 5-9-5 9-5ZM3 12l9 5 9-5M3 16l9 5 9-5"/>',
  sliders:'<path d="M4 7h6m4 0h6M4 17h10m4 0h2"/><circle cx="12" cy="7" r="2"/><circle cx="16" cy="17" r="2"/>',
  plus:'<path d="M12 5v14M5 12h14"/>', upload:'<path d="M12 16V3m-5 5 5-5 5 5M4 15v5h16v-5"/>',
  shield:'<path d="M12 3 4 6v6c0 4 8 9 8 9s8-5 8-9V6l-8-3Z"/><path d="m8 12 3 3 5-6"/>',
  chevron:'<path d="m9 5 7 7-7 7"/>', settings:'<path d="m9 3 6 0 1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1 1-3Z"/><circle cx="12" cy="12" r="3"/>',
  play:'<path d="m8 4 13 8-13 8V4Z"/>', stop:'<rect x="5" y="5" width="14" height="14" rx="2"/>',
  download:'<path d="M12 3v13m-5-5 5 5 5-5M4 17v4h16v-4"/>', refresh:'<path d="M20 9a8 8 0 1 0 0 7M20 3v6h-6"/>',
  sparkles:'<path d="m12 3 2.6 6.4L21 12l-6.4 2.6L12 21l-2.6-6.4L3 12l6.4-2.6L12 3ZM20 2v4M18 4h4"/>',
  copy:'<rect x="8" y="8" width="12" height="13" rx="2"/><path d="M16 8V3H3v13h5"/>',
  arrow:'<path d="M4 12h15m-6-6 6 6-6 6"/>', message:'<path d="M4 4h16v13H9l-5 4V4Z"/><path d="M8 9h8M8 13h5"/>',
  monitor:'<rect x="3" y="3" width="18" height="13" rx="2"/><path d="M8 21h8m-4-5v5"/>',
  mic:'<rect x="9" y="2" width="6" height="13" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3m-4 0h8"/>',
  headphones:'<path d="M4 14v-3a8 8 0 0 1 16 0v3"/><rect x="3" y="12" width="4" height="8" rx="2"/><rect x="17" y="12" width="4" height="8" rx="2"/>',
  corner:'<path d="M5 4v10a3 3 0 0 0 3 3h11m-5-5 5 5-5 5"/>', lock:'<rect x="5" y="10" width="14" height="12" rx="2"/><path d="M8 10V6a4 4 0 0 1 8 0v4"/>',
  x:'<path d="m6 6 12 12M18 6 6 18"/>', search:'<circle cx="10" cy="10" r="7"/><path d="m15 15 6 6"/>',
  check:'<path d="m4 12 5 5L20 6"/>', file:'<path d="M5 3h9l5 5v13H5V3Zm9 0v6h5M8 13h8M8 17h6"/>',
  trash:'<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/>'
};
function icon(name) { return `<svg viewBox="0 0 24 24" aria-hidden="true">${paths[name] || paths.file}</svg>`; }
function icons(root = document) { root.querySelectorAll('[data-icon]').forEach(el => { el.innerHTML = icon(el.dataset.icon); }); }
icons();
let prefs; try { prefs = JSON.parse(localStorage.getItem('dialog.settings') || '{}'); } catch { prefs = {}; }
let status = null, socket, reconnectTimer, running = false, starting = false, call, startedAt = 0, timer, answer = '', answerHistory = [], entries = new Map(), documents = [], toastTimer;
const config = { auto: true, strict: false, style: '', model: '', effort: 'low', language: 'ru', pause: 480, microphone: true, font: 25, ...prefs };
function toast(text, error = false) { $('toast').textContent = text; $('toast').classList.toggle('error', error); $('toast').classList.remove('hidden'); clearTimeout(toastTimer); toastTimer = setTimeout(() => $('toast').classList.add('hidden'), error ? 10000 : 3500); }
async function api(url, options) { const res = await fetch(url, options); let data; try { data = await res.json(); } catch { throw new Error('Сервер не ответил. Проверьте, что npm start запущен.'); } if (!res.ok) throw new Error(data.error || 'Ошибка запроса'); return data; }
function save() { localStorage.setItem('dialog.settings', JSON.stringify(config)); sendSettings(); }
function send(event) { if (socket?.readyState !== WebSocket.OPEN) { toast('Нет связи с локальным сервером', true); return false; } socket.send(JSON.stringify(event)); return true; }
function sendSettings() { if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: 'settings', ...config })); }
function connect() {
  socket = new WebSocket(`ws://${location.host}/live`);
  socket.onopen = () => { clearTimeout(reconnectTimer); sendSettings(); };
  socket.onmessage = ({ data }) => { try { handle(JSON.parse(data)); } catch (e) { console.error(e); } };
  socket.onclose = () => { if (running || starting) stopCall(); setGenerating(false); $('liveStatus').textContent = 'Нет связи с сервером'; reconnectTimer = setTimeout(() => { connect(); loadStatus(); }, 2500); };
}
function setGenerating(value) { $('answerText').classList.toggle('generating', value); $('cancelAnswer').classList.toggle('hidden', !value); }
function handle(event) {
  if (event.type === 'connected') {
    const id = localStorage.getItem('dialog.session'); send({ type: 'session.open', ...(id ? { id } : {}) });
  }
  if (event.type === 'session.snapshot') {
    const session = event.session; localStorage.setItem('dialog.session', session.id);
    entries.clear(); $('transcript').innerHTML = transcriptEmptyMarkup;
    for (const item of session.transcript) renderTranscript(item);
    answerHistory = session.exchanges.map(e => ({ question: e.question, answer: e.text, sources: e.sources, time: new Date(e.time).toISOString() }));
    const last = session.exchanges.at(-1); answer = last?.text || '';
    $('onboarding').classList.toggle('hidden', !!last); $('answerContent').classList.toggle('hidden', !last);
    $('answerText').textContent = answer; $('currentQuestion').textContent = last?.question || '';
    $('sources').replaceChildren(); if (last) renderSources(last.sources);
    setGenerating(last?.status === 'inProgress'); $('answerState').textContent = last ? 'Готово' : '';
  }
  if (event.type === 'answer.sources') { $('sources').replaceChildren(); renderSources(event.sources); }
  if (event.type === 'agent.tool') $('answerState').textContent = event.tool === 'read_material' ? 'Читаю материал…' : event.tool === 'conversation_history' ? 'Смотрю историю…' : 'Ищу в материалах…';
  if (event.type === 'agent.compacting') $('answerState').textContent = 'Обновляю контекст…';
  if (event.type === 'transcript') renderTranscript(event);
  if (event.type === 'answer.start') {
    answer = ''; $('onboarding').classList.add('hidden'); $('answerContent').classList.remove('hidden'); $('currentQuestion').textContent = event.question;
    $('answerText').textContent = ''; $('sources').replaceChildren(); $('answerState').textContent = 'Codex формулирует ответ…';
    renderSources(event.sources); setGenerating(true); $('answerScroll').scrollTop = 0;
    answerHistory.push({ question: event.question, answer: '', sources: event.sources, time: new Date().toISOString() });
  }
  if (event.type === 'answer.delta') { answer += event.delta; $('answerText').textContent = answer; $('answerState').textContent = `Первый текст за ${(event.firstToken / 1000).toFixed(1)} с`; }
  if (event.type === 'answer.done') { setGenerating(false); answer = event.text; $('answerText').textContent = answer; $('answerState').textContent = `Готово · первый текст ${(event.firstToken / 1000).toFixed(1)} с`; if (answerHistory.length) answerHistory.at(-1).answer = answer; }
  if (event.type === 'answer.error') { setGenerating(false); $('answerState').textContent = 'Не удалось получить ответ'; if (!answer) $('answerText').textContent = event.message; toast(event.message, true); }
  if (event.type === 'answer.cancelled') { setGenerating(false); answer = event.text || answer; $('answerText').textContent = answer; $('answerState').textContent = 'Ответ остановлен'; }
  if (event.type === 'connection.status') applyStatus(event);
  if (event.type.startsWith('speech.')) { if (status) { status.speech = event.type.split('.')[1]; status.speechError = event.message; } renderSpeech(event.type.split('.')[1], event.message); }
  if (event.type === 'error') toast(event.message, true);
}
function renderTranscript(event) {
  if (!event.text) {
    const entry = entries.get(event.id);
    if (event.final && entry && !entry.final) { entry.element.remove(); entries.delete(event.id); }
    return;
  }
  $('transcriptEmpty')?.remove();
  let entry = entries.get(event.id);
  if (entry?.final && !event.final) return;
  const nearBottom = $('transcript').scrollHeight - $('transcript').scrollTop - $('transcript').clientHeight < 70;
  if (!entry) {
    const element = document.createElement('article'); element.className = 'transcript-entry';
    const meta = document.createElement('div'), label = document.createElement('strong'), time = document.createElement('span'), text = document.createElement('p'), use = document.createElement('button');
    label.textContent = event.source === 'remote' ? 'Собеседник' : 'Я'; time.textContent = new Date(event.time).toLocaleTimeString('ru', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    meta.append(label, time); use.textContent = 'Ответить ↗'; use.addEventListener('click', () => send({ type: 'question', text: entries.get(event.id).text }));
    element.append(meta, text, use); entry = { element, paragraph: text, source: event.source, time: event.time }; entries.set(event.id, entry);
  }
  Object.assign(entry, { text: event.text, final: event.final }); entry.paragraph.textContent = event.text;
  entry.element.classList.toggle('mine', event.source === 'mic'); entry.element.classList.toggle('partial', !event.final);
  [...entries.values()].sort((a, b) => a.time - b.time).forEach(e => $('transcript').append(e.element));
  if (nearBottom) $('transcript').scrollTop = $('transcript').scrollHeight;
}
function renderSources(sources) {
  if (!sources.length) { const p = document.createElement('p'); p.className = 'field-help'; p.textContent = config.strict ? 'Подходящих фрагментов в базе не найдено.' : 'Подходящих фрагментов не найдено. Codex может использовать общие знания.'; $('sources').append(p); return; }
  for (const source of sources) {
    const details = document.createElement('details'), summary = document.createElement('summary'), content = document.createElement('pre'); details.className = 'source-detail';
    summary.textContent = `[${source.ref}] ${source.name} · строка ${source.line}`; content.textContent = source.text; details.append(summary, content); $('sources').append(details);
  }
}
async function loadStatus() { try { applyStatus(await api('/api/status')); } catch (e) { toast(e.message, true); } }
function applyStatus(value) {
  status = value;
  $('codexConnection').textContent = value.connected ? 'Codex подключён через ChatGPT' : 'Войдите в Codex через ChatGPT';
  $('loginButton').classList.toggle('hidden', value.connected);
  if (!config.style) config.style = value.defaultStyle || '';
  const models = (value.models || []).filter(m => m.model.startsWith('gpt-'));
  $('modelSelect').replaceChildren(...models.map(m => new Option(m.displayName, m.model)));
  if (!models.some(m => m.model === config.model)) config.model = models.find(m => /luna|mini/.test(m.model))?.model || models.find(m => m.isDefault)?.model || models[0]?.model || '';
  $('modelSelect').value = config.model; refreshEfforts();
  renderSpeech(value.speech, value.speechError); sendSettings();
}
function renderSpeech(state, message) {
  $('speechDot').className = 'status-dot ' + (state === 'ready' ? 'ready' : state === 'error' ? 'error' : '');
  $('speechStatus').textContent = state === 'ready' ? 'Whisper готов к разговору' : state === 'error' ? 'Распознавание недоступно' : 'Whisper загружается…';
  $('speechDetail').textContent = message || (state === 'ready' ? 'Локальная модель base · аудио не отправляется в облако' : 'Первый запуск скачивает модель. Это может занять несколько минут.');
  if (!running && !starting) $('liveStatus').textContent = state === 'ready' ? '' : state === 'error' ? 'Распознавание недоступно' : 'Загрузка…';
}
function refreshEfforts() {
  const model = status?.models.find(m => m.model === $('modelSelect').value);
  const values = model?.supportedReasoningEfforts || [];
  $('effortSelect').replaceChildren(...values.map(e => new Option(e.reasoningEffort === 'low' ? 'Low · быстрее' : e.reasoningEffort, e.reasoningEffort)));
  if (!values.some(e => e.reasoningEffort === config.effort)) config.effort = values.find(e => ['none', 'minimal', 'low'].includes(e.reasoningEffort))?.reasoningEffort || model?.defaultReasoningEffort || 'low';
  $('effortSelect').value = config.effort;
}
async function startCall() {
  if (starting) return;
  if (running) return stopCall();
  if (!status?.connected) { openSettings('connection'); toast('Сначала подключите подписку Codex', true); return; }
  if (status?.speech !== 'ready') { await loadStatus(); if (status?.speech !== 'ready') { openSettings('connection'); toast('Локальный Whisper ещё не готов. Пока можно ввести вопрос вручную.', true); return; } }
  if (!navigator.mediaDevices?.getDisplayMedia || !window.AudioWorkletNode) { toast('Откройте приложение в Google Chrome или Edge, чтобы передавать звук вкладки Meet.', true); return; }
  starting = true; $('startCall').disabled = true; $('liveStatus').textContent = 'Выберите вкладку со звонком…';
  call = new CallAudio(event => { if (socket?.readyState === WebSocket.OPEN && socket.bufferedAmount < 2_000_000) socket.send(JSON.stringify(event)); }, level, () => { if (running) { toast('Передача звука завершена'); stopCall(); } });
  try {
    await call.start({ microphone: config.microphone, language: config.language, pause: Number(config.pause), threshold: 0.009 });
    running = true; startedAt = Date.now(); $('startCall').classList.add('running'); $('startCall').innerHTML = icon('stop') + '<span>Завершить</span>'; $('micEnabled').disabled = true;
    $('liveStatus').textContent = 'Слушаем разговор'; $('liveDot').classList.add('live'); $('liveDot').classList.remove('hidden'); $('transcriptBadge').classList.remove('hidden'); $('transcriptBadge').textContent = 'НА СВЯЗИ';
    timer = setInterval(() => { const sec = Math.floor((Date.now() - startedAt) / 1000); $('sessionTime').textContent = `${Math.floor(sec / 60).toString().padStart(2, '0')}:${(sec % 60).toString().padStart(2, '0')}`; }, 1000);
  } catch (e) { if (e.name !== 'NotAllowedError') toast(e.message, true); else toast('Доступ к звуку не предоставлен. Можно подключиться снова.'); renderSpeech(status.speech); }
  finally { starting = false; $('startCall').disabled = false; }
}
async function stopCall() {
  if (!call) return; const stopped = call; call = null; running = false; starting = false; clearInterval(timer);
  await stopped.stop(); $('startCall').disabled = false; $('startCall').classList.remove('running'); $('startCall').innerHTML = icon('play') + '<span>Слушать</span>'; $('micEnabled').disabled = false;
  $('liveDot').classList.remove('live'); $('liveDot').classList.add('hidden'); $('transcriptBadge').classList.add('hidden'); $('transcriptBadge').textContent = 'ОЖИДАНИЕ'; $('liveStatus').textContent = ''; level('remote', 0); level('mic', 0);
}
let lastLevel = {};
function level(source, value) { if (Date.now() - (lastLevel[source] || 0) < 70 && value) return; lastLevel[source] = Date.now(); const meter = $(source + 'Meter'); meter.classList.toggle('active', value > .008); [...meter.children].forEach((bar, i) => { bar.style.height = `${3 + Math.min(15, value * 180) * [0.45, .75, 1, .7, .4][i]}px`; }); }
function openLibrary() { renderMaterials(); $('libraryDialog').showModal(); }
function openSettings(tab = 'style') { $('styleInput').value = config.style; $('strictMaterials').checked = config.strict; $('modelSelect').value = config.model; $('languageSelect').value = config.language; $('pauseSelect').value = String(config.pause); refreshEfforts(); switchTab(tab); $('settingsDialog').showModal(); }
function switchTab(tab) { document.querySelectorAll('[data-tab]').forEach(b => b.classList.toggle('active', b.dataset.tab === tab)); $('styleTab').classList.toggle('hidden', tab !== 'style'); $('connectionTab').classList.toggle('hidden', tab !== 'connection'); }
async function loadMaterials() { try { documents = await api('/api/materials'); renderMaterials(); } catch (e) { toast(e.message, true); } }
function renderMaterials() {
  $('fileCount').textContent = documents.length; $('materialList').replaceChildren(); $('sidebarFiles').replaceChildren();
  if (!documents.length) { $('materialList').innerHTML = '<p class="material-empty">Материалы пока не добавлены</p>'; }
  for (const doc of documents) {
    const row = document.createElement('div'); row.className = 'material-row'; const image = document.createElement('i'); image.innerHTML = icon('file');
    const info = document.createElement('div'), name = document.createElement('strong'), meta = document.createElement('small'), remove = document.createElement('button');
    name.textContent = doc.name; meta.textContent = `${doc.characters.toLocaleString('ru')} символов · ${doc.chunks} фрагм.`; info.append(name, meta);
    remove.className = 'icon-button'; remove.setAttribute('aria-label', `Удалить ${doc.name}`); remove.innerHTML = icon('trash');
    remove.onclick = async () => { try { documents = await api('/api/materials/' + doc.id, { method: 'DELETE' }); renderMaterials(); } catch (e) { toast(e.message, true); } };
    row.append(image, info, remove); $('materialList').append(row);
    const side = document.createElement('div'); side.className = 'side-file'; side.innerHTML = icon('file'); const label = document.createElement('span'); label.textContent = doc.name; side.title = doc.name; side.append(label); $('sidebarFiles').append(side);
  }
}
async function upload(files) {
  if (!files.length) return; $('dropzone').disabled = true; $('uploadStatus').textContent = 'Читаем файлы…';
  try {
    let errors = [];
    const all = [...files];
    for (let offset = 0; offset < all.length; offset += 20) {
      const batch = all.slice(offset, offset + 20), body = new FormData();
      batch.forEach(f => body.append('files', f)); body.append('relativePaths', JSON.stringify(batch.map(f => f.webkitRelativePath || f.name)));
      $('uploadStatus').textContent = `Добавляем ${Math.min(offset + 20, all.length)} из ${all.length}…`;
      const result = await api('/api/materials', { method: 'POST', body }); documents = result.documents; errors.push(...result.errors); renderMaterials();
    }
    $('uploadStatus').textContent = errors.length ? errors.slice(0, 8).join('\n') : `Готово. В базе ${documents.length} файл(ов).`;
  } catch (e) { $('uploadStatus').textContent = e.message; }
  finally { $('dropzone').disabled = false; $('fileInput').value = ''; if ($('folderInput')) $('folderInput').value = ''; }
}
function ask(event) { event.preventDefault(); const text = $('questionInput').value.trim(); if (text && send({ type: 'question', text })) $('questionInput').value = ''; }
function exportSession() {
  const lines = ['# Диалог', new Date().toLocaleString('ru'), '', '## Расшифровка', ...[...entries.values()].sort((a, b) => a.time - b.time).map(e => `\n**${e.source === 'remote' ? 'Собеседник' : 'Я'}:** ${e.text}`), '\n## Ответы', ...answerHistory.map(a => `\n### ${a.question}\n\n${a.answer}\n\n${a.sources.map(s => `[${s.ref}] ${s.name}, строка ${s.line}`).join('\n')}`)];
  const blob = new Blob([lines.join('\n')], { type: 'text/markdown;charset=utf-8' }); const url = URL.createObjectURL(blob), a = document.createElement('a'); a.href = url; a.download = `dialog-${new Date().toISOString().slice(0, 10)}.md`; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
['libraryNav', 'uploadSide', 'stepUpload'].forEach(id => $(id).onclick = openLibrary);
['styleNav', 'stepStyle'].forEach(id => $(id).onclick = () => openSettings('style'));
['settingsButton'].forEach(id => $(id).onclick = () => openSettings('connection'));
['startCall', 'stepCall'].forEach(id => $(id).onclick = startCall);
$('sessionNav').onclick = () => $('questionInput').focus();
$('questionForm').onsubmit = ask; $('exportSession').onclick = exportSession;
$('cancelAnswer').onclick = () => { send({ type: 'cancel' }); setGenerating(false); $('answerState').textContent = 'Ответ остановлен'; };
$('clearSession').onclick = async () => { if (running) await stopCall(); send({ type: 'clear' }); entries.clear(); answerHistory = []; answer = ''; $('transcript').innerHTML = transcriptEmptyMarkup; $('answerContent').classList.add('hidden'); $('onboarding').classList.remove('hidden'); $('sessionTime').textContent = ''; $('answerState').textContent = ''; setGenerating(false); };
$('copyAnswer').onclick = async () => { if (!answer) return; try { await navigator.clipboard.writeText(answer); toast('Ответ скопирован'); } catch { toast('Не удалось скопировать ответ', true); } };
$('autoAnswer').checked = config.auto; $('autoAnswer').onchange = e => { config.auto = e.target.checked; save(); };
$('micEnabled').checked = config.microphone; $('micEnabled').onchange = e => { config.microphone = e.target.checked; save(); };
function changeFont(delta) { config.font = Math.max(16, Math.min(40, config.font + delta)); document.documentElement.style.setProperty('--answer-size', config.font + 'px'); save(); }
$('smallerFont').onclick = () => changeFont(-2); $('largerFont').onclick = () => changeFont(2); changeFont(0);
document.querySelectorAll('.close-modal').forEach(b => b.onclick = () => b.closest('dialog').close());
document.querySelectorAll('dialog').forEach(d => d.addEventListener('click', e => { if (e.target === d) { const r = d.getBoundingClientRect(); if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) d.close(); } }));
document.querySelectorAll('[data-tab]').forEach(b => b.onclick = () => switchTab(b.dataset.tab));
const presets = { short: 'Отвечай по-русски в 2–4 коротких предложениях. Сразу начинай с сути. Используй разговорный язык, без вступлений и канцелярита. Текст должен быть удобен для устного ответа.', explain: 'Отвечай по-русски простым разговорным языком. Сначала прямой ответ, затем объяснение идеи и один понятный пример. Не больше трёх коротких абзацев. Сложные термины кратко объясняй.', code: 'Отвечай по-русски как разработчик на обсуждении проекта: коротко, точно, разговорно. Сначала объясни идею и зачем она нужна. Учитывай код из материалов. Показывай минимальный код только при необходимости. Не выдумывай детали проекта.' };
document.querySelectorAll('[data-preset]').forEach(b => b.onclick = () => { $('styleInput').value = presets[b.dataset.preset]; });
$('modelSelect').onchange = () => { config.effort = 'low'; refreshEfforts(); };
$('saveSettings').onclick = () => { Object.assign(config, { style: $('styleInput').value, strict: $('strictMaterials').checked, model: $('modelSelect').value, effort: $('effortSelect').value, language: $('languageSelect').value, pause: Number($('pauseSelect').value) }); save(); $('settingsDialog').close(); toast(running ? 'Сохранено. Настройки звука применятся после переподключения.' : 'Настройки сохранены'); };
$('loginButton').onclick = async () => { const popup = window.open('about:blank', '_blank'); try { const data = await api('/api/login', { method: 'POST' }); if (!data.url) throw new Error('Codex не вернул ссылку входа'); if (popup) { popup.opener = null; popup.location = data.url; } else toast('Разрешите открытие окна входа в браузере', true); } catch (e) { popup?.close(); toast(e.message, true); } };
$('retrySpeech').onclick = async () => { try { await api('/api/speech/retry', { method: 'POST' }); await loadStatus(); } catch (e) { toast(e.message, true); } };
$('dropzone').onclick = () => $('fileInput').click(); $('fileInput').onchange = e => upload(e.target.files);
$('folderInput').onchange = e => upload(e.target.files); $('folderButton').onclick = () => $('folderInput').click();
for (const event of ['dragenter', 'dragover']) $('dropzone').addEventListener(event, e => { e.preventDefault(); $('dropzone').classList.add('dragging'); });
for (const event of ['dragleave', 'drop']) $('dropzone').addEventListener(event, e => { e.preventDefault(); $('dropzone').classList.remove('dragging'); if (event === 'drop') upload(e.dataTransfer.files); });
window.addEventListener('beforeunload', e => { if (running) { e.preventDefault(); e.returnValue = ''; } });
connect(); loadStatus(); loadMaterials();
// Check download completion while the first local model is warming up.
const warmupPoll = setInterval(async () => { if (status?.speech === 'ready' || status?.speech === 'error') { clearInterval(warmupPoll); return; } await loadStatus(); }, 8000);
