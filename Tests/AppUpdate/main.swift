import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label); checks += 1
}
for (a, b, expected): (String, String, ComparisonResult) in [
    ("1.10", "1.9", .orderedDescending), ("1.0", "1.0.0", .orderedSame),
    ("2", "1.99.99", .orderedDescending), ("1.0.9", "1.1", .orderedAscending),
    ("1.0.0.1", "1.0", .orderedDescending), ("01.02", "1.2", .orderedSame)
] { check(AppUpdatePolicy.compare(a, b) == expected, "Numeric version comparison \(a)/\(b)") }
for malformed in ["", "1..2", "v1.2", "1.2-beta", " 1.2", "1.", "-1", "١.٢", "1.2.3.4.5", String(repeating: "9", count: 30)] {
    check(AppUpdatePolicy.compare(malformed, "1.0") == nil, "Malformed version ignored")
}
func offer(version: String = "1.1", minimum: String = "18.0", id: Int = 6820971713,
           bundle: String = "mycompny.ParentalControl", installed: String = "1.0", system: String = "18.0") -> AppUpdatePolicy.Offer? {
    AppUpdatePolicy.offer(product: .init(trackId: id, bundleId: bundle, version: version, minimumOsVersion: minimum),
                          appID: 6820971713, bundleID: "mycompny.ParentalControl", installed: installed, systemVersion: system)
}
check(offer()?.version == "1.1", "New compatible public version can be offered")
check(offer(version: "1.0") == nil, "No prompt for current version")
check(offer(version: "0.9") == nil, "Never suggest downgrade")
check(offer(installed: "2.0") == nil, "Newer installed marketing version stays untouched")
check(offer(minimum: "18.1") == nil, "Update unavailable on this iOS stays hidden")
check(offer(minimum: "27.0", system: "27.0.1") != nil, "Patch-level system compatibility")
check(offer(id: 1) == nil && offer(bundle: "other.app") == nil, "Identity mismatch rejected")
check(offer(minimum: "unknown") == nil && offer(version: "unknown") == nil, "Unknown compatibility/version ignored")
let now = Date(timeIntervalSince1970: 1_800_000_000)
check(AppUpdatePolicy.isDue(last: nil, now: now), "First foreground check allowed")
check(!AppUpdatePolicy.isDue(last: now, now: now), "Concurrent/repeated openings suppressed")
check(!AppUpdatePolicy.isDue(last: now.addingTimeInterval(-86399), now: now), "Daily throttling persists until full interval")
check(AppUpdatePolicy.isDue(last: now.addingTimeInterval(-86400), now: now), "Next daily check allowed")
check(AppUpdatePolicy.isDue(last: now.addingTimeInterval(3600), now: now), "Clock correction cannot suppress indefinitely")
for (source, expected) in [("USA", "US"), ("BLR", "BY"), ("GBR", "GB"), ("DEU", "DE"), ("UKR", "UA"), ("us", "US"), ("RUS", "RU")] {
    check(AppUpdatePolicy.country(storefrontCode: source) == expected, "Storefront \(source) converted to lookup region")
}
for unknown in ["", "ZZZ", "US?", "123", "../../us"] {
    check(AppUpdatePolicy.country(storefrontCode: unknown) == nil, "Unknown storefront must not fall back to US")
}
let empty = try JSONDecoder().decode(AppUpdatePolicy.Lookup.self, from: Data(#"{"results":[]}"#.utf8))
check(empty.results.isEmpty, "Unavailable in storefront is a valid empty lookup")
print("Passed \(checks) App Store update policy checks")
