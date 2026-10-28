const assert = require('node:assert/strict');
const { readFileSync, mkdtempSync, writeFileSync } = require('node:fs');
const { resolve, join } = require('node:path');
const { tmpdir } = require('node:os');
const { execFileSync } = require('node:child_process');
const root = resolve(__dirname, '../..');
const app = readFileSync(join(root, 'ParentalControl/App/AppState.swift'), 'utf8');
const view = readFileSync(join(root, 'ParentalControl/Views/MapTabView.swift'), 'utf8');
const load = app.split('    func loadChildLocationIfNeeded() async {')[1]
  .split('    private func applyRemoteCommandIfNeeded')[0];
const refresh = app.split('    func refreshChildLocationFromParent() async {')[1]
  .split('    private func locationFailureMessage')[0];
assert.ok(refresh.indexOf('guard requireFamilyAccess()') < refresh.indexOf('isParentRefreshingChildLocation = true'));
assert.match(refresh, /catch \{\s+guard !Task.isCancelled, FamilyAccessStore.allowed/);
assert.match(refresh, /guard FamilyAccessStore.allowed, deviceRole == \.parent/);
assert.equal((view.match(/if appState.isFamilyAccessAllowed, let message = appState.parentLocationStatusMessage/g) || []).length, 2);
assert.match(view, /onChange\(of: appState.isFamilyAccessAllowed\)[\s\S]*?if !allowed \{ refreshTask\?\.cancel\(\) \}/);
assert.match(app, /isFamilyAccessAllowed = allowed\s+if !allowed \{ parentLocationStatusMessage = nil \}/);

// Run the actual automatic-load method with a fake service: no network or purchases.
const swift = `import Foundation
enum DeviceRole { case parent, child }
enum FamilyAccessStore { static var allowed = false }
enum L10n { static func tr(_ key: String) -> String { key } }
struct Snapshot { var updatedAt = Date() }
struct Pairing { var isLinked = true; var familyID = UUID() }
final class Storage {
    var cached: Snapshot? = Snapshot()
    func loadChildLocationSnapshot() -> Snapshot? { cached }
    func saveChildLocationSnapshot(_ snapshot: Snapshot) { cached = snapshot }
}
final class Service {
    var calls = 0
    var fail = false
    var expire = false
    func fetchChildLocation() async throws -> Snapshot? {
        calls += 1
        if expire { FamilyAccessStore.allowed = false }
        if fail { throw NSError(domain: "test", code: -1) }
        return Snapshot()
    }
}
final class AppState {
    var deviceRole: DeviceRole = .parent
    var pairingState: Pairing? = Pairing()
    var isLoadingChildLocation = false
    var isParentRefreshingChildLocation = false
    var childLocationSnapshot: Snapshot?
    var parentLocationStatusMessage: String? = "stale error"
    var parentLocationRevision = 0
    let storage = Storage()
    let remoteSyncService = Service()
    func loadChildLocationIfNeeded() async {${load}
}
@main struct Run {
    static func main() async {
        let paused = AppState()
        await paused.loadChildLocationIfNeeded()
        precondition(paused.remoteSyncService.calls == 0)
        precondition(paused.parentLocationStatusMessage == nil)
        precondition(paused.childLocationSnapshot != nil)
        precondition(!paused.isLoadingChildLocation)

        FamilyAccessStore.allowed = true
        let success = AppState()
        success.parentLocationStatusMessage = nil
        await success.loadChildLocationIfNeeded()
        precondition(success.remoteSyncService.calls == 1)
        precondition(success.childLocationSnapshot != nil)
        precondition(success.parentLocationStatusMessage == nil)

        let failure = AppState()
        failure.remoteSyncService.fail = true
        await failure.loadChildLocationIfNeeded()
        precondition(failure.parentLocationStatusMessage == "map.refresh.connection_error")
        precondition(!failure.isLoadingChildLocation)

        let expiredDuringRequest = AppState()
        expiredDuringRequest.parentLocationStatusMessage = nil
        expiredDuringRequest.remoteSyncService.fail = true
        expiredDuringRequest.remoteSyncService.expire = true
        await expiredDuringRequest.loadChildLocationIfNeeded()
        precondition(expiredDuringRequest.parentLocationStatusMessage == nil)
        precondition(!expiredDuringRequest.isLoadingChildLocation)
        print("Map access tests passed: inactive/cache, active success/error, expiration in flight")
    }
}
`;
const temp = mkdtempSync(join(tmpdir(), 'parental-map-access-'));
const source = join(temp, 'main.swift');
const binary = join(temp, 'test');
writeFileSync(source, swift);
execFileSync('swiftc', ['-parse-as-library', source, '-o', binary], { stdio: 'inherit' });
execFileSync(binary, [], { stdio: 'inherit' });
