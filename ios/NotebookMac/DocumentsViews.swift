import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NotebookCore

struct MacDocumentsList: View {
    @ObservedObject var documents: DocumentsModel
    @Binding var selection: String?
    @State private var query = ""
    @State private var adding = false
    @State private var dropping = false
    private var items: [DocumentItem] {
        let q = query.trimmingCharacters(in:.whitespaces).lowercased()
        return documents.documents
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.notes.lowercased().contains(q) || $0.text.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) } }
            .sorted { $0.createdAt > $1.createdAt }
    }
    var body: some View {
        List(selection:$selection) {
            if let importing = documents.importing { HStack { ProgressView().controlSize(.small); Text(importing).font(.caption).foregroundStyle(.secondary) } }
            ForEach(items) { item in
                HStack(spacing:10) {
                    DocumentIcon(item:item)
                    VStack(alignment:.leading, spacing:2) {
                        Text(item.name).font(.system(.body, weight:.semibold)).lineLimit(1)
                        Text("\(item.kindLabel) · \(item.sizeLabel)").font(.caption).foregroundStyle(.secondary)
                        Text(item.statusLabel).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.vertical, 4).tag(item.id)
            }
        }
        .overlay { if !documents.loaded { ProgressView() } else if documents.documents.isEmpty && documents.importing == nil { ContentUnavailableView("No documents yet", systemImage:"doc.text", description:Text("Add PDFs, photos, Word, Excel or text files. Their text is recognized on this Mac.")) } else if items.isEmpty && !query.isEmpty { ContentUnavailableView.search(text:query) } }
        .overlay(RoundedRectangle(cornerRadius:8).stroke(dropping ? Color.notebookBlue : .clear, lineWidth:2))
        .dropDestination(for:URL.self) { urls, _ in add(urls); return true } isTargeted: { dropping = $0 }
        .searchable(text:$query, prompt:"Search documents and their text")
        .navigationTitle("Documents")
        .navigationSubtitle(documents.documents.count == 1 ? "1 document" : "\(documents.documents.count) documents")
        .navigationSplitViewColumnWidth(min:240, ideal:300)
        .toolbar { Button { adding = true } label: { Label("Add Files", systemImage:"plus") }.disabled(documents.importing != nil).help("Add files (⇧⌘O)").keyboardShortcut("o", modifiers:[.command, .shift]) }
        .fileImporter(isPresented:$adding, allowedContentTypes:[.item], allowsMultipleSelection:true) { result in if case .success(let urls) = result { add(urls) } }
        .onAppear { documents.reload() }
        .alert("Documents", isPresented:Binding(get:{ documents.error != nil }, set:{ if !$0 { documents.error = nil } })) { } message: { Text(documents.error ?? "") }
    }
    private func add(_ urls: [URL]) { Task { if let last = await documents.importFiles(urls, source:"documents").last { selection = last.id } } }
}

struct MacDocumentDetail: View {
    @ObservedObject var documents: DocumentsModel
    let item: DocumentItem
    @State private var name: String
    @State private var notes: String
    @State private var tags: String
    @State private var preview: NSImage?
    @State private var confirmDelete = false
    init(documents: DocumentsModel, item: DocumentItem) {
        self.documents = documents; self.item = item
        _name = State(initialValue:item.name); _notes = State(initialValue:item.notes); _tags = State(initialValue:item.tags.joined(separator:", "))
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading, spacing:20) {
                HStack(spacing:14) {
                    DocumentIcon(item:item, size:44)
                    VStack(alignment:.leading, spacing:4) {
                        TextField("Name", text:$name).textFieldStyle(.plain).font(MacStyle.titleFont).onSubmit(save)
                        HStack(spacing:6) {
                            Pill(text:item.kindLabel, tint:DocumentIcon.tint(item))
                            Text("\(item.sizeLabel)\(item.pages > 1 ? " · \(item.pages) pages" : "") · \(item.statusLabel)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if let preview {
                    Image(nsImage:preview).resizable().scaledToFit().frame(maxHeight:420).clipShape(RoundedRectangle(cornerRadius:10, style:.continuous))
                        .shadow(color:.black.opacity(0.12), radius:10, y:3).frame(maxWidth:.infinity)
                }
                SectionBlock("Notes") {
                    VStack(alignment:.leading, spacing:10) {
                        TextEditor(text:$notes).font(.body).frame(minHeight:70).scrollContentBackground(.hidden)
                        Divider()
                        TagField(tags:$tags, onCommit:save)
                    }
                    .card(padding:14)
                }
                if !item.text.isEmpty {
                    SectionBlock(item.textMethod.contains("ocr") ? "Recognized text" : "Text") {
                        Text(item.text).font(.callout).lineSpacing(3).textSelection(.enabled).frame(maxWidth:.infinity, alignment:.leading).card()
                    }
                }
            }
            .pageColumn()
        }
        .navigationTitle(item.name)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { if let url = await documents.fileURL(item) { NSWorkspace.shared.open(url) } } } label: { Label("Open", systemImage:"arrow.up.forward.app") }.help("Open in its app")
                Button(role:.destructive) { confirmDelete = true } label: { Label("Delete", systemImage:"trash") }.help("Delete document")
            }
        }
        .task { if item.hasPreview { preview = await documents.preview(item) } }
        .onDisappear(perform:save)
        .confirmationDialog("Delete “\(item.name)”?", isPresented:$confirmDelete) {
            Button("Delete", role:.destructive) { documents.delete(item) }
        } message: { Text("The file and its text are removed from this Mac and your other devices when they sync.") }
    }
    /// Saves only fields that actually changed.
    private func save() {
        let values = tags.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        let changedName = name != item.name, changedNotes = notes != item.notes, changedTags = values != item.tags
        guard changedName || changedNotes || changedTags else { return }
        documents.update(item, name:changedName ? name : nil, notes:changedNotes ? notes : nil, tags:changedTags ? values : nil)
    }
}

/// A document's kind as a tinted symbol.
struct DocumentIcon: View {
    let item: DocumentItem
    var size: CGFloat = 32
    var body: some View {
        Image(systemName:Self.symbol(item)).font(.system(size:size * 0.45, weight:.medium)).foregroundStyle(Self.tint(item))
            .frame(width:size, height:size).background(Self.tint(item).opacity(0.13), in:RoundedRectangle(cornerRadius:size * 0.26, style:.continuous))
    }
    static func symbol(_ item: DocumentItem) -> String {
        ["PDF":"doc.richtext", "Image":"photo", "Excel":"tablecells", "Word":"doc.text", "PowerPoint":"rectangle.on.rectangle", "Text":"text.alignleft"][item.kindLabel] ?? "doc"
    }
    static func tint(_ item: DocumentItem) -> Color {
        ["PDF":Color.red, "Image":.purple, "Excel":.green, "Word":.blue, "PowerPoint":.orange, "Text":.gray][item.kindLabel] ?? .indigo
    }
}
