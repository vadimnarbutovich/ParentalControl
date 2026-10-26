import CryptoKit
import Foundation
import Security
import os

/// Результат проверки PIN на стороне ребёнка.
enum ParentPinEntryResult: Equatable {
    /// Хэш совпал — родительский режим можно открывать.
    case success
    /// Введён неверный PIN. `remainingAttempts` — сколько попыток осталось до lockout.
    case wrongPin(remainingAttempts: Int)
    /// Лимит неверных попыток исчерпан, lockout до `until`.
    case lockedOut(until: Date)
    /// PIN ещё не задан родителем (нет кэшированного хэша).
    case notConfigured
    case unavailable
}

/// Метаданные PIN, общие для child и parent. Хранятся в Keychain, шлются между устройствами
/// только в виде хэш+соль (исходный PIN не покидает устройство, где введён).
struct ParentPinMetadata: Equatable, Codable {
    let hash: Data
    let salt: Data
    let updatedAt: Date
}

enum ParentPinStorageState: Equatable {
    case available(ParentPinMetadata)
    case missing
    case unavailable
    case corrupted
}

enum ParentPinRecoveryPolicy {
    static func shouldAttempt(state: ParentPinStorageState, requiresRefresh: Bool,
                              lastAttempt: Date?, now: Date) -> Bool {
        if case .unavailable = state { return false }
        if case .available = state, !requiresRefresh { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < 300 { return false }
        return true
    }
}

/// Injectable boundary for regression tests; never logs data or PIN-derived values.
struct ParentPinKeychain {
    var read: (String) -> (OSStatus, Data?)
    var write: (String, Data) -> OSStatus
    var delete: (String) -> OSStatus

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "mycompny.parentalcontrol.parent_pin",
         kSecAttrAccount as String: account]
    }

    static let live = ParentPinKeychain(read: { account in
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }, write: { account, data in
        let query = query(account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var addition = query
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(addition as CFDictionary, nil)
        // A concurrent writer may have inserted the item. Never delete it.
        return added == errSecDuplicateItem
            ? SecItemUpdate(query as CFDictionary, update as CFDictionary) : added
    }, delete: { account in
        SecItemDelete(query(account) as CFDictionary)
    })
}

/// Сервис управления родительским PIN-кодом для входа в «родительский режим» на устройстве ребёнка.
///
/// Логика:
/// - Родитель в своих настройках задаёт PIN (4 цифры). Сервис генерит соль (16 случайных байт),
///   считает `SHA-256(pin || salt)` и хранит хэш+соль в Keychain локально + шлёт на backend.
/// - На устройстве ребёнка хэш+соль приезжают через `fetchParentSnapshot.parentPin` и кэшируются
///   в Keychain (`saveMetadata`). При вводе PIN ребёнком хэш считается локально и сравнивается с
///   кэшированным — PIN никогда не передаётся в сеть.
/// - Защита от подбора: после 5 неверных попыток вводится lockout 60 сек (`Self.lockoutDuration`).
///   Счётчик и время lockout тоже хранятся в Keychain, чтобы пережить рестарт приложения.
///
/// Все методы синхронные и потокобезопасные (`@MainActor` навешан в местах вызова из AppState).
final class ParentPinService {
    /// Сколько неверных попыток разрешено подряд до временной блокировки ввода.
    static let maxFailedAttempts = 5
    /// Длительность блокировки ввода после превышения лимита (секунд).
    static let lockoutDuration: TimeInterval = 60

    /// Account-ключи в Keychain — все под одним `service`-ом для удобства управления.
    private enum Account: String, CaseIterable {
        case record = "parent_pin_record_v1"
        case hash = "parent_pin_hash"
        case salt = "parent_pin_salt"
        case updatedAt = "parent_pin_updated_at"
        case failedAttempts = "parent_pin_failed_attempts"
        case lockedUntil = "parent_pin_locked_until"
    }

    private struct Record: Codable {
        let version: Int
        let metadata: ParentPinMetadata? // nil is a durable deletion, not a fallback to legacy keys.
    }
    private let keychain: ParentPinKeychain
    private let log = Logger(subsystem: "mycompny.ParentalControl", category: "ParentPIN")
    private let iso8601 = ISO8601DateFormatter()

    init(keychain: ParentPinKeychain = .live) { self.keychain = keychain }

    // MARK: - Hashing

    /// Хэширует PIN с заданной солью (SHA-256). Используется и при установке (родитель), и при
    /// проверке (ребёнок). PIN всегда нормализуется к utf8-байтам без обрезки whitespace —
    /// тот же набор символов должен попадать в хэш на любом устройстве.
    func hashPin(_ pin: String, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(pin.utf8))
        hasher.update(data: salt)
        return Data(hasher.finalize())
    }

    /// Генерирует криптографически случайную соль (16 байт). Используется при первой установке PIN.
    func generateSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        // SecRandomCopyBytes — корректный источник случайности на iOS. В случае сбоя
        // (что крайне маловероятно) откатываемся к `arc4random_buf` для надёжности.
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in 0..<bytes.count {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        return Data(bytes)
    }

    // MARK: - Metadata storage

    /// Сохраняет хэш+соль+updatedAt в Keychain. Перезаписывает предыдущие значения.
    /// Также сбрасывает счётчик неверных попыток (логично — PIN изменился, начинаем с чистого листа).
    @discardableResult
    func saveMetadata(_ metadata: ParentPinMetadata) -> Bool {
        guard metadata.hash.count == 32, metadata.salt.count == 16 else { return false }
        let previous = loadMetadata()
        guard writeRecord(metadata) else { return false }
        if previous != metadata { resetFailedAttempts() }
        return true
    }

    /// Возвращает кэшированные метаданные, если PIN установлен. `nil` — PIN не сконфигурирован
    /// (либо родитель ещё не задал, либо удалил, либо ребёнок не получил ответ от backend).
    func loadMetadata() -> ParentPinMetadata? {
        if case .available(let metadata) = storageState() { return metadata }
        return nil
    }

    func storageState() -> ParentPinStorageState {
        let (status, data) = keychain.read(Account.record.rawValue)
        if status == errSecSuccess {
            guard let data, let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.version == 1 else { return .corrupted }
            guard let metadata = record.metadata else { return .missing }
            guard metadata.hash.count == 32, metadata.salt.count == 16 else { return .corrupted }
            return .available(metadata)
        }
        guard status == errSecItemNotFound else {
            report("read", status)
            return .unavailable
        }
        // Migrate complete legacy records without removing them before a successful write.
        let legacy = [Account.hash, .salt, .updatedAt].map { keychain.read($0.rawValue) }
        if let error = legacy.first(where: { $0.0 != errSecSuccess && $0.0 != errSecItemNotFound }) {
            report("read_legacy", error.0)
            return .unavailable
        }
        if legacy.allSatisfy({ $0.0 == errSecItemNotFound }) { return .missing }
        guard let hash = legacy[0].1, hash.count == 32,
              let salt = legacy[1].1, salt.count == 16,
              let dateData = legacy[2].1, let dateString = String(data: dateData, encoding: .utf8),
              let date = iso8601.date(from: dateString) else { return .corrupted }
        let metadata = ParentPinMetadata(hash: hash, salt: salt, updatedAt: date)
        _ = writeRecord(metadata) // A failed migration leaves the valid legacy record usable.
        return .available(metadata)
    }

    private func writeRecord(_ metadata: ParentPinMetadata?) -> Bool {
        guard let data = try? JSONEncoder().encode(Record(version: 1, metadata: metadata)),
              writeData(data, for: .record) else { return false }
        for account in [Account.hash, .salt, .updatedAt] { deleteItem(account: account) }
        return true
    }

    /// Полностью удаляет PIN из Keychain (хэш, соль, updatedAt, счётчики). Вызывается, когда
    /// родитель явно удалил PIN или когда устройство сменило роль/family.
    @discardableResult
    func clearMetadata() -> Bool {
        guard writeRecord(nil) else { return false }
        resetFailedAttempts()
        return true
    }

    /// `true`, если в Keychain есть валидный хэш+соль (PIN можно проверить).
    func isPinConfigured() -> Bool {
        return loadMetadata() != nil
    }

    // MARK: - Verification (child side)

    /// Проверяет введённый ребёнком PIN. Учитывает lockout-таймер и счётчик неверных попыток.
    /// При успехе сбрасывает счётчик; при неудаче инкрементирует и при превышении лимита
    /// фиксирует `lockedUntil`.
    func verifyPin(_ pin: String) -> ParentPinEntryResult {
        let metadata: ParentPinMetadata
        switch storageState() {
        case .available(let value): metadata = value
        case .missing: return .notConfigured
        case .unavailable, .corrupted: return .unavailable
        }
        if let lockedUntil = currentLockoutEnd(), lockedUntil > Date() {
            return .lockedOut(until: lockedUntil)
        }
        let computedHash = hashPin(pin, salt: metadata.salt)
        // Сравнение через `constantTime` — на 4-значном PIN практически не важно, но привычка
        // полезная: не даём time-based side channel'ам подсказку «насколько близко угадали».
        if constantTimeEqual(computedHash, metadata.hash) {
            resetFailedAttempts()
            return .success
        }
        let nextAttempts = currentFailedAttempts() + 1
        if nextAttempts >= Self.maxFailedAttempts {
            let until = Date().addingTimeInterval(Self.lockoutDuration)
            guard writeString(String(nextAttempts), for: .failedAttempts),
                  writeString(String(until.timeIntervalSinceReferenceDate), for: .lockedUntil) else { return .unavailable }
            return .lockedOut(until: until)
        }
        guard writeString(String(nextAttempts), for: .failedAttempts) else { return .unavailable }
        return .wrongPin(remainingAttempts: Self.maxFailedAttempts - nextAttempts)
    }

    /// Текущий конец lockout-таймера, если он активен (в будущем). `nil` — lockout не задан
    /// или уже истёк (в этом случае автоматически чистим запись).
    func currentLockoutEnd() -> Date? {
        guard let stored = readString(for: .lockedUntil),
              let interval = TimeInterval(stored) else {
            return nil
        }
        let date = Date(timeIntervalSinceReferenceDate: interval)
        if date <= Date() {
            // Lockout истёк — чистим, чтобы не тянуть лишний state.
            deleteItem(account: .lockedUntil)
            return nil
        }
        return date
    }

    // MARK: - Internal helpers

    private func currentFailedAttempts() -> Int {
        guard let raw = readString(for: .failedAttempts), let value = Int(raw) else {
            return 0
        }
        return max(0, value)
    }

    private func resetFailedAttempts() {
        deleteItem(account: .failedAttempts)
        deleteItem(account: .lockedUntil)
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var result: UInt8 = 0
        for i in 0..<lhs.count {
            result |= lhs[i] ^ rhs[i]
        }
        return result == 0
    }

    // MARK: - Keychain CRUD

    @discardableResult
    private func writeData(_ data: Data, for account: Account) -> Bool {
        let status = keychain.write(account.rawValue, data)
        report("write", status)
        return status == errSecSuccess
    }

    @discardableResult
    private func writeString(_ string: String, for account: Account) -> Bool {
        writeData(Data(string.utf8), for: account)
    }

    private func readData(for account: Account) -> Data? {
        let (status, data) = keychain.read(account.rawValue)
        report("read", status)
        guard status == errSecSuccess else { return nil }
        return data
    }

    private func readString(for account: Account) -> String? {
        guard let data = readData(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteItem(account: Account) {
        report("delete", keychain.delete(account.rawValue))
    }

    private func report(_ operation: String, _ status: OSStatus) {
        guard status != errSecSuccess, status != errSecItemNotFound else { return }
        log.error("Keychain \(operation, privacy: .public) failed, status=\(status, privacy: .public)")
    }
}

extension ParentPinMetadata {
    /// Сериализация в base64 для отправки на backend. Backend хранит строкой, не зная PIN.
    var hashBase64: String { hash.base64EncodedString() }
    var saltBase64: String { salt.base64EncodedString() }

    /// Восстановление из строкового представления (от backend в snapshot).
    static func fromBackend(hashBase64: String, saltBase64: String, updatedAt: Date) -> ParentPinMetadata? {
        guard let hash = Data(base64Encoded: hashBase64),
              let salt = Data(base64Encoded: saltBase64), hash.count == 32, salt.count == 16 else {
            return nil
        }
        return ParentPinMetadata(hash: hash, salt: salt, updatedAt: updatedAt)
    }
}
