import SwiftUI

struct AppBackgroundView: View {
    var body: some View {
        ZStack {
            AppTheme.screenGradient
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    AppTheme.neonBlue.opacity(0.36),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 330
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    AppTheme.neonPurple.opacity(0.26),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 300
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    AppTheme.neonGreen.opacity(0.18),
                    .clear
                ],
                center: .center,
                startRadius: 30,
                endRadius: 420
            )
            .ignoresSafeArea()

            StaticStarsLayer()
                .ignoresSafeArea()
        }
    }
}

extension View {
    func appScreenBackground() -> some View {
        background(AppBackgroundView())
    }
}

private struct StaticStarsLayer: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                ForEach(0..<60, id: \.self) { i in
                    let x = size.width * pseudoRandom(i * 13 + 1)
                    let y = size.height * pseudoRandom(i * 29 + 7)
                    let r = 0.8 + pseudoRandom(i * 19 + 5) * 1.5
                    let alpha = 0.08 + pseudoRandom(i * 43 + 2) * 0.22
                    Circle()
                        .fill(starColor(for: i).opacity(alpha))
                        .frame(width: r, height: r)
                        .position(x: x, y: y)
                }
            }
            .drawingGroup()
        }
        .allowsHitTesting(false)
    }

    private func starColor(for index: Int) -> Color {
        switch index % 5 {
        case 0: return AppTheme.neonBlue
        case 1: return AppTheme.neonGreen
        case 2: return .white
        case 3: return AppTheme.neonPurple
        default: return AppTheme.neonOrange
        }
    }

    private func pseudoRandom(_ seed: Int) -> CGFloat {
        let value = sin(Double(seed) * 12.9898) * 43758.5453
        return CGFloat(value - floor(value))
    }
}
