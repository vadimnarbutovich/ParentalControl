import SwiftUI

struct PermissionReminderBannerView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let kind = appState.activePermissionReminder {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.neonOrange)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(titleKey(for: kind))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        Text(bodyKey(for: kind))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                Button {
                    Task {
                        await appState.handlePermissionBannerAllow(kind: kind)
                    }
                } label: {
                    Text(LocalizedStringKey(appState.permissionBannerPrimaryButtonKey(for: kind)))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NeonPrimaryButtonStyle(tint: AppTheme.neonBlue))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.07, green: 0.11, blue: 0.22).opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppTheme.glassBorder.opacity(0.45), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func titleKey(for kind: PermissionReminderKind) -> LocalizedStringKey {
        switch kind {
        case .health:
            return "permission.banner.health.title"
        case .screenTime:
            return "permission.banner.screentime.title"
        case .notifications:
            return "permission.banner.notifications.title"
        case .liveActivities:
            return "permission.banner.liveactivity.title"
        }
    }

    private func bodyKey(for kind: PermissionReminderKind) -> LocalizedStringKey {
        switch kind {
        case .health:
            return "permission.banner.health.body"
        case .screenTime:
            return "permission.banner.screentime.body"
        case .notifications:
            return "permission.banner.notifications.body"
        case .liveActivities:
            return "permission.banner.liveactivity.body"
        }
    }
}
