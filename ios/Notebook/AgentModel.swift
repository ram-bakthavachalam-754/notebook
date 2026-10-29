import Foundation
import SwiftUI
import JavaScriptCore
import Security
import NotebookCore

struct AgentThread: Identifiable {
    var raw: [String:Any]
    var id: String { raw["id"] as? String ?? "" }
    var title: String { raw["title"] as? String ?? "Conversation" }
}
struct AgentMessage: Identifiable {
    var raw: [String:Any]
    var id: String { raw["id"] as? String ?? "" }
    var role: String { raw["role"] as? String ?? "notice" }
    var content: String { raw["content"] as? String ?? "" }
    var tool: String { raw["tool"] as? String ?? "Tool" }
    var attachments: [[String:Any]] { raw["attachments"] as? [[String:Any]] ?? [] }
    var result: [String:Any] { (try? jsonObject(content)) as? [String:Any] ?? [:] }
    var activity: String {
        if let error = result["error"] as? String { return error }
        if result["kind"] as? String == "search" { return (result["provider"] as? String ?? "Web search") + " · " + (result["query"] as? String ?? "Web search") }
        if result["kind"] as? String == "page" { return "Read page · " + (result["title"] as? String ?? "Webpage") }
        if result["kind"] as? String == "document" { return "Read document · " + (result["name"] as? String ?? "Document") }
        if let action = result["action"] as? String {
            let verb = ["create_record":"Created", "update_record":"Updated", "delete_record":"Deleted"][action] ?? action
            return "\(verb) \(result["collection"] as? String ?? "record") · \(result["label"] as? String ?? "")"
        }
        return tool.replacingOccurrences(of:"_",with:" ") + " · complete"
    }
}

struct AgentProseBlock: Identifiable {
    let raw: [String:Any]
    var id: Int { raw["id"] as? Int ?? 0 }
    var kind: String { raw["kind"] as? String ?? "paragraph" }
    var content: String { raw["content"] as? String ?? "" }
    var level: Int { raw["level"] as? Int ?? 3 }
    var marker: String { raw["marker"] as? String ?? "•" }
    var depth: Int { raw["depth"] as? Int ?? 0 }
    var language: String { raw["language"] as? String ?? "" }
    var rows: [[String]] { raw["rows"] as? [[String]] ?? [] }
}

enum AgentKeychain {
    static func query(_ config: [String:String]) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.ram.notebook.agent",
         kSecAttrAccount as String:(config["provider"] ?? "") + ":" + (config["baseURL"] ?? ""), kSecAttrSynchronizable as String:false]
    }
    static func read(_ config: [String:String]) throws -> String {
        var request = query(config); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary,&result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data:data,encoding:.utf8) else { throw NotebookError.message("Could not read the AI key from this device's keychain.") }
        return value
    }
    static func save(_ key: String, config: [String:String]) throws {
        let request = query(config)
        let update: [String:Any] = [kSecValueData as String:Data(key.utf8), kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(request as CFDictionary,update as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(request.merging(update) { _,new in new } as CFDictionary,nil) }
        guard status == errSecSuccess else { throw NotebookError.message("Could not save the AI key in this device's keychain.") }
    }
    static func remove(_ config: [String:String]) throws {
        let status = SecItemDelete(query(config) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NotebookError.message("Could not remove the AI key.") }
    }
}
private final class AgentNetworkDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class AgentModel: ObservableObject {
    @Published var threads: [AgentThread] = []
    @Published var messages: [AgentMessage] = []
    @Published var selected: String?
    @Published var busy = false
    @Published var streamingText = ""
    @Published var runningThread: String?
    @Published var status = "Saved on this device"
    @Published var error: String?
    @Published var config: [String:String] = ["provider":"openai","baseURL":"https://api.openai.com/v1","model":"gpt-5.4"]
    /// A parent's installed rules (without the AI key), or nil. Never shown to the child.
    @Published private(set) var policy: [String:Any]?
    var kidMode: Bool { policy?["managed"] as? Bool == true }
    private static let policyKey = "notebook-family-policy", policyVersionKey = "notebook-family-policy-version"
    private static let familyKey: [String:String] = ["provider":"family-policy","baseURL":""]
    private static let enrollmentKey: [String:String] = ["provider":"family-enrollment","baseURL":""]
    static let parallelKey: [String:String] = ["provider":"parallel","baseURL":"https://api.parallel.ai"]
    /// The agent's web search: "duckduckgo" (free, no key) or "parallel" (your Parallel API key).
    @Published private(set) var webSearch = UserDefaults.standard.string(forKey:"notebook-agent-web-search") ?? "duckduckgo"
    var hasSearchKey: Bool { !(((try? AgentKeychain.read(Self.parallelKey)) ?? "").isEmpty) }
    /// What web_search uses this turn. Children always get DuckDuckGo: the Parallel key is the parent's own.
    private var searchWith: String { !kidMode && webSearch == "parallel" && hasSearchKey ? "parallel" : "duckduckgo" }
    /// The family this device joined: it then accepts only rules signed by that parent.
    var enrollment: FamilyEnrollment? {
        guard let text = try? AgentKeychain.read(Self.enrollmentKey), let data = Data(base64Encoded:text) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(FamilyEnrollment.self, from:data)
    }
    private var lastFamilyFetch = Date.distantPast
    /// Installs newer rules the parent published to iCloud. Runs with sync, at
    /// most once a minute; problems are kept quiet, since the child can't fix them.
    func fetchFamilyPolicy(container: String) async {
        guard let enrollment, !busy, Date().timeIntervalSince(lastFamilyFetch) > 60 else { return }
        lastFamilyFetch = Date()
        do {
            guard let signed = try await FamilyCloud.fetch(policyID:enrollment.policyID, container:container),
                  signed.version > UserDefaults.standard.integer(forKey:Self.policyVersionKey) else { return }
            try installPolicy(try JSONEncoder().encode(signed))
        } catch { familyFetchError = error.localizedDescription }
    }
    private(set) var familyFetchError: String?
    /// Joins a parent's family with the code from their Family editor. Returns
    /// the 6-digit number to compare with the parent's screen. A device that a
    /// parent already manages can't join another family.
    @discardableResult func joinFamily(_ code: String) throws -> String {
        guard !kidMode, enrollment == nil else { throw NotebookError.message("A parent already manages this device.") }
        let joined = try FamilyPolicy.parse(code)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try AgentKeychain.save(try encoder.encode(joined).base64EncodedString(), config:Self.enrollmentKey)
        objectWillChange.send(); notebook?.objectWillChange.send()
        return FamilyPolicy.confirmation(joined)
    }
    private weak var notebook: NotebookModel?
    private let store: RecordStore
    private let context: JSContext
    private var engineError: String?
    private var runTask: Task<Void,Never>?
    private var receivedText = ""
    private var proseCache: [String:[AgentProseBlock]] = [:]
    private let web = AgentWebTransport()
    private let networkDelegate = AgentNetworkDelegate()
    private lazy var session = URLSession(configuration:.ephemeral,delegate:networkDelegate,delegateQueue:nil)
    init(notebook: NotebookModel) {
        self.notebook = notebook; store = notebook.store; context = JSContext()!
        if let data = UserDefaults.standard.data(forKey:"notebook-agent-config"), let saved = (try? JSONSerialization.jsonObject(with:data)) as? [String:String] { config = saved }
        context.exceptionHandler = { [weak self] _,value in self?.engineError = value?.toString() }
        let get: @convention(block) (String) -> String = { [weak self] key in
            do { guard let self else { return "{}" }; try self.checkAccess(); return try jsonString(["value":self.store.getKey(key) ?? NSNull()]) }
            catch { return (try? jsonString(["error":error.localizedDescription])) ?? "{}" }
        }
        let set: @convention(block) (String,String) -> String = { [weak self] key,text in
            do {
                guard let self else { return "{}" }; try self.checkAccess(); try Task.checkCancellation()
                let saved = try self.store.setKey(key,value:jsonObject(text)); self.notebook?.reload()
                return try jsonString(["value":saved])
            } catch { return (try? jsonString(["error":error.localizedDescription])) ?? "{}" }
        }
        let remove: @convention(block) (String) -> String = { [weak self] key in
            do { guard let self else { return "{}" }; try self.checkAccess(); try Task.checkCancellation(); try self.store.deleteKey(key); self.notebook?.reload(); return try jsonString(["value":true]) }
            catch { return (try? jsonString(["error":error.localizedDescription])) ?? "{}" }
        }
        context.setObject(get,forKeyedSubscript:"agentRead" as NSString); context.setObject(set,forKeyedSubscript:"agentWrite" as NSString); context.setObject(remove,forKeyedSubscript:"agentRemove" as NSString)
        // The Finance screen's price cache, so the agent values holdings with the same quotes.
        let prices: @convention(block) () -> String? = { [weak self] in
            guard let self, (try? self.checkAccess()) != nil else { return nil }
            return try? String(contentsOf:FinanceModel.priceCacheURL(self.store), encoding:.utf8)
        }
        context.setObject(prices,forKeyedSubscript:"agentPriceCache" as NSString)
        context.evaluateScript("""
        var input = null;
        var window = {};
        const AppManager = {register(){}};
        const localStorage = {getItem:k=>k==='portfolio-price-cache'?agentPriceCache():null,setItem(){}};
        const UIUtils = {todayISO:()=>new Date().toISOString().slice(0,10)};
        function agentUnwrap(text){const result=JSON.parse(text);if(result.error)throw new Error(result.error);return result.value;}
        const StorageManager = {get:key=>agentUnwrap(agentRead('app_'+key)),set:(key,value)=>agentUnwrap(agentWrite('app_'+key,JSON.stringify(value)))};
        """)
        do {
            for file in ["portfolio-app","spending-app","agent-policy","agent-core","agent-finance","agent-web","agent-stream","agent-presentation"] {
                guard let url = Bundle.main.url(forResource:file,withExtension:"js") else { throw NotebookError.message("Agent resources are missing.") }
                _ = try evaluate(String(contentsOf:url,encoding:.utf8))
            }
            try evaluate("""
            const agentIO = {get:key=>agentUnwrap(agentRead(key)),set:(key,value)=>agentUnwrap(agentWrite(key,JSON.stringify(value))),remove:key=>agentUnwrap(agentRemove(key)),financeSummary:month=>AgentFinance.summary(month),portfolioTransaction:(row,deleting)=>AgentFinance.transaction(row,deleting)};
            const agentImages = AgentCore.imageLoader(agentIO);
            """)
            loadPolicy()
            reload()
        } catch { self.error = error.localizedDescription }
    }
    private func checkAccess() throws { guard notebook?.unlocked == true else { throw NotebookError.message("Unlock Notebook to continue.") } }
    @discardableResult private func evaluate(_ script: String, input: Any? = nil) throws -> JSValue {
        engineError = nil; context.exception = nil
        if let input { context.setObject(input,forKeyedSubscript:"input" as NSString) }
        let result = context.evaluateScript(script)
        if let engineError { throw NotebookError.message(engineError) }
        guard let result else { throw NotebookError.message("The agent could not process this request.") }
        return result
    }
    private func rows(_ key: String, _ field: String) throws -> [[String:Any]] { (try store.getKey(key) as? [String:Any])?[field] as? [[String:Any]] ?? [] }
    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return formatter.string(from:Date())
    }
    func reload() {
        guard notebook?.unlocked == true else { messages = []; threads = []; return }
        do {
            let storedThreads = try rows("app_agentThreads","threads")
            threads = (try evaluate("AgentCore.threads(input)",input:storedThreads).toArray() as? [[String:Any]] ?? []).map { AgentThread(raw:$0) }
            if !threads.contains(where:{$0.id == selected}) { selected = threads.first?.id }
            let all = try rows("app_agentMessages","messages").filter { $0["threadID"] as? String == selected }
            messages = (try evaluate("AgentCore.ordered(input)",input:all).toArray() as? [[String:Any]] ?? []).map { AgentMessage(raw:$0) }
        } catch { self.error = error.localizedDescription }
    }
    func select(_ id: String) { selected = id; reload() }
    func newChat() {
        do {
            try checkAccess(); let now = timestamp(), id = UUID().uuidString.lowercased()
            _ = try store.setKey("app_agentThreads",value:["threads":[["id":id,"title":"New conversation","createdAt":now,"modifiedAt":now]]])
            selected = id; reload()
        } catch { self.error = error.localizedDescription }
    }
    /// The error message in a provider's reply, however it's shaped.
    static func serverMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
            if let error = object["error"] as? [String:Any], let message = error["message"] as? String { return String(message.prefix(300)) }
            if let message = object["error"] as? String ?? object["message"] as? String { return String(message.prefix(300)) }
        }
        return String(String(decoding:data, as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines).prefix(300))
    }
    /// Deletes a conversation and its messages, here and on your other devices.
    func deleteThread(_ id: String) {
        guard !(busy && runningThread == id) else { error = "Stop the agent before deleting this conversation."; return }
        do {
            try checkAccess()
            for row in try store.records("agentMessages") where row["threadID"] as? String == id {
                var row = row; row["_syncHeads"] = row["_syncAllHeads"]; try store.delete(kind:"agentMessages", record:row)
            }
            for row in try store.records("agentThreads", entity:id) {
                var row = row; row["_syncHeads"] = row["_syncAllHeads"]; try store.delete(kind:"agentThreads", record:row); break
            }
            if selected == id { selected = nil }
            reload()
            Task { await notebook?.sync() }
        } catch { self.error = error.localizedDescription }
    }
    var hasKey: Bool { !( (try? AgentKeychain.read(kidMode ? Self.familyKey : config)) ?? "" ).isEmpty }
    /// The last saved settings for each service (provider → config).
    static var rememberedSettings: [String:[String:String]] {
        guard let data = UserDefaults.standard.data(forKey:"notebook-agent-configs") else { return [:] }
        return ((try? JSONSerialization.jsonObject(with:data)) as? [String:[String:String]]) ?? [:]
    }
    func saveSettings(_ input: [String:String], key: String, clear: Bool) throws {
        try checkAccess(); guard !busy else { throw NotebookError.message("Stop the agent before changing providers.") }
        guard !kidMode else { throw NotebookError.message("A parent set up your AI on this device.") }
        guard let valid = try evaluate("AgentCore.settings(input)",input:input).toDictionary() as? [String:String] else { throw NotebookError.message("Invalid provider settings.") }
        guard key.count <= 4096 else { throw NotebookError.message("API key is too long.") }
        if clear { try AgentKeychain.remove(valid) }
        if !key.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { try AgentKeychain.save(key.trimmingCharacters(in:.whitespacesAndNewlines),config:valid) }
        UserDefaults.standard.set(try jsonData(valid),forKey:"notebook-agent-config"); config = valid
        // Each service keeps its own address and model, so switching back finds them.
        var remembered = Self.rememberedSettings; remembered[valid["provider"] ?? ""] = valid
        UserDefaults.standard.set(try jsonData(remembered),forKey:"notebook-agent-configs")
    }
    func saveWebSearch(_ provider: String, key: String, clear: Bool) throws {
        try checkAccess(); guard !busy else { throw NotebookError.message("Stop the agent before changing web search.") }
        guard !kidMode else { throw NotebookError.message("A parent set up your AI on this device.") }
        guard ["duckduckgo","parallel"].contains(provider) else { throw NotebookError.message("Choose a web search service.") }
        let key = key.trimmingCharacters(in:.whitespacesAndNewlines)
        guard key.count <= 4096 else { throw NotebookError.message("API key is too long.") }
        if clear { try AgentKeychain.remove(Self.parallelKey) }
        if !key.isEmpty { try AgentKeychain.save(key, config:Self.parallelKey) }
        if provider == "parallel" && !hasSearchKey { throw NotebookError.message("Paste your Parallel API key to use Parallel search.") }
        UserDefaults.standard.set(provider, forKey:"notebook-agent-web-search"); webSearch = provider
    }
    // MARK: Kid mode
    private func loadPolicy() {
        defer { JournalReminder.update(policy) }
        guard let data = UserDefaults.standard.data(forKey:Self.policyKey), let stored = try? JSONSerialization.jsonObject(with:data),
              let valid = try? evaluate("AgentPolicy.normalize(input)",input:stored).toDictionary() as? [String:Any], valid["managed"] as? Bool == true else { policy = nil; return }
        policy = valid
        config = (try? evaluate("AgentPolicy.connection(input)",input:valid).toDictionary() as? [String:String]) ?? config
    }
    /// Installs a parent's rules on this device. Versions must increase, so an
    /// older, looser policy can't be put back. `managed: false` releases the device.
    func installPolicy(_ data: Data) throws {
        guard !busy else { throw NotebookError.message("Stop the agent first.") }
        var input = try JSONSerialization.jsonObject(with:data)
        if let object = input as? [String:Any], object["envelope"] != nil {
            guard let enrollment else { throw NotebookError.message("Join your family first, in Settings → Family.") }
            let signed = try JSONDecoder().decode(SignedFamilyPolicy.self, from:data)
            input = try JSONSerialization.jsonObject(with:try FamilyPolicy.open(signed, enrollment:enrollment, installedVersion:UserDefaults.standard.integer(forKey:Self.policyVersionKey)))
        } else {
            // Unsigned rules are for testing; a family's rules are always signed.
            #if DEBUG
            guard enrollment == nil else { throw NotebookError.message("This device only accepts rules signed by your parent.") }
            #else
            throw NotebookError.message("This isn't a signed rules file from your parent.")
            #endif
        }
        guard let valid = try evaluate("AgentPolicy.normalize(input)",input:input).toDictionary() as? [String:Any], let version = valid["version"] as? Int else { throw NotebookError.message("Invalid family policy.") }
        guard version > UserDefaults.standard.integer(forKey:Self.policyVersionKey) else { throw NotebookError.message("This family policy is older than the one installed.") }
        if valid["managed"] as? Bool != true {
            try AgentKeychain.remove(Self.familyKey); try AgentKeychain.remove(Self.enrollmentKey)
            UserDefaults.standard.removeObject(forKey:Self.policyKey)
        } else {
            let connection = valid["connection"] as? [String:Any] ?? [:], key = connection["apiKey"] as? String ?? ""
            if !key.isEmpty { try AgentKeychain.save(key, config:Self.familyKey) }
            else if connection["provider"] as? String != "compatible", ((try? AgentKeychain.read(Self.familyKey)) ?? "").isEmpty { throw NotebookError.message("The family policy has no AI key.") }
            let stored = try evaluate("AgentPolicy.withoutKey(input)",input:valid).toDictionary() ?? [:]
            UserDefaults.standard.set(try jsonData(stored), forKey:Self.policyKey)
        }
        UserDefaults.standard.set(version, forKey:Self.policyVersionKey)
        if valid["managed"] as? Bool != true, let data = UserDefaults.standard.data(forKey:"notebook-agent-config"), let saved = (try? JSONSerialization.jsonObject(with:data)) as? [String:String] { config = saved }
        loadPolicy(); newChat()
        notebook?.objectWillChange.send()
    }
    /// The child's questions so far today, for the daily limit.
    private func questionsToday() -> Int {
        let iso = ISO8601DateFormatter(), fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ((try? rows("app_agentMessages","messages")) ?? []).filter { row in
            guard row["role"] as? String == "user", row["kidReply"] == nil, let text = row["createdAt"] as? String, let date = iso.date(from:text) ?? fractional.date(from:text) else { return false }
            return Calendar.current.isDateInToday(date)
        }.count
    }
    /// Questions left today and whether it's quiet time, for the Ask screen.
    var kidLimit: [String:Any] {
        guard let policy else { return [:] }
        return (try? evaluate("AgentPolicy.limit(input.policy,input.sent,new Date())",input:["policy":policy,"sent":questionsToday()]).toDictionary() as? [String:Any]) ?? [:]
    }
    func kidStarters() -> [(subject: String, question: String)] {
        ((try? evaluate("AgentPolicy.starters(new Date(),6)").toArray() as? [[String:String]]) ?? []).map { ($0["subject"] ?? "", $0["question"] ?? "") }
    }
    func kidWonder(surprise: Bool = false) -> (subject: String, question: String) {
        let value = (try? evaluate(surprise ? "AgentPolicy.surprise()" : "AgentPolicy.wonderOfTheDay(new Date())").toDictionary() as? [String:String]) ?? [:]
        return (value["subject"] ?? "", value["question"] ?? "")
    }
    func followUps(_ text: String) -> (text: String, questions: [String]) {
        let value = (try? evaluate("AgentPolicy.followUps(input)",input:text).toDictionary() as? [String:Any]) ?? [:]
        return (value["text"] as? String ?? text, value["followUps"] as? [String] ?? [])
    }
    /// One tool-free checker call. Throws on anything unexpected, so callers fail closed.
    private func check(_ kind: String, _ content: String, previous: String?, images: [String], key: String) async throws -> [String:Any] {
        guard let policy else { throw NotebookError.message("No family policy.") }
        let pictures = images.isEmpty ? [] : ((try evaluate("input.map(id => agentImages(id)).filter(Boolean)",input:images).toArray()) ?? [])
        guard let spec = try evaluate("AgentPolicy.checkRequest(input.policy,input.kind,input.content,input.previous,input.images)",input:["policy":policy,"kind":kind,"content":content,"previous":previous ?? NSNull(),"images":pictures]).toDictionary() as? [String:Any],
              let address = spec["url"] as? String, let url = URL(string:address) else { throw NotebookError.message("Invalid check request.") }
        var request = URLRequest(url:url); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if config["provider"] == "anthropic" { request.setValue(key,forHTTPHeaderField:"x-api-key"); request.setValue("2023-06-01",forHTTPHeaderField:"anthropic-version") }
        else if !key.isEmpty { request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization") }
        request.httpBody = try jsonData(spec["body"]!)
        let (data,response) = try await session.data(for:request)
        try checkAccess(); try Task.checkCancellation()
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw NotebookError.message("The check failed.") }
        let payload = try JSONSerialization.jsonObject(with:data)
        return try evaluate("AgentPolicy.parseCheck(input.policy,input.kind,input.payload)",input:["policy":policy,"kind":kind,"payload":payload]).toDictionary() as? [String:Any] ?? [:]
    }
    func cancel() { runTask?.cancel() }
    func locked() { cancel(); streamingText = ""; receivedText = ""; proseCache.removeAll(); messages = []; threads = [] }
    func prose(_ text: String) -> [AgentProseBlock] {
        if let cached = proseCache[text] { return cached }
        let blocks = ((try? evaluate("AgentPresentation.blocks(input)",input:text).toArray()) as? [[String:Any]] ?? []).map { AgentProseBlock(raw:$0) }
        if proseCache.count >= 128 { proseCache.removeAll() }
        proseCache[text] = blocks
        return blocks
    }
    private func modelResponse(_ request: URLRequest, config: [String:String]) async throws -> Any {
        let (bytes,response) = try await session.bytes(for:request)
        try checkAccess(); try Task.checkCancellation()
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw NotebookError.message(code == 401 || code == 403 ? "Provider authentication failed. Check your API key and model access." : code == 429 ? "Provider rate limit or quota reached. Try again later." : "AI server returned HTTP \(code). Check Agent settings.") }
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField:"Content-Type") ?? ""
        if !contentType.lowercased().contains("text/event-stream") {
            var data = Data()
            for try await byte in bytes { try checkAccess(); try Task.checkCancellation(); guard data.count < 10 * 1024 * 1024 else { throw NotebookError.message("The provider response was too large.") }; data.append(byte) }
            return try JSONSerialization.jsonObject(with:data)
        }
        try evaluate("var agentReplyStream = AgentStream.create(input);",input:config["provider"] ?? "openai")
        var lastUpdate = Date()
        // Feed whole lines, blank ones included: they end each stream event.
        // (`bytes.lines` drops blank lines, which ran events together.)
        var line = Data()
        for try await byte in bytes {
            line.append(byte)
            guard byte == 0x0A else { continue }
            try checkAccess(); try Task.checkCancellation()
            let content = try evaluate("agentReplyStream.feed(input)",input:String(decoding:line,as:UTF8.self)).toString() ?? ""
            line.removeAll(keepingCapacity:true)
            receivedText = content
            if !content.isEmpty && status != "Writing…" { status = "Writing…" }
            // Kid mode shows nothing until the whole answer has passed its check.
            if !kidMode && Date().timeIntervalSince(lastUpdate) >= 0.6 {
                let visible = try evaluate("AgentPresentation.reveal(input)",input:content).toString() ?? ""
                if streamingText != visible { streamingText = visible }
                lastUpdate = Date()
            }
        }
        try checkAccess(); try Task.checkCancellation()
        if !line.isEmpty { try evaluate("agentReplyStream.feed(input)",input:String(decoding:line,as:UTF8.self)) }
        receivedText = try evaluate("agentReplyStream.content").toString() ?? receivedText
        return try evaluate("agentReplyStream.finish()").toDictionary() ?? [:]
    }
    private func browse(_ name: String, arguments: Any) async throws -> [String:Any] {
        try checkAccess(); try Task.checkCancellation()
        guard let spec = try evaluate("AgentWeb.prepare(input.name,input.args,input.search)",input:["name":name,"args":arguments,"search":searchWith]).toDictionary() as? [String:Any],
              let address = spec["url"] as? String, let limit = spec["maxBytes"] as? Int else { throw NotebookError.message("Invalid web request.") }
        let search = spec["kind"] as? String == "search", parallel = spec["provider"] as? String == "parallel"
        var params: [String:Any] = ["spec":spec,"now":timestamp()]
        if parallel { params["body"] = try await parallelSearch(spec, maxBytes:limit) }
        else {
            let document = try await web.read(address,maxBytes:limit,duckDuckGo:search)
            params["body"] = document.body; params["contentType"] = document.contentType; params["url"] = document.url
        }
        try checkAccess(); try Task.checkCancellation()
        let script = parallel ? "AgentWeb.parallelSearch(input.spec,JSON.parse(input.body),input.now)" : search ? "AgentWeb.search(input.spec,JSON.parse(input.body),input.now)" : "AgentWeb.page(input.spec,input.body,input.contentType,input.url,input.now)"
        return try evaluate(script,input:params).toDictionary() as? [String:Any] ?? [:]
    }
    /// Parallel's Search API, with this device's Parallel key. Only the query leaves the device.
    private func parallelSearch(_ spec: [String:Any], maxBytes: Int) async throws -> String {
        let key = try AgentKeychain.read(Self.parallelKey)
        guard !key.isEmpty else { throw NotebookError.message("Add your Parallel API key in Settings → AI Agent → Web Search.") }
        var request = URLRequest(url:URL(string:"https://api.parallel.ai/v1/search")!); request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField:"Content-Type"); request.setValue(key, forHTTPHeaderField:"x-api-key")
        request.httpBody = try jsonData(spec["body"] ?? [:])
        let (data, response) = try await session.data(for:request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw NotebookError.message("Parallel returned an invalid response.") }
        guard status == 200 else { throw NotebookError.message(status == 401 || status == 403 ? "Parallel didn't accept the API key. Check it in Settings → AI Agent → Web Search." : "Parallel search failed (HTTP \(status)): " + Self.serverMessage(data)) }
        guard data.count <= maxBytes else { throw NotebookError.message("Parallel's answer was too large.") }
        return String(decoding:data, as:UTF8.self)
    }
    // MARK: News reader
    /// Whether News can ask your model for summaries: an adult with a provider set up.
    var canSummarize: Bool { !kidMode && (config["provider"] == "compatible" || hasKey) }
    var modelLabel: String { config["model"] ?? "your model" }
    /// Characters of source text a summary is given: local models often have
    /// small context windows; hosted ones take a whole long article.
    var summaryInput: Int { config["provider"] == "compatible" ? 12000 : 60000 }
    /// An article's readable text, read on this device with the agent's safe web reader.
    func readArticle(_ url: String) async throws -> (title: String, text: String, url: String) {
        // The reader returns at most 20,000 characters at a time; long articles
        // are read on, up to 60,000 characters.
        var page = try await browse("read_webpage", arguments:["url":url, "maxCharacters":20000])
        let title = page["title"] as? String ?? "", address = page["url"] as? String ?? url
        var text = page["content"] as? String ?? ""
        while text.count < 60000, let next = (page["nextOffset"] as? NSNumber)?.intValue, next > 0 {
            guard let more = try? await browse("read_webpage", arguments:["url":url, "offset":next, "maxCharacters":20000]), let content = more["content"] as? String, !content.isEmpty else { break }
            text += content; page = more
        }
        return (title, text, address)
    }
    /// One tool-free call to your own model, streamed as it's written. Used by
    /// News for summaries and the digest; nothing is saved to your notebook.
    func write(system: String, prompt: String, maxTokens: Int, onText: @escaping (String) -> Void = { _ in }) async throws -> String {
        try checkAccess()
        let config = config, key = try AgentKeychain.read(config)
        guard canSummarize, let base = config["baseURL"], let model = config["model"], !model.isEmpty else { throw NotebookError.message("Set up a model in Agent Settings to get summaries.") }
        let anthropic = config["provider"] == "anthropic"
        var body: [String:Any] = ["model":model, "stream":true]
        if anthropic { body["max_tokens"] = maxTokens; body["system"] = system; body["messages"] = [["role":"user", "content":prompt]] }
        else { body["messages"] = [["role":"system", "content":system], ["role":"user", "content":prompt]]; body[config["provider"] == "openai" ? "max_completion_tokens" : "max_tokens"] = maxTokens }
        guard let url = URL(string:base + (anthropic ? "/messages" : "/chat/completions")) else { throw NotebookError.message("Invalid AI server URL.") }
        func request(_ body: [String:Any]) throws -> URLRequest {
            var request = URLRequest(url:url); request.httpMethod = "POST"; request.timeoutInterval = 240
            request.setValue("application/json", forHTTPHeaderField:"Content-Type")
            if anthropic { request.setValue(key, forHTTPHeaderField:"x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField:"anthropic-version") }
            else if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField:"Authorization") }
            request.httpBody = try jsonData(body)
            return request
        }
        // A low temperature keeps summaries close to the text, and local thinking
        // models are asked not to spend the budget thinking first. Some servers and
        // models reject one of these; they're asked again with the plain request.
        var hinted = body
        if config["provider"] != "openai" { hinted["temperature"] = 0.3 }
        if config["provider"] == "compatible" { hinted["chat_template_kwargs"] = ["enable_thinking":false] }
        // OpenAI counts hidden reasoning against the limit; keep it short so the answer fits.
        if config["provider"] == "openai" { hinted["reasoning_effort"] = "low" }
        var (bytes, response) = try await session.bytes(for:request(hinted))
        if (response as? HTTPURLResponse)?.statusCode == 400, hinted.count != body.count {
            (bytes, response) = try await session.bytes(for:request(body))
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // Show what the server said: it names the real problem (a model name, a parameter).
            var reply = Data()
            for try await byte in bytes { reply.append(byte); if reply.count > 4000 { break } }
            let detail = Self.serverMessage(reply)
            if code == 401 || code == 403 { throw NotebookError.message("Your AI provider refused the key. Check Agent Settings." + (detail.isEmpty ? "" : " (\(detail))")) }
            throw NotebookError.message("The AI server returned HTTP \(code)" + (detail.isEmpty ? "." : ": \(detail)"))
        }
        // Its own parser variable, so a chat running at the same time isn't disturbed.
        try evaluate("var newsSummaryStream = AgentStream.create(input);", input:config["provider"] ?? "openai")
        var line = Data(), last = Date.distantPast
        for try await byte in bytes {
            line.append(byte)
            guard byte == 0x0A else { continue }
            try Task.checkCancellation(); try checkAccess()
            let text = try evaluate("newsSummaryStream.feed(input)", input:String(decoding:line, as:UTF8.self)).toString() ?? ""
            line.removeAll(keepingCapacity:true)
            if Date().timeIntervalSince(last) > 0.25 { onText(text); last = Date() }
        }
        if !line.isEmpty { try evaluate("newsSummaryStream.feed(input)", input:String(decoding:line, as:UTF8.self)) }
        _ = try evaluate("newsSummaryStream.finish()")
        let text = (try evaluate("newsSummaryStream.content").toString() ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        onText(text)
        return text
    }
    func send(_ text: String, allowWrites: Bool, attachments: [[String:Any]] = []) {
        guard !busy else { return }
        let text = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.count <= 32000, !text.isEmpty || !attachments.isEmpty else { error = "Enter a message of at most 32,000 characters."; return }
        guard attachments.count <= 10 else { error = "Attach up to 10 documents per message."; return }
        if selected == nil { newChat() }
        guard let threadID = selected else { return }
        let config = config, kid = kidMode ? policy : nil
        busy = true; error = nil; status = "Thinking…"; runningThread = threadID; streamingText = ""; receivedText = ""
        runTask = Task { [self] in
            let runID = UUID().uuidString.lowercased(), runAt = timestamp(); var sequence = 0
            @MainActor func append(_ message: [String:Any]) throws {
                try checkAccess()
                var row = message
                row.merge(["id":UUID().uuidString.lowercased(),"threadID":threadID,"runID":runID,"runAt":runAt,"sequence":sequence,"createdAt":timestamp(),"modifiedAt":timestamp()]) { _,new in new }
                sequence += 1
                _ = try store.setKey("app_agentMessages",value:["messages":[row]]); reload()
            }
            defer { busy = false; streamingText = ""; receivedText = ""; runningThread = nil; status = "Saved on this device"; runTask = nil; notebook?.reload(); Task { await notebook?.sync() } }
            do {
                try checkAccess(); try Task.checkCancellation()
                _ = try evaluate("AgentCore.settings(input)",input:config)
                let key = try AgentKeychain.read(kid != nil ? Self.familyKey : config)
                guard config["provider"] == "compatible" || !key.isEmpty else { throw NotebookError.message(kid != nil ? "Ask isn't ready on this device yet." : "Add your API key in Agent settings on this device.") }
                var userMessage: [String:Any] = ["role":"user","content":text,"provider":config["provider"] ?? "","model":config["model"] ?? ""]
                if !attachments.isEmpty { userMessage["attachments"] = attachments }
                // Kid mode: the daily limit and quiet hours, then the question check,
                // before the agent sees anything. A blocked question gets an ordinary reply.
                var turnPolicy: Any = NSNull()
                if var kid {
                    let limit = kidLimit
                    if limit["blocked"] as? Bool == true {
                        userMessage["kidReply"] = "limit"; try append(userMessage)
                        try append(["role":"assistant","content":limit["message"] as? String ?? "","kidReply":"limit"]); return
                    }
                    let previous = try rows("app_agentMessages","messages").filter { $0["threadID"] as? String == threadID && $0["role"] as? String == "user" }
                    let last = (try evaluate("AgentCore.ordered(input)",input:previous).toArray() as? [[String:Any]])?.last?["content"] as? String
                    try append(userMessage)
                    status = "Thinking…"
                    let named = text.isEmpty ? attachments.compactMap { $0["name"] as? String }.joined(separator:", ") : text
                    let images = attachments.filter { ($0["type"] as? String ?? "").hasPrefix("image/") }.compactMap { $0["id"] as? String }
                    let decision: [String:Any]
                    do {
                        let result = try await check("question", named, previous:last, images:images, key:key)
                        decision = try evaluate("AgentPolicy.decide(input.policy,input.check)",input:["policy":kid,"check":result]).toDictionary() as? [String:Any] ?? [:]
                    } catch {
                        try checkAccess(); try Task.checkCancellation()
                        try append(["role":"assistant","content":try evaluate("AgentPolicy.CHECK_FAILED").toString() ?? "","kidReply":"check"]); return
                    }
                    if decision["action"] as? String != "answer" { try append(["role":"assistant","content":decision["reply"] as? String ?? "","kidReply":decision["kind"] as? String ?? "block"]); return }
                    kid["careful"] = decision["careful"] as? Bool == true
                    turnPolicy = kid
                } else {
                    try append(userMessage)
                }
                let canWrite = kid != nil ? ((kid?["tools"] as? [String:Any])?["editNotes"] as? Bool ?? false) : allowWrites
                if var thread = try rows("app_agentThreads","threads").first(where:{$0["id"] as? String == threadID}), thread["title"] as? String == "New conversation" {
                    thread["title"] = String((text.isEmpty ? attachments.first?["name"] as? String ?? "Document" : text).prefix(64)); thread["modifiedAt"] = runAt
                    _ = try store.setKey("app_agentThreads",value:["threads":[thread]])
                }
                let stored = try rows("app_agentMessages","messages").filter { $0["threadID"] as? String == threadID }
                var history = try evaluate("AgentCore.history(input)",input:stored).toArray() as? [[String:Any]] ?? []
                var actions = 0
                // One timestamp per question keeps every step's prompt identical up to the new tool results.
                let now = ISO8601DateFormatter().string(from:Date())
                for _ in 0..<24 {
                    try checkAccess(); try Task.checkCancellation(); streamingText = ""; receivedText = ""; status = "Thinking…"
                    let params: [String:Any] = ["config":config,"messages":history,"now":now,"allowWrites":canWrite,"policy":turnPolicy,"search":searchWith,"trading":kid == nil]
                    guard let spec = try evaluate("AgentCore.request(input.config,input.messages,input.now,input.allowWrites,agentImages,input.policy,input.search,input.trading)",input:params).toDictionary() as? [String:Any], let address = spec["url"] as? String, let url = URL(string:address) else { throw NotebookError.message("Invalid AI server URL.") }
                    var request = URLRequest(url:url); request.httpMethod = "POST"; request.timeoutInterval = 180
                    request.setValue("application/json",forHTTPHeaderField:"Content-Type")
                    if config["provider"] == "anthropic" { request.setValue(key,forHTTPHeaderField:"x-api-key"); request.setValue("2023-06-01",forHTTPHeaderField:"anthropic-version") }
                    else if !key.isEmpty { request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization") }
                    request.httpBody = try jsonData(spec["body"]!)
                    let payload = try await modelResponse(request,config:config)
                    try checkAccess(); try Task.checkCancellation()
                    guard var answer = try evaluate("AgentCore.response(input.config,input.payload)",input:["config":config,"payload":payload]).toDictionary() as? [String:Any] else { throw NotebookError.message("Invalid AI response.") }
                    let calls = answer["tool_calls"] as? [[String:Any]] ?? []
                    guard !(answer["content"] as? String ?? "").isEmpty || !calls.isEmpty else { throw NotebookError.message("The model returned no answer. Choose a model that supports tools.") }
                    guard calls.count <= 20 else { throw NotebookError.message("The model requested too many actions at once.") }
                    if let kid {
                        // Only a final, checked answer is ever stored where the child can see it.
                        if calls.isEmpty {
                            do {
                                let result = try await check("answer", answer["content"] as? String ?? "", previous:text, images:[], key:key)
                                let verdict = try evaluate("AgentPolicy.decideAnswer(input.policy,input.check)",input:["policy":kid,"check":result]).toDictionary() as? [String:Any] ?? [:]
                                if verdict["action"] as? String == "replace" { answer = ["role":"assistant","content":verdict["reply"] as? String ?? "","kidReply":"answer"] }
                            } catch {
                                try checkAccess(); try Task.checkCancellation()
                                answer = ["role":"assistant","content":try evaluate("AgentPolicy.CHECK_FAILED").toString() ?? "","kidReply":"check"]
                            }
                        } else { answer["content"] = "" }
                    }
                    try append(answer); streamingText = ""; receivedText = ""; history.append(answer)
                    if calls.isEmpty { return }
                    for call in calls {
                        try checkAccess(); try Task.checkCancellation(); actions += 1
                        guard actions <= 100 else { throw NotebookError.message("Action limit reached. Send a follow-up to continue.") }
                        let function = call["function"] as? [String:Any] ?? [:], name = function["name"] as? String ?? ""
                        status = "Working · " + name.replacingOccurrences(of:"_",with:" ")
                        var result: [String:Any]
                        do {
                            let arguments = try jsonObject(function["arguments"] as? String ?? "{}")
                            if ["web_search","read_webpage"].contains(name) { result = try await browse(name,arguments:arguments) }
                            else if name.hasPrefix("trading_") {
                                // Never a child's: the request didn't offer these, and a call anyway is refused.
                                guard kid == nil, let notebook else { throw NotebookError.message("That tool is not available.") }
                                result = try await notebook.trading.agentTool(name, arguments:arguments, canWrite:canWrite)
                            }
                            else {
                                // Value holdings with current quotes: refresh any older than five minutes first.
                                if name == "finance_summary", let tickers = try? evaluate("PortfolioApp.loadData(); PortfolioApp.computeHoldings().filter(h=>h.totalShares>0).map(h=>h.ticker)").toArray() as? [String], !tickers.isEmpty {
                                    status = "Getting current prices…"
                                    _ = await FinanceModel.refreshQuotes(tickers, store:store)
                                    try checkAccess(); try Task.checkCancellation()
                                }
                                let input: [String:Any] = ["name":name,"args":arguments,"options":["id":UUID().uuidString.lowercased(),"now":ISO8601DateFormatter().string(from:Date()),"allowWrites":canWrite,"policy":turnPolicy]]
                                result = try evaluate("AgentCore.execute(input.name,input.args,agentIO,input.options)",input:input).toDictionary() as? [String:Any] ?? [:]
                            }
                            try checkAccess(); try Task.checkCancellation()
                        } catch { try checkAccess(); try Task.checkCancellation(); result = ["error":error.localizedDescription] }
                        let output = try jsonString(result)
                        var message: [String:Any] = ["role":"tool","tool_call_id":call["id"] as? String ?? "","tool":name,"content":output]
                        if result["success"] as? Bool == true { message["action"] = result }
                        try append(message); history.append(try evaluate("AgentCore.shape(input)",input:message).toDictionary() as? [String:Any] ?? ["role":"tool","tool_call_id":call["id"] as? String ?? "","content":output])
                    }
                }
                throw NotebookError.message("Step limit reached. Completed actions are saved; send a follow-up to continue.")
            } catch {
                let message = Task.isCancelled ? "Stopped. Completed actions remain saved." : kid != nil ? "Something went wrong. Try again in a moment." : error.localizedDescription
                if notebook?.unlocked == true {
                    // An interrupted kid answer was never checked, so it isn't kept.
                    if !receivedText.isEmpty && kid == nil { try? append(["role":"assistant","content":receivedText,"interrupted":true]) }
                    self.error = message; try? append(["role":"notice","content":message])
                }
            }
        }
    }
}
