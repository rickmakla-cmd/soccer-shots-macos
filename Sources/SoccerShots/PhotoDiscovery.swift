import Foundation
import ImageIO

struct DiscoveredPhoto: Identifiable, Equatable, Sendable {
    let id: URL
    let url: URL
    let fileSize: Int64
    let modificationDate: Date
    let captureDate: Date?
}

struct PhotoDiscovery: Sendable {
    static let rasterExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "tif", "tiff", "bmp", "heic", "heif"
    ]
    static let rawExtensions: Set<String> = [
        "cr3", "cr2", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2",
        "raw", "pef", "dng", "srw", "mrw", "dcr", "kdc", "3fr", "fff", "iiq", "x3f"
    ]
    static let proprietaryRawExtensions = rawExtensions.subtracting(["dng"])
    static let supportedExtensions = rasterExtensions.union(rawExtensions)

    func discover(
        in folder: URL,
        fileManager: FileManager = .default,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [DiscoveredPhoto] {
        try cancellationCheck()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw SoccerShotsError.message("The selected folder could not be read.") }

        var candidates: [DiscoveredPhoto] = []
        for case let url as URL in enumerator {
            try cancellationCheck()
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            candidates.append(.init(
                id: url,
                url: url,
                fileSize: Int64(values.fileSize ?? 0),
                modificationDate: values.contentModificationDate ?? .distantPast,
                captureDate: captureDate(for: url)
            ))
        }
        return Self.preferRAW(candidates).sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    static func preferRAW(_ photos: [DiscoveredPhoto]) -> [DiscoveredPhoto] {
        Dictionary(grouping: photos) { photo in
            photo.url.deletingPathExtension().path.lowercased()
        }.values.compactMap { group in
            group.first { rawExtensions.contains($0.url.pathExtension.lowercased()) } ?? group.first
        }
    }

    static func burstGroups(_ photos: [DiscoveredPhoto], window: TimeInterval = 2) -> [[DiscoveredPhoto]] {
        let dated = photos.filter { $0.captureDate != nil }.sorted { $0.captureDate! < $1.captureDate! }
        var result: [[DiscoveredPhoto]] = []
        var current: [DiscoveredPhoto] = []
        for photo in dated {
            if let previous = current.last, let previousDate = previous.captureDate, let date = photo.captureDate,
               date.timeIntervalSince(previousDate) <= window {
                current.append(photo)
            } else {
                if current.count > 1 { result.append(current) }
                current = [photo]
            }
        }
        if current.count > 1 { result.append(current) }
        return result
    }

    private func captureDate(for url: URL) -> Date? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}
