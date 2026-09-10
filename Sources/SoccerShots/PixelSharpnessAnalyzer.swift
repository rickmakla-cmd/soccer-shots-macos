import CoreGraphics
import Foundation
import Vision

/// Measures edge definition from pixels instead of asking a language model to
/// infer focus. The largest detected person is used so fences and foliage do
/// not dominate the result. A missing person produces no score rather than a
/// misleading whole-frame measurement.
struct PixelSharpnessAnalyzer: Sendable {
    private let sampleSize = 192

    func score(_ image: CGImage) -> Double? {
        guard let subject = primaryPersonCrop(in: image),
              let pixels = grayscalePixels(from: subject) else { return nil }

        var gradients = [Double]()
        gradients.reserveCapacity((sampleSize - 2) * (sampleSize - 2))
        for y in 1..<(sampleSize - 1) {
            for x in 1..<(sampleSize - 1) {
                let offset = y * sampleSize + x
                let center = Int(pixels[offset])
                // Ignore nearly clipped pixels: their boundaries exaggerate
                // focus without containing useful subject detail.
                guard (12...243).contains(center) else { continue }
                let horizontal = Int(pixels[offset + 1]) - Int(pixels[offset - 1])
                let vertical = Int(pixels[offset + sampleSize]) - Int(pixels[offset - sampleSize])
                gradients.append(Double(horizontal * horizontal + vertical * vertical).squareRoot())
            }
        }
        guard gradients.count >= 100 else { return nil }
        gradients.sort()

        // Average the strongest 10% of useful subject edges. This is more
        // resistant to smooth jerseys/skin than averaging the entire crop.
        let start = gradients.count * 9 / 10
        let edgeStrength = gradients[start...].reduce(0, +) / Double(gradients.count - start)
        return Self.score(edgeStrength: edgeStrength)
    }

    static func score(edgeStrength: Double) -> Double {
        // Broad anchors deliberately avoid false precision. The benchmark UI
        // exposes the result so these can be calibrated against manual labels.
        let normalized = min(1, max(0, (edgeStrength - 18) / 62))
        return (2 + normalized * 7).rounded(toPlaces: 1)
    }

    private func primaryPersonCrop(in image: CGImage) -> CGImage? {
        let request = VNDetectHumanRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.max(by: {
                  $0.boundingBox.width * $0.boundingBox.height
                      < $1.boundingBox.width * $1.boundingBox.height
              }) else { return nil }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let box = observation.boundingBox
        var rect = CGRect(
            x: box.minX * width,
            y: (1 - box.maxY) * height,
            width: box.width * width,
            height: box.height * height
        )
        rect = rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.08)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            .integral
        guard rect.width >= 32, rect.height >= 32 else { return nil }
        return image.cropping(to: rect)
    }

    private func grayscalePixels(from image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize)
        guard let context = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        return pixels
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = Foundation.pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
