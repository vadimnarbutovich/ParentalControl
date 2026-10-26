import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}
check(ProPurchasePlan.allCases == [.annual, .monthly, .lifetime], "Annual selected first; no weekly plan")
check(RevenueCatConfig.revenueCatProjectId == "proj77ee7cb3", "Dedicated project")
check(RevenueCatConfig.defaultPublicSDKKey == "appl_KrCdjMXWpMntCfiZHePfqlqHZyC", "Dedicated App Store key")
check(RevenueCatConfig.entitlementIdentifier == "ParentalControl Pro", "Shared entitlement")
for plan in ProPurchasePlan.allCases {
    check(plan.packageIdentifier == "$rc_" + plan.rawValue, "Standard package identifiers")
    check(plan.productIdentifier == "mycompny.ParentalControl.pro." + plan.rawValue, "Product ID mapping")
}
check(ProPurchasePlan.annual.priceKey == "paywall.price.per_year_format", "Annual billing period")
check(ProPurchasePlan.monthly.priceKey == "paywall.price.per_month_format", "Monthly billing period")
check(ProPurchasePlan.lifetime.priceKey == "paywall.price.once_format", "One-time purchase")
for plan in ProPurchasePlan.allCases {
    for eligible in [true, false] {
        for free in [true, false] {
            for days in [nil, 1, 3, 7] as [Int?] {
                for periods in [1, 2] {
                    let expected = plan == .annual && eligible && free && days == 3 && periods == 1
                    check(plan.offersThreeDayTrial(isEligible: eligible, isFreeTrial: free,
                                                  durationDays: days, numberOfPeriods: periods) == expected,
                          "Only eligible three-day annual free trial may be advertised")
                }
            }
        }
    }
}
func savings(_ annual: String, _ monthly: String, _ annualCurrency: String? = "USD",
             _ monthlyCurrency: String? = "USD") -> Int? {
    PaywallSavings.annualPercent(annual: Decimal(string: annual)!,
                                monthly: Decimal(string: monthly)!,
                                annualCurrency: annualCurrency, monthlyCurrency: monthlyCurrency)
}
check(savings("12.99", "1.99") == 46, "US savings must reflect real prices, not a fixed 50%")
check(PaywallSavings.approximateBadgePercent(savings("12.99", "1.99")!) == 50, "US badge displays approximately 50%")
check(PaywallSavings.approximateBadgePercent(31) == 30, "Other regions use their actual approximate savings")
check(PaywallSavings.approximateBadgePercent(99) == 99, "Approximation must not advertise a free paid plan")
check(PaywallSavings.approximateBadgePercent(2) == 2, "Keep small savings visible")
check(savings("12", "2") == 50, "Exactly half price")
check(savings("24", "2") == nil, "No discount")
check(savings("25", "2") == nil, "Annual more expensive")
check(savings("0", "2") == nil, "Free price must not be advertised as paid discount")
check(savings("12", "0") == nil, "No division by zero")
check(savings("-1", "2") == nil, "Invalid annual price")
check(savings("12", "-2") == nil, "Invalid monthly price")
check(savings("12", "2", "USD", "EUR") == nil, "Do not compare different currencies")
check(savings("12", "2", nil, nil) == nil, "Do not assume missing currencies match")
check(savings("12", "2", "", "") == nil, "Empty currency is invalid")
check(savings("0.01", "100") == 99, "Never round up to 100% free")
check(PaywallSavings.annualPercent(annual: .nan, monthly: 1,
                                  annualCurrency: "USD", monthlyCurrency: "USD") == nil, "Reject NaN")
for paid in [false, true] {
    for pending in [false, true] {
        for product in [nil, "unknown"] + ProPurchasePlan.allCases.map({ Optional($0.productIdentifier) }) {
            let access = PaywallAccessPresentation(hasPaidAccess: paid, productIdentifier: product,
                                                  awaitingConfirmation: pending)
            check((access.statusKey != nil) == paid, "Only canonical paid access displays an active status")
            if !paid || pending {
                check(access.currentPlan == nil, "Expired/demo/unconfirmed products are not current plans")
            }
            for selected in ProPurchasePlan.allCases {
                let action = access.action(for: selected)
                if pending {
                    check(action == .retry, "Pending verification retries, never charges again")
                } else if !paid {
                    check(action == .purchase, "Stale SDK metadata cannot hide purchases after revocation")
                } else if access.currentPlan == .lifetime {
                    check(action == .none, "Lifetime suppresses purchases for every selection")
                    check(access.statusKey == "paywall.status.lifetime", "Lifetime is not described as a subscription")
                } else if selected == access.currentPlan {
                    check(action == .none, "Current plan is already owned; no repeat purchase or management redirect")
                } else {
                    check(action == .purchase, "Other plans remain selectable for a subscriber")
                }
            }
        }
    }
}
for plan in [ProPurchasePlan.monthly, .annual] {
    let offline = PaywallAccessPresentation(hasPaidAccess: true, productIdentifier: plan.productIdentifier,
                                           awaitingConfirmation: false)
    check(offline.currentPlan == plan, "Cached paid receipt retains its plan offline, without a local expiry timer")
    check(offline.statusKey == "paywall.status.\(plan.rawValue)", "Correct subscription status")
}
check(PurchaseCustomerIdentity.isCanonical("pc-e53ccc48-9fd3-4252-93f6-ea6111046888"), "Recognize server purchase owner")
for legacy in ["", "pc-", "pc-invalid", "sb-e53ccc48-9fd3-4252-93f6-ea6111046888", "$RCAnonymousID:123"] {
    check(!PurchaseCustomerIdentity.isCanonical(legacy), "Legacy or malformed identity must be resolved by server")
}
let monthly = PaywallAccessPresentation(hasPaidAccess: true,
    productIdentifier: ProPurchasePlan.monthly.productIdentifier, awaitingConfirmation: false)
check(monthly.action(for: .annual) == .purchase, "Monthly subscriber can purchase annual, not open cancellation management")
check(monthly.action(for: .monthly) == .none, "Monthly subscriber cannot buy the same current plan again")
check(monthly.action(for: .lifetime) == .purchase, "Monthly subscriber can select lifetime")
// Delayed server confirmation: same process, no app restart or second payment.
var confirmation = PurchaseConfirmationState.idle
confirmation.recordVerification(false)
check(confirmation == .awaiting, "First negative verification waits, not success")
let waiting = confirmation
confirmation.receivedInactiveSDKEntitlement()
check(confirmation == .awaiting, "Stale SDK data must not lose pending operation")
confirmation.recordVerification(nil)
check(confirmation == .awaiting, "Unavailable verifier cannot confirm a purchase")
check(!PurchaseConfirmationState.shouldDismiss(previous: waiting, current: confirmation), "Network failure keeps paywall open")
confirmation.recordVerification(true)
check(confirmation == .confirmed, "Late positive verification clears waiting")
check(PurchaseConfirmationState.shouldDismiss(previous: waiting, current: confirmation), "Late success closes paywall")
let confirmedAnnual = PaywallAccessPresentation(hasPaidAccess: true,
    productIdentifier: ProPurchasePlan.annual.productIdentifier, awaitingConfirmation: confirmation == .awaiting)
check(confirmedAnnual.statusKey == "paywall.status.annual", "Plan is visible immediately after delayed confirmation")
check(!PurchaseConfirmationState.shouldDismiss(previous: .idle, current: .idle), "Existing paid access alone cannot close paywall")
check(!PurchaseConfirmationState.shouldDismiss(previous: .confirmed, current: .confirmed), "Reopening paid paywall keeps it open")
check(!PurchaseConfirmationState.shouldDismiss(previous: .awaiting, current: .idle), "Revocation or reset is not purchase success")
confirmation.receivedInactiveSDKEntitlement()
check(confirmation == .idle, "Inactive entitlement clears previous completion, never grants access")
let recoveryNow = Date(timeIntervalSince1970: 1000)
for awaiting in [false, true] {
    for inFlight in [false, true] {
        for remaining in [nil, -1, 0, 1, 120] as [TimeInterval?] {
            let deadline = remaining.map { recoveryNow.addingTimeInterval($0) }
            check(PendingPurchaseRecovery.shouldRetry(awaiting: awaiting, inFlight: inFlight,
                deadline: deadline, now: recoveryNow) == (awaiting && !inFlight && (remaining ?? -1) > 0),
                "Automatic recovery is bounded, pending-only and never concurrent with purchase/restore")
        }
    }
}
print("PASS: \(checks) purchase catalog, identity, trial-policy, savings and paid presentation checks")
