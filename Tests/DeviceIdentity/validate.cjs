const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const storage = read('ParentalControl/Storage/AppGroupStore.swift');
const keychain = read('ParentalControl/Storage/DeviceIdentityKeychain.swift');
const app = read('ParentalControl/App/AppState.swift');
const identity = keychain.slice(keychain.indexOf('    struct Identity:'), keychain.indexOf('    private static let service'));
const credentials = storage.slice(storage.indexOf('    func loadDeviceInstallID()'), storage.indexOf('    func loadAPNSToken()'));
const role = storage.slice(storage.indexOf('    func loadDeviceRole()'), storage.indexOf('    func loadPairingState()'));
assert.ok(identity && credentials && role);
assert.match(app, /guard deviceRole == role else \{ return \}/);
assert.match(app, /if let registeredRole = bootstrap.deviceRole, registeredRole != role/);
assert.match(app, /chooseDeviceRole\(registeredRole\)\s+return/);
assert.match(app, /let deviceRole: DeviceRole\?/);
const source = `import Foundation
enum DeviceRole: String { case parent, child }
enum StorageKey {
    static let deviceRole = "role"
    static let deviceInstallID = "id"
    static let deviceSecret = "secret"
}
final class MemoryStore {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func set(_ value: String?, forKey key: String) { values[key] = value }
}
enum DeviceIdentityKeychain {
${identity}
    static var saved: Identity?
    static func read() -> Identity? { saved }
    static func save(_ value: Identity) { saved = value }
}
final class CredentialStore {
    let store = MemoryStore()
${role}
${credentials}
}
` + read('Tests/DeviceIdentity/cases.swift');
// Generated build artifact: execute the actual storage methods with an
// in-memory Keychain double, never the developer's real credentials.
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'parental-identity-test-'));
fs.writeFileSync(path.join(temp, 'main.swift'), source);
execFileSync('xcrun', ['swiftc', '-module-cache-path', path.join(temp, 'cache'), path.join(temp, 'main.swift'), '-o', path.join(temp, 'tests')], { stdio: 'inherit' });
execFileSync(path.join(temp, 'tests'), { stdio: 'inherit' });

const recoveryMethods = app.slice(app.indexOf('    func checkInstallationRecovery('),
  app.indexOf('    private func prepareRecoveryPinEntry()'));
assert.ok(recoveryMethods.length > 1000);
const returnMethod = app.slice(app.indexOf('    func returnToFamilyRecovery()'), app.indexOf('    /// Explicit, bounded recovery reads.'));
assert.ok(returnMethod.length > 300);
assert.doesNotMatch(returnMethod, /unlinkDevices|clearPairing|saveDeviceSecret|saveDeviceInstallID/);
const recoverySource = read('Tests/DeviceIdentity/recovery-cases.swift')
  .replace('// ACTUAL_RECOVERY_METHODS', recoveryMethods)
  .replace('// ACTUAL_RETURN_METHOD', returnMethod);
fs.writeFileSync(path.join(temp, 'main.swift'), recoverySource);
execFileSync('xcrun', ['swiftc', '-module-cache-path', path.join(temp, 'cache'), path.join(temp, 'main.swift'), '-o', path.join(temp, 'recovery-tests')], { stdio: 'inherit' });
execFileSync(path.join(temp, 'recovery-tests'), { stdio: 'inherit' });
const view = read('ParentalControl/ContentView.swift');
assert.ok(view.indexOf('FamilyRecoveryView()') < view.indexOf('RoleSelectionView()'));
assert.match(view, /fullScreenCover\(isPresented: \$showsPin/);
assert.match(view, /alert\("recovery.reset"/);
assert.match(view, /appState.recoveredDeviceRole == \.child/);
assert.match(app, /recoveryPinFamilyID == familyID else \{ return \.unavailable \}/);
assert.match(app, /try await remoteSyncService.fetchParentPin\(\)/);
const choose = app.slice(app.indexOf('    func chooseDeviceRole('), app.indexOf('    func clearPairing('));
assert.match(choose, /pendingSetupFamilyID == nil/, 'Synchronous role selection must not bypass pending reset');
assert.match(view, /await appState.selectInstallationRole\(\.parent\)/);
assert.match(view, /await appState.selectInstallationRole\(\.child\)/);
assert.match(view, /\.disabled\(appState.isChoosingDeviceRole\)/);
const edge = read('supabase/functions/parental-control-sync/index.ts');
const resetStart = edge.indexOf('if (action === "reset_pending_setup")');
assert.ok(resetStart > edge.indexOf('const authed = await requireDevice(req)'));
assert.ok(resetStart < edge.indexOf('const access = await accessSnapshot'));
assert.match(edge.slice(resetStart, edge.indexOf('const access = await accessSnapshot')), /p_device: authed.deviceId/);
const resetSQL = read('supabase/migrations/202610260001_reset_pending_setup.sql');
assert.match(resetSQL, /families where id=p_family for update/);
assert.match(resetSQL, /family_id=p_family and id<>p_device/);
assert.doesNotMatch(resetSQL, /(?:update|delete from) public.pc_access_owners/i);
