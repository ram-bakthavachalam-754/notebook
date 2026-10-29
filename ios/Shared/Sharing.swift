import SwiftUI
import CloudKit
import NotebookCore

extension Notification.Name {
    /// Shared items arrived, changed or went away; lists re-read them.
    static let notebookSharesChanged = Notification.Name("notebookSharesChanged")
    /// Finance deleted an account (the object is its ID).
    static let notebookAccountDeleted = Notification.Name("notebookAccountDeleted")
}

/// Shared notes, links collections and view-only accounts. Each lives in its
/// own store and iCloud zone (see `ShareLibrary`); this model is what the
/// screens talk to.
@MainActor final class SharingModel: ObservableObject {
    @Published private(set) var shares: [ShareInfo] = []
    @Published var notices: [String] = []
    @Published var error: String?
    @Published private(set) var status: String?
    @Published var busy = false
    let library: ShareLibrary
    let sync: ShareSync
    private weak var notebook: NotebookModel?
    #if DEBUG
    /// Tests share without iCloud: everything but the upload happens.
    var localOnly = false
    #endif
    init(notebook: NotebookModel, library: ShareLibrary, container: String) {
        self.notebook = notebook; self.library = library
        sync = ShareSync(library:library, container:container)
        reload()
        observer = NotificationCenter.default.addObserver(forName:.notebookAccountDeleted, object:nil, queue:.main) { [weak self] note in
            guard let id = note.object as? String else { return }
            MainActor.assumeIsolated { if let self, let info = self.share(kind:"account", entity:id), info.owner { Task { await self.stop(info) } } }
        }
    }
    private var observer: NSObjectProtocol?
    var available: Bool {
        #if DEBUG
        if localOnly { return true }
        #endif
        return CloudSync.provisioned(container:sync.containerID)
    }
    func reload() {
        shares = library.shares()
        notices = library.notices()
        status = try? library.notebook.metadata("share-error")
    }
    func share(_ id: String?) -> ShareInfo? { id.flatMap { id in shares.first { $0.id == id } } }
    func share(kind: String, entity: String) -> ShareInfo? { shares.first { $0.kind == kind && $0.entity == entity } }
    func dismissNotices() { library.clearNotices(); notices = [] }
    private func changed() {
        reload()
        NotificationCenter.default.post(name:.notebookSharesChanged, object:nil)
        notebook?.reload()
    }
    func syncNow() async {
        guard available else { return }
        let before = library.shares()
        _ = await sync.sync()
        if library.shares() != before || library.notices() != notices { changed() } else { reload() }
    }

    // MARK: Who may share with whom
    private var kidPolicy: [String:Any]? { notebook?.agent.kidMode == true ? notebook?.agent.policy : nil }
    /// Kids share notes and links only, and only as their parent allows.
    func canShare(_ kind: String) -> Bool {
        guard let policy = kidPolicy else { return true }
        return kind != "account" && (policy["sharing"] as? [String:Any])?["mode"] as? String ?? "family" != "off"
    }
    /// Whether a child may share with, or accept from, this Apple Account.
    nonisolated static func allowed(_ email: String, policy: [String:Any]?) -> Bool {
        guard let policy, policy["managed"] as? Bool == true else { return true }
        let sharing = policy["sharing"] as? [String:Any] ?? [:]
        switch sharing["mode"] as? String ?? "family" {
        case "anyone": return true
        case "off": return false
        default: return !email.isEmpty && (sharing["family"] as? [String] ?? []).contains(email.lowercased())
        }
    }
    private func ownerName() -> String {
        #if os(macOS)
        NSFullUserName()
        #else
        ""
        #endif
    }

    // MARK: Sharing something
    /// Moves a note (and the photos in it) into a new share. The private copy
    /// is removed only once the share exists in iCloud.
    func shareNote(_ item: NotebookItem) async -> ShareInfo? {
        guard let notebook, item.share == nil else { return share(item.share) }
        let entity = item.raw["_syncEntity"] as? String ?? item.id
        return await create(kind:"note", entity:entity, title:item.title.isEmpty ? "Untitled" : item.title) {
            let store = notebook.store
            let versions = try store.records("notes", entity:entity)
            guard let current = versions.first else { throw NotebookError.message("Save the note before sharing it.") }
            guard versions.count == 1 else { throw NotebookError.message("This note has two versions. Keep one of them, then share it.") }
            var records: [(kind: String, record: [String:Any])] = [("notes", current)]
            for id in Self.mediaIDs(current["content"] as? String ?? "") {
                if let media = try store.records("media", entity:id).first { records.append(("media", media)) }
            }
            return records
        } removePrivate: {
            for row in try notebook.store.records("notes", entity:entity) { var row = row; row["_syncHeads"] = row["_syncAllHeads"]; try notebook.store.delete(kind:"notes", record:row); break }
        }
    }
    /// Moves a links collection and its links into a new share.
    func shareCollection(_ collection: LinkItem) async -> ShareInfo? {
        guard let notebook, collection.share == nil else { return share(collection.share) }
        let store = notebook.store
        return await create(kind:"links", entity:collection.id, title:collection.name) {
            try store.records("links").filter { ($0["_syncEntity"] as? String) == collection.id || $0["collectionId"] as? String == collection.id }
                .reduce(into:[String:[String:Any]]()) { newest, row in
                    let entity = row["_syncEntity"] as? String ?? ""
                    if (newest[entity]?["modifiedAt"] as? String ?? "") <= (row["modifiedAt"] as? String ?? "") { newest[entity] = row }
                }.values.map { ("links", $0) }
        } removePrivate: {
            var done = Set<String>()
            for row in try store.records("links") where (row["_syncEntity"] as? String) == collection.id || row["collectionId"] as? String == collection.id {
                guard done.insert(row["_syncEntity"] as? String ?? "").inserted else { continue }
                var row = row; row["_syncHeads"] = row["_syncAllHeads"]; try store.delete(kind:"links", record:row)
            }
        }
    }
    /// Shares a view of an account at a level. The account itself stays in
    /// your Finance; the share holds only what the level shows.
    func shareAccount(_ account: FinanceRow, level: String, view: [String:Any]) async -> ShareInfo? {
        guard canShare("account") else { return nil }
        return await create(kind:"account", entity:account.id, title:account.name, level:level) { [("accountViews", view)] } removePrivate: { }
    }
    private func create(kind: String, entity: String, title: String, level: String = "", records: () throws -> [(kind: String, record: [String:Any])], removePrivate: () throws -> Void) async -> ShareInfo? {
        guard canShare(kind) else { error = "A parent's setting doesn't allow sharing."; return nil }
        guard available else { error = "Sharing needs iCloud. This copy of Notebook isn't signed for iCloud, so it can't share yet."; return nil }
        busy = true; defer { busy = false }
        var created: ShareInfo?
        do {
            let info = try library.create(kind:kind, entity:entity, title:title, ownerName:ownerName(), level:level, records:try records())
            created = info
            #if DEBUG
            if !localOnly { try await sync.publish(info.id) }
            #else
            try await sync.publish(info.id)
            #endif
            try removePrivate()
            changed()
            Task { await syncNow() }
            return library.share(info.id)
        } catch {
            // Nothing left half-shared: the private item was never touched.
            if let created, !(library.share(created.id)?.published ?? false) { try? library.remove(created.id) }
            self.error = error.localizedDescription; changed(); return nil
        }
    }
    nonisolated static func mediaIDs(_ html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern:"data-media=[\"']([^\"']+)[\"']") else { return [] }
        let text = html as NSString
        return Array(Set(regex.matches(in:html, range:NSRange(location:0, length:text.length)).map { text.substring(with:$0.range(at:1)) })).sorted()
    }

    // MARK: Managing a share
    func addPerson(_ info: ShareInfo, email: String, canEdit: Bool) async -> URL? {
        guard Self.allowed(email, policy:kidPolicy) else { error = "A parent's setting allows sharing only with the family's Apple Accounts."; return nil }
        busy = true; defer { busy = false }
        do { let url = try await sync.addPerson(info.id, email:email, canEdit:canEdit); reload(); return url }
        catch { self.error = error.localizedDescription; reload(); return nil }
    }
    func removePerson(_ info: ShareInfo, _ person: SharePerson) async {
        busy = true; defer { busy = false }
        do { try await sync.removePerson(info.id, email:person.email) } catch { self.error = error.localizedDescription }
        reload()
    }
    func inviteURL(_ info: ShareInfo) async -> URL? { try? await sync.inviteURL(info.id) }
    func setLevel(_ info: ShareInfo, _ level: String) async {
        do {
            try library.update(info.id) { $0.level = level }
            NotificationCenter.default.post(name:.notebookSharesChanged, object:nil)
            try await sync.updateDetails(info.id)
        } catch { self.error = error.localizedDescription }
        reload()
    }
    /// Ends a share for everyone. A note or collection comes back into your
    /// notebook unless `keep` is false (deleting it).
    func stop(_ info: ShareInfo, keep: Bool = true) async {
        busy = true; defer { busy = false }
        do {
            if keep, info.kind != "account" { _ = try library.restore(info.id) }
            #if DEBUG
            if localOnly { try library.remove(info.id) } else { try await sync.stop(info.id) }
            #else
            try await sync.stop(info.id)
            #endif
        } catch { self.error = error.localizedDescription }
        changed()
        Task { await notebook?.sync() }
    }
    /// Removes someone else's item from your notebook. They keep it.
    func leave(_ info: ShareInfo) async {
        busy = true; defer { busy = false }
        do {
            #if DEBUG
            if localOnly { try library.remove(info.id) } else { try await sync.leave(info.id) }
            #else
            try await sync.leave(info.id)
            #endif
        } catch { self.error = error.localizedDescription }
        changed()
    }
    func accept(url: URL) async {
        await accepting { [policy = kidPolicy] in try await self.sync.accept(url:url, allowed:{ Self.allowed($0, policy:policy) }) }
    }
    func accept(_ metadata: CKShare.Metadata) async {
        await accepting { [policy = kidPolicy] in try await self.sync.accept(metadata, allowed:{ Self.allowed($0, policy:policy) }) }
    }
    private func accepting(_ body: () async throws -> ShareInfo) async {
        if kidPolicy.map({ (($0["sharing"] as? [String:Any])?["mode"] as? String) == "off" }) == true { error = "A parent's setting doesn't allow shared items."; return }
        busy = true; defer { busy = false }
        do { _ = try await body(); changed() } catch { self.error = error.localizedDescription }
    }
}

extension NotebookItem {
    /// The share this item lives in, if it's shared.
    var share: String? { raw["_syncShare"] as? String }
    var readOnly: Bool { share != nil && raw["_syncShareEdit"] as? Bool != true }
    /// Someone else's note, shown under Shared with You.
    var sharedWithMe: Bool { share != nil && raw["_syncShareOwner"] as? Bool != true }
}

/// "Shared with Partner" or "From Partner · View only", for lists and editors.
func shareLine(_ info: ShareInfo) -> String {
    if info.owner {
        let names = info.people.filter { $0.status != "removed" }.map { $0.name.isEmpty ? $0.email : $0.name }
        return names.isEmpty ? "Shared · nobody added yet" : "Shared with " + ListFormatter.localizedString(byJoining:names)
    }
    return "From \(info.ownerName.isEmpty ? "someone" : info.ownerName) · " + (info.canEdit ? "Can edit" : "View only")
}

/// The share sheet for one item: start sharing, add people, send the
/// invitation link, stop sharing; or for someone else's item, leave it.
struct ShareSheet: View {
    @ObservedObject var sharing: SharingModel
    /// The note, collection or account, as "note"/"links"/"account".
    let kind: String
    let title: String
    let existing: String?
    /// Creates the share; returns it, or nil when it couldn't.
    let start: (_ level: String) async -> ShareInfo?
    var onStopped: () -> Void = { }
    @Environment(\.dismiss) private var dismiss
    @State private var shareID: String?
    @State private var email = ""
    @State private var canEdit = true
    @State private var level = "holdings"
    @State private var invite: URL?
    @State private var confirmStop = false
    private var info: ShareInfo? { sharing.share(shareID ?? existing) }
    var body: some View {
        NavigationStack {
            Form {
                if let info, !info.owner {
                    Section {
                        LabeledContent("From", value:info.ownerName.isEmpty ? "Someone" : info.ownerName)
                        LabeledContent("You", value:info.canEdit ? "Can edit" : "View only")
                    } footer: { Text("Leaving removes it from your notebook. \(info.ownerName.isEmpty ? "The owner" : info.ownerName) and anyone else on it keep it.") }
                    Section { Button("Leave", role:.destructive) { Task { await sharing.leave(info); onStopped(); dismiss() } } }
                } else if let info {
                    people(info)
                    if kind == "account" { levelPicker(info) }
                    Section {
                        if let invite { ShareLink(item:invite, subject:Text(title), message:Text("I shared “\(title)” with you in Notebook.")) { Label("Send Invitation Link…", systemImage:"paperplane") } }
                        Button("Stop Sharing", role:.destructive) { confirmStop = true }
                    } footer: { Text(kind == "account" ? "Stopping removes the view from everyone else's Finance. Your account isn't changed." : "Stopping removes it for everyone else and keeps it in your notebook.") }
                } else {
                    Section {
                        Text(kind == "account" ? "People you add see this account in their Finance under Shared Accounts, view only. It never counts in their totals." : "People you add see this \(kind == "note" ? "note" : "collection") in their notebook and can edit it if you let them. It's encrypted so only people on it can read it.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if kind == "account" { levelPicker(nil) }
                    Section { Button("Share") { Task { if let created = await start(level) { shareID = created.id } } }.disabled(sharing.busy || !sharing.available) }
                    if !sharing.available { Text("Sharing needs iCloud. This copy of Notebook isn't signed for iCloud yet.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share “\(title)”")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
            .task(id:info?.id) { if let info, info.owner { invite = await sharing.inviteURL(info) } }
            .confirmationDialog("Stop sharing “\(title)”?", isPresented:$confirmStop, titleVisibility:.visible) {
                Button("Stop Sharing", role:.destructive) { if let info { Task { await sharing.stop(info); onStopped(); dismiss() } } }
            } message: { Text("Everyone else loses access straight away.") }
            .alert("Sharing", isPresented:Binding(get:{ sharing.error != nil }, set:{ if !$0 { sharing.error = nil } })) { } message: { Text(sharing.error ?? "") }
            .overlay { if sharing.busy { ProgressView() } }
        }
        #if os(macOS)
        .frame(minWidth:440, minHeight:380)
        #endif
    }
    @ViewBuilder private func people(_ info: ShareInfo) -> some View {
        Section {
            ForEach(info.people, id:\.self) { person in
                HStack {
                    VStack(alignment:.leading) {
                        Text(person.name.isEmpty ? person.email : person.name)
                        Text([person.name.isEmpty ? nil : person.email, person.canEdit ? "Can edit" : "View only", person.status == "pending" ? "Invited" : nil].compactMap { $0 }.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await sharing.removePerson(info, person) } } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless).help("Remove")
                }
            }
            TextField("Apple Account email", text:$email)
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                #endif
            if kind != "account" {
                Picker("Permission", selection:$canEdit) { Text("Can edit").tag(true); Text("View only").tag(false) }
            }
            Button("Add Person") {
                let address = email
                Task { if let url = await sharing.addPerson(info, email:address, canEdit:canEdit && kind != "account") { invite = url; email = "" } }
            }
            .disabled(!email.contains("@") || sharing.busy)
        } header: { Text("People") } footer: { Text("After adding someone, send them the invitation link. They open it on a device with Notebook.") }
    }
    private func levelPicker(_ info: ShareInfo?) -> some View {
        Section {
            Picker("Level", selection:Binding(get:{ info?.level ?? level }, set:{ value in level = value; if let info { Task { await sharing.setLevel(info, value) } } })) {
                Text("Balance only").tag("balance"); Text("Balance and holdings").tag("holdings"); Text("Holdings and transactions").tag("transactions")
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #else
            .pickerStyle(.inline).labelsHidden()
            #endif
        } header: { Text("What they see") } footer: {
            Text("Never your other accounts, net worth, notes or strategies. Lowering the level hides those details from then on; Stop Sharing removes everything they received.")
        }
    }
}

/// Settings → Sharing: what you've shared, what's shared with you, and a
/// place to open an invitation link.
struct SharingSettings: View {
    @ObservedObject var sharing: SharingModel
    @State private var link = ""
    var body: some View {
        Form {
            if !sharing.notices.isEmpty {
                Section {
                    ForEach(sharing.notices, id:\.self) { Text($0) }
                    Button("Dismiss") { sharing.dismissNotices() }
                }
            }
            Section("Shared by you") {
                let mine = sharing.shares.filter(\.owner)
                if mine.isEmpty { Text("Nothing yet. Use Share on a note, a links collection or an account.").foregroundStyle(.secondary) }
                ForEach(mine) { info in row(info) }
            }
            Section("Shared with you") {
                let theirs = sharing.shares.filter { !$0.owner }
                if theirs.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                ForEach(theirs) { info in
                    row(info).contextMenu { Button("Leave", role:.destructive) { Task { await sharing.leave(info) } } }
                }
            }
            Section {
                TextField("Paste an invitation link", text:$link)
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                Button("Open Invitation") {
                    guard let url = URL(string:link.trimmingCharacters(in:.whitespacesAndNewlines)), url.scheme == "https" else { sharing.error = "That isn't an invitation link."; return }
                    Task { await sharing.accept(url:url); if sharing.error == nil { link = "" } }
                }
                .disabled(link.isEmpty || sharing.busy || !sharing.available)
            } header: { Text("Invitations") } footer: {
                Text(sharing.available ? "Opening an invitation link usually brings you here by itself. If it opened somewhere else, paste it here." : "Sharing needs a copy of Notebook signed for iCloud.")
            }
            if let status = sharing.status { Section { Text(status).font(.caption).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .navigationTitle("Sharing")
        .task { await sharing.syncNow() }
        .alert("Sharing", isPresented:Binding(get:{ sharing.error != nil }, set:{ if !$0 { sharing.error = nil } })) { } message: { Text(sharing.error ?? "") }
    }
    private func row(_ info: ShareInfo) -> some View {
        HStack {
            Image(systemName:["note":"note.text", "links":"link", "account":"building.columns"][info.kind] ?? "square.and.arrow.up").foregroundStyle(.secondary).frame(width:22)
            VStack(alignment:.leading) {
                Text(info.ready ? info.title : "Arriving…")
                Text(shareLine(info) + (info.kind == "account" && info.owner ? " · " + (["balance":"Balance only", "holdings":"Balance and holdings", "transactions":"Holdings and transactions"][info.level] ?? "") : "")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Someone else's account, as they chose to show it. Read only, and never
/// part of your own totals.
struct SharedAccountView: View {
    let info: ShareInfo
    let view: [String:Any]
    let price: (String) -> Double?
    private func money(_ value: Double) -> String { value.formatted(.currency(code:"USD")) }
    private var holdings: [[String:Any]] { view["holdings"] as? [[String:Any]] ?? [] }
    /// Valued with this device's prices where it has them, else the owner's last.
    private func value(_ row: [String:Any]) -> Double {
        let shares = (row["shares"] as? NSNumber)?.doubleValue ?? 0
        if let ticker = row["ticker"] as? String, let current = price(ticker), current > 0 { return shares * current }
        return (row["value"] as? NSNumber)?.doubleValue ?? 0
    }
    var total: Double {
        holdings.isEmpty ? (view["value"] as? NSNumber)?.doubleValue ?? 0 : holdings.reduce((view["cash"] as? NSNumber)?.doubleValue ?? 0) { $0 + value($1) }
    }
    var body: some View {
        ScrollView { page }
        .navigationTitle(view["name"] as? String ?? info.title)
    }
    var page: some View {
            VStack(alignment:.leading, spacing:20) {
                VStack(alignment:.leading, spacing:6) {
                    Text(view["name"] as? String ?? info.title).font(.system(size:28, weight:.semibold, design:.serif))
                    Text(money(total)).font(.system(size:34, weight:.semibold)).monospacedDigit()
                    Text("\(shareLine(info)) · not counted in your totals").font(.callout).foregroundStyle(.secondary)
                    if let updated = view["updatedAt"] as? String, let date = ISO8601DateFormatter().date(from:updated) {
                        Text("Updated \(date.formatted(.relative(presentation:.named)))").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if !holdings.isEmpty {
                    VStack(alignment:.leading, spacing:8) {
                        Text("Holdings").font(.headline)
                        Grid(alignment:.trailing, horizontalSpacing:18, verticalSpacing:8) {
                            GridRow { Text("Symbol").gridColumnAlignment(.leading); Text("Shares"); Text("Value") }.font(.caption).foregroundStyle(.secondary)
                            Divider()
                            ForEach(Array(holdings.enumerated()), id:\.offset) { _, row in
                                GridRow {
                                    Text(row["display"] as? String ?? row["ticker"] as? String ?? "").font(.body.weight(.medium)).gridColumnAlignment(.leading)
                                    Text(((row["shares"] as? NSNumber)?.doubleValue ?? 0).formatted(.number.precision(.fractionLength(0...8))))
                                    Text(money(value(row)))
                                }
                                .monospacedDigit()
                            }
                            if let cash = (view["cash"] as? NSNumber)?.doubleValue, cash != 0 {
                                GridRow { Text("Cash").gridColumnAlignment(.leading); Text(""); Text(money(cash)) }.monospacedDigit()
                            }
                        }
                    }
                }
                if let transactions = view["transactions"] as? [[String:Any]], !transactions.isEmpty {
                    VStack(alignment:.leading, spacing:8) {
                        Text("Transactions").font(.headline)
                        ForEach(Array(transactions.enumerated()), id:\.offset) { _, t in
                            HStack(spacing:14) {
                                Text(String((t["date"] as? String ?? "").prefix(10))).foregroundStyle(.secondary).monospacedDigit()
                                Text((t["type"] as? String ?? "").capitalized).frame(width:70, alignment:.leading)
                                Text(t["display"] as? String ?? t["ticker"] as? String ?? "").fontWeight(.medium)
                                Spacer()
                                Text("\(((t["quantity"] as? NSNumber)?.doubleValue ?? 0).formatted(.number.precision(.fractionLength(0...8)))) × \(money((t["price"] as? NSNumber)?.doubleValue ?? 0))").monospacedDigit()
                            }
                        }
                    }
                }
            }
            .padding(24).frame(maxWidth:.infinity, alignment:.leading)
    }
}
