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
print("PASS: \(checks) purchase catalog and trial-policy checks")
