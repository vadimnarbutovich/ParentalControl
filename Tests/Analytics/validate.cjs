// Run from the app repository: node Tests/Analytics/validate.cjs
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const schema = read('ParentalControl/Analytics/AnalyticsSchema.swift');
const analytics = read('ParentalControl/Analytics/AppAnalytics.swift');
const docs = read('appmetrica.md');
const events = new Set([...schema.matchAll(/^        "([a-z_]+)":/gm)].map(m => m[1]));
assert(events.size > 40, 'Event catalog exists');
const reported = new Set();
function walk(directory) {
  for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, item.name);
    if (item.isDirectory()) walk(file);
    else if (item.name.endsWith('.swift')) {
      const source = fs.readFileSync(file, 'utf8');
      for (const [, name] of source.matchAll(/AppAnalytics\.report\(\s*"([^"]+)"/g)) {
        assert(events.has(name), `${file}: unregistered event ${name}`);
        reported.add(name);
      }
      if (!file.endsWith('/Analytics/AppAnalytics.swift')) {
        assert(!/AppMetrica\.(reportEvent|activate|reporter|reportUserProfile|setUserProfile)/.test(source),
          `${file}: bypass of analytics facade`);
      }
    }
  }
}
walk(path.join(root, 'ParentalControl'));
for (const event of events) {
  assert(reported.has(event), `Unused schema event ${event}`);
  assert(docs.includes('`' + event + '`'), `Missing documentation: ${event}`);
}
assert(analytics.includes('9edea000-9fd2-4da0-9b68-845eedb8bf86'), 'New dedicated key');
assert(!analytics.includes('90679160-6625-4373-bd17-55564f521a13'), 'No inherited key in SDK configuration');
assert.match(analytics, /#if DEBUG\s+return\s+#else/, 'No SDK activation in Debug');
assert.match(analytics, /guard didActivate else \{ return \}/, 'Never report without safe activation');
for (const property of ['locationTracking', 'accurateLocationTracking', 'allowsBackgroundLocationUpdates',
  'advertisingIdentifierTrackingEnabled', 'appOpenTrackingEnabled', 'revenueAutoTrackingEnabled']) {
  assert(analytics.includes(`configuration.${property} = false`), property);
}
assert(!analytics.includes('sendEventsBuffer'), 'Do not flush each event');
const state = read('ParentalControl/App/AppState.swift');
const polling = state.slice(state.indexOf('private func startRemotePollingIfNeeded()'),
  state.indexOf('private func processPendingRemoteCommandsIfNeeded()'));
assert(!polling.includes('AppAnalytics.report'), 'No per-poll events');
const statistics = read('ParentalControl/Views/StatisticsView.swift');
assert(!/AppAnalytics\.report[^\n]*selectedDay/.test(statistics), 'Do not export selected dates');
console.log(`PASS: ${events.size} documented/wired events, safe configuration and privacy boundaries`);
