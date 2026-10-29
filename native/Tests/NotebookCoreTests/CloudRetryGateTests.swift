import XCTest
import CloudKit
@testable import NotebookCore

final class CloudRetryGateTests: XCTestCase {
    func testServerDeadlineSurvivesRestartAndDoesNotBlockLocalWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("notebook.sqlite")
        let store = try RecordStore(url:url)
        let gate = CloudRetryGate(store:store,container:"test")
        let now = Date(timeIntervalSince1970:1000)
        let error = NSError(domain:CKErrorDomain,code:CKError.serviceUnavailable.rawValue,userInfo:[CKErrorRetryAfterKey:1798.1])
        XCTAssertTrue(try gate.record(error,now:now))
        XCTAssertThrowsError(try gate.check(now:now.addingTimeInterval(1798)))
        _ = try store.save(kind:"notes",record:["id":"offline","content":"Saved during cooldown"])
        let reopened = try RecordStore(url:url)
        let restored = CloudRetryGate(store:reopened,container:"test")
        XCTAssertEqual(try restored.remaining(now:now),1798.1,accuracy:0.001)
        XCTAssertEqual(try reopened.records("notes").count,1)
        XCTAssertThrowsError(try restored.check(now:now.addingTimeInterval(60)))
        XCTAssertNoThrow(try restored.check(now:now.addingTimeInterval(1799)))
        XCTAssertNil(try restored.message(now:now.addingTimeInterval(1799)))
    }
    func testPartialFailuresUseLongestDelayAndCannotShortenCooldown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = try RecordStore(url:directory.appendingPathComponent("notebook.sqlite"))
        let gate = CloudRetryGate(store:store,container:"test")
        let now = Date(timeIntervalSince1970:1000)
        let long = NSError(domain:CKErrorDomain,code:CKError.requestRateLimited.rawValue,userInfo:[CKErrorRetryAfterKey:1800])
        let short = NSError(domain:CKErrorDomain,code:CKError.serviceUnavailable.rawValue,userInfo:[:])
        let partial = NSError(domain:CKErrorDomain,code:CKError.partialFailure.rawValue,userInfo:[CKPartialErrorsByItemIDKey:["a":long,"b":short]])
        XCTAssertTrue(try gate.record(partial,now:now))
        XCTAssertTrue(try gate.record(short,now:now.addingTimeInterval(10)))
        XCTAssertEqual(try gate.remaining(now:now),1800)
        XCTAssertFalse(try gate.record(NSError(domain:CKErrorDomain,code:CKError.permissionFailure.rawValue),now:now))
        XCTAssertEqual(try CloudRetryGate(store:store,container:"other").remaining(now:now),0)
    }
}
