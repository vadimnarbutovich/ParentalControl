import SwiftUI
import UIKit
import CoreLocation

private enum SupportEmail {
    static let address = "vadim.narb@yandex.com"
}

enum AppStoreLinks {
    static let appID = "6820971713"

    static var writeReviewURL: URL? {
        URL(string: "itms-apps://itunes.apple.com/app/id\(appID)?action=write-review")
    }

    static var shareURL: URL {
        URL(string: "https://apps.apple.com/app/id\(appID)")!
    }
}

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionService: SubscriptionService
    @State private var activeSheet: SettingsSheet?
    @State private var showOnboardingReplay = false
    @State private var showPaywall = false
    @State private var showShareSheet = false
    @State private var showPinClearConfirm = false
    @State private var showUnlinkConfirm = false
    @State private var isUnlinking = false
    @FocusState private var focusedField: SettingsFocusField?

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackgroundView(usesSharedCanvas: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if appState.deviceRole == .parent {
                            premiumSection
                        }
                        pairingSection
                        if appState.deviceRole == .parent {
                            parentPinSection
                        }
                        if appState.deviceRole == .parent || appState.isParentModeActive {
                            removalProtectionSection
                        }
                        if appState.deviceRole == .child,
                           appState.isParentModeActive,
                           appState.childLocationAuthorizationStatus != .authorizedAlways {
                            locationPermissionSection
                        }
                        appSection
                        helpSection
#if DEBUG && !HIDE_DEBUG_UI
                        diagnosticsSection
#endif
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
                case .removalProtection:
                    RemovalProtectionView()
                case .pinSetup:
                    ParentPinSetupSheet()
                        .environmentObject(appState)
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                #if DEBUG && !HIDE_DEBUG_UI
                case .permissions:
                    PermissionsSettingsSheet()
                        .environmentObject(appState)
                        .presentationDragIndicator(.hidden)
                #endif
                }
            }
            .confirmationDialog(
                Text("settings.pin.clear.confirm.title"),
                isPresented: $showPinClearConfirm,
                titleVisibility: .visible
            ) {
                Button("settings.pin.clear.confirm.action", role: .destructive) {
                    Task { await appState.clearParentPinFromUI() }
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("settings.pin.clear.confirm.message")
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
                if appState.deviceRole == .parent {
                    PaywallView(isPresented: $showPaywall, openSource: .settings)
                        .environmentObject(subscriptionService)
                }
            }
        }
        .onAppear { refreshLocationPermissionStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshLocationPermissionStatus() }
        }
    }

    private func refreshLocationPermissionStatus() {
        guard appState.deviceRole == .child else { return }
        appState.refreshChildLocationAuthorizationStatus()
    }

    private var premiumSection: some View {
        let hasPaidAccess = appState.isFamilyAccessAllowed && FamilyAccessStore.receipt?.lease.state == .paid
        return VStack(alignment: .leading, spacing: 10) {
            Text("settings.section.premium")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))

            settingsRow(
                titleKey: hasPaidAccess ? "settings.premium.paid_active" : "settings.premium.unlock_all",
                titleColor: hasPaidAccess ? AppTheme.neonGreen : .white
            ) {
                guard appState.deviceRole == .parent else { return }
                AppAnalytics.report("settings_premium_tap")
                showPaywall = true
            }
        }
        .padding()
        // Запекаем glow/тени glass-card в Metal-текстуру (как на «Расписании»/Dashboard), чтобы
        // скролл не пересчитывал shadow-слои покадрово. Запекаем только ФОН (Color.clear.glassCard),
        // контент остаётся снаружи drawingGroup и полностью интерактивен. Обёртка
        // padding(36)/drawingGroup/padding(-36) сохраняет эффекты в зоне padding и возвращает layout-frame.
        .background(
            Color.clear
                .glassCard(cornerRadius: 24, glowColor: AppTheme.neonGreen)
                .padding(36)
                .drawingGroup()
                .padding(-36)
        )
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr(appState.deviceRole == .parent
                 ? "settings.section.child_connection"
                 : "settings.section.parent_connection"))
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)

            if appState.deviceRole == .parent {
                parentPairingSection
            } else {
                childPairingSection
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.clear
                .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
                .padding(36)
                .drawingGroup()
                .padding(-36)
        )
    }

    private var removalProtectionSection: some View {
        Button {
            activeSheet = .removalProtection
            AppAnalytics.report("removal_protection_open", parameters: ["source": "settings"])
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("protection.title")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text("protection.settings_description")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            Color.clear
                .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
                .padding(36)
                .drawingGroup()
                .padding(-36)
        )
    }

    private var locationPermissionSection: some View {
        Button {
            Task { await appState.configureChildLocationAccessFromParentMode() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("onboarding.location.title")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(L10n.tr(locationPermissionDescriptionKey))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(appState.isConfiguringChildLocationAccess)
        .background(
            Color.clear
                .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
                .padding(36)
                .drawingGroup()
                .padding(-36)
        )
    }

    private var locationPermissionDescriptionKey: String {
        switch appState.childLocationAuthorizationStatus {
        case .notDetermined: return "setup.location.body"
        case .authorizedAlways: return "location.settings.ready"
        default: return "location.settings.description"
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.section.app")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))

            settingsRow(titleKey: "settings.item.language") {
                AppAnalytics.report("settings_language_tap")
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        }
        .padding()
        .background(
            Color.clear
                .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
                .padding(36)
                .drawingGroup()
                .padding(-36)
        )
    }

#if DEBUG && !HIDE_DEBUG_UI
    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.section.diagnostics")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
            settingsRow(titleKey: "settings.item.permissions") {
                AppAnalytics.report("settings_permissions_open")
                activeSheet = .permissions
            }
        }
        .padding()
        .background(
            Color.clear
                .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
                .padding(36)
                .drawingGroup()
                .padding(-36)
        )
    }
#endif

    private var parentPairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.pairingState?.isLinked == true {
                linkedPairingView
            } else {
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
        }
        .padding(.vertical, 8)
    }

    private var childPairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.pairingState?.isLinked == true {
                linkedPairingView
            } else {
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
                if let message = appState.remoteStatusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.neonBlue)
                }
            }
        }
        .padding(.vertical, 8)
    }

    /// Состояние «устройства связаны»: чистый статус + кнопка «Отвязать устройства» (сброс связки).
    /// Намеренно НЕ показываем `remoteStatusMessage` — это общий канал статусов команд
    /// (включая «отменено» от отменённых фоновых запросов), не относящийся к связке.
    private var linkedPairingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(AppTheme.neonGreen)
                Text("settings.pairing.linked.status")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.neonGreen)
            }
            Button(role: .destructive) {
                showUnlinkConfirm = true
            } label: {
                HStack(spacing: 8) {
                    if isUnlinking { ProgressView().tint(.white) }
                    Text("settings.pairing.unlink")
                }
            }
            .buttonStyle(SecondaryInlineButtonStyle())
            .disabled(isUnlinking)
            .confirmationDialog(
                "settings.pairing.unlink.confirm.title",
                isPresented: $showUnlinkConfirm,
                titleVisibility: .visible
            ) {
                Button("settings.pairing.unlink.confirm.button", role: .destructive) {
                    isUnlinking = true
                    Task {
                        await appState.unlinkDevices()
                        isUnlinking = false
                    }
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("settings.pairing.unlink.confirm.message")
            }
        }
    }

    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Управление родительским PIN: установка/смена/удаление. Показывается только в роли parent.
    /// Сам PIN хранится локально в Keychain + хэш на backend; ребёнок никогда не видит исходный PIN.
    private var parentPinSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.pin.section")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))

            Text("settings.pin.description")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Image(systemName: appState.parentPinIsSet ? "lock.fill" : "lock.open")
                    .foregroundStyle(appState.parentPinIsSet ? AppTheme.neonGreen : AppTheme.neonOrange)
                Text(appState.parentPinIsSet ? "settings.pin.status.set" : "settings.pin.status.unset")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.vertical, 6)

            if appState.pairingState?.isLinked != true {
                // PIN можно задать только после связки устройств: запрос уходит на backend и
                // привязан к семье. До связки — дизейблим и показываем подсказку, иначе была бы
                // непонятная ошибка при сохранении.
                Text("settings.pin.requires_link")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                settingsRow(titleKey: "settings.pin.set", action: {})
                    .disabled(true)
                    .opacity(0.45)
            } else if appState.parentPinIsSet {
                settingsRow(titleKey: "settings.pin.change") {
                    AppAnalytics.report("settings_pin_change_tap")
                    activeSheet = .pinSetup
                }
                Button {
                    AppAnalytics.report("settings_pin_clear_tap")
                    showPinClearConfirm = true
                } label: {
                    HStack {
                        Text("settings.pin.clear")
                            .font(.body.weight(.medium))
                            .foregroundStyle(AppTheme.neonOrange)
                        Spacer()
                        Image(systemName: "trash")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(AppTheme.neonOrange)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
            } else {
                settingsRow(titleKey: "settings.pin.set") {
                    AppAnalytics.report("settings_pin_set_tap")
                    activeSheet = .pinSetup
                }
            }
        }
        .padding()
        // Запекаем фон glass-card (см. premiumSection). Кнопки PIN остаются интерактивными.
        .background(
            Color.clear
                .glassCard(cornerRadius: 24, glowColor: AppTheme.neonOrange)
                .padding(36)
                .drawingGroup()
                .padding(-36)
        )
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
        // Запекаем фон glass-card (см. premiumSection) — единый безопасный паттерн со всеми секциями.
        .background(
            Color.clear
                .glassCard(cornerRadius: 24, glowColor: AppTheme.neonPurple)
                .padding(36)
                .drawingGroup()
                .padding(-36)
        )
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

    private func settingsRow(titleKey: String, titleColor: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(LocalizedStringKey(titleKey))
                    .font(.body.weight(.medium))
                    .foregroundStyle(titleColor)
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
}

private enum SettingsFocusField: Hashable {
    case childPairingCode
}

private enum SettingsSheet: Int, Identifiable {
    case removalProtection
    case pinSetup
    #if DEBUG && !HIDE_DEBUG_UI
    case permissions
    #endif

    var id: Int { rawValue }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
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
                    permissionRow("settings.permission.notifications", isOn: appState.isNotificationAuthorized)
                    if appState.deviceRole == .child {
                        permissionRow("settings.permission.screentime", isOn: appState.screenTimeService.isAuthorized)
                    }

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

/// Лист установки/смены родительского PIN. Два поля по 4 цифры (новый PIN и повторение),
/// валидация в реальном времени, кнопка «Сохранить» активна только при совпадении и валидности.
/// При успехе закрывает себя и обновляет `appState.parentPinIsSet`.
struct ParentPinSetupSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var newPin: String = ""
    @State private var confirmPin: String = ""
    @State private var isSaving = false
    @State private var errorKey: String?
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case newPin
        case confirmPin
    }

    private var pinIsValid: Bool {
        newPin.count == 4 && newPin.allSatisfy(\.isNumber)
    }

    private var canSave: Bool {
        pinIsValid && newPin == confirmPin && !isSaving
    }

    var body: some View {
        VStack(spacing: 0) {
            // Системный индикатор перетягивания включён через `.presentationDragIndicator(.visible)`,
            // поэтому собственную «полоску» здесь не рисуем (иначе дублируется).
            VStack(spacing: 18) {
                Text(appState.parentPinIsSet ? "settings.pin.sheet.title.change" : "settings.pin.sheet.title.set")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text("settings.pin.sheet.subtitle")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                pinField(
                    titleKey: "settings.pin.sheet.new",
                    text: $newPin,
                    field: .newPin
                )
                pinField(
                    titleKey: "settings.pin.sheet.confirm",
                    text: $confirmPin,
                    field: .confirmPin
                )

                if let errorKey {
                    Text(LocalizedStringKey(errorKey))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(AppTheme.neonOrange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                Button {
                    Task { await savePin() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("settings.pin.sheet.save")
                    }
                }
                .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
                .disabled(!canSave)
                .opacity(canSave ? 1.0 : 0.5)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 18)
        }
        .appScreenBackground()
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            focused = .newPin
        }
    }

    private func pinField(titleKey: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(titleKey))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            SecureField("", text: text)
                .keyboardType(.numberPad)
                .focused($focused, equals: field)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
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
                .onChange(of: text.wrappedValue) { _, newValue in
                    // Ограничиваем 4 цифры; всё нечисловое отфильтровываем сразу,
                    // чтобы пользователь не «застрял» в невалидном состоянии.
                    let filtered = newValue.filter(\.isNumber).prefix(4)
                    if filtered != newValue {
                        text.wrappedValue = String(filtered)
                    }
                    errorKey = nil
                }
        }
    }

    private func savePin() async {
        guard !isSaving else { return }
        guard pinIsValid else {
            errorKey = "settings.pin.sheet.error.format"
            return
        }
        guard newPin == confirmPin else {
            errorKey = "settings.pin.sheet.error.mismatch"
            return
        }
        isSaving = true
        defer { isSaving = false }
        let success = await appState.setParentPinFromUI(newPin)
        if success {
            dismiss()
        } else {
            errorKey = "settings.pin.sheet.error.network"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(SubscriptionService())
}
