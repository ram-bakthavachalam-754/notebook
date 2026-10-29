import XCTest
@testable import NotebookCore

final class ShareLibraryTests: XCTestCase {
    var root: URL!
    var keys: [String:Data] = [:]
    var notebook: RecordStore!
    var library: ShareLibrary!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("share-tests-" + UUID().uuidString)
        notebook = try RecordStore(url:root.appendingPathComponent("notebook.sqlite"))
        library = ShareLibrary(notebook:notebook, keys:({ [unowned self] in keys[$0] }, { [unowned self] id, data in keys[id] = data }))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    private func note() throws -> [String:Any] {
        try notebook.save(kind:"notes", record:["id":"n1", "title":"Groceries", "content":"<p>Milk</p>"])
        return try notebook.records("notes", entity:"n1")[0]
    }

    func testCreateCopiesTheItemIntoItsOwnStore() throws {
        let info = try library.create(kind:"note", entity:"n1", title:"Groceries", ownerName:"Ram", records:[("notes", try note())])
        XCTAssertTrue(info.owner && info.ready && !info.published)
        XCTAssertEqual(library.shares().map(\.id), [info.id])
        XCTAssertEqual(try library.store(info.id).records("notes").first?["title"] as? String, "Groceries")
        XCTAssertEqual(keys[info.id]?.count, 32)
        // Sharing the same item twice returns the same share.
        XCTAssertEqual(try library.create(kind:"note", entity:"n1", title:"Groceries", ownerName:"Ram", records:[]).id, info.id)
        XCTAssertThrowsError(try library.create(kind:"note", entity:"x", title:"", ownerName:"", records:[("journal", ["id":"x"])]), "the journal can't be shared")
    }
    func testRevisionsTravelSealedAndChecked() throws {
        let info = try library.create(kind:"note", entity:"n1", title:"Groceries", ownerName:"Ram", records:[("notes", try note())])
        let revision = try library.store(info.id).revisions(pending:true)[0]
        let sealed = try library.seal(revision, share:info.id)
        XCTAssertFalse(String(decoding:sealed, as:UTF8.self).contains("Milk"))
        XCTAssertEqual(try library.open(sealed, share:info, recordName:revision.id), revision)
        XCTAssertThrowsError(try library.open(sealed, share:info, recordName:UUID().uuidString.lowercased()), "the record name is authenticated")
        var other = info; other.id = UUID().uuidString.lowercased(); keys[other.id] = keys[info.id]
        XCTAssertThrowsError(try library.open(sealed, share:other, recordName:revision.id), "a revision can't move to another share")
        // A participant can't slip another note or another kind into a note share.
        XCTAssertThrowsError(try ShareLibrary.check(Revision(kind:"notes", entity:"n2", parents:[], payload:"{}", device:"d"), info))
        XCTAssertThrowsError(try ShareLibrary.check(Revision(kind:"finance", entity:"n1", parents:[], payload:"{}", device:"d"), info))
        XCTAssertNoThrow(try ShareLibrary.check(Revision(kind:"media", entity:"m1", parents:[], payload:"{}", device:"d"), info))
    }
    func testDetailsNeverChangeWhatAShareIs() throws {
        var info = ShareInfo(id:UUID().uuidString.lowercased(), kind:"note", entity:"", title:"", owner:false)
        try ShareLibrary.applyInfo(try jsonData(["kind":"account", "entity":"a1", "title":"Brokerage", "ownerName":"Ram", "level":"holdings"]), to:&info)
        XCTAssertEqual([info.kind, info.entity, info.title, info.ownerName, info.level], ["account", "a1", "Brokerage", "Ram", "holdings"])
        info.ready = true
        XCTAssertThrowsError(try ShareLibrary.applyInfo(try jsonData(["kind":"note", "entity":"a1"]), to:&info))
        try ShareLibrary.applyInfo(try jsonData(["kind":"account", "entity":"a1", "title":"Renamed", "level":"everything"]), to:&info)
        XCTAssertEqual([info.title, info.level], ["Renamed", "balance"], "an unknown level falls back to the least")
    }
    func testStopRestoresTheNoteWithItsHistory() throws {
        let original = try note()
        let info = try library.create(kind:"note", entity:"n1", title:"Groceries", ownerName:"Ram", records:[("notes", original)])
        var shown = original; shown["_syncHeads"] = original["_syncAllHeads"]
        try notebook.delete(kind:"notes", record:shown)
        XCTAssertTrue(try notebook.records("notes").isEmpty)
        let store = try library.store(info.id)
        var edited = try store.records("notes")[0]; edited["content"] = "<p>Milk, eggs</p>"
        try store.save(kind:"notes", record:edited)
        XCTAssertEqual(try library.restore(info.id), 1)
        let back = try notebook.records("notes")
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0]["content"] as? String, "<p>Milk, eggs</p>")
        XCTAssertEqual(back[0]["_syncConflict"] as? Bool, false, "it continues after the deletion, not beside it")
        try library.remove(info.id)
        XCTAssertNil(library.share(info.id)); XCTAssertNil(keys[info.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.directory.appendingPathComponent(info.id + ".sqlite").path))
    }
    func testNoticesAreKeptUntilCleared() {
        library.addNotice("A"); library.addNotice("B")
        XCTAssertEqual(library.notices(), ["A", "B"])
        library.clearNotices(); XCTAssertEqual(library.notices(), [])
    }
}

extension ShareLibraryTests {
    func testStopKeepsBothVersionsOfAConflict() throws {
        let original = try note()
        let info = try library.create(kind:"note", entity:"n1", title:"Groceries", ownerName:"Ram", records:[("notes", original)])
        var shown = original; shown["_syncHeads"] = original["_syncAllHeads"]
        try notebook.delete(kind:"notes", record:shown)
        let store = try library.store(info.id)
        // Two people edit the same version at once.
        let base = try store.records("notes")[0]
        var a = base; a["content"] = "<p>Milk, eggs</p>"; try store.save(kind:"notes", record:a)
        var b = base; b["content"] = "<p>Milk, bread</p>"; try store.save(kind:"notes", record:b)
        XCTAssertEqual(try store.records("notes").count, 2)
        XCTAssertEqual(try library.restore(info.id), 2)
        XCTAssertEqual(Set(try notebook.records("notes").compactMap { $0["content"] as? String }), ["<p>Milk, eggs</p>", "<p>Milk, bread</p>"])
    }
}
