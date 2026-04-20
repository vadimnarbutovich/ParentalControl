import SwiftUI

struct MinutesRingView<CenterContent: View>: View {
    let progress: CGFloat
    let lineWidth: CGFloat
    @ViewBuilder var centerContent: () -> CenterContent

    init(
        progress: CGFloat,
        lineWidth: CGFloat = 16,
        @ViewBuilder centerContent: @escaping () -> CenterContent
    ) {
        self.progress = min(max(progress, 0), 1)
        self.lineWidth = lineWidth
        self.centerContent = centerContent
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: lineWidth))

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            AppTheme.neonGreen,
                            AppTheme.neonBlue,
                            AppTheme.neonOrange,
                            AppTheme.neonGreen
                        ]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: progress)
                .shadow(color: AppTheme.neonGreen.opacity(0.22), radius: 6, x: 0, y: 0)

            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                .padding(lineWidth * 0.9)

            centerContent()
        }
    }
}
