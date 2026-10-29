import Foundation

/// Links saved from the iPhone share sheet. The share extension can't open
/// the notebook, so it leaves each link as a small file in the App Group
/// container, and the app adds them to Links the next time it's unlocked.
enum LinkInbox {
    /// Nil when the build has no App Group (see docs/NATIVE_MAC.md, "Saving links from Safari").
    static var folder: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey:"NotebookAppGroup") as? String, !group.isEmpty, !group.hasPrefix("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:group) else { return nil }
        return container.appendingPathComponent("Link Inbox", isDirectory:true)
    }
    struct Entry: Codable { var url: String; var title: String; var note: String; var savedAt: Date }
    static func save(_ entry: Entry) throws {
        guard let folder else { throw CocoaError(.featureUnsupported) }
        try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to:folder.appendingPathComponent(UUID().uuidString + ".json"), options:[.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    /// The waiting links, oldest first, with the files to remove once each is saved.
    static func pending() -> [(entry: Entry, file: URL)] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at:folder, includingPropertiesForKeys:nil) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf:file), let entry = try? decoder.decode(Entry.self, from:data) else { try? FileManager.default.removeItem(at:file); return nil }
            return (entry, file)
        }.sorted { $0.entry.savedAt < $1.entry.savedAt }
    }
}
