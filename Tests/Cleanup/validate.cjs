const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const exists = name => fs.existsSync(path.join(root, name));

for (const name of ['ButtonGo', 'apps', 'focusSession', 'focusTime', 'health', 'notification',
  'onboardingHero', 'timer', 'walk', 'squat', 'pushups', 'squatHelp', 'pushupsHelp']) {
  assert.ok(!exists(`ParentalControl/Assets.xcassets/${name}.imageset`), `Retired asset: ${name}`);
}
for (const name of ['onboardingFamily', 'onboardingParents', 'onboardingChildren', 'childLocationMarker']) {
  assert.ok(exists(`ParentalControl/Assets.xcassets/${name}.imageset/Contents.json`), `Keep active asset: ${name}`);
}
const bundle = read('ParentalControlWidgets/ParentalControlWidgetsBundle.swift');
assert.match(bundle, /ParentalControlWidgetsLiveActivity\(\)/);
assert.doesNotMatch(bundle, /ParentalControlWidgets\(\)|ParentalControlWidgetsControl\(\)/);
for (const folder of ['DeviceActivityMonitorExtension', 'ShieldActionExtension', 'ShieldConfigurationExtension',
  'DeviceActivityReportExtension', 'NotificationServiceExtension', 'LocationPushServiceExtension']) {
  assert.ok(exists(`${folder}/Info.plist`), `Keep active extension: ${folder}`);
}
const dashboard = read('ParentalControl/Views/DashboardView.swift');
assert.match(dashboard, /DailyBudgetBalanceCard\(/);
assert.match(dashboard, /ChildTasksSection\(\)/);
assert.doesNotMatch(dashboard, /selectedExercise|earnMinutesSection|ExerciseSessionView/);
assert.doesNotMatch(read('ParentalControl/Views/SettingsView.swift'), /ConversionSettingsSheet|case conversion/);
const state = read('ParentalControl/App/AppState.swift');
assert.match(state, /func refreshStepsAndRewards\(\) async \{\s+resetDailyBalanceIfNeeded\(\)/,
  'Old method name still performs the live daily reset');
assert.match(state, /settings\.squatsPerMinute/);
assert.match(read('ParentalControl/Storage/AppGroupStore.swift'), /func loadSettings\(\) -> ConversionSettings/);
const reports = read('ParentalControl/Views/ChildTasksView.swift');
assert.match(reports, /CameraPicker/);
assert.match(reports, /UIImagePickerController/);
assert.ok(!exists('ParentalControl/ParentalControl.xcdatamodeld'));
assert.ok(!exists('ParentalControl/Persistence.swift'));
console.log('PASS: cleanup preserves active assets, extensions, reports and legacy balance readers');
