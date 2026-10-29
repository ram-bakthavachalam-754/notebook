import Foundation
import CloudKit
import CryptoKit

/// Someone on a share, as its owner sees them.
public struct SharePerson: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var email: String
    public var canEdit: Bool
    /// "pending", "accepted", "removed" or "unknown", from CloudKit.
    public var status: String
    public init(name: String, email: String, canEdit: Bool, status: String) { self.name = name; self.email = email; self.canEdit = canEdit; self.status = status }
}

/// One shared item: a note, a links collection or a view-only finance account.
/// It lives in its own CloudKit zone (`Share-<id>`), its own local store and
/// its own key, so it never mixes with the private notebook or other shares.
public struct ShareInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// "note", "links" or "account".
    public var kind: String
    /// The shared item's ID: the note, the collection or the account.
    public var entity: String
    public var title: String
    public var owner: Bool
    public var ownerName: String
    public var ownerEmail: String
    /// The zone owner's user record name (CKCurrentUserDefaultName for our own).
    public var zoneOwner: String
    public var canEdit: Bool
    /// For an account: "balance", "holdings" or "transactions".
    public var level: String
    public var people: [SharePerson]
    /// The key and details have arrived, so the item can be shown.
    public var ready: Bool
    /// The owner's device has created the zone and CKShare in iCloud.
    public var published: Bool
    public init(id: String, kind: String, entity: String, title: String, owner: Bool, ownerName: String = "", ownerEmail: String = "", zoneOwner: String = CKCurrentUserDefaultName,
                canEdit: Bool = true, level: String = "", people: [SharePerson] = [], ready: Bool = false, published: Bool = false) {
        self.id = id; self.kind = kind; self.entity = entity; self.title = title; self.owner = owner; self.ownerName = ownerName; self.ownerEmail = ownerEmail
        self.zoneOwner = zoneOwner; self.canEdit = canEdit; self.level = level; self.people = people; self.ready = ready; self.published = published
    }
    /// The record kinds each kind of share may hold. Anything else arriving in
    /// a share zone is refused, so a participant can't plant other records.
    public static let kinds: [String:Set<String>] = ["note":["notes","media"], "links":["links"], "account":["accountViews"]]
    public static let levels = ["balance", "holdings", "transactions"]
    public var zoneName: String { "Share-" + id }
}

/// Everything about shares that stays on this device: the list of shares,
/// each share's local record store and its key. No network here, so the
/// share bookkeeping is testable on its own.
public final class ShareLibrary: @unchecked Sendable {
    public let notebook: RecordStore
    public let directory: URL
    private let lock = NSRecursiveLock()
    private var stores: [String:RecordStore] = [:]
    private let readKey: (String) throws -> Data?
    private let writeKey: (String, Data?) throws -> Void
    /// Keys default to the Keychain; tests pass an in-memory pair.
    public init(notebook: RecordStore, keys: ((String) throws -> Data?, (String, Data?) throws -> Void)? = nil) {
        self.notebook = notebook
        directory = notebook.url.deletingLastPathComponent().appendingPathComponent("Shares")
        readKey = keys?.0 ?? { try NotebookKeychain.read("share:" + $0) }
        writeKey = keys?.1 ?? { id, data in
            if let data { try NotebookKeychain.write(data, account:"share:" + id) } else { NotebookKeychain.remove("share:" + id) }
        }
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    public func shares() -> [ShareInfo] {
        locked { (try? notebook.metadata("shares-v1")).flatMap { try? JSONDecoder().decode([ShareInfo].self, from:Data($0.utf8)) } ?? [] }
    }
    public func share(_ id: String) -> ShareInfo? { shares().first { $0.id == id } }
    public func share(kind: String, entity: String) -> ShareInfo? { shares().first { $0.kind == kind && $0.entity == entity } }
    private func save(_ list: [ShareInfo]) throws { try notebook.setMetadata("shares-v1", String(decoding:try JSONEncoder().encode(list), as:UTF8.self)) }
    public func upsert(_ info: ShareInfo) throws {
        try locked {
            var list = shares()
            if let index = list.firstIndex(where: { $0.id == info.id }) { list[index] = info } else { list.append(info) }
            try save(list)
        }
    }
    @discardableResult public func update(_ id: String, _ change: (inout ShareInfo) -> Void) throws -> ShareInfo? {
        try locked {
            guard var info = share(id) else { return nil }
            change(&info); try upsert(info); return info
        }
    }
    /// Forgets a share on this device: its records, key and sync position.
    public func remove(_ id: String) throws {
        try locked {
            try save(shares().filter { $0.id != id })
            stores.removeValue(forKey:id)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at:directory.appendingPathComponent(id + ".sqlite" + suffix)) }
            try writeKey(id, nil)
            try notebook.setMetadata("share-token:" + id, nil)
        }
    }
    public func store(_ id: String) throws -> RecordStore {
        try locked {
            guard UUID(uuidString:id) != nil else { throw NotebookError.message("Invalid share.") }
            if let store = stores[id] { return store }
            let store = try RecordStore(url:directory.appendingPathComponent(id + ".sqlite"))
            stores[id] = store; return store
        }
    }
    public func key(_ id: String) throws -> Data? { try readKey(id) }
    public func setKey(_ id: String, _ key: Data) throws {
        guard key.count == 32 else { throw NotebookError.message("Invalid share key.") }
        if let existing = try readKey(id), existing == key { return }
        try writeKey(id, key)
    }

    /// A new share on the owner's device, holding copies of the item's
    /// records. Nothing is sent anywhere until it's published.
    public func create(kind: String, entity: String, title: String, ownerName: String, level: String = "", records: [(kind: String, record: [String:Any])]) throws -> ShareInfo {
        guard let allowed = ShareInfo.kinds[kind], records.allSatisfy({ allowed.contains($0.kind) }) else { throw NotebookError.message("This can't be shared.") }
        if let existing = share(kind:kind, entity:entity) { return existing }
        let info = ShareInfo(id:UUID().uuidString.lowercased(), kind:kind, entity:entity, title:title, owner:true, ownerName:ownerName, level:level, ready:true)
        try setKey(info.id, SyncCrypto.randomKey())
        let store = try store(info.id)
        for item in records { _ = try store.save(kind:item.kind, record:Self.fresh(item.record)) }
        try upsert(info)
        return info
    }
    /// A record without its history in another store, so it starts a new one.
    public static func fresh(_ record: [String:Any]) -> [String:Any] {
        var copy = record.filter { !$0.key.hasPrefix("_sync") }
        if let entity = record["_syncEntity"] as? String { copy["id"] = entity }
        return copy
    }
    /// Copies a share's records back into the private notebook, continuing
    /// each record's own history there (a note deleted when it was shared
    /// comes back as the same note). Records the notebook already has a live
    /// version of are left alone.
    public func restore(_ id: String) throws -> Int {
        guard let info = share(id), let kinds = ShareInfo.kinds[info.kind] else { return 0 }
        let store = try store(id)
        var restored = 0
        do {
            for kind in kinds.sorted() where kind != "accountViews" {
                // Every version of a record comes back, so two kept versions stay two.
                for (entity, versions) in Dictionary(grouping:try store.records(kind), by:{ $0["_syncEntity"] as? String ?? "" }) where !entity.isEmpty {
                    let heads = try notebook.heads(kind:kind, entity:entity).map(\.id)
                    if kind == "media", try notebook.heads(kind:kind, entity:entity).contains(where: { $0.payload != nil }) { continue }
                    for record in versions {
                        var copy = Self.fresh(record)
                        copy["_syncEntity"] = entity; copy["_syncHeads"] = heads
                        _ = try notebook.save(kind:kind, record:copy)
                        restored += 1
                    }
                }
            }
        }
        return restored
    }

    // MARK: Encryption and checks for what travels through a share zone.
    public static func context(_ shareID: String, _ recordName: String) -> String { "Notebook share v1|" + shareID + "|" + recordName }
    public func seal(_ revision: Revision, share: String) throws -> Data {
        guard let key = try key(share) else { throw NotebookError.message("This share's key is missing.") }
        return try SyncCrypto.seal(JSONEncoder().encode(revision), key:key, context:Self.context(share, revision.id))
    }
    public func open(_ data: Data, share info: ShareInfo, recordName: String) throws -> Revision {
        guard let key = try key(info.id) else { throw NotebookError.message("This share's key is missing.") }
        let revision = try JSONDecoder().decode(Revision.self, from:SyncCrypto.open(data, key:key, context:Self.context(info.id, recordName)))
        guard revision.id == recordName else { throw NotebookError.message("Invalid encrypted record identity.") }
        try Self.check(revision, info)
        return revision
    }
    /// A shared note holds that note and its photos; an account holds only its
    /// view. A links collection holds the collection and links in it.
    public static func check(_ revision: Revision, _ info: ShareInfo) throws {
        guard ShareInfo.kinds[info.kind]?.contains(revision.kind) == true else { throw NotebookError.message("A shared item contained a record it shouldn't.") }
        if (info.kind == "note" && revision.kind == "notes") || info.kind == "account", revision.entity != info.entity {
            throw NotebookError.message("A shared item contained a record it shouldn't.")
        }
    }
    public static func encodeInfo(_ info: ShareInfo) throws -> Data {
        try jsonData(["kind":info.kind, "entity":info.entity, "title":info.title, "ownerName":info.ownerName, "level":info.level])
    }
    /// Applies the details the owner published (never the owner flag or permission).
    public static func applyInfo(_ data: Data, to info: inout ShareInfo) throws {
        guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any], let kind = object["kind"] as? String, ShareInfo.kinds[kind] != nil,
              let entity = object["entity"] as? String, !entity.isEmpty else { throw NotebookError.message("A shared item's details couldn't be read.") }
        if info.ready, info.kind != kind || info.entity != entity { throw NotebookError.message("A shared item changed what it is.") }
        info.kind = kind; info.entity = entity
        info.title = String((object["title"] as? String ?? "").prefix(200))
        if !info.owner, let name = object["ownerName"] as? String, !name.isEmpty { info.ownerName = String(name.prefix(100)) }
        let level = object["level"] as? String ?? ""
        info.level = ShareInfo.levels.contains(level) ? level : (kind == "account" ? "balance" : "")
    }

    /// Messages for the person, such as a share that was stopped. Shown once.
    public func notices() -> [String] { locked { (try? notebook.metadata("share-notices")).flatMap { try? JSONDecoder().decode([String].self, from:Data($0.utf8)) } ?? [] } }
    public func addNotice(_ text: String) { locked { try? notebook.setMetadata("share-notices", String(decoding:(try? JSONEncoder().encode(notices() + [text])) ?? Data("[]".utf8), as:UTF8.self)) } }
    public func clearNotices() { locked { try? notebook.setMetadata("share-notices", nil) } }
}

/// Moves shared items through iCloud. The owner's zones are in their private
/// database; everyone else sees them in their shared database. This doesn't
/// touch the private notebook's zone or its sync engine: it reads and writes
/// only `Share-` zones, with plain CloudKit change fetches.
public actor ShareSync {
    public nonisolated let library: ShareLibrary
    public nonisolated let containerID: String
    private var running = false
    public init(library: ShareLibrary, container: String) { self.library = library; containerID = container }
    private var container: CKContainer { CKContainer(identifier:containerID) }
    private func database(_ info: ShareInfo) -> CKDatabase { info.owner ? container.privateCloudDatabase : container.sharedCloudDatabase }
    private func zoneID(_ info: ShareInfo) -> CKRecordZone.ID { CKRecordZone.ID(zoneName:info.zoneName, ownerName:info.owner ? CKCurrentUserDefaultName : info.zoneOwner) }
    private func record(_ name: String, _ info: ShareInfo) -> CKRecord.ID { CKRecord.ID(recordName:name, zoneID:zoneID(info)) }
    private static func shareID(_ zone: CKRecordZone.ID) -> String? {
        guard zone.zoneName.hasPrefix("Share-") else { return nil }
        let id = String(zone.zoneName.dropFirst(6))
        return UUID(uuidString:id) != nil ? id.lowercased() : nil
    }
    private func ready() async throws {
        guard CloudSync.provisioned(container:containerID) else { throw NotebookError.message("Sharing needs a signed build with iCloud turned on.") }
        guard try await container.accountStatus() == .available else { throw NotebookError.message("Sign in to iCloud to share.") }
        let current = try await container.userRecordID().recordName
        if let bound = try library.notebook.metadata("cloud-account"), bound != current {
            throw NotebookError.message("The iCloud account changed. Sharing is paused until you sign back into the original account.")
        }
    }
    private func retryCheck() throws {
        if let until = try library.notebook.metadata("share-retry-until").flatMap(Double.init), until > Date().timeIntervalSince1970 {
            throw NotebookError.message("iCloud asked Notebook to wait before syncing shared items.")
        }
    }
    private func noteRetry(_ error: Error) {
        if let seconds = (error as? CKError)?.retryAfterSeconds { try? library.notebook.setMetadata("share-retry-until", String(Date().timeIntervalSince1970 + seconds)) }
    }

    /// Creates the zone, its key record, its details and a zone-wide CKShare
    /// that nobody is on yet. People are added with `addPerson`.
    public func publish(_ id: String) async throws {
        try await ready()
        guard let info = library.share(id), info.owner, let key = try library.key(id) else { throw NotebookError.message("This share isn't on this device.") }
        let database = container.privateCloudDatabase
        _ = try await database.modifyRecordZones(saving:[CKRecordZone(zoneID:zoneID(info))], deleting:[])
        do { try await publishRecords(info, key:key, database:database) }
        catch {
            // Don't leave an empty share zone behind.
            _ = try? await database.modifyRecordZones(saving:[], deleting:[zoneID(info)])
            throw error
        }
        try library.update(id) { $0.published = true }
    }
    private func publishRecords(_ info: ShareInfo, key: Data, database: CKDatabase) async throws {
        let keyRecord = CKRecord(recordType:"ShareKey", recordID:record("key", info))
        keyRecord.encryptedValues["key"] = key
        let details = CKRecord(recordType:"ShareInfo", recordID:record("info", info))
        details.encryptedValues["info"] = try ShareLibrary.encodeInfo(info)
        let share = CKShare(recordZoneID:zoneID(info))
        share[CKShare.SystemFieldKey.title] = info.title
        share.publicPermission = .none
        let results = try await database.modifyRecords(saving:[keyRecord, details, share], deleting:[], savePolicy:.allKeys)
        for (_, result) in results.saveResults { if case .failure(let error) = result { throw error } }
    }
    /// Republishes the title or account level after the owner changes it.
    public func updateDetails(_ id: String) async throws {
        guard let info = library.share(id), info.owner, info.published else { return }
        try await ready()
        let database = container.privateCloudDatabase
        let details = (try? await database.record(for:record("info", info))) ?? CKRecord(recordType:"ShareInfo", recordID:record("info", info))
        details.encryptedValues["info"] = try ShareLibrary.encodeInfo(info)
        var saving: [CKRecord] = [details]
        if let share = try? await database.record(for:CKRecord.ID(recordName:CKRecordNameZoneWideShare, zoneID:zoneID(info))) as? CKShare {
            share[CKShare.SystemFieldKey.title] = info.title; saving.append(share)
        }
        _ = try await database.modifyRecords(saving:saving, deleting:[], savePolicy:.changedKeys)
    }
    private func zoneShare(_ info: ShareInfo) async throws -> CKShare {
        guard let share = try await database(info).record(for:CKRecord.ID(recordName:CKRecordNameZoneWideShare, zoneID:zoneID(info))) as? CKShare else {
            throw NotebookError.message("This share couldn't be found in iCloud.")
        }
        return share
    }
    /// Adds someone by the email address of their Apple Account and returns the
    /// link to send them. View-only shares stay view-only for everyone.
    public func addPerson(_ id: String, email: String, canEdit: Bool) async throws -> URL? {
        try await ready()
        guard let info = library.share(id), info.owner else { throw NotebookError.message("Only the owner can add people.") }
        if !info.published { try await publish(id) }
        let address = email.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard address.contains("@"), address.count <= 200 else { throw NotebookError.message("Enter the email address of their Apple Account.") }
        let share = try await zoneShare(info)
        let participant: CKShare.Participant
        do { participant = try await container.shareParticipant(forEmailAddress:address) }
        catch { throw NotebookError.message("No Apple Account was found for \(address).") }
        participant.permission = canEdit && info.kind != "account" ? .readWrite : .readOnly
        if !share.participants.contains(where: { $0.userIdentity.lookupInfo?.emailAddress?.lowercased() == address }) { share.addParticipant(participant) }
        else if let existing = share.participants.first(where: { $0.userIdentity.lookupInfo?.emailAddress?.lowercased() == address }) { existing.permission = participant.permission }
        let saved = try await container.privateCloudDatabase.modifyRecords(saving:[share], deleting:[], savePolicy:.changedKeys)
        var url = share.url
        for (_, result) in saved.saveResults {
            switch result { case .success(let record): url = (record as? CKShare)?.url ?? url; try updatePeople(record as? CKShare, id); case .failure(let error): throw error }
        }
        return url
    }
    public func removePerson(_ id: String, email: String) async throws {
        try await ready()
        guard let info = library.share(id), info.owner else { return }
        let share = try await zoneShare(info)
        for participant in share.participants where participant.role != .owner && participant.userIdentity.lookupInfo?.emailAddress?.lowercased() == email.lowercased() { share.removeParticipant(participant) }
        let saved = try await container.privateCloudDatabase.modifyRecords(saving:[share], deleting:[], savePolicy:.changedKeys)
        for (_, result) in saved.saveResults { if case .success(let record) = result { try updatePeople(record as? CKShare, id) } }
    }
    public func inviteURL(_ id: String) async throws -> URL? {
        guard let info = library.share(id), info.owner, info.published else { return nil }
        return try await zoneShare(info).url
    }
    private func updatePeople(_ share: CKShare?, _ id: String) throws {
        guard let share else { return }
        let people = share.participants.filter { $0.role != .owner }.map { participant in
            let name = participant.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from:$0, style:.default) } ?? ""
            let email = participant.userIdentity.lookupInfo?.emailAddress ?? participant.userIdentity.lookupInfo?.phoneNumber ?? ""
            let status = switch participant.acceptanceStatus { case .pending: "pending"; case .accepted: "accepted"; case .removed: "removed"; default: "unknown" }
            return SharePerson(name:name, email:email, canEdit:participant.permission == .readWrite, status:status)
        }
        try library.update(id) { info in
            if info.owner { info.people = people }
            else {
                info.canEdit = share.currentUserParticipant?.permission == .readWrite && info.kind != "account"
                if let owner = share.owner.userIdentity.nameComponents { info.ownerName = PersonNameComponentsFormatter.localizedString(from:owner, style:.default) }
                info.ownerEmail = share.owner.userIdentity.lookupInfo?.emailAddress ?? info.ownerEmail
            }
        }
    }
    /// Ends a share for everyone by deleting its zone. The caller has already
    /// copied anything worth keeping back into the private notebook.
    public func stop(_ id: String) async throws {
        guard let info = library.share(id), info.owner else { return }
        if info.published {
            try await ready()
            do { _ = try await container.privateCloudDatabase.modifyRecordZones(saving:[], deleting:[zoneID(info)]) }
            catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem { }
        }
        try library.remove(id)
    }
    /// Takes this person off someone else's share. The owner and others keep it.
    public func leave(_ id: String) async throws {
        guard let info = library.share(id), !info.owner else { return }
        try await ready()
        do { _ = try await container.sharedCloudDatabase.modifyRecordZones(saving:[], deleting:[zoneID(info)]) }
        catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem { }
        try library.remove(id)
    }
    /// Accepts an invitation link pasted or opened in Notebook.
    public func accept(url: URL, allowed: @Sendable (String) -> Bool = { _ in true }) async throws -> ShareInfo {
        try await ready()
        return try await accept(container.shareMetadata(for:url), allowed:allowed)
    }
    /// Accepts an invitation the system handed Notebook (the person tapped the link).
    public func accept(_ metadata: CKShare.Metadata, allowed: @Sendable (String) -> Bool = { _ in true }) async throws -> ShareInfo {
        try await ready()
        let zone = metadata.share.recordID.zoneID
        guard metadata.containerIdentifier == containerID, let id = Self.shareID(zone) else { throw NotebookError.message("This invitation isn't for Notebook.") }
        let ownerEmail = metadata.share.owner.userIdentity.lookupInfo?.emailAddress ?? ""
        guard allowed(ownerEmail.lowercased()) else { throw NotebookError.message("A parent's setting doesn't allow sharing with this person.") }
        if metadata.participantRole == .owner { throw NotebookError.message("This is your own shared item.") }
        if metadata.participantStatus != .accepted { _ = try await container.accept(metadata) }
        let ownerName = metadata.share.owner.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from:$0, style:.default) } ?? ""
        var info = library.share(id) ?? ShareInfo(id:id, kind:"note", entity:"", title:metadata.share[CKShare.SystemFieldKey.title] as? String ?? "Shared item", owner:false)
        info.zoneOwner = zone.ownerName; info.ownerName = ownerName.isEmpty ? info.ownerName : ownerName; info.ownerEmail = ownerEmail
        info.canEdit = metadata.participantPermission == .readWrite
        try library.upsert(info)
        try await fetchZone(info)
        return library.share(id) ?? info
    }

    /// Fetches and sends every share. Errors are returned as a message, never
    /// thrown into the notebook's own sync.
    public func sync() async -> String? {
        guard !running, CloudSync.provisioned(container:containerID) else { return nil }
        running = true; defer { running = false }
        do {
            try retryCheck()
            try await ready()
            var changed = Set<String>()
            for scope in [CKDatabase.Scope.private, .shared] { changed.formUnion(try await fetchDatabase(scope)) }
            for listed in library.shares() where listed.owner ? listed.published : true {
                // Only zones iCloud says changed, and any never fetched here.
                if changed.contains(listed.id) || token("share-token:" + listed.id, CKServerChangeToken.self) == nil || !listed.ready { try await fetchZone(listed) }
                // Fetching can find the share was stopped and remove it.
                guard let info = library.share(listed.id) else { continue }
                if info.canEdit || info.owner { try await send(info) }
            }
            try library.notebook.setMetadata("share-error", nil)
            return nil
        } catch {
            noteRetry(error)
            try? library.notebook.setMetadata("share-error", error.localizedDescription)
            return error.localizedDescription
        }
    }
    private func token<T: NSObject & NSSecureCoding>(_ key: String, _ type: T.Type) -> T? {
        guard let text = try? library.notebook.metadata(key), let data = Data(base64Encoded:text) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass:type, from:data)
    }
    private func setToken(_ key: String, _ value: CKServerChangeToken) throws {
        try library.notebook.setMetadata(key, try NSKeyedArchiver.archivedData(withRootObject:value, requiringSecureCoding:true).base64EncodedString())
    }
    /// Which share zones appeared or went away. Only `Share-` zones are looked at.
    @discardableResult private func fetchDatabase(_ scope: CKDatabase.Scope) async throws -> Set<String> {
        let database = scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
        let tokenKey = "share-db-token:" + (scope == .private ? "private" : "shared")
        var token = self.token(tokenKey, CKServerChangeToken.self)
        var changed = Set<String>()
        while true {
            let changes = try await database.databaseChanges(since:token)
            for change in changes.modifications {
                guard let id = Self.shareID(change.zoneID) else { continue }
                changed.insert(id)
                guard library.share(id) == nil else { continue }
                // A share made on another of our devices, or accepted on one.
                try library.upsert(ShareInfo(id:id, kind:"note", entity:"", title:"Shared item", owner:scope == .private, zoneOwner:change.zoneID.ownerName, published:true))
            }
            for deletion in changes.deletions {
                guard let id = Self.shareID(deletion.zoneID), let info = library.share(id) else { continue }
                try removed(info)
            }
            try setToken(tokenKey, changes.changeToken)
            token = changes.changeToken
            if !changes.moreComing { break }
        }
        return changed
    }
    /// The zone is gone: the owner stopped sharing, or we left on another device.
    private func removed(_ info: ShareInfo) throws {
        if info.owner {
            // Stopped on another of our devices, which copied the item back into
            // the notebook. Keep edits this device hadn't sent yet.
            if let store = try? library.store(info.id), (try? store.pendingCount()) ?? 0 > 0 { _ = try library.restore(info.id) }
        } else if info.ready {
            library.addNotice("“\(info.title)” is no longer shared with you.")
        }
        try library.remove(info.id)
    }
    private func fetchZone(_ start: ShareInfo) async throws {
        var info = start
        let database = database(info), zone = zoneID(info)
        let tokenKey = "share-token:" + info.id
        var token = self.token(tokenKey, CKServerChangeToken.self)
        while true {
            let changes: (modificationResultsByID: [CKRecord.ID:Result<CKDatabase.RecordZoneChange.Modification, any Error>], deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do { changes = try await database.recordZoneChanges(inZoneWith:zone, since:token) }
            catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone { try removed(info); return }
            let records = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
            // Details first, so the revisions in the same batch can be checked and read.
            for record in records {
                switch record.recordType {
                case "ShareKey": if let key = record.encryptedValues["key"] as? Data { try library.setKey(info.id, key) }
                case "ShareInfo": if let data = record.encryptedValues["info"] as? Data { try ShareLibrary.applyInfo(data, to:&info); try library.upsert(info) }
                case CKRecord.SystemType.share: try updatePeople(record as? CKShare, info.id); info = library.share(info.id) ?? info
                default: break
                }
            }
            if try library.key(info.id) == nil, let record = try? await database.record(for:self.record("key", info)), let key = record.encryptedValues["key"] as? Data { try library.setKey(info.id, key) }
            if info.entity.isEmpty, let record = try? await database.record(for:self.record("info", info)), let data = record.encryptedValues["info"] as? Data { try ShareLibrary.applyInfo(data, to:&info); try library.upsert(info) }
            var revisions: [Revision] = []
            for record in records where record.recordType == "NotebookChange" {
                guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else { continue }
                revisions.append(try library.open(Data(contentsOf:url), share:info, recordName:record.recordID.recordName))
            }
            try library.store(info.id).receive(revisions)
            if !info.ready, try library.key(info.id) != nil, !info.entity.isEmpty {
                info.ready = true; try library.upsert(info)
                if !info.owner { library.addNotice("\(info.ownerName.isEmpty ? "Someone" : info.ownerName) shared “\(info.title)” with you.") }
            }
            try setToken(tokenKey, changes.changeToken)
            token = changes.changeToken
            if !changes.moreComing { break }
        }
    }
    private func send(_ info: ShareInfo) async throws {
        guard info.ready, ShareInfo.kinds[info.kind] != nil else { return }
        let store = try library.store(info.id)
        let pending = try store.revisions(pending:true).filter { (try? ShareLibrary.check($0, info)) != nil }
        guard !pending.isEmpty else { return }
        let database = database(info)
        for start in stride(from:0, to:pending.count, by:100) {
            let chunk = Array(pending[start..<min(start + 100, pending.count)])
            var files: [URL] = []
            defer { for file in files { try? FileManager.default.removeItem(at:file) } }
            var records: [CKRecord] = []
            for revision in chunk {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-share-" + revision.id + ".bin")
                try library.seal(revision, share:info.id).write(to:url, options:.atomic); files.append(url)
                let record = CKRecord(recordType:"NotebookChange", recordID:record(revision.id, info))
                record["payload"] = CKAsset(fileURL:url)
                records.append(record)
            }
            let results = try await database.modifyRecords(saving:records, deleting:[], savePolicy:.ifServerRecordUnchanged, atomically:false)
            var uploaded: [String] = []
            for (id, result) in results.saveResults {
                switch result {
                case .success: uploaded.append(id.recordName)
                case .failure(let error as CKError) where error.code == .serverRecordChanged:
                    // Saved before, but the acknowledgement was lost. Accept it
                    // only if what's in iCloud is exactly this revision.
                    guard let server = error.serverRecord, let asset = server["payload"] as? CKAsset, let url = asset.fileURL else { throw error }
                    try store.receive([try library.open(Data(contentsOf:url), share:info, recordName:id.recordName)])
                    uploaded.append(id.recordName)
                case .failure(let error): throw error
                }
            }
            try store.markUploaded(uploaded)
        }
    }
}
