import Foundation

nonisolated enum AppUpdatePolicy {
    static let interval: TimeInterval = 24 * 60 * 60

    struct Offer: Codable, Equatable, Identifiable {
        let version: String
        var id: String { version }
    }

    struct Lookup: Decodable {
        let results: [Product]
    }

    struct Product: Codable {
        let trackId: Int
        let bundleId: String
        let version: String
        let minimumOsVersion: String
    }

    /// Numeric marketing versions: 1.10 > 1.9, but 1.0 == 1.0.0.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        func parts(_ value: String) -> [Int]? {
            let segments = value.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(segments.count) else { return nil }
            let numbers = segments.compactMap { segment -> Int? in
                guard !segment.isEmpty, segment.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
                return Int(segment)
            }
            return numbers.count == segments.count ? numbers : nil
        }
        guard let left = parts(lhs), let right = parts(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func offer(product: Product, appID: Int, bundleID: String,
                      installed: String, systemVersion: String) -> Offer? {
        guard product.trackId == appID, product.bundleId == bundleID,
              compare(product.version, installed) == .orderedDescending,
              let compatibility = compare(product.minimumOsVersion, systemVersion),
              compatibility != .orderedDescending else { return nil }
        return Offer(version: product.version)
    }

    static func isDue(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now < last || now.timeIntervalSince(last) >= interval
    }

    /// StoreKit supplies ISO alpha-3; Apple's lookup requires alpha-2.
    /// Foundation canonicalizes known region aliases (USA -> US, BLR -> BY).
    static func country(storefrontCode: String) -> String? {
        let code = storefrontCode.uppercased()
        guard (2...3).contains(code.count), code.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        let region = Locale(identifier: "und_" + code).region?.identifier.uppercased()
        guard let region, region.count == 2,
              Locale.Region.isoRegions.contains(where: { $0.identifier == region }) else { return nil }
        return region
    }
}
