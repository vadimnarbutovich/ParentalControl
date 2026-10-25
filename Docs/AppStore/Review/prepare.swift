import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Deterministic App Review screenshot preparation. No UI/text alterations.
// Usage: swift prepare.swift source.png output.png
guard CommandLine.arguments.count == 3 else { fatalError("Expected input and output paths") }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard !FileManager.default.fileExists(atPath: output.path),
      let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: 1125, height: 2436,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Cannot prepare image") }
let width: CGFloat = 1125, height: CGFloat = 2436
context.setFillColor(CGColor(red: 0.035, green: 0.055, blue: 0.10, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
let scale = min(width / CGFloat(image.width), height / CGFloat(image.height))
let drawnWidth = CGFloat(image.width) * scale, drawnHeight = CGFloat(image.height) * scale
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: (width - drawnWidth) / 2, y: (height - drawnHeight) / 2,
                              width: drawnWidth, height: drawnHeight))
guard let result = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Cannot encode image") }
CGImageDestinationAddImage(destination, result, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save image") }
print("Prepared opaque sRGB PNG: 1125 x 2436")
