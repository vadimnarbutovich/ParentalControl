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
                awaitingPurchase: pending, leaseState: state, statusConfirmed: true)
            check(active == .hidden, "Allowed access never shows a blocked banner, including paid offline")
            let blocked = FamilyAccessBannerPresentation.resolve(allowed: false, isParent: parent,
                awaitingPurchase: pending, leaseState: state, statusConfirmed: true)
            if state == .setup {
                check(blocked == (parent ? .parentSetup : .childSetup), "Setup is not a subscription problem, even with a pending purchase")
                check(blocked.action == nil, "Finishing setup must not require a purchase")
                check(blocked.titleKey == "access.banner.setup.title", "Setup has its own title")
            } else if parent && pending {
                check(blocked == .purchasePending, "An unconfirmed purchase must not ask to pay again")
                check(blocked.buttonKey == "access.banner.check_status", "Check an existing purchase, not select a new plan")
            } else if state == .expired {
                check(blocked == (parent ? .parentPaused : .childPaused), "Confirmed expiry shows the appropriate banner")
                check((blocked.action != nil) == parent, "Only parents can open a paywall")
            } else {
                check(blocked == .hidden, "Missing, unverified or locally expired demo must not flash a paused banner")
            }
            let checking = FamilyAccessBannerPresentation.resolve(allowed: false, isParent: parent,
                awaitingPurchase: pending, leaseState: state, statusConfirmed: false)
            if state == .setup {
                check(checking == (parent ? .parentSetup : .childSetup), "Setup guidance remains available")
            } else if parent && pending {
                check(checking == .purchasePending, "Explicit purchase confirmation remains a separate flow")
            } else {
                check(checking == .hidden, "Checking, cold launch and offline startup reserve no banner space")
            }
        }
    }
}
check(FamilyAccessBannerPresentation.childPaused.messageKey == "access.banner.child.body", "Dedicated child message")
let scope = FamilyAccessBannerSession.Scope(familyID: UUID(), childID: UUID())
let anotherScope = FamilyAccessBannerSession.Scope(familyID: scope.familyID, childID: UUID())
var session = FamilyAccessBannerSession()
check(!session.isConfirmed(for: scope), "Cold launch cannot show cached expiry")
let firstRequest = session.requestToken
session.confirm(token: firstRequest, scope: scope, currentScope: scope)
check(session.isConfirmed(for: scope), "Successful foreground status check confirms this pairing")
check(!session.isConfirmed(for: anotherScope), "Confirmation never carries to another pairing")
check(!session.isConfirmed(for: nil), "Unlinked device cannot inherit confirmation")
session.enterForeground()
check(session.isConfirmed(for: scope), "Transient system overlays must not flicker a confirmed banner")
session.enterBackground()
session.confirm(token: firstRequest, scope: scope, currentScope: scope)
check(!session.isConfirmed(for: scope), "Late response after background cannot confirm UI")
let backgroundRequest = session.requestToken
session.enterForeground()
session.confirm(token: backgroundRequest, scope: scope, currentScope: scope)
session.confirm(token: firstRequest, scope: scope, currentScope: scope)
check(!session.isConfirmed(for: scope), "Neither background nor previous-session replies can reveal cached expiry")
session.confirm(token: session.requestToken, scope: scope, currentScope: anotherScope)
check(!session.isConfirmed(for: anotherScope), "Pairing changes while awaiting a response are fenced")
session.confirm(token: session.requestToken, scope: nil, currentScope: nil)
check(!session.isConfirmed(for: nil), "Missing pairing is not confirmation")
session.confirm(token: session.requestToken, scope: scope, currentScope: scope)
check(session.isConfirmed(for: scope), "A new foreground check can show real expiry")
// Polling failures do not call confirm or reset: already confirmed expiry stays
// visible, avoiding a hide/show cycle on every refresh.
check(session.isConfirmed(for: scope), "A later offline interval preserves confirmed status in this session")
print("Passed \(checks) access-banner checks")
