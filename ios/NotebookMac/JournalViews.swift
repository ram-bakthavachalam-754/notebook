import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import NotebookCore

extension NotebookItem {
    var mood: JournalMood { JournalMood(stored:raw["mood"] as? String) }
    var entryDate: Date? { JournalDates.date(date) }
}

struct JournalList: View {
    @ObservedObject var model: NotebookModel
    @Binding var selection: String?
    @Binding var newEntry: NotebookItem?
    @State private var query = ""
    /// Entries by month. The notebook already lists them newest first, so this
    /// only groups them; each month's title is formatted once.
    private func months() -> [(title: String, entries: [NotebookItem])] {
        let q = query.trimmingCharacters(in:.whitespaces)
        var entries = q.isEmpty ? model.journal : model.journal.filter { $0.preview.localizedCaseInsensitiveContains(q) || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) } }
        if let newEntry, q.isEmpty, !model.journal.contains(where:{ $0.id == newEntry.id }) { entries.insert(newEntry, at:0) }
        var titles: [String:String] = [:]
        var result: [(title: String, entries: [NotebookItem])] = []
        for entry in entries {
            let key = String(entry.date.prefix(7))
            let title = titles[key] ?? { let value = entry.entryDate?.formatted(.dateTime.month(.wide).year()) ?? "Undated"; titles[key] = value; return value }()
            if result.last?.title == title { result[result.count - 1].entries.append(entry) } else { result.append((title, [entry])) }
        }
        return result
    }
    var body: some View {
        let months = months()
        List(selection:$selection) {
            ForEach(months, id:\.title) { month in
                Section(month.title) { ForEach(month.entries) { JournalRow(model:model, item:$0, isNew:$0.id == newEntry?.id).tag($0.id) } }
            }
        }
        .overlay { if !model.loaded { ProgressView() } else if model.journal.isEmpty && newEntry == nil { ContentUnavailableView("No entries yet", systemImage:"book.closed", description:Text("Press ⇧⌘N to write about today.")) } else if months.isEmpty && !query.isEmpty { ContentUnavailableView.search(text:query) } }
        // Rows in sections otherwise stay one line tall.
        .environment(\.defaultMinListRowHeight, 56)
        .searchable(text:$query, prompt:"Search entries")
        .navigationTitle("Journal")
        .navigationSubtitle(model.journal.count == 1 ? "1 entry" : "\(model.journal.count) entries")
        .navigationSplitViewColumnWidth(min:240, ideal:300)
        .toolbar { Button { NotificationCenter.default.post(name:.notebookNewEntry, object:nil) } label: { Label("New Entry", systemImage:"square.and.pencil") }.help("New entry (⇧⌘N)") }
    }
}

struct JournalRow: View {
    @ObservedObject var model: NotebookModel
    let item: NotebookItem
    var isNew = false
    @State private var thumbnail: NSImage?
    var body: some View {
        HStack(alignment:.top, spacing:12) {
            VStack(spacing:0) {
                Text(item.entryDate?.formatted(.dateTime.weekday(.abbreviated)).uppercased() ?? "—").font(.system(size:9, weight:.bold)).foregroundStyle(item.mood.tint)
                Text(item.entryDate?.formatted(.dateTime.day()) ?? "?").font(.system(size:19, weight:.semibold, design:.rounded)).monospacedDigit()
            }
            .frame(width:38, height:42)
            .background(item.mood.tint.opacity(0.1), in:RoundedRectangle(cornerRadius:9, style:.continuous))
            VStack(alignment:.leading, spacing:3) {
                HStack(spacing:6) {
                    Label(item.mood.label, systemImage:item.mood.symbol).font(.caption.weight(.medium)).foregroundStyle(item.mood.tint)
                    if item.conflict || item.versions > 1 { Image(systemName:"square.on.square").font(.caption2).foregroundStyle(.orange).help("Another version was kept") }
                }
                Text(isNew && item.preview.isEmpty ? "New entry" : item.preview.isEmpty ? "No text" : item.preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength:0)
            if let thumbnail { Image(nsImage:thumbnail).resizable().scaledToFill().frame(width:42, height:42).clipShape(RoundedRectangle(cornerRadius:8, style:.continuous)) }
        }
        .padding(.vertical, 4)
        .task(id:item.firstMediaID) {
            guard let id = item.firstMediaID, let value = await model.thumbnails([id])[id],
                  let data = Data(base64Encoded:value.replacingOccurrences(of:"^data:[^,]*;base64,", with:"", options:.regularExpression)) else { thumbnail = nil; return }
            thumbnail = NSImage(data:data)
        }
    }
}

struct JournalDetail: View {
    @ObservedObject var model: NotebookModel
    @StateObject private var draft: NotebookDraft
    @State private var media: [String:String] = [:]
    @State private var command: NoteEditorCommand?
    @State private var tags: String
    @State private var photo: PhotosPickerItem?
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var confirmDelete = false
    @State private var confirmResolve = false
    @State private var resolved = false
    private let onSaved: () -> Void
    private let onDiscard: () -> Void
    init(model: NotebookModel, item: NotebookItem, onSaved: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.model = model; self.onSaved = onSaved; self.onDiscard = onDiscard
        _draft = StateObject(wrappedValue:NotebookDraft(item:item, kind:"journal", store:model.store))
        _tags = State(initialValue:item.tags.joined(separator:", "))
    }
    private var item: NotebookItem { draft.item }
    var body: some View {
        VStack(alignment:.leading, spacing:0) {
            if (item.conflict || item.versions > 1) && !resolved {
                HStack {
                    Image(systemName:"square.on.square")
                    Text("This entry was changed in two places, so both versions were kept.")
                    Spacer()
                    Button("Keep This Version") { confirmResolve = true }
                }
                .font(.callout).padding(.horizontal, MacStyle.pagePadding).padding(.vertical, 8).background(.orange.opacity(0.12))
            }
            HStack(alignment:.center, spacing:12) {
                VStack(alignment:.leading, spacing:4) {
                    Text(item.entryDate?.formatted(.dateTime.weekday(.wide)).uppercased() ?? "").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(item.mood.tint)
                    Text(item.entryDate?.formatted(.dateTime.month(.wide).day().year()) ?? "Undated").font(MacStyle.titleFont)
                }
                Spacer()
                DatePicker("Date", selection:Binding(get:{ item.entryDate ?? Date() }, set:{ draft.change("date", JournalDates.stored($0)) }), displayedComponents:.date)
                    .labelsHidden().datePickerStyle(.field).fixedSize().help("Change the entry's date")
                Picker("Mood", selection:Binding(get:{ item.mood }, set:{ draft.change("mood", $0.rawValue) })) {
                    ForEach(JournalMood.allCases) { Label($0.label, systemImage:$0.symbol).tag($0) }
                }
                .fixedSize().tint(item.mood.tint).help("How was the day?")
            }
            .padding(.horizontal, MacStyle.pagePadding).padding(.top, 24)
            TagField(tags:$tags, onCommit:commitTags).padding(.horizontal, MacStyle.pagePadding).padding(.top, 10)
            NoteEditor(html:item.content, media:media, command:$command) { draft.change("content", $0) }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { command = .bold } label: { Label("Bold", systemImage:"bold") }.help("Bold (⌘B)")
                Button { command = .italic } label: { Label("Italic", systemImage:"italic") }.help("Italic (⌘I)")
                Button { command = .bulletList } label: { Label("Bulleted List", systemImage:"list.bullet") }.help("Bulleted list")
                Menu {
                    Button("From Photos…") { choosingPhotos = true }
                    Button("From Files…") { choosingFiles = true }
                } label: { Label("Add Photo", systemImage:"photo") }.help("Add a photo")
            }
            ToolbarItem { Button(role:.destructive) { confirmDelete = true } label: { Label("Delete", systemImage:"trash") }.help("Delete entry") }
        }
        .navigationTitle("Journal")
        .navigationSubtitle(draft.status)
        .photosPicker(isPresented:$choosingPhotos, selection:$photo, matching:.images)
        .fileImporter(isPresented:$choosingFiles, allowedContentTypes:[.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf:url) { insertPhoto(data) } else { model.error = "That photo couldn't be opened." }
        }
        .onChange(of:photo) { _, value in
            guard let value else { return }
            photo = nil
            Task { if let data = try? await value.loadTransferable(type:Data.self) { insertPhoto(data) } }
        }
        .task { media = await model.media(for:item.content) }
        .onAppear { draft.onSaved = onSaved }
        .onDisappear { commitTags(); Task { await draft.flush() } }
        .confirmationDialog("Delete this entry?", isPresented:$confirmDelete) {
            Button("Delete", role:.destructive) {
                Task {
                    await draft.flush()
                    if draft.item.raw["_syncHeads"] == nil { onDiscard() } else { model.delete(draft.item, kind:"journal") }
                }
            }
        } message: { Text("It's removed from this Mac and from your other devices when they sync.") }
        .confirmationDialog("Keep this version and replace the others?", isPresented:$confirmResolve) {
            Button("Keep This Version") { Task { await draft.resolve(); if !draft.failed { resolved = true } } }
        } message: { Text("The other versions stay in the history but disappear from the list.") }
    }
    private func insertPhoto(_ data: Data) {
        Task {
            do { let saved = try await model.addPhoto(data); media[saved.id] = saved.src; command = .insertMedia(id:saved.id, src:saved.src) }
            catch { model.error = error.localizedDescription }
        }
    }
    private func commitTags() {
        let values = tags.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        if values != item.tags { draft.change("tags", values) }
    }
}
