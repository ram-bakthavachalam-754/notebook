import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import NotebookCore

struct NotebookDocuments: View {
    @ObservedObject var notebook: NotebookModel
    @StateObject private var model: DocumentsModel
    @State private var query = ""
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var selected: DocumentItem?
    @State private var deleting: DocumentItem?
    init(notebook: NotebookModel) { self.notebook = notebook; _model = StateObject(wrappedValue:notebook.documents) }
    var items: [DocumentItem] {
        model.documents.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) || $0.tags.joined(separator:" ").localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                if !model.loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60).listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "Keep the paper. Find the words." : "No matches",systemImage:"doc.text.magnifyingglass")
                    } description: {
                        Text(query.isEmpty ? "Add receipts, statements, scans, and reports. Notebook recognizes their text on this device so you can search them, and the agent can read them when you ask." : "Try another word or phrase.")
                    } actions: {
                        if query.isEmpty { Button("Add from Files") { importing = true }; PhotosPicker("Add a photo",selection:$photo,matching:.images) }
                    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(items) { item in
                            Button { selected = item } label: { DocumentRow(model:model,item:item) }
                                .buttonStyle(.plain)
                                .swipeActions { Button("Delete",role:.destructive) { deleting = item } }
                        }
                    } header: { Text("\(items.count) \(items.count == 1 ? "document" : "documents")").textCase(nil) }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(Color.notebookPaper)
            .searchable(text:$query,prompt:"Search documents and their text")
            .navigationTitle("Documents")
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Menu {
                        Button("Add from Files",systemImage:"folder") { importing = true }
                        PhotosPicker(selection:$photo,matching:.images) { Label("Add a photo",systemImage:"photo") }
                    } label: { Image(systemName:"plus") }.accessibilityLabel("Add document").disabled(model.importing != nil)
                }
                ToolbarItem(placement:.bottomBar) { Text(model.importing ?? (notebook.connected ? "Documents sync with iCloud" : "Saved on this device")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.item],allowsMultipleSelection:true) { result in
                if case .success(let urls) = result { Task { await model.importFiles(urls,source:"documents") } }
            }
            .onChange(of:photo) { _, value in
                guard let value else { return }
                Task {
                    do {
                        guard let data = try await value.loadTransferable(type:Data.self) else { return }
                        let type = value.supportedContentTypes.first
                        let name = "Photo " + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + "." + (type?.preferredFilenameExtension ?? "jpg")
                        _ = try await model.importData(data,name:name,type:type?.preferredMIMEType,source:"documents")
                    } catch { model.error = error.localizedDescription }
                    photo = nil
                }
            }
            .refreshable { await notebook.sync(); model.reload() }
            .navigationDestination(item:$selected) { item in DocumentDetail(model:model,item:item) }
            .confirmationDialog("Delete this document on every device?",isPresented:Binding(get:{ deleting != nil },set:{ if !$0 { deleting = nil } }),titleVisibility:.visible) {
                Button("Delete",role:.destructive) { if let deleting { model.delete(deleting) }; deleting = nil }
            }
            .onAppear { model.reload() }
            .onChange(of:notebook.reloadVersion) { _,_ in model.reload() }
            .onChange(of:notebook.unlocked) { _,value in if value { model.reload() } else { selected = nil; importing = false } }
            .alert("Documents",isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}

struct DocumentRow: View {
    @ObservedObject var model: DocumentsModel
    let item: DocumentItem
    @State private var thumb: UIImage?
    var body: some View {
        HStack(spacing:12) {
            Group {
                if let thumb { Image(uiImage:thumb).resizable().scaledToFill() }
                else { Text(item.kindLabel).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
            }.frame(width:42,height:52).background(Color(uiColor:.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius:6))
            VStack(alignment:.leading,spacing:5) {
                Text(item.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text("\(item.kindLabel) · \(item.sizeLabel)" + (item.pages > 1 ? " · \(item.pages) pages" : "")).font(.caption).foregroundStyle(.secondary)
                if !item.notes.isEmpty { Text(item.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if !item.tags.isEmpty { Text(item.tags.joined(separator:" · ")).font(.caption).foregroundStyle(Color.notebookBlue) }
            }
            Spacer()
        }.padding(.vertical,6).contentShape(Rectangle())
        .task(id:item.id) { if item.hasPreview { thumb = await model.preview(item,field:"thumb") } }
    }
}

struct DocumentDetail: View {
    @ObservedObject var model: DocumentsModel
    let item: DocumentItem
    @State private var name: String
    @State private var notes: String
    @State private var tags: String
    @State private var preview: UIImage?
    @State private var shareURL: URL?
    @State private var showAll = false
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    init(model: DocumentsModel, item: DocumentItem) {
        self.model = model; self.item = item
        _name = State(initialValue:item.name); _notes = State(initialValue:item.notes); _tags = State(initialValue:item.tags.joined(separator:", "))
    }
    private var current: DocumentItem { model.documents.first { $0.id == item.id } ?? item }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                TextField("Name",text:$name).font(.custom("Charter",size:26)).onSubmit { model.update(current,name:name) }
                Text("\(current.kindLabel) · \(current.sizeLabel)" + (current.pages > 0 ? " · \(current.pages) \(current.pages == 1 ? "page" : "pages")" : "")).font(.caption).foregroundStyle(.secondary)
                Label(current.statusLabel,systemImage:current.textStatus == "ready" ? "text.viewfinder" : "doc").font(.caption).foregroundStyle(["failed","unsupported"].contains(current.textStatus) ? .red : .secondary)
                if let preview { Image(uiImage:preview).resizable().scaledToFit().frame(maxHeight:360).frame(maxWidth:.infinity).background(Color(uiColor:.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius:12)) }
                VStack(alignment:.leading,spacing:8) {
                    Text("Notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("What this file is, why you kept it… The agent can read these notes too.",text:$notes,axis:.vertical).lineLimit(2...8).padding(12).background(Color(uiColor:.secondarySystemBackground),in:RoundedRectangle(cornerRadius:10))
                    Text("Tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Comma-separated tags",text:$tags).padding(12).background(Color(uiColor:.secondarySystemBackground),in:RoundedRectangle(cornerRadius:10)).autocorrectionDisabled()
                }
                VStack(alignment:.leading,spacing:8) {
                    Text("Recognized text").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let text = current.text
                    Text(text.isEmpty ? (current.textMessage.isEmpty ? current.statusLabel : current.textMessage) : (showAll || text.count <= 20000 ? text : String(text.prefix(20000)) + "\n…"))
                        .font(.callout).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(14).background(Color(uiColor:.secondarySystemBackground),in:RoundedRectangle(cornerRadius:12))
                    if text.count > 20000 && !showAll { Button("Show the complete text") { showAll = true }.font(.caption) }
                }
            }.padding(20).frame(maxWidth:680).frame(maxWidth:.infinity,alignment:.leading)
        }
        .background(Color.notebookPaper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement:.topBarTrailing) {
                if let shareURL { ShareLink(item:shareURL) { Image(systemName:"square.and.arrow.up") }.accessibilityLabel("Share file") }
                Menu {
                    Button("Delete document",systemImage:"trash",role:.destructive) { deleting = true }
                } label: { Image(systemName:"ellipsis.circle") }.accessibilityLabel("Document actions")
            }
        }
        .task { preview = await model.preview(current); shareURL = await model.fileURL(current) }
        .onDisappear { save() }
        .confirmationDialog("Delete this document on every device?",isPresented:$deleting,titleVisibility:.visible) {
            Button("Delete",role:.destructive) { model.delete(current); dismiss() }
        }
    }
    private func save() {
        let newTags = tags.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        if (trimmed.isEmpty ? current.name : trimmed) != current.name || notes != current.notes || newTags != current.tags {
            model.update(current,name:trimmed.isEmpty ? nil : trimmed,notes:notes,tags:newTags)
        }
    }
}
