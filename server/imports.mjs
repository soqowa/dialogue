import path from 'node:path';

export const extensions = new Set('.txt .md .mdx .js .jsx .ts .tsx .mjs .cjs .py .ipynb .java .c .cpp .h .hpp .cs .go .rs .rb .php .swift .kt .kts .scala .sql .html .css .scss .json .yaml .yml .toml .xml .sh .r .tex .csv .vue .svelte .pdf .docx'.split(' '));
export const plainNames = new Set(['readme', 'license', 'makefile', 'dockerfile', 'justfile', 'cmakelists.txt']);
const ignored = new Set(['.git', 'node_modules', '.venv', 'venv', '.build', 'build', 'dist', 'target', 'vendor', 'coverage', '.next', '.cache', '__pycache__']);
export function relativeMaterialPath(value) {
  const name = String(value).replaceAll('\\', '/');
  if (!name || name.startsWith('/') || /^[a-z]:/i.test(name) || name.split('/').some(p => !p || p === '.' || p === '..') || /[\0\r\n]/.test(name)) throw new Error('Некорректный относительный путь');
  return name;
}
export function supportedMaterial(name) {
  const parts = name.replaceAll('\\', '/').split('/');
  if (parts.some(p => ignored.has(p) || p.startsWith('.'))) return false;
  return extensions.has(path.extname(name).toLowerCase()) || plainNames.has(parts.at(-1).toLowerCase());
}
export async function importMaterials(knowledge, files, relativePaths) {
  const errors = []; let imported = 0, skipped = 0;
  for (let i = 0; i < files.length; i++) {
    const file = files[i];
    let name;
    try {
      name = relativeMaterialPath(relativePaths?.[i] || Buffer.from(file.originalname, 'latin1').toString('utf8'));
      if (!supportedMaterial(name)) { skipped++; continue; }
      const ext = path.extname(name).toLowerCase();
      let text;
      if (ext === '.pdf') {
        const { PDFParse } = await import('pdf-parse'); const parser = new PDFParse({ data: file.buffer });
        try { text = (await parser.getText()).text; } finally { await parser.destroy(); }
      } else if (ext === '.docx') { const { default: mammoth } = await import('mammoth'); text = (await mammoth.extractRawText({ buffer: file.buffer })).value; }
      else { text = file.buffer.toString('utf8'); if (text.includes('\0')) throw new Error('Бинарный файл'); }
      if (text.length > 2_000_000) throw new Error('Больше 2 млн символов: разделите файл');
      const size = knowledge.documents.filter(d => d.name !== name).reduce((sum, d) => sum + d.text.length, 0);
      if (size + text.length > 20_000_000) throw new Error('База больше 20 млн символов');
      await knowledge.add(name, text, { persist: false }); imported++;
    } catch (e) { errors.push(`${name || file.originalname}: ${e.message}`); }
  }
  if (imported) await knowledge.save();
  return { documents: knowledge.list(), imported, skipped, errors };
}
