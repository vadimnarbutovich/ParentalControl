import SwiftUI
import UIKit

/// Конфетти по мотивам HabitsTracker (`StreakCelebrationPopupView`), без share/UI карточки.
struct CelebrationConfettiView: UIViewRepresentable {
    let trigger: Int

    func makeUIView(context: Context) -> CelebrationConfettiUIView {
        CelebrationConfettiUIView()
    }

    func updateUIView(_ uiView: CelebrationConfettiUIView, context: Context) {
        uiView.fire(trigger: trigger)
    }
}

final class CelebrationConfettiUIView: UIView {
    private let emitter = CAEmitterLayer()
    private var lastTrigger = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(emitter)
        configureEmitter()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY - 10)
        emitter.emitterSize = CGSize(width: 8, height: 8)
    }

    func fire(trigger: Int) {
        guard trigger != lastTrigger else { return }
        lastTrigger = trigger

        emitter.beginTime = CACurrentMediaTime()
        emitter.birthRate = 1
        emitter.setValue(185, forKeyPath: "emitterCells.confetti.birthRate")
        emitter.setValue(150, forKeyPath: "emitterCells.circle.birthRate")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self else { return }
            self.emitter.setValue(0, forKeyPath: "emitterCells.confetti.birthRate")
            self.emitter.setValue(0, forKeyPath: "emitterCells.circle.birthRate")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
            guard let self else { return }
            self.emitter.setValue(60, forKeyPath: "emitterCells.confetti.birthRate")
            self.emitter.setValue(46, forKeyPath: "emitterCells.circle.birthRate")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.32) { [weak self] in
            self?.emitter.setValue(0, forKeyPath: "emitterCells.confetti.birthRate")
            self?.emitter.setValue(0, forKeyPath: "emitterCells.circle.birthRate")
        }
    }

    private func configureEmitter() {
        emitter.emitterShape = .point
        emitter.emitterMode = .surface
        emitter.renderMode = .unordered
        emitter.birthRate = 0

        let colors: [UIColor] = [
            .systemYellow, .systemPink, .systemBlue,
            .systemGreen, .systemOrange, .systemPurple,
            .white
        ]

        let confetti = CAEmitterCell()
        confetti.name = "confetti"
        confetti.contents = ConfettiImageFactory.rectanglePiece().cgImage
        confetti.birthRate = 0
        confetti.lifetime = 5.4
        confetti.lifetimeRange = 1.3
        confetti.velocity = 350
        confetti.velocityRange = 120
        confetti.emissionRange = .pi * 2
        confetti.spin = 2.8
        confetti.spinRange = 2.6
        confetti.scale = 0.16
        confetti.scaleRange = 0.08
        confetti.yAcceleration = 75
        confetti.color = UIColor.white.cgColor
        confetti.redRange = 1
        confetti.greenRange = 1
        confetti.blueRange = 1

        let circle = CAEmitterCell()
        circle.name = "circle"
        circle.contents = ConfettiImageFactory.circlePiece().cgImage
        circle.birthRate = 0
        circle.lifetime = 5.0
        circle.lifetimeRange = 1.4
        circle.velocity = 320
        circle.velocityRange = 110
        circle.emissionRange = .pi * 2
        circle.spin = 2.2
        circle.spinRange = 2.2
        circle.scale = 0.18
        circle.scaleRange = 0.09
        circle.yAcceleration = 70

        emitter.emitterCells = [confetti, circle]

        emitter.setValue(colors.randomElement()?.cgColor, forKeyPath: "emitterCells.confetti.color")
        emitter.setValue(colors.randomElement()?.cgColor, forKeyPath: "emitterCells.circle.color")
    }
}

private enum ConfettiImageFactory {
    static func rectanglePiece() -> UIImage {
        let size = CGSize(width: 22, height: 12)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: 2).addClip()
            UIColor.white.setFill()
            ctx.fill(rect)
        }
    }

    static func circlePiece() -> UIImage {
        let size = CGSize(width: 14, height: 14)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: rect)
        }
    }
}
