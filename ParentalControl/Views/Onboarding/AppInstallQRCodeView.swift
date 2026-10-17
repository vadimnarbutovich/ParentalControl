import CoreImage.CIFilterBuiltins
import SwiftUI

/// A public App Store link only: no pairing code or other family data.
struct AppInstallQRCodeView: View {
    // Generate once, not whenever setup or permission state changes.
    private static let image = AppInstallQRCode.makeImage(for: AppStoreLinks.shareURL)

    var body: some View {
        if let image = Self.image {
            Image(image, scale: 1, label: Text("setup.install.qr.accessibility"))
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: 200)
                // Keep a white quiet zone of at least four modules on every side.
                .padding(32)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity)
        }
    }
}

enum AppInstallQRCode {
    static func makeImage(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Integer scaling keeps QR modules crisp; no networking is involved.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
