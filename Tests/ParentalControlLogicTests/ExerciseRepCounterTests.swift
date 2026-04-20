import CoreGraphics
import Testing
@testable import ParentalControlLogic

@Test
func squatCounterCountsOneRepForDownUpCycle() {
    let counter = ExerciseRepCounter()
    counter.reset()

    counter.process(joints: squatPose(kneeAngle: 170), type: .squat)
    counter.process(joints: squatPose(kneeAngle: 95), type: .squat)
    counter.process(joints: squatPose(kneeAngle: 170), type: .squat)

    #expect(counter.reps == 1)
}

@Test
func pushupCounterCountsOneRepForDownUpCycle() {
    let counter = ExerciseRepCounter()
    counter.reset()

    counter.process(joints: pushupPose(elbowAngle: 165), type: .pushUp)
    counter.process(joints: pushupPose(elbowAngle: 70), type: .pushUp)
    counter.process(joints: pushupPose(elbowAngle: 165), type: .pushUp)

    #expect(counter.reps == 1)
}

private func squatPose(kneeAngle: CGFloat) -> BodyJoints {
    let knee = CGPoint(x: 0, y: 0)
    let ankle = CGPoint(x: 1, y: 0)
    let radians = kneeAngle * .pi / 180
    let hip = CGPoint(x: cos(radians), y: sin(radians))

    return BodyJoints(
        leftShoulder: nil,
        rightShoulder: nil,
        leftElbow: nil,
        rightElbow: nil,
        leftWrist: nil,
        rightWrist: nil,
        leftHip: hip,
        rightHip: hip,
        leftKnee: knee,
        rightKnee: knee,
        leftAnkle: ankle,
        rightAnkle: ankle
    )
}

private func pushupPose(elbowAngle: CGFloat) -> BodyJoints {
    let elbow = CGPoint(x: 0, y: 0)
    let wrist = CGPoint(x: 1, y: 0)
    let radians = elbowAngle * .pi / 180
    let shoulder = CGPoint(x: cos(radians), y: sin(radians))

    return BodyJoints(
        leftShoulder: shoulder,
        rightShoulder: shoulder,
        leftElbow: elbow,
        rightElbow: elbow,
        leftWrist: wrist,
        rightWrist: wrist,
        leftHip: nil,
        rightHip: nil,
        leftKnee: nil,
        rightKnee: nil,
        leftAnkle: nil,
        rightAnkle: nil
    )
}
