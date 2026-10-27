const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const read = path => readFileSync(resolve(__dirname, '../../ParentalControl', path), 'utf8');
const content = read('ContentView.swift');
const banner = read('Views/FamilyAccessBannerView.swift');
const background = read('Design/AppBackgroundView.swift');
assert.match(content, /AppBackgroundContainer \{\s+VStack\(spacing: 0\)/);
assert.match(background, /\.environment\(\\.appBackgroundCanvas, canvas\)/);
assert.match(background, /var usesSharedCanvas = false/, 'Sheets/covers must not inherit the presenting canvas by default');
assert.match(background, /func appScreenBackground\(usesSharedCanvas: Bool = false\)/);
assert.match(background, /if usesSharedCanvas, let canvas = sharedCanvas/,
    'Only explicitly shared backgrounds read global coordinates');
const localBackground = background.slice(background.indexOf('            } else {'), background.indexOf('    private var artwork:'));
assert.match(localBackground, /\n\s+artwork\n/);
assert.doesNotMatch(localBackground, /GeometryReader|\.frame\(|\.offset\(|\.drawingGroup\(|\.clipped\(/,
    'Local artwork must fill sheets directly, without a cropped offscreen texture');
assert.match(read('Views/BlockListView.swift'), /AppBackgroundView\(usesSharedCanvas: !selectionOnly\)/,
    'Onboarding sheet fills its own bounds; main-tab block list retains the shared canvas');
// Keep an explicit inventory: future modal screens are local by default, and
// existing main-screen surfaces still align with the fixed Premium banner.
function section(file, from, until) {
    const source = read(file);
    const start = source.indexOf(from);
    const end = until ? source.indexOf(until, start + from.length) : source.length;
    assert.ok(start >= 0 && end > start, `Missing audited section: ${file} / ${from}`);
    return source.slice(start, end);
}
for (const [file, from, until] of [
    ['Views/MainTabView.swift', 'struct MainTabView:', 'private struct ParentModeExitBanner:'],
    ['Views/MainTabView.swift', 'private struct ParentDashboardView:', 'private struct AdjustTimeSheet:'],
    ['Views/TasksTabView.swift', 'struct TasksTabView:', 'struct TaskEditorView:'],
    ['Views/SettingsView.swift', 'struct SettingsView:', 'private struct PermissionsSettingsSheet:'],
    ['Views/StatisticsView.swift', 'var body: some View', 'private var summarySheet:'],
    ['Views/DashboardView.swift', 'struct DashboardView:'],
    ['Views/MapTabView.swift', 'struct MapTabView:'],
    ['Views/SchedulesTabView.swift', 'struct SchedulesTabView:'],
    ['Views/ChildTasksView.swift', 'private struct ChildTaskDetailView:', 'struct CameraPicker:'],
]) {
    assert.match(section(file, from, until), /(?:AppBackgroundView|appScreenBackground)\(usesSharedCanvas: true\)/,
        `Preserve the shared main-screen background: ${file} / ${from}`);
}
for (const [file, from, until] of [
    ['Views/MainTabView.swift', 'private struct AdjustTimeSheet:'],
    ['Views/MainTabView.swift', 'struct ParentModeEntryView:', 'private struct ParentDashboardView:'],
    ['Views/SettingsView.swift', 'private struct PermissionsSettingsSheet:'],
    ['Views/TasksTabView.swift', 'struct TaskEditorView:'],
    ['Views/StatisticsView.swift', 'private var summarySheet:'],
    ['Views/DailyBudgetView.swift', 'struct DailyLimitSheet:'],
    ['Views/ScheduleEditorView.swift', 'struct ScheduleEditorView:'],
    ['Views/RemovalProtectionView.swift', 'struct RemovalProtectionView:'],
    ['Views/PaywallView.swift', 'struct PaywallView:'],
    ['Views/Onboarding/OnboardingPresentation.swift', 'struct OnboardingPageLayout'],
]) {
    const modal = section(file, from, until);
    assert.match(modal, /(?:AppBackgroundView|appScreenBackground)\(\)/);
    assert.doesNotMatch(modal, /usesSharedCanvas: true/,
        `Modal must not sample the presenting screen: ${file} / ${from}`);
}
assert.match(background, /\.frame\(width: canvas.width, height: canvas.height\)/);
const canvasFrame = background.indexOf('.frame(width: canvas.width, height: canvas.height)');
const canvasRaster = background.indexOf('.drawingGroup(opaque: true)', canvasFrame);
const canvasOffset = background.indexOf('.offset(x: canvas.minX', canvasFrame);
assert.ok(canvasFrame < canvasRaster && canvasRaster < canvasOffset,
    'Rasterize the full background before offset/clipping to avoid the iOS 18 banner seam');
assert.match(background, /\.offset\(x: canvas.minX - localFrame.minX,\s+y: canvas.minY - localFrame.minY\)/);
assert.match(background, /\.clipped\(\)\s+\} else/);
assert.match(background, /\.ignoresSafeArea\(\)\s+\.allowsHitTesting\(false\)/);
assert.match(read('Views/MainTabView.swift'), /tabs\s+\.overlay\(alignment: \.top\) \{\s+if showsAccessBanner/);
assert.match(content, /FamilyAccessBannerView\(presentation: accessBanner\)/);
assert.match(content, /MainTabView\(showsAccessBanner: accessBanner != \.hidden\)/,
    'The blend strip exists only when the same presentation actually renders a banner');
assert.ok(!read('Views/MainTabView.swift').includes('tabs\n                .mask'), 'Top-edge blending must not clip the tab bar');
assert.match(content, /VStack\(spacing: 0\) \{\s+PermissionReminderBannerView\(\)/);
assert.ok(content.indexOf('FamilyAccessBannerView(') < content.indexOf('MainTabView('), 'Banner reserves space before TabView');
assert.ok(!content.includes('.safeAreaInset(edge: .top'), 'Do not rely on an inset propagated through TabView');
assert.match(content, /appState.hasCompletedOnboarding, appState.deviceRole != nil/);
assert.match(content, /\.familyAccessPaywall\(isRoot: true\)/);
assert.match(banner, /fixedSize\(horizontal: false, vertical: true\)/);
assert.match(banner, /_ = appState.requireFamilyAccess\(\)/);
assert.match(banner, /\.buttonStyle\(NeonPrimaryButtonStyle\(tint: AppTheme.neonGreen\)\)/);
const buttonLabel = banner.split('Text(L10n.tr(state.buttonKey))')[1].split('.buttonStyle')[0];
assert.ok(!buttonLabel.includes('.font('), 'Use the same standard button font as Adjust time today');
assert.ok(!/refreshFamilyAccess|retryPendingPurchaseConfirmation|\.task|Timer|restorePurchases/.test(banner), 'Banner must not create polling, payments or restore operations');
assert.match(read('ru.lproj/Localizable.strings'), /"access.banner.child.body" = "Попроси родителя подключить Premium в своём телефоне\.";/);
assert.match(read('ru.lproj/Localizable.strings'), /"paywall.legal.restore" = "Восстановить";/);
console.log('Access banner layout, actions and copy checks passed');

// Exercise the actual action gate: setup denies commands without prompting a
// purchase; expiry still prompts, and allowed access remains unaffected.
const app = read('App/AppState.swift');
const gate = app.slice(app.indexOf('    @discardableResult\n    func requireFamilyAccess()'),
    app.indexOf('    func refreshFamilyAccess('));
assert.ok(gate.includes('func requireFamilyConfigurationAccess()'));
const { mkdtempSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { execFileSync } = require('node:child_process');
const temp = mkdtempSync(resolve(tmpdir(), 'parental-setup-gate-'));
const swift = `import Foundation
enum DeviceRole { case parent, child }
enum FamilyAccessStore {
    static var allowed = false
    static var isSettingUp = false
    static let purchaseRequired = Foundation.Notification.Name("purchase")
}
enum NotificationCenter {
    static let \`default\` = Recorder()
    final class Recorder {
        var count = 0
        func post(name: Foundation.Notification.Name, object: Any?) { count += 1 }
    }
}
final class AppState {
    var deviceRole: DeviceRole = .parent
${gate}
}
let app = AppState()
for role in [DeviceRole.parent, .child] {
    app.deviceRole = role
    for setup in [false, true] {
        FamilyAccessStore.isSettingUp = setup
        for allowed in [false, true] {
            FamilyAccessStore.allowed = allowed
            NotificationCenter.default.count = 0
            precondition(app.requireFamilyAccess() == allowed)
            precondition(NotificationCenter.default.count == (!allowed && !setup && role == .parent ? 1 : 0))
            NotificationCenter.default.count = 0
            precondition(app.requireFamilyConfigurationAccess() == (setup || allowed))
            precondition(NotificationCenter.default.count == (!allowed && !setup && role == .parent ? 1 : 0))
        }
    }
}
print("Setup/expired/active command and configuration gates passed")
`;
writeFileSync(resolve(temp, 'main.swift'), swift);
execFileSync('xcrun', ['swiftc', '-module-cache-path', resolve(temp, 'cache'), resolve(temp, 'main.swift'), '-o', resolve(temp, 'tests')], { stdio: 'inherit' });
execFileSync(resolve(temp, 'tests'), { stdio: 'inherit' });
assert.match(read('Views/FamilyAccessPaywallPresenter.swift'), /!FamilyAccessStore.isSettingUp else \{ return \}/,
    'Queued automatic requests must not open a paywall during setup');
assert.match(app, /paidMutations.contains\(action\), storage.loadDeviceRole\(\) == \.parent,\s*!FamilyAccessStore.isSettingUp/g);
const posts = [...app.matchAll(/NotificationCenter.default.post\(name: FamilyAccessStore.purchaseRequired/g)];
assert.equal(posts.length, 3);
for (const post of posts) {
    assert.ok(app.slice(post.index - 100, post.index).includes('!FamilyAccessStore.isSettingUp'),
        'Every automatic purchase notification must exclude setup');
}
const dashboard = read('Views/MainTabView.swift');
assert.match(dashboard, /private var isCommandButtonEnabled: Bool \{\s*guard appState.pairingState\?\.isLinked == true else \{ return false \}\s*guard !FamilyAccessStore.isSettingUp else \{ return false \}/);
assert.match(dashboard, /private var shouldShowDisabledVisualState: Bool \{\s*if FamilyAccessStore.isSettingUp \{ return true \}/);
assert.match(read('Views/SettingsView.swift'), /showPaywall = true/, 'Manual Premium entry remains available');
assert.match(content, /appState.familyAccessBannerPresentation\(/);
assert.match(app, /confirmedState: accessBannerSession.confirmedState\(for: accessBannerScope, currentLease: lease\)/);
assert.match(app, /@Published private var accessBannerSession = FamilyAccessBannerSession\(\)/);
assert.match(app, /func appDidBecomeActive\(\) \{\s*accessBannerSession.enterForeground\(\)/);
assert.match(app, /func appDidEnterBackground\(\) \{\s*accessBannerSession.enterBackground\(\)/);
const refresh = app.slice(app.indexOf('    func refreshFamilyAccess('), app.indexOf('    func adoptFamilyAccess()'));
assert.match(refresh, /let lease = try await remoteSyncService.accessStatus\(ready: ready\)\s*accessBannerSession.confirm\(token: bannerToken, scope: bannerScope, currentScope: accessBannerScope, lease: lease\)/);
assert.equal((refresh.match(/remoteSyncService.accessStatus\(/g) || []).length, 1, 'Reuse the single existing status request');
assert.ok(!refresh.includes('enterBackground()'), 'Ordinary polling must not hide a confirmed banner');
assert.ok(!refresh.split('} catch {')[1].includes('accessBannerSession.confirm'), 'Network errors cannot confirm expiry');
const adoption = app.slice(app.indexOf('    func adoptFamilyAccess()'), app.indexOf('    static let didReceiveRemotePayloadNotification'));
assert.match(adoption, /let allowed = FamilyAccessStore.allowed/);
assert.ok(!adoption.includes('accessBannerSession'), 'Visual suppression must not change enforcement');

// Decode real access_status bodies through the production method. This method
// is also used during setup, where enforced:false legitimately has no lease.
const statusMethod = app.slice(app.indexOf('    @discardableResult\n    func accessStatus('), app.indexOf('    func purchaseIdentity()'));
assert.ok(statusMethod.length > 500);
writeFileSync(resolve(temp, 'Status.swift'), `import Foundation
final class StatusClient {
    var data = Data()
    var calls = 0
    func call<T: Decodable, P: Encodable>(action: String, payload: P, timeout: Int) async throws -> T {
        precondition(action == "access_status" && timeout == 15)
        calls += 1
        return try JSONDecoder().decode(T.self, from: data)
    }
${statusMethod}
}
@main struct Test {
    static func main() async throws {
        let client = StatusClient()
        let family = UUID(), child = UUID()
        for state in [FamilyAccessLease.State.setup, .demo, .paid, .expired, .verificationRequired] {
            let lease = FamilyAccessLease(protocolVersion: 1, familyID: family, pairingID: child,
                revision: 7, issuedAtMs: 1000, controlUntilMs: state == .paid || state == .demo ? 2000 : nil,
                nextCheckAtMs: 1100, state: state)
            var access = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lease)) as! [String: Any]
            access["enforced"] = true
            client.data = try JSONSerialization.data(withJSONObject: ["access": access, "accessChanged": false])
            let received = try await client.accessStatus(ready: true)
            precondition(received == lease)
        }
        client.data = Data(#"{"access":{"enforced":false}}"#.utf8)
        let disabled = try await client.accessStatus(ready: false)
        precondition(disabled == nil)
        client.data = Data(#"{"access":{"enforced":true,"state":"verification_required"}}"#.utf8)
        do {
            _ = try await client.accessStatus(ready: true)
            preconditionFailure("Malformed response must not confirm expiry")
        } catch is DecodingError { }
        precondition(client.calls == 7, "Exactly one request per check, no extra retry")
        print("Actual access-status response decoding passed for all states, disabled enforcement and malformed response")
    }
}
`);
execFileSync('xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', resolve(temp, 'cache'),
    resolve(__dirname, '../../ParentalControl/Models/FamilyAccessLease.swift'), resolve(temp, 'Status.swift'),
    '-o', resolve(temp, 'status-tests')], { stdio: 'inherit' });
execFileSync(resolve(temp, 'status-tests'), { stdio: 'inherit' });
