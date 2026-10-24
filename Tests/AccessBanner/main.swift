import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

let states: [FamilyAccessLease.State?] = [nil, .setup, .demo, .paid, .expired, .verificationRequired]
for state in states {
    for parent in [false, true] {
        for pending in [false, true] {
            let active = FamilyAccessBannerPresentation.resolve(allowed: true, isParent: parent,
                awaitingPurchase: pending, leaseState: state)
            check(active == .hidden, "Allowed access never shows a blocked banner, including paid offline")
            let blocked = FamilyAccessBannerPresentation.resolve(allowed: false, isParent: parent,
                awaitingPurchase: pending, leaseState: state)
            if !parent {
                check(blocked.action == nil, "Child must not purchase, retry or open a paywall")
                check(blocked == .childPaused || blocked == .childVerification, "Child copy ignores local purchase state")
            } else if pending {
                check(blocked == .purchasePending, "An unconfirmed purchase must not ask to pay again")
                check(blocked.buttonKey == "access.banner.check_status", "Check an existing purchase, not select a new plan")
            } else if state == .demo || state == .expired {
                check(blocked == .parentPaused, "Inactive access can offer plans")
                check(blocked.titleKey == "access.banner.inactive.title", "No guessed reason for expiry or refund")
                check(blocked.buttonKey == "access.banner.choose_plan", "Single clear CTA")
            } else {
                check(blocked == .parentVerification, "Missing, setup or unverified state is not subscription expiry")
                check(blocked.buttonKey == "access.banner.check_status", "Check status when not confirmed")
            }
        }
    }
}
check(FamilyAccessBannerPresentation.childPaused.messageKey == "access.banner.child.body", "Dedicated child message")
check(FamilyAccessBannerPresentation.childVerification.messageKey == "access.banner.child_verification.body", "Unverified child state does not tell parent to purchase")
print("Passed \(checks) access-banner checks")
