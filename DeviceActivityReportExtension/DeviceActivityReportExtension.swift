import _DeviceActivity_SwiftUI
import ExtensionFoundation
import ExtensionKit
import FamilyControls
import ManagedSettings
import SwiftUI

private let appGroupId = "group.mycompny.parentalcontrol"

@main
struct ParentalControlDeviceActivityReportExtension: DeviceActivityReportExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier("com.apple.deviceactivityui.report-extension")
    }

    var body: some DeviceActivityReportScene {
        ParentalControlDailyActivityReport { configuration in
            ParentalControlDailyActivityReportView(configuration: configuration)
        }
    }
}

private struct ParentalControlDailyActivityReport<Content: View>: DeviceActivityReportScene {
    typealias Configuration = ParentalControlDailyActivityConfiguration

    let context: DeviceActivityReport.Context = .parentalControlDailyActivity
    let content: (ParentalControlDailyActivityConfiguration) -> Content

    func makeConfiguration(
        representing data: DeviceActivityResults<DeviceActivityData>
    ) async -> ParentalControlDailyActivityConfiguration {
        let trackedTokens = loadTrackedApplicationTokens()
        let shouldFilterByTrackedTokens = !trackedTokens.isEmpty
        var usageByApp: [ParentalControlAppUsageKey: Int] = [:]

        for await activityData in data {
            for await segment in activityData.activitySegments {
                for await category in segment.categories {
                    for await app in category.applications {
                        let appName = app.application.localizedDisplayName ?? tr("report.app_usage.other")
                        let token = app.application.token
                        if shouldFilterByTrackedTokens {
                            guard let token, trackedTokens.contains(token) else {
                                continue
                            }
                        }
                        let seconds = Int(app.totalActivityDuration.rounded())
                        guard seconds > 0 else { continue }
                        let key = ParentalControlAppUsageKey(
                            name: appName,
                            token: token
                        )
                        usageByApp[key, default: 0] += seconds
                    }
                }
            }
        }

        let items = usageByApp
            .map {
                ParentalControlAppUsageItem(
                    name: $0.key.name,
                    token: $0.key.token,
                    durationSeconds: $0.value
                )
            }
            .sorted { lhs, rhs in
                if lhs.durationSeconds == rhs.durationSeconds {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.durationSeconds > rhs.durationSeconds
            }

        return ParentalControlDailyActivityConfiguration(
            totalDurationSeconds: items.reduce(0) { $0 + $1.durationSeconds },
            items: items
        )
    }

    @MainActor
    func _makeScene(with id: String) -> PrimitiveAppExtensionScene? {
        body._makeScene(with: id)
    }
}

private struct ParentalControlDailyActivityReportView: View {
    let configuration: ParentalControlDailyActivityConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(formatDuration(configuration.totalDurationSeconds))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                if configuration.items.isEmpty {
                    Text(tr("report.app_usage.empty"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(configuration.items.prefix(30)) { item in
                                HStack(spacing: 10) {
                                    if let token = item.token {
                                        appIdentityView(token: token, name: item.name)
                                    } else {
                                        Text(item.name)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(formatDuration(item.durationSeconds))
                                        .font(.subheadline.weight(.semibold))
                                        .monospacedDigit()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: TimeInterval(seconds)) ?? "0m"
    }

    private func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    @ViewBuilder
    private func appIdentityView(token: ApplicationToken, name: String) -> some View {
        HStack(spacing: 8) {
            Label(token)
                .labelStyle(.iconOnly)
                .frame(width: 20, height: 20)
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
        }
    }
}

private struct ParentalControlDailyActivityConfiguration {
    let totalDurationSeconds: Int
    let items: [ParentalControlAppUsageItem]
}

private struct ParentalControlAppUsageItem: Identifiable {
    let id = UUID()
    let name: String
    let token: ApplicationToken?
    let durationSeconds: Int
}

private struct ParentalControlAppUsageKey: Hashable {
    let name: String
    let token: ApplicationToken?
}

private extension DeviceActivityReport.Context {
    static let parentalControlDailyActivity = Self("parentalcontrol.daily-activity")
}

private func tr(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private func loadTrackedApplicationTokens() -> Set<ApplicationToken> {
    let selectionKey = "parentalcontrol.familySelection"
    guard let defaults = UserDefaults(suiteName: appGroupId),
          let data = defaults.data(forKey: selectionKey),
          let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
        return []
    }
    return selection.applicationTokens
}
