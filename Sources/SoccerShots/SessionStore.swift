import Foundation

struct SessionSnapshot: Codable, Equatable, Sendable {
    let folderPath: String
    let folderBookmark: Data?
    let selectedPhotoPath: String?
    let galleryFilter: GalleryFilter
    let gallerySort: GallerySort
    let updatedAt: Date
}

struct SessionStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "SoccerShots.activeSession") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> SessionSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    func save(_ snapshot: SessionSnapshot) throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
