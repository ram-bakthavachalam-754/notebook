import SwiftUI
import UniformTypeIdentifiers
import NotebookCore

struct MacAgentThreads: View {
    @ObservedObject var agent: AgentModel
    @State private var deleting: AgentThread?
    var body: some View {
        List(selection:Binding(get:{ agent.selected }, set:{ if let id = $0 { agent.select(id) } })) {
            ForEach(agent.threads) { thread in
                Label { Text(thread.title).lineLimit(2) } icon: { Image(systemName:"bubble.left").foregroundStyle(.purple) }.padding(.vertical, 4).tag(thread.id)
                    .contextMenu { Button("Delete Conversation…", role:.destructive) { deleting = thread } }
            }
        }
        .onDeleteCommand { deleting = agent.threads.first { $0.id == agent.selected } }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented:Binding(get:{ deleting != nil }, set:{ if !$0 { deleting = nil } }), presenting:deleting) { thread in
            Button("Delete", role:.destructive) { agent.deleteThread(thread.id) }
        } message: { _ in Text("Its messages are removed from this Mac and your other devices. Notes or entries the agent made stay.") }
        .overlay { if agent.threads.isEmpty { ContentUnavailableView(agent.kidMode ? "No questions yet" : "No conversations yet", systemImage:"sparkles", description:Text(agent.kidMode ? "Ask about anything you wonder about." : "Start one to ask about your notes, journal and finances.")) } }
        .navigationTitle(agent.kidMode ? "Ask" : "Agent")
        .navigationSplitViewColumnWidth(min:220, ideal:260)
        .toolbar {
            Button { agent.newChat() } label: { Label(agent.kidMode ? "New Question" : "New Conversation", systemImage:"square.and.pencil") }.disabled(agent.busy).help(agent.kidMode ? "New question" : "New conversation")
            Button(role:.destructive) { deleting = agent.threads.first { $0.id == agent.selected } } label: { Label("Delete Conversation", systemImage:"trash") }
                .disabled(agent.selected == nil || agent.busy).help("Delete this conversation (⌫)")
        }
        .onAppear { agent.reload() }
    }
}

struct MacAgentChat: View {
    @ObservedObject var notebook: NotebookModel
    @ObservedObject var agent: AgentModel
    @ObservedObject var documents: DocumentsModel
    @State private var draft = ""
    @State private var allowEdits = true
    @State private var pending: [DocumentItem] = []
    @State private var attaching = false
    @State private var settings = false
    @State private var dropping = false
    private let suggestions = [
        ("Turn reflection into a note", "Read my recent journal entries and summarize recurring themes. Save the summary as a note.", "book.closed", Color.pink),
        ("See where the money goes", "Review my accounts and holdings. Explain what stands out, using my saved data.", "chart.pie", Color.green),
        ("Find a way forward", "Find my notes about unfinished projects and help me make an action plan.", "list.bullet.clipboard", Color.orange),
        ("Make sense of a file", "Look through my Documents, read the most recent file, and tell me what it contains and anything I should act on.", "doc.text.magnifyingglass", Color.indigo)
    ]
    var body: some View {
        VStack(spacing:0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading, spacing:18) {
                        if agent.messages.isEmpty && !agent.busy { welcome }
                        ForEach(agent.messages) { message($0) }
                        if agent.busy && agent.runningThread == agent.selected {
                            HStack(alignment:.top, spacing:12) {
                                avatar
                                VStack(alignment:.leading, spacing:10) {
                                    if !agent.streamingText.isEmpty { AgentProse(blocks:agent.prose(agent.streamingText)) }
                                    HStack(spacing:8) { ProgressView().controlSize(.small); Text(agent.status).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        Color.clear.frame(height:1).id("end")
                    }
                    .padding(.horizontal, MacStyle.pagePadding).padding(.vertical, 24).frame(maxWidth:780).frame(maxWidth:.infinity)
                }
                .onChange(of:agent.messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor:.bottom) } }
                .onChange(of:agent.selected) { _, _ in proxy.scrollTo("end", anchor:.bottom) }
            }
            composer
        }
        .navigationTitle(agent.threads.first { $0.id == agent.selected }?.title ?? "Agent")
        .navigationSubtitle("\(agent.config["model"] ?? "AI") · \(notebook.connected ? "Chats sync with iCloud" : "Saved on this Mac")")
        .toolbar { Button { settings = true } label: { Label("Agent Settings", systemImage:"slider.horizontal.3") }.disabled(agent.busy).help("Choose your AI provider and model") }
        .sheet(isPresented:$settings) { AgentSettingsSheet(agent:agent) }
        .fileImporter(isPresented:$attaching, allowedContentTypes:[.item], allowsMultipleSelection:true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .alert("Agent", isPresented:Binding(get:{ agent.error != nil }, set:{ if !$0 { agent.error = nil } })) { } message: { Text(agent.error ?? "") }
    }
    private var avatar: some View {
        Image(systemName:"sparkles").font(.system(size:12, weight:.semibold)).foregroundStyle(.white)
            .frame(width:26, height:26).background(LinearGradient(colors:[.purple, .indigo], startPoint:.topLeading, endPoint:.bottomTrailing), in:Circle())
    }
    private var welcome: some View {
        VStack(alignment:.leading, spacing:16) {
            Image(systemName:"sparkles").font(.system(size:22, weight:.semibold)).foregroundStyle(.white)
                .frame(width:48, height:48).background(LinearGradient(colors:[.purple, .indigo], startPoint:.topLeading, endPoint:.bottomTrailing), in:RoundedRectangle(cornerRadius:14, style:.continuous))
            Text("A little help.\nA lot of possibility.").font(MacStyle.titleFont)
            Text("Find connections and get things done across your notes, journal, finances and documents.").foregroundStyle(.secondary)
            LazyVGrid(columns:[GridItem(.flexible(), spacing:12), GridItem(.flexible(), spacing:12)], spacing:12) {
                ForEach(suggestions, id:\.0) { item in
                    Button { draft = item.1 } label: {
                        VStack(alignment:.leading, spacing:8) {
                            Image(systemName:item.2).font(.system(size:15, weight:.medium)).foregroundStyle(item.3)
                            Text(item.0).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                            Text(item.1).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace:true).multilineTextAlignment(.leading)
                        }
                        .card(padding:14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
            if !agent.hasKey && agent.config["provider"] != "compatible" { Button("Connect Your AI…") { settings = true }.buttonStyle(.borderedProminent) }
        }
        .padding(.vertical, 28)
    }
    @ViewBuilder private func message(_ message: AgentMessage) -> some View {
        if message.role == "tool" {
            DisclosureGroup {
                Text(String(message.content.prefix(4000))).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth:.infinity, alignment:.leading)
            } label: {
                Label(message.activity, systemImage:message.result["error"] == nil ? "checkmark.circle" : "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
            }
        } else if message.role == "user" && (!message.content.isEmpty || !message.attachments.isEmpty) {
            HStack {
                Spacer(minLength:80)
                VStack(alignment:.trailing, spacing:6) {
                    if !message.attachments.isEmpty { attachments(message) }
                    if !message.content.isEmpty {
                        Text(message.content).textSelection(.enabled)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color.notebookBlue.opacity(0.13), in:RoundedRectangle(cornerRadius:16, style:.continuous))
                    }
                }
            }
        } else if !message.content.isEmpty || !message.attachments.isEmpty {
            HStack(alignment:.top, spacing:12) {
                if message.role == "notice" { Image(systemName:"info.circle").foregroundStyle(.secondary).frame(width:26) } else { avatar }
                VStack(alignment:.leading, spacing:6) {
                    if !message.attachments.isEmpty { attachments(message) }
                    if message.role == "assistant" { AgentProse(blocks:agent.prose(message.content)) }
                    else { Text(message.content).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity, alignment:.leading) }
                }
                .padding(.top, 3)
            }
        }
    }
    private func attachments(_ message: AgentMessage) -> some View {
        HStack { ForEach(Array(message.attachments.enumerated()), id:\.offset) { _, file in Label(file["name"] as? String ?? "Document", systemImage:"doc").font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in:Capsule()) } }
    }
    private var composer: some View {
        VStack(alignment:.leading, spacing:8) {
            if !pending.isEmpty || documents.importing != nil {
                HStack {
                    ForEach(pending) { item in
                        HStack(spacing:4) { Image(systemName:"doc"); Text(item.name).lineLimit(1); Button { pending.removeAll { $0.id == item.id } } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain) }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in:Capsule())
                    }
                    if let importing = documents.importing { ProgressView().controlSize(.small); Text(importing).font(.caption).foregroundStyle(.secondary) }
                }
            }
            TextField("Ask, explore, or get something done…", text:$draft, axis:.vertical)
                .textFieldStyle(.plain).lineLimit(2...8).onSubmit(send)
            HStack(spacing:12) {
                Button { attaching = true } label: { Image(systemName:"paperclip") }.buttonStyle(.borderless).disabled(agent.busy || documents.importing != nil).help("Attach files. They're saved in Documents.")
                Toggle("Allow edits", isOn:$allowEdits).toggleStyle(.checkbox).help("Let the agent create and change records").foregroundStyle(.secondary)
                Spacer()
                let empty = draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && pending.isEmpty
                if agent.busy {
                    Button { agent.cancel() } label: { Image(systemName:"stop.fill").font(.system(size:11, weight:.bold)).foregroundStyle(.white).frame(width:28, height:28).background(Color.primary.opacity(0.8), in:Circle()) }
                        .buttonStyle(.plain).help("Stop")
                } else {
                    Button(action:send) { Image(systemName:"arrow.up").font(.system(size:13, weight:.bold)).foregroundStyle(.white).frame(width:28, height:28).background(empty ? Color.secondary.opacity(0.4) : Color.notebookBlue, in:Circle()) }
                        .buttonStyle(.plain).keyboardShortcut(.return, modifiers:.command).disabled(empty).help("Send (⌘↩)")
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.background, in:RoundedRectangle(cornerRadius:20, style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:20, style:.continuous).strokeBorder(dropping ? Color.notebookBlue : Color.cardStroke, lineWidth:dropping ? 2 : 1))
        .shadow(color:.black.opacity(0.06), radius:12, y:4)
        .frame(maxWidth:780)
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth:.infinity)
        .dropDestination(for:URL.self) { urls, _ in attach(urls); return true } isTargeted: { dropping = $0 }
    }
    private func attach(_ urls: [URL]) {
        Task { for item in await documents.importFiles(urls, source:"chat") where !pending.contains(item) { pending.append(item) } }
    }
    private func send() {
        guard !agent.busy, !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !pending.isEmpty else { return }
        if !agent.hasKey && agent.config["provider"] != "compatible" { settings = true; return }
        agent.send(draft, allowWrites:allowEdits, attachments:pending.map(\.attachment)); draft = ""; pending = []
    }
}

