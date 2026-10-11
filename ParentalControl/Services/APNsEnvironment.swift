import Foundation

/// Reports the signing environment, never inferred from DEBUG or the iOS version.
/// Unknown is supported by the server for legacy builds and missing receipts.
enum APNsEnvironment {
    static func current(bundle: Bundle = .main) -> String? {
        if let profileURL = bundle.url(forResource: "embedded", withExtension: "mobileprovision") {
            guard let profile = try? Data(contentsOf: profileURL),
                  let start = profile.range(of: Data("<plist".utf8)),
                  let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: profile.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil
                  ) as? [String: Any],
                  let entitlements = plist["Entitlements"] as? [String: Any],
                  let value = entitlements["aps-environment"] as? String else { return nil }
            switch value {
            case "development": return "sandbox"
            case "production": return "production"
            default: return nil
            }
        }
        // App Store/TestFlight may strip the provisioning profile. A store receipt
        // (including sandboxReceipt for TestFlight purchases) still means production APNs.
        if let receipt = bundle.appStoreReceiptURL, FileManager.default.fileExists(atPath: receipt.path) {
            return "production"
        }
        return nil
    }
}
