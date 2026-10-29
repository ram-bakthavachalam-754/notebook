import Foundation
import CryptoKit
import Security

public enum SyncCrypto {
    public static func randomKey() -> Data { SymmetricKey(size:.bits256).withUnsafeBytes { Data($0) } }
    public static func seal(_ data: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32 else { throw NotebookError.message("Invalid notebook key.") }
        return try AES.GCM.seal(data, using:SymmetricKey(data:key), authenticating:Data(context.utf8)).combined!
    }
    public static func open(_ data: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32 else { throw NotebookError.message("Invalid notebook key.") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined:data), using:SymmetricKey(data:key), authenticating:Data(context.utf8))
    }
    public static func pairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey, publicKey: Data, secret: Data) throws -> Data {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation:publicKey))
        return shared.hkdfDerivedSymmetricKey(using:SHA256.self, salt:secret, sharedInfo:Data("Notebook pairing v1".utf8), outputByteCount:32).withUnsafeBytes { Data($0) }
    }
    public static func confirmation(_ publicKey: Data) -> String {
        let hash = Array(SHA256.hash(data:publicKey))
        let value = (UInt32(hash[0]) << 24 | UInt32(hash[1]) << 16 | UInt32(hash[2]) << 8 | UInt32(hash[3])) % 1_000_000
        return String(format:"%06u",value)
    }
}
public enum NotebookKeychain {
    private static let service = "com.ram.notebook.sync.v1"
    public static func read(_ account: String) throws -> Data? {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NotebookError.message("Unlock this device to access the Notebook key (Keychain \(status)).") }
        return item as? Data
    }
    public static func write(_ data: Data, account: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        let attrs: [String:Any] = [kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary,attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attrs) { _,new in new } as CFDictionary,nil) }
        guard status == errSecSuccess else { throw NotebookError.message("Could not save the Notebook key (Keychain \(status)).") }
    }
    public static func remove(_ account: String) {
        SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account] as CFDictionary)
    }
}
public struct PairingInvitation: Codable, Sendable {
    public let version: Int
    public let container: String
    public let notebook: String
    public let invitation: String
    public let secret: Data
    public let publicKey: Data
    public let expires: Date
    public func code() throws -> String { "notebook://pair/" + (try JSONEncoder().encode(self)).base64EncodedString() }
    public static func parse(_ code: String, container: String, now: Date = Date(), currentNotebook: String? = nil) throws -> PairingInvitation {
        let prefix = "notebook://pair/"
        guard code.hasPrefix(prefix), code.count < 4096, let data = Data(base64Encoded:String(code.dropFirst(prefix.count))) else { throw NotebookError.message("This is not a Notebook pairing code.") }
        let invite = try JSONDecoder().decode(Self.self,from:data)
        guard invite.version == 1, invite.container == container, UUID(uuidString:invite.notebook) != nil, UUID(uuidString:invite.invitation) != nil, invite.secret.count == 32, invite.publicKey.count == 32 else { throw NotebookError.message("The pairing code is not compatible with this app.") }
        guard invite.expires > now, invite.expires.timeIntervalSince(now) <= 601 else { throw NotebookError.message("This pairing code expired. Create a new one on your Mac.") }
        if let currentNotebook, currentNotebook != invite.notebook {
            throw NotebookError.message("This code belongs to a different notebook. Generate a new QR code from your original Mac notebook to pair again. Your existing notes have been kept.")
        }
        return invite
    }
}
public struct PairingRequest: Codable, Sendable {
    public var name: String
    public var publicKey: Data
}
public struct PairingApproval: Codable, Sendable {
    public var notebook: String
    public var key: Data
    public var devicePublicKey: Data
}
