import SwiftUI

private struct AppBackgroundCanvasKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}

extension EnvironmentValues {
    fileprivate var appBackgroundCanvas: CGRect? {
        get { self[AppBackgroundCanvasKey.self] }
        set { self[AppBackgroundCanvasKey.self] = newValue }
    }
}

/// Navigation stacks still own their backgrounds, but all sample the same
/// full-screen canvas. A pinned banner must not restart the gradient below it.
struct AppBackgroundContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let insets = proxy.safeAreaInsets
            let canvas = CGRect(x: frame.minX - insets.leading,
                                y: frame.minY - insets.top,
                                width: frame.width + insets.leading + insets.trailing,
                                height: frame.height + insets.top + insets.bottom)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppBackgroundView())
                .environment(\.appBackgroundCanvas, canvas)
        }
    }
}

struct AppBackgroundView: View {
    @Environment(\.appBackgroundCanvas) private var sharedCanvas

    var body: some View {
        GeometryReader { proxy in
            let localFrame = proxy.frame(in: .global)
            let canvas = sharedCanvas ?? localFrame
            artwork
                .frame(width: canvas.width, height: canvas.height)
                // Rasterize the full canvas before sampling it. On iOS 18,
                // clipped gradient layers otherwise leave a seam below the banner.
                .drawingGroup(opaque: true)
                .offset(x: canvas.minX - localFrame.minX,
                        y: canvas.minY - localFrame.minY)
        }
        // Clip the sampled artwork, not the screen's controls or scroll view.
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var artwork: some View {
        ZStack {
            AppTheme.screenGradient

            RadialGradient(
                colors: [
                    AppTheme.neonBlue.opacity(0.36),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 330
            )

            RadialGradient(
                colors: [
                    AppTheme.neonPurple.opacity(0.26),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 300
            )

            RadialGradient(
                colors: [
                    AppTheme.neonGreen.opacity(0.18),
                    .clear
                ],
                center: .center,
                startRadius: 30,
                endRadius: 420
            )

            StaticStarsLayer()
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
