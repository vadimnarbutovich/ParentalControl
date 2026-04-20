import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import Vision

final class PoseDetectionService {
    private let request = VNDetectHumanBodyPoseRequest()
    private let sequenceHandler = VNSequenceRequestHandler()
    private let minimumConfidence: Float = 0.2

    func detectJoints(
        from sampleBuffer: CMSampleBuffer,
        orientation: CGImagePropertyOrientation
    ) -> BodyJoints? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
            guard let observation = request.results?.first else { return nil }
            let points = try observation.recognizedPoints(.all)

            return BodyJoints(
                leftShoulder: point(.leftShoulder, in: points),
                rightShoulder: point(.rightShoulder, in: points),
                leftElbow: point(.leftElbow, in: points),
                rightElbow: point(.rightElbow, in: points),
                leftWrist: point(.leftWrist, in: points),
                rightWrist: point(.rightWrist, in: points),
                leftHip: point(.leftHip, in: points),
                rightHip: point(.rightHip, in: points),
                leftKnee: point(.leftKnee, in: points),
                rightKnee: point(.rightKnee, in: points),
                leftAnkle: point(.leftAnkle, in: points),
                rightAnkle: point(.rightAnkle, in: points)
            )
        } catch {
            return nil
        }
    }

    private func point(
        _ joint: VNHumanBodyPoseObservation.JointName,
        in points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    ) -> CGPoint? {
        guard let point = points[joint], point.confidence >= minimumConfidence else { return nil }
        return CGPoint(x: point.location.x, y: point.location.y)
    }
}
