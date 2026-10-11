import SwiftUI

struct ActionSlideButton: View {
    let isOn: Bool
    let inactiveTitle: LocalizedStringKey
    let activeTitle: LocalizedStringKey
    var inactiveSymbol = "pause.fill"
    var activeSymbol = "play.fill"
    var activeTint = AppTheme.neonGreen
    var isEnabled = true
    var overrideTitle: LocalizedStringKey?
    let onActivate: () -> Void
    let onDeactivate: () -> Void

    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging = false
    @State private var hintOffset: CGFloat = 0
    @State private var hintLoopTask: Task<Void, Never>?

    private let trackHeight: CGFloat = 68
    private let knobSize: CGFloat = 56
    private let horizontalPadding: CGFloat = 6
    private let hintNudge: CGFloat = 10
    @State private var dragBaseOffset: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let maxOffset = max(0, proxy.size.width - knobSize - (horizontalPadding * 2))
            let restingOffset = isOn ? maxOffset : 0
            let liveOffset = min(max(restingOffset + dragTranslation, 0), maxOffset)
            let iconColor = isEnabled ? (isOn ? activeTint : AppTheme.neonBlue) : .gray

            // Капсула + круг: дуга левого края дорожки и окружность ручки имеют общий центр (геометрия «slide»).
            // Одно число cornerRadius у прямоугольника 56×56 и полосы 68 не даёт совпадающих дуг.
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .frame(width: proxy.size.width, height: trackHeight)

                Text(overrideTitle ?? (isOn ? activeTitle : inactiveTitle))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, knobSize + 18)

                Circle()
                    .fill(iconColor)
                    .frame(width: knobSize, height: knobSize)
                    .overlay(
                        Image(systemName: isOn ? activeSymbol : inactiveSymbol)
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: iconColor.opacity(0.35), radius: 8, x: 0, y: 0)
                    .offset(x: liveOffset + horizontalPadding + hintOffset)
            }
            .frame(width: proxy.size.width, height: trackHeight)
            .contentShape(Rectangle())
            .onAppear { restartHintLoopIfNeeded() }
            .onDisappear { stopHintLoop(resetOffset: true) }
            .onChange(of: isOn) { _, _ in
                resetDrag()
                restartHintLoopIfNeeded()
            }
            .onChange(of: isDragging) { _, dragging in
                if dragging {
                    stopHintLoop(resetOffset: true)
                } else {
                    restartHintLoopIfNeeded()
                }
            }
            .onChange(of: isEnabled) { _, _ in
                resetDrag()
                restartHintLoopIfNeeded()
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard isEnabled else { return }
                        if !isDragging {
                            isDragging = true
                        }
                        if dragBaseOffset == nil {
                            dragBaseOffset = restingOffset
                        }
                        dragTranslation = value.translation.width
                    }
                    .onEnded { value in
                        guard isEnabled else { resetDrag(); return }
                        let baseOffset = dragBaseOffset ?? restingOffset
                        let finalOffset = min(max(baseOffset + value.translation.width, 0), maxOffset)
                        let shouldActivate = !isOn && finalOffset > maxOffset * 0.78
                        let shouldDeactivate = isOn && finalOffset < maxOffset * 0.22

                        // Reset visual drag first to avoid jump when state flips.
                        dragTranslation = 0
                        dragBaseOffset = nil

                        if shouldActivate {
                            onActivate()
                        } else if shouldDeactivate {
                            onDeactivate()
                        }
                        isDragging = false
                    }
            )
        }
        .frame(height: trackHeight)
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(overrideTitle ?? (isOn ? activeTitle : inactiveTitle)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard isEnabled else { return }
            if isOn { onDeactivate() } else { onActivate() }
        }
    }

    private func resetDrag() {
        dragTranslation = 0
        dragBaseOffset = nil
        isDragging = false
    }

    private func restartHintLoopIfNeeded() {
        stopHintLoop(resetOffset: true)
        guard isEnabled, !isDragging else {
            if hintOffset != 0 {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { hintOffset = 0 }
            }
            return
        }
        let direction: CGFloat = isOn ? -1 : 1
        hintLoopTask = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 1.05)) {
                    hintOffset = direction * hintNudge
                }
                try? await Task.sleep(nanoseconds: 1_050_000_000)
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 1.05)) {
                    hintOffset = 0
                }
                try? await Task.sleep(nanoseconds: 1_050_000_000)
            }
        }
    }

    private func stopHintLoop(resetOffset: Bool) {
        hintLoopTask?.cancel()
        hintLoopTask = nil
        guard resetOffset, hintOffset != 0 else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { hintOffset = 0 }
    }
}
