import SwiftUI
import Combine

@MainActor
private enum FamilyAccessPresentation {
    static var stack = FamilyAccessPresentationStack()
}

private struct FamilyAccessPaywallPresenter: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var subscriptions: SubscriptionService
    @State private var id = UUID()
    @State private var isPresented = false
    let isRoot: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { FamilyAccessPresentation.stack.register(id, isRoot: isRoot) }
            .onDisappear { FamilyAccessPresentation.stack.unregister(id) }
            .onReceive(NotificationCenter.default.publisher(for: FamilyAccessStore.purchaseRequired)
                .receive(on: RunLoop.main)) { _ in
                guard appState.deviceRole == .parent,
                      FamilyAccessPresentation.stack.presenter == id,
                      !FamilyAccessStore.isSettingUp else { return }
                isPresented = true
            }
            .fullScreenCover(isPresented: $isPresented) {
                PaywallView(isPresented: $isPresented)
                    .environmentObject(subscriptions)
            }
    }
}

extension View {
    /// Each presentation owns its full-screen paywall so closing it returns to
    /// the same screen, including an editor sheet with an unsaved draft.
    func familyAccessPaywall(isRoot: Bool = false) -> some View {
        modifier(FamilyAccessPaywallPresenter(isRoot: isRoot))
    }
}
