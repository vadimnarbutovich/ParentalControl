// Run from the project root: node Docs/AppStore/Metadata/validate.cjs
// Structural checks only; linguistic review still requires a human reader.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const root = __dirname;
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
const expectedLocales = [
  'ar-SA', 'de-DE', 'el', 'en-AU', 'en-CA', 'en-GB', 'en-US', 'es-ES', 'es-MX',
  'fr-FR', 'it', 'ja', 'ko', 'pl', 'pt-BR', 'ro', 'ru', 'uk', 'vi', 'zh-Hans', 'zh-Hant',
];
assert.deepEqual(Object.keys(manifest.locales).sort(), expectedLocales.sort());
const folders = fs.readdirSync(root, { withFileTypes: true }).filter(entry => entry.isDirectory()).map(entry => entry.name).sort();
assert.deepEqual(folders, expectedLocales.sort());
const referenceURLs = [
  'https://vadimnarbutovich.github.io/parentalcontrolapp/privacy-en.html',
  'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/',
];
const combined = fs.readFileSync(path.join(root, 'ALL_TRANSLATIONS.txt'), 'utf8');
const rows = [];
for (const [locale, entry] of Object.entries(manifest.locales)) {
  const row = { locale };
  for (const [field, limit] of Object.entries(manifest.limits)) {
    assert.equal(entry[field].file, `${locale}/${field}.txt`);
    const raw = fs.readFileSync(path.join(root, entry[field].file), 'utf8');
    const text = raw.replace(/\n$/, '');
    assert.ok(text.length > 0 && text === text.trim(), `${locale}/${field}: empty or extra whitespace`);
    assert.equal(text, text.normalize('NFC'), `${locale}/${field}: normalize Unicode before counting`);
    assert.ok(!/[\uFEFF\uFFFD\u200B\r\t]/.test(text), `${locale}/${field}: unexpected control character`);
    assert.equal([...text].length, entry[field].characters, `${locale}/${field}: manifest count is stale`);
    // Checking both Unicode code points and UTF-16 is conservative across clients.
    assert.ok(text.length <= limit && [...text].length <= limit, `${locale}/${field}: exceeds ${limit}`);
    assert.ok(combined.includes(text), `${locale}/${field}: combined review file is stale`);
    assert.ok(!text.includes('```'), `${locale}/${field}: Markdown fences are not metadata`);
    if (field === 'promotional_text') {
      assert.ok(!text.includes('\n'), `${locale}: promotional text must be a single paragraph`);
    } else {
      assert.deepEqual(text.match(/https:\/\/\S+/g), referenceURLs, `${locale}: legal links changed`);
      assert.equal(text.match(/ParentalControl/g)?.length, 1, `${locale}: brand missing or duplicated`);
      assert.ok(text.includes('PIN'), `${locale}: PIN detail missing`);
      const paragraphs = text.split('\n\n');
      assert.equal(paragraphs.length, 20, `${locale}: a source section may be missing`);
      for (let i = 2; i <= 14; i += 2) assert.ok(!paragraphs[i].includes('\n'), `${locale}: malformed section heading`);
    }
    row[field] = `${[...text].length}/${limit}`;
  }
  rows.push(row);
}
console.table(rows);
console.log(`Validated ${rows.length} locales: all 42 fields fit their limits; structure, links and review copy match.`);
