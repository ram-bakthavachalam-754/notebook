import Foundation
import SwiftUI
import NotebookCore

/// A file the user added: metadata and recognized text in the `documents`
/// collection, bytes and previews in `app_documentData_<id>`, like journal media.
struct DocumentItem: Identifiable, Hashable {
    var raw: [String:Any]
    var id: String { raw["id"] as? String ?? "" }
    var name: String { raw["name"] as? String ?? "Document" }
    var type: String { raw["type"] as? String ?? "application/octet-stream" }
    var size: Int { raw["size"] as? Int ?? 0 }
    var pages: Int { raw["pages"] as? Int ?? 0 }
    var text: String { raw["text"] as? String ?? "" }
    var textStatus: String { raw["textStatus"] as? String ?? "unsupported" }
    var textMethod: String { raw["textMethod"] as? String ?? "none" }
    var textMessage: String { raw["textMessage"] as? String ?? "" }
    var notes: String { raw["notes"] as? String ?? "" }
    var tags: [String] { raw["tags"] as? [String] ?? [] }
    var createdAt: String { raw["createdAt"] as? String ?? "" }
    var hasPreview: Bool { raw["hasPreview"] as? Bool ?? false }
    var isImage: Bool { type.hasPrefix("image/") }
    var kindLabel: String {
        if type == "application/pdf" { return "PDF" }
        if isImage { return "Image" }
        if type.contains("spreadsheetml") { return "Excel" }
        if type.contains("wordprocessingml") { return "Word" }
        if type.contains("presentationml") { return "PowerPoint" }
        if type.hasPrefix("text/") || type.contains("json") || type.contains("xml") { return "Text" }
        return "File"
    }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount:Int64(size),countStyle:.file) }
    var statusLabel: String {
        switch textStatus {
        case "ready": return (textMethod.contains("ocr") ? "Text recognized · " : "Text ready · ") + text.count.formatted() + " characters"
        case "empty": return "No readable text found"
        case "failed": return "Could not read: " + textMessage
        default: return "Kept as a file · text not available for this type"
        }
    }
    var attachment: [String:Any] { ["id":id,"name":name,"type":type] }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.raw["modifiedAt"] as? String == rhs.raw["modifiedAt"] as? String }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor final class DocumentsModel: ObservableObject {
    @Published private(set) var loaded = false
    @Published var documents: [DocumentItem] = []
    @Published var importing: String?
    @Published var error: String?
    private weak var notebook: NotebookModel?
    private let store: RecordStore
    init(notebook: NotebookModel) { self.notebook = notebook; store = notebook.store; reload() }
    private func checkAccess() throws { guard notebook?.unlocked == true else { throw NotebookError.message("Unlock Notebook to continue.") } }
    func reload() {
        guard notebook?.unlocked == true else { documents = []; return }
        let store = store
        Task { [weak self] in
            do {
                let rows = try await Task.detached(priority:.userInitiated) { try store.records("documents") }.value
                self?.documents = rows.map { DocumentItem(raw:$0) }
                self?.loaded = true
            } catch { self?.error = error.localizedDescription }
        }
    }
    /// Files from the Files app or a share; each is saved as soon as it is read.
    @discardableResult func importFiles(_ urls: [URL], source: String) async -> [DocumentItem] {
        var added: [DocumentItem] = []
        for (index, url) in urls.prefix(20).enumerated() {
            importing = "Reading \(url.lastPathComponent)… (\(index + 1) of \(min(urls.count,20)))"
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf:url)
                added.append(try await importData(data,name:url.lastPathComponent,type:nil,source:source))
            } catch { self.error = "\(url.lastPathComponent): \(error.localizedDescription)" }
        }
        importing = nil
        return added
    }
    func importData(_ data: Data, name: String, type: String?, source: String) async throws -> DocumentItem {
        try checkAccess()
        guard !data.isEmpty else { throw NotebookError.message("This file is empty.") }
        guard data.count <= DocumentText.maxBytes else { throw NotebookError.message("Files larger than 25 MB cannot be imported.") }
        let safe = String(name.split(separator:"/").last.map(String.init) ?? name).replacingOccurrences(of:":",with:"-").prefix(200)
        let cleanName = safe.isEmpty ? "Document" : String(safe)
        let extracted = await Task.detached(priority:.userInitiated) { DocumentText.extract(name:cleanName,type:type,data:data) }.value
        try checkAccess()
        let now = ISO8601DateFormatter().string(from:Date()), id = UUID().uuidString.lowercased()
        let resolved = extracted["type"] as? String ?? "application/octet-stream"
        var row: [String:Any] = ["id":id,"name":cleanName,"type":resolved,"size":data.count,"pages":extracted["pages"] as? Int ?? 0,"text":extracted["text"] as? String ?? "","textStatus":extracted["status"] as? String ?? "unsupported","textMethod":extracted["method"] as? String ?? "none","textMessage":extracted["message"] as? String ?? "","notes":"","tags":[String](),"source":source,"hasPreview":extracted["preview"] != nil,"createdAt":now,"modifiedAt":now]
        var bytes: [String:Any] = ["id":id,"name":cleanName,"type":resolved,"size":data.count,"data":"data:" + resolved + ";base64," + data.base64EncodedString()]
        bytes["preview"] = extracted["preview"] ?? NSNull(); bytes["thumb"] = extracted["thumb"] ?? NSNull()
        let store = store
        let saved = try await Task.detached(priority:.userInitiated) { () throws -> [String:Any] in
            _ = try store.setKey("app_documentData_" + id,value:bytes)
            let result = try store.setKey("app_documents",value:["documents":[row]]) as? [String:Any]
            return (result?["documents"] as? [[String:Any]])?.first ?? row
        }.value
        row = saved
        notebook?.reload(); reload()
        Task { await notebook?.sync() }
        return DocumentItem(raw:row)
    }
    func update(_ item: DocumentItem, name: String? = nil, notes: String? = nil, tags: [String]? = nil) {
        do {
            try checkAccess()
            var row = item.raw
            if let name { let clean = name.trimmingCharacters(in:.whitespacesAndNewlines); if !clean.isEmpty { row["name"] = String(clean.prefix(200)) } }
            if let notes { row["notes"] = String(notes.prefix(20000)) }
            if let tags { row["tags"] = tags.map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty } }
            row["modifiedAt"] = ISO8601DateFormatter().string(from:Date())
            _ = try store.setKey("app_documents",value:["documents":[row]])
            reload(); notebook?.reload()
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ item: DocumentItem) {
        do {
            try checkAccess()
            _ = try store.setKey("app_documents",value:["documents":[],"_syncDeleted":[item.raw]])
            try? store.deleteKey("app_documentData_" + item.id)
            reload(); notebook?.reload()
            Task { await notebook?.sync() }
        } catch { self.error = error.localizedDescription }
    }
    private func dataURL(_ id: String, field: String) async -> String? {
        let store = store
        return await Task.detached(priority:.userInitiated) { (try? store.getKey("app_documentData_" + id) as? [String:Any])?[field] as? String }.value
    }
    func preview(_ item: DocumentItem, field: String = "preview") async -> PlatformImage? {
        guard let value = await dataURL(item.id,field:field), let comma = value.firstIndex(of:","), let data = Data(base64Encoded:String(value[value.index(after:comma)...])) else { return nil }
        return PlatformImage(data:data)
    }
    /// A private temporary copy for sharing or Quick Look; cleared when the app is backgrounded.
    func fileURL(_ item: DocumentItem) async -> URL? {
        guard let value = await dataURL(item.id,field:"data"), let comma = value.firstIndex(of:","), let data = Data(base64Encoded:String(value[value.index(after:comma)...])) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("documents/" + item.id,isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let url = directory.appendingPathComponent(item.name)
            try data.write(to:url,options:[.atomic,.completeFileProtection])
            return url
        } catch { self.error = error.localizedDescription; return nil }
    }
    static func clearTemporaryCopies() { try? FileManager.default.removeItem(at:FileManager.default.temporaryDirectory.appendingPathComponent("documents")) }
}
