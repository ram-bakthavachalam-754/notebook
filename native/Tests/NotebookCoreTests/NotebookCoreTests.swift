import XCTest
import CryptoKit
import CSQLite
@testable import NotebookCore

final class NotebookCoreTests: XCTestCase {
    var directories: [URL] = []
    override func tearDown() { for url in directories { try? FileManager.default.removeItem(at:url) } }
    func store() throws -> RecordStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(dir)
        return try RecordStore(url:dir.appendingPathComponent("notebook.sqlite"))
    }
    func note(_ id: String = "n", _ text: String = "original") -> [String:Any] { ["id":id,"title":"Note","content":text,"tags":["personal"]] }
    func testExistingRevisionHistoryGetsIndexedWithoutChangingRecords() throws {
        let original = try store()
        var record = try original.save(kind:"notes",record:note())
        for i in 1...20 {
            record["content"] = "Edit \(i)"
            record = try original.save(kind:"notes",record:record)
        }
        let before = try original.records("notes")
        // Simulate the schema shipped before current-revision indexing.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(original.url.path,&db),SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db,"DROP TABLE revision_parents; DELETE FROM meta WHERE key='revision-parents-v1'",nil,nil,nil),SQLITE_OK)
        let upgraded = try RecordStore(url:original.url)
        XCTAssertEqual(try jsonString(upgraded.records("notes")),try jsonString(before))
        XCTAssertEqual(try upgraded.revisions().count,21)
        XCTAssertEqual(try upgraded.pendingCount(),21)
        XCTAssertEqual(try upgraded.heads(kind:"notes",entity:"n").count,1)
        try upgraded.markUploaded(upgraded.revisions().map(\.id))
        XCTAssertEqual(try upgraded.pendingCount(),0)
    }
    func transfer(_ a: RecordStore, _ b: RecordStore) throws { try b.receive(a.revisions()); try a.receive(b.revisions()) }
    func testOfflineChangesConvergeWithoutLosingEitherEdit() throws {
        let mac = try store(), phone = try store()
        _ = try mac.save(kind:"notes",record:note()); try transfer(mac,phone)
        var left = try mac.records("notes")[0], right = try phone.records("notes")[0]
        left["content"] = "Mac offline"; right["content"] = "Phone offline"
        _ = try mac.save(kind:"notes",record:left); _ = try phone.save(kind:"notes",record:right)
        try transfer(mac,phone)
        XCTAssertEqual(Set(try mac.records("notes").compactMap { $0["content"] as? String }),["Mac offline","Phone offline"])
        XCTAssertEqual(try jsonString(mac.records("notes").sorted { ($0["id"] as! String) < ($1["id"] as! String) }),try jsonString(phone.records("notes").sorted { ($0["id"] as! String) < ($1["id"] as! String) }))
        let chosen = try mac.records("notes")[0]
        _ = try mac.save(kind:"notes",record:chosen,resolve:true); try transfer(mac,phone)
        XCTAssertEqual(try phone.records("notes").count,1)
    }
    func testDeleteAndOfflineEditPreserveRecoverableCopy() throws {
        let mac = try store(), phone = try store()
        _ = try mac.save(kind:"notes",record:note()); try transfer(mac,phone)
        try mac.delete(kind:"notes",record:mac.records("notes")[0])
        var edit = try phone.records("notes")[0]; edit["content"] = "unsynced work"
        _ = try phone.save(kind:"notes",record:edit); try transfer(mac,phone)
        XCTAssertEqual(try mac.records("notes").count,1)
        XCTAssertEqual(try mac.records("notes")[0]["_syncConflict"] as? Bool,true)
        try mac.delete(kind:"notes",record:mac.records("notes")[0]); try transfer(mac,phone)
        XCTAssertTrue(try phone.records("notes").isEmpty)
    }
    func testResolutionDoesNotDiscardAnUnseenConcurrentEdit() throws {
        let a = try store(), b = try store(), c = try store()
        _ = try a.save(kind:"notes",record:note()); try transfer(a,b); try transfer(a,c)
        var left = try a.records("notes")[0], right = try b.records("notes")[0], unseen = try c.records("notes")[0]
        left["content"] = "left"; right["content"] = "right"; unseen["content"] = "unseen"
        _ = try a.save(kind:"notes",record:left); _ = try b.save(kind:"notes",record:right)
        try transfer(a,b)
        let shown = try a.records("notes")[0]
        _ = try c.save(kind:"notes",record:unseen); try transfer(a,c)
        _ = try a.save(kind:"notes",record:shown,resolve:true)
        XCTAssertEqual(try a.records("notes").count,2)
        XCTAssertTrue(try a.records("notes").contains { $0["content"] as? String == "unseen" })
    }
    func testUnchangedStaleCollectionCannotResurrectDeletedNoteOrDeleteRemoteAddition() throws {
        let mac = try store(), phone = try store()
        _ = try mac.setKey("app_notes",value:["notes":[note()]])
        let stale = try mac.getKey("app_notes")!
        try transfer(mac,phone)
        try phone.delete(kind:"notes",record:phone.records("notes")[0])
        _ = try phone.save(kind:"notes",record:note("new","phone")); try transfer(mac,phone)
        _ = try mac.setKey("app_notes",value:stale)
        XCTAssertEqual(try mac.records("notes").compactMap { $0["id"] as? String },["new"])
    }
    func testOutOfOrderDuplicatesAndRestartKeepDurableQueue() throws {
        let a = try store(), b = try store()
        var record = try a.save(kind:"journal",record:note())
        record["content"] = "v2"; _ = try a.save(kind:"journal",record:record)
        let ops = try a.revisions()
        let child = ops.first { !$0.parents.isEmpty }!, parent = ops.first { $0.parents.isEmpty }!
        try b.receive([child]); try b.receive([parent,child])
        XCTAssertEqual(try b.records("journal").count,1)
        XCTAssertEqual(try b.records("journal")[0]["content"] as? String,"v2")
        let reopened = try RecordStore(url:a.url)
        XCTAssertEqual(try reopened.revisions(pending:true).count,2)
        try reopened.markUploaded([parent.id]); XCTAssertEqual(try reopened.revisions(pending:true).count,1)
    }
    func testRevisionsOfKindsFromNewerVersionsAreKeptWithoutBreakingSync() throws {
        let db = try store()
        let device = UUID().uuidString.lowercased()
        let future = Revision(kind:"sharedCalendars",entity:"view-1",parents:[],payload:#"{"name":"Recipes","level":"balance"}"#,device:device)
        let note = Revision(kind:"notes",entity:"n",parents:[],payload:try jsonString(note()),device:device)
        // A batch mixing known and unknown kinds is accepted in one transaction.
        XCTAssertNoThrow(try db.receive([future,note]))
        XCTAssertEqual(try db.records("notes").count,1)
        XCTAssertEqual(try db.revisions(kind:"sharedCalendars").map(\.id),[future.id])
        XCTAssertEqual(try db.records("sharedCalendars").first?["name"] as? String,"Recipes")
        XCTAssertEqual(try db.pendingCount(),0,"received revisions are never uploaded again")
        XCTAssertFalse(try db.keys().contains { $0.contains("sharedCalendars") },"unknown kinds are not projected")
        XCTAssertNoThrow(try db.receive([future]),"redelivery is idempotent")
        // Local writes still accept only this build's kinds.
        XCTAssertThrowsError(try db.save(kind:"sharedCalendars",record:["id":"x","name":"Local"]))
        // Malformed kind names and payloads are still rejected.
        for kind in ["","SharedCalendars","../x","links!","a" + String(repeating:"b",count:40)] {
            XCTAssertThrowsError(try db.receive([Revision(kind:kind,entity:"e",parents:[],payload:"{}",device:device)]),kind)
        }
        XCTAssertThrowsError(try db.receive([Revision(kind:"sharedCalendars",entity:"e",parents:[],payload:"[1]",device:device)]))
    }
    func testLinksAreAKnownKindWithACollectionKey() throws {
        let db = try store()
        let saved = try db.setKey("app_links",value:["links":[["id":"c","type":"collection","name":"Recipes"],["id":"l","type":"link","url":"https://example.com","collectionId":"c"]]]) as! [String:Any]
        XCTAssertEqual((saved["links"] as? [[String:Any]])?.count,2)
        XCTAssertEqual(try db.records("links").count,2)
        XCTAssertEqual(try db.pendingCount(),2,"local links upload like notes")
        let link = try db.records("links",entity:"l")[0]
        _ = try db.setKey("app_links",value:["links":[[String:Any]](),"_syncDeleted":[link]])
        XCTAssertEqual(try db.records("links").map { $0["id"] as? String },["c"])
    }
    func testSavingsGoalsAreAKnownKindWithACollectionKey() throws {
        let db = try store()
        _ = try db.setKey("app_money",value:["goals":[["id":"g","type":"goal","name":"LEGO","target":60,"saved":0]]])
        XCTAssertEqual(try db.records("money").first?["name"] as? String,"LEGO")
        XCTAssertTrue(RecordStore.knownKinds.contains("money"))
    }
    func testTamperedImmutableRevisionRollsBackBatch() throws {
        let a = try store(), b = try store()
        _ = try a.save(kind:"notes",record:note())
        let op = try a.revisions()[0]; try b.receive([op])
        var altered = op; altered.payload = try jsonString(note("n","tampered"))
        let extra = Revision(kind:"notes",entity:"extra",parents:[],payload:try jsonString(note("extra")),device:"a")
        XCTAssertThrowsError(try b.receive([extra,altered]))
        XCTAssertEqual(try b.revisions().count,1)
    }
    func testMigrationPreservesRichContentMediaAndOriginalFiles() throws {
        let db = try store(), dir = db.url.deletingLastPathComponent().appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let original = try jsonData(["notes":[note("n","<p>Hello <b>world</b></p>")]])
        let file = dir.appendingPathComponent("app_notes.json"); try original.write(to:file)
        try jsonData(["id":"photo","data":"data:image/png;base64,aGVsbG8="]).write(to:dir.appendingPathComponent("app_journalMedia_photo.json"))
        try db.migrateLegacy(directory:dir); try db.migrateLegacy(directory:dir)
        XCTAssertEqual(try db.records("notes").count,1)
        XCTAssertEqual(try db.records("media").first?["id"] as? String,"photo")
        XCTAssertEqual(try Data(contentsOf:file),original)
    }
    func testCryptoRejectsWrongKeyModifiedDataAndCrossRecordReplay() throws {
        let key = SyncCrypto.randomKey(), original = Data("private journal".utf8)
        let sealed = try SyncCrypto.seal(original,key:key,context:"notebook:record")
        XCTAssertEqual(try SyncCrypto.open(sealed,key:key,context:"notebook:record"),original)
        XCTAssertThrowsError(try SyncCrypto.open(sealed,key:SyncCrypto.randomKey(),context:"notebook:record"))
        XCTAssertThrowsError(try SyncCrypto.open(sealed,key:key,context:"notebook:other-record"))
        var corrupt = sealed; corrupt[20] ^= 1
        XCTAssertThrowsError(try SyncCrypto.open(corrupt,key:key,context:"notebook:record"))
    }
    func testOnlyApprovedPhoneCanDecryptPairingResponse() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey(), phone = Curve25519.KeyAgreement.PrivateKey(), other = Curve25519.KeyAgreement.PrivateKey()
        let secret = SyncCrypto.randomKey()
        let macKey = try SyncCrypto.pairingKey(privateKey:mac,publicKey:phone.publicKey.rawRepresentation,secret:secret)
        let phoneKey = try SyncCrypto.pairingKey(privateKey:phone,publicKey:mac.publicKey.rawRepresentation,secret:secret)
        XCTAssertEqual(macKey,phoneKey)
        let data = try SyncCrypto.seal(SyncCrypto.randomKey(),key:macKey,context:"invite")
        let otherKey = try SyncCrypto.pairingKey(privateKey:other,publicKey:mac.publicKey.rawRepresentation,secret:secret)
        XCTAssertThrowsError(try SyncCrypto.open(data,key:otherKey,context:"invite"))
    }
    func testPairingRejectsExpiredAndDifferentContainerCodes() throws {
        let invite = PairingInvitation(version:1,container:"iCloud.test",notebook:UUID().uuidString,invitation:UUID().uuidString,secret:SyncCrypto.randomKey(),publicKey:Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,expires:Date().addingTimeInterval(600))
        let code = try invite.code()
        XCTAssertNoThrow(try PairingInvitation.parse(code,container:"iCloud.test"))
        XCTAssertNoThrow(try PairingInvitation.parse(code,container:"iCloud.test",currentNotebook:invite.notebook))
        XCTAssertThrowsError(try PairingInvitation.parse(code,container:"iCloud.test",currentNotebook:UUID().uuidString))
        XCTAssertThrowsError(try PairingInvitation.parse(code,container:"iCloud.other"))
        XCTAssertThrowsError(try PairingInvitation.parse(code,container:"iCloud.test",now:Date().addingTimeInterval(601)))
    }
}
