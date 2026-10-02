import Foundation

/// Статус задания в его жизненном цикле (разовое задание):
/// `pending` — создано родителем, ребёнок ещё не отправил отчёт;
/// `submitted` — ребёнок отправил фото-отчёт (через системное «Поделиться») и ждёт подтверждения;
/// `approved` — родитель подтвердил, время начислено (задание уходит в «выполненные»).
enum ChildTaskStatus: String, Codable, CaseIterable {
    case pending
    case submitted
    case approved
}

/// Задание для ребёнка, которое создаёт родитель. Family-сущность parent → child:
/// синхронизируется через `family_child_tasks` (action'ы `list/upsert/delete/submit/approve_child_task`)
/// по тому же образцу, что и `BlockSchedule`. Фото-отчёт у нас НЕ хранится — ребёнок отправляет
/// его родителю через системный share sheet (мессенджер), приложение лишь ведёт статус и награду.
struct ChildTask: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var details: String
    /// Награда за выполнение в секундах (в UI выбирается в минутах). Начисляется ребёнку
    /// при подтверждении через существующий механизм `add_earned_seconds`.
    var rewardSeconds: Int
    var status: ChildTaskStatus
    let createdAt: Date
    var updatedAt: Date
    var submittedAt: Date?
    var approvedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        rewardSeconds: Int,
        status: ChildTaskStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        submittedAt: Date? = nil,
        approvedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.rewardSeconds = rewardSeconds
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.submittedAt = submittedAt
        self.approvedAt = approvedAt
    }

    /// Награда в минутах (округление вниз) — для отображения и пикера.
    var rewardMinutes: Int { max(0, rewardSeconds / 60) }

    /// Активные (не подтверждённые) задания — отображаются как «текущие».
    var isActive: Bool { status != .approved }

    /// Маппинг DTO с бэкенда (`list_child_tasks`).
    init(remoteDTO: RemoteChildTaskDTO) {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func parse(_ s: String?) -> Date? {
            guard let s else { return nil }
            return isoFrac.date(from: s) ?? isoPlain.date(from: s)
        }
        let created = parse(remoteDTO.createdAtISO) ?? Date()
        self.init(
            id: remoteDTO.id,
            title: remoteDTO.title,
            details: remoteDTO.details ?? "",
            rewardSeconds: max(0, remoteDTO.rewardSeconds),
            status: ChildTaskStatus(rawValue: remoteDTO.status) ?? .pending,
            createdAt: created,
            updatedAt: parse(remoteDTO.updatedAtISO) ?? created,
            submittedAt: parse(remoteDTO.submittedAtISO),
            approvedAt: parse(remoteDTO.approvedAtISO)
        )
    }
}
