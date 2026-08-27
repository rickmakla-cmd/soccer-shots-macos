import SwiftData
import SwiftUI

@main
struct SoccerShotsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 660)
        }
        .modelContainer(for: ScoreRecord.self)
        .windowResizability(.contentMinSize)
    }
}
