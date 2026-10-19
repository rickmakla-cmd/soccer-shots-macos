import SwiftData
import SwiftUI

@main
struct SoccerShotsApp: App {
    @StateObject private var model: AppModel
    private let modelContainer: ModelContainer

    init() {
        let backupStore = ScoreBackupStore()
        let hadAppSpecificStore = FileManager.default.fileExists(atPath: backupStore.storeURL.path)
        do {
            try backupStore.prepareDirectory()
            ScoreBackupStore.preserveRawStoreBeforeOpening(storeURL: backupStore.storeURL)
            if hadAppSpecificStore {
                try backupStore.createPortableBackupFromRawStoreIfNeeded(storeURL: backupStore.storeURL)
            } else {
                // Older releases used SwiftData's generic default.store location,
                // which can be shared by unrelated unsandboxed apps. Import its
                // data only when no portable backup already exists.
                try backupStore.createPortableBackupFromRawStoreIfNeeded(
                    storeURL: ScoreBackupStore.legacySharedStoreURL()
                )
            }
        } catch {
            UserDefaults.standard.set(
                "SoccerShots preserved the original database but could not create its portable pre-migration backup: \(error.localizedDescription)",
                forKey: ScoreBackupStore.startupErrorKey
            )
        }
        let container: ModelContainer
        do {
            let configuration = ModelConfiguration(url: backupStore.storeURL)
            container = try ModelContainer(for: ScoreRecord.self, configurations: configuration)
        } catch {
            fatalError("SoccerShots could not open its score database: \(error.localizedDescription)")
        }
        modelContainer = container

        do {
            let restored = try backupStore.restoreMissingRecords(in: container.mainContext)
            let records = try container.mainContext.fetch(FetchDescriptor<ScoreRecord>())
            if !records.isEmpty {
                try backupStore.save(records: records)
            }
            if restored > 0, hadAppSpecificStore {
                UserDefaults.standard.set(
                    "Recovered \(restored.formatted()) saved score-cache records after repairing the database. No photo folder or session was reopened; choose a folder to start new work.",
                    forKey: ScoreBackupStore.startupNoticeKey
                )
            }
        } catch {
            UserDefaults.standard.set(
                "SoccerShots could not safely open or recover its score database: \(error.localizedDescription)",
                forKey: ScoreBackupStore.startupErrorKey
            )
        }
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 660)
        }
        .modelContainer(modelContainer)
        .windowResizability(.contentMinSize)
    }
}
