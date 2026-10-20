import Foundation

nonisolated enum ScheduleControlStore {
    private static let generationKey = "parentalcontrol.scheduleFetchGeneration"
    struct Fetch: Sendable {
        let generation: String
        let pairing: Data
        func isCurrent(generation: String?, pairing: Data?, role: String?) -> Bool {
            self.generation == generation && self.pairing == pairing && role == "child"
        }
    }
    struct Snapshot: Equatable, Sendable {
        let schedules: Data
        let selection: Data?
        let pairing: Data?
        let role: String?
        let timeZone: String
    }

    static func transaction<T>(_ action: (UserDefaults) throws -> T) throws -> T {
        var result: Result<T, Error>?
        guard RemoteControlGate.withLock({
            result = Result {
                guard let defaults = RemoteControlGate.defaults else { throw ControlSystemWorker.Failure.busy }
                defaults.synchronize()
                return try action(defaults)
            }
        }), let result else { throw ControlSystemWorker.Failure.busy }
        return try result.get()
    }

    static func beginFetch() throws -> Fetch {
        try transaction { defaults in
            guard defaults.string(forKey: "parentalcontrol.deviceRole") == "child",
                  let pairing = defaults.data(forKey: "parentalcontrol.pairingState") else {
                throw ControlSystemWorker.Failure.stale
            }
            let generation = UUID().uuidString
            defaults.set(generation, forKey: generationKey)
            defaults.synchronize()
            return Fetch(generation: generation, pairing: pairing)
        }
    }

    static func commit(_ data: Data, fetch: Fetch) throws {
        let canonical = try ScheduleControlPlan.canonicalCache(data)
        try transaction { defaults in
            guard fetch.isCurrent(generation: defaults.string(forKey: generationKey),
                  pairing: defaults.data(forKey: "parentalcontrol.pairingState"),
                  role: defaults.string(forKey: "parentalcontrol.deviceRole")) else {
                throw ControlSystemWorker.Failure.stale
            }
            defaults.set(canonical, forKey: ScheduleControlPlan.cacheKey)
            defaults.synchronize()
        }
    }

    static func snapshot() throws -> Snapshot {
        try transaction { defaults in
            Snapshot(schedules: defaults.data(forKey: ScheduleControlPlan.cacheKey) ?? Data("[]".utf8),
                selection: defaults.data(forKey: "parentalcontrol.familySelection"),
                pairing: defaults.data(forKey: "parentalcontrol.pairingState"),
                role: defaults.string(forKey: "parentalcontrol.deviceRole"),
                timeZone: TimeZone.current.identifier)
        }
    }
}
