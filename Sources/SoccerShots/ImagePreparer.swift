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
        let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        guard var image = CIImage(contentsOf: url, options: options) else {
            throw SoccerShotsError.message("macOS could not decode \(url.lastPathComponent).")
        }
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > maxDimension {
            let scale = maxDimension / longEdge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let jpeg = context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else { throw SoccerShotsError.message("Could not prepare \(url.lastPathComponent) for scoring.") }
        return .init(ciImage: image, jpegData: jpeg)
    }
}
