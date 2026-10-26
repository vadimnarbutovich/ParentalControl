//
//  ContentView.swift
//  ParentalControl
//
//  Created by Vadzim Narbutovich on 03.03.2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptionService: SubscriptionService

    var body: some View {
        AppBackgroundContainer {
            VStack(spacing: 0) {
                PermissionReminderBannerView()
                if appState.hasCompletedOnboarding, appState.deviceRole != nil {
                    FamilyAccessBannerView()
                }
                if appState.isCheckingInstallationRecovery || appState.recoveredFamily != nil || appState.installationRecoveryFailed {
                    FamilyRecoveryView()
                } else if let role = appState.deviceRole {
                    if appState.hasCompletedOnboarding {
                        MainTabView()
                            .environmentObject(subscriptionService)
                    } else if let familyID = appState.recoverySetupFamilyID {
                        RecoverySetupView().id(familyID)
                    } else {
                        OnboardingFlowView()
                            .id(role)
                    }
                } else {
                    RoleSelectionView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .familyAccessPaywall(isRoot: true)
        .onReceive(NotificationCenter.default.publisher(for: FamilyAccessStore.changed)) { _ in
            appState.adoptFamilyAccess()
        }
        .onChange(of: subscriptionService.isPro) { _, isPro in
            appState.enforcePremiumFeatures(isPro: isPro, isStatusKnown: subscriptionService.isSubscriptionStatusKnown)
        }
        .onChange(of: subscriptionService.isSubscriptionStatusKnown) { _, isKnown in
            appState.enforcePremiumFeatures(isPro: subscriptionService.isPro, isStatusKnown: isKnown)
        }
    }
}

private struct FamilyRecoveryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showsPin = false
    @State private var confirmsReset = false

    private var busy: Bool {
        appState.isCheckingInstallationRecovery || appState.isResettingRecoveredFamily
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(AppTheme.neonBlue)
                    .accessibilityHidden(true)
                Text(appState.isCheckingInstallationRecovery || appState.recoveredFamily == nil ? "recovery.checking" : "recovery.title")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                if appState.installationRecoveryFailed {
                    Text("recovery.error")
                        .foregroundStyle(.white.opacity(0.75))
                    Button("reports.retry") {
                        Task { await appState.checkInstallationRecovery(retry: true) }
                    }
                    .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
                } else if appState.recoveredFamily != nil {
                    Text("recovery.message")
                        .foregroundStyle(.white.opacity(0.75))
                    Button("recovery.restore") { appState.restoreRecoveredFamily() }
                        .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
                    Button("recovery.reset") {
                        if appState.recoveredDeviceRole == .child { showsPin = true }
                        else { confirmsReset = true }
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle(tint: AppTheme.neonBlue))
                    if appState.recoveredDeviceRole == .child {
                        Text("recovery.child_hint")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                if busy { ProgressView().tint(.white) }
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
            .disabled(busy)
        }
        .scrollIndicators(.hidden)
        .fullScreenCover(isPresented: $showsPin, onDismiss: {
            if appState.isParentModeActive { confirmsReset = true }
        }) {
            ParentModeEntryView(isPresented: $showsPin)
        }
        .alert("recovery.reset", isPresented: $confirmsReset) {
            Button("common.cancel", role: .cancel) { appState.exitParentMode() }
            Button("recovery.reset", role: .destructive) {
                Task { await appState.resetRecoveredFamily() }
            }
        } message: {
            Text("recovery.confirm")
        }
    }
}

private struct RoleSelectionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    OnboardingFamilyIllustration(tint: AppTheme.neonBlue,
                                                 compact: geometry.size.height < 700)
                    VStack(spacing: 14) {
                        Text("role.select.title")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .accessibilityAddTraits(.isHeader)
                        Text("role.select.subtitle")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 14) {
                        roleCard("role.select.parent", image: "onboardingParents", tint: AppTheme.neonBlue) {
                            appState.chooseDeviceRole(.parent)
                        }
                        roleCard("role.select.child", image: "onboardingChildren", tint: AppTheme.neonGreen) {
                            appState.chooseDeviceRole(.child)
                        }
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(AppBackgroundView(usesSharedCanvas: true))
        .preferredColorScheme(.dark)
    }

    private func roleCard(_ title: String, image: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text(L10n.tr(title))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 24, glowColor: tint, drawsOuterShadows: false)
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(ScreenTimeService(appStore: AppGroupStore()))
        .environmentObject(SubscriptionService())
}
