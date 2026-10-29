import XCTest
@testable import NotebookCore

final class JournalOrderingTests: XCTestCase {
    func testJournalUsesEntryDateThenModifiedDateOnEveryClient() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = try RecordStore(url:directory.appendingPathComponent("notebook.sqlite"))
        let entries: [[String:Any]] = [
            ["id":"00000000-0000-0000-0000-000000000001","date":"2026-01-01T12:00:00Z","modifiedAt":"2026-10-06T12:00:00Z","content":"older"],
            ["id":"00000000-0000-0000-0000-000000000002","date":"2026-10-05T12:00:00Z","modifiedAt":"2026-10-05T12:00:00Z","content":"newer"],
            ["id":"00000000-0000-0000-0000-000000000003","date":"2026-10-05T09:00:00Z","modifiedAt":"2026-10-05T13:00:00Z","content":"a"],
            ["id":"00000000-0000-0000-0000-000000000004","date":"2026-10-05T09:00:00Z","modifiedAt":"2026-10-05T11:00:00Z","content":"b"]
        ]
        for entry in entries { _ = try store.save(kind:"journal",record:entry) }
        XCTAssertEqual(try store.records("journal").compactMap { $0["id"] as? String }, [
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000003",
            "00000000-0000-0000-0000-000000000004",
            "00000000-0000-0000-0000-000000000001"
        ])
    }
}

extension JournalOrderingTests {
    func testNotesSortWithFractionalSecondsAndPlainDates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("order-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at:url) }
        let db = try RecordStore(url:url)
        try db.save(kind:"notes", record:["id":"old", "modifiedAt":"2026-01-01T09:00:00.500Z"])
        try db.save(kind:"notes", record:["id":"new", "modifiedAt":"2026-10-20T09:00:00.250Z"])
        try db.save(kind:"notes", record:["id":"mid", "modifiedAt":"2026-05-01T09:00:00Z"])
        XCTAssertEqual(try db.records("notes").compactMap { $0["id"] as? String }, ["new", "mid", "old"])
        try db.save(kind:"journal", record:["id":"a", "date":"2026-03-01", "modifiedAt":"2026-03-01T00:00:00Z"])
        try db.save(kind:"journal", record:["id":"b", "date":"2026-09-01T12:00:00.000Z", "modifiedAt":"2026-09-01T00:00:00Z"])
        XCTAssertEqual(try db.records("journal").compactMap { $0["id"] as? String }, ["b", "a"])
    }
}
