// Build artifact only: use the actual sheet bodies and design components.
// The fake AppState never connects to production or reads device credentials.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../..');
const output = process.argv[2];
assert.ok(output && output.startsWith('/private/tmp/parental-real-sheets.'));
function extract(file, start, end) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const a = source.indexOf(start), b = source.indexOf(end, a);
  assert.ok(a >= 0 && b > a);
  return source.slice(a, b);
}
const adjust = extract('ParentalControl/Views/MainTabView.swift', 'private struct AdjustTimeSheet:', '#Preview');
const pin = extract('ParentalControl/Views/SettingsView.swift', 'struct ParentPinSetupSheet:', '#Preview');
const source = `import SwiftUI
import Combine
@MainActor final class AppState: ObservableObject {
    @Published var budgetError: String?
    @Published var parentPinIsSet = true
    func requireFamilyAccess() -> Bool { true }
    func setParentPinFromUI(_ pin: String) async -> Bool { false }
}
extension View {
    func familyAccessPaywall() -> some View { self }
}
@main struct RealSheetsPreview: App {
    @StateObject private var state = AppState()
    var body: some Scene { WindowGroup { PreviewRoot().environmentObject(state) } }
}
struct PreviewRoot: View {
    @State private var presented = false
    private let pin = ProcessInfo.processInfo.arguments.contains("-pin")
    var body: some View {
        AppBackgroundContainer {
            NavigationStack {
                ZStack {
                    AppBackgroundView(usesSharedCanvas: true)
                    ScrollView {
                        VStack(spacing: 24) {
                            Text("Осталось сегодня").font(.largeTitle)
                            Text("60 мин").font(.system(size: 64, weight: .bold))
                            Text("Дневной лимит").font(.title)
                        }.padding(32).frame(maxWidth: .infinity)
                    }
                }
                .sheet(isPresented: $presented) {
                    Group {
                        if pin { ParentPinSetupSheet() }
                        else { AdjustTimeSheet { _ in false } }
                    }
                    .presentationDetents(pin ? [.medium] : [.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .task { presented = true }
        }.preferredColorScheme(.dark)
    }
}
${adjust}
${pin}
`;
fs.writeFileSync(path.join(output, 'Preview.swift'), source);
const app = path.join(output, 'RealSheets.app');
fs.mkdirSync(path.join(app, 'ru.lproj'), {recursive: true});
fs.copyFileSync(path.join(root, 'ParentalControl/ru.lproj/Localizable.strings'), path.join(app, 'ru.lproj/Localizable.strings'));
fs.writeFileSync(path.join(app, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.parental.realsheets</string>
<key>CFBundleExecutable</key><string>RealSheets</string>
<key>CFBundleName</key><string>RealSheets</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleDevelopmentRegion</key><string>ru</string>
<key>MinimumOSVersion</key><string>18.0</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>`);
console.log('Generated actual AdjustTimeSheet and ParentPinSetupSheet with offline test dependencies');
