const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const app = read('ParentalControl/App/AppState.swift');
const nse = read('NotificationServiceExtension/RemoteControlProcessor.swift');
const model = read('ParentalControl/Models/DailyBudget.swift');
assert.match(app, /applyDailyBudgetPolicy\(poll.budget\?\.policy, reportedState: poll.budget\?\.state\)/,
    'Host must use usage from the same existing poll response');
assert.match(app, /DailyBudgetStore.shared.apply\(policy,[\s\S]*?legacyUsedToday:[^\n]+\n\s*reportedState: reportedState\)/);
assert.match(nse, /DailyBudgetStore.shared.apply\(policy, legacyUsedToday: 0, reportedState: poll.budget\?\.state\)/);
assert.match(nse, /guard previous != nil else \{ throw Failure.budgetUninitialized \}/,
    'NSE must not initialize a budget before host setup');
const apply = model.slice(model.indexOf('    func apply(_ policy: DailyBudgetPolicy, legacyUsedToday:'),
    model.indexOf('    static func pendingEnforcementKey('));
assert.match(apply, /return try locked/);
assert.ok(apply.indexOf('existing.advance(to: today)') < apply.indexOf('existing.restoreReportedUsage('));
assert.ok(apply.indexOf('existing.restoreReportedUsage(') < apply.indexOf('existing.apply(policy)'));
assert.match(apply, /state = DailyBudgetState.restoring\(policy/);
assert.doesNotMatch(apply, /URLSession|Task|Timer|await/, 'No network/IPC or asynchronous work under the budget file lock');
assert.match(apply, /defaults\?\.set\(max\(defaults\?\.integer\(forKey: key\) \?\? 0, state.policy.revision\)/,
    'Restoring a counter must not pretend enforcement succeeded');
console.log('Host/NSE budget recovery wiring, locking and no-extra-request checks passed');
