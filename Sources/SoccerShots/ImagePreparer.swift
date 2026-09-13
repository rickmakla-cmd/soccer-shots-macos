import CoreImage
import Foundation
import ImageIO
import QuickLookThumbnailing
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
    ) async throws -> PreparedImage {
        guard maxDimension > 0 else {
            throw SoccerShotsError.message("macOS could not decode \(url.lastPathComponent).")
        }
        let thumbnail = try await Self.thumbnail(for: url, maxDimension: maxDimension)
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

    /// Returns a verified, visible representation. ImageIO is fastest and normally
    /// uses the camera's embedded JPEG. Quick Look is the system fallback for RAW
    /// files whose ImageIO representation intermittently renders as an all-black frame.
    static func thumbnail(for url: URL, maxDimension: CGFloat) async throws -> CGImage {
        if let image = imageIOThumbnail(for: url, maxDimension: maxDimension),
           !isEffectivelyBlack(image) {
            return image
        }

        try Task.checkCancellation()
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxDimension, height: maxDimension),
            scale: 1,
            representationTypes: .thumbnail
        )
        let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        guard !isEffectivelyBlack(representation.cgImage) else {
            throw SoccerShotsError.message(
                "macOS produced a blank preview for \(url.lastPathComponent). It was not sent for scoring."
            )
        }
        return representation.cgImage
    }

    private static func imageIOThumbnail(for url: URL, maxDimension: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
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
