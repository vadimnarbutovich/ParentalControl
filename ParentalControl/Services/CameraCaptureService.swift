import AVFoundation
import Foundation
import ImageIO

final class CameraCaptureService: NSObject {
    let session = AVCaptureSession()
    var sampleBufferHandler: ((CMSampleBuffer, CGImagePropertyOrientation) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "parentalcontrol.camera.session")
    private let outputQueue = DispatchQueue(label: "parentalcontrol.camera.output")
    private var configured = false
    private var cameraPosition: AVCaptureDevice.Position = .front

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !configured {
                configured = configureSession()
            }
            guard configured, !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    private func configureSession() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput) else {
            return false
        }
        session.addInput(cameraInput)
        cameraPosition = camera.position

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(videoOutput) else { return false }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported, cameraPosition == .front {
                connection.isVideoMirrored = true
            }
            if connection.isVideoRotationAngleSupported(270) {
                connection.videoRotationAngle = 270
            }
        }
        return true
    }

    private func imageOrientation(for connection: AVCaptureConnection) -> CGImagePropertyOrientation {
        let isMirrored = connection.isVideoMirrored
        switch connection.videoOrientation {
        case .portrait:
            return isMirrored ? .leftMirrored : .right
        case .portraitUpsideDown:
            return isMirrored ? .rightMirrored : .left
        case .landscapeRight:
            return isMirrored ? .upMirrored : .down
        case .landscapeLeft:
            return isMirrored ? .downMirrored : .up
        @unknown default:
            return isMirrored ? .leftMirrored : .right
        }
    }
}

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        sampleBufferHandler?(sampleBuffer, imageOrientation(for: connection))
    }
}
