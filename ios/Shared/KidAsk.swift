import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif
import NotebookCore

/// The agent for a child: "Ask", for curiosity. Nothing here names rules,
/// topics, versions or who set them; a blocked question just gets an answer.
struct KidAsk: View {
    @ObservedObject var agent: AgentModel
    @ObservedObject var documents: DocumentsModel
    @State private var draft = ""
    @State private var pending: [DocumentItem] = []
    @State private var attaching = false
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif
    private let accent = Color(red:0.95, green:0.48, blue:0.22)
    private var name: String { agent.policy?["name"] as? String ?? "" }
    private var attach: [String:Bool] { agent.policy?["attach"] as? [String:Bool] ?? [:] }
    var body: some View {
        let limit = agent.kidLimit
        VStack(spacing:0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading, spacing:16) {
                        let visible = visibleMessages
                        if visible.isEmpty && !agent.busy { welcome }
                        ForEach(visible) { message in bubble(message, last:message.id == visible.last?.id) }
                        if agent.busy && agent.runningThread == agent.selected {
                            HStack(spacing:8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }.font(.system(.body, design:.rounded))
                        }
                        Color.clear.frame(height:1).id("end")
                    }
                    .padding(24).frame(maxWidth:720).frame(maxWidth:.infinity)
                }
                .onChange(of:agent.messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor:.bottom) } }
                .onChange(of:agent.selected) { _, _ in proxy.scrollTo("end", anchor:.bottom) }
            }
            composer(limit)
        }
        .fontDesign(.rounded)
        .navigationTitle("Ask")
        .toolbar { Button { agent.newChat() } label: { Label("New Question", systemImage:"plus.bubble") }.disabled(agent.busy) }
        .fileImporter(isPresented:$attaching, allowedContentTypes:attach["files"] == true ? [.image, .pdf, .plainText] : [.image], allowsMultipleSelection:false) { result in
            if case .success(let urls) = result { Task { for item in await documents.importFiles(urls, source:"chat") where !pending.contains(item) { pending.append(item) } } }
        }
        #if os(iOS)
        .onChange(of:photo) { _, value in
            guard let value else { return }
            Task {
                if let data = try? await value.loadTransferable(type:Data.self), let item = try? await documents.importData(data, name:"Photo.jpg", type:"image/jpeg", source:"chat") { pending.append(item) }
                photo = nil
            }
        }
        #endif
    }
    /// What the child sees: their questions and the replies, never tool steps.
    private var visibleMessages: [AgentMessage] {
        agent.messages.filter { message in
            let shown = ["user", "assistant", "notice"].contains(message.role) && !message.content.isEmpty
            return shown || (message.role == "user" && !message.attachments.isEmpty)
        }
    }
    private var welcome: some View {
        let wonder = agent.kidWonder()
        return VStack(alignment:.leading, spacing:16) {
            Text(name.isEmpty ? "What are you wondering about?" : "Hi \(name)! What are you wondering about?").font(.system(size:28, weight:.semibold, design:.rounded))
            Button { ask(wonder.question) } label: {
                VStack(alignment:.leading, spacing:6) {
                    Label("Wonder of the day", systemImage:"sparkles").font(.caption.weight(.semibold)).foregroundStyle(accent)
                    Text(wonder.question).font(.title3.weight(.medium)).multilineTextAlignment(.leading)
                    Text(wonder.subject).font(.caption).foregroundStyle(.secondary)
                }
                .padding(16).frame(maxWidth:.infinity, alignment:.leading)
                .background(accent.opacity(0.12), in:RoundedRectangle(cornerRadius:18))
            }
            .buttonStyle(.plain)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:200), spacing:10)], alignment:.leading, spacing:10) {
                ForEach(agent.kidStarters(), id:\.question) { starter in
                    Button { ask(starter.question) } label: {
                        VStack(alignment:.leading, spacing:4) {
                            Text(starter.subject.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            Text(starter.question).multilineTextAlignment(.leading)
                        }
                        .padding(12).frame(maxWidth:.infinity, minHeight:70, alignment:.topLeading)
                        .background(Color.secondary.opacity(0.1), in:RoundedRectangle(cornerRadius:14))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { ask(agent.kidWonder(surprise:true).question) } label: { Label("Surprise me", systemImage:"dice") }
                .buttonStyle(.borderedProminent).tint(accent)
        }
    }
    @ViewBuilder private func bubble(_ message: AgentMessage, last: Bool) -> some View {
        if message.role == "user" {
            VStack(alignment:.trailing, spacing:6) {
                ForEach(Array(message.attachments.enumerated()), id:\.offset) { _, file in Label(file["name"] as? String ?? "Photo", systemImage:"photo").font(.caption) }
                if !message.content.isEmpty { Text(message.content) }
            }
            .padding(12).foregroundStyle(.white).background(accent, in:RoundedRectangle(cornerRadius:18))
            .frame(maxWidth:.infinity, alignment:.trailing)
        } else {
            let parts = agent.followUps(message.content)
            VStack(alignment:.leading, spacing:10) {
                AgentProse(blocks:agent.prose(parts.text)).font(.system(.title3, design:.rounded))
                if last && !agent.busy && !parts.questions.isEmpty {
                    HStack { ForEach(parts.questions, id:\.self) { q in Button(q) { ask(q) }.buttonStyle(.bordered).tint(accent) } }
                }
            }
            .padding(14).background(Color.secondary.opacity(0.08), in:RoundedRectangle(cornerRadius:18))
        }
    }
    private func composer(_ limit: [String:Any]) -> some View {
        let blocked = limit["blocked"] as? Bool == true
        return VStack(alignment:.leading, spacing:8) {
            if !pending.isEmpty || documents.importing != nil {
                HStack {
                    ForEach(pending) { item in
                        HStack(spacing:4) { Image(systemName:"photo"); Text(item.name).lineLimit(1); Button { pending.removeAll { $0.id == item.id } } label: { Image(systemName:"xmark.circle.fill") }.buttonStyle(.plain) }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4).background(.quaternary, in:Capsule())
                    }
                    if documents.importing != nil { ProgressView().controlSize(.small) }
                }
            }
            HStack(spacing:10) {
                #if os(iOS)
                if attach["library"] == true { PhotosPicker(selection:$photo, matching:.images) { Image(systemName:"photo") }.disabled(agent.busy || blocked) }
                #else
                if attach["library"] == true || attach["files"] == true { Button { attaching = true } label: { Image(systemName:"photo") }.buttonStyle(.borderless).disabled(agent.busy || blocked).help("Show me a picture") }
                #endif
                TextField(blocked ? (limit["message"] as? String ?? "") : "Ask me anything you wonder about…", text:$draft, axis:.vertical)
                    .textFieldStyle(.plain).lineLimit(1...5).onSubmit { ask(draft) }.disabled(blocked)
                Button { ask(draft) } label: { Image(systemName:"arrow.up.circle.fill").font(.title) }
                    .buttonStyle(.plain).foregroundStyle(accent)
                    .disabled(blocked || agent.busy || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && pending.isEmpty)
            }
            if let remaining = limit["remaining"] as? Int, remaining <= 10 {
                Text("\(remaining) question\(remaining == 1 ? "" : "s") left today").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in:RoundedRectangle(cornerRadius:20))
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
    private func ask(_ question: String) {
        let text = question.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !agent.busy, !text.isEmpty || !pending.isEmpty else { return }
        agent.send(text, allowWrites:false, attachments:pending.map(\.attachment)); draft = ""; pending = []
    }
}
