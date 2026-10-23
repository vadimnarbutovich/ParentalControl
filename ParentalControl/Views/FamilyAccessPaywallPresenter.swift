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
                      FamilyAccessPresentation.stack.presenter == id else { return }
                isPresented = true
            }
            .sheet(isPresented: $isPresented) {
                PaywallView(isPresented: $isPresented)
                    .environmentObject(subscriptions)
            }
    }
}

extension View {
    /// Sheets own their paywall so denial never replaces or dismisses a draft.
    func familyAccessPaywall(isRoot: Bool = false) -> some View {
        modifier(FamilyAccessPaywallPresenter(isRoot: isRoot))
    }
}
