import Foundation

struct MinuteBalance: Codable, Equatable {
    var totalEarnedSeconds: Int
    var totalSpentSeconds: Int

    var availableSeconds: Int {
        max(0, totalEarnedSeconds - totalSpentSeconds)
    }

    var availableMinutes: Int {
        availableSeconds / 60
    }

    static let empty = MinuteBalance(totalEarnedSeconds: 0, totalSpentSeconds: 0)

    private enum CodingKeys: String, CodingKey {
        case totalEarnedSeconds
        case totalSpentSeconds
        case totalEarnedMinutes
        case totalSpentMinutes
    }

    init(totalEarnedSeconds: Int, totalSpentSeconds: Int) {
        self.totalEarnedSeconds = totalEarnedSeconds
        self.totalSpentSeconds = totalSpentSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let earnedSeconds = try container.decodeIfPresent(Int.self, forKey: .totalEarnedSeconds),
           let spentSeconds = try container.decodeIfPresent(Int.self, forKey: .totalSpentSeconds) {
            totalEarnedSeconds = earnedSeconds
            totalSpentSeconds = spentSeconds
            return
        }

        let earnedMinutes = try container.decodeIfPresent(Int.self, forKey: .totalEarnedMinutes) ?? 0
        let spentMinutes = try container.decodeIfPresent(Int.self, forKey: .totalSpentMinutes) ?? 0
        totalEarnedSeconds = max(0, earnedMinutes * 60)
        totalSpentSeconds = max(0, spentMinutes * 60)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalEarnedSeconds, forKey: .totalEarnedSeconds)
        try container.encode(totalSpentSeconds, forKey: .totalSpentSeconds)
    }
}

struct ConversionSettings: Codable, Equatable {
    var stepsPerMinute: Int
    var squatsPerMinute: Int
    var pushUpsPerMinute: Int

    static let `default` = ConversionSettings(
        stepsPerMinute: 100,
        squatsPerMinute: 5,
        pushUpsPerMinute: 5
    )

    private enum CodingKeys: String, CodingKey {
        case stepsPerMinute
        case squatsPerMinute
        case pushUpsPerMinute
        // Legacy field from previous versions.
        case repsPerMinute
    }

    init(stepsPerMinute: Int, squatsPerMinute: Int, pushUpsPerMinute: Int) {
        self.stepsPerMinute = max(1, stepsPerMinute)
        self.squatsPerMinute = max(1, squatsPerMinute)
        self.pushUpsPerMinute = max(1, pushUpsPerMinute)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSteps = try container.decodeIfPresent(Int.self, forKey: .stepsPerMinute) ?? Self.default.stepsPerMinute
        let legacyReps = try container.decodeIfPresent(Int.self, forKey: .repsPerMinute)
        let decodedSquats = try container.decodeIfPresent(Int.self, forKey: .squatsPerMinute) ?? legacyReps ?? Self.default.squatsPerMinute
        let decodedPushUps = try container.decodeIfPresent(Int.self, forKey: .pushUpsPerMinute) ?? legacyReps ?? Self.default.pushUpsPerMinute
        self.init(
            stepsPerMinute: decodedSteps,
            squatsPerMinute: decodedSquats,
            pushUpsPerMinute: decodedPushUps
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stepsPerMinute, forKey: .stepsPerMinute)
        try container.encode(squatsPerMinute, forKey: .squatsPerMinute)
        try container.encode(pushUpsPerMinute, forKey: .pushUpsPerMinute)
    }

    func repsPerMinute(for type: ExerciseType) -> Int {
        switch type {
        case .squat:
            return squatsPerMinute
        case .pushUp:
            return pushUpsPerMinute
        }
    }
}

enum ExerciseType: String, Codable, CaseIterable, Identifiable {
    case squat
    case pushUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .squat: L10n.tr("exercise.type.squat")
        case .pushUp: L10n.tr("exercise.type.pushup")
        }
    }
}

enum LedgerEntrySource: String, Codable {
    case steps
    case squat
    case pushUp
    case focusSession
    case testAdjustment
}

struct ActivityLedgerEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let source: LedgerEntrySource
    let deltaSeconds: Int
    let note: String
    let repetitionCount: Int?
    let focusDurationSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case source
        case deltaSeconds
        case deltaMinutes
        case note
        case repetitionCount
        case focusDurationSeconds
    }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        source: LedgerEntrySource,
        deltaSeconds: Int,
        note: String,
        repetitionCount: Int? = nil,
        focusDurationSeconds: Int? = nil
    ) {
        self.id = id
        self.date = date
        self.source = source
        self.deltaSeconds = deltaSeconds
        self.note = note
        self.repetitionCount = repetitionCount
        self.focusDurationSeconds = focusDurationSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        source = try container.decode(LedgerEntrySource.self, forKey: .source)
        note = try container.decode(String.self, forKey: .note)
        repetitionCount = try container.decodeIfPresent(Int.self, forKey: .repetitionCount)
        focusDurationSeconds = try container.decodeIfPresent(Int.self, forKey: .focusDurationSeconds)

        if let seconds = try container.decodeIfPresent(Int.self, forKey: .deltaSeconds) {
            deltaSeconds = seconds
        } else {
            let minutes = try container.decodeIfPresent(Int.self, forKey: .deltaMinutes) ?? 0
            deltaSeconds = minutes * 60
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(source, forKey: .source)
        try container.encode(deltaSeconds, forKey: .deltaSeconds)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(repetitionCount, forKey: .repetitionCount)
        try container.encodeIfPresent(focusDurationSeconds, forKey: .focusDurationSeconds)
    }
}

struct DailyStats: Equatable {
    let date: Date
    let steps: Int
    let earnedSeconds: Int
    let spentSeconds: Int
    let pushUps: Int
    let squats: Int
    let focusSessionTotalSeconds: Int
}

enum DeviceRole: String, Codable, CaseIterable, Identifiable {
    case parent
    case child

    var id: String { rawValue }
}

struct DevicePairingState: Codable, Equatable {
    let familyID: UUID
    let pairingCode: String
    let parentDeviceID: UUID?
    let childDeviceID: UUID?
    let linkedAt: Date

    var isLinked: Bool {
        parentDeviceID != nil && childDeviceID != nil
    }
}

enum RemoteFocusCommandType: String, Codable {
    case startFocus = "start_focus"
    case endFocus = "end_focus"
}

enum RemoteFocusCommandStatus: String, Codable {
    case queued
    case sent
    case delivered
    case applied
    case failed
}

struct RemoteFocusCommand: Codable, Equatable {
    let id: UUID
    let familyID: UUID
    let commandType: RemoteFocusCommandType
    let durationSeconds: Int?
    let status: RemoteFocusCommandStatus
    let createdAt: Date
    let updatedAt: Date
}

struct RemoteChildRuntimeState: Codable, Equatable {
    let isFocusActive: Bool
    let focusEndsAt: Date?
    let lastUpdatedAt: Date
}

struct ParentCommandDeliveryState: Equatable {
    let commandID: UUID
    let commandType: RemoteFocusCommandType
    let status: RemoteFocusCommandStatus
    let queuedAt: Date
    let updatedAt: Date
    let appliedAt: Date?
    let errorMessage: String?

    var latencySeconds: Int? {
        guard let appliedAt else { return nil }
        return max(0, Int(appliedAt.timeIntervalSince(queuedAt)))
    }
}

struct ParentLinkHealthState: Codable, Equatable {
    let pendingCommands: Int
    let oldestPendingAgeSeconds: Int?
    let childLastSeenAgeSeconds: Int?
    let childLikelyOnline: Bool
    let recentFailedCommands30m: Int
}
