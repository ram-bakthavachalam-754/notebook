import Foundation
import JavaScriptCore
import NotebookCore

/// A child's profile as the parent edits it. It lives in the parent's own
/// notebook (the `family` kind), so it syncs between the parent's devices
/// with the notebook's encryption. The child never sees it.
struct ChildProfile: Identifiable {
    var raw: [String:Any]
    var id: String { raw["id"] as? String ?? "" }
    var name: String { raw["name"] as? String ?? "" }
    var age: Int { raw["age"] as? Int ?? 9 }
    var version: Int { raw["publishedVersion"] as? Int ?? 0 }
    func value<T>(_ key: String, _ fallback: T) -> T { raw[key] as? T ?? fallback }
    func section(_ key: String) -> [String:Any] { raw[key] as? [String:Any] ?? [:] }
}

@MainActor final class FamilyModel: ObservableObject {
    @Published var children: [ChildProfile] = []
    @Published var error: String?
    private weak var notebook: NotebookModel?
    private let store: RecordStore
    private let context = JSContext()!
    /// The fields that make up the published rules; the rest is bookkeeping.
    static let policyFields = ["name","age","parentName","topics","style","rules","refusal","connection","tools","limits","apps","attach","sharing"]
    init(notebook: NotebookModel) {
        self.notebook = notebook; store = notebook.store
        if let url = Bundle.main.url(forResource:"agent-policy", withExtension:"js"), let source = try? String(contentsOf:url, encoding:.utf8) { context.evaluateScript(source) }
        reload()
    }
    var topics: [(id: String, label: String)] {
        (context.evaluateScript("AgentPolicy.TOPICS")?.toArray() as? [[String]] ?? []).map { ($0[0], $0[1]) }
    }
    func preset(_ age: Int) -> [String:String] {
        context.setObject(age, forKeyedSubscript:"input" as NSString)
        return context.evaluateScript("AgentPolicy.PRESETS[AgentPolicy.presetFor(input)]")?.toDictionary() as? [String:String] ?? [:]
    }
    func reload() {
        guard notebook?.unlocked == true else { children = []; return }
        do {
            var newest: [String:[String:Any]] = [:]
            for row in try store.records("family") {
                let entity = row["_syncEntity"] as? String ?? row["id"] as? String ?? ""
                if let kept = newest[entity], (kept["modifiedAt"] as? String ?? "") >= (row["modifiedAt"] as? String ?? "") { continue }
                newest[entity] = row
            }
            children = newest.values.map(ChildProfile.init).filter { $0.raw["type"] as? String == "child" }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch { self.error = error.localizedDescription }
    }
    private func write(_ raw: [String:Any]) throws {
        guard notebook?.unlocked == true else { throw NotebookError.message("Unlock Notebook to continue.") }
        var record = raw; record["modifiedAt"] = ISO8601DateFormatter().string(from:Date())
        try store.save(kind:"family", record:record, resolve:true)
        reload(); Task { await notebook?.sync() }
    }
    /// A new child starts from the age's preset: the apps, topics and limits the design lists.
    @discardableResult func add(name: String, age: Int) -> ChildProfile? {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { error = "Enter the child's name."; return nil }
        let raw: [String:Any] = [
            "id":UUID().uuidString.lowercased(), "type":"child", "name":trimmed, "age":age, "parentName":"",
            "topics":preset(age), "style":"wonder", "rules":[String](),
            "refusal":"That's a good one to ask a grown-up about. Want to wonder about something else?",
            "connection":["provider":"anthropic", "model":"claude-haiku-5-5", "baseURL":"", "apiKey":""],
            "tools":["web":false, "editNotes":true], "limits":["messagesPerDay":40, "quietHours":["21:00","07:00"]],
            "apps":["notes":["on":true, "templates":true], "journal":["on":true, "reminder":"19:30"], "agent":["on":true], "money":["on":true, "allowance":5], "links":["on":false], "documents":["on":false]],
            "attach":["camera":true, "library":true, "files":false],
            "sharing":["mode":"family", "family":[String]()],
            "publishedVersion":0, "createdAt":ISO8601DateFormatter().string(from:Date())
        ]
        do { try write(raw); return ChildProfile(raw:raw) } catch { self.error = error.localizedDescription; return nil }
    }
    func save(_ profile: ChildProfile) {
        guard var current = try? store.records("family", entity:profile.id).first else { return }
        for key in Self.policyFields { current[key] = profile.raw[key] }
        do { try write(current) } catch { self.error = error.localizedDescription }
    }
    func delete(_ profile: ChildProfile) {
        do {
            if var row = try store.records("family", entity:profile.id).first { row["_syncHeads"] = row["_syncAllHeads"]; try store.delete(kind:"family", record:row) }
            reload(); Task { await notebook?.sync() }
        } catch { self.error = error.localizedDescription }
    }
    /// Settings changed since the last published rules.
    func unpublished(_ profile: ChildProfile) -> Int {
        let published = profile.section("published")
        return Self.policyFields.filter { key in
            let a = profile.raw[key].flatMap { try? jsonString($0) }, b = published[key].flatMap { try? jsonString($0) }
            return a != b
        }.count
    }
    /// The parent's signing key. It's one record with a fixed ID, so the
    /// parent's devices converge on one key; children trust only its public half.
    private static let parentKeyID = "parent-signing-key"
    private func signingKey() throws -> Data {
        if let row = try store.records("family", entity:Self.parentKeyID).max(by: { ($0["modifiedAt"] as? String ?? "") < ($1["modifiedAt"] as? String ?? "") }),
           let text = row["signingKey"] as? String, let key = Data(base64Encoded:text), key.count == 32 { return key }
        let key = FamilyPolicy.newSigningKey()
        try write(["id":Self.parentKeyID, "type":"parentKey", "signingKey":key.base64EncodedString(), "createdAt":ISO8601DateFormatter().string(from:Date())])
        return key
    }
    /// The child's policy ID and family key, made the first time they're needed.
    private func childKeys(_ current: inout [String:Any]) -> (policyID: String, familyKey: Data) {
        if let id = current["policyID"] as? String, let text = current["familyKey"] as? String, let key = Data(base64Encoded:text), key.count == 32 { return (id, key) }
        let keys = (FamilyPolicy.newPolicyID(), SyncCrypto.randomKey())
        current["policyID"] = keys.0; current["familyKey"] = keys.1.base64EncodedString()
        return keys
    }
    /// The code a child's device scans or pastes to join, and the 6-digit number
    /// both screens show. It expires in 10 minutes.
    func enrollment(_ profile: ChildProfile) throws -> (code: String, confirmation: String) {
        guard var current = try store.records("family", entity:profile.id).first else { throw NotebookError.message("This child was removed.") }
        let isNew = current["policyID"] == nil
        let keys = childKeys(&current)
        let parentKey = try FamilyPolicy.publicKey(try signingKey())
        if isNew { try write(current) }
        let joining = FamilyEnrollment(policyID:keys.policyID, child:profile.id, name:profile.name, familyKey:keys.familyKey, parentKey:parentKey, expires:Date().addingTimeInterval(600))
        return (try FamilyPolicy.code(joining), FamilyPolicy.confirmation(joining))
    }
    /// Seals and signs the rules, and sends them to iCloud for the child's
    /// devices to fetch. The returned file can also be carried over by hand.
    private func signed(_ policy: [String:Any], _ current: inout [String:Any]) throws -> Data {
        let keys = childKeys(&current)
        let sealed = try FamilyPolicy.seal(try JSONSerialization.data(withJSONObject:policy, options:[.sortedKeys]), policyID:keys.policyID, version:policy["version"] as? Int ?? 0, familyKey:keys.familyKey, signingKey:try signingKey())
        deliver(sealed, child:current["id"] as? String ?? "")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sealed)
    }
    /// Per child: how the last publish reached iCloud, for the parent's list.
    @Published var delivery: [String:String] = [:]
    private func deliver(_ sealed: SignedFamilyPolicy, child: String) {
        guard let notebook else { return }
        Task {
            let container = await notebook.cloud.containerID
            guard CloudSync.provisioned(container:container) else { return }
            delivery[child] = "Sending v\(sealed.version) through iCloud…"
            do { try await FamilyCloud.publish(sealed, container:container); delivery[child] = "v\(sealed.version) sent through iCloud" }
            catch { delivery[child] = "Couldn't send through iCloud: \(error.localizedDescription) Install the file by hand instead." }
        }
    }
    /// The signed rules file for the child's device, at the next version.
    /// Validated with the same code the child's device runs, then recorded as published.
    func publish(_ profile: ChildProfile) throws -> Data {
        guard var current = try store.records("family", entity:profile.id).first else { throw NotebookError.message("This child was removed.") }
        let version = (current["publishedVersion"] as? Int ?? 0) + 1
        var policy: [String:Any] = ["schema":1, "version":version, "managed":true, "child":profile.id, "issuedAt":ISO8601DateFormatter().string(from:Date())]
        for key in Self.policyFields { policy[key] = current[key] }
        if (policy["parentName"] as? String ?? "").isEmpty { policy["parentName"] = "a parent" }
        try validate(policy)
        let file = try signed(policy, &current)
        current["publishedVersion"] = version
        current["published"] = Dictionary(uniqueKeysWithValues:Self.policyFields.compactMap { key in current[key].map { (key, $0) } })
        current["publishedAt"] = policy["issuedAt"]
        try write(current)
        return file
    }
    /// Releases the child's devices from kid mode.
    func release(_ profile: ChildProfile) throws -> Data {
        guard var current = try store.records("family", entity:profile.id).first else { throw NotebookError.message("This child was removed.") }
        let version = (current["publishedVersion"] as? Int ?? 0) + 1
        let file = try signed(["schema":1, "version":version, "managed":false, "child":profile.id], &current)
        current["publishedVersion"] = version; current.removeValue(forKey:"published")
        try write(current)
        return file
    }
    private func validate(_ policy: [String:Any]) throws {
        var problem: String?
        context.exceptionHandler = { _, value in problem = value?.toString() }
        context.setObject(policy, forKeyedSubscript:"input" as NSString)
        context.evaluateScript("AgentPolicy.normalize(input)")
        context.exceptionHandler = nil
        if let problem { throw NotebookError.message(problem.replacingOccurrences(of:"Error: ", with:"")) }
        let connection = policy["connection"] as? [String:Any] ?? [:]
        if connection["provider"] as? String != "compatible", (connection["apiKey"] as? String ?? "").isEmpty { throw NotebookError.message("Add an AI key for this child in Connection.") }
    }
}
