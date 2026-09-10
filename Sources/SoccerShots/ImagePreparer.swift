import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedImage: @unchecked Sendable {
    let cgImage: CGImage
    let ciImage: CIImage
    let jpegData: Data
}

struct ImagePreparer: Sendable {
    static let maxDimension: CGFloat = 2_400

    func prepare(
        _ url: URL,
        maxDimension: CGFloat = Self.maxDimension,
        quality: Double = 0.9
    ) throws -> PreparedImage {
        guard maxDimension > 0,
              let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                // Prefer the camera's embedded JPEG preview. Some Canon CR3
                // files decode correctly on screen but RAW-render as black.
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw SoccerShotsError.message("macOS could not decode \(url.lastPathComponent).")
        }
        // Render through ImageIO first. CIImage(contentsOf:) can expose a RAW
        // recipe that looks correct when consumed directly but encodes as black.
        let image = CIImage(cgImage: thumbnail)
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            jpeg as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw SoccerShotsError.message("Could not prepare \(url.lastPathComponent) for scoring.") }
        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let verificationSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let verificationImage = CGImageSourceCreateImageAtIndex(verificationSource, 0, nil),
              !Self.isEffectivelyBlack(verificationImage) else {
            throw SoccerShotsError.message(
                "macOS produced a blank preview for \(url.lastPathComponent). It was not sent for scoring."
            )
        }
        return .init(
            cgImage: thumbnail,
            ciImage: image,
            jpegData: jpeg as Data
        )
    }

    static func isEffectivelyBlack(_ image: CGImage) -> Bool {
        let width = 16
        let height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return true }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var brightest: UInt8 = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            brightest = max(brightest, pixels[offset])
            brightest = max(brightest, pixels[offset + 1])
            brightest = max(brightest, pixels[offset + 2])
        }
        return brightest <= 1
    }
}
