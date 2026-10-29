import SwiftUI
import NotebookCore

extension NotebookItem {
    var pinned: Bool { raw["pinned"] as? Bool ?? false }
    var tags: [String] { raw["tags"] as? [String] ?? [] }
    var modified: String { raw["modifiedAt"] as? String ?? raw["createdAt"] as? String ?? "" }
    var displayTitle: String { title.trimmingCharacters(in:.whitespaces).isEmpty ? "Untitled" : title }
}

private let isoParser: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
private let isoPlainParser = ISO8601DateFormatter()
func notebookDate(_ value: String) -> Date? { isoParser.date(from:value) ?? isoPlainParser.date(from:value) }

struct NotesList: View {
    @ObservedObject var model: NotebookModel
    @Binding var selection: String?
    @Binding var newNote: NotebookItem?
    @State private var query = ""
    /// The notebook already lists notes newest first; pinned ones go on top.
    private func filtered() -> [NotebookItem] {
        let q = query.trimmingCharacters(in:.whitespaces)
        let matching = q.isEmpty ? model.notes : model.notes.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.preview.localizedCaseInsensitiveContains(q) || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) } }
        return matching.filter(\.pinned) + matching.filter { !$0.pinned }
    }
    var body: some View {
        let notes = filtered()
        List(selection:$selection) {
            if let newNote, query.isEmpty, !model.notes.contains(where:{ $0.id == newNote.id }) { NoteRow(item:newNote, placeholder:"New note").tag(newNote.id) }
            let mine = notes.filter { !$0.sharedWithMe }, pinned = mine.filter(\.pinned)
            if pinned.isEmpty { ForEach(mine) { NoteRow(item:$0).tag($0.id) } }
            else {
                Section("Pinned") { ForEach(pinned) { NoteRow(item:$0).tag($0.id) } }
                Section("Notes") { ForEach(mine.filter { !$0.pinned }) { NoteRow(item:$0).tag($0.id) } }
            }
            let shared = notes.filter(\.sharedWithMe)
            if !shared.isEmpty { Section("Shared with You") { ForEach(shared) { NoteRow(item:$0).tag($0.id) } } }
        }
        .overlay { if !model.loaded { ProgressView() } else if model.notes.isEmpty && newNote == nil { ContentUnavailableView("No notes yet", systemImage:"note.text", description:Text("Press ⌘N to write one.")) } else if notes.isEmpty && !query.isEmpty { ContentUnavailableView.search(text:query) } }
        // Rows in sections otherwise stay one line tall.
        .environment(\.defaultMinListRowHeight, 64)
        .searchable(text:$query, prompt:"Search notes")
        .navigationTitle("Notes")
        .navigationSubtitle(model.notes.count == 1 ? "1 note" : "\(model.notes.count) notes")
        .navigationSplitViewColumnWidth(min:240, ideal:300)
        .toolbar {
            if KidApps.templates(model.agent.policy) {
                Menu {
                    Button("Blank Note") { NotificationCenter.default.post(name:.notebookNewNote, object:nil) }
                    Divider()
                    ForEach(NoteTemplate.all) { template in
                        Button { NotificationCenter.default.post(name:.notebookNewNote, object:template.name) } label: { Label("\(template.name): \(template.detail)", systemImage:template.icon) }
                    }
                } label: { Label("New Note", systemImage:"square.and.pencil") } primaryAction: { NotificationCenter.default.post(name:.notebookNewNote, object:nil) }
                .help("New note (⌘N), or start from a template")
            } else {
                Button { NotificationCenter.default.post(name:.notebookNewNote, object:nil) } label: { Label("New Note", systemImage:"square.and.pencil") }.help("New note (⌘N)")
            }
        }
    }
}

struct NoteRow: View {
    let item: NotebookItem
    var placeholder: String? = nil
    var body: some View {
        VStack(alignment:.leading, spacing:3) {
            HStack(spacing:5) {
                Text(placeholder ?? item.displayTitle).font(.system(.body, weight:.semibold)).lineLimit(1)
                if item.conflict || item.versions > 1 { Image(systemName:"square.on.square").font(.caption2).foregroundStyle(.orange).help("Another version was kept") }
                if item.share != nil { Image(systemName:"person.2.fill").font(.caption2).foregroundStyle(.secondary).help(item.sharedWithMe ? "Shared with you" : "Shared") }
            }
            (Text(notebookDate(item.modified).map { NoteRow.shortDate($0) + "  " } ?? "").foregroundStyle(.primary.opacity(0.75)) + Text(item.preview.isEmpty ? "No additional text" : item.preview))
                .font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace:true)
        }
        .padding(.vertical, 5)
    }
}

extension NoteRow {
    /// Like Notes: the time today, the weekday this week, otherwise the date.
    static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date:.omitted, time:.shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from:date, to:Date()).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date:.numeric, time:.omitted)
    }
}

struct NoteDetail: View {
    @ObservedObject var model: NotebookModel
    @StateObject private var draft: NotebookDraft
    @State private var media: [String:String] = [:]
    @State private var command: NoteEditorCommand?
    @State private var tags: String
    @State private var confirmDelete = false
    @State private var confirmResolve = false
    @State private var resolved = false
    @State private var sharingSheet = false
    @ObservedObject private var sharing: SharingModel
    private let onSaved: () -> Void
    private let onDiscard: () -> Void
    init(model: NotebookModel, item: NotebookItem, onSaved: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.model = model; self.onSaved = onSaved; self.onDiscard = onDiscard
        // Start from the note's own tags so leaving early can never save them as empty.
        _tags = State(initialValue:item.tags.joined(separator:", "))
        _draft = StateObject(wrappedValue:NotebookDraft(item:item, kind:"notes", store:model.store(for:item)))
        sharing = model.sharing
    }
    private var item: NotebookItem { draft.item }
    private var shareInfo: ShareInfo? { sharing.share(item.share) }
    private var readOnly: Bool { item.readOnly }
    var body: some View {
        VStack(alignment:.leading, spacing:0) {
            if (item.conflict || item.versions > 1) && !resolved {
                HStack {
                    Image(systemName:"square.on.square")
                    Text("This note was changed in two places, so both versions were kept.")
                    Spacer()
                    Button("Keep This Version") { confirmResolve = true }
                }
                .font(.callout).padding(.horizontal, MacStyle.pagePadding).padding(.vertical, 8).background(.orange.opacity(0.12))
            }
            if let shareInfo {
                Label(shareLine(shareInfo), systemImage:"person.2").font(.callout).foregroundStyle(.secondary).padding(.horizontal, MacStyle.pagePadding).padding(.top, 14)
            }
            if let date = notebookDate(item.modified) {
                Text(date.formatted(.dateTime.month(.wide).day().year().hour().minute()))
                    .font(.caption).foregroundStyle(.tertiary).frame(maxWidth:.infinity).padding(.top, 14)
            }
            TextField("Untitled", text:Binding(get:{ item.title }, set:{ draft.change("title", $0) }))
                .textFieldStyle(.plain).font(MacStyle.titleFont).padding(.horizontal, MacStyle.pagePadding).padding(.top, 10).disabled(readOnly)
            TagField(tags:$tags, onCommit:commitTags).padding(.horizontal, MacStyle.pagePadding).padding(.top, 8).disabled(readOnly)
            NoteEditor(html:item.content, media:media, command:$command, editable:!readOnly) { draft.change("content", $0) }
        }
        .toolbar { toolbar }
        .navigationTitle(item.displayTitle)
        .navigationSubtitle(readOnly ? "View only" : draft.status)
        .task { media = await model.media(for:item.content, in:item) }
        .sheet(isPresented:$sharingSheet) {
            ShareSheet(sharing:sharing, kind:"note", title:item.displayTitle, existing:item.share) { _ in
                await draft.flush()
                return await sharing.shareNote(draft.item)
            } onStopped: { onDiscard() }
        }
        .onAppear { draft.onSaved = onSaved }
        .onDisappear { commitTags(); Task { await draft.flush() } }
        .confirmationDialog(shareInfo?.owner == false ? "Leave “\(item.displayTitle)”?" : "Delete “\(item.displayTitle)”?", isPresented:$confirmDelete) {
            Button(shareInfo?.owner == false ? "Leave" : "Delete", role:.destructive) {
                Task {
                    await draft.flush()
                    // A note that was never saved has nothing to delete.
                    if draft.item.raw["_syncHeads"] == nil { onDiscard() } else { model.delete(draft.item, kind:"notes") }
                }
            }
        } message: { Text(deleteMessage) }
        .confirmationDialog("Keep this version and replace the others?", isPresented:$confirmResolve) {
            Button("Keep This Version") { Task { await draft.resolve(); if !draft.failed { resolved = true } } }
        } message: { Text("The other versions stay in the history but disappear from the list.") }
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
            ToolbarItemGroup {
                Button { sharingSheet = true } label: { Label("Share", systemImage:shareInfo == nil ? "person.crop.circle.badge.plus" : "person.2.fill") }
                    .help(shareInfo.map(shareLine) ?? "Share this note").disabled(draft.item.raw["_syncHeads"] == nil || !sharing.canShare("note"))
            }
            ToolbarItemGroup {
                Button { command = .bold } label: { Label("Bold", systemImage:"bold") }.help("Bold (⌘B)").disabled(readOnly)
                Button { command = .italic } label: { Label("Italic", systemImage:"italic") }.help("Italic (⌘I)").disabled(readOnly)
                Button { command = .heading } label: { Label("Heading", systemImage:"textformat.size") }.help("Heading").disabled(readOnly)
                Button { command = .bulletList } label: { Label("Bulleted List", systemImage:"list.bullet") }.help("Bulleted list").disabled(readOnly)
                Button { command = .numberedList } label: { Label("Numbered List", systemImage:"list.number") }.help("Numbered list").disabled(readOnly)
            }
            ToolbarItemGroup {
                Button { draft.change("pinned", !item.pinned) } label: { Label(item.pinned ? "Unpin" : "Pin", systemImage:item.pinned ? "pin.slash" : "pin") }.help(item.pinned ? "Unpin" : "Pin to the top").disabled(readOnly)
                Button(role:.destructive) { confirmDelete = true } label: { Label(shareInfo?.owner == false ? "Leave" : "Delete", systemImage:"trash") }.help(shareInfo?.owner == false ? "Remove this shared note from your notebook" : "Delete note")
            }
    }
    private var deleteMessage: String {
        guard let shareInfo else { return "It's removed from this Mac and from your other devices when they sync." }
        return shareInfo.owner ? "It's shared, so this deletes it for everyone on it." : "It's removed from your notebook. \(shareInfo.ownerName.isEmpty ? "The owner" : shareInfo.ownerName) keeps it."
    }
    private func commitTags() {
        let values = tags.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        if values != item.tags { draft.change("tags", values) }
    }
}

/// Tags typed as a comma-separated line, with a tag symbol in front.
struct TagField: View {
    @Binding var tags: String
    let onCommit: () -> Void
    var body: some View {
        HStack(spacing:6) {
            Image(systemName:"tag").font(.caption).foregroundStyle(.tertiary)
            TextField("Add tags", text:$tags).textFieldStyle(.plain).font(.callout).foregroundStyle(.secondary).onSubmit(onCommit)
        }
    }
}
