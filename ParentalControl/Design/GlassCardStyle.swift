import SwiftUI

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    var glowColor: Color? = nil
    var borderOpacity: Double = 0.30

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.09, green: 0.13, blue: 0.24).opacity(0.98),
                                Color(red: 0.05, green: 0.08, blue: 0.17).opacity(0.97),
                                Color(red: 0.03, green: 0.05, blue: 0.12).opacity(0.98)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 7)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.11),
                                        Color.white.opacity(0.04),
                                        .clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(cardLightAccents(cornerRadius: cornerRadius, glowColor: glowColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(AppTheme.glassBorder.opacity(borderOpacity), lineWidth: 1)
                    )
            )
            .ifLet(glowColor) { view, color in
                view
                    .shadow(color: color.opacity(0.26), radius: 14, x: 0, y: 0)
                    .shadow(color: color.opacity(0.16), radius: 24, x: 0, y: 0)
            }
    }
}

struct NeonPrimaryButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.neonGreen
    /// Зацикленная «полоска света» слева направо (например paywall CTA).
    var shimmeringSheen: Bool = false
    /// Меньше шрифт и вертикальные отступы (вторичные CTA).
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(
                compact
                    ? .system(size: 16, weight: .semibold, design: .rounded)
                    : .headline.weight(.semibold)
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 10 : 14)
            .foregroundStyle(.black.opacity(configuration.isPressed ? 0.8 : 0.95))
            .background(
                NeonPrimaryButtonBackground(
                    tint: tint,
                    isPressed: configuration.isPressed,
                    shimmeringSheen: shimmeringSheen
                )
            )
            .shadow(color: tint.opacity(0.24), radius: 6, x: 0, y: 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// Полоска света слева направо — та же логика, что у paywall CTA (`NeonPrimaryButtonStyle.shimmeringSheen`).
struct ShimmeringLightSheen: View {
    var opacity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { context in
            GeometryReader { geo in
                Self.shimmerBand(width: geo.size.width, height: geo.size.height, date: context.date)
            }
        }
        .blendMode(.screen)
        .opacity(opacity)
    }

    static func shimmerBand(width w: CGFloat, height h: CGFloat, date: Date) -> some View {
        let cycle: Double = 2.75
        let p = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
        let bandW = max(w * 0.45, 76)
        return Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(0.18),
                        Color.white.opacity(0.82),
                        Color(red: 1, green: 0.96, blue: 0.62).opacity(0.65),
                        Color.white.opacity(0.72),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: bandW, height: h * 2.6)
            .rotationEffect(.degrees(-22))
            .offset(x: -bandW * 0.9 + p * (w + bandW * 1.45), y: 0)
    }
}

private struct NeonPrimaryButtonBackground: View {
    let tint: Color
    let isPressed: Bool
    let shimmeringSheen: Bool
    private let corner: CGFloat = 14

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(tint.opacity(isPressed ? 0.86 : 1))
            if shimmeringSheen {
                ShimmeringLightSheen(opacity: isPressed ? 0.55 : 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct NeonChipButtonStyle: ButtonStyle {
    var isActive: Bool
    var tint: Color = AppTheme.neonGreen
    /// `true` — как сегмент в `HStack` на всю ширину. `false` — ширина по контенту (горизонтальный скролл).
    var fillHorizontally: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .modifier(ChipHorizontalSizing(fillHorizontally: fillHorizontally))
            .padding(.vertical, 14)
            .foregroundStyle(isActive ? Color.black : .white)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isActive ? tint : Color.white.opacity(configuration.isPressed ? 0.15 : 0.08))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct ChipHorizontalSizing: ViewModifier {
    let fillHorizontally: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if fillHorizontally {
            content.frame(maxWidth: .infinity)
        } else {
            content.padding(.horizontal, 16)
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 24, glowColor: Color? = nil) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, glowColor: glowColor))
    }
}

private func cardLightAccents(cornerRadius: CGFloat, glowColor: Color?) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.26),
                        Color.white.opacity(0.05),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )

        if let glowColor {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            glowColor.opacity(0.28),
                            .clear,
                            glowColor.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
