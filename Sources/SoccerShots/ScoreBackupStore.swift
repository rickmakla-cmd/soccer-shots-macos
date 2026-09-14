import Foundation
import SQLite3
import SwiftData

struct ScoreRecordSnapshot: Codable, Sendable {
    let filepath: String
    let filename: String
    let fileSize: Int64
    let modificationDate: Date
    let sessionFolder: String
    let scoredAt: Date
    let scoringVersion: String
    let scoringEngine: String
    let isPostProcessed: Bool
    let isManuallyRejected: Bool
    let isSelectedForExport: Bool
    let manualReviewLabelRaw: String?
    let scoreData: Data
    let deepReviewData: Data?
    let benchmarkData: Data?
    let geminiBatchData: Data?
    let evidenceBenchmarkData: Data?
}

struct ScoreBackupEnvelope: Codable, Sendable {
    let formatVersion: Int
    let createdAt: Date
    let records: [ScoreRecordSnapshot]
}

@MainActor
struct ScoreBackupStore {
    static let startupNoticeKey = "SoccerShots.startupPersistenceNotice"
    static let startupErrorKey = "SoccerShots.startupPersistenceError"

    private let fileManager: FileManager
    private let directoryURL: URL

    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectory(fileManager: fileManager)
    }

    var backupURL: URL { directoryURL.appendingPathComponent("score-records-v1.json") }
    var previousBackupURL: URL { directoryURL.appendingPathComponent("score-records-v1.previous.json") }

    func save(records: [ScoreRecord]) throws {
        guard !records.isEmpty else { return }
        let snapshots = records.map(ScoreRecordSnapshot.init)
        try save(snapshots: snapshots)
    }

    /// Records an intentional state change, including a user-confirmed reset that
    /// leaves the database empty. Routine checkpoints never replace a good backup
    /// with an unexpectedly empty store.
    func replaceWithCurrentState(records: [ScoreRecord]) throws {
        try write(snapshots: records.map(ScoreRecordSnapshot.init), allowsEmpty: true)
    }

    func save(snapshots: [ScoreRecordSnapshot]) throws {
        guard !snapshots.isEmpty else { return }
        try write(snapshots: snapshots, allowsEmpty: false)
    }

    private func write(snapshots: [ScoreRecordSnapshot], allowsEmpty: Bool) throws {
        guard allowsEmpty || !snapshots.isEmpty else { return }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let envelope = ScoreBackupEnvelope(formatVersion: 1, createdAt: Date(), records: snapshots)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)

        if fileManager.fileExists(atPath: backupURL.path) {
            if fileManager.fileExists(atPath: previousBackupURL.path) {
                try fileManager.removeItem(at: previousBackupURL)
            }
            try fileManager.copyItem(at: backupURL, to: previousBackupURL)
        }
        try data.write(to: backupURL, options: [.atomic])
    }

    @discardableResult
    func restoreIfEmpty(in context: ModelContext) throws -> Int {
        guard try context.fetchCount(FetchDescriptor<ScoreRecord>()) == 0 else { return 0 }
        guard let envelope = try loadFirstValidBackup(), !envelope.records.isEmpty else { return 0 }

        var snapshotsByPath: [String: ScoreRecordSnapshot] = [:]
        for snapshot in envelope.records {
            snapshotsByPath[snapshot.filepath] = snapshot
        }
        for snapshot in snapshotsByPath.values {
            context.insert(ScoreRecord(snapshot: snapshot))
        }
        try context.save()
        return snapshotsByPath.count
    }

    /// Creates the portable backup without asking SwiftData to open the store.
    /// This protects the first launch of an upgrade, before automatic migration
    /// has any opportunity to alter or empty the database.
    func createPortableBackupFromRawStoreIfNeeded(storeURL: URL? = nil) throws {
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sourceURL = storeURL ?? applicationSupport.appendingPathComponent("default.store")
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(sourceURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openResult == SQLITE_OK, let database else {
            defer { if database != nil { sqlite3_close(database) } }
            throw sqliteError(database, fallback: "The existing score database could not be opened for backup.")
        }
        defer { sqlite3_close(database) }

        let sql = """
        SELECT ZFILEPATH, ZFILENAME, ZFILESIZE, ZMODIFICATIONDATE, ZSESSIONFOLDER,
               ZSCOREDAT, ZSCORINGVERSION, ZSCORINGENGINE, ZISPOSTPROCESSED,
               ZISMANUALLYREJECTED, ZISSELECTEDFOREXPORT, ZMANUALREVIEWLABELRAW,
               ZSCOREDATA, ZDEEPREVIEWDATA, ZBENCHMARKDATA, ZGEMINIBATCHDATA,
               ZEVIDENCEBENCHMARKDATA
        FROM ZSCORERECORD
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(database, fallback: "The existing score database could not be read for backup.")
        }
        defer { sqlite3_finalize(statement) }

        var snapshots: [ScoreRecordSnapshot] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let filepath = sqliteString(statement, 0),
                  let filename = sqliteString(statement, 1),
                  let sessionFolder = sqliteString(statement, 4),
                  let scoringVersion = sqliteString(statement, 6),
                  let scoringEngine = sqliteString(statement, 7),
                  let scoreData = swiftDataBlob(statement, 12) else {
                throw NSError(
                    domain: "SoccerShots.ScoreBackup",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "An existing score row was incomplete, so no partial backup was written."]
                )
            }
            snapshots.append(ScoreRecordSnapshot(
                filepath: filepath,
                filename: filename,
                fileSize: sqlite3_column_int64(statement, 2),
                modificationDate: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)),
                sessionFolder: sessionFolder,
                scoredAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 5)),
                scoringVersion: scoringVersion,
                scoringEngine: scoringEngine,
                isPostProcessed: sqlite3_column_int(statement, 8) != 0,
                isManuallyRejected: sqlite3_column_int(statement, 9) != 0,
                isSelectedForExport: sqlite3_column_int(statement, 10) != 0,
                manualReviewLabelRaw: sqliteString(statement, 11),
                scoreData: scoreData,
                deepReviewData: swiftDataBlob(statement, 13),
                benchmarkData: swiftDataBlob(statement, 14),
                geminiBatchData: swiftDataBlob(statement, 15),
                evidenceBenchmarkData: swiftDataBlob(statement, 16)
            ))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw sqliteError(database, fallback: "The existing score database could not be fully read for backup.")
        }
        try save(snapshots: snapshots)
    }

    /// Copies the unopened SQLite store before SwiftData gets a chance to migrate it.
    /// This is a last-resort recovery layer in addition to the portable JSON backup.
    static func preserveRawStoreBeforeOpening(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storeURL = applicationSupport.appendingPathComponent("default.store")
        guard fileManager.fileExists(atPath: storeURL.path) else { return }

        do {
            let root = defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("store-snapshots", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            let snapshotName = "\(formatter.string(from: Date()))-\(UUID().uuidString)"
            let destination = root.appendingPathComponent(snapshotName, isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: storeURL.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(
                    at: source,
                    to: destination.appendingPathComponent("default.store" + suffix)
                )
            }

            let snapshots = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent > $1.lastPathComponent }
            for obsolete in snapshots.dropFirst(3) {
                try? fileManager.removeItem(at: obsolete)
            }
        } catch {
            UserDefaults.standard.set(
                "SoccerShots could not make its pre-launch database safety copy: \(error.localizedDescription)",
                forKey: startupErrorKey
            )
        }
    }

    private func loadFirstValidBackup() throws -> ScoreBackupEnvelope? {
        var lastError: Error?
        for url in [backupURL, previousBackupURL] where fileManager.fileExists(atPath: url.path) {
            do {
                let envelope = try JSONDecoder().decode(ScoreBackupEnvelope.self, from: Data(contentsOf: url))
                guard envelope.formatVersion == 1 else { continue }
                return envelope
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        return nil
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.rickmakla.SoccerShots", isDirectory: true)
    }

    private func sqliteString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func swiftDataBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, index))
        var data = Data(bytes: bytes, count: length)
        if data.count > 1, data.first == 0x01 {
            let payloadStart = data.index(after: data.startIndex)
            if data[payloadStart] == 0x7B || data[payloadStart] == 0x5B {
                data.removeFirst()
            }
        }
        return data
    }

    private func sqliteError(_ database: OpaquePointer?, fallback: String) -> Error {
        let message = database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? fallback
        return NSError(domain: "SoccerShots.ScoreBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension ScoreRecordSnapshot {
    init(_ record: ScoreRecord) {
        filepath = record.filepath
        filename = record.filename
        fileSize = record.fileSize
        modificationDate = record.modificationDate
        sessionFolder = record.sessionFolder
        scoredAt = record.scoredAt
        scoringVersion = record.scoringVersion
        scoringEngine = record.scoringEngine
        isPostProcessed = record.isPostProcessed
        isManuallyRejected = record.isManuallyRejected
        isSelectedForExport = record.isSelectedForExport
        manualReviewLabelRaw = record.manualReviewLabelRaw
        scoreData = record.scoreData
        deepReviewData = record.deepReviewData
        benchmarkData = record.benchmarkData
        geminiBatchData = record.geminiBatchData
        evidenceBenchmarkData = record.evidenceBenchmarkData
    }
}
