import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { Knowledge } from './knowledge.mjs';
import { Sessions } from './sessions.mjs';
import { defaultStyle } from './prompts.mjs';

export const GENERAL_PROJECT = 'general';
const defaults = () => ({ style: defaultStyle, strict: false, model: '', effort: 'low', lastSessionId: null, initialized: false });
const cleanSettings = (value = {}) => ({
  ...(typeof value.style === 'string' ? { style: value.style.slice(0, 12000) } : {}),
  ...(typeof value.strict === 'boolean' ? { strict: value.strict } : {}),
  ...(typeof value.model === 'string' ? { model: value.model.slice(0, 150) } : {}),
  ...(typeof value.effort === 'string' ? { effort: value.effort.slice(0, 30) } : {}),
});

class ProjectContext {
  constructor(root, metadata) {
    this.metadata = metadata;
    this.id = metadata.id;
    // Keep existing data in place: it becomes the permanent General project.
    this.folder = this.id === GENERAL_PROJECT ? root : path.join(root, 'projects', this.id);
    this.work = path.join(this.folder, 'codex-workspace');
    this.knowledge = new Knowledge(this.folder);
    this.sessions = new Sessions(path.join(this.folder, 'sessions'));
    this.preferences = defaults(); this.saving = Promise.resolve(); this.preferenceRevisions = new Map();
  }
  async load() {
    await mkdir(this.work, { recursive: true });
    await this.knowledge.load(); await this.sessions.load();
    try { this.preferences = { ...defaults(), ...JSON.parse(await readFile(path.join(this.folder, 'project-settings.json'), 'utf8')) }; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  info() { return { ...this.metadata, isGeneral: this.id === GENERAL_PROJECT }; }
  snapshot() { return { ...this.info(), settings: this.preferences }; }
  updatePreferences(value) {
    if (typeof value.clientId === 'string' && Number.isSafeInteger(value.revision)) {
      if ((this.preferenceRevisions.get(value.clientId) ?? -1) >= value.revision) return this.saving;
      this.preferenceRevisions.set(value.clientId, value.revision);
    }
    Object.assign(this.preferences, cleanSettings(value), { initialized: true });
    return this.savePreferences();
  }
  savePreferences() {
    const file = path.join(this.folder, 'project-settings.json'), data = JSON.stringify(this.preferences);
    this.saving = this.saving.catch(() => {}).then(async () => {
      await writeFile(file + '.tmp', data, { mode: 0o600 }); await rename(file + '.tmp', file);
    });
    return this.saving;
  }
  async rememberSession(session) { this.preferences.lastSessionId = session.id; await this.savePreferences(); }
  async flush() { await Promise.all([this.knowledge.saving, this.sessions.flush(), this.saving]); }
}

export class Projects {
  constructor(folder) { this.folder = folder; this.items = new Map(); this.mutations = Promise.resolve(); }
  async load() {
    await mkdir(this.folder, { recursive: true });
    let metadata;
    try { metadata = JSON.parse(await readFile(path.join(this.folder, 'projects.json'), 'utf8')).projects; }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (metadata !== undefined && !Array.isArray(metadata)) throw new Error('Повреждён список проектов.');
    const general = { id: GENERAL_PROJECT, name: 'Общее', createdAt: Date.now() };
    const entries = metadata || [general];
    if (!entries.some(p => p.id === GENERAL_PROJECT)) entries.unshift(general);
    for (const entry of entries) {
      if (entry.id !== GENERAL_PROJECT && !/^[\da-f-]{36}$/.test(entry.id)) throw new Error('Некорректный идентификатор проекта.');
      const context = new ProjectContext(this.folder, entry.id === GENERAL_PROJECT ? { ...entry, name: 'Общее' } : entry);
      await context.load(); this.items.set(entry.id, context);
    }
    if (!metadata) await this.saveRegistry();
  }
  list() { return [...this.items.values()].sort((a, b) => a.id === GENERAL_PROJECT ? -1 : b.id === GENERAL_PROJECT ? 1 : a.metadata.createdAt - b.metadata.createdAt).map(p => p.info()); }
  get(id = GENERAL_PROJECT) {
    const context = this.items.get(id); if (!context) throw new Error('Проект не найден.'); return context;
  }
  serialize(action) {
    const operation = this.mutations.catch(() => {}).then(action); this.mutations = operation; return operation;
  }
  name(value, except = null) {
    const name = String(value || '').replace(/\s+/g, ' ').trim();
    if (!name || name.length > 80) throw new Error('Название проекта должно содержать от 1 до 80 символов.');
    if ([...this.items.values()].some(p => p.id !== except && p.metadata.name.toLocaleLowerCase('ru') === name.toLocaleLowerCase('ru'))) throw new Error('Проект с таким названием уже есть.');
    return name;
  }
  initializeGeneral(value) {
    return this.serialize(async () => {
      const general = this.get();
      if (!general.preferences.initialized) {
        Object.assign(general.preferences, cleanSettings(value), { initialized: true });
        const last = value?.sessionID;
        if (typeof last === 'string' && general.sessions.items.has(last)) general.preferences.lastSessionId = last;
        await general.savePreferences();
      }
      return general.snapshot();
    });
  }
  create(value) {
    return this.serialize(async () => {
      const name = this.name(value), general = this.get();
      // Capture all fields synchronously, before disk I/O can let other edits interleave.
      const documents = structuredClone(general.knowledge.documents);
      const preferences = structuredClone(general.preferences);
      const context = new ProjectContext(this.folder, { id: randomUUID(), name, createdAt: Date.now() });
      await context.load();
      context.knowledge.documents = documents; context.knowledge.reindex(); await context.knowledge.save();
      context.preferences = { ...preferences, initialized: true, lastSessionId: null };
      await context.savePreferences();
      this.items.set(context.id, context);
      try { await this.saveRegistry(); } catch (error) { this.items.delete(context.id); throw error; }
      return context.snapshot();
    });
  }
  rename(id, value) {
    return this.serialize(async () => {
      if (id === GENERAL_PROJECT) throw new Error('«Общее» нельзя переименовать.');
      const context = this.get(id), old = context.metadata.name;
      context.metadata.name = this.name(value, id);
      try { await this.saveRegistry(); } catch (error) { context.metadata.name = old; throw error; }
      return context.snapshot();
    });
  }
  async saveRegistry() {
    const file = path.join(this.folder, 'projects.json');
    await writeFile(file + '.tmp', JSON.stringify({ version: 1, projects: [...this.items.values()].map(p => p.metadata) }), { mode: 0o600 });
    await rename(file + '.tmp', file);
  }
  async flush() { await this.mutations.catch(() => {}); await Promise.all([...this.items.values()].map(p => p.flush())); }
}
