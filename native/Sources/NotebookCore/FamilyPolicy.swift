import Foundation
import CryptoKit
import CloudKit

/// A parent's published rules as they travel to a child's device: encrypted
/// with the child's family key and signed with the parent's key, so only an
/// enrolled device can read them and only the parent can write them.
///
///     envelope  = AES-GCM(familyKey, policyJSON, aad: policyID ‖ version)
///     signature = Ed25519(parentKey, policyID ‖ version ‖ envelope)
public struct SignedFamilyPolicy: Codable, Sendable, Equatable {
    public var schema = 1
    public var policyID: String
    public var version: Int
    public var envelope: Data
    public var signature: Data
}

/// What a child's device learns when it joins: which rules to accept, how to
/// read them and whose signature to trust. Shown once as a QR or paste code.
public struct FamilyEnrollment: Codable, Sendable, Equatable {
    public var version = 1
    public var policyID: String
    public var child: String
    public var name: String
    public var familyKey: Data
    public var parentKey: Data
    public var expires: Date
    public init(policyID: String, child: String, name: String, familyKey: Data, parentKey: Data, expires: Date) {
        self.policyID = policyID; self.child = child; self.name = name; self.familyKey = familyKey; self.parentKey = parentKey; self.expires = expires
    }
}

public enum FamilyPolicy {
    static let codePrefix = "notebook://family/"
    private static func context(_ policyID: String, _ version: Int) -> Data { Data("Notebook family policy v1|\(policyID)|\(version)|".utf8) }

    /// A new parent signing key (raw private key bytes), kept in the parent's notebook.
    public static func newSigningKey() -> Data { Curve25519.Signing.PrivateKey().rawRepresentation }
    public static func publicKey(_ signingKey: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation:signingKey).publicKey.rawRepresentation
    }
    /// A random 128-bit policy ID, also the CloudKit record name.
    public static func newPolicyID() -> String { SymmetricKey(size:.bits128).withUnsafeBytes { Data($0) }.map { String(format:"%02x", $0) }.joined() }

    public static func seal(_ policy: Data, policyID: String, version: Int, familyKey: Data, signingKey: Data) throws -> SignedFamilyPolicy {
        guard version > 0 else { throw NotebookError.message("A family policy needs a version.") }
        let envelope = try SyncCrypto.seal(policy, key:familyKey, context:String(decoding:context(policyID, version), as:UTF8.self))
        let signature = try Curve25519.Signing.PrivateKey(rawRepresentation:signingKey).signature(for:context(policyID, version) + envelope)
        return SignedFamilyPolicy(policyID:policyID, version:version, envelope:envelope, signature:signature)
    }

    /// Checks the signature against the enrolled parent, refuses a version at or
    /// below the installed one, and returns the policy JSON. The policy inside
    /// must carry the same version and child, so an envelope can't be replayed
    /// under another version or for another child.
    public static func open(_ signed: SignedFamilyPolicy, enrollment: FamilyEnrollment, installedVersion: Int) throws -> Data {
        guard signed.schema == 1, signed.policyID == enrollment.policyID else { throw NotebookError.message("These rules are for a different child or family.") }
        guard let parent = try? Curve25519.Signing.PublicKey(rawRepresentation:enrollment.parentKey),
              parent.isValidSignature(signed.signature, for:context(signed.policyID, signed.version) + signed.envelope) else {
            throw NotebookError.message("These rules aren't signed by the parent this device joined.")
        }
        guard signed.version > installedVersion else { throw NotebookError.message("These rules are older than the ones installed.") }
        let policy: Data
        do { policy = try SyncCrypto.open(signed.envelope, key:enrollment.familyKey, context:String(decoding:context(signed.policyID, signed.version), as:UTF8.self)) }
        catch { throw NotebookError.message("These rules couldn't be read with this device's family key.") }
        guard let inner = try JSONSerialization.jsonObject(with:policy) as? [String:Any], inner["version"] as? Int == signed.version,
              (inner["child"] as? String).map({ $0 == enrollment.child }) ?? false else {
            throw NotebookError.message("These rules don't match this device.")
        }
        return policy
    }

    public static func code(_ enrollment: FamilyEnrollment) throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        return codePrefix + (try encoder.encode(enrollment)).base64EncodedString()
    }
    public static func parse(_ code: String, now: Date = Date()) throws -> FamilyEnrollment {
        let text = code.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.hasPrefix(codePrefix), text.count < 4096, let data = Data(base64Encoded:String(text.dropFirst(codePrefix.count))) else {
            throw NotebookError.message("This is not a Notebook family code.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let enrollment = try? decoder.decode(FamilyEnrollment.self, from:data), enrollment.version == 1, enrollment.familyKey.count == 32,
              enrollment.parentKey.count == 32, enrollment.policyID.count == 32, !enrollment.child.isEmpty else {
            throw NotebookError.message("This family code isn't compatible with this version of Notebook.")
        }
        guard enrollment.expires > now, enrollment.expires.timeIntervalSince(now) <= 601 else { throw NotebookError.message("This family code expired. Show a new one on the parent's device.") }
        return enrollment
    }
    /// The 6-digit number both screens show, to confirm the code came from the right parent.
    public static func confirmation(_ enrollment: FamilyEnrollment) -> String { SyncCrypto.confirmation(enrollment.parentKey + Data(enrollment.policyID.utf8)) }
}

/// Delivery through CloudKit's public database: one `FamilyPolicy` record per
/// child, named by the policy ID. Anyone can read it, but it holds only the
/// signed, encrypted envelope, and only its creator (the parent) can change it.
public enum FamilyCloud {
    static let recordType = "FamilyPolicy"
    public static func publish(_ signed: SignedFamilyPolicy, container: String) async throws {
        guard CloudSync.provisioned(container:container) else { return }
        let database = CKContainer(identifier:container).publicCloudDatabase
        let id = CKRecord.ID(recordName:signed.policyID)
        let record = (try? await database.record(for:id)) ?? CKRecord(recordType:recordType, recordID:id)
        if let current = record["version"] as? Int, current >= signed.version { return }
        record["envelope"] = signed.envelope; record["signature"] = signed.signature; record["version"] = signed.version
        _ = try await database.modifyRecords(saving:[record], deleting:[], savePolicy:.changedKeys)
    }
    /// The published rules for a policy, or nil if none are there yet.
    public static func fetch(policyID: String, container: String) async throws -> SignedFamilyPolicy? {
        guard CloudSync.provisioned(container:container) else { return nil }
        let record: CKRecord
        do { record = try await CKContainer(identifier:container).publicCloudDatabase.record(for:CKRecord.ID(recordName:policyID)) }
        catch let error as CKError where error.code == .unknownItem { return nil }
        guard let envelope = record["envelope"] as? Data, let signature = record["signature"] as? Data, let version = record["version"] as? Int else { return nil }
        return SignedFamilyPolicy(policyID:policyID, version:version, envelope:envelope, signature:signature)
    }
}
