import SwiftUI
import Foundation
import ImageIO
import UniformTypeIdentifiers
import NotebookCore

/// The Mac's original five moods are the stored values. The iPhone briefly
/// saved great/good/bad; those are shown as their nearest mood and are only
/// rewritten if the person picks a mood for that entry.
enum JournalMood: String, CaseIterable, Identifiable {
    case amazing, happy, neutral, sad, stressed
    var id: Self { self }
    var label: String { ["amazing":"Amazing", "happy":"Happy", "neutral":"Okay", "sad":"Sad", "stressed":"Stressed"][rawValue]! }
    var symbol: String { ["amazing":"sun.max", "happy":"face.smiling", "neutral":"circle", "sad":"cloud.rain", "stressed":"bolt"][rawValue]! }
    var tint: Color { ["amazing":Color.orange, "happy":.green, "neutral":.gray, "sad":.blue, "stressed":.purple][rawValue]! }
    init(stored value: String?) {
        switch value ?? "" {
        case "great": self = .amazing
        case "good": self = .happy
        case "bad": self = .stressed
        default: self = JournalMood(rawValue:value ?? "") ?? .neutral
        }
    }
}

enum JournalDates {
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let isoPlain = ISO8601DateFormatter()
    /// Entry dates are ISO timestamps of local noon (or older plain YYYY-MM-DD).
    static func date(_ value: String) -> Date? {
        if let date = iso.date(from:value) ?? isoPlain.date(from:value) { return date }
        let parts = value.prefix(10).split(separator:"-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from:DateComponents(year:parts[0], month:parts[1], day:parts[2], hour:12))
    }
    /// The same encoding the Mac journal uses: the chosen day at local noon, in UTC.
    static func stored(_ day: Date) -> String {
        var parts = Calendar.current.dateComponents([.year, .month, .day], from:day); parts.hour = 12
        return iso.string(from:Calendar.current.date(from:parts) ?? day)
    }
}

enum JournalPhoto {
    /// Downscale like the Mac journal: 1600 px JPEG at 0.82, plus a 240 px thumbnail.
    static func encode(_ data: Data) throws -> (data: String, thumb: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw NotebookError.message("This file isn't a photo Notebook can read.") }
        func jpeg(_ size: Int, _ quality: Double) throws -> String {
            let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceCreateThumbnailWithTransform:true, kCGImageSourceThumbnailMaxPixelSize:size]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw NotebookError.message("This photo couldn't be read.") }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw NotebookError.message("This photo couldn't be saved.") }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality:quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw NotebookError.message("This photo couldn't be saved.") }
            return "data:image/jpeg;base64," + (output as Data).base64EncodedString()
        }
        return (try jpeg(1600, 0.82), try jpeg(240, 0.7))
    }
}

extension NotebookModel {
    /// Saves a photo as its own media record, as the Mac journal does, and
    /// returns its id and a displayable source for the editor.
    func addPhoto(_ data: Data, for item: NotebookItem? = nil) async throws -> (id: String, src: String) {
        // A photo in a shared note travels with the note, in its share.
        let store = item.map { self.store(for:$0) } ?? store
        return try await Task.detached(priority:.userInitiated) {
            let encoded = try JournalPhoto.encode(data)
            let id = UUID().uuidString.lowercased()
            _ = try store.setKey("app_journalMedia_" + id, value:["id":id, "createdAt":ISO8601DateFormatter().string(from:Date()), "kind":"image", "type":"image/jpeg", "data":encoded.data, "thumb":encoded.thumb])
            return (id, encoded.data)
        }.value
    }
    /// Small previews for list rows, read without loading the full photos.
    func thumbnails(_ ids: [String]) async -> [String:String] {
        let store = store
        return (try? await Task.detached(priority:.utility) { try store.mediaPreviews(ids) }.value) ?? [:]
    }
}

extension NotebookItem {
    /// The first photo or video in an entry, for its list thumbnail.
    var firstMediaID: String? {
        guard let match = content.range(of:#"data-media=["']([^"']+)["']"#, options:.regularExpression) else { return nil }
        return content[match].split(separator:"=", maxSplits:1).last.map { $0.trimmingCharacters(in:CharacterSet(charactersIn:"\"'")) }
    }
}
