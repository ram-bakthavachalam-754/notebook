import Foundation
import NotebookCore

/// One record of the `links` kind: a saved web link, or a collection links
/// belong to (`type` is "link" or "collection").
struct LinkItem: Identifiable, Equatable {
    var raw: [String:Any]
    var id: String { raw["id"] as? String ?? "" }
    var isCollection: Bool { raw["type"] as? String == "collection" }
    var url: String { raw["url"] as? String ?? "" }
    var title: String { (raw["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host }
    var name: String { raw["name"] as? String ?? "Untitled" }
    var site: String { (raw["site"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host }
    var host: String { URL(string:url)?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url }
    var note: String { raw["note"] as? String ?? "" }
    var tags: [String] { raw["tags"] as? [String] ?? [] }
    var collection: String? { raw["collectionId"] as? String }
    var savedBy: String { raw["savedBy"] as? String ?? "" }
    var createdAt: String { raw["createdAt"] as? String ?? "" }
    var modifiedAt: String { raw["modifiedAt"] as? String ?? createdAt }
    /// The share a link or collection lives in, if it's shared.
    var share: String? { raw["_syncShare"] as? String }
    var editable: Bool { share == nil || raw["_syncShareEdit"] as? Bool == true }
    var sharedWithMe: Bool { share != nil && raw["_syncShareOwner"] as? Bool != true }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.modifiedAt == rhs.modifiedAt }
}

/// Links and collections. They sync like notes, one record per link, so they
/// work offline. A link edited on two devices at once keeps the newest edit:
/// a title or a tag isn't prose worth keeping two versions of.
@MainActor final class LinksModel: ObservableObject {
    @Published var links: [LinkItem] = []
    @Published var collections: [LinkItem] = []
    @Published var error: String?
    @Published private(set) var loaded = false
    private weak var notebook: NotebookModel?
    private let store: RecordStore
    private let web = AgentWebTransport()
    init(notebook: NotebookModel) { self.notebook = notebook; store = notebook.store; reload() }
    private func checkAccess() throws { guard notebook?.unlocked == true else { throw NotebookError.message("Unlock Notebook to continue.") } }
    func reload() {
        guard notebook?.unlocked == true else { links = []; collections = []; return }
        let store = store, library = notebook?.shareLibrary
        Task { [weak self] in
            do {
                let rows = try await Task.detached(priority:.userInitiated) {
                    var rows = try store.records("links")
                    // Shared collections, each record marked with its share.
                    for info in library?.shares() ?? [] where info.kind == "links" && info.ready {
                        for var row in (try? library?.store(info.id).records("links")) ?? [] {
                            row["_syncShare"] = info.id; row["_syncShareEdit"] = info.owner || info.canEdit; row["_syncShareOwner"] = info.owner
                            rows.append(row)
                        }
                    }
                    return rows
                }.value
                // Show one version of each record: the most recently changed.
                var newest: [String:[String:Any]] = [:]
                for row in rows {
                    let entity = (row["_syncShare"] as? String ?? "") + "/" + (row["_syncEntity"] as? String ?? row["id"] as? String ?? "")
                    if let kept = newest[entity], (kept["modifiedAt"] as? String ?? "") >= (row["modifiedAt"] as? String ?? "") { continue }
                    newest[entity] = row
                }
                let items = newest.values.map(LinkItem.init)
                self?.collections = items.filter(\.isCollection).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self?.links = items.filter { !$0.isCollection }.sorted { $0.createdAt > $1.createdAt }
                self?.loaded = true
            } catch { self?.error = error.localizedDescription }
        }
    }
    /// The store a share's records live in, or the private notebook's.
    private func store(_ share: String?) throws -> RecordStore {
        guard let share else { return store }
        guard let library = notebook?.shareLibrary, let info = library.share(share) else { throw NotebookError.message("This collection is no longer shared with you.") }
        return try library.store(info.id)
    }
    /// The stored record behind an item, in whichever store holds it.
    private func current(_ item: LinkItem) throws -> [String:Any]? {
        guard var row = try store(item.share).records("links", entity:item.raw["_syncEntity"] as? String ?? item.id).first else { return nil }
        for key in ["_syncShare", "_syncShareEdit", "_syncShareOwner"] { row[key] = item.raw[key] }
        return row
    }
    /// Saves a record over every version on this device, then syncs.
    private func write(_ raw: [String:Any]) throws {
        try checkAccess()
        if raw["_syncShare"] != nil, raw["_syncShareEdit"] as? Bool != true { throw NotebookError.message("This collection is view only.") }
        var record = raw; record["modifiedAt"] = ISO8601DateFormatter().string(from:Date())
        try store(raw["_syncShare"] as? String).save(kind:"links", record:record, resolve:true)
        reload()
        Task { await notebook?.sync() }
    }
    private static var deviceName: String {
        #if os(macOS)
        NSFullUserName().isEmpty ? (Host.current().localizedName ?? "Mac") : NSFullUserName()
        #else
        "iPhone"
        #endif
    }
    /// Adds a link, then fills in the page's title and site name from the web.
    @discardableResult func add(_ address: String, collection: String?) async -> LinkItem? {
        var text = address.trimmingCharacters(in:.whitespacesAndNewlines)
        if !text.isEmpty, !text.contains("://") { text = "https://" + text }
        guard let url = URL(string:text), ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else {
            error = "Enter a web address that starts with http or https."; return nil
        }
        if let existing = links.first(where: { $0.url == url.absoluteString && $0.collection == collection }) { return existing }
        let now = ISO8601DateFormatter().string(from:Date())
        var raw: [String:Any] = ["id":UUID().uuidString.lowercased(), "type":"link", "url":url.absoluteString, "title":"", "site":"", "note":"", "tags":[String](), "savedBy":Self.deviceName, "createdAt":now]
        if let collection {
            raw["collectionId"] = collection
            // A link added to a shared collection goes into that share.
            if let folder = collections.first(where: { $0.id == collection }), let share = folder.share {
                raw["_syncShare"] = share; raw["_syncShareEdit"] = folder.editable; raw["_syncShareOwner"] = !folder.sharedWithMe
            }
        }
        do { try write(raw) } catch { self.error = error.localizedDescription; return nil }
        let saved = LinkItem(raw:raw)
        if let details = await pageDetails(url.absoluteString), let current = try? current(saved) {
            var updated = current
            // Keep anything the person typed while the page was loading.
            if (updated["title"] as? String ?? "").isEmpty { updated["title"] = details.title }
            if (updated["site"] as? String ?? "").isEmpty { updated["site"] = details.site }
            try? write(updated)
        }
        return links.first { $0.id == saved.id } ?? saved
    }
    /// The page's title and site name, read with the agent's safe web reader
    /// (public addresses only, checked redirects).
    func pageDetails(_ address: String) async -> (title: String, site: String)? {
        guard let page = try? await web.read(address, maxBytes:300_000, truncate:true), page.contentType.contains("html") else { return nil }
        func meta(_ property: String) -> String? {
            for pattern in [#"<meta[^>]+(?:property|name)=["']\#(property)["'][^>]*content=["']([^"']*)["']"#, #"<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']\#(property)["']"#] {
                if let regex = try? NSRegularExpression(pattern:pattern, options:.caseInsensitive),
                   let match = regex.firstMatch(in:page.body, range:NSRange(page.body.startIndex..., in:page.body)),
                   let range = Range(match.range(at:1), in:page.body) { return Self.decode(String(page.body[range])) }
            }
            return nil
        }
        var title = meta("og:title") ?? ""
        if title.isEmpty, let start = page.body.range(of:"<title", options:.caseInsensitive),
           let open = page.body[start.upperBound...].firstIndex(of:">"),
           let end = page.body.range(of:"</title>", options:.caseInsensitive, range:open..<page.body.endIndex) {
            title = Self.decode(String(page.body[page.body.index(after:open)..<end.lowerBound]))
        }
        let site = meta("og:site_name") ?? ""
        guard !title.isEmpty || !site.isEmpty else { return nil }
        return (String(title.prefix(300)), String(site.prefix(100)))
    }
    private static func decode(_ text: String) -> String {
        var value = text
        for (entity, character) in [("&amp;","&"), ("&quot;","\""), ("&#39;","'"), ("&#x27;","'"), ("&apos;","'"), ("&lt;","<"), ("&gt;",">"), ("&nbsp;"," "), ("&ndash;","–"), ("&mdash;","—")] { value = value.replacingOccurrences(of:entity, with:character) }
        return value.components(separatedBy:.whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator:" ")
    }
    func update(_ item: LinkItem, title: String? = nil, note: String? = nil, tags: [String]? = nil, collection: String?? = nil) {
        // Always edit what's stored: a link deleted meanwhile stays deleted.
        guard var raw = try? current(item) else { return }
        if let title { raw["title"] = title }
        if let note { raw["note"] = note }
        if let tags { raw["tags"] = tags }
        if let collection { if let value = collection { raw["collectionId"] = value } else { raw.removeValue(forKey:"collectionId") } }
        do {
            var target: LinkItem?
            if let collection, let id = collection { target = collections.first { $0.id == id } }
            let destination: String? = collection == nil ? item.share : target?.share
            if destination != item.share {
                // Moving into or out of a shared collection moves the link to that store.
                var moved = ShareLibrary.fresh(raw)
                if let target, let share = target.share { moved["_syncShare"] = share; moved["_syncShareEdit"] = target.editable; moved["_syncShareOwner"] = !target.sharedWithMe }
                try write(moved)
                try remove(raw, from:item.share)
            } else { try write(raw) }
        } catch { self.error = error.localizedDescription }
    }
    /// One deletion that replaces every version of the record.
    private func remove(_ row: [String:Any], from share: String?) throws {
        if share != nil, row["_syncShareEdit"] as? Bool != true { throw NotebookError.message("This collection is view only.") }
        var row = row; row["_syncHeads"] = row["_syncAllHeads"]
        try store(share).delete(kind:"links", record:row)
    }
    #if os(iOS)
    private var importing = false
    /// Adds the links saved from the share sheet since Notebook was last open.
    func importInbox() async {
        guard notebook?.unlocked == true, !importing else { return }
        importing = true; defer { importing = false }
        for (entry, file) in LinkInbox.pending() {
            if let saved = await add(entry.url, collection:nil) {
                // The page's own title wins; Safari's is the fallback. A note never replaces one already there.
                let title = (saved.raw["title"] as? String ?? "").isEmpty && !entry.title.isEmpty ? entry.title : nil
                let note = saved.note.isEmpty && !entry.note.isEmpty ? entry.note : nil
                if title != nil || note != nil { update(saved, title:title, note:note) }
            } else if notebook?.unlocked != true { return }
            else { error = nil }
            try? FileManager.default.removeItem(at:file)
        }
    }
    #endif
    @discardableResult func addCollection(_ name: String) -> LinkItem? {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let raw: [String:Any] = ["id":UUID().uuidString.lowercased(), "type":"collection", "name":trimmed, "createdAt":ISO8601DateFormatter().string(from:Date())]
        do { try write(raw); return LinkItem(raw:raw) } catch { self.error = error.localizedDescription; return nil }
    }
    func rename(_ collection: LinkItem, to name: String) {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty, var raw = try? current(collection) else { return }
        raw["name"] = trimmed
        do {
            try write(raw)
            if let share = collection.share, let library = notebook?.shareLibrary, library.share(share)?.owner == true {
                try library.update(share) { $0.title = trimmed }
                Task { [sync = notebook?.sharing.sync] in try? await sync?.updateDetails(share) }
            }
        } catch { self.error = error.localizedDescription }
    }
    /// Deletes a link, or a collection; a collection's links move to Unsorted.
    /// A shared collection is deleted for everyone (or left, if it's someone else's).
    func delete(_ item: LinkItem) {
        do {
            try checkAccess()
            if item.isCollection, let share = item.share, let sharing = notebook?.sharing, let info = sharing.share(share) {
                Task { if info.owner { await sharing.stop(info, keep:false) } else { await sharing.leave(info) }; reload() }
                return
            }
            if item.isCollection {
                for row in try store.records("links") where row["collectionId"] as? String == item.id { update(LinkItem(raw:row), collection:.some(nil)) }
            }
            if let row = try current(item) { try remove(row, from:item.share) }
            reload()
            Task { await notebook?.sync() }
        } catch { self.error = error.localizedDescription }
    }
}
