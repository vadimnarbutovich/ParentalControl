import SwiftUI

/// Parent's phone shows instructions only. The authorization itself must take
/// place on the child's phone, inside the PIN-protected parent session.
struct RemovalProtectionView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var screenTimeService: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsGuide = false
    @State private var confirmsRemoval = false
    @State private var messageKey: String?

    private var canView: Bool {
        appState.deviceRole == .parent ||
            (appState.deviceRole == .child && appState.isParentModeActive)
    }
    private var canManage: Bool {
        appState.deviceRole == .child && appState.isParentModeActive
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if canView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("protection.intro")
                            .foregroundStyle(.secondary)
                        if canManage {
                            controls
                        } else {
                            // Never show the parent's local authorization as the child's status.
                            Text("protection.parent_instructions")
                        }
                        DisclosureGroup(isExpanded: $showsGuide) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("protection.guide.family")
                                Text("protection.guide.account")
                                Text("protection.guide.confirm")
                                Text("protection.guide.warning")
                                    .foregroundStyle(.secondary)
                                Link(L10n.tr("protection.guide.apple"),
                                     destination: URL(string: "https://support.apple.com/108380")!)
                            }
                            .padding(.top, 12)
                        } label: {
                            Text("protection.guide.title").font(.headline)
                        }
                        .tint(AppTheme.neonBlue)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .glassCard(cornerRadius: 24, glowColor: AppTheme.neonBlue)
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.hidden)
            .appScreenBackground()
            .navigationTitle(L10n.tr("protection.title"))
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(Text("protection.disable.title"), isPresented: $confirmsRemoval,
                                titleVisibility: .visible) {
                Button("protection.disable.action", role: .destructive) {
                    guard canManage else { return }
                    perform(disabling: true)
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("protection.disable.message")
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(screenTimeService.isAuthorizationRequestInProgress)
        .onAppear {
            screenTimeService.refreshAuthorizationStatus()
            if appState.deviceRole == .parent { showsGuide = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { screenTimeService.refreshAuthorizationStatus() }
        }
        .onChange(of: canView) { _, allowed in
            if !allowed { confirmsRemoval = false; dismiss() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.tr(screenTimeService.isRemovalProtectionEnabled
                          ? "protection.enabled"
                          : screenTimeService.prefersChildAuthorization
                            ? "protection.needs_confirmation" : "protection.not_enabled"),
                  systemImage: screenTimeService.isRemovalProtectionEnabled ? "checkmark.shield.fill" : "shield")
                .font(.headline)
                .foregroundStyle(screenTimeService.isRemovalProtectionEnabled ? AppTheme.neonGreen : AppTheme.neonOrange)

            if let messageKey {
                Text(L10n.tr(messageKey)).font(.subheadline).foregroundStyle(.secondary)
            }

            if screenTimeService.isRemovalProtectionEnabled {
                Button("protection.disable.action") { confirmsRemoval = true }
                    .buttonStyle(NeonChipButtonStyle(isActive: false, tint: AppTheme.neonRed))
                    .disabled(screenTimeService.isAuthorizationRequestInProgress)
            } else {
                Button { perform(disabling: false) } label: {
                    Text("protection.enable").frame(maxWidth: .infinity)
                }
                .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
                .disabled(screenTimeService.isAuthorizationRequestInProgress)
            }
            if screenTimeService.isAuthorizationRequestInProgress {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func perform(disabling: Bool) {
        guard canManage, !screenTimeService.isAuthorizationRequestInProgress else { return }
        messageKey = nil
        Task { @MainActor in
            do {
                if disabling {
                    try await appState.allowRemovalFromParentMode()
                    messageKey = "protection.disabled"
                } else {
                    try await appState.enableRemovalProtectionFromParentMode()
                }
            } catch {
                messageKey = RemovalProtectionError.messageKey(for: error)
                if messageKey == "protection.error.account" { showsGuide = true }
            }
        }
    }
}
