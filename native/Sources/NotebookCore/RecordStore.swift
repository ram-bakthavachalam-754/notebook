import Foundation
import CSQLite

public enum NotebookError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
public func jsonString(_ object: Any) throws -> String { String(decoding: try jsonData(object), as: UTF8.self) }
public func jsonObject(_ string: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(string.utf8), options: [.fragmentsAllowed]) }

/// An immutable revision, shared verbatim by both platforms. Parents express causality;
/// wall clocks never decide which edit survives. Deletions are durable revisions too.
public struct Revision: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var entity: String
    public var parents: [String]
    public var payload: String?
    public var created: String
    public var device: String
    public init(id: String = UUID().uuidString.lowercased(), kind: String, entity: String, parents: [String], payload: String?, created: String = ISO8601DateFormatter().string(from: Date()), device: String) {
        self.id = id; self.kind = kind; self.entity = entity; self.parents = parents.sorted(); self.payload = payload; self.created = created; self.device = device
    }
}

/// All writes, including the persistent upload queue, commit together. WAL permits the
/// Electron bridge and CloudKit process to open the same database safely.
public final class RecordStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw NotebookError.message("Cannot open Notebook database.") }
        sqlite3_busy_timeout(db, 10000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS revisions (id TEXT PRIMARY KEY, kind TEXT NOT NULL, entity TEXT NOT NULL, parents TEXT NOT NULL, payload TEXT, created TEXT NOT NULL, device TEXT NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0)")
        try execute("CREATE INDEX IF NOT EXISTS revisions_entity ON revisions(kind,entity)")
        try execute("CREATE INDEX IF NOT EXISTS revisions_pending ON revisions(uploaded)")
        if try metadata("revision-parents-v1") == nil {
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS revision_parents (kind TEXT NOT NULL, entity TEXT NOT NULL, parent TEXT NOT NULL, PRIMARY KEY(kind,entity,parent)) WITHOUT ROWID")
                try execute("INSERT OR IGNORE INTO revision_parents SELECT r.kind,r.entity,p.value FROM revisions r,json_each(r.parents) p")
                try execute("CREATE INDEX IF NOT EXISTS revisions_heads ON revisions(kind,entity,id)")
                try setMetadata("revision-parents-v1","1")
            }
        }
        if try metadata("device") == nil { try setMetadata("device", UUID().uuidString.lowercased()) }
        // Upgrade the short-lived Mac-only Finance keys without removing the originals.
        if try metadata("finance-records-v1") == nil {
            try transaction {
                for key in Self.financeFields.keys.sorted() {
                    if let raw = try metadata("kv:" + key), let blob = try jsonObject(raw) as? [String:Any] { try setFinanceInside(key,blob) }
                }
                try setMetadata("finance-records-v1","1")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }
    private func protected<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func statement(_ sql: String, _ args: [String?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw NotebookError.message(String(cString: sqlite3_errmsg(db))) }
        for (i, value) in args.enumerated() {
            if let value { sqlite3_bind_text(stmt, Int32(i+1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            else { sqlite3_bind_null(stmt, Int32(i+1)) }
        }
        return stmt
    }
    private func execute(_ sql: String, _ args: [String?] = []) throws {
        try protected {
            let stmt = try statement(sql, args); defer { sqlite3_finalize(stmt) }
            let result = sqlite3_step(stmt)
            guard result == SQLITE_DONE || result == SQLITE_ROW else { throw NotebookError.message(String(cString: sqlite3_errmsg(db))) }
        }
    }
    private func query(_ sql: String, _ args: [String?] = []) throws -> [[String?]] {
        try protected {
            let stmt = try statement(sql, args); defer { sqlite3_finalize(stmt) }
            var rows: [[String?]] = []
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw NotebookError.message(String(cString: sqlite3_errmsg(db))) }
                rows.append((0..<sqlite3_column_count(stmt)).map { i in sqlite3_column_type(stmt,i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt,i)) })
            }
            return rows
        }
    }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try protected {
            try execute("BEGIN IMMEDIATE")
            do { let value = try body(); try execute("COMMIT"); return value }
            catch { try? execute("ROLLBACK"); throw error }
        }
    }
    public func metadata(_ key: String) throws -> String? { try query("SELECT value FROM meta WHERE key=?", [key]).first?.first ?? nil }
    public func setMetadata(_ key: String, _ value: String?) throws {
        if let value { try execute("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key,value]) }
        else { try execute("DELETE FROM meta WHERE key=?", [key]) }
    }
    public func revisions(kind: String? = nil, entity: String? = nil, pending: Bool = false) throws -> [Revision] {
        var conditions = ["1=1"], args: [String?] = []
        if let kind { conditions.append("kind=?"); args.append(kind) }
        if let entity { conditions.append("entity=?"); args.append(entity) }
        if pending { conditions.append("uploaded=0") }
        return try query("SELECT id,kind,entity,parents,payload,created,device FROM revisions WHERE " + conditions.joined(separator:" AND ") + " ORDER BY id", args).map { row in
            Revision(id: row[0]!, kind: row[1]!, entity: row[2]!, parents: try JSONDecoder().decode([String].self, from: Data(row[3]!.utf8)), payload: row[4], created: row[5]!, device: row[6]!)
        }
    }
    public func heads(kind: String, entity: String) throws -> [Revision] {
        try currentRevisions(kind:kind,entity:entity)
    }
    private func currentRevisions(kind: String, entity: String? = nil) throws -> [Revision] {
        let filter = entity == nil ? "" : " AND r.entity=?"
        let args: [String?] = entity.map { [kind,$0] } ?? [kind]
        return try query("SELECT r.id,r.kind,r.entity,r.parents,r.payload,r.created,r.device FROM revisions r WHERE r.kind=?" + filter + " AND NOT EXISTS (SELECT 1 FROM revision_parents p WHERE p.kind=r.kind AND p.entity=r.entity AND p.parent=r.id) ORDER BY r.id",args).map { row in
            Revision(id:row[0]!,kind:row[1]!,entity:row[2]!,parents:try JSONDecoder().decode([String].self,from:Data(row[3]!.utf8)),payload:row[4],created:row[5]!,device:row[6]!)
        }
    }
    /// Changes whenever any revision is added, so readers can skip work when
    /// nothing changed. Revisions are never removed.
    public func changeStamp(kind: String? = nil) throws -> String {
        let row = try kind.map { try query("SELECT COUNT(*),MAX(rowid) FROM revisions WHERE kind=?", [$0]) } ?? query("SELECT COUNT(*),MAX(rowid) FROM revisions")
        return (row.first ?? []).map { $0 ?? "" }.joined(separator:"/")
    }
    public func pendingCount() throws -> Int {
        Int(try query("SELECT COUNT(*) FROM revisions WHERE uploaded=0").first?[0] ?? "0") ?? 0
    }
    public func mediaPreviews(_ ids: [String]) throws -> [String:String] { try previews(kind:"media",field:"thumb",imagesOnly:true,ids:ids) }
    /// Uploaded documents keep a small rendered preview beside their original bytes.
    public func documentPreviews(_ ids: [String], field: String = "thumb") throws -> [String:String] {
        guard ["thumb","preview"].contains(field) else { throw NotebookError.message("Invalid preview field.") }
        return try previews(kind:"documentData",field:field,imagesOnly:false,ids:ids)
    }
    private func previews(kind: String, field: String, imagesOnly: Bool, ids: [String]) throws -> [String:String] {
        guard ids.count <= 500 else { throw NotebookError.message("Too many media previews requested.") }
        var previews: [String:String] = [:]
        for id in Set(ids) {
            // Read only thumbnail fields, not original photo/video bytes or history.
            let rows = try query("SELECT r.payload IS NULL,json_extract(r.payload,'$.kind'),json_extract(r.payload,'$." + field + "') FROM revisions r WHERE r.kind=? AND r.entity=? AND NOT EXISTS (SELECT 1 FROM revision_parents p WHERE p.kind=r.kind AND p.entity=r.entity AND p.parent=r.id) ORDER BY r.id",[kind,id])
            guard !rows.contains(where: { $0[0] == "1" }), let first = rows.first,
                  !imagesOnly || first[1] == "image", let thumbnail = first[2] else { continue }
            previews[id] = thumbnail
        }
        return previews
    }
    public static let knownKinds: Set<String> = ["notes","journal","tags","media","finance","agentThreads","agentMessages","documents","documentData","links","family","money","accountViews","news","trading","explore"]
    /// Kinds this build doesn't know arrive from newer devices (links, shared
    /// accounts…). Keep them verbatim so sync continues and a later update can
    /// read them; they're never projected into collections or re-uploaded.
    /// Only this build's own kinds can be written locally.
    private static func acceptsKind(_ kind: String, received: Bool) -> Bool {
        if knownKinds.contains(kind) { return true }
        guard received, (1...32).contains(kind.count), let first = kind.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else { return false }
        return kind.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
    private func insert(_ revision: Revision, uploaded: Bool) throws {
        guard Self.acceptsKind(revision.kind, received:uploaded), !revision.entity.isEmpty, UUID(uuidString: revision.id) != nil,
              !revision.parents.contains(revision.id), revision.parents.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw NotebookError.message("Invalid sync revision.") }
        if let payload = revision.payload { guard (try jsonObject(payload)) is [String:Any] else { throw NotebookError.message("Invalid record data.") } }
        if let existing = try query("SELECT kind,entity,parents,payload,created,device FROM revisions WHERE id=?", [revision.id]).first {
            guard existing == [revision.kind,revision.entity,try jsonString(revision.parents),revision.payload,revision.created,revision.device] else { throw NotebookError.message("A sync revision was changed unexpectedly.") }
            if uploaded { try markUploaded([revision.id]) }
            return
        }
        try execute("INSERT INTO revisions VALUES(?,?,?,?,?,?,?,?)", [revision.id,revision.kind,revision.entity,try jsonString(revision.parents),revision.payload,revision.created,revision.device,uploaded ? "1" : "0"])
        for parent in revision.parents {
            try execute("INSERT OR IGNORE INTO revision_parents VALUES(?,?,?)",[revision.kind,revision.entity,parent])
        }
    }
    public func receive(_ revisions: [Revision]) throws {
        try transaction { for revision in revisions { try insert(revision, uploaded:true) } }
    }
    public func markUploaded(_ ids: [String]) throws { for id in ids { try execute("UPDATE revisions SET uploaded=1 WHERE id=?", [id]) } }
    public func records(_ kind: String, entity: String? = nil) throws -> [[String:Any]] {
        let grouped = Dictionary(grouping: try currentRevisions(kind:kind,entity:entity), by: \.entity)
        var output: [[String:Any]] = []
        for (entity, revisions) in grouped {
            let heads = revisions.sorted { $0.id < $1.id }
            let hasDeletion = heads.contains { $0.payload == nil }
            for (index, revision) in heads.filter({ $0.payload != nil }).enumerated() {
                var payload = try jsonObject(revision.payload!) as! [String:Any]
                let conflict = hasDeletion || index > 0
                payload["id"] = conflict ? entity + "~" + revision.id : entity
                payload["_syncEntity"] = entity
                payload["_syncHeads"] = [revision.id]
                payload["_syncAllHeads"] = heads.map(\.id)
                payload["_syncConflict"] = conflict
                payload["_syncVersions"] = heads.count
                output.append(payload)
            }
        }
        let iso = ISO8601DateFormatter(), fractional = ISO8601DateFormatter(), day = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; day.formatOptions = [.withFullDate]
        // Parse each distinct timestamp once, rather than twice for every
        // comparison. Reading a large library must not spend seconds sorting.
        // The apps write fractional seconds and older entries plain dates.
        var dates: [String:Date] = [:]
        func parsed(_ value: String) -> Date {
            if let cached = dates[value] { return cached }
            let date = iso.date(from:value) ?? fractional.date(from:value) ?? (value.count == 10 ? day.date(from:value) : nil) ?? .distantPast
            dates[value] = date; return date
        }
        let sorted = output.map { record in
            (record:record, primary:parsed(record[kind == "journal" ? "date" : "modifiedAt"] as? String ?? ""), modified:parsed(record["modifiedAt"] as? String ?? ""))
        }.sorted {
            // Journal chronology is the user-assigned entry date on every
            // client. Editing an older entry must not move it to today's date.
            if $0.primary != $1.primary { return $0.primary > $1.primary }
            // The desktop renderer uses this same secondary ordering when two
            // journal entries share a calendar date.
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return ($0.record["id"] as? String ?? "") < ($1.record["id"] as? String ?? "")
        }
        return sorted.map(\.record)
    }
    private func clean(_ value: [String:Any], entity: String) -> [String:Any] {
        var result = value.filter { !$0.key.hasPrefix("_sync") }; result["id"] = entity; return result
    }
    @discardableResult public func save(kind: String, record: [String:Any], resolve: Bool = false) throws -> [String:Any] {
        try transaction { try saveInside(kind:kind, record:record, resolve:resolve) }
    }
    private func saveInside(kind: String, record: [String:Any], resolve: Bool = false) throws -> [String:Any] {
        guard let id = record["id"] as? String, !id.isEmpty else { throw NotebookError.message("Record has no ID.") }
        let entity = record["_syncEntity"] as? String ?? id
        // Resolve only versions actually shown to the user. A remote version that
        // arrives while the confirmation is open must remain a separate head.
        let parents = resolve ? (record["_syncAllHeads"] as? [String] ?? record["_syncHeads"] as? [String] ?? []) : (record["_syncHeads"] as? [String] ?? [])
        let payload = try jsonString(clean(record, entity:entity))
        // Re-saving an unchanged stale collection must never resurrect an old version.
        if parents.count == 1, let old = try query("SELECT payload FROM revisions WHERE id=? AND kind=? AND entity=?",[parents[0],kind,entity]).first, old[0] == payload { return record }
        let revision = Revision(kind:kind, entity:entity, parents:parents, payload:payload, device:try metadata("device")!)
        try insert(revision, uploaded:false)
        var result = record; result["_syncEntity"] = entity; result["_syncHeads"] = [revision.id]
        result["_syncAllHeads"] = ((record["_syncAllHeads"] as? [String] ?? []).filter { !parents.contains($0) } + [revision.id]).sorted()
        return result
    }
    public func delete(kind: String, record: [String:Any]) throws {
        try transaction { try deleteInside(kind:kind, record:record) }
    }
    private func deleteInside(kind: String, record: [String:Any]) throws {
        guard let id = record["id"] as? String else { throw NotebookError.message("Record has no ID.") }
        let entity = record["_syncEntity"] as? String ?? id
        let parents = record["_syncHeads"] as? [String] ?? []
        try insert(Revision(kind:kind, entity:entity, parents:parents, payload:nil, device:try metadata("device")!), uploaded:false)
    }
    private func collection(_ key: String) -> (String,String)? {
        switch key {
        case "app_notes": return ("notes","notes")
        case "app_journal": return ("journal","entries")
        case "app_tags": return ("tags","tags")
        case "app_agentThreads": return ("agentThreads","threads")
        case "app_agentMessages": return ("agentMessages","messages")
        case "app_documents": return ("documents","documents")
        case "app_links": return ("links","links")
        case "app_money": return ("money","goals")
        default: return nil
        }
    }
    /// Large binary records live one entity per key: journal photos/videos and
    /// the original bytes of uploaded documents.
    static let attachmentPrefixes = ["app_journalMedia_":"media","app_documentData_":"documentData"]
    private func attachment(_ key: String) -> (String,String)? {
        for (prefix, kind) in Self.attachmentPrefixes where key.hasPrefix(prefix) { return (kind, String(key.dropFirst(prefix.count))) }
        return nil
    }
    private func attachmentRecord(_ kind: String, _ id: String) throws -> [String:Any]? {
        if let record = try records(kind,entity:id).first(where: { $0["id"] as? String == id }) { return record }
        if let separator = id.lastIndex(of:"~"), UUID(uuidString:String(id[id.index(after:separator)...])) != nil {
            return try records(kind,entity:String(id[..<separator])).first { $0["id"] as? String == id }
        }
        return nil
    }
    public func getKey(_ key: String) throws -> Any? {
        if Self.financeFields[key] != nil { return try financeBlob(key) }
        if let (kind, field) = collection(key) { return [field:try records(kind)] }
        if let (kind, id) = attachment(key) { return try attachmentRecord(kind,id) }
        return try metadata("kv:" + key).map { try jsonObject($0) }
    }
    /// Collection omissions aren't deletions. Only explicit removed records can delete;
    /// this protects remote additions from stale renderer snapshots.
    public func setKey(_ key: String, value: Any) throws -> Any {
        try transaction {
            if Self.financeFields[key] != nil {
                guard let blob = value as? [String:Any] else { throw NotebookError.message("Invalid Finance data.") }
                try setFinanceInside(key, blob); return try financeBlob(key)
            }
            if let (kind, field) = collection(key) {
                guard let value = value as? [String:Any], let records = value[field] as? [[String:Any]] else { throw NotebookError.message("Invalid collection.") }
                var saved: [[String:Any]] = []
                for record in records { saved.append(try saveInside(kind:kind, record:record)) }
                for record in value["_syncDeleted"] as? [[String:Any]] ?? [] { try deleteInside(kind:kind, record:record) }
                return [field:saved]
            }
            if let (kind, id) = attachment(key), var record = value as? [String:Any] {
                record["id"] = id
                if record["_syncHeads"] == nil, let old = try attachmentRecord(kind,id) { record["_syncHeads"] = old["_syncHeads"] }
                return try saveInside(kind:kind, record:record)
            }
            try setMetadata("kv:" + key, jsonString(value)); return value
        }
    }
    /// Every Finance record and the upload queue commit in the same transaction.
    public func setFinance(_ values: [String:Any]) throws {
        guard Set(values.keys) == Set(Self.financeFields.keys), values.values.allSatisfy({ $0 is [String:Any] }) else {
            throw NotebookError.message("Invalid Finance import.")
        }
        try transaction { for key in Self.financeFields.keys.sorted() { try setFinanceInside(key, values[key] as! [String:Any]) } }
    }
    public func deleteKey(_ key: String) throws {
        if Self.financeFields[key] != nil {
            var blob = try financeBlob(key)
            var tombstones = blob["tombstones"] as? [String:String] ?? [:]
            for field in Self.financeFields[key]! {
                for row in blob[field] as? [[String:Any]] ?? [] { if let id = row["id"] as? String ?? row["date"] as? String { tombstones[id] = ISO8601DateFormatter().string(from:Date()) } }
                blob[field] = [[String:Any]]()
            }
            blob["tombstones"] = tombstones; _ = try setKey(key,value:blob); return
        }
        if let (kind, _) = collection(key) { for record in try records(kind) { try delete(kind:kind, record:record) } }
        else if let (kind, _) = attachment(key), let record = try getKey(key) as? [String:Any] { try delete(kind:kind, record:record) }
        else { try setMetadata("kv:" + key, nil) }
    }
    public func keys() throws -> [String] {
        var attachments: [String] = []
        for (prefix, kind) in Self.attachmentPrefixes.sorted(by: { $0.key < $1.key }) { attachments += try records(kind).compactMap { ($0["id"] as? String).map { prefix + $0 } } }
        return ["app_notes","app_journal","app_tags","app_agentThreads","app_agentMessages","app_documents"] + Self.financeFields.keys.sorted() + attachments + (try query("SELECT key FROM meta WHERE key LIKE 'kv:%'").compactMap { $0[0].map { String($0.dropFirst(3)) } })
    }
    public func migrateLegacy(directory: URL) throws {
        guard try metadata("migration-v1") == nil else { return }
        let files = FileManager.default.fileExists(atPath: directory.path) ? try FileManager.default.contentsOfDirectory(at:directory, includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" } : []
        // Validate the complete source before writing; original files remain untouched.
        let values = try files.map { ($0.deletingPathExtension().lastPathComponent, try JSONSerialization.jsonObject(with: Data(contentsOf:$0), options: [.fragmentsAllowed])) }
        // setKey owns its transaction. The completion marker only follows all imports;
        // stable imported IDs/heads make an interrupted migration safe to retry.
        for (key, value) in values {
            if let (kind, _) = collection(key), !(try revisions(kind:kind)).isEmpty { continue }
            if attachment(key) != nil, try getKey(key) != nil { continue }
            _ = try setKey(key, value:value)
        }
        try setMetadata("migration-v1", "complete")
    }
}

// Finance keeps one entity per array record (and per snapshot day), so offline
// additions on separate devices union. Concurrent versions of the SAME record
// resolve deterministically by revision time/id; immutable history is retained.
// A stale, unchanged renderer row cannot create a revision or resurrect a delete.
extension RecordStore {
    static let financeFields = [
        "app_portfolio": ["accounts","transactions","properties","liabilities","strategies","watchlist","shares"],
        "app_portfolio-history": ["snapshots"],
        "app_spending": ["accounts","transactions","rules","links"]
    ]
    private func financeHeads(_ key: String) throws -> [String:[Revision]] {
        Dictionary(grouping:try currentRevisions(kind:"finance").filter { $0.entity.hasPrefix(key + "|") },by:\.entity)
    }
    private func financeWinner(_ heads: [Revision]) -> Revision? {
        heads.max { a,b in a.created == b.created ? a.id < b.id : a.created < b.created }
    }
    private func financeBlob(_ key: String) throws -> [String:Any] {
        let fields = Self.financeFields[key]!
        var blob: [String:Any] = Dictionary(uniqueKeysWithValues:fields.map { ($0, [[String:Any]]()) })
        var tombstones: [String:String] = [:]
        for (_, heads) in try financeHeads(key).sorted(by: { $0.key < $1.key }) {
            guard let winner = financeWinner(heads), let payload = winner.payload,
                  let wrapper = try jsonObject(payload) as? [String:Any], let field = wrapper["field"] as? String else { continue }
            if field == "_meta" { if let meta = wrapper["record"] as? [String:Any] { blob.merge(meta) { _,new in new }; tombstones.merge(meta["tombstones"] as? [String:String] ?? [:]) { old,_ in old } }; continue }
            guard fields.contains(field), let rowID = wrapper["rowID"] as? String else { continue }
            if let deleted = wrapper["deletedAt"] as? String { tombstones[rowID] = deleted; continue }
            guard var row = wrapper["record"] as? [String:Any] else { continue }
            row["_syncHeads"] = heads.map(\.id)
            row["_syncEntity"] = winner.entity
            var rows = blob[field] as? [[String:Any]] ?? []; rows.append(row); blob[field] = rows
        }
        if key == "app_portfolio-history", let rows = blob["snapshots"] as? [[String:Any]] { blob["snapshots"] = rows.sorted { ($0["date"] as? String ?? "") < ($1["date"] as? String ?? "") } }
        blob["tombstones"] = tombstones
        return blob
    }
    private func setFinanceInside(_ key: String, _ blob: [String:Any]) throws {
        guard let fields = Self.financeFields[key] else { throw NotebookError.message("Invalid Finance key.") }
        let existing = try financeHeads(key)
        let tombstones = blob["tombstones"] as? [String:String] ?? [:]
        func write(field: String, rowID: String, row: [String:Any]?, deletedAt: String? = nil) throws {
            // JSON-encode the ID so delimiters inside an imported ID cannot collide.
            let entity = key + "|" + field + "|" + (try jsonString(rowID))
            let heads = existing[entity] ?? []
            let cleanRow = row?.filter { !$0.key.hasPrefix("_sync") }
            let parents = row?["_syncHeads"] as? [String] ?? heads.map(\.id)
            for revision in try revisions(kind:"finance",entity:entity) where parents.contains(revision.id) {
                if let payload = revision.payload, let old = try jsonObject(payload) as? [String:Any] {
                    if let cleanRow, let oldRow = old["record"], try jsonString(cleanRow) == jsonString(oldRow) { return }
                    if let deletedAt, old["deletedAt"] as? String == deletedAt { return }
                }
            }
            var wrapper: [String:Any] = ["id":entity,"field":field,"rowID":rowID,"_syncHeads":parents]
            if let cleanRow { wrapper["record"] = cleanRow }
            if let deletedAt { wrapper["deletedAt"] = deletedAt }
            _ = try saveInside(kind:"finance",record:wrapper)
        }
        for field in fields {
            guard blob[field] == nil || blob[field] is [Any] else { throw NotebookError.message("Invalid Finance collection.") }
            for raw in blob[field] as? [Any] ?? [] {
                var row: [String:Any]
                if let object = raw as? [String:Any] { row = object }
                else if field == "watchlist", let symbol = raw as? String { row = ["id":"sym:" + symbol.uppercased(),"symbol":symbol] }
                else { throw NotebookError.message("Invalid Finance record.") }
                guard let id = row["id"] as? String ?? row["date"] as? String ?? row["symbol"] as? String, !id.isEmpty else { throw NotebookError.message("Finance record has no ID.") }
                if tombstones[id] == nil { try write(field:field,rowID:id,row:row) }
            }
        }
        for (_, heads) in existing {
            guard let winner = financeWinner(heads), let payload = winner.payload, let wrapper = try jsonObject(payload) as? [String:Any], let field = wrapper["field"] as? String, let id = wrapper["rowID"] as? String, let deleted = tombstones[id] else { continue }
            try write(field:field,rowID:id,row:nil,deletedAt:deleted)
        }
        var meta = blob.filter { !fields.contains($0.key) && !$0.key.hasPrefix("_sync") }; meta["tombstones"] = tombstones
        try write(field:"_meta",rowID:"meta",row:meta)
    }
}
