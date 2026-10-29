import SwiftUI
import PhotosUI
import NotebookCore

private struct AgentScrollEnd: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct NotebookAgent: View {
    @ObservedObject var notebook: NotebookModel
    @StateObject private var agent: AgentModel
    @State private var draft = ""
    @State private var pending: [DocumentItem] = []
    @State private var attachingFiles = false
    @State private var attachPhoto: PhotosPickerItem?
    @ObservedObject private var documents: DocumentsModel
    @State private var allowEdits = true
    @State private var settings = false
    @State private var conversations = false
    @State private var deletingThread: AgentThread?
    @AppStorage("notebook-agent-live-text") private var liveText = true
    @State private var pendingSend = false
    @State private var scrollHeight: CGFloat = 0
    @State private var scrollEnd: CGFloat = 0
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(notebook: NotebookModel) { self.notebook = notebook; _agent = StateObject(wrappedValue:notebook.agent); documents = notebook.documents }
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:22) {
                            if agent.messages.isEmpty && !agent.busy {
                                VStack(alignment:.leading,spacing:18) {
                                    Image(systemName:"sparkle").font(.system(size:32)).foregroundStyle(Color.notebookBlue)
                                    Text("A little help.\nA lot of possibility.").font(.custom("Charter",size:34))
                                    Text("Find connections and get things done across your notes, journal, and finances.").foregroundStyle(.secondary)
                                    suggestion("Turn reflection into a note", "Read my recent journal entries and summarize recurring themes. Save the summary as a note.")
                                    suggestion("See where the money goes", "Review my finances and this month's spending. Explain what stands out, using my saved data.")
                                    suggestion("Find a way forward", "Find my notes about unfinished projects and help me make an action plan.")
                                    if !agent.hasKey && agent.config["provider"] != "compatible" { Button("Connect your AI") { settings = true }.buttonStyle(.borderedProminent) }
                                }.padding(.vertical,30)
                            }
                            ForEach(agent.messages) { message in
                                if message.role == "tool" {
                                    DisclosureGroup {
                                        if let sources = message.result["sources"] as? [[String:String]] {
                                            ForEach(Array(sources.enumerated()),id:\.offset) { _,source in
                                                if let address = source["url"], let url = try? AgentWebTransport.validateURL(address) { Link(source["title"] ?? address,destination:url).font(.caption) }
                                            }
                                        }
                                        if ["search","page","document"].contains(message.result["kind"] as? String ?? "") {
                                            let excerpt = message.result["abstract"] as? String ?? message.result["content"] as? String ?? message.result["answer"] as? String ?? message.result["message"] as? String ?? ""
                                            Text(String(excerpt.prefix(1600))).font(.caption).textSelection(.enabled)
                                            if let time = message.result["fetchedAt"] as? String { Text("Retrieved " + time).font(.caption2).foregroundStyle(.secondary) }
                                            if message.result["kind"] as? String == "document" { Text(message.result["view"] as? String == "image" ? "Image shown to the model with its recognized text" : "Recognized text from Documents").font(.caption2).foregroundStyle(.secondary) }
                                        } else { Text(message.content).font(.caption.monospaced()).textSelection(.enabled) }
                                    } label: {
                                        Label(message.activity,systemImage:message.result["error"] == nil ? "checkmark.circle" : "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                                    }
                                } else if !message.content.isEmpty || !message.attachments.isEmpty {
                                    VStack(alignment:.leading,spacing:8) {
                                        Text(message.role == "user" ? "You" : message.role == "notice" ? "Status" : "Notebook").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        if message.role == "assistant" { AgentProse(blocks:agent.prose(message.content)) }
                                        else if !message.content.isEmpty { Text(message.content).font(.body).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                                        if !message.attachments.isEmpty {
                                            FlowChips(items:message.attachments.map { ($0["id"] as? String ?? UUID().uuidString, $0["name"] as? String ?? "Document") },remove:nil)
                                        }
                                    }
                                    .padding(message.role == "user" ? 16 : 0)
                                    .background(message.role == "user" ? Color.notebookPaper : Color.clear,in:RoundedRectangle(cornerRadius:14))
                                    .id(message.id)
                                }
                            }
                            if agent.busy && agent.runningThread == agent.selected {
                                VStack(alignment:.leading,spacing:12) {
                                    if liveText && !agent.streamingText.isEmpty {
                                        Text("Notebook").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        AgentProse(blocks:agent.prose(agent.streamingText)).accessibilityIdentifier("agent-streaming-response")
                                    }
                                    HStack(spacing:10) { ProgressView().controlSize(.small); Text(agent.status).font(.caption).foregroundStyle(.secondary) }.accessibilityIdentifier("agent-working")
                                }
                            }
                            Color.clear.frame(height:1).id("end").background(GeometryReader { geometry in Color.clear.preference(key:AgentScrollEnd.self,value:geometry.frame(in:.named("agent-scroll")).maxY) })
                        }.padding(20).frame(maxWidth:680).frame(maxWidth:.infinity)
                    }
                    .coordinateSpace(name:"agent-scroll")
                    .background(GeometryReader { geometry in Color.clear.onAppear { scrollHeight = geometry.size.height }.onChange(of:geometry.size.height) { _,height in scrollHeight = height } })
                    .onPreferenceChange(AgentScrollEnd.self) { scrollEnd = $0 }
                    .overlay(alignment:.bottom) {
                        if scrollEnd > scrollHeight + 60 {
                            Button {
                                withAnimation(reduceMotion ? nil : .smooth(duration:0.22)) { proxy.scrollTo("end",anchor:.bottom) }
                            } label: {
                                Label(agent.busy && agent.runningThread == agent.selected ? "New text below" : "Jump to latest",systemImage:"arrow.down").font(.caption.weight(.medium)).padding(.horizontal,14).padding(.vertical,10)
                            }.buttonStyle(.plain).background(.regularMaterial,in:Capsule()).overlay(Capsule().stroke(Color.secondary.opacity(0.2))).padding(.bottom,12).accessibilityIdentifier("agent-jump-latest")
                        }
                    }
                    .onChange(of:agent.messages.last(where:{$0.role == "user"})?.id) { _,id in
                        if pendingSend, let id { pendingSend = false; proxy.scrollTo(id,anchor:.top) }
                    }
                    .onChange(of:agent.busy) { _,value in if !value { pendingSend = false } }
                    .onChange(of:agent.selected) { _,_ in if !pendingSend { proxy.scrollTo("end",anchor:.bottom) } }
                    .onAppear { proxy.scrollTo("end",anchor:.bottom) }
                }
                VStack(alignment:.leading,spacing:10) {
                    if let error = agent.error { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("agent-error") }
                    VStack(spacing:10) {
                        if !pending.isEmpty {
                            FlowChips(items:pending.map { ($0.id,$0.name) }) { id in pending.removeAll { $0.id == id } }
                            Text("Saved in Documents · the agent reads them when you send").font(.caption2).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                        }
                        if let importing = documents.importing { HStack(spacing:8) { ProgressView().controlSize(.small); Text(importing).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading) }
                        TextField("Ask, explore, or get something done…",text:$draft,axis:.vertical).lineLimit(2...6).accessibilityIdentifier("agent-input")
                        HStack {
                            Menu {
                                Button("Attach from Files",systemImage:"folder") { attachingFiles = true }
                                PhotosPicker(selection:$attachPhoto,matching:.images) { Label("Attach a photo",systemImage:"photo") }
                                if !documents.documents.isEmpty {
                                    Menu("From Documents") { ForEach(documents.documents.prefix(30)) { item in Button(item.name) { attach(item) } } }
                                }
                            } label: { Image(systemName:"paperclip").font(.body) }.disabled(agent.busy || documents.importing != nil).accessibilityLabel("Attach files")
                            Toggle("Allow edits",isOn:$allowEdits).toggleStyle(.switch).fixedSize().font(.caption).accessibilityIdentifier("agent-allow-edits")
                            Spacer()
                            if agent.busy { Button("Stop") { agent.cancel() }.buttonStyle(.bordered) }
                            else { Button { send() } label: { Image(systemName:"arrow.up").font(.body.weight(.semibold)).padding(4) }.buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && pending.isEmpty).accessibilityLabel("Send message") }
                        }
                    }.padding(14).background(Color.notebookPaper,in:RoundedRectangle(cornerRadius:16))
                    .fileImporter(isPresented:$attachingFiles,allowedContentTypes:[.item],allowsMultipleSelection:true) { result in
                        if case .success(let urls) = result { Task { for item in await documents.importFiles(urls,source:"chat") { attach(item) } } }
                    }
                    .onChange(of:attachPhoto) { _, value in
                        guard let value else { return }
                        Task {
                            do {
                                guard let data = try await value.loadTransferable(type:Data.self) else { return }
                                let type = value.supportedContentTypes.first
                                attach(try await documents.importData(data,name:"Photo " + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)) + "." + (type?.preferredFilenameExtension ?? "jpg"),type:type?.preferredMIMEType,source:"chat"))
                            } catch { agent.error = error.localizedDescription }
                            attachPhoto = nil
                        }
                    }
                    HStack {
                        Text("\(agent.config["model"] ?? "AI") · \(notebook.connected ? "Chats sync with iCloud" : "Saved on this device")").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Live text",isOn:$liveText).toggleStyle(.button).font(.caption2).accessibilityIdentifier("agent-live-text")
                    }
                }.padding(.horizontal,16).padding(.vertical,12)
            }
            .background(Color(uiColor:.systemBackground))
            .navigationTitle("Agent").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button { conversations = true } label: { Image(systemName:"bubble.left.and.bubble.right") }.accessibilityLabel("Conversations") }
                ToolbarItemGroup(placement:.topBarTrailing) {
                    Button { agent.newChat() } label: { Image(systemName:"square.and.pencil") }.accessibilityLabel("New conversation")
                    Button { settings = true } label: { Image(systemName:"gearshape") }.disabled(agent.busy).accessibilityLabel("Agent settings")
                }
            }
            .sheet(isPresented:$settings) { AgentSettingsSheet(agent:agent) }
            .sheet(isPresented:$conversations) {
                NavigationStack {
                    List {
                        Button("New conversation",systemImage:"plus") { agent.newChat(); conversations = false }
                        ForEach(agent.threads) { thread in
                            Button { agent.select(thread.id); conversations = false } label: { HStack { Text(thread.title).foregroundStyle(.primary); Spacer(); if agent.selected == thread.id { Image(systemName:"checkmark").foregroundStyle(Color.notebookBlue) } } }
                                .swipeActions { Button("Delete", role:.destructive) { deletingThread = thread } }
                        }
                    }.navigationTitle("Conversations").toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { conversations = false } } }
                    .confirmationDialog("Delete “\(deletingThread?.title ?? "")”?", isPresented:Binding(get:{ deletingThread != nil }, set:{ if !$0 { deletingThread = nil } }), titleVisibility:.visible, presenting:deletingThread) { thread in
                        Button("Delete", role:.destructive) { agent.deleteThread(thread.id) }
                    } message: { _ in Text("Its messages are removed from this iPhone and your other devices. Notes or entries the agent made stay.") }
                }
            }
            .onAppear { agent.reload() }
            .onChange(of:notebook.reloadVersion) { _,_ in agent.reload() }
            .onChange(of:notebook.unlocked) { _,value in if !value { settings = false; conversations = false; draft = ""; pending = []; attachingFiles = false; agent.locked() } else { agent.reload() } }
            .onChange(of:phase) { _,value in if value == .background { settings = false; conversations = false } }
        }
    }
    private func suggestion(_ title: String, _ prompt: String) -> some View {
        Button { draft = prompt } label: { HStack { Text(title).font(.subheadline); Spacer(); Image(systemName:"arrow.up.right") }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.notebookPaper,in:RoundedRectangle(cornerRadius:12)) }.buttonStyle(.plain)
    }
    private func attach(_ item: DocumentItem) {
        guard !pending.contains(where: { $0.id == item.id }) else { return }
        guard pending.count < 10 else { agent.error = "Attach up to 10 documents per message."; return }
        pending.append(item)
    }
    private func send() {
        if !agent.hasKey && agent.config["provider"] != "compatible" { settings = true; return }
        pendingSend = true; agent.send(draft,allowWrites:allowEdits,attachments:pending.map(\.attachment)); draft = ""; pending = []
    }
}

/// Attachment chips: a name per document, with an optional remove button while composing.
private struct FlowChips: View {
    let items: [(String,String)]
    let remove: ((String) -> Void)?
    var body: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:6) {
                ForEach(items,id:\.0) { id, name in
                    HStack(spacing:6) {
                        Image(systemName:"doc").font(.caption2)
                        Text(name).font(.caption).lineLimit(1)
                        if let remove { Button { remove(id) } label: { Image(systemName:"xmark").font(.caption2) }.buttonStyle(.plain).accessibilityLabel("Remove " + name) }
                    }.padding(.horizontal,9).padding(.vertical,6).background(Color(uiColor:.secondarySystemBackground),in:Capsule())
                }
            }
        }
    }
}

