import SwiftUI

/// Компактный бейдж подписки: корона (SF Symbol `crown.fill`) + «Pro» и перелив как у paywall CTA.
struct ProSubscriptionBadge: View {
    private var crownGold: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1, green: 0.92, blue: 0.45),
                Color(red: 0.96, green: 0.72, blue: 0.12),
                Color(red: 0.82, green: 0.52, blue: 0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "crown.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(crownGold)
                .shadow(color: Color(red: 1, green: 0.85, blue: 0.25).opacity(0.55), radius: 3, x: 0, y: 0)

            Text("dashboard.badge.pro")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.white,
                            Color.white.opacity(0.88)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.14, green: 0.11, blue: 0.08),
                                Color(red: 0.07, green: 0.06, blue: 0.11)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                ShimmeringLightSheen(opacity: 0.92)
            }
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 1, green: 0.82, blue: 0.32).opacity(0.6),
                                Color(red: 0.65, green: 0.45, blue: 0.12).opacity(0.4)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        )
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 3)
        .shadow(color: Color(red: 1, green: 0.75, blue: 0.2).opacity(0.12), radius: 10, x: 0, y: 0)
    }
}

#Preview {
    ZStack {
        Color(red: 0.05, green: 0.08, blue: 0.15).ignoresSafeArea()
        ProSubscriptionBadge()
    }
}
