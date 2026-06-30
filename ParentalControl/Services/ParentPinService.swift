import CryptoKit
import Foundation
import Security

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
}

/// Метаданные PIN, общие для child и parent. Хранятся в Keychain, шлются между устройствами
/// только в виде хэш+соль (исходный PIN не покидает устройство, где введён).
struct ParentPinMetadata: Equatable {
    let hash: Data
    let salt: Data
    let updatedAt: Date
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
        case hash = "parent_pin_hash"
        case salt = "parent_pin_salt"
        case updatedAt = "parent_pin_updated_at"
        case failedAttempts = "parent_pin_failed_attempts"
        case lockedUntil = "parent_pin_locked_until"
    }

    private let keychainService = "mycompny.parentalcontrol.parent_pin"
    private let iso8601 = ISO8601DateFormatter()

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
    func saveMetadata(_ metadata: ParentPinMetadata) {
        writeData(metadata.hash, for: .hash)
        writeData(metadata.salt, for: .salt)
        writeString(iso8601.string(from: metadata.updatedAt), for: .updatedAt)
        resetFailedAttempts()
    }

    /// Возвращает кэшированные метаданные, если PIN установлен. `nil` — PIN не сконфигурирован
    /// (либо родитель ещё не задал, либо удалил, либо ребёнок не получил ответ от backend).
    func loadMetadata() -> ParentPinMetadata? {
        guard
            let hash = readData(for: .hash),
            let salt = readData(for: .salt),
            let updatedAtString = readString(for: .updatedAt),
            let updatedAt = iso8601.date(from: updatedAtString)
        else {
            return nil
        }
        return ParentPinMetadata(hash: hash, salt: salt, updatedAt: updatedAt)
    }

    /// Полностью удаляет PIN из Keychain (хэш, соль, updatedAt, счётчики). Вызывается, когда
    /// родитель явно удалил PIN или когда устройство сменило роль/family.
    func clearMetadata() {
        for account in Account.allCases {
            deleteItem(account: account)
        }
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
        guard let metadata = loadMetadata() else {
            return .notConfigured
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
            writeString(String(nextAttempts), for: .failedAttempts)
            writeString(String(until.timeIntervalSinceReferenceDate), for: .lockedUntil)
            return .lockedOut(until: until)
        }
        writeString(String(nextAttempts), for: .failedAttempts)
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

    private func writeData(_ data: Data, for account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        // Доступ — только когда устройство разблокировано. PIN не должен быть прочитан при locked state.
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func writeString(_ string: String, for account: Account) {
        writeData(Data(string.utf8), for: account)
    }

    private func readData(for account: Account) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func readString(for account: Account) -> String? {
        guard let data = readData(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteItem(account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension ParentPinMetadata {
    /// Сериализация в base64 для отправки на backend. Backend хранит строкой, не зная PIN.
    var hashBase64: String { hash.base64EncodedString() }
    var saltBase64: String { salt.base64EncodedString() }

    /// Восстановление из строкового представления (от backend в snapshot).
    static func fromBackend(hashBase64: String, saltBase64: String, updatedAt: Date) -> ParentPinMetadata? {
        guard let hash = Data(base64Encoded: hashBase64),
              let salt = Data(base64Encoded: saltBase64) else {
            return nil
        }
        return ParentPinMetadata(hash: hash, salt: salt, updatedAt: updatedAt)
    }
}
