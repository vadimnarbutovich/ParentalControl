import _DeviceActivity_SwiftUI
import ExtensionFoundation
import ExtensionKit
import FamilyControls
import ManagedSettings
import SwiftUI

@main
struct ParentalControlDeviceActivityReportExtension: DeviceActivityReportExtension {
    @available(iOS 26.2, *)
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
        // The host passes the complete selection in DeviceActivityFilter. Filtering
        // again by application tokens would discard apps from selected categories.
        var usageByApp: [ParentalControlAppUsageKey: TimeInterval] = [:]
        var usageByWebsite: [WebDomain: TimeInterval] = [:]

        for await activityData in data {
            for await segment in activityData.activitySegments {
                for await category in segment.categories {
                    for await app in category.applications {
                        let appName = app.application.localizedDisplayName ?? tr("report.app_usage.other")
                        let token = app.application.token
                        let seconds = app.totalActivityDuration
                        guard seconds > 0 else { continue }
                        let key = ParentalControlAppUsageKey(
                            name: appName,
                            token: token
                        )
                        usageByApp[key, default: 0] += seconds
                    }
                    for await website in category.webDomains {
                        guard website.totalActivityDuration > 0 else { continue }
                        usageByWebsite[website.webDomain, default: 0] += website.totalActivityDuration
                    }
                }
            }
        }

        let items = usageByApp
            .map {
                ParentalControlAppUsageItem(
                    name: $0.key.name,
                    token: $0.key.token,
                    durationSeconds: Int($0.value.rounded())
                )
            }
            .sorted { lhs, rhs in
                if lhs.durationSeconds == rhs.durationSeconds {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.durationSeconds > rhs.durationSeconds
            }

        return ParentalControlDailyActivityConfiguration(
            items: items,
            websites: usageByWebsite.map {
                ParentalControlWebsiteUsageItem(domain: $0.key, durationSeconds: Int($0.value.rounded()))
            }.sorted { $0.durationSeconds > $1.durationSeconds }
        )
    }

    @MainActor
    func _makeScene(with id: String) -> PrimitiveAppExtensionScene? {
        body._makeScene(with: id)
    }
}

private struct ParentalControlDailyActivityReportView: View {
    let configuration: ParentalControlDailyActivityConfiguration

    @State private var hasMoreBelow = false

    // Keep identical to AppTheme.usageReportBackground in the app target.
    private let reportBackground = Color(red: 0.05, green: 0.08, blue: 0.17)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if configuration.items.isEmpty && configuration.websites.isEmpty {
                Text(tr("report.app_usage.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(configuration.items) { item in
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
                        if !configuration.websites.isEmpty {
                            Text(tr("report.websites.title"))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, configuration.items.isEmpty ? 0 : 8)
                            ForEach(configuration.websites) { item in
                                HStack(spacing: 10) {
                                    if let token = item.domain.token {
                                        Label(token).labelStyle(.titleOnly)
                                            .font(.subheadline).lineLimit(1)
                                    } else {
                                        Text(item.domain.domain ?? tr("report.app_usage.other"))
                                            .font(.subheadline).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(formatDuration(item.durationSeconds))
                                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    // Render a continuous surface INSIDE the scroll content.
                    // contentShape alone did not make transparent gaps respond
                    // to drags in the remote DeviceActivityReport on device.
                    // Do not replace this with Color.clear or opacity(0).
                    .background(reportBackground)
                    .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    // Observe only this flag, not every scroll offset. The hint
                    // does not change the viewport or trigger report reloads.
                    geometry.contentSize.height > geometry.containerSize.height + 1 &&
                        geometry.visibleRect.maxY < geometry.contentSize.height - 1
                } action: { _, moreBelow in
                    hasMoreBelow = moreBelow
                }
                .overlay(alignment: .bottom) {
                    if hasMoreBelow {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 12)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Cover the WHOLE host placeholder, also for an empty or short result.
        // Applying this only to rows would leave the hint visible below them.
        .background(reportBackground)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute] : [.second])
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
    let items: [ParentalControlAppUsageItem]
    let websites: [ParentalControlWebsiteUsageItem]
}

private struct ParentalControlWebsiteUsageItem: Identifiable {
    var id: WebDomain { domain }
    let domain: WebDomain
    let durationSeconds: Int
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
