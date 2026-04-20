import AVFoundation
import Combine
import Foundation
import ImageIO
import SwiftUI

@MainActor
final class ExerciseSessionViewModel: ObservableObject {
    @Published private(set) var selectedType: ExerciseType
    @Published private(set) var currentReps = 0
    @Published private(set) var isRunning = false
    @Published private(set) var poseDetected = false
    @Published private(set) var guidanceTextKey = "exercise.guidance.showYourself"
    @Published private(set) var guidanceColor: Color = .red
    @Published private(set) var isReadyForCounting = false
    #if DEBUG && !HIDE_DEBUG_UI
    @Published private(set) var debugHintText = ""
    @Published private(set) var debugDistanceText = "Дистанция: --"
    @Published private(set) var debugDistanceOK = false
    @Published private(set) var debugDownText = "Опускание: --"
    @Published private(set) var debugDownOK = false
    @Published private(set) var debugUpText = "Подъем: --"
    @Published private(set) var debugUpOK = false
    #endif

    var cameraSession: AVCaptureSession { cameraService.session }

    private let cameraService = CameraCaptureService()
    private let poseService = PoseDetectionService()
    private let counter = ExerciseRepCounter()
    private var stableReady = false
    private var readyStreak = 0
    private var notReadyStreak = 0
    private var missingPoseStreak = 0
    private var distanceSignalStable = false
    private var distanceSignalGoodStreak = 0
    private var distanceSignalBadStreak = 0
    private var guidanceDistanceStable = false
    private var guidanceDistanceGoodStreak = 0
    private var guidanceDistanceBadStreak = 0
    private var lastBodyScale: CGFloat?
    private var repositionHoldFrames = 0

    init(selectedType: ExerciseType) {
        self.selectedType = selectedType
    }

    func requestCameraAccess() async -> Bool {
        await cameraService.requestPermission()
    }

    func prepareIfNeeded() async {
        _ = await cameraService.requestPermission()
        cameraService.sampleBufferHandler = { [weak self] sampleBuffer, orientation in
            self?.processFrame(sampleBuffer, orientation: orientation)
        }
    }

    func toggleSession() {
        isRunning ? stopSession() : startSession()
    }

    func startSessionIfNeeded() {
        guard !isRunning else { return }
        startSession()
    }

    func startSession() {
        counter.reset()
        currentReps = 0
        guidanceTextKey = "exercise.guidance.showYourself"
        guidanceColor = .red
        isReadyForCounting = false
        stableReady = false
        readyStreak = 0
        notReadyStreak = 0
        missingPoseStreak = 0
        distanceSignalStable = false
        distanceSignalGoodStreak = 0
        distanceSignalBadStreak = 0
        guidanceDistanceStable = false
        guidanceDistanceGoodStreak = 0
        guidanceDistanceBadStreak = 0
        lastBodyScale = nil
        repositionHoldFrames = 0
        resetDebugSignals()
        isRunning = true
        cameraService.start()
    }

    func stopSession() {
        isRunning = false
        poseDetected = false
        isReadyForCounting = false
        stableReady = false
        readyStreak = 0
        notReadyStreak = 0
        missingPoseStreak = 0
        distanceSignalStable = false
        distanceSignalGoodStreak = 0
        distanceSignalBadStreak = 0
        guidanceDistanceStable = false
        guidanceDistanceGoodStreak = 0
        guidanceDistanceBadStreak = 0
        lastBodyScale = nil
        repositionHoldFrames = 0
        resetDebugSignals()
        cameraService.stop()
    }

    func resetCounter() {
        counter.reset()
        currentReps = 0
        poseDetected = false
        guidanceTextKey = "exercise.guidance.showYourself"
        guidanceColor = .red
        isReadyForCounting = false
        stableReady = false
        readyStreak = 0
        notReadyStreak = 0
        missingPoseStreak = 0
        distanceSignalStable = false
        distanceSignalGoodStreak = 0
        distanceSignalBadStreak = 0
        guidanceDistanceStable = false
        guidanceDistanceGoodStreak = 0
        guidanceDistanceBadStreak = 0
        lastBodyScale = nil
        repositionHoldFrames = 0
        resetDebugSignals()
    }

    func earnedSeconds(settings: ConversionSettings) -> Int {
        let repsPerMinute = settings.repsPerMinute(for: selectedType)
        guard repsPerMinute > 0 else { return 0 }
        return (currentReps * 60) / repsPerMinute
    }

    private func processFrame(
        _ sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation
    ) {
        guard isRunning else { return }
        guard let joints = poseService.detectJoints(from: sampleBuffer, orientation: orientation) else {
            missingPoseStreak = min(missingPoseStreak + 1, 300)
            if stableReady && missingPoseStreak < 40 {
                Task { @MainActor [weak self] in
                    self?.poseDetected = false
                    self?.isReadyForCounting = true
                    self?.guidanceTextKey = "exercise.guidance.ready"
                    self?.guidanceColor = .green
                    #if DEBUG && !HIDE_DEBUG_UI
                    self?.debugHintText = "hold_ready | miss:\(self?.missingPoseStreak ?? 0)"
                    self?.debugDistanceOK = true
                    #endif
                }
                return
            }
            stableReady = false
            readyStreak = 0
            notReadyStreak = 0
            Task { @MainActor [weak self] in
                self?.poseDetected = false
                self?.isReadyForCounting = false
                self?.guidanceTextKey = "exercise.guidance.showYourself"
                self?.guidanceColor = .red
                #if DEBUG && !HIDE_DEBUG_UI
                self?.debugHintText = "no_pose"
                self?.resetDebugSignals()
                #endif
            }
            return
        }
        missingPoseStreak = 0
        let indicators = indicators(for: joints, type: selectedType)
        let readiness = readinessStatus(for: joints, type: selectedType)
        let motionStable = updateMotionStability(joints: joints, type: selectedType)
        if readiness.isReady {
            readyStreak = min(readyStreak + 1, 120)
            notReadyStreak = 0
        } else {
            notReadyStreak = min(notReadyStreak + 1, 120)
            readyStreak = 0
        }

        if !stableReady && readyStreak >= 2 {
            stableReady = true
        } else if stableReady && notReadyStreak >= 35 {
            stableReady = false
        }

        if stableReady && motionStable {
            counter.process(joints: joints, type: selectedType)
        }
        let reps = counter.reps
        #if DEBUG && !HIDE_DEBUG_UI
        let mode = selectedType == .squat ? "SQ" : "PU"
        let liveDebug =
            "\(mode) | raw:\(readiness.isReady ? 1 : 0) stable:\(stableReady ? 1 : 0) r:\(readyStreak) nr:\(notReadyStreak) miss:\(missingPoseStreak) | \(readiness.debug)"
        #endif
        Task { @MainActor [weak self] in
            self?.poseDetected = true
            self?.currentReps = reps
            self?.isReadyForCounting = self?.stableReady ?? false
            if self?.stableReady ?? false {
                if indicators.guidanceDistanceOK {
                    self?.guidanceTextKey = "exercise.guidance.ready"
                    self?.guidanceColor = .green
                } else {
                    self?.guidanceTextKey = indicators.distanceMessageKey
                    self?.guidanceColor = .red
                }
            } else {
                self?.guidanceTextKey = readiness.messageKey
                self?.guidanceColor = .red
            }
            #if DEBUG && !HIDE_DEBUG_UI
            self?.debugHintText = liveDebug
            self?.debugDistanceText = indicators.distanceText
            self?.debugDistanceOK = indicators.distanceOK
            self?.debugDownText = indicators.downText
            self?.debugDownOK = indicators.downOK
            self?.debugUpText = indicators.upText
            self?.debugUpOK = indicators.upOK
            #endif
        }
    }

    private func readinessStatus(for joints: BodyJoints, type: ExerciseType) -> (isReady: Bool, messageKey: String, debug: String) {
        switch type {
        case .squat:
            return squatReadiness(joints)
        case .pushUp:
            return pushupReadiness(joints)
        }
    }

    private func squatReadiness(_ joints: BodyJoints) -> (isReady: Bool, messageKey: String, debug: String) {
        let leftLegReady = joints.leftHip != nil && joints.leftKnee != nil
        let rightLegReady = joints.rightHip != nil && joints.rightKnee != nil
        guard leftLegReady || rightLegReady else {
            return (false, "exercise.guidance.showYourself", "legs:missing")
        }

        let centerCandidates = [joints.leftHip?.x, joints.rightHip?.x, joints.leftKnee?.x, joints.rightKnee?.x]
            .compactMap { $0 }
        let centerX = average(centerCandidates) ?? -1
        let hipWidth = span(joints.leftHip?.x, joints.rightHip?.x) ?? -1

        let hasAnkle = joints.leftAnkle != nil || joints.rightAnkle != nil
        let debug = String(
            format: "center:%.2f w:%.2f legs:%d/%d ankle:%d",
            Double(centerX),
            Double(hipWidth),
            leftLegReady ? 1 : 0,
            rightLegReady ? 1 : 0,
            hasAnkle ? 1 : 0
        )
        return (true, "exercise.guidance.ready", debug)
    }

    private func pushupReadiness(_ joints: BodyJoints) -> (isReady: Bool, messageKey: String, debug: String) {
        let leftArmReady = joints.leftShoulder != nil && joints.leftElbow != nil && joints.leftWrist != nil
        let rightArmReady = joints.rightShoulder != nil && joints.rightElbow != nil && joints.rightWrist != nil
        guard leftArmReady || rightArmReady else {
            return (false, "exercise.guidance.showYourself", "arms:missing")
        }

        let centerCandidates = [joints.leftShoulder?.x, joints.rightShoulder?.x, joints.leftWrist?.x, joints.rightWrist?.x]
            .compactMap { $0 }
        let centerX = average(centerCandidates) ?? -1
        let shoulderWidth = span(joints.leftShoulder?.x, joints.rightShoulder?.x) ?? -1

        let debug = String(
            format: "center:%.2f w:%.2f arms:%d/%d",
            Double(centerX),
            Double(shoulderWidth),
            leftArmReady ? 1 : 0,
            rightArmReady ? 1 : 0
        )
        return (true, "exercise.guidance.ready", debug)
    }

    private func average(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / CGFloat(values.count)
    }

    private func span(_ lhs: CGFloat?, _ rhs: CGFloat?) -> CGFloat? {
        guard let lhs, let rhs else { return nil }
        return abs(lhs - rhs)
    }

    private func indicators(
        for joints: BodyJoints,
        type: ExerciseType
    ) -> (
        distanceText: String,
        distanceOK: Bool,
        guidanceDistanceOK: Bool,
        distanceMessageKey: String,
        downText: String,
        downOK: Bool,
        upText: String,
        upOK: Bool
    ) {
        switch type {
        case .squat:
            let centerCandidates = [joints.leftHip?.x, joints.rightHip?.x, joints.leftKnee?.x, joints.rightKnee?.x]
                .compactMap { $0 }
            let centerX = average(centerCandidates)
            let distanceWidth = span(joints.leftHip?.x, joints.rightHip?.x)
            // Calmer user-facing distance zone: wider to avoid prompt flicker.
            let centerTooSide = (centerX.map { $0 < 0.05 || $0 > 0.95 } ?? true)
            let tooClose = (distanceWidth.map { $0 > 0.38 } ?? false)
            let tooFar = (distanceWidth.map { $0 < 0.0035 } ?? false)
            let rawDistanceOK = !centerTooSide && !tooClose && !tooFar
            let distanceOK = smoothedDistanceSignal(rawDistanceOK)
            let guidanceDistanceOK = smoothedGuidanceDistanceSignal(rawDistanceOK)
            let distanceMessageKey: String
            if centerTooSide {
                distanceMessageKey = "exercise.guidance.center"
            } else if tooClose {
                distanceMessageKey = "exercise.guidance.farther"
            } else if tooFar {
                distanceMessageKey = "exercise.guidance.closer"
            } else {
                distanceMessageKey = "exercise.guidance.ready"
            }

            let kneeAngle = average(
                [
                    angle(a: joints.leftHip, b: joints.leftKnee, c: joints.leftAnkle),
                    angle(a: joints.rightHip, b: joints.rightKnee, c: joints.rightAnkle)
                ].compactMap { $0 }
            )
            let downOK = (kneeAngle ?? 180) < 110
            let upOK = (kneeAngle ?? 0) > 155

            return (
                distanceText: String(format: "Дистанция: c=%.2f w=%.2f", Double(centerX ?? -1), Double(distanceWidth ?? -1)),
                distanceOK: distanceOK,
                guidanceDistanceOK: guidanceDistanceOK,
                distanceMessageKey: distanceMessageKey,
                downText: String(format: "Опускание: knee=%.0f°", Double(kneeAngle ?? -1)),
                downOK: downOK,
                upText: String(format: "Подъем: knee=%.0f°", Double(kneeAngle ?? -1)),
                upOK: upOK
            )
        case .pushUp:
            let centerCandidates = [joints.leftShoulder?.x, joints.rightShoulder?.x, joints.leftWrist?.x, joints.rightWrist?.x]
                .compactMap { $0 }
            let centerX = average(centerCandidates)
            let distanceWidth = span(joints.leftShoulder?.x, joints.rightShoulder?.x)
            let centerTooSide = (centerX.map { $0 < 0.05 || $0 > 0.95 } ?? true)
            let tooClose = (distanceWidth.map { $0 > 0.4 } ?? false)
            let tooFar = (distanceWidth.map { $0 < 0.0035 } ?? false)
            let rawDistanceOK = !centerTooSide && !tooClose && !tooFar
            let distanceOK = smoothedDistanceSignal(rawDistanceOK)
            let guidanceDistanceOK = smoothedGuidanceDistanceSignal(rawDistanceOK)
            let distanceMessageKey: String
            if centerTooSide {
                distanceMessageKey = "exercise.guidance.center"
            } else if tooClose {
                distanceMessageKey = "exercise.guidance.farther"
            } else if tooFar {
                distanceMessageKey = "exercise.guidance.closer"
            } else {
                distanceMessageKey = "exercise.guidance.ready"
            }

            let elbowAngle = average(
                [
                    angle(a: joints.leftShoulder, b: joints.leftElbow, c: joints.leftWrist),
                    angle(a: joints.rightShoulder, b: joints.rightElbow, c: joints.rightWrist)
                ].compactMap { $0 }
            )
            let downOK = (elbowAngle ?? 180) < 110
            let upOK = (elbowAngle ?? 0) > 145

            return (
                distanceText: String(format: "Дистанция: c=%.2f w=%.2f", Double(centerX ?? -1), Double(distanceWidth ?? -1)),
                distanceOK: distanceOK,
                guidanceDistanceOK: guidanceDistanceOK,
                distanceMessageKey: distanceMessageKey,
                downText: String(format: "Опускание: elbow=%.0f°", Double(elbowAngle ?? -1)),
                downOK: downOK,
                upText: String(format: "Подъем: elbow=%.0f°", Double(elbowAngle ?? -1)),
                upOK: upOK
            )
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

    private func resetDebugSignals() {
        #if DEBUG && !HIDE_DEBUG_UI
        debugHintText = ""
        debugDistanceText = "Дистанция: --"
        debugDistanceOK = false
        debugDownText = "Опускание: --"
        debugDownOK = false
        debugUpText = "Подъем: --"
        debugUpOK = false
        #endif
    }

    private func smoothedDistanceSignal(_ rawOK: Bool) -> Bool {
        if rawOK {
            distanceSignalGoodStreak = min(distanceSignalGoodStreak + 1, 60)
            distanceSignalBadStreak = 0
        } else {
            distanceSignalBadStreak = min(distanceSignalBadStreak + 1, 60)
            distanceSignalGoodStreak = 0
        }

        if !distanceSignalStable && distanceSignalGoodStreak >= 3 {
            distanceSignalStable = true
        } else if distanceSignalStable && distanceSignalBadStreak >= 12 {
            distanceSignalStable = false
        }
        return distanceSignalStable
    }

    private func smoothedGuidanceDistanceSignal(_ rawOK: Bool) -> Bool {
        if rawOK {
            guidanceDistanceGoodStreak = min(guidanceDistanceGoodStreak + 1, 120)
            guidanceDistanceBadStreak = 0
        } else {
            guidanceDistanceBadStreak = min(guidanceDistanceBadStreak + 1, 120)
            guidanceDistanceGoodStreak = 0
        }

        // Guidance prompt should be calmer than debug signal.
        if !guidanceDistanceStable && guidanceDistanceGoodStreak >= 2 {
            guidanceDistanceStable = true
        } else if guidanceDistanceStable && guidanceDistanceBadStreak >= 42 {
            guidanceDistanceStable = false
        }
        return guidanceDistanceStable
    }

    private func updateMotionStability(joints: BodyJoints, type: ExerciseType) -> Bool {
        guard let currentScale = bodyScaleMetric(joints: joints, type: type) else {
            repositionHoldFrames = max(repositionHoldFrames - 1, 0)
            return repositionHoldFrames == 0
        }

        if let previous = lastBodyScale {
            let delta = abs(currentScale - previous)
            let threshold: CGFloat = (type == .squat) ? 0.016 : 0.02
            if delta > threshold {
                repositionHoldFrames = 14
            } else if repositionHoldFrames > 0 {
                repositionHoldFrames -= 1
            }
            // Smooth scale to avoid overreacting to one noisy frame.
            lastBodyScale = (previous * 0.7) + (currentScale * 0.3)
        } else {
            lastBodyScale = currentScale
        }

        return repositionHoldFrames == 0
    }

    private func bodyScaleMetric(joints: BodyJoints, type: ExerciseType) -> CGFloat? {
        switch type {
        case .squat:
            let hipWidth = span(joints.leftHip?.x, joints.rightHip?.x)
            let kneeWidth = span(joints.leftKnee?.x, joints.rightKnee?.x)
            let widths = [hipWidth, kneeWidth].compactMap { $0 }
            return average(widths)
        case .pushUp:
            let shoulderWidth = span(joints.leftShoulder?.x, joints.rightShoulder?.x)
            let wristWidth = span(joints.leftWrist?.x, joints.rightWrist?.x)
            let widths = [shoulderWidth, wristWidth].compactMap { $0 }
            return average(widths)
        }
    }
}
