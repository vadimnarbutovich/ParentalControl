import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeConfiguration()
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        makeConfiguration()
    }

    private func makeConfiguration() -> ShieldConfiguration {
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
            primaryButtonBackgroundColor: .systemGreen,
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: NSLocalizedString("shield.ok", comment: ""),
                color: .white
            )
        )
    }
}
