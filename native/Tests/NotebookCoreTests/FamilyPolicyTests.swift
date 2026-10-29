import XCTest
@testable import NotebookCore

final class FamilyPolicyTests: XCTestCase {
    let parent = FamilyPolicy.newSigningKey()
    let familyKey = SyncCrypto.randomKey()
    let policyID = FamilyPolicy.newPolicyID()
    func enrollment(now: Date = Date()) throws -> FamilyEnrollment {
        FamilyEnrollment(policyID:policyID, child:"sam", name:"Sam", familyKey:familyKey, parentKey:try FamilyPolicy.publicKey(parent), expires:now.addingTimeInterval(600))
    }
    func policy(_ version: Int, child: String = "sam") -> Data { try! JSONSerialization.data(withJSONObject:["schema":1, "version":version, "child":child, "managed":true]) }

    func testRoundTripAndVersionRollback() throws {
        let signed = try FamilyPolicy.seal(policy(3), policyID:policyID, version:3, familyKey:familyKey, signingKey:parent)
        let opened = try FamilyPolicy.open(signed, enrollment:try enrollment(), installedVersion:2)
        XCTAssertEqual((try JSONSerialization.jsonObject(with:opened) as? [String:Any])?["version"] as? Int, 3)
        XCTAssertThrowsError(try FamilyPolicy.open(signed, enrollment:try enrollment(), installedVersion:3), "an equal version is refused")
        let data = try JSONEncoder().encode(signed)
        XCTAssertEqual(try JSONDecoder().decode(SignedFamilyPolicy.self, from:data), signed)
    }
    func testTamperingAndOtherSignersAreRefused() throws {
        var signed = try FamilyPolicy.seal(policy(1), policyID:policyID, version:1, familyKey:familyKey, signingKey:parent)
        var bytes = [UInt8](signed.envelope); bytes[bytes.count / 2] ^= 1; signed.envelope = Data(bytes)
        XCTAssertThrowsError(try FamilyPolicy.open(signed, enrollment:try enrollment(), installedVersion:0)) { XCTAssertTrue("\($0)".contains("signed")) }
        let stranger = try FamilyPolicy.seal(policy(1), policyID:policyID, version:1, familyKey:familyKey, signingKey:FamilyPolicy.newSigningKey())
        XCTAssertThrowsError(try FamilyPolicy.open(stranger, enrollment:try enrollment(), installedVersion:0))
        // Raising the version on the outside breaks the signature.
        var bumped = try FamilyPolicy.seal(policy(1), policyID:policyID, version:1, familyKey:familyKey, signingKey:parent); bumped.version = 9
        XCTAssertThrowsError(try FamilyPolicy.open(bumped, enrollment:try enrollment(), installedVersion:0))
    }
    func testInnerPolicyMustMatchVersionChildAndKey() throws {
        let mismatched = try FamilyPolicy.seal(policy(1), policyID:policyID, version:2, familyKey:familyKey, signingKey:parent)
        XCTAssertThrowsError(try FamilyPolicy.open(mismatched, enrollment:try enrollment(), installedVersion:0))
        let sibling = try FamilyPolicy.seal(policy(1, child:"alex"), policyID:policyID, version:1, familyKey:familyKey, signingKey:parent)
        XCTAssertThrowsError(try FamilyPolicy.open(sibling, enrollment:try enrollment(), installedVersion:0))
        let otherKey = try FamilyPolicy.seal(policy(1), policyID:policyID, version:1, familyKey:SyncCrypto.randomKey(), signingKey:parent)
        XCTAssertThrowsError(try FamilyPolicy.open(otherKey, enrollment:try enrollment(), installedVersion:0))
        let otherID = try FamilyPolicy.seal(policy(1), policyID:FamilyPolicy.newPolicyID(), version:1, familyKey:familyKey, signingKey:parent)
        XCTAssertThrowsError(try FamilyPolicy.open(otherID, enrollment:try enrollment(), installedVersion:0))
    }
    func testEnrollmentCodesExpire() throws {
        let now = Date()
        let code = try FamilyPolicy.code(try enrollment(now:now))
        let parsed = try FamilyPolicy.parse(code, now:now)
        XCTAssertEqual(parsed.policyID, policyID)
        XCTAssertEqual(FamilyPolicy.confirmation(parsed).count, 6)
        XCTAssertThrowsError(try FamilyPolicy.parse(code, now:now.addingTimeInterval(601)))
        XCTAssertThrowsError(try FamilyPolicy.parse(code, now:now.addingTimeInterval(-60)), "a code from the future is refused")
        XCTAssertThrowsError(try FamilyPolicy.parse("notebook://pair/abc"))
    }
}
