import DeviceActivity
import ManagedSettings

// Шаблон для отдельного target `DeviceActivityMonitorExtension`.
// Файл не подключен к app target и нужен как основа для extension-таргета.
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private let store = ManagedSettingsStore()

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        // В extension здесь читаем selection из App Group и применяем shield.
        // Реальная логика будет выполнена после добавления extension target в Xcode.
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        store.clearAllSettings()
    }
}
