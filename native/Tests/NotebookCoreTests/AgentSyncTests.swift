import XCTest
@testable import NotebookCore

final class AgentSyncTests: XCTestCase {
    func testIndependentDeviceChatsMergeAndPersistWithoutReplacingOtherMessages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let mac = try RecordStore(url:root.appendingPathComponent("mac.sqlite")), phone = try RecordStore(url:root.appendingPathComponent("phone.sqlite"))
        _ = try mac.setKey("app_agentThreads",value:["threads":[["id":"chat","title":"Shared conversation"]]])
        try phone.receive(mac.revisions())
        let stale = try mac.getKey("app_agentMessages")!
        _ = try mac.setKey("app_agentMessages",value:["messages":[["id":"mac-user","threadID":"chat","runID":"mac-run","sequence":0,"role":"user","content":"Made on Mac"]]])
        _ = try phone.setKey("app_agentMessages",value:["messages":[["id":"phone-user","threadID":"chat","runID":"phone-run","sequence":0,"role":"user","content":"Made independently on phone"]]])
        _ = try phone.setKey("app_agentMessages",value:["messages":[["id":"phone-tool","threadID":"chat","runID":"phone-run","sequence":1,"role":"tool","content":"Action completed"]]])
        XCTAssertTrue(try mac.revisions(pending:true).contains { $0.kind == "agentMessages" })
        try phone.receive(mac.revisions()); try mac.receive(phone.revisions())
        _ = try mac.setKey("app_agentMessages",value:stale)
        let reopened = try RecordStore(url:phone.url)
        let messages = try reopened.getKey("app_agentMessages") as! [String:Any]
        XCTAssertEqual((messages["messages"] as! [[String:Any]]).count,3)
        XCTAssertEqual(try jsonString(mac.getKey("app_agentMessages")!),try jsonString(reopened.getKey("app_agentMessages")!))
        XCTAssertTrue(try mac.revisions().contains { $0.kind == "agentMessages" })
    }
    func testAgentMessagesUseEncryptedSyncEnvelopes() throws {
        let revision = Revision(kind:"agentMessages",entity:"message",parents:[],payload:try jsonString(["id":"message","content":"Private conversation"]),device:"phone")
        let key = Data(repeating:42,count:32)
        let envelope = try SyncCrypto.seal(JSONEncoder().encode(revision),key:key,context:"notebook:message")
        XCTAssertEqual(try JSONDecoder().decode(Revision.self,from:SyncCrypto.open(envelope,key:key,context:"notebook:message")),revision)
    }
}
