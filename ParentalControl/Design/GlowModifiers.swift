import SwiftUI

struct NeonGlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.24), radius: radius, x: 0, y: 0)
    }
}

extension View {
    func neonGlow(_ color: Color, radius: CGFloat = 18) -> some View {
        modifier(NeonGlowModifier(color: color, radius: radius))
    }
}
