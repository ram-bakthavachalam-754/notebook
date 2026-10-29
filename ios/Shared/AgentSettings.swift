import SwiftUI

/// AI Agent settings in one place, shared by Mac and iPhone: the model the
/// agent talks to and the service its web search uses. Each row opens its own
/// page, like the Settings app. On Mac the pages switch in place with a back
/// button: the Settings window has no navigation bar to go back with.
struct AgentSettingsView: View {
    @ObservedObject var agent: AgentModel
    private enum Page { case model, webSearch }
    #if os(macOS)
    @State private var page: Page?
    #endif
    private static let services = ["openai":"OpenAI", "anthropic":"Anthropic", "compatible":"Local"]
    private var modelSummary: String {
        let service = Self.services[agent.config["provider"] ?? ""] ?? "Not set"
        let model = agent.config["model"] ?? ""
        return model.isEmpty ? service : "\(service) · \(model)"
    }
    private var searchSummary: String { agent.webSearch == "parallel" ? "Parallel" : "DuckDuckGo" }
    private var ready: Bool { agent.hasKey || agent.config["provider"] == "compatible" }

    var body: some View {
        #if os(macOS)
        if let page {
            VStack(spacing:0) {
                HStack {
                    Button { self.page = nil } label: { Label("AI Agent", systemImage:"chevron.left") }
                        .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("agent-settings-back")
                    Spacer()
                    Text(page == .model ? "Model" : "Web Search").font(.headline)
                    Spacer()
                    Color.clear.frame(width:80, height:1)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()
                detail(page) { self.page = nil }
            }
        } else { list }
        #else
        list
        #endif
    }
    @ViewBuilder private func detail(_ page: Page, done: (() -> Void)? = nil) -> some View {
        switch page {
        case .model: AgentModelSettings(agent:agent, done:done)
        case .webSearch: AgentWebSearchSettings(agent:agent, done:done)
        }
    }
    @ViewBuilder private func row(_ target: Page, icon: String, tint: Color, title: String, value: String) -> some View {
        #if os(macOS)
        Button { page = target } label: {
            HStack {
                AgentSettingsRow(icon:icon, tint:tint, title:title, value:value)
                Image(systemName:"chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #else
        NavigationLink { detail(target) } label: { AgentSettingsRow(icon:icon, tint:tint, title:title, value:value) }
        #endif
    }
    private var list: some View {
        Form {
            Section {
                row(.model, icon:"sparkles", tint:.purple, title:"Model", value:modelSummary)
                    .accessibilityIdentifier("agent-settings-model")
            } header: { Text("Model") } footer: {
                Text(ready ? "When you chat, the parts of your notebook the agent needs are sent to this service." : "Add an API key to start chatting.")
            }
            Section {
                row(.webSearch, icon:"globe", tint:.blue, title:"Web Search", value:searchSummary)
                    .accessibilityIdentifier("agent-settings-web-search")
            } header: { Text("Tools") } footer: {
                Text("Only the search query leaves your device, never your notes or journal.")
            }
            Section {
                Label("Keys stay in this device's keychain and never sync. Set up each device on its own.", systemImage:"key")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("AI Agent").navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// A Settings-app row: a small coloured icon, a title, and the current value.
struct AgentSettingsRow: View {
    let icon: String, tint: Color, title: String, value: String
    var body: some View {
        HStack(spacing:12) {
            Image(systemName:icon).font(.system(size:13, weight:.semibold)).foregroundStyle(.white)
                .frame(width:28, height:28).background(tint, in:RoundedRectangle(cornerRadius:7, style:.continuous))
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// AI Agent settings as a sheet, opened from the Agent screen.
struct AgentSettingsSheet: View {
    @ObservedObject var agent: AgentModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        #if os(macOS)
        VStack(spacing:0) {
            AgentSettingsView(agent:agent)
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width:540, height:560)
        #else
        NavigationStack {
            AgentSettingsView(agent:agent)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }
        #endif
    }
}

/// Which service and model the agent uses, and that service's key.
struct AgentModelSettings: View {
    @ObservedObject var agent: AgentModel
    /// Goes back to AI Agent after saving; without it, the page dismisses itself.
    var done: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var provider: String
    @State private var baseURL: String
    @State private var model: String
    @State private var key = ""
    @State private var removeKey = false
    @State private var problem: String?
    @State private var models: [String] = []
    @State private var loadingModels = false
    @State private var modelsProblem: String?
    private static let defaults = [
        "openai":("https://api.openai.com/v1", "gpt-5.4"),
        "anthropic":("https://api.anthropic.com/v1", "claude-sonnet-5-5"),
        "compatible":("http://localhost:11434/v1", "")
    ]
    /// Local servers people run most, with their usual addresses.
    private static let servers = [("Ollama", "http://localhost:11434/v1"), ("LM Studio", "http://localhost:1234/v1")]
    /// What each service had when you last saved it, or typed since: switching
    /// services never throws away what you entered for another one.
    @State private var drafts: [String:(baseURL: String, model: String, key: String)]
    init(agent: AgentModel, done: (() -> Void)? = nil) {
        self.agent = agent; self.done = done
        let provider = agent.config["provider"] ?? "openai"
        _provider = State(initialValue:provider)
        _baseURL = State(initialValue:agent.config["baseURL"] ?? "")
        _model = State(initialValue:agent.config["model"] ?? "")
        var drafts: [String:(baseURL: String, model: String, key: String)] = [:]
        for (id, saved) in AgentModel.rememberedSettings { drafts[id] = (saved["baseURL"] ?? "", saved["model"] ?? "", "") }
        drafts[provider] = (agent.config["baseURL"] ?? "", agent.config["model"] ?? "", "")
        _drafts = State(initialValue:drafts)
    }
    private var local: Bool { provider == "compatible" }
    private var savedKey: Bool { !(((try? AgentKeychain.read(["provider":provider, "baseURL":baseURL])) ?? "").isEmpty) }
    private var device: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    var body: some View {
        AgentSavePage(title:"Model", problem:problem, canSave:!model.trimmingCharacters(in:.whitespaces).isEmpty, save:save) { form }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Service", selection:$provider) {
                    Text("OpenAI").tag("openai"); Text("Anthropic").tag("anthropic"); Text("Local or other").tag("compatible")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("agent-provider")
            } footer: { Text("When you chat, the parts of your notebook the agent needs are sent to this service.") }
            if local {
                Section {
                    HStack {
                        TextField("Server address", text:$baseURL, prompt:Text("http://localhost:11434/v1"))
                            .accessibilityIdentifier("agent-base-url")
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            #endif
                        Menu("Presets") {
                            ForEach(Self.servers, id:\.0) { server in Button("\(server.0) (\(server.1))") { baseURL = server.1; models = []; modelsProblem = nil } }
                        }
                        .fixedSize()
                    }
                } header: { Text("Server") } footer: {
                    Text(device == "iPhone" ? "localhost is this iPhone. To use a server on your Mac, enter the Mac's network address, like http://192.168.1.20:11434/v1." : "Any server with an OpenAI-compatible API, ending in /v1. Ollama is usually http://localhost:11434/v1.")
                }
            }
            Section {
                HStack {
                    TextField("Model", text:$model, prompt:Text(local ? "llama3.2" : Self.defaults[provider]?.1 ?? ""))
                        .accessibilityIdentifier("agent-model")
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    if local {
                        if loadingModels { ProgressView().controlSize(.small) }
                        else if models.isEmpty { Button("Find Models") { Task { await findModels() } }.disabled(baseURL.isEmpty) }
                        else { Menu("Choose") { ForEach(models, id:\.self) { name in Button(name) { model = name } } }.fixedSize() }
                    }
                }
                if let modelsProblem { Text(modelsProblem).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Model") } footer: {
                Text(local ? "Pick a model that supports tool calling, such as llama3.1, llama3.2 or qwen2.5. The agent uses tools to read and edit your notebook." : "The model ID exactly as the provider writes it.")
            }
            Section {
                LabeledContent("Saved key") {
                    if removeKey { Text("Removed when you save").foregroundStyle(.orange) }
                    else { Text(savedKey ? "On this \(device)" : local ? "None (not needed for most local servers)" : "None").foregroundStyle(.secondary) }
                }
                SecureField(savedKey ? "Paste a new key to replace it" : "Paste your API key", text:$key)
                    .accessibilityIdentifier("agent-api-key")
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                if savedKey && !removeKey { Button("Remove Saved Key", role:.destructive) { removeKey = true; key = "" } }
            } header: { Text("API key") } footer: {
                Text("Keys stay in this \(device)'s keychain and never sync. Set up each device on its own.")
            }
        }
        .formStyle(.grouped)
        .onChange(of:provider) { old, value in
            drafts[old] = (baseURL, model, key)
            removeKey = false; problem = nil; models = []; modelsProblem = nil
            if let draft = drafts[value] { baseURL = draft.baseURL; model = draft.model; key = draft.key }
            else if let preset = Self.defaults[value] { baseURL = preset.0; model = preset.1; key = "" }
        }
        .onChange(of:baseURL) { _, _ in models = []; modelsProblem = nil }
        .onDisappear { key = "" }
    }

    private func save() {
        problem = nil
        do {
            try agent.saveSettings(["provider":provider, "baseURL":baseURL.trimmingCharacters(in:.whitespacesAndNewlines), "model":model.trimmingCharacters(in:.whitespacesAndNewlines)], key:key, clear:removeKey)
            key = ""; if let done { done() } else { dismiss() }
        } catch { problem = error.localizedDescription }
    }
    /// Asks the server which models it has (`GET /models`, which Ollama and LM Studio answer).
    private func findModels() async {
        loadingModels = true; modelsProblem = nil
        defer { loadingModels = false }
        let address = baseURL.trimmingCharacters(in:.whitespacesAndNewlines).trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        guard let url = URL(string:address + "/models"), ["http", "https"].contains(url.scheme ?? "") else { modelsProblem = "Enter the server address first."; return }
        var request = URLRequest(url:url); request.timeoutInterval = 8
        let saved = key.isEmpty ? ((try? AgentKeychain.read(["provider":provider, "baseURL":baseURL])) ?? "") : key
        if !saved.isEmpty { request.setValue("Bearer " + saved, forHTTPHeaderField:"Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let root = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let list = root["data"] as? [[String:Any]] else { modelsProblem = "The server answered, but not with a list of models."; return }
            models = list.compactMap { $0["id"] as? String }.sorted()
            if models.isEmpty { modelsProblem = "The server has no models yet. With Ollama, run: ollama pull llama3.2" }
            else if model.isEmpty { model = models[0] }
        } catch { modelsProblem = "Couldn't reach \(address). Is the server running?" }
    }
}

/// Which service the agent's web_search tool uses, and Parallel's key.
struct AgentWebSearchSettings: View {
    @ObservedObject var agent: AgentModel
    var done: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var provider: String
    @State private var key = ""
    @State private var removeKey = false
    @State private var problem: String?
    init(agent: AgentModel, done: (() -> Void)? = nil) { self.agent = agent; self.done = done; _provider = State(initialValue:agent.webSearch) }
    private var savedKey: Bool { agent.hasSearchKey }
    private var device: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }
    var body: some View {
        AgentSavePage(title:"Web Search", problem:problem, canSave:provider == "duckduckgo" || (savedKey && !removeKey) || !key.trimmingCharacters(in:.whitespaces).isEmpty, save:save) {
            Form {
                Section {
                    choice("duckduckgo", title:"DuckDuckGo", detail:"Free, no key. Topic summaries and links, not full search results.")
                    choice("parallel", title:"Parallel", detail:"Full web search with ranked pages and excerpts. Uses your Parallel API key.")
                } header: { Text("Search with") } footer: {
                    Text("The agent always reads web pages itself; this only changes how it searches.")
                }
                if provider == "parallel" {
                    Section {
                        LabeledContent("Saved key") {
                            if removeKey { Text("Removed when you save").foregroundStyle(.orange) }
                            else { Text(savedKey ? "On this \(device)" : "None").foregroundStyle(.secondary) }
                        }
                        SecureField(savedKey ? "Paste a new key to replace it" : "Paste your Parallel API key", text:$key)
                            .accessibilityIdentifier("agent-search-key")
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                        if savedKey && !removeKey { Button("Remove Saved Key", role:.destructive) { removeKey = true; key = "" } }
                        Link("Get a key at platform.parallel.ai", destination:URL(string:"https://platform.parallel.ai")!)
                    } header: { Text("Parallel API key") } footer: {
                        Text("Kept in this \(device)'s keychain and never synced. Searches are billed to your Parallel account.")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of:provider) { _, _ in problem = nil }
        .onDisappear { key = "" }
    }
    private func choice(_ id: String, title: String, detail: String) -> some View {
        Button { provider = id } label: {
            HStack {
                VStack(alignment:.leading, spacing:2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if provider == id { Image(systemName:"checkmark").foregroundStyle(Color.accentColor).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-search-" + id)
        .accessibilityAddTraits(provider == id ? .isSelected : [])
    }
    private func save() {
        problem = nil
        do { try agent.saveWebSearch(provider, key:key, clear:removeKey); key = ""; if let done { done() } else { dismiss() } }
        catch { problem = error.localizedDescription }
    }
}

/// A settings page with Save: in the toolbar on iPhone, in a bar under the form on Mac.
/// Saving goes back to AI Agent.
struct AgentSavePage<Content: View>: View {
    let title: String
    let problem: String?
    let canSave: Bool
    let save: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if os(macOS)
        VStack(spacing:0) {
            content()
            Divider()
            HStack {
                if let problem { Label(problem, systemImage:"exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).lineLimit(2) }
                Spacer()
                Button("Save", action:save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
            .padding(12)
        }
        #else
        content()
            .safeAreaInset(edge:.bottom) {
                if let problem { Label(problem, systemImage:"exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).padding().frame(maxWidth:.infinity).background(.bar) }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Save", action:save).disabled(!canSave).accessibilityIdentifier("agent-save-settings") } }
        #endif
    }
}
