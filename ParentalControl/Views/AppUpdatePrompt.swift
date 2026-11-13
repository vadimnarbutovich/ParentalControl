import SwiftUI
import UIKit

struct AppUpdatePrompt: View {
    let offer: AppUpdatePolicy.Offer
    let update: () -> Void
    let later: () -> Void
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.65).ignoresSafeArea().accessibilityHidden(true)
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "arrow.down.app.fill")
                            .font(.system(size: 46, weight: .semibold))
                            .foregroundStyle(AppTheme.neonBlue)
                            .padding(18)
                            .background(AppTheme.neonBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: 24))
                            .accessibilityHidden(true)
                        VStack(spacing: 12) {
                            Text("app_update.title")
                                .font(.system(.title2, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityFocused($focused)
                            Text("app_update.message")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.78))
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 12) {
                            Button("app_update.update", action: update)
                                .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonGreen))
                            Button("app_update.later", action: later)
                                .buttonStyle(OnboardingSecondaryButtonStyle(tint: AppTheme.neonBlue))
                        }
                    }
                    .padding(24)
                    .glassCard(cornerRadius: 28, glowColor: AppTheme.neonBlue)
                    .frame(maxWidth: 420)
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, later)
        .onAppear { focused = true }
    }
}

private struct AppUpdatePresenter: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var service = AppUpdateService()
    @State private var offer: AppUpdatePolicy.Offer?
    let eligible: Bool

    private var active: Bool { eligible && scenePhase == .active }

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(offer == nil)
            .accessibilityHidden(offer != nil)
            .overlay {
                if let offer {
                    AppUpdatePrompt(offer: offer, update: {
                        self.offer = nil
                        openURL(AppStoreLinks.shareURL)
                    }, later: { self.offer = nil })
                }
            }
            .task(id: active) {
                guard active, offer == nil, let candidate = await service.availableUpdate(),
                      !Task.isCancelled, UIApplication.shared.applicationState == .active,
                      canPresent else { return }
                service.didPresent()
                offer = candidate
            }
            .onChange(of: active) { _, value in
                if !value { offer = nil }
            }
    }

    private var canPresent: Bool {
        // Do not compete with an editor, paywall, PIN entry, or native alert.
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        guard let root = windows.first(where: \.isKeyWindow)?.rootViewController else { return false }
        return root.presentedViewController == nil && !root.isBeingPresented && !root.isBeingDismissed
    }
}

extension View {
    func appUpdatePrompt(eligible: Bool) -> some View {
        modifier(AppUpdatePresenter(eligible: eligible))
    }
}

#Preview("Update — English") {
    ZStack {
        AppTheme.screenGradient.ignoresSafeArea()
        AppUpdatePrompt(offer: .init(version: "1.1"), update: {}, later: {})
    }
    .environment(\.locale, Locale(identifier: "en"))
}
