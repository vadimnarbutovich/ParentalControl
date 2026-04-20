import ManagedSettings
import ManagedSettingsUI
import SwiftUI

// Шаблон для отдельного target `ShieldConfigurationExtension`.
// Нужен для кастомного экрана блокировки.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .dark,
            backgroundColor: UIColor.black.withAlphaComponent(0.85),
            icon: nil,
            title: ShieldConfiguration.Label(
                text: NSLocalizedString("shield.title", comment: ""),
                color: .white
            ),
            subtitle: ShieldConfiguration.Label(
                text: NSLocalizedString("shield.subtitle", comment: ""),
                color: .lightGray
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: NSLocalizedString("shield.open.button", comment: ""),
                color: .black
            ),
            primaryButtonBackgroundColor: .systemGreen
        )
    }
}
