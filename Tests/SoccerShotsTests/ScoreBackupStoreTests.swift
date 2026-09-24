import Foundation
import SQLite3
import SwiftData
import Testing
@testable import SoccerShots

@Suite("Score database safety backup")
@MainActor
struct ScoreBackupStoreTests {
    @Test func restoresAnEmptyStoreFromPortableBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoccerShotsBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backupStore = ScoreBackupStore(directoryURL: root)
        let snapshot = sampleSnapshot(path: "/photos/IMG_0042.CR3")
        try backupStore.save(snapshots: [snapshot])

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ScoreRecord.self, configurations: configuration)
        let restored = try backupStore.restoreIfEmpty(in: container.mainContext)
        let records = try container.mainContext.fetch(FetchDescriptor<ScoreRecord>())

        #expect(restored == 1)
        #expect(records.count == 1)
        #expect(records[0].filepath == snapshot.filepath)
        #expect(records[0].scoreData == snapshot.scoreData)
    }

    @Test func neverRestoresOverExistingRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoccerShotsBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backupStore = ScoreBackupStore(directoryURL: root)
        try backupStore.save(snapshots: [sampleSnapshot(path: "/backup.CR3")])

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ScoreRecord.self, configurations: configuration)
        container.mainContext.insert(ScoreRecord(snapshot: sampleSnapshot(path: "/live.CR3")))
        try container.mainContext.save()

        #expect(try backupStore.restoreIfEmpty(in: container.mainContext) == 0)
        let records = try container.mainContext.fetch(FetchDescriptor<ScoreRecord>())
        #expect(records.count == 1)
        #expect(records[0].filepath == "/live.CR3")
    }

    @Test func intentionalEmptyStateDoesNotResurrectResetScores() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoccerShotsBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backupStore = ScoreBackupStore(directoryURL: root)
        try backupStore.save(snapshots: [sampleSnapshot(path: "/old.CR3")])
        try backupStore.replaceWithCurrentState(records: [])

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ScoreRecord.self, configurations: configuration)
        #expect(try backupStore.restoreIfEmpty(in: container.mainContext) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<ScoreRecord>()) == 0)
    }

    @Test func fallsBackToPreviousGenerationWhenLatestBackupIsCorrupt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoccerShotsBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backupStore = ScoreBackupStore(directoryURL: root)
        try backupStore.save(snapshots: [sampleSnapshot(path: "/recover-me.CR3")])
        try backupStore.save(snapshots: [sampleSnapshot(path: "/newer.CR3")])
        try Data("not-json".utf8).write(to: backupStore.backupURL)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ScoreRecord.self, configurations: configuration)
        #expect(try backupStore.restoreIfEmpty(in: container.mainContext) == 1)
        let records = try container.mainContext.fetch(FetchDescriptor<ScoreRecord>())
        #expect(records.first?.filepath == "/recover-me.CR3")
    }

    @Test func exportsLegacySQLiteBeforeSwiftDataOpensIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoccerShotsBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyURL = root.appendingPathComponent("legacy.store")
        var database: OpaquePointer?
        #expect(sqlite3_open(legacyURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE ZSCORERECORD (
            ZFILEPATH TEXT, ZFILENAME TEXT, ZFILESIZE INTEGER, ZMODIFICATIONDATE REAL,
            ZSESSIONFOLDER TEXT, ZSCOREDAT REAL, ZSCORINGVERSION TEXT, ZSCORINGENGINE TEXT,
            ZISPOSTPROCESSED INTEGER, ZISMANUALLYREJECTED INTEGER, ZISSELECTEDFOREXPORT INTEGER,
            ZMANUALREVIEWLABELRAW TEXT, ZSCOREDATA BLOB, ZDEEPREVIEWDATA BLOB,
            ZBENCHMARKDATA BLOB, ZGEMINIBATCHDATA BLOB, ZEVIDENCEBENCHMARKDATA BLOB
        );
        INSERT INTO ZSCORERECORD VALUES (
            '/photos/legacy.CR3', 'legacy.CR3', 42, 100, '/photos', 200, 'v1', 'Gemma',
            0, 0, 1, NULL, X'017B7D', NULL, NULL, NULL, NULL
        );
        """
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        database = nil

        let backupStore = ScoreBackupStore(directoryURL: root.appendingPathComponent("backup"))
        try backupStore.createPortableBackupFromRawStoreIfNeeded(storeURL: legacyURL)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ScoreRecord.self, configurations: configuration)
        #expect(try backupStore.restoreIfEmpty(in: container.mainContext) == 1)
        let records = try container.mainContext.fetch(FetchDescriptor<ScoreRecord>())
        #expect(records.first?.filepath == "/photos/legacy.CR3")
        #expect(records.first?.scoreData == Data("{}".utf8))
    }

    @Test func rawStoreSnapshotIncludesCommittedWALChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoccerShotsBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent("source.store")
        let destinationURL = root.appendingPathComponent("snapshot.store")

        var sourceDatabase: OpaquePointer?
        #expect(sqlite3_open(sourceURL.path, &sourceDatabase) == SQLITE_OK)
        guard let sourceDatabase else { return }
        defer { sqlite3_close(sourceDatabase) }
        #expect(sqlite3_exec(sourceDatabase, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(sourceDatabase, "CREATE TABLE scores (value TEXT);", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(sourceDatabase, "INSERT INTO scores VALUES ('keeper');", nil, nil, nil) == SQLITE_OK)

        try ScoreBackupStore.createRawStoreSnapshot(from: sourceURL, to: destinationURL)

        var snapshotDatabase: OpaquePointer?
        #expect(sqlite3_open_v2(destinationURL.path, &snapshotDatabase, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        guard let snapshotDatabase else { return }
        defer { sqlite3_close(snapshotDatabase) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(snapshotDatabase, "SELECT value FROM scores", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        let value = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        #expect(value == "keeper")
    }

    private func sampleSnapshot(path: String) -> ScoreRecordSnapshot {
        ScoreRecordSnapshot(
            filepath: path,
            filename: URL(fileURLWithPath: path).lastPathComponent,
            fileSize: 42,
            modificationDate: Date(timeIntervalSinceReferenceDate: 100),
            sessionFolder: "/photos",
            scoredAt: Date(timeIntervalSinceReferenceDate: 200),
            scoringVersion: "test",
            scoringEngine: "test",
            isPostProcessed: false,
            isManuallyRejected: false,
            isSelectedForExport: true,
            manualReviewLabelRaw: nil,
            scoreData: Data("score".utf8),
            primaryEvidenceData: nil,
            deepReviewData: nil,
            benchmarkData: nil,
            geminiBatchData: nil,
            evidenceBenchmarkData: nil
        )
    }
}
