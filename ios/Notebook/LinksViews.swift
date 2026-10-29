import SwiftUI
import NotebookCore

/// Links on iPhone: a collection picker at the top, then the links in it.
struct NotebookLinks: View {
    @ObservedObject var notebook: NotebookModel
    @StateObject private var model: LinksModel
    @State private var scope = "__all__"
    @State private var query = ""
    @State private var adding = false
    @State private var address = ""
    @State private var naming: LinkItem?
    @State private var name = ""
    @State private var editing: LinkItem?
    @State private var sharingCollection: LinkItem?
    @Environment(\.openURL) private var openURL
    init(notebook: NotebookModel) { self.notebook = notebook; _model = StateObject(wrappedValue:notebook.links) }
    private var collection: LinkItem? { model.collections.first { $0.id == scope } }
    private var readOnly: Bool { collection.map { !$0.editable } ?? false }
    private var items: [LinkItem] {
        let ids = Set(model.collections.map(\.id))
        return model.links.filter { link in
            (scope == "__all__" || (scope == "__unsorted__" ? link.collection.map { !ids.contains($0) } ?? true : link.collection == scope))
                && (query.isEmpty || [link.title, link.url, link.site, link.note].contains { $0.localizedCaseInsensitiveContains(query) } || link.tags.contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    var body: some View {
        NavigationStack {
            List {
                if model.collections.count > 0 || scope != "__all__" {
                    ScrollView(.horizontal, showsIndicators:false) {
                        HStack {
                            chip("All", "__all__"); chip("Unsorted", "__unsorted__")
                            ForEach(model.collections) { c in
                                chip(c.name, c.id, icon:c.share == nil ? nil : "person.2.fill").contextMenu {
                                    if notebook.sharing.canShare("links") { Button(c.share == nil ? "Share" : "Sharing", systemImage:"person.crop.circle.badge.plus") { sharingCollection = c } }
                                    if c.editable { Button("Rename", systemImage:"pencil") { name = c.name; naming = c } }
                                    Button(c.sharedWithMe ? "Leave collection" : "Delete collection", systemImage:"trash", role:.destructive) { if scope == c.id { scope = "__all__" }; model.delete(c) }
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if !model.loaded {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60).listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "Save it for later." : "No matches", systemImage:"link")
                    } description: {
                        Text(query.isEmpty ? "Save web pages to come back to. Share a page from Safari, or tap + and paste a link. Notebook adds the page's title." : "Try another word.")
                    } actions: {
                        if query.isEmpty { Button("Add a link") { address = UIPasteboard.general.hasURLs ? (UIPasteboard.general.url?.absoluteString ?? "") : ""; adding = true } }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    ForEach(items) { link in
                        Button { if let url = URL(string:link.url) { openURL(url) } } label: { row(link) }
                            .buttonStyle(.plain)
                            .swipeActions { if link.editable { Button("Delete", role:.destructive) { model.delete(link) }; Button("Edit") { editing = link }.tint(.notebookBlue) } }
                            .contextMenu {
                                if link.editable { Button("Edit", systemImage:"pencil") { editing = link } }
                                Button("Copy link", systemImage:"doc.on.doc") { UIPasteboard.general.string = link.url }
                                ShareLink(item:URL(string:link.url) ?? URL(string:"https://")!) { Label("Share", systemImage:"square.and.arrow.up") }
                                if link.editable {
                                    Menu("Move to") {
                                        Button("Unsorted") { model.update(link, collection:.some(nil)) }
                                        ForEach(model.collections.filter(\.editable)) { c in Button(c.name) { model.update(link, collection:.some(c.id)) } }
                                    }
                                    Button("Delete", systemImage:"trash", role:.destructive) { model.delete(link) }
                                }
                            }
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(Color.notebookPaper)
            .searchable(text:$query, prompt:"Search links")
            .refreshable { await notebook.sync(); model.reload() }
            .navigationTitle(collection?.name ?? (scope == "__unsorted__" ? "Unsorted" : "Links"))
            .safeAreaInset(edge:.bottom) {
                if let info = notebook.sharing.share(collection?.share) { Text(shareLine(info)).font(.caption).foregroundStyle(.secondary).padding(6).frame(maxWidth:.infinity).background(.bar) }
            }
            .sheet(item:$sharingCollection) { c in
                ShareSheet(sharing:notebook.sharing, kind:"links", title:c.name, existing:c.share) { _ in await notebook.sharing.shareCollection(c) } onStopped: { scope = "__all__" }
            }
            .onReceive(NotificationCenter.default.publisher(for:.notebookSharesChanged)) { _ in model.reload() }
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) {
                    Menu {
                        Button("Add link", systemImage:"link.badge.plus") { address = UIPasteboard.general.hasURLs ? (UIPasteboard.general.url?.absoluteString ?? "") : ""; adding = true }.disabled(readOnly)
                        Button("New collection", systemImage:"folder.badge.plus") { name = ""; naming = LinkItem(raw:["type":"collection"]) }
                    } label: { Image(systemName:"plus") }.accessibilityLabel("Add")
                }
            }
            .alert("Add a link", isPresented:$adding) {
                TextField("https://", text:$address).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                Button("Save") { let text = address; Task { await model.add(text, collection:scope.hasPrefix("__") ? nil : scope) } }
                Button("Cancel", role:.cancel) { }
            } message: { Text(collection.map { "Saved in \($0.name)." } ?? "Notebook adds the page's title.") }
            .alert(naming?.id.isEmpty == false ? "Rename collection" : "New collection", isPresented:Binding(get:{ naming != nil }, set:{ if !$0 { naming = nil } })) {
                TextField("Name", text:$name)
                Button(naming?.id.isEmpty == false ? "Rename" : "Create") {
                    if let naming, !naming.id.isEmpty { model.rename(naming, to:name) } else if let created = model.addCollection(name) { scope = created.id }
                    naming = nil
                }
                Button("Cancel", role:.cancel) { naming = nil }
            }
            .sheet(item:$editing) { LinkEditorSheet(model:model, link:$0) }
            .alert("Links", isPresented:Binding(get:{ model.error != nil }, set:{ if !$0 { model.error = nil } })) { } message: { Text(model.error ?? "") }
            .onAppear { model.reload() }
        }
    }
    private func chip(_ title: String, _ id: String, icon: String? = nil) -> some View {
        Button { scope = id } label: { if let icon { Label(title, systemImage:icon) } else { Text(title) } }
            .font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
            .background(scope == id ? Color.notebookBlue : Color.secondary.opacity(0.12), in:Capsule())
            .foregroundStyle(scope == id ? Color.white : Color.primary)
            .buttonStyle(.plain)
    }
    private func row(_ link: LinkItem) -> some View {
        VStack(alignment:.leading, spacing:3) {
            Text(link.title).font(.headline).lineLimit(2)
            HStack(spacing:4) {
                Text(link.site)
                if !link.savedBy.isEmpty { Text("· " + link.savedBy) }
                if let date = ISO8601DateFormatter().date(from:link.createdAt) { Text("·"); Text(date, format:.relative(presentation:.named)) }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !link.note.isEmpty { Text(link.note).font(.subheadline).lineLimit(2) }
            if !link.tags.isEmpty { Text(link.tags.map { "#" + $0 }.joined(separator:" ")).font(.caption).foregroundStyle(Color.notebookBlue) }
        }
        .padding(.vertical, 4).contentShape(Rectangle())
    }
}

private struct LinkEditorSheet: View {
    @ObservedObject var model: LinksModel
    let link: LinkItem
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String
    @State private var tags: String
    @State private var collection: String
    init(model: LinksModel, link: LinkItem) {
        self.model = model; self.link = link
        _title = State(initialValue:link.title); _note = State(initialValue:link.note)
        _tags = State(initialValue:link.tags.joined(separator:", ")); _collection = State(initialValue:link.collection ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Text(link.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                TextField("Title", text:$title)
                Picker("Collection", selection:$collection) { Text("Unsorted").tag(""); ForEach(model.collections.filter(\.editable)) { Text($0.name).tag($0.id) } }
                TextField("Tags, separated by commas", text:$tags).textInputAutocapitalization(.never)
                TextField("Note", text:$note, axis:.vertical).lineLimit(3...8)
            }
            .navigationTitle("Edit link").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button("Save") {
                        let values = tags.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
                        let target = collection.isEmpty ? nil : collection
                        model.update(link, title:title != link.title ? title : nil, note:note != link.note ? note : nil, tags:values != link.tags ? values : nil, collection:target != link.collection ? .some(target) : nil)
                        dismiss()
                    }
                }
            }
        }
    }
}
