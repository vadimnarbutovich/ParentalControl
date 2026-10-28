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
                awaitingPurchase: pending, leaseState: state, confirmedState: state)
            check(active == .hidden, "Allowed access never shows a blocked banner, including paid offline")
            let blocked = FamilyAccessBannerPresentation.resolve(allowed: false, isParent: parent,
                awaitingPurchase: pending, leaseState: state, confirmedState: state)
            if state == .setup {
                check(blocked == (parent ? .parentSetup : .childSetup), "Setup is not a subscription problem, even with a pending purchase")
                check(blocked.action == nil, "Finishing setup must not require a purchase")
                check(blocked.titleKey == "access.banner.setup.title", "Setup has its own title")
            } else if parent && pending {
                check(blocked == .purchasePending, "An unconfirmed purchase must not ask to pay again")
                check(blocked.buttonKey == "access.banner.check_status", "Check an existing purchase, not select a new plan")
            } else if state == .expired || state == .verificationRequired {
                check(blocked == (parent ? .parentPaused : .childPaused), "Confirmed expiry shows the appropriate banner")
                check((blocked.action != nil) == parent, "Only parents can open a paywall")
            } else {
                check(blocked == .hidden, "Missing or locally expired demo must not flash a paused banner")
            }
            let checking = FamilyAccessBannerPresentation.resolve(allowed: false, isParent: parent,
                awaitingPurchase: pending, leaseState: state, confirmedState: nil)
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
func lease(_ state: FamilyAccessLease.State, revision: Int = 7, issued: Int64 = 2_000,
           until: Int64? = nil, for binding: FamilyAccessBannerSession.Scope = scope) -> FamilyAccessLease {
    .init(protocolVersion: 1, familyID: binding.familyID, pairingID: binding.childID,
          revision: revision, issuedAtMs: issued, controlUntilMs: until,
          nextCheckAtMs: min(issued + 100, until ?? Int64.max), state: state)
}
let expired = lease(.expired)
var session = FamilyAccessBannerSession()
func confirmed(_ scope: FamilyAccessBannerSession.Scope?) -> Bool {
    session.confirmedState(for: scope, currentLease: expired) != nil
}
check(!confirmed(scope), "Cold launch cannot show cached expiry")
let firstRequest = session.requestToken
session.confirm(token: firstRequest, scope: scope, currentScope: scope, lease: expired)
check(confirmed(scope), "Successful foreground status check confirms this pairing")
check(!confirmed(anotherScope), "Confirmation never carries to another pairing")
check(!confirmed(nil), "Unlinked device cannot inherit confirmation")
session.enterForeground()
check(confirmed(scope), "Transient system overlays must not flicker a confirmed banner")
session.enterBackground()
session.confirm(token: firstRequest, scope: scope, currentScope: scope, lease: expired)
check(!confirmed(scope), "Late response after background cannot confirm UI")
let backgroundRequest = session.requestToken
session.enterForeground()
session.confirm(token: backgroundRequest, scope: scope, currentScope: scope, lease: expired)
session.confirm(token: firstRequest, scope: scope, currentScope: scope, lease: expired)
check(!confirmed(scope), "Neither background nor previous-session replies can reveal cached expiry")
session.confirm(token: session.requestToken, scope: scope, currentScope: anotherScope, lease: expired)
check(!confirmed(anotherScope), "Pairing changes while awaiting a response are fenced")
session.confirm(token: session.requestToken, scope: nil, currentScope: nil, lease: expired)
check(!confirmed(nil), "Missing pairing is not confirmation")
session.confirm(token: session.requestToken, scope: scope, currentScope: scope, lease: expired)
check(confirmed(scope), "A new foreground check can show real expiry")
// Polling failures do not call confirm or reset: already confirmed expiry stays
// visible, avoiding a hide/show cycle on every refresh.
check(confirmed(scope), "A later offline interval preserves confirmed status in this session")

// Real regression: server ends demo without changing revision; stored receipt
// intentionally remains demo. Presentation must use the fresh server response.
let demo = lease(.demo, issued: 1_000, until: 2_000)
let denied = lease(.verificationRequired)
check(!denied.mayReplace(demo, family: scope.familyID, pairing: scope.childID), "Receipt policy remains unchanged")
session = FamilyAccessBannerSession()
session.confirm(token: session.requestToken, scope: scope, currentScope: scope, lease: demo)
let oldDemoStatus = session.confirmedState(for: scope, currentLease: demo)
check(FamilyAccessBannerPresentation.resolve(allowed: false, isParent: true, awaitingPurchase: false,
    leaseState: .demo, confirmedState: oldDemoStatus) == .hidden, "Local clock expiry alone is not fresh server denial")
session.confirm(token: session.requestToken, scope: scope, currentScope: scope, lease: denied)
let freshStatus = session.confirmedState(for: scope, currentLease: demo)
check(freshStatus == .verificationRequired, "Natural demo expiry is visible despite retained receipt")
for parent in [true, false] {
    check(FamilyAccessBannerPresentation.resolve(allowed: false, isParent: parent, awaitingPurchase: false,
        leaseState: .demo, confirmedState: freshStatus) == (parent ? .parentPaused : .childPaused),
        "Both devices show the correct expired-demo card")
    check(FamilyAccessBannerPresentation.resolve(allowed: true, isParent: parent, awaitingPurchase: false,
        leaseState: .paid, confirmedState: freshStatus) == .hidden, "Purchase removes the card immediately")
}
let paid = lease(.paid, revision: 8, issued: 2_100, until: 4_000)
check(session.confirmedState(for: scope, currentLease: paid) == nil, "Old denial cannot override a newer purchase")
check(session.confirmedState(for: scope, currentLease: lease(.demo, revision: 8, until: 4_000)) == nil,
      "A newer demo decision also fences old denial")
session.confirm(token: session.requestToken, scope: scope, currentScope: scope, lease: paid)
session.confirm(token: session.requestToken, scope: scope, currentScope: scope, lease: denied)
check(session.confirmedState(for: scope, currentLease: paid) == .paid, "Delayed older denial cannot replace fresh paid evidence")
session.enterBackground()
session.enterForeground()
check(session.confirmedState(for: scope, currentLease: demo) == nil, "Returning to app hides stale denial until checked")
session.confirm(token: session.requestToken, scope: scope, currentScope: scope, lease: nil)
check(session.confirmedState(for: scope, currentLease: demo) == nil, "Disabled enforcement or missing lease cannot confirm denial")
session.confirm(token: session.requestToken, scope: scope, currentScope: scope, lease: lease(.verificationRequired, for: anotherScope))
check(session.confirmedState(for: scope, currentLease: demo) == nil, "Response payload must match requested pairing")
session.confirm(token: session.requestToken, scope: scope, currentScope: scope, lease: lease(.verificationRequired, until: 3_000))
check(session.confirmedState(for: scope, currentLease: demo) == nil, "Malformed denial is ignored")
session.confirm(token: session.requestToken, scope: scope, currentScope: scope, lease: lease(.verificationRequired, issued: 1_500))
check(session.confirmedState(for: scope, currentLease: demo) == nil, "Same-revision response before demo deadline is not expiry")
print("Passed \(checks) access-banner checks")
