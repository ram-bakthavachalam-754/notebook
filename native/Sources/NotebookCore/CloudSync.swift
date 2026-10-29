import Foundation
import CloudKit
import CryptoKit
#if os(macOS)
import Security
#endif

/// The same engine runs inside iOS and the bundled macOS helper. CloudKit only
/// receives authenticated ciphertext. Immutable revisions make retries idempotent.
public actor CloudSync: CKSyncEngineDelegate {
    public static let defaultContainer = "iCloud.com.ram.notebook"
    private let store: RecordStore
    public let containerID: String
    private var engine: CKSyncEngine?
    private var database: CKDatabase?
    private var notebook: String?
    private var key: Data?
    private var halted = false
    private var active = false
    private var assetURLs: [String:URL] = [:]
    private var invite: PairingInvitation?
    private var invitationPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var pendingRequest: PairingRequest?
    private var joinInvitation: PairingInvitation?
    private var joinPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    public init(store: RecordStore, container: String = defaultContainer) { self.store = store; self.containerID = container }

    public static func provisioned(container: String) -> Bool {
        #if os(macOS)
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue:kSecCSSigningInformation), &info) == errSecSuccess,
              let entitlements = (info as? [String:Any])?[kSecCodeInfoEntitlementsDict as String] as? [String:Any],
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] else { return false }
        return containers.contains(container)
        #elseif targetEnvironment(simulator)
        // This build deliberately validates live CloudKit only on provisioned
        // hardware; simulator builds remain useful for independent offline use.
        return false
        #else
        return Bundle.main.object(forInfoDictionaryKey:"NotebookCloudEnabled") as? String == "YES"
        #endif
    }
    private var retryGate: CloudRetryGate { CloudRetryGate(store:store,container:containerID) }
    private func cloudRequest<T>(_ operation: () async throws -> T) async throws -> T {
        try retryGate.check()
        do { return try await operation() }
        catch {
            if try retryGate.record(error), let message = try retryGate.message() {
                throw CloudCooldownError(message:message)
            }
            throw error
        }
    }
    private func cloud() throws -> CKDatabase {
        guard Self.provisioned(container:containerID) else { throw NotebookError.message("iCloud sync needs a signed build with the Notebook CloudKit container. Your notes are saved on this device.") }
        if let database { return database }
        let db = CKContainer(identifier:containerID).privateCloudDatabase
        database = db; return db
    }
    private func account() async throws -> String {
        _ = try cloud()
        let container = CKContainer(identifier:containerID)
        guard try await cloudRequest({ try await container.accountStatus() }) == .available else { throw NotebookError.message("Sign in to iCloud in Settings to connect Notebook.") }
        return try await cloudRequest { try await container.userRecordID().recordName }
    }
    private func checkAccount() async throws {
        let current = try await account()
        if let bound = try store.metadata("cloud-account"), bound != current {
            halted = true; engine = nil
            throw NotebookError.message("The iCloud account changed. Sync is paused to keep this notebook separate. Sign back into the original account.")
        }
    }
    public func status() throws -> [String:Any] {
        let configured = Self.provisioned(container:containerID)
        let linked = try store.metadata("notebook") != nil
        let pending = try store.pendingCount()
        return ["available":configured,"linked":linked,"pending":pending,"syncing":active,
                "retryAfterSeconds":try retryGate.remaining(),
                "message":try retryGate.message() ?? store.metadata("sync-error") ?? (!configured ? "iCloud setup required" : !linked ? "Saved on this device" : pending > 0 ? "Changes waiting to sync" : "Up to date"),
                "lastSynced":try store.metadata("last-sync") ?? ""]
    }
    public func start() async throws {
        try retryGate.check()
        guard !halted else { throw NotebookError.message(try store.metadata("sync-error") ?? "Sync is paused. Restart Notebook to retry.") }
        guard let notebook = try store.metadata("notebook") else { return }
        try await checkAccount()
        guard let key = try NotebookKeychain.read("notebook:" + notebook), key.count == 32 else { throw NotebookError.message("This device's sync key is missing. Pair again with an authorized device.") }
        self.notebook = notebook; self.key = key
        if engine == nil {
            let state = try store.metadata("cloud-state").map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self,from:Data($0.utf8)) }
            var config = CKSyncEngine.Configuration(database:try cloud(),stateSerialization:state,delegate:self)
            config.automaticallySync = true
            engine = CKSyncEngine(config)
            if state == nil { engine!.state.add(pendingDatabaseChanges:[.saveZone(CKRecordZone(zoneID:zoneID))]) }
        }
        queuePending()
    }
    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName:"Notebook-" + (notebook ?? "unpaired")) }
    private func queuePending() {
        guard !halted, let engine else { return }
        do { engine.state.add(pendingRecordZoneChanges:try store.revisions(pending:true).map { .saveRecord(CKRecord.ID(recordName:$0.id,zoneID:zoneID)) }) }
        catch { fail(error) }
    }
    public func sync() async throws {
        if active { return }
        active = true; defer { active = false }
        do {
            try await start()
            guard let engine else { return }
            // Fetch first so existing remote revisions are integrated before uploading.
            try await cloudRequest { try await engine.fetchChanges() }
            guard !halted else { throw NotebookError.message("Sync stopped to protect local data.") }
            queuePending()
            try await cloudRequest { try await engine.sendChanges() }
            try retryGate.check()
            if !halted {
                try store.setMetadata("last-sync",ISO8601DateFormatter().string(from:Date()))
                try store.setMetadata("sync-error",nil)
            }
        } catch {
            // A cooldown is shown dynamically from its durable deadline, rather
            // than persisting a stale "30 minutes" message after it expires.
            if (try? retryGate.remaining()) == 0 { try? store.setMetadata("sync-error",error.localizedDescription) }
            throw error
        }
    }
    private func fail(_ error: Error) {
        if error is CloudCooldownError || (try? retryGate.record(error)) == true { return }
        halted = true
        try? store.setMetadata("sync-error",error.localizedDescription)
        // Do not checkpoint a fetch that we could not persist/decrypt. Restart retries
        // from the previous durable token; local data is never erased on cloud errors.
    }
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard !halted else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                try store.setMetadata("cloud-state",String(decoding:try JSONEncoder().encode(update.stateSerialization),as:UTF8.self))
            case .accountChange(let change):
                if case .signIn = change.changeType {
                    // CKSyncEngine emits initial sign-in for a fresh state. It is
                    // safe only when it matches this notebook's bound account.
                    try await checkAccount()
                    queuePending()
                } else {
                    halted = true; engine = nil
                    try store.setMetadata("sync-error","iCloud account changed. Restart Notebook after signing into the original account. Local notes are safe.")
                }
            case .fetchedRecordZoneChanges(let changes):
                guard let key, let notebook else { throw NotebookError.message("Sync key unavailable.") }
                var revisions: [Revision] = []
                for modification in changes.modifications where modification.record.recordID.zoneID == zoneID {
                    let record = modification.record
                    // Newer versions may add record types; skip them rather than pausing sync.
                    guard record.recordType == "NotebookChange" else { continue }
                    guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else { throw NotebookError.message("An iCloud record is incomplete. Sync paused.") }
                    let bytes = try SyncCrypto.open(Data(contentsOf:url),key:key,context:notebook + ":" + record.recordID.recordName)
                    let revision = try JSONDecoder().decode(Revision.self,from:bytes)
                    guard revision.id == record.recordID.recordName else { throw NotebookError.message("Invalid encrypted record identity.") }
                    revisions.append(revision)
                }
                try store.receive(revisions)
                if changes.deletions.contains(where: { $0.recordID.zoneID == zoneID }) { throw NotebookError.message("Cloud history was removed. Sync is paused; local data has been kept.") }
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) { throw NotebookError.message("The iCloud notebook was removed. Local data has been kept. Restore from an authorized device before resuming sync.") }
            case .didFetchRecordZoneChanges(let fetched):
                if let error = fetched.error { try retryGate.record(error) }
            case .sentDatabaseChanges(let sent):
                for failed in sent.failedZoneSaves { try retryGate.record(failed.error) }
            case .sentRecordZoneChanges(let sent):
                try store.markUploaded(sent.savedRecords.map { $0.recordID.recordName })
                for saved in sent.savedRecords { removeAsset(saved.recordID.recordName) }
                for failed in sent.failedRecordSaves {
                    if failed.error.code == .serverRecordChanged, let server = failed.error.serverRecord {
                        // A crash can happen after CloudKit saves but before the local ACK.
                        // Only acknowledge a retry when its authenticated contents match.
                        guard let key, let notebook, let asset = server["payload"] as? CKAsset, let url = asset.fileURL else { throw failed.error }
                        let remote = try JSONDecoder().decode(Revision.self,from:SyncCrypto.open(Data(contentsOf:url),key:key,context:notebook + ":" + server.recordID.recordName))
                        try store.receive([remote])
                        syncEngine.state.remove(pendingRecordZoneChanges:[.saveRecord(server.recordID)])
                        removeAsset(server.recordID.recordName)
                    } else if failed.error.code == .zoneNotFound {
                        throw NotebookError.message("The iCloud notebook is unavailable. Local changes remain queued.")
                    } else if try !retryGate.record(failed.error) { try store.setMetadata("sync-error",failed.error.localizedDescription) }
                }
            default: break
            }
        } catch { fail(error) }
    }
    private func removeAsset(_ id: String) { if let url = assetURLs.removeValue(forKey:id) { try? FileManager.default.removeItem(at:url) } }
    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !halted, (try? retryGate.remaining()) == 0, let key, let notebook else { return nil }
        do {
            let pending = try store.revisions(pending:true)
            let byID = Dictionary(uniqueKeysWithValues:pending.map { ($0.id,$0) })
            let changes = Array(syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }.prefix(100))
            var records: [CKRecord.ID:CKRecord] = [:]
            for change in changes {
                guard case .saveRecord(let id) = change else { continue }
                guard let revision = byID[id.recordName] else { syncEngine.state.remove(pendingRecordZoneChanges:[change]); continue }
                let encrypted = try SyncCrypto.seal(JSONEncoder().encode(revision),key:key,context:notebook + ":" + id.recordName)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-sync-" + revision.id + ".bin")
                try encrypted.write(to:url,options:.atomic)
                assetURLs[revision.id] = url
                let record = CKRecord(recordType:"NotebookChange",recordID:id)
                record["payload"] = CKAsset(fileURL:url)
                records[id] = record
            }
            let batchRecords = records
            return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges:changes) { batchRecords[$0] }
        } catch { fail(error); return nil }
    }

    // Pairing stays in a separate private zone. The QR secret authenticates a request;
    // ECDH encrypts approval specifically to the phone whose code the user confirms.
    private let pairZone = CKRecordZone.ID(zoneName:"NotebookPairing")
    private func pairID(_ id: String) -> CKRecord.ID { CKRecord.ID(recordName:id,zoneID:pairZone) }
    public func beginPairing() async throws -> String {
        try await checkAccount()
        await cancelPairing()
        let accountID = try await account()
        if try store.metadata("notebook") == nil {
            let id = UUID().uuidString.lowercased()
            try NotebookKeychain.write(SyncCrypto.randomKey(),account:"notebook:" + id)
            try store.setMetadata("cloud-account",accountID)
            try store.setMetadata("notebook",id)
        }
        try await start()
        _ = try await cloudRequest { try await cloud().save(CKRecordZone(zoneID:pairZone)) }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let invitation = PairingInvitation(version:1,container:containerID,notebook:notebook!,invitation:UUID().uuidString.lowercased(),secret:SyncCrypto.randomKey(),publicKey:privateKey.publicKey.rawRepresentation,expires:Date().addingTimeInterval(600))
        self.invite = invitation; invitationPrivateKey = privateKey; pendingRequest = nil
        return try invitation.code()
    }
    public func pendingPairing() async throws -> [String:Any]? {
        guard let invite, invite.expires > Date() else { return nil }
        do {
            let record = try await cloudRequest { try await cloud().record(for:pairID(invite.invitation)) }
            guard let data = record["request"] as? Data else { return nil }
            let request = try JSONDecoder().decode(PairingRequest.self,from:SyncCrypto.open(data,key:invite.secret,context:invite.invitation))
            guard request.publicKey.count == 32, !request.name.isEmpty, request.name.count <= 100 else { throw NotebookError.message("Invalid pairing request.") }
            pendingRequest = request
            return ["name":request.name,"confirmation":SyncCrypto.confirmation(request.publicKey)]
        } catch let error as CKError where error.code == .unknownItem { return nil }
    }
    public func approvePairing(confirmation: String) async throws {
        guard let invite, invite.expires > Date(), let privateKey = invitationPrivateKey, let request = pendingRequest, let key,
              confirmation == SyncCrypto.confirmation(request.publicKey) else { throw NotebookError.message("Pairing expired or the confirmation code changed. Try again.") }
        try await checkAccount()
        let record = try await cloudRequest { try await cloud().record(for:pairID(invite.invitation)) }
        let responseKey = try SyncCrypto.pairingKey(privateKey:privateKey,publicKey:request.publicKey,secret:invite.secret)
        let approval = PairingApproval(notebook:invite.notebook,key:key,devicePublicKey:request.publicKey)
        record["approval"] = try SyncCrypto.seal(JSONEncoder().encode(approval),key:responseKey,context:invite.invitation) as CKRecordValue
        _ = try await cloudRequest { try await cloud().save(record) }
        self.invite = nil; invitationPrivateKey = nil; pendingRequest = nil
    }
    public func cancelPairing() async {
        if let invite { _ = try? await cloudRequest { try await cloud().deleteRecord(withID:pairID(invite.invitation)) } }
        invite = nil; invitationPrivateKey = nil; pendingRequest = nil
    }
    public func requestPairing(code: String, name: String) async throws -> String {
        try retryGate.check()
        let invite = try PairingInvitation.parse(code,container:containerID,currentNotebook:store.metadata("notebook"))
        try await checkAccount()
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let request = PairingRequest(name:String(name.prefix(100)),publicKey:privateKey.publicKey.rawRepresentation)
        let record = CKRecord(recordType:"NotebookPairing",recordID:pairID(invite.invitation))
        record["request"] = try SyncCrypto.seal(JSONEncoder().encode(request),key:invite.secret,context:invite.invitation) as CKRecordValue
        _ = try await cloudRequest { try await cloud().save(record) }
        joinInvitation = invite; joinPrivateKey = privateKey
        return SyncCrypto.confirmation(request.publicKey)
    }
    public func finishPairing() async throws -> Bool {
        guard let invite = joinInvitation, invite.expires > Date(), let privateKey = joinPrivateKey else { throw NotebookError.message("Pairing expired. Scan a new code from your Mac.") }
        let accountID = try await account()
        let record = try await cloudRequest { try await cloud().record(for:pairID(invite.invitation)) }
        guard let encrypted = record["approval"] as? Data else { return false }
        let responseKey = try SyncCrypto.pairingKey(privateKey:privateKey,publicKey:invite.publicKey,secret:invite.secret)
        let approval = try JSONDecoder().decode(PairingApproval.self,from:SyncCrypto.open(encrypted,key:responseKey,context:invite.invitation))
        guard approval.notebook == invite.notebook, approval.devicePublicKey == privateKey.publicKey.rawRepresentation, approval.key.count == 32 else { throw NotebookError.message("The approval belongs to a different device.") }
        if let existing = try store.metadata("notebook") {
            guard existing == approval.notebook else { throw NotebookError.message("The connected notebook changed. Scan a fresh code from your original Mac.") }
            if let existingKey = try NotebookKeychain.read("notebook:" + existing), existingKey != approval.key {
                throw NotebookError.message("This approval has a different notebook key. Your existing connection and notes have been kept.")
            }
        }
        try NotebookKeychain.write(approval.key,account:"notebook:" + approval.notebook)
        try store.setMetadata("cloud-account",accountID)
        try store.setMetadata("notebook",approval.notebook)
        joinInvitation = nil; joinPrivateKey = nil
        _ = try? await cloudRequest { try await cloud().deleteRecord(withID:pairID(invite.invitation)) }
        try await sync()
        return true
    }
}
