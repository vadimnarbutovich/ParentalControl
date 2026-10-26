import Foundation

/// Copy and actions only. Never derives or grants access from SDK metadata.
nonisolated enum FamilyAccessBannerPresentation: Equatable {
    case hidden, parentSetup, childSetup, parentPaused, childPaused, purchasePending

    enum Action { case paywall }

    static func resolve(allowed: Bool, isParent: Bool, awaitingPurchase: Bool,
                        leaseState: FamilyAccessLease.State?, statusConfirmed: Bool) -> Self {
        guard !allowed else { return .hidden }
        if leaseState == .setup { return isParent ? .parentSetup : .childSetup }
        if isParent && awaitingPurchase { return .purchasePending }
        // Cached denial and a local demo-clock failure are not fresh confirmation
        // of expiry. Show no placeholder while the existing status request runs.
        guard statusConfirmed, leaseState == .expired else { return .hidden }
        return isParent ? .parentPaused : .childPaused
    }

    var titleKey: String {
        switch self {
        case .hidden: ""
        case .parentSetup, .childSetup: "access.banner.setup.title"
        case .parentPaused: "access.banner.inactive.title"
        case .childPaused: "access.banner.paused.title"
        case .purchasePending: "access.banner.pending.title"
        }
    }

    var messageKey: String {
        switch self {
        case .hidden: ""
        case .parentSetup: "access.banner.setup.parent.body"
        case .childSetup: "access.banner.setup.child.body"
        case .parentPaused: "access.banner.parent.body"
        case .childPaused: "access.banner.child.body"
        case .purchasePending: "access.banner.pending.body"
        }
    }

    var action: Action? {
        switch self {
        case .parentPaused, .purchasePending: .paywall
        case .hidden, .parentSetup, .childSetup, .childPaused: nil
        }
    }

    var symbolName: String {
        switch self {
        case .parentSetup, .childSetup: "iphone"
        case .purchasePending: "hourglass"
        default: "pause.circle.fill"
        }
    }

    var buttonKey: String {
        self == .parentPaused ? "access.banner.choose_plan" : "access.banner.check_status"
    }
}

/// Presentation only: never changes access, receipt storage or refresh cadence.
/// A response from the previous foreground session/family cannot reveal a
/// cached paused banner after returning to the app or changing the pairing.
nonisolated struct FamilyAccessBannerSession {
    struct Scope: Equatable {
        let familyID: UUID
        let childID: UUID
    }
    private(set) var requestToken = UUID()
    private var isForeground = true
    private var confirmedScope: Scope?

    func isConfirmed(for scope: Scope?) -> Bool {
        isForeground && scope != nil && confirmedScope == scope
    }

    mutating func enterBackground() {
        isForeground = false
        requestToken = UUID()
        confirmedScope = nil
    }

    mutating func enterForeground() {
        if !isForeground { requestToken = UUID() }
        isForeground = true
    }

    mutating func confirm(token: UUID, scope: Scope?, currentScope: Scope?) {
        guard isForeground, token == requestToken, let scope, scope == currentScope else { return }
        confirmedScope = scope
    }
}
