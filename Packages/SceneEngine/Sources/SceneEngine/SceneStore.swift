import Foundation

/// Persistence backend for saved scenes. `save` reports a write that didn't happen: saving one
/// scene stays best-effort, but a settings import must know (`SceneLibrary.replaceAll`).
public protocol SceneStoring: Sendable {
    func load() async -> [Scene]
    func save(_ scenes: [Scene]) async throws
}

/// In-memory scene store for tests and previews.
public actor InMemorySceneStore: SceneStoring {
    private var scenes: [Scene]
    public init(_ scenes: [Scene] = []) { self.scenes = scenes }
    public func load() -> [Scene] { scenes }
    public func save(_ scenes: [Scene]) { self.scenes = scenes }
}

/// Atomic JSON store at `<dir>/scenes.json` (pure Foundation; covered by `make test`).
public struct DiskSceneStore: SceneStoring {
    private let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("scenes.json")
    }

    public static func defaultDirectory(
        appName: String = "OpenDisplay",
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    public func load() async -> [Scene] {
        guard let data = try? Data(contentsOf: fileURL),
              let scenes = try? JSONDecoder().decode([Scene].self, from: data) else { return [] }
        return scenes
    }

    /// Atomic: a write that fails leaves the previous file as it was, and throws.
    public func save(_ scenes: [Scene]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(scenes).write(to: fileURL, options: .atomic)
    }
}

/// CRUD over a scene store, upserting by scene id. The single owner of saved scenes for the app/CLI.
public actor SceneLibrary {
    private var scenes: [Scene]
    private let store: any SceneStoring

    public init(store: any SceneStoring) async {
        self.store = store
        self.scenes = await store.load()
    }

    public func all() -> [Scene] { scenes.sorted { $0.name < $1.name } }
    public func scene(named name: String) -> Scene? { scenes.first { $0.name == name } }
    public func scene(id: String) -> Scene? { scenes.first { $0.id == id } }

    /// Best-effort persistence, as before: the next change writes the whole library again.
    public func save(_ scene: Scene) async {
        if let index = scenes.firstIndex(where: { $0.id == scene.id }) {
            scenes[index] = scene
        } else {
            scenes.append(scene)
        }
        try? await store.save(scenes)
    }

    public func delete(id: String) async {
        scenes.removeAll { $0.id == id }
        try? await store.save(scenes)
    }

    /// Replaces the whole library with `newScenes` and persists it — a settings import or reset.
    /// Throws when scenes.json couldn't be written: memory then holds `newScenes` while the file
    /// still holds what was there, and the caller decides — an import puts the previous ones back.
    public func replaceAll(with newScenes: [Scene]) async throws {
        scenes = newScenes
        try await store.save(scenes)
    }
}
