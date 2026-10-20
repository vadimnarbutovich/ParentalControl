// Run on macOS: node Tests/Localization/validate.cjs
// Checks every UI locale and source-code localization reference.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '../..');
const locales = fs.readdirSync(path.join(root, 'ParentalControl'))
  .filter(name => name.endsWith('.lproj') && name !== 'Base.lproj')
  .map(name => name.slice(0, -6)).sort();
const project = JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', path.join(root, 'ParentalControl.xcodeproj/project.pbxproj')]));
assert.deepEqual(project.objects[project.rootObject].knownRegions.filter(locale => locale !== 'Base').sort(), locales,
  'Project regions must match the localized resources');
const tables = [
  ['ParentalControl', 'Localizable.strings'],
  ['ParentalControl', 'InfoPlist.strings'],
  ['ParentalControlWidgets', 'Localizable.strings'],
  ['ShieldConfigurationExtension', 'Localizable.strings'],
  ['ShieldActionExtension', 'Localizable.strings'],
  ['DeviceActivityReportExtension', 'Localizable.strings'],
];
function read(target, locale, table) {
  const file = path.join(root, target, `${locale}.lproj`, table);
  execFileSync('plutil', ['-lint', file]);
  const result = JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-', file], { encoding: 'utf8' }));
  if (table.endsWith('.strings')) {
    const declarations = [...fs.readFileSync(file, 'utf8').matchAll(/^\s*"((?:\\.|[^"\\])*)"\s*=/gm)];
    assert.equal(declarations.length, Object.keys(result).length, `Duplicate keys: ${file}`);
  }
  return result;
}
function formats(value) {
  let nextIndex = 1;
  // Match the format syntax used by this app, not percentages in plain labels
  // such as "80 % SPAREN". Space flags are intentionally not used by our formats.
  return [...value.matchAll(/%%|(?<!\d)%(?:(\d+)\$)?[-+#0]*(?:\d+)?(?:\.\d+)?(?:hh|ll|h|l|q|z|t|j)?[@diuoxXfFeEgGcCsSpaA]/g)]
    .filter(match => match[0] !== '%%')
    .map(match => `${match[1] || nextIndex++}:${match[0].replace(/^%(?:\d+\$)?/, '')}`)
    .sort();
}
// Product names, plural references and identical words/abbreviations reviewed
// in the target languages (e.g. Polish Start/Stop and Romanian Calendar).
const allowedEnglish = new Set([
  'ParentalControl', 'ParentalControl Premium', 'Premium', 'Pro', 'Screen Time',
  '%1$@ — %2$@', '%#@steps@', '%#@reps@', 'OK', 'PIN', 'QR', 'GPS',
  'Start', 'Stop', 'Calendar', 'min', 'sec', '%d min', '%@ min', '%d sec', '%d / %d min',
]);
// Reviewed cognates/loanwords, not untranslated English sentences.
const sameWords = {
  fr: new Set(['Squat', 'Squats', 'Suggestions', 'Description', 'Minutes', 'MINUTES', 'Notifications', 'Parent', 'Conversion']),
  de: new Set(['App', 'Feedback', 'Name', 'Status: %@', 'Code: %@', 'Websites']),
  it: new Set(['App', 'Feedback', 'Privacy']),
  'zh-Hant': new Set(['App']),
};
let checked = 0;
const unchanged = [];
for (const [target, table] of tables) {
  const base = read(target, 'en', table);
  for (const locale of locales) {
    const translated = read(target, locale, table);
    assert.deepEqual(Object.keys(translated).sort(), Object.keys(base).sort(), `${target}/${locale}/${table}: keys`);
    for (const [key, value] of Object.entries(translated)) {
      const label = `${target}/${locale}/${key}`;
      assert.ok(value.trim(), `${label}: empty translation`);
      assert.deepEqual(formats(value), formats(base[key]), `${label}: format arguments`);
      assert.ok(!value.includes('ScreenBlocker'), `${label}: incorrect app name`);
      if (base[key].includes('](%@)')) assert.ok(value.includes('](%@)'), `${label}: missing share link`);
      assert.notEqual(value, key, `${label}: key used as translation`);
      if (locale !== 'en' && value === base[key] && !allowedEnglish.has(value)
          && !sameWords[locale]?.has(value) && /[A-Za-z]{3}/.test(value)) unchanged.push(`${label} = ${value}`);
      checked++;
    }
  }
}
const pluralBase = read('ParentalControl', 'en', 'Localizable.stringsdict');
for (const locale of locales) {
  const translated = read('ParentalControl', locale, 'Localizable.stringsdict');
  assert.deepEqual(Object.keys(translated).sort(), Object.keys(pluralBase).sort(), `${locale}: plural keys`);
  for (const [key, entry] of Object.entries(translated)) {
    assert.equal(entry.NSStringLocalizedFormatKey, pluralBase[key].NSStringLocalizedFormatKey, `${locale}/${key}: plural format`);
    for (const variable of Object.keys(pluralBase[key]).filter(key => key !== 'NSStringLocalizedFormatKey')) {
      const forms = entry[variable];
      assert.equal(forms.NSStringFormatSpecTypeKey, 'NSStringPluralRuleType');
      assert.equal(forms.NSStringFormatValueTypeKey, pluralBase[key][variable].NSStringFormatValueTypeKey);
      // Some languages require categories only for fractional numbers. Checking all
      // CLDR categories also protects future uses of these translation resources.
      for (const category of new Intl.PluralRules(locale).resolvedOptions().pluralCategories) {
        assert.ok(forms[category], `${locale}/${key}: missing plural category ${category}`);
      }
      assert.ok(forms.other, `${locale}/${key}: missing other`);
      for (const [category, value] of Object.entries(forms)) {
        if (!category.startsWith('NSString')) assert.deepEqual(formats(value), formats(pluralBase[key][variable].other), `${locale}/${key}/${category}: plural arguments`);
      }
    }
  }
}
// Dotted key literals also appear in ternaries, enums and helper arguments, not
// only in Text/NSLocalizedString calls. Check those within each resource bundle.
// Explicit localization calls additionally catch typos in a key's first segment.
let references = 0;
for (const [target, table] of tables.filter(([, table]) => table === 'Localizable.strings')) {
  const base = read(target, 'en', table);
  const prefixes = new Set(Object.keys(base).map(key => key.split('.')[0]));
  const files = execFileSync('rg', ['--files', path.join(root, target), '-g', '*.swift'], { encoding: 'utf8' }).trim().split('\n');
  for (const file of files) {
    const source = fs.readFileSync(file, 'utf8').replace(/\/\/[^\n]*/g, '');
    const keys = new Set();
    for (const match of source.matchAll(/"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"/g)) {
      // SF Symbols may share a prefix with localization namespaces.
      const isSymbol = /(?:systemImage|systemName):\s*$/.test(source.slice(0, match.index));
      if (!isSymbol && prefixes.has(match[1].split('.')[0])) keys.add(match[1]);
    }
    for (const match of source.matchAll(/(?:L10n\.(?:tr|f|plural)|NSLocalizedString|LocalizedStringKey|Text|Button|Label|Toggle|Section|Picker|GroupBox|navigationTitle|accessibilityLabel)\s*\(\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"/g)) keys.add(match[1]);
    for (const key of keys) {
      assert.ok(key in base, `${path.relative(root, file)}: unknown localization key ${key}`);
      references++;
    }
  }
}
console.log(`Validated ${checked} strings, ${Object.keys(pluralBase).length * locales.length} plural entries and ${references} source references across ${locales.length} locales.`);
if (unchanged.length) {
  console.log('Review identical English values:\n' + unchanged.join('\n'));
  process.exitCode = 1;
}
