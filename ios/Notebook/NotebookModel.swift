import Foundation
import SwiftUI
import LocalAuthentication
import NotebookCore

struct NotebookItem: Identifiable {
    /// Lists show thousands of these, so the plain-text preview is worked out
    /// once (when the content changes), not on every redraw.
    var raw: [String:Any] { didSet { if raw["content"] as? String != oldValue["content"] as? String { preview = Self.plainText(raw["content"] as? String ?? "") } } }
    private(set) var preview: String
    init(raw: [String:Any]) { self.raw = raw; preview = Self.plainText(raw["content"] as? String ?? "") }
    var id: String { raw["id"] as? String ?? "" }
    var title: String { raw["title"] as? String ?? "Untitled" }
    var content: String { raw["content"] as? String ?? "" }
    var date: String { raw["date"] as? String ?? raw["modifiedAt"] as? String ?? "" }
    var conflict: Bool { raw["_syncConflict"] as? Bool ?? false }
    var versions: Int { raw["_syncVersions"] as? Int ?? 1 }
    /// The first few hundred characters as plain text. A single pass, since
    /// regular expressions over a long note were the slowest part of a list.
    static func plainText(_ html: String) -> String {
        // Works on raw bytes: walking Characters was slower than the regex it replaced.
        var out = [UInt8](), inTag = false, space = false
        out.reserveCapacity(320)
        let bytes = Array(html.utf8)
        var i = 0
        let entities: [([UInt8], UInt8)] = [(Array("nbsp;".utf8), 32), (Array("amp;".utf8), 38), (Array("lt;".utf8), 60), (Array("gt;".utf8), 62), (Array("quot;".utf8), 34), (Array("#39;".utf8), 39)]
        while i < bytes.count, out.count < 300 {
            var c = bytes[i]; i += 1
            if inTag { if c == 62 { inTag = false; space = true }; continue }
            if c == 60 { inTag = true; continue }
            if c == 38, let match = entities.first(where: { i + $0.0.count <= bytes.count && Array(bytes[i..<i + $0.0.count]) == $0.0 }) { c = match.1; i += match.0.count }
            if c == 32 || c == 9 || c == 10 || c == 13 { space = true; continue }
            if space && !out.isEmpty { out.append(32) }
            space = false; out.append(c)
        }
        // A cut in the middle of a multi-byte character decodes as "�": drop it.
        var text = String(decoding:out, as:UTF8.self)
        while text.last == "\u{FFFD}" { text.removeLast() }
        return text
    }
}
@MainActor final class NotebookModel: ObservableObject {
    @Published var reloadVersion = 0
    /// False until the first read finishes, so lists show progress, not "empty".
    @Published private(set) var loaded = false
    private var lastStamp: String?
    @Published var notes: [NotebookItem] = []
    @Published var journal: [NotebookItem] = []
    @Published var error: String?
    @Published var syncMessage = "Saved on this device"
    @Published var connected = false
    @Published var syncing = false
    @Published var unlocked = false
    @Published var lockEnabled = UserDefaults.standard.bool(forKey:"notebook-lock")
    let store: RecordStore
    let cloud: CloudSync
    private var authenticating = false
    private var pollingTask: Task<Void,Never>?
    private var reloadTask: Task<Void,Never>?
    private var editing = 0
    private var agentInstance: AgentModel?
    var agent: AgentModel {
        if let agentInstance { return agentInstance }
        let value = AgentModel(notebook:self); agentInstance = value; return value
    }
    private var familyInstance: FamilyModel?
    var family: FamilyModel {
        if let familyInstance { return familyInstance }
        let value = FamilyModel(notebook:self); familyInstance = value; return value
    }
    private var linksInstance: LinksModel?
    var links: LinksModel {
        if let linksInstance { return linksInstance }
        let value = LinksModel(notebook:self); linksInstance = value; return value
    }
    private var newsInstance: NewsModel?
    var news: NewsModel {
        if let newsInstance { return newsInstance }
        let value = NewsModel(notebook:self); newsInstance = value; return value
    }
    /// Your Robinhood login on this device, for live quotes in Finance and Trading.
    let robinhood = RobinhoodLink()
    private var tradingInstance: TradingModel?
    var trading: TradingModel {
        if let tradingInstance { return tradingInstance }
        let value = TradingModel(notebook:self); tradingInstance = value; return value
    }
    private var exploreInstance: ExploreModel?
    var explore: ExploreModel {
        if let exploreInstance { return exploreInstance }
        let value = ExploreModel(notebook:self); exploreInstance = value; return value
    }
    private var moneyInstance: MoneyModel?
    var money: MoneyModel {
        if let moneyInstance { return moneyInstance }
        let value = MoneyModel(notebook:self); moneyInstance = value; return value
    }
    let shareLibrary: ShareLibrary
    private var sharingInstance: SharingModel?
    var sharing: SharingModel {
        if let sharingInstance { return sharingInstance }
        let value = SharingModel(notebook:self, library:shareLibrary, container:cloudContainer); sharingInstance = value; return value
    }
    private let cloudContainer: String
    private var documentsInstance: DocumentsModel?
    var documents: DocumentsModel {
        if let documentsInstance { return documentsInstance }
        let value = DocumentsModel(notebook:self); documentsInstance = value; return value
    }
    init(store: RecordStore) {
        self.store = store
        cloudContainer = Bundle.main.object(forInfoDictionaryKey:"NotebookCloudContainer") as? String ?? CloudSync.defaultContainer
        cloud = CloudSync(store:store,container:cloudContainer)
        shareLibrary = ShareLibrary(notebook:store)
        unlocked = !lockEnabled
        reload()
    }
    func reload() {
        guard editing == 0 else { return }
        reloadTask?.cancel()
        let store = store, library = shareLibrary, previous = lastStamp
        reloadTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority:.userInitiated) { () -> ([NotebookItem], [NotebookItem], Bool, String)? in
                    // Syncing every 20 seconds usually changes nothing: skip the read.
                    let stamp = try Self.stamp(store, library)
                    if stamp == previous { return nil }
                    return (try (store.records("notes").map { NotebookItem(raw:$0) } + Self.sharedNotes(library)).sorted { ($0.raw["modifiedAt"] as? String ?? "") > ($1.raw["modifiedAt"] as? String ?? "") },
                     try store.records("journal").map { NotebookItem(raw:$0) },
                     try store.metadata("notebook") != nil, stamp)
                }.value
                guard !Task.isCancelled, let self, self.editing == 0 else { return }
                guard let result else { self.loaded = true; return }
                self.notes = result.0; self.journal = result.1; self.connected = result.2; self.lastStamp = result.3
                self.loaded = true
                self.reloadVersion += 1
            } catch { if !Task.isCancelled { self?.error = error.localizedDescription } }
        }
    }
    /// What the notebook and its shared notes look like now, cheaply.
    nonisolated static func stamp(_ store: RecordStore, _ library: ShareLibrary) throws -> String {
        let shares = library.shares().filter { $0.kind == "note" }
        return try ([store.changeStamp(), store.metadata("notebook") ?? ""] + shares.map { "\($0.id):\($0.ready):\($0.canEdit):" + ((try? library.store($0.id).changeStamp()) ?? "") }).joined(separator:"|")
    }
    /// Notes shared with or by you, each marked with its share. Their IDs are
    /// prefixed so they can't collide with a note in your own notebook.
    nonisolated static func sharedNotes(_ library: ShareLibrary) -> [NotebookItem] {
        library.shares().filter { $0.kind == "note" && $0.ready }.flatMap { info -> [NotebookItem] in
            ((try? library.store(info.id).records("notes", entity:info.entity)) ?? []).map { record in
                var raw = record
                raw["id"] = "share:" + info.id + ":" + (record["id"] as? String ?? "")
                raw["_syncShare"] = info.id; raw["_syncShareEdit"] = info.owner || info.canEdit; raw["_syncShareOwner"] = info.owner
                return NotebookItem(raw:raw)
            }
        }
    }
    /// Where an item's records live: its share, or the private notebook.
    func store(for item: NotebookItem) -> RecordStore { item.share.flatMap { try? shareLibrary.store($0) } ?? store }
    func beginEditing() { editing += 1; reloadTask?.cancel() }
    func endEditing() { editing = max(0,editing-1); if editing == 0 { reload(); Task { await sync() } } }
    func newItem(kind: String, template: NoteTemplate? = nil) -> NotebookItem {
        let now = ISO8601DateFormatter().string(from:Date())
        return NotebookItem(raw:["id":UUID().uuidString.lowercased(),"title":template?.name ?? "","content":template?.html ?? "","date":now,"createdAt":now,"modifiedAt":now,"tags":[String](),"mood":"neutral"])
    }
    func delete(_ item: NotebookItem, kind: String) {
        // Deleting a shared note ends the share for everyone; someone else's is left.
        if let info = sharing.share(item.share) {
            Task { if info.owner { await sharing.stop(info, keep:false) } else { await sharing.leave(info) } }
            return
        }
        do { try store.delete(kind:kind,record:item.raw); reload() }
        catch { self.error = error.localizedDescription }
    }
    func sync() async {
        guard !syncing, editing == 0, unlocked else { return }
        // An unsigned build can't reach iCloud. Don't try: a failed attempt
        // records an error in the shared database that other apps display.
        guard CloudSync.provisioned(container:await cloud.containerID) else { syncMessage = "Saved on this device"; return }
        syncing = true; defer { syncing = false }
        await agent.fetchFamilyPolicy(container:await cloud.containerID)
        do {
            let status = try await cloud.status()
            connected = status["linked"] as? Bool ?? false
            if connected { syncMessage = "Syncing…"; try await cloud.sync() }
            let current = try await cloud.status()
            syncMessage = current["message"] as? String ?? "Saved on this device"
            reload()
        } catch { syncMessage = error.localizedDescription }
        await sharing.syncNow()
    }
    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for:.seconds(20))
            }
        }
    }
    func background() {
        pollingTask?.cancel(); pollingTask = nil
        agentInstance?.cancel(); DocumentsModel.clearTemporaryCopies()
        if lockEnabled { unlocked = false; agentInstance?.locked(); newsInstance?.locked(); tradingInstance?.locked() }
    }
    func unlock() async {
        guard !authenticating else { return }
        authenticating = true; defer { authenticating = false }
        do {
            let context = LAContext(); context.localizedCancelTitle = "Cancel"
            unlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication,localizedReason:"Unlock your private Notebook.")
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            // Cancelled, by the person or by the system (the Mac locking its
            // screen, or another app taking over): the lock screen stays up with
            // its Unlock button, so there's nothing to report.
        } catch { if !unlocked { self.error = error.localizedDescription } }
    }
    func setProtection(_ enabled: Bool) async {
        let context = LAContext()
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication,localizedReason:enabled ? "Protect Notebook with Face ID, Touch ID, or your device passcode." : "Turn off Notebook protection.") else { return }
            lockEnabled = enabled; unlocked = true
            UserDefaults.standard.set(enabled,forKey:"notebook-lock")
        } catch { self.error = error.localizedDescription }
    }
    /// Fetch only attachments referenced by this editor, once, away from the UI.
    func media(for html: String, in item: NotebookItem? = nil) async -> [String:String] {
        let store = item.map { self.store(for:$0) } ?? store
        do {
            return try await Task.detached(priority:.userInitiated) {
                let regex = try NSRegularExpression(pattern:"data-media=[\"']([^\"']+)[\"']")
                let source = html as NSString
                let ids = Set(regex.matches(in:html,range:NSRange(location:0,length:source.length)).map { source.substring(with:$0.range(at:1)) })
                var media: [String:String] = [:]
                for id in ids {
                    if let record = try store.getKey("app_journalMedia_" + id) as? [String:Any], let data = record["data"] as? String { media[id] = data }
                }
                return media
            }.value
        } catch { self.error = error.localizedDescription; return [:] }
    }
}

/// One editor owns its draft and causal revision. Saves are coalesced and run
/// off the main actor; a completed save must never replace newer typed text.
@MainActor final class NotebookDraft: ObservableObject {
    @Published var item: NotebookItem
    @Published private(set) var status = "Saved on this device"
    @Published private(set) var failed = false
    private let store: RecordStore
    private let kind: String
    private var generation = 0
    private var persisted = 0
    private var debounce: Task<Void,Never>?
    private var writer: Task<Void,Never>?
    private var resolveNext = false
    /// Called after each successful save, so a list shown beside the editor can refresh.
    var onSaved: (() -> Void)?
    init(item: NotebookItem, kind: String, store: RecordStore) { self.item=item; self.kind=kind; self.store=store }
    func change(_ field: String, _ value: Any) {
        item.raw[field] = value
        generation += 1; failed=false; status="Saving…"
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(300)) } catch { return }
            await self?.flush()
        }
    }
    func resolve() async { resolveNext=true; generation += 1; await flush() }
    func flush() async {
        debounce?.cancel(); debounce=nil
        while let current = writer { await current.value; if failed { return } }
        guard persisted < generation else { return }
        // Assign before awaiting, so all callers share one in-flight writer.
        writer = Task { [self] in
            while persisted < generation {
                let savingGeneration=generation, resolving=resolveNext
                var snapshot=item.raw
                snapshot["modifiedAt"] = ISO8601DateFormatter().string(from:Date())
                let store=store, kind=kind
                do {
                    let result = try await Task.detached(priority:.userInitiated) {
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                           let value=ProcessInfo.processInfo.environment["NOTEBOOK_TEST_SAVE_DELAY_MS"], let delay=Double(value) {
                            Thread.sleep(forTimeInterval:min(max(delay,0),2000)/1000)
                        }
                        #endif
                        return try store.save(kind:kind,record:snapshot,resolve:resolving)
                    }.value
                    // Keep the latest content/title/tags, but advance the parents
                    // for the next save. Remote versions remain separate heads.
                    for key in ["_syncHeads","_syncAllHeads","_syncEntity","modifiedAt"] { item.raw[key]=result[key] }
                    persisted=savingGeneration; if resolving {resolveNext=false}
                    failed=false; status=persisted == generation ? "Saved on this device" : "Saving…"
                    onSaved?()
                } catch { failed=true; status="Could not save: " + error.localizedDescription; break }
            }
            writer=nil
        }
        await writer?.value
    }
}
