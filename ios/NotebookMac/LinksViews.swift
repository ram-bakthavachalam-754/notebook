import SwiftUI
import AppKit
import NotebookCore

/// "All links", "Unsorted", or a collection's id.
let allLinks = "__all__", unsortedLinks = "__unsorted__"

struct LinksCollections: View {
    @ObservedObject var links: LinksModel
    @ObservedObject var sharing: SharingModel
    @Binding var selection: String?
    @State private var sharingCollection: LinkItem?
    @State private var naming: LinkItem?
    @State private var name = ""
    @State private var deleting: LinkItem?
    var body: some View {
        List(selection:$selection) {
            row("All Links", icon:"link", count:links.links.count).tag(allLinks)
            row("Unsorted", icon:"tray", count:links.links.filter { $0.collection == nil || !links.collections.map(\.id).contains($0.collection!) }.count).tag(unsortedLinks)
            Section("Collections") { ForEach(links.collections.filter { !$0.sharedWithMe }) { collectionRow($0) } }
            let shared = links.collections.filter(\.sharedWithMe)
            if !shared.isEmpty { Section("Shared with You") { ForEach(shared) { collectionRow($0) } } }
        }
        .navigationTitle("Links")
        .navigationSplitViewColumnWidth(min:200, ideal:240)
        .toolbar { Button { name = ""; naming = LinkItem(raw:["type":"collection"]) } label: { Label("New Collection", systemImage:"folder.badge.plus") }.help("New collection") }
        .onAppear { links.reload() }
        .alert(naming?.id.isEmpty == false ? "Rename Collection" : "New Collection", isPresented:Binding(get:{ naming != nil }, set:{ if !$0 { naming = nil } })) {
            TextField("Name", text:$name)
            Button(naming?.id.isEmpty == false ? "Rename" : "Create") {
                if let naming, !naming.id.isEmpty { links.rename(naming, to:name) }
                else if let created = links.addCollection(name) { selection = created.id }
                naming = nil
            }
            Button("Cancel", role:.cancel) { naming = nil }
        } message: { Text("For example Reading list, Recipes or Science videos.") }
        .confirmationDialog(deleteTitle, isPresented:deletingShown, presenting:deleting) { collection in
            Button(collection.sharedWithMe ? "Leave Collection" : "Delete Collection", role:.destructive) { if selection == collection.id { selection = allLinks }; links.delete(collection) }
        } message: { collection in
            Text(deleteMessage(collection))
        }
        .sheet(item:$sharingCollection) { collection in
            ShareSheet(sharing:sharing, kind:"links", title:collection.name, existing:collection.share) { _ in await sharing.shareCollection(collection) }
                onStopped: { selection = allLinks }
        }
        .onReceive(NotificationCenter.default.publisher(for:.notebookSharesChanged)) { _ in links.reload() }
    }
    private var deletingShown: Binding<Bool> { Binding(get:{ deleting != nil }, set:{ if !$0 { deleting = nil } }) }
    private var deleteTitle: String {
        let verb = deleting?.sharedWithMe == true ? "Leave" : "Delete"
        return "\(verb) “\(deleting?.name ?? "")”?"
    }
    private func deleteMessage(_ collection: LinkItem) -> String {
        if collection.sharedWithMe { return "It's removed from your Links. The owner keeps it." }
        if collection.share != nil { return "It's shared, so this deletes it and its links for everyone on it." }
        return "Its links are kept in Unsorted."
    }
    private func collectionRow(_ collection: LinkItem) -> some View {
        row(collection.name, icon:collection.share == nil ? "folder" : "folder.badge.person.crop", count:links.links.filter { $0.collection == collection.id }.count).tag(collection.id)
            .contextMenu {
                if sharing.canShare("links") { Button(collection.share == nil ? "Share…" : "Sharing…") { sharingCollection = collection } }
                if collection.editable { Button("Rename…") { name = collection.name; naming = collection } }
                Button(collection.sharedWithMe ? "Leave Collection…" : "Delete Collection…", role:.destructive) { deleting = collection }
            }
            .dropDestination(for:URL.self) { urls, _ in guard collection.editable else { return false }; add(urls, to:collection.id); return true }
    }
    private func row(_ title: String, icon: String, count: Int) -> some View { Label { Text(title) } icon: { Image(systemName:icon).foregroundStyle(.blue) }.badge(count) }
    private func add(_ urls: [URL], to collection: String) {
        Task { for url in urls where ["http","https"].contains(url.scheme ?? "") { await links.add(url.absoluteString, collection:collection) } }
    }
}

struct LinksList: View {
    @ObservedObject var links: LinksModel
    @ObservedObject var sharing: SharingModel
    let scope: String
    @State private var address = ""
    @State private var query = ""
    @State private var adding = false
    @State private var dropping = false
    @State private var editing: LinkItem?
    @State private var sharingSheet = false
    @FocusState private var addressFocused: Bool
    private var collection: LinkItem? { links.collections.first { $0.id == scope } }
    private var readOnly: Bool { collection.map { !$0.editable } ?? false }
    private var subtitle: String {
        let count = items.count == 1 ? "1 link" : "\(items.count) links"
        guard let collection, let info = sharing.share(collection.share) else { return count }
        return count + " · " + shareLine(info)
    }
    private var items: [LinkItem] {
        let ids = Set(links.collections.map(\.id))
        let q = query.trimmingCharacters(in:.whitespaces).lowercased()
        return links.links.filter { link in
            (scope == allLinks || (scope == unsortedLinks ? link.collection.map { !ids.contains($0) } ?? true : link.collection == scope))
                && (q.isEmpty || [link.title, link.url, link.site, link.note].contains { $0.lowercased().contains(q) } || link.tags.contains { $0.lowercased().contains(q) })
        }
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"link").font(.system(size:13, weight:.semibold)).foregroundStyle(.blue)
                TextField("Paste a link to save it\(collection.map { " in \($0.name)" } ?? "")", text:$address).textFieldStyle(.plain).focused($addressFocused).onSubmit(add)
                if adding { ProgressView().controlSize(.small) }
                Button("Save", action:add).buttonStyle(.borderedProminent).controlSize(.small).disabled(address.trimmingCharacters(in:.whitespaces).isEmpty || adding)
            }
            .disabled(readOnly)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.cardFill, in:RoundedRectangle(cornerRadius:12, style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:12, style:.continuous).strokeBorder(addressFocused ? Color.blue.opacity(0.6) : Color.cardStroke))
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
            List {
                ForEach(items) { link in
                    LinkRow(link:link, collection:scope == allLinks ? links.collections.first { $0.id == link.collection }?.name : nil)
                        .contentShape(Rectangle())
                        .onTapGesture(count:2) { open(link) }
                        .contextMenu { menu(link) }
                        .help(link.share != nil && !link.editable ? "View only" : link.url)
                }
            }
            .overlay {
                if !links.loaded { ProgressView() }
                else if links.links.isEmpty { ContentUnavailableView("No links yet", systemImage:"link", description:Text("Paste a link above or drop one from your browser. Notebook adds the page's title.")) }
                else if items.isEmpty && !query.isEmpty { ContentUnavailableView.search(text:query) }
                else if items.isEmpty { ContentUnavailableView("No links here", systemImage:"folder", description:Text("Drop a link here or paste one above.")) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius:8).stroke(dropping ? Color.notebookBlue : .clear, lineWidth:2).allowsHitTesting(false))
        .dropDestination(for:URL.self) { urls, _ in
            guard !readOnly else { return false }
            Task { for url in urls where ["http","https"].contains(url.scheme ?? "") { await links.add(url.absoluteString, collection:target) } }
            return true
        } isTargeted: { dropping = $0 }
        .searchable(text:$query, prompt:"Search links")
        .navigationTitle(collection?.name ?? (scope == unsortedLinks ? "Unsorted" : "All Links"))
        .navigationSubtitle(subtitle)
        .toolbar {
            if let collection, sharing.canShare("links") {
                Button { sharingSheet = true } label: { Label("Share", systemImage:collection.share == nil ? "person.crop.circle.badge.plus" : "person.2.fill") }.help(collection.share == nil ? "Share this collection" : "Sharing")
            }
            Button { addressFocused = true } label: { Label("Add Link", systemImage:"plus") }.keyboardShortcut("l", modifiers:[.command, .shift]).help("Add a link (⇧⌘L)").disabled(readOnly)
        }
        .sheet(isPresented:$sharingSheet) {
            if let collection { ShareSheet(sharing:sharing, kind:"links", title:collection.name, existing:collection.share) { _ in await sharing.shareCollection(collection) } }
        }
        .sheet(item:$editing) { LinkEditor(links:links, link:$0) }
        .alert("Links", isPresented:Binding(get:{ links.error != nil }, set:{ if !$0 { links.error = nil } })) { } message: { Text(links.error ?? "") }
    }
    /// New links go into the collection being shown.
    private var target: String? { scope == allLinks || scope == unsortedLinks ? nil : scope }
    private func add() {
        let text = address
        guard !text.trimmingCharacters(in:.whitespaces).isEmpty else { return }
        adding = true
        Task { if await links.add(text, collection:target) != nil { address = "" }; adding = false }
    }
    private func open(_ link: LinkItem) { if let url = URL(string:link.url) { NSWorkspace.shared.open(url) } }
    @ViewBuilder private func menu(_ link: LinkItem) -> some View {
        Button("Open in Browser") { open(link) }
        Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.url, forType:.string) }
        if link.editable {
            Button("Edit…") { editing = link }
            Menu("Move to") {
                Button("Unsorted") { links.update(link, collection:.some(nil)) }.disabled(link.collection == nil)
                ForEach(links.collections.filter(\.editable)) { c in Button(c.name) { links.update(link, collection:.some(c.id)) }.disabled(link.collection == c.id) }
            }
            Divider()
            Button("Delete", role:.destructive) { links.delete(link) }
        }
    }
}

private struct LinkRow: View {
    let link: LinkItem
    let collection: String?
    var body: some View {
        HStack(alignment:.top, spacing:12) {
            let labels = link.site.split(separator:"."), name = labels.count >= 2 ? String(labels[labels.count - 2]) : link.site
            Monogram(text:name, tint:Monogram.tint(for:name), size:34)
            VStack(alignment:.leading, spacing:3) {
                Text(link.title).font(.system(.body, weight:.semibold)).lineLimit(2)
                HStack(spacing:5) {
                    Text(link.site)
                    if let collection { Text("·"); Label(collection, systemImage:"folder").labelStyle(.titleAndIcon) }
                    if let date = ISO8601DateFormatter().date(from:link.createdAt) { Text("·"); Text(date, format:.relative(presentation:.named)) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !link.note.isEmpty { Text(link.note).font(.callout).foregroundStyle(.secondary).lineLimit(2).padding(.top, 2) }
                if !link.tags.isEmpty { HStack(spacing:4) { ForEach(link.tags, id:\.self) { Pill(text:"#" + $0, tint:.blue) } }.padding(.top, 2) }
            }
        }
        .padding(.vertical, 6)
        .help(link.savedBy.isEmpty ? link.url : link.url + "\nSaved from " + link.savedBy)
    }
}

private struct LinkEditor: View {
    @ObservedObject var links: LinksModel
    let link: LinkItem
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String
    @State private var tags: String
    @State private var collection: String
    init(links: LinksModel, link: LinkItem) {
        self.links = links; self.link = link
        _title = State(initialValue:link.title); _note = State(initialValue:link.note)
        _tags = State(initialValue:link.tags.joined(separator:", ")); _collection = State(initialValue:link.collection ?? "")
    }
    var body: some View {
        EditorSheet(title:"Edit Link", width:480, height:400) {
            Section {
                TextField("Title", text:$title)
                Picker("Collection", selection:$collection) {
                    Text("Unsorted").tag("")
                    ForEach(links.collections.filter(\.editable)) { Text($0.name).tag($0.id) }
                }
                TextField("Tags", text:$tags, prompt:Text("Separated by commas"))
                TextField("Note", text:$note, axis:.vertical).lineLimit(3...8)
            } footer: { Text(link.url).textSelection(.enabled).lineLimit(2) }
        } actions: {
            Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
    }
    private func save() {
        let values = tags.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        let newCollection = collection.isEmpty ? nil : collection
        links.update(link, title:title != link.title ? title : nil, note:note != link.note ? note : nil, tags:values != link.tags ? values : nil,
                     collection:newCollection != link.collection ? .some(newCollection) : nil)
        dismiss()
    }
}
