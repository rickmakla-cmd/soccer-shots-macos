import Foundation

struct ExportResult: Equatable, Sendable {
    let exported: Int
    let failed: Int
    let destination: URL
    let failures: [String]
}

enum ExportProgress: Equatable, Sendable {
    case idle
    case exporting(index: Int, total: Int, filename: String)
    case finished(exported: Int, failed: Int)

    var message: String {
        switch self {
        case .idle:
            "Export ready"
        case let .exporting(index, total, filename):
            "Exporting \(index) of \(total): \(filename)"
        case let .finished(exported, failed):
            "Export finished: \(exported) copied, \(failed) failed"
        }
    }
}

struct ExportService: Sendable {
    private let fileManager: FileManager
    private let xmpBuilder: XMPBuilder

    init(fileManager: FileManager = .default, xmpBuilder: XMPBuilder = .init()) {
        self.fileManager = fileManager
        self.xmpBuilder = xmpBuilder
    }

    func export(
        photos: [ScoredPhoto],
        to directory: URL,
        progress: @Sendable (ExportProgress) -> Void = { _ in }
    ) throws -> ExportResult {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var exported = 0
        var failures: [String] = []

        for (offset, photo) in photos.enumerated() {
            try Task.checkCancellation()
            progress(.exporting(index: offset + 1, total: photos.count, filename: photo.filename))
            let destinations = availableDestinations(for: photo.fileURL, in: directory)

            do {
                try fileManager.copyItem(at: photo.fileURL, to: destinations.original)
                do {
                    let data = Data(xmpBuilder.sidecar(for: photo).utf8)
                    try data.write(to: destinations.sidecar, options: .atomic)
                    exported += 1
                } catch {
                    try? fileManager.removeItem(at: destinations.original)
                    throw error
                }
            } catch {
                failures.append("\(photo.filename): \(error.localizedDescription)")
            }
        }

        progress(.finished(exported: exported, failed: failures.count))
        return ExportResult(
            exported: exported,
            failed: failures.count,
            destination: directory,
            failures: failures
        )
    }

    func availableDestinations(for source: URL, in directory: URL) -> (original: URL, sidecar: URL) {
        let originalBase = source.deletingPathExtension().lastPathComponent
        let originalExtension = source.pathExtension
        var suffix = 1

        while true {
            let base = suffix == 1 ? originalBase : "\(originalBase)-\(suffix)"
            let originalName = originalExtension.isEmpty ? base : "\(base).\(originalExtension)"
            let original = directory.appendingPathComponent(originalName, isDirectory: false)
            let sidecar = directory.appendingPathComponent("\(base).xmp", isDirectory: false)
            if !fileManager.fileExists(atPath: original.path), !fileManager.fileExists(atPath: sidecar.path) {
                return (original, sidecar)
            }
            suffix += 1
        }
    }
}
