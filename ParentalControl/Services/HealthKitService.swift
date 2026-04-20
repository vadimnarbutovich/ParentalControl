import Foundation
import HealthKit

protocol HealthKitProviding {
    func isAvailable() -> Bool
    /// Диалог уже был показан, но шаги не читаются — пользователь отозвал/не дал доступ; нужно открыть «Здоровье».
    func isStepReadLikelyDenied() async -> Bool
    /// Асинхронно: для read-доступа к шагам нельзя опираться только на `authorizationStatus` — комбинируем `getRequestStatusForAuthorization` и пробные запросы с реальными данными.
    func hasStepReadAccess() async -> Bool
    func requestAccess() async -> Bool
    func fetchTodaySteps() async throws -> Int
    func fetchSteps(from startDate: Date, to endDate: Date) async throws -> Int
}

final class HealthKitService: HealthKitProviding {
    private let store = HKHealthStore()

    func isAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func isStepReadLikelyDenied() async -> Bool {
        guard isAvailable(),
              let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return false
        }
        // Если диалог ещё ни разу не показывали — это не «отказ», а «не спрашивали».
        let read: Set<HKObjectType> = [stepType]
        let requestStatus = await fetchRequestStatus(toShare: [], read: read)
        if requestStatus == .shouldRequest {
            return false
        }
        // Диалог был показан, но данные не читаются → скорее всего отказ.
        return !(await hasStepReadAccess())
    }

    func hasStepReadAccess() async -> Bool {
        guard isAvailable(),
              let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return false
        }

        // 1) Если диалог ещё не показывали — доступа точно нет.
        let read: Set<HKObjectType> = [stepType]
        let requestStatus = await fetchRequestStatus(toShare: [], read: read)
        if requestStatus == .shouldRequest {
            return false
        }

        // 2) Диалог был показан. Apple скрывает статус read-доступа (privacy by design),
        //    поэтому единственный надёжный способ — проверить, возвращает ли запрос реальные данные.
        //    Запрашиваем шаги за последние 7 дней: если > 0 — доступ есть.
        //    Если 0 — с высочайшей вероятностью доступ отозван
        //    (устройство с активным пользователем записывает шаги каждый день).
        return await probeHasRealStepData(for: stepType)
    }

    func requestAccess() async -> Bool {
        guard isAvailable(),
              let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            store.requestAuthorization(toShare: [], read: [stepType]) { _, _ in
                Task {
                    let granted = await self.hasStepReadAccess()
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func fetchTodaySteps() async throws -> Int {
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: Date())
        return try await fetchSteps(from: startDate, to: Date())
    }

    func fetchSteps(from startDate: Date, to endDate: Date) async throws -> Int {
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            return 0
        }
        guard endDate > startDate else { return 0 }

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let steps = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: Int(steps))
            }

            store.execute(query)
        }
    }

    private func fetchRequestStatus(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async -> HKAuthorizationRequestStatus {
        await withCheckedContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: toShare, read: read) { status, _ in
                continuation.resume(returning: status)
            }
        }
    }

    /// Apple не позволяет узнать статус read-доступа напрямую (privacy by design):
    /// при отказе запросы просто возвращают пустые результаты без ошибок.
    /// Поэтому запрашиваем шаги за последние 7 дней — если сумма > 0, доступ есть.
    /// На реальном устройстве с активным пользователем шаги записываются ежедневно,
    /// поэтому 0 за неделю практически гарантированно означает отсутствие доступа.
    private func probeHasRealStepData(for stepType: HKQuantityType) async -> Bool {
        await withCheckedContinuation { continuation in
            let calendar = Calendar.current
            let end = Date()
            let start = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: end))!
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                let steps = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: steps > 0)
            }
            store.execute(query)
        }
    }
}
