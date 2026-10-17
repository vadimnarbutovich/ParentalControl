import SwiftUI

/// Presentation-only components. Pairing, permission requests and PIN state live in the flow.
struct OnboardingPageLayout<Content: View, Footer: View>: View {
    let roleKey: String
    let roleSymbol: String
    let stepIndex: Int
    let stepCount: Int
    let titleKey: String
    let tint: Color
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: 0) {
                progressHeader
                ScrollView {
                    VStack(spacing: 20) {
                        Text(L10n.tr(titleKey))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        content()
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .id(stepIndex)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)

                footer()
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    .background(Color(red: 0.04, green: 0.07, blue: 0.14).opacity(0.96))
                    .overlay(alignment: .top) { Color.white.opacity(0.08).frame(height: 1) }
            }
        }
        .background(AppBackgroundView())
        .preferredColorScheme(.dark)
    }

    private var progressHeader: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Label(L10n.tr(roleKey), systemImage: roleSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(stepIndex + 1) / \(stepCount)")
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize()
            }
            HStack(spacing: 4) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index <= stepIndex ? tint : .white.opacity(0.12))
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

struct OnboardingFamilyIllustration: View {
    let tint: Color
    var compact = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var height: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 80 }
        return compact ? 160 : 210
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.18), .clear], center: .center,
                                     startRadius: 0, endRadius: height * 0.5))
                .frame(width: height * 1.4, height: height)
            Image("onboardingFamily")
                .resizable()
                .scaledToFit()
                .frame(width: height, height: height)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

}

struct OnboardingCard<Content: View>: View {
    var tint: Color = AppTheme.neonBlue
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .glassCard(cornerRadius: 24, glowColor: tint, drawsOuterShadows: false)
    }
}

struct OnboardingStatusLabel: View {
    let ready: Bool
    var body: some View {
        Label(L10n.tr(ready ? "setup.status.ready" : "setup.status.pending"),
              systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ready ? AppTheme.neonGreen : .white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background((ready ? AppTheme.neonGreen : .white).opacity(0.08), in: Capsule())
    }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
    var tint: Color = AppTheme.neonBlue
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(tint.opacity(configuration.isPressed ? 0.18 : 0.08),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.22), lineWidth: 1) }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct OnboardingQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.5 : 0.75))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}
