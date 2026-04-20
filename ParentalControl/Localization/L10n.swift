import Foundation

enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: args)
    }

    static func plural(_ key: String, _ value: Int) -> String {
        String.localizedStringWithFormat(tr(key), value)
    }

    static func duration(seconds: Int) -> String {
        let normalized = max(0, seconds)
        if normalized < 60 {
            let format = tr("unit.seconds.short")
            if format == "unit.seconds.short" {
                return "\(normalized)s"
            }
            return String(format: format, locale: Locale.current, arguments: [normalized])
        }
        let minutes = normalized / 60
        let format = tr("unit.minutes.short")
        if format == "unit.minutes.short" {
            return "\(minutes)m"
        }
        return String(format: format, locale: Locale.current, arguments: [minutes])
    }
}
