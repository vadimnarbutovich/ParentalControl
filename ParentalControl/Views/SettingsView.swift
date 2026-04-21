import SwiftUI
import UIKit

private enum SupportEmail {
    static let address = "vadim.narb@yandex.com"
}

private enum AppStoreLinks {
    static let appID = "6761118244"

    static var writeReviewURL: URL? {
        URL(string: "itms-apps://itunes.apple.com/app/id\(appID)?action=write-review")
    }

    static var shareURL: URL {
        URL(string: "https://apps.apple.com/app/id\(appID)")!
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionService: SubscriptionService
    @State private var activeSheet: SettingsSheet?
    @State private var showOnboardingReplay = false
    @State private var showPaywall = false
    @State private var showShareSheet = false
    @FocusState private var focusedField: SettingsFocusField?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("settings.title")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        premiumSection
                        appSection
                        helpSection
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    dismissKeyboard()
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { _ in
                            dismissKeyboard()
                        }
                )
            }
            .scrollIndicators(.hidden)
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .conversion:
                    ConversionSettingsSheet()
                        .environmentObject(appState)
                        .presentationDragIndicator(.hidden)
                #if DEBUG && !HIDE_DEBUG_UI
                case .permissions:
                    PermissionsSettingsSheet()
                        .environmentObject(appState)
                        .presentationDragIndicator(.hidden)
                #endif
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ActivityShareSheet(items: [AppStoreLinks.shareURL])
            }
            .fullScreenCover(isPresented: $showOnboardingReplay) {
                OnboardingFlowView(onReplayFinished: { showOnboardingReplay = false })
                    .environmentObject(appState)
                    .environmentObject(appState.screenTimeService)
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(isPresented: $showPaywall, openSource: .settings)
                    .environmentObject(subscriptionService)
            }
        }
    }

    private var premiumSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.section.premium")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))

            settingsRow(
                titleKey: subscriptionService.isPro
                    ? "settings.premium.active"
                    : "settings.premium.unlock_all"
            ) {
                AppAnalytics.report("settings_premium_tap")
                showPaywall = true
            }
        }
        .padding()
        .glassCard(cornerRadius: 24, glowColor: AppTheme.neonGreen)
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.section.app")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))

            if appState.deviceRole == .parent {
                parentPairingSection
            } else {
                childPairingSection
            }

            settingsRow(titleKey: "settings.item.conversion") {
                AppAnalytics.report("settings_conversion_open")
                activeSheet = .conversion
            }
            settingsRow(titleKey: "settings.item.language") {
                AppAnalytics.report("settings_language_tap")
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            settingsToggleRow(
                titleKey: "settings.item.midnight_reset",
                isOn: Binding(
                    get: { appState.isMidnightResetEnabled },
                    set: { newValue in
                        if !newValue && !subscriptionService.isPro {
                            AppAnalytics.report("settings_midnight_reset_toggle", parameters: ["action": "blocked"])
                            showPaywall = true
                            return
                        }
                        AppAnalytics.report(
                            "settings_midnight_reset_toggle",
                            parameters: ["enabled": newValue]
                        )
                        appState.updateMidnightResetEnabled(newValue)
                    }
                )
            )
#if DEBUG && !HIDE_DEBUG_UI
            settingsRow(titleKey: "settings.item.permissions") {
                AppAnalytics.report("settings_permissions_open")
                activeSheet = .permissions
            }
#endif
        }
        .padding()
        .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
    }

    private var parentPairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.parent.link.title")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            if let code = appState.parentPairingCode ?? appState.pairingState?.pairingCode {
                Text(L10n.f("settings.parent.link.code", code))
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.neonGreen)
            } else {
                Text("settings.parent.link.empty")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("settings.parent.link.generate") {
                Task { await appState.createPairingCodeForParent() }
            }
            .buttonStyle(SecondaryInlineButtonStyle())
            if let message = appState.remoteStatusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.neonBlue)
            }
        }
        .padding(.vertical, 8)
    }

    private var childPairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.child.link.title")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            TextField(
                L10n.tr("settings.child.link.placeholder"),
                text: $appState.pairingCodeInput
            )
            .focused($focusedField, equals: .childPairingCode)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled(true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            Button("settings.child.link.connect") {
                Task { await appState.connectChildWithPairingCode() }
            }
            .buttonStyle(SecondaryInlineButtonStyle())
            if let code = appState.pairingState?.pairingCode {
                Text(L10n.f("settings.child.link.connected_code", code))
                    .font(.footnote)
                    .foregroundStyle(AppTheme.neonGreen)
            }
            if let message = appState.remoteStatusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.neonBlue)
            }
        }
        .padding(.vertical, 8)
    }

    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.section.help")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))

            settingsRow(titleKey: "settings.item.show_onboarding") {
                AppAnalytics.report("settings_onboarding_replay_tap")
                showOnboardingReplay = true
            }
            settingsRow(titleKey: "settings.item.feedback", action: openFeedbackEmail)
            settingsRow(titleKey: "settings.item.rate_app") {
                AppAnalytics.report("settings_rate_app_tap")
                guard let url = AppStoreLinks.writeReviewURL else { return }
                UIApplication.shared.open(url)
            }
            settingsRow(titleKey: "settings.item.share_app") {
                AppAnalytics.report("settings_share_app_tap")
                showShareSheet = true
            }
        }
        .padding()
        .glassCard(cornerRadius: 24, glowColor: AppTheme.neonPurple)
        .padding(36)
        .drawingGroup()
        .padding(-36)
    }

    private func openFeedbackEmail() {
        AppAnalytics.report("settings_feedback_tap")
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = SupportEmail.address
        components.queryItems = [
            URLQueryItem(name: "subject", value: "ParentalControl feedback"),
        ]
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    private func settingsRow(titleKey: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(LocalizedStringKey(titleKey))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    private func settingsToggleRow(titleKey: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(LocalizedStringKey(titleKey))
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppTheme.neonGreen)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}

private enum SettingsFocusField: Hashable {
    case childPairingCode
}

private struct ConversionSettingsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var stepsText = ""
    @State private var squatsText = ""
    @State private var pushUpsText = ""
    @State private var lastSaved: ConversionSettings?
    @FocusState private var focusedField: ConversionField?

    var body: some View {
        VStack(spacing: 0) {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.30))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 8)
                    Text("onboarding.conversion.title")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)

                    Text("onboarding.conversion.subtitle")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 14)

                    HStack(spacing: 20) {
                        conversionPaceThumb(asset: "walk", tint: AppTheme.neonBlue)
                        conversionPaceThumb(asset: "squat", tint: AppTheme.neonGreen)
                        conversionPaceThumb(asset: "pushups", tint: Color.orange.opacity(0.95))
                    }
                    .padding(.vertical, 8)

                    VStack(alignment: .leading, spacing: 16) {
                        conversionPaceField("settings.conversion.steps.per.minute", text: $stepsText, field: .steps)
                        conversionPaceField("settings.conversion.squats.per.minute", text: $squatsText, field: .squats)
                        conversionPaceField("settings.conversion.pushups.per.minute", text: $pushUpsText, field: .pushUps)
                    }
                    .padding(.horizontal, 6)

                    Button("settings.conversion.reset.defaults") {
                        applyDefaults()
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.neonBlue)
                    .padding(.top, 4)

                    Button("settings.conversion.save") {
                        reportConversionSaveTapped()
                        saveSettingsIfNeeded()
                        dismiss()
                    }
                    .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
                    .padding(.top, 8)

                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .onTapGesture {
                dismissKeyboard()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        dismissKeyboard()
                    }
            )
        }
        .appScreenBackground()
        .onAppear {
            syncFromState()
        }
        .onDisappear {
            saveSettingsIfNeeded()
        }
    }

    private func conversionPaceThumb(asset: String, tint: Color) -> some View {
        Image(asset)
            .resizable()
            .scaledToFit()
            .frame(width: 72, height: 72)
            .shadow(color: tint.opacity(0.45), radius: 14, y: 2)
    }

    private func conversionPaceField(_ titleKey: String, text: Binding<String>, field: ConversionField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            TextField("", text: text)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: field)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(AppTheme.glassBorder.opacity(0.4), lineWidth: 1)
                        )
                )
        }
    }

    private func syncFromState() {
        let settings = appState.settings
        stepsText = "\(settings.stepsPerMinute)"
        squatsText = "\(settings.squatsPerMinute)"
        pushUpsText = "\(settings.pushUpsPerMinute)"
        lastSaved = settings
    }

    private func reportConversionSaveTapped() {
        let steps = Int(stepsText).flatMap { $0 > 0 ? $0 : nil }
        let squats = Int(squatsText).flatMap { $0 > 0 ? $0 : nil }
        let pushUps = Int(pushUpsText).flatMap { $0 > 0 ? $0 : nil }
        var params: [String: Any] = [
            "valid": steps != nil && squats != nil && pushUps != nil,
        ]
        if let steps { params["steps_per_minute"] = steps }
        if let squats { params["squats_per_minute"] = squats }
        if let pushUps { params["pushups_per_minute"] = pushUps }
        AppAnalytics.report("conversion_save_tap", parameters: params)
    }

    private func applyDefaults() {
        AppAnalytics.report("conversion_apply_defaults_tap")
        let defaults = ConversionSettings.default
        stepsText = "\(defaults.stepsPerMinute)"
        squatsText = "\(defaults.squatsPerMinute)"
        pushUpsText = "\(defaults.pushUpsPerMinute)"
    }

    private func saveSettingsIfNeeded() {
        guard
            let steps = Int(stepsText), steps > 0,
            let squats = Int(squatsText), squats > 0,
            let pushUps = Int(pushUpsText), pushUps > 0
        else {
            return
        }

        let updated = ConversionSettings(
            stepsPerMinute: steps,
            squatsPerMinute: squats,
            pushUpsPerMinute: pushUps
        )
        guard updated != lastSaved else { return }
        appState.updateSettings(updated)
        lastSaved = updated
    }

    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private enum ConversionField: Hashable {
    case steps
    case squats
    case pushUps
}

private enum SettingsSheet: Int, Identifiable {
    case conversion
    #if DEBUG && !HIDE_DEBUG_UI
    case permissions
    #endif

    var id: Int { rawValue }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController,
           let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct SecondaryInlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.14))
            )
    }
}

#if DEBUG && !HIDE_DEBUG_UI
private struct PermissionsSettingsSheet: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.30))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 10)

            Text("settings.section.permissions")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 12) {
                    permissionRow("settings.permission.healthkit", isOn: appState.isHealthAuthorized)
                    permissionRow("settings.permission.camera", isOn: appState.isCameraAuthorized)
                    permissionRow("settings.permission.notifications", isOn: appState.isNotificationAuthorized)
                    permissionRow("settings.permission.screentime", isOn: appState.screenTimeService.isAuthorized)
                    permissionRow("settings.permission.live_activity", isOn: appState.isLiveActivitiesEnabled)

                    Button("settings.request.permissions") {
                        Task {
                            await appState.requestPermissions()
                        }
                    }
                    .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
                    .padding(.top, 4)

                    Button("settings.open.settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
                }
                .padding(.horizontal)
                .padding(.bottom, 14)
            }
        }
        .appScreenBackground()
        .task {
            await appState.refreshPermissionStatuses()
        }
    }

    private func permissionRow(_ titleKey: String, isOn: Bool) -> some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey(titleKey))
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: isOn ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isOn ? AppTheme.neonGreen : AppTheme.neonOrange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}
#endif

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(SubscriptionService())
}
