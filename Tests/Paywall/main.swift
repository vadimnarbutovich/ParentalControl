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
print("PASS: \(checks) purchase catalog, trial-policy and savings checks")
