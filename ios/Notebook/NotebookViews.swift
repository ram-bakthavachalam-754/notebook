import SwiftUI
import PhotosUI

struct NotebookRoot: View {
    @ObservedObject var model: NotebookModel
    @Environment(\.scenePhase) var phase
    @State private var settings = false
    /// A child's policy decides which apps appear; adults see everything.
    private func shows(_ app: String) -> Bool {
        guard model.agent.kidMode else { return true }
        let apps = model.agent.policy?["apps"] as? [String:[String:Any]] ?? [:]
        return apps[app]?["on"] as? Bool ?? (app == "agent")
    }
    var body: some View {
        ZStack {
            TabView {
                if shows("notes") { NotebookList(model:model,kind:"notes",settings:$settings).tabItem { Label("Notes",systemImage:"note.text") } }
                if shows("journal") { NotebookList(model:model,kind:"journal",settings:$settings).tabItem { Label("Journal",systemImage:"book.closed") } }
                if !model.agent.kidMode { NotebookFinance(notebook:model).tabItem { Label("Finance",systemImage:"chart.line.uptrend.xyaxis") } }
                if !model.agent.kidMode { NotebookNews(notebook:model).tabItem { Label("News",systemImage:"newspaper") } }
                if shows("links") { NotebookLinks(notebook:model).tabItem { Label("Links",systemImage:"link") } }
                if model.agent.kidMode {
                    if shows("agent") { NavigationStack { KidAsk(agent:model.agent,documents:model.documents) }.tabItem { Label("Ask",systemImage:"sparkles") } }
                } else {
                    NotebookAgent(notebook:model).tabItem { Label("Agent",systemImage:"sparkles") }
                }
                if shows("documents") { NotebookDocuments(notebook:model).tabItem { Label("Documents",systemImage:"doc.text") } }
                if model.agent.kidMode && shows("money") { NavigationStack { KidMoney(money:model.money,allowance:KidApps.allowance(model.agent.policy)) }.tabItem { Label("Money",systemImage:"dollarsign.circle") } }
            }
            .tint(.notebookBlue)
            .sheet(isPresented:$settings) { NotebookSettings(model:model) }
            if !model.unlocked || (phase != .active && model.lockEnabled) {
                Color.notebookPaper.ignoresSafeArea()
                VStack(spacing:22) {
                    Image(systemName:"lock.shield").font(.system(size:46,weight:.light)).foregroundStyle(.secondary)
                    Text("A little privacy.").font(.custom("Charter",size:34))
                    Text("Your notes, journal, and finances, just for you.").foregroundStyle(.secondary)
                    Button("Unlock Notebook") { Task { await model.unlock() } }.buttonStyle(.borderedProminent).tint(.notebookBlue)
                }.padding(30)
            }
        }
        .task { model.startPolling(); await model.links.importInbox() }
        .onChange(of:model.unlocked) { _, unlocked in if unlocked { Task { await model.links.importInbox() } } }
        .onChange(of:phase) { _, phase in
            if phase == .active { model.startPolling(); Task { await model.links.importInbox() } }
            else if phase == .background { settings = false; model.background() }
        }
        .alert("Notebook",isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .alert("Shared with you",isPresented:Binding(get:{ model.unlocked && !model.sharing.notices.isEmpty },set:{ if !$0 { model.sharing.dismissNotices() } })) { Button("OK") { model.sharing.dismissNotices() } } message: { Text(model.sharing.notices.joined(separator:"\n")) }
        .onChange(of:model.unlocked) { _, _ in NotebookSceneDelegate.attach(model) }
        .onAppear { NotebookSceneDelegate.attach(model) }
    }
}
struct NotebookList: View {
    @ObservedObject var model: NotebookModel
    let kind: String
    @Binding var settings: Bool
    @State private var query = ""
    @State private var selected: NotebookItem?
    @State private var deleting: NotebookItem?
    var items: [NotebookItem] {
        (kind == "notes" ? model.notes : model.journal).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                if !model.loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60).listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? (kind == "notes" ? "A place for your thoughts." : "Make a little room for today.") : "No matches",systemImage:kind == "notes" ? "note.text" : "book")
                    } description: {
                        Text(query.isEmpty ? "Start writing here, or connect your Mac to bring your notebook along." : "Try another word or phrase.")
                    } actions: {
                        if query.isEmpty { Button("Start writing") { selected = model.newItem(kind:kind) }; if !model.connected { Button("Connect your Mac") { settings = true } } }
                    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(items.filter { !$0.sharedWithMe }) { item in
                            Button { selected = item } label: {
                                VStack(alignment:.leading,spacing:7) {
                                    HStack {
                                        Text(kind == "notes" ? (item.title.isEmpty ? "Untitled" : item.title) : dateLabel(item.date)).font(.system(.headline)).foregroundStyle(.primary)
                                        Spacer()
                                        if item.conflict || item.versions > 1 { Image(systemName:"doc.on.doc").foregroundStyle(.orange).accessibilityLabel("Conflicting versions preserved") }
                                        if item.raw["pinned"] as? Bool == true { Image(systemName:"pin.fill").font(.caption).foregroundStyle(.secondary) }
                                        if item.share != nil { Image(systemName:"person.2.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Shared") }
                                    }
                                    Text(item.preview.isEmpty ? "No additional text" : item.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    if let tags = item.raw["tags"] as? [String], !tags.isEmpty { Text(tags.joined(separator:" · ")).font(.caption).foregroundStyle(Color.notebookBlue) }
                                }.padding(.vertical,9).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions { Button("Delete",role:.destructive) { deleting = item } }
                        }
                    } header: { Text("\(items.count) \(kind == "notes" ? "notes" : "entries")").textCase(nil) }
                    let shared = items.filter(\.sharedWithMe)
                    if !shared.isEmpty {
                        Section("Shared with you") {
                            ForEach(shared) { item in
                                Button { selected = item } label: {
                                    VStack(alignment:.leading,spacing:5) {
                                        Text(item.title.isEmpty ? "Untitled" : item.title).font(.headline).foregroundStyle(.primary)
                                        Text(item.preview.isEmpty ? "No additional text" : item.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                        if let info = model.sharing.share(item.share) { Text(shareLine(info)).font(.caption).foregroundStyle(Color.notebookBlue) }
                                    }.padding(.vertical,7).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .swipeActions { Button("Leave",role:.destructive) { deleting = item } }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(Color.notebookPaper)
            .searchable(text:$query,prompt:kind == "notes" ? "Search notes" : "Search journal")
            .navigationTitle(kind == "notes" ? "Notes" : "Journal")
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button { settings = true } label: { Image(systemName:"gearshape") }.accessibilityLabel("Settings and sync") }
                ToolbarItem(placement:.topBarTrailing) {
                    if kind == "notes" && KidApps.templates(model.agent.policy) {
                        Menu {
                            Button("Blank Note") { selected = model.newItem(kind:kind) }
                            ForEach(NoteTemplate.all) { template in
                                Button { selected = model.newItem(kind:kind, template:template) } label: { Label(template.name, systemImage:template.icon) }
                            }
                        } label: { Image(systemName:"square.and.pencil") } primaryAction: { selected = model.newItem(kind:kind) }
                        .accessibilityLabel("New note")
                    } else {
                        Button { selected = model.newItem(kind:kind) } label: { Image(systemName:"square.and.pencil") }.accessibilityLabel("New \(kind == "notes" ? "note" : "journal entry")")
                    }
                }
                ToolbarItem(placement:.bottomBar) { Text(model.syncing ? "Syncing…" : (model.connected ? model.syncMessage : "Saved on this device")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .refreshable { await model.sync() }
            .navigationDestination(item:$selected) { item in NotebookEditor(model:model,kind:kind,item:item) }
            .confirmationDialog(deleting?.sharedWithMe == true ? "Leave this shared note?" : "Delete this \(kind == "notes" ? "note" : "entry")?",isPresented:Binding(get:{ deleting != nil },set:{ if !$0 { deleting = nil } }),titleVisibility:.visible) {
                Button(deleting?.sharedWithMe == true ? "Leave" : "Delete",role:.destructive) { if let deleting { model.delete(deleting,kind:kind) }; deleting = nil }
            } message: {
                if deleting?.sharedWithMe == true { Text("It's removed from your notebook. The owner keeps it.") }
                else if deleting?.share != nil { Text("It's shared, so this deletes it for everyone on it.") }
            }
        }
    }
    func dateLabel(_ raw: String) -> String {
        if let date = ISO8601DateFormatter().date(from:raw) { return date.formatted(date:.abbreviated,time:.omitted) }
        return String(raw.prefix(10))
    }
}
extension NotebookItem: Hashable {
    static func == (lhs: Self,rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
struct NotebookEditor: View {
    @ObservedObject var model: NotebookModel
    let kind: String
    @StateObject private var draft: NotebookDraft
    private var item: NotebookItem { draft.item }
    @State private var media: [String:String] = [:]
    @Environment(\.scenePhase) private var phase
    init(model: NotebookModel, kind: String, item: NotebookItem) {
        self.model=model; self.kind=kind
        _draft=StateObject(wrappedValue:NotebookDraft(item:item,kind:kind,store:model.store(for:item)))
    }
    @State private var sharingSheet = false
    @State private var photo: PhotosPickerItem?
    @State private var editorCommand: NoteEditorCommand?
    @State private var tags: String = ""
    @State private var resolved = false
    @State private var resolveConfirmation = false

    var body: some View {
        VStack(spacing:0) {
            if (item.conflict || item.versions > 1) && !resolved {
                HStack { Text("Another version was kept so no writing is lost.").font(.caption); Spacer(); Button("Keep this version") { resolveConfirmation = true }.font(.caption).bold() }.padding().background(.orange.opacity(0.12))
            }
            if let info = model.sharing.share(item.share) {
                Label(shareLine(info), systemImage:"person.2").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity, alignment:.leading).padding(.horizontal,22).padding(.top,10)
            }
            if kind == "notes" {
                TextField("Untitled",text:Binding(get:{ item.raw["title"] as? String ?? "" },set:{ draft.change("title",$0) })).font(.custom("Charter",size:30)).padding(.horizontal,22).padding(.top,18).padding(.bottom,10).disabled(item.readOnly)
            } else {
                HStack {
                    Text(String(item.date.prefix(10))).font(.custom("Charter",size:26))
                    Spacer()
                    Picker("Mood",selection:Binding(get:{ JournalMood(stored:item.raw["mood"] as? String) },set:{ draft.change("mood",$0.rawValue) })) {
                        ForEach(JournalMood.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden()
                }.padding(22)
            }
            TextField("Add tags, separated by commas",text:$tags).font(.caption).foregroundStyle(.secondary).padding(.horizontal,22).padding(.bottom,12)
                .onSubmit { commitTags() }.disabled(item.readOnly)
            NoteEditor(html:item.content,media:media,command:$editorCommand,editable:!item.readOnly) { html in draft.change("content",html) }
        }
        .background(Color.notebookPaper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if kind == "notes" && model.sharing.canShare("note") {
                ToolbarItem(placement:.topBarTrailing) {
                    Button { sharingSheet = true } label: { Image(systemName:item.share == nil ? "person.crop.circle.badge.plus" : "person.2.fill") }
                        .accessibilityLabel("Share").disabled(item.raw["_syncHeads"] == nil)
                }
            }
            ToolbarItem(placement:.principal) { Text(item.readOnly ? "View only" : draft.status).font(.caption).foregroundStyle(draft.failed ? Color.red : Color.secondary).accessibilityIdentifier("editor-save-status") }
            if !item.readOnly { ToolbarItemGroup(placement:.bottomBar) {
                Button { editorCommand = .bold } label: { Image(systemName:"bold") }.accessibilityLabel("Bold")
                Button { editorCommand = .italic } label: { Image(systemName:"italic") }.accessibilityLabel("Italic")
                Button { editorCommand = .heading } label: { Image(systemName:"textformat.size") }.accessibilityLabel("Heading")
                Button { editorCommand = .bulletList } label: { Image(systemName:"list.bullet") }.accessibilityLabel("Bulleted list")
                Button { editorCommand = .numberedList } label: { Image(systemName:"list.number") }.accessibilityLabel("Numbered list")
                Spacer()
                PhotosPicker(selection:$photo,matching:.images) { Image(systemName:"photo") }.accessibilityLabel("Add photo")
            } }
        }
        .sheet(isPresented:$sharingSheet) {
            ShareSheet(sharing:model.sharing, kind:"note", title:item.title.isEmpty ? "Untitled" : item.title, existing:item.share) { _ in
                await draft.flush()
                return await model.sharing.shareNote(draft.item)
            }
        }
        .onAppear { model.beginEditing(); tags = (item.raw["tags"] as? [String] ?? []).joined(separator:", ") }
        .task { media = await model.media(for:item.content, in:item) }
        .onDisappear {
            commitTags()
            flushInBackground { model.endEditing() }
        }
        .onChange(of:phase) { _,phase in if phase != .active { commitTags(); flushInBackground() } }
        .onChange(of:photo) { _, value in
            Task {
                do {
                    // Saved as its own media record, like on the Mac; the note keeps a marker.
                    guard let value, let data = try await value.loadTransferable(type:Data.self) else { return }
                    let saved = try await model.addPhoto(data, for:item); media[saved.id] = saved.src; editorCommand = .insertMedia(id:saved.id, src:saved.src)
                    photo = nil
                } catch { model.error = error.localizedDescription }
            }
        }
        .confirmationDialog("Keep this version and replace the other versions?",isPresented:$resolveConfirmation,titleVisibility:.visible) {
            Button("Keep this version") { Task { await draft.resolve(); if !draft.failed { resolved=true } } }
        } message: { Text("Other versions stay in the revision history but disappear from the list.") }
    }
    func commitTags() {
        let values = tags.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        if values != (item.raw["tags"] as? [String] ?? []) { draft.change("tags",values) }
    }
    func flushInBackground(completion: @escaping @MainActor () -> Void = {}) {
        let task=UIApplication.shared.beginBackgroundTask(withName:"Save notebook draft")
        Task {
            await draft.flush(); completion()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}
