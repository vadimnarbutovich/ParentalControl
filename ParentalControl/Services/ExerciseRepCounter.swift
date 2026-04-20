import CoreGraphics
import Foundation

final class ExerciseRepCounter {
    private enum Phase {
        case up
        case down
    }

    private var phase: Phase = .up
    private(set) var reps = 0
    private var lastRepDate = Date.distantPast
    private let repCooldown: TimeInterval = 0.35
    private var downPhaseStartedAt = Date.distantPast
    private let minimumDownPhaseDuration: TimeInterval = 0.15
    private let minimumSquatDownPhaseDuration: TimeInterval = 0.22
    private var pushupAngleEMA: CGFloat?
    private var pushupMinAngleInDown: CGFloat = .greatestFiniteMagnitude
    private var squatAngleEMA: CGFloat?
    private var squatMinAngleInDown: CGFloat = .greatestFiniteMagnitude
    private var squatBaselineLocked = false
    private var squatUpStreak = 0

    func reset() {
        phase = .up
        reps = 0
        lastRepDate = .distantPast
        downPhaseStartedAt = .distantPast
        pushupAngleEMA = nil
        pushupMinAngleInDown = .greatestFiniteMagnitude
        squatAngleEMA = nil
        squatMinAngleInDown = .greatestFiniteMagnitude
        squatBaselineLocked = false
        squatUpStreak = 0
    }

    func process(joints: BodyJoints, type: ExerciseType) {
        switch type {
        case .squat:
            processSquat(joints: joints)
        case .pushUp:
            processPushUp(joints: joints)
        }
    }

    private func processSquat(joints: BodyJoints) {
        let left = angle(a: joints.leftHip, b: joints.leftKnee, c: joints.leftAnkle)
        let right = angle(a: joints.rightHip, b: joints.rightKnee, c: joints.rightAnkle)
        guard let left, let right else { return }
        guard abs(left - right) <= 45 else { return }

        let observedAngle = (left + right) / 2
        let avgAngle: CGFloat
        if let previous = squatAngleEMA {
            avgAngle = (previous * 0.7) + (observedAngle * 0.3)
        } else {
            avgAngle = observedAngle
        }
        squatAngleEMA = avgAngle

        // Avoid false counting while user is still finding camera position.
        if !squatBaselineLocked {
            if avgAngle > 160 {
                squatUpStreak = min(squatUpStreak + 1, 20)
            } else {
                squatUpStreak = 0
            }
            if squatUpStreak >= 4 {
                squatBaselineLocked = true
            }
            return
        }

        if phase == .up {
            if avgAngle < 125 {
                phase = .down
                downPhaseStartedAt = Date()
                squatMinAngleInDown = avgAngle
            }
            return
        }

        // phase == .down
        squatMinAngleInDown = min(squatMinAngleInDown, avgAngle)
        if avgAngle > 155 {
            guard Date().timeIntervalSince(downPhaseStartedAt) >= minimumSquatDownPhaseDuration else { return }
            guard squatMinAngleInDown < 130 else { return }
            registerRepIfNeeded()
        }
    }

    private func processPushUp(joints: BodyJoints) {
        let left = angle(a: joints.leftShoulder, b: joints.leftElbow, c: joints.leftWrist)
        let right = angle(a: joints.rightShoulder, b: joints.rightElbow, c: joints.rightWrist)
        guard let observedAngle = average(left, right) else { return }

        let avgAngle: CGFloat
        if let previous = pushupAngleEMA {
            avgAngle = (previous * 0.7) + (observedAngle * 0.3)
        } else {
            avgAngle = observedAngle
        }
        pushupAngleEMA = avgAngle

        if phase == .up && avgAngle < 110 {
            phase = .down
            downPhaseStartedAt = Date()
            pushupMinAngleInDown = avgAngle
        } else if phase == .down {
            pushupMinAngleInDown = min(pushupMinAngleInDown, avgAngle)
        }

        if phase == .down && avgAngle > 145 {
            guard Date().timeIntervalSince(downPhaseStartedAt) >= minimumDownPhaseDuration else { return }
            // Ignore shallow dips that come from small elbow jitter.
            guard pushupMinAngleInDown < 125 else { return }
            registerRepIfNeeded()
        }
    }

    private func registerRepIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastRepDate) >= repCooldown else { return }
        reps += 1
        phase = .up
        lastRepDate = now
        downPhaseStartedAt = .distantPast
        pushupMinAngleInDown = .greatestFiniteMagnitude
        squatMinAngleInDown = .greatestFiniteMagnitude
    }

    private func average(_ lhs: CGFloat?, _ rhs: CGFloat?) -> CGFloat? {
        switch (lhs, rhs) {
        case let (l?, r?): (l + r) / 2
        case let (l?, nil): l
        case let (nil, r?): r
        default: nil
        }
    }

    private func angle(a: CGPoint?, b: CGPoint?, c: CGPoint?) -> CGFloat? {
        guard let a, let b, let c else { return nil }
        let ab = CGVector(dx: a.x - b.x, dy: a.y - b.y)
        let cb = CGVector(dx: c.x - b.x, dy: c.y - b.y)

        let dot = (ab.dx * cb.dx) + (ab.dy * cb.dy)
        let magnitudes = hypot(ab.dx, ab.dy) * hypot(cb.dx, cb.dy)
        guard magnitudes > 0 else { return nil }

        let cosine = max(-1, min(1, dot / magnitudes))
        return acos(cosine) * 180 / .pi
    }
}
