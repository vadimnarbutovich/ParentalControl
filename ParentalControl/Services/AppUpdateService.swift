import Foundation
import Combine
import StoreKit
import UIKit

/// Foreground-only, optional discovery. No family state, database or background tasks.
@MainActor
final class AppUpdateService: ObservableObject {
    private struct Cache: Codable {
        let country: String
        let checkedAt: Date
        let product: AppUpdatePolicy.Product?
    }

    private let defaults: UserDefaults
    private let bundle: Bundle
    private var checking = false
    private let attemptKey = "appUpdate.lastAttempt"
    private let promptKey = "appUpdate.lastPrompt"
    private let cacheKey = "appUpdate.lookupCache"

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
    }

    func availableUpdate() async -> AppUpdatePolicy.Offer? {
        guard !checking, UIApplication.shared.applicationState == .active,
              AppUpdatePolicy.isDue(last: defaults.object(forKey: promptKey) as? Date, now: Date()),
              let installed = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let bundleID = bundle.bundleIdentifier,
              let appID = Int(AppStoreLinks.appID) else { return nil }
        // Use the same version check in App Store, TestFlight and development builds.
        checking = true
        defer { checking = false }

        guard let storefront = await Storefront.current,
              let country = AppUpdatePolicy.country(storefrontCode: storefront.countryCode),
              !Task.isCancelled, UIApplication.shared.applicationState == .active else { return nil }
        let now = Date()
        var cache = defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        if AppUpdatePolicy.isDue(last: defaults.object(forKey: attemptKey) as? Date, now: now) {
            // Persist before I/O, including failed/offline attempts, to avoid launch polling.
            defaults.set(now, forKey: attemptKey)
            defaults.removeObject(forKey: cacheKey)
            cache = nil
            var url = URLComponents(string: "https://itunes.apple.com/lookup")!
            url.queryItems = [URLQueryItem(name: "id", value: AppStoreLinks.appID),
                             URLQueryItem(name: "country", value: country),
                             URLQueryItem(name: "entity", value: "software")]
            guard let requestURL = url.url else { return nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let (data, response) = try await session.data(from: requestURL)
                guard !Task.isCancelled, let response = response as? HTTPURLResponse,
                      response.statusCode == 200, data.count < 1_000_000 else { return nil }
                let lookup = try JSONDecoder().decode(AppUpdatePolicy.Lookup.self, from: data)
                cache = Cache(country: country, checkedAt: now,
                              product: lookup.results.first { $0.trackId == appID && $0.bundleId == bundleID })
                if let cache, let encoded = try? JSONEncoder().encode(cache) { defaults.set(encoded, forKey: cacheKey) }
            } catch { return nil } // Offline/unknown must never interrupt normal app use.
        }
        guard !Task.isCancelled, let cache, cache.country == country,
              !AppUpdatePolicy.isDue(last: cache.checkedAt, now: Date()), let product = cache.product else { return nil }
        return AppUpdatePolicy.offer(product: product, appID: appID, bundleID: bundleID,
                                     installed: installed, systemVersion: UIDevice.current.systemVersion)
    }

    func didPresent() {
        defaults.set(Date(), forKey: promptKey)
    }
}
