import Foundation

/// Copy and actions only. Never derives or grants access from SDK metadata.
nonisolated enum FamilyAccessBannerPresentation: Equatable {
    case hidden, parentPaused, childPaused, purchasePending, parentVerification, childVerification

    enum Action { case paywall }

    static func resolve(allowed: Bool, isParent: Bool, awaitingPurchase: Bool,
                        leaseState: FamilyAccessLease.State?) -> Self {
        guard !allowed else { return .hidden }
        if isParent && awaitingPurchase { return .purchasePending }
        // A missing or unverified receipt is not proof of an expired subscription.
        if leaseState == nil || leaseState == .verificationRequired || leaseState == .paid || leaseState == .setup {
            return isParent ? .parentVerification : .childVerification
        }
        return isParent ? .parentPaused : .childPaused
    }

    var titleKey: String {
        switch self {
        case .hidden: ""
        case .parentPaused: "access.banner.inactive.title"
        case .childPaused, .childVerification: "access.banner.paused.title"
        case .purchasePending: "access.banner.pending.title"
        case .parentVerification: "access.banner.verification.title"
        }
    }

    var messageKey: String {
        switch self {
        case .hidden: ""
        case .parentPaused: "access.banner.parent.body"
        case .childPaused: "access.banner.child.body"
        case .purchasePending: "access.banner.pending.body"
        case .parentVerification: "access.banner.verification.body"
        case .childVerification: "access.banner.child_verification.body"
        }
    }

    var action: Action? {
        switch self {
        case .parentPaused, .purchasePending, .parentVerification: .paywall
        case .hidden, .childPaused, .childVerification: nil
        }
    }

    var buttonKey: String {
        self == .parentPaused ? "access.banner.choose_plan" : "access.banner.check_status"
    }
}
