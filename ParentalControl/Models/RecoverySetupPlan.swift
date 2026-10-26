import Foundation

nonisolated enum OnboardingStep: String {
    case parentIntro, childIntro, install, notifications, screenTime, location
    case pairing, pin, apps, protection, limit, finish
}

/// Build once from confirmed server data and current device permissions.
/// Do not mutate the step array while its current page is being completed.
nonisolated enum RecoverySetupPlan {
    static func steps(isParent: Bool, notifications: Bool, screenTime: Bool,
                      location: Bool, pinConfigured: Bool, appsSelected: Bool,
                      configurationAllowed: Bool, budgetExists: Bool) -> [OnboardingStep] {
        // A retained family link cannot tell us whether the child app is installed.
        // Reuse the optional install/share page without creating a new pairing.
        var result: [OnboardingStep] = isParent ? [.install] : []
        if !isParent && !screenTime { result.append(.screenTime) }
        if !notifications { result.append(.notifications) }
        if !isParent && !location { result.append(.location) }
        let needsApps = !isParent && configurationAllowed && (!screenTime || !appsSelected)
        // Existing PIN is verified before opening the protected child app picker.
        if !pinConfigured || needsApps { result.append(.pin) }
        if needsApps { result.append(.apps) }
        if isParent && configurationAllowed && !budgetExists { result.append(.limit) }
        return result
    }
}
