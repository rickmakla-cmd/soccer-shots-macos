import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

struct PreparedImage: @unchecked Sendable {
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
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw SoccerShotsError.message("macOS could not decode \(url.lastPathComponent).")
        }
        // Render through ImageIO first. CIImage(contentsOf:) can expose a RAW
        // recipe that looks correct when consumed directly but encodes as black.
        let image = CIImage(cgImage: thumbnail)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let jpeg = context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else { throw SoccerShotsError.message("Could not prepare \(url.lastPathComponent) for scoring.") }
        guard let verificationImage = CIImage(data: jpeg),
              !Self.isEffectivelyBlack(verificationImage, context: context) else {
            throw SoccerShotsError.message(
                "macOS produced a blank preview for \(url.lastPathComponent). It was not sent for scoring."
            )
        }
        return .init(ciImage: image, jpegData: jpeg)
    }

    static func isEffectivelyBlack(_ image: CIImage, context: CIContext) -> Bool {
        let filter = CIFilter.areaMaximum()
        filter.inputImage = image
        filter.extent = image.extent
        guard let output = filter.outputImage else { return true }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return (pixel[0...2].max() ?? 0) <= 1
    }
}
