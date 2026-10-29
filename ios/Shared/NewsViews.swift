import SwiftUI

/// A headline row: the title as the source wrote it, who published it and when.
struct NewsRow: View {
    let story: NewsStory
    var showTopic = false
    var saved = false
    var body: some View {
        VStack(alignment:.leading, spacing:4) {
            Text(story.title).font(.headline).lineLimit(3)
            if !story.blurb.isEmpty { Text(story.blurb).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing:5) {
                Text(story.byline)
                if let date = story.publishedAt { Text("·"); Text(date, format:.relative(presentation:.named)) }
                if story.via == "hn" { Text("·"); Text("\(story.points) points on Hacker News") }
                if showTopic { Text("·"); Text(story.topic).foregroundStyle(Color.notebookBlue) }
                if saved { Image(systemName:"bookmark.fill").foregroundStyle(.orange).accessibilityLabel("Saved") }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Summaries already written this session, so reopening a story is instant.
@MainActor private enum NewsSummaries { static var byURL: [String:(text: String, label: String)] = [:] }

/// Reading a story without leaving Notebook: the article is read on this
/// device and your model summarizes it. Without a model you get the article's
/// text; when the page can't be read here, its link.
struct NewsReader: View {
    @ObservedObject var news: NewsModel
    @ObservedObject var agent: AgentModel
    let story: NewsStory
    private enum Phase: Equatable { case reading, summarizing(String, String), summary(String, String), article(String), unreadable(String) }
    @State private var phase = Phase.reading
    /// The publisher's own address, once a Google News link is resolved.
    @State private var address: String?
    @Environment(\.openURL) private var openURL
    var body: some View {
        ScrollView {
            VStack(alignment:.leading, spacing:16) {
                VStack(alignment:.leading, spacing:8) {
                    Text(story.topic.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Color.notebookBlue)
                    Text(story.title).font(.system(size:28, weight:.semibold, design:.serif)).textSelection(.enabled)
                    HStack(spacing:6) {
                        Text(story.byline)
                        if let date = story.publishedAt { Text("·"); Text(date.formatted(date:.abbreviated, time:.shortened)) }
                        Text("· via \(NewsModel.sourceNames[story.via] ?? story.via)")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing:10) {
                    Button { open(address ?? story.url) } label: { Label("Open Article", systemImage:"safari") }.buttonStyle(.borderedProminent).tint(.notebookBlue)
                    Button { news.toggleSaved(story) } label: { Label(news.isSaved(story) ? "Saved" : "Save", systemImage:news.isSaved(story) ? "bookmark.fill" : "bookmark") }.buttonStyle(.bordered)
                    if !story.discussionURL.isEmpty, story.discussionURL != story.url { Button { open(story.discussionURL) } label: { Label("Discussion", systemImage:"bubble.left.and.bubble.right") }.buttonStyle(.bordered) }
                    ShareLink(item:URL(string:story.url) ?? URL(string:"https://")!) { Label("Share", systemImage:"square.and.arrow.up") }.buttonStyle(.bordered)
                }
                .labelStyle(.titleAndIcon)
                Divider()
                content
            }
            .padding(28).frame(maxWidth:720, alignment:.leading).frame(maxWidth:.infinity)
        }
        .task(id:story.url) { await load() }
    }
    @ViewBuilder private var content: some View {
        switch phase {
        case .reading:
            HStack(spacing:10) { ProgressView().controlSize(.small); Text("Reading the article…").foregroundStyle(.secondary) }
        case .summarizing(let note, let partial):
            label(note, busy:true)
            if !partial.isEmpty { AgentProse(blocks:agent.prose(partial)) }
        case .summary(let note, let text):
            label(note, busy:false)
            AgentProse(blocks:agent.prose(text))
        case .article(let text):
            label(agent.canSummarize ? "The article, as read on this device." : "The article, as read on this device. Set up a model in Agent Settings to get summaries.", busy:false)
            ForEach(Array(paragraphs(text).enumerated()), id:\.offset) { _, paragraph in Text(paragraph).textSelection(.enabled).lineSpacing(4) }
        case .unreadable(let reason):
            VStack(alignment:.leading, spacing:10) {
                if !story.blurb.isEmpty { Text(story.blurb).font(.title3) }
                Label(reason, systemImage:"doc.text.magnifyingglass").foregroundStyle(.secondary)
                Button("Open Article") { open(address ?? story.url) }
            }
        }
    }
    private func label(_ text: String, busy: Bool) -> some View {
        HStack(spacing:6) {
            if busy { ProgressView().controlSize(.small) } else { Image(systemName:"sparkles").foregroundStyle(.secondary) }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func paragraphs(_ text: String) -> [String] {
        // The reader's text arrives as one run; split it on sentence ends into readable chunks.
        var out: [String] = [], current = ""
        for sentence in text.components(separatedBy:". ") {
            current += (current.isEmpty ? "" : ". ") + sentence
            if current.count > 450 { out.append(current + (current.hasSuffix(".") ? "" : ".")); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
    private func open(_ address: String) { if let url = URL(string:address) { openURL(url) } }
    private func load() async {
        if let cached = NewsSummaries.byURL[story.url] { phase = .summary(cached.label, cached.text); return }
        phase = .reading
        let link = await NewsModel.resolve(story.url)
        address = link
        // 1. The article itself, read on this device.
        let text = ((try? await agent.readArticle(link))?.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        guard !Task.isCancelled else { return }
        let readable = text.count >= 400
        if readable, agent.canSummarize {
            let note = "Summary by \(agent.modelLabel), from the article"
            if let summary = await summarize(note, material:"ARTICLE TEXT:\n" + String(text.prefix(agent.summaryInput))) { finish(note, summary); return }
        }
        guard !Task.isCancelled else { return }
        // 2. Can't be read (or wasn't an article): other outlets' coverage of the same story.
        if agent.canSummarize {
            phase = .summarizing("The article wouldn't load. Checking other coverage…", "")
            let others = await NewsModel.coverage(story)
            if others.count >= 2 {
                let material = "SEARCH COVERAGE (headlines and descriptions from several outlets; the article itself could not be read):\n" + others.map { "- \($0.title) (\($0.byline)): \($0.blurb)" }.joined(separator:"\n")
                let note = "Summary by \(agent.modelLabel), from coverage by " + ListFormatter.localizedString(byJoining:Array(Set(others.map(\.byline))).sorted().prefix(3).map { $0 })
                if let summary = await summarize(note, material:material) { finish(note, summary); return }
            }
        }
        guard !Task.isCancelled else { return }
        // 3. No model: the article's own text. 4. Nothing worked: the link.
        if readable { phase = .article(text) }
        else { phase = .unreadable(agent.canSummarize ? "This article couldn't be read here, and there wasn't enough other coverage to summarize. Open it in your browser." : "This article couldn't be read here. Open it in your browser.") }
    }
    /// One streamed summary; nil when the model judged the material unusable or failed.
    private func summarize(_ note: String, material: String) async -> String? {
        phase = .summarizing(note.replacingOccurrences(of:"Summary by", with:"Summarizing with"), "")
        do {
            let text = try await agent.write(system:NewsModel.summarySystem, prompt:NewsModel.summaryPrompt(title:story.title, material:material), maxTokens:8000) { partial in
                if !partial.hasPrefix("UNUSABLE") { phase = .summarizing(note.replacingOccurrences(of:"Summary by", with:"Summarizing with"), partial) }
            }
            return text.isEmpty || text.hasPrefix("UNUSABLE") ? nil : text
        } catch is CancellationError { return nil }
        catch { if !Task.isCancelled { news.error = "The summary didn't finish: \(error.localizedDescription)" }; return nil }
    }
    private func finish(_ note: String, _ text: String) {
        NewsSummaries.byURL[story.url] = (text, note)
        phase = .summary(note, text)
    }
}

/// Topics you follow and where headlines come from.
struct NewsTopics: View {
    @ObservedObject var news: NewsModel
    @State private var custom = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if news.topics.isEmpty { Text("Pick a few topics below, or type your own.").foregroundStyle(.secondary) }
                    ForEach(news.topics, id:\.self) { topic in
                        HStack { Text(topic); Spacer(); Button { news.unfollow(topic) } label: { Image(systemName:"minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Stop following \(topic)") }
                    }
                    HStack {
                        TextField("Any topic, like SF Giants or Rust", text:$custom).onSubmit(add)
                        Button("Follow", action:add).disabled(custom.trimmingCharacters(in:.whitespaces).isEmpty)
                    }
                } header: { Text("Following (\(news.topics.count) of \(NewsModel.maxTopics))") }
                ForEach(NewsModel.catalog, id:\.group) { group in
                    Section(group.group) {
                        FlowChips(items:group.topics, on:news.following) { topic in news.following(topic) ? news.unfollow(news.topics.first { $0.caseInsensitiveCompare(topic) == .orderedSame } ?? topic) : news.follow(topic) }
                    }
                }
                Section {
                    ForEach(["google", "bing", "hn"], id:\.self) { id in
                        Toggle(isOn:Binding(get:{ news.sources.contains(id) }, set:{ _ in news.toggleSource(id) })) {
                            VStack(alignment:.leading, spacing:2) { Text(NewsModel.sourceNames[id]!); Text(NewsModel.sourceDetails[id]!).font(.caption).foregroundStyle(.secondary) }
                        }
                        .disabled(news.sources == [id])
                    }
                } header: { Text("Sources") } footer: { Text("Only the topic is sent to these services. Headlines are quoted as published; Notebook never writes them.") }
            }
            .formStyle(.grouped)
            .navigationTitle("Topics")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(width:520, height:620)
        #endif
    }
    private func add() { news.follow(custom); custom = "" }
}

/// Topic chips that wrap onto as many lines as they need.
private struct FlowChips: View {
    let items: [String]
    let on: (String) -> Bool
    let toggle: (String) -> Void
    var body: some View {
        FlowLayout(spacing:8) {
            ForEach(items, id:\.self) { item in
                Button { toggle(item) } label: {
                    Label(item, systemImage:on(item) ? "checkmark" : "plus").font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(on(item) ? Color.notebookBlue.opacity(0.15) : Color.secondary.opacity(0.1), in:Capsule())
                        .foregroundStyle(on(item) ? Color.notebookBlue : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
private struct FlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? 400, subviews)
        return CGSize(width:proposal.width ?? rows.map(\.width).max() ?? 0, height:rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items { let size = subviews[index].sizeThatFits(.unspecified); subviews[index].place(at:CGPoint(x:x, y:y), proposal:ProposedViewSize(size)); x += size.width + spacing }
            y += row.height + spacing
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(index); rows[rows.count - 1].width += spacing + size.width; rows[rows.count - 1].height = max(last.height, size.height)
            } else { rows.append(([index], size.width, size.height)) }
        }
        return rows
    }
}

/// "Catch me up": an AI digest of the headlines, labeled as such.
struct NewsDigest: View {
    @ObservedObject var news: NewsModel
    @ObservedObject var agent: AgentModel
    var body: some View {
        if agent.canSummarize, news.stories.count >= 3 {
            if let digest = news.digest {
                VStack(alignment:.leading, spacing:8) {
                    HStack {
                        Label(news.digesting ? "Writing your digest…" : "AI digest of these headlines, by \(agent.modelLabel)", systemImage:"sparkles").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !news.digesting { Button("Hide") { news.hideDigest() }.font(.caption).buttonStyle(.borderless) }
                    }
                    ForEach(Array(digest.split(separator:"\n").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }.enumerated()), id:\.offset) { _, text in styled(text) }
                }
                .padding(14).background(Color.notebookBlue.opacity(0.07), in:RoundedRectangle(cornerRadius:12))
            } else {
                Button { Task { await news.catchMeUp(agent) } } label: { Label(news.digesting ? "Writing your digest…" : "Catch Me Up", systemImage:"sparkles") }
                    .buttonStyle(.bordered).tint(.notebookBlue).disabled(news.digesting)
            }
        }
    }
    /// "Topic: sentence" with the topic in bold.
    private func styled(_ text: String) -> Text {
        if let colon = text.firstIndex(of:":"), text.distance(from:text.startIndex, to:colon) <= 40 {
            return Text(text[..<colon]).bold() + Text(text[colon...])
        }
        return Text(text)
    }
}

/// "Latest", a topic, or Saved.
enum NewsScope: Hashable { case latest, topic(String), saved }

extension NewsModel {
    func stories(in scope: NewsScope, matching query: String) -> [NewsStory] {
        let list: [NewsStory]
        switch scope {
        case .latest: list = latest
        case .topic(let topic): list = stories(topic)
        case .saved: list = saved
        }
        let q = query.trimmingCharacters(in:.whitespaces)
        return q.isEmpty ? list : list.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.byline.localizedCaseInsensitiveContains(q) }
    }
    var updatedLine: String {
        if loading { return "Getting headlines…" }
        guard let fetchedAt else { return "" }
        return "Updated " + fetchedAt.formatted(.relative(presentation:.named))
    }
}

#if os(macOS)
/// The Mac's middle column for News: headlines, by topic or all together.
struct MacNewsList: View {
    @ObservedObject var news: NewsModel
    @ObservedObject var agent: AgentModel
    @Binding var selection: String?
    @State private var scope = NewsScope.latest
    @State private var query = ""
    @State private var topicsShown = false
    var body: some View {
        let items = news.stories(in:scope, matching:query)
        List(selection:$selection) {
            if scope == .latest && !items.isEmpty && query.isEmpty { NewsDigest(news:news, agent:agent).padding(.vertical, 4).selectionDisabled() }
            ForEach(items) { story in NewsRow(story:story, showTopic:scope == .latest, saved:scope != .saved && news.isSaved(story)).tag(story.url) }
        }
        .overlay { placeholder(items) }
        .searchable(text:$query, prompt:"Search headlines")
        .navigationTitle("News")
        .navigationSubtitle(news.updatedLine)
        .navigationSplitViewColumnWidth(min:280, ideal:340)
        .toolbar { toolbar }
        .sheet(isPresented:$topicsShown) { NewsTopics(news:news) }
        .task { news.reload(); await news.refresh() }
        .onChange(of:news.topics) { _, topics in if case .topic(let topic) = scope, !topics.contains(topic) { scope = .latest } }
        .alert("News", isPresented:Binding(get:{ news.error != nil }, set:{ if !$0 { news.error = nil } })) { } message: { Text(news.error ?? "") }
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Show", selection:$scope) {
                Text("Latest").tag(NewsScope.latest)
                ForEach(news.topics, id:\.self) { Text($0).tag(NewsScope.topic($0)) }
                Divider()
                Text("Saved").tag(NewsScope.saved)
            }
            .help("Which headlines to show")
            Button { Task { await news.refresh(force:true) } } label: { Label("Refresh", systemImage:"arrow.clockwise") }.disabled(news.loading).keyboardShortcut("r").help("Get the latest headlines (⌘R)")
            Button { topicsShown = true } label: { Label("Topics", systemImage:"slider.horizontal.3") }.help("Choose topics and sources")
        }
    }
    @ViewBuilder private func placeholder(_ items: [NewsStory]) -> some View {
        if news.topics.isEmpty && scope != .saved {
            ContentUnavailableView { Label("Headlines on your topics", systemImage:"newspaper") } description: { Text("Follow a few topics and News gathers the latest from Google News, Bing News or Hacker News.") } actions: { Button("Choose Topics…") { topicsShown = true } }
        } else if items.isEmpty && (news.loading || !news.loaded) {
            ProgressView("Getting headlines…")
        } else if items.isEmpty && !query.isEmpty {
            ContentUnavailableView.search(text:query)
        } else if items.isEmpty && scope == .saved {
            ContentUnavailableView("Nothing saved", systemImage:"bookmark", description:Text("Save a story to keep it here."))
        } else if items.isEmpty {
            ContentUnavailableView("No recent headlines", systemImage:"newspaper", description:Text("Nothing from the last two days. Try Refresh."))
        }
    }
}
#else
/// News on iPhone: topic chips at the top, headlines below, the reader on tap.
struct NotebookNews: View {
    @ObservedObject var notebook: NotebookModel
    @ObservedObject private var news: NewsModel
    @State private var scope = NewsScope.latest
    @State private var query = ""
    @State private var topicsShown = false
    init(notebook: NotebookModel) { self.notebook = notebook; news = notebook.news }
    var body: some View {
        NavigationStack {
            let items = news.stories(in:scope, matching:query)
            List {
                if !news.topics.isEmpty {
                    ScrollView(.horizontal, showsIndicators:false) {
                        HStack {
                            chip("Latest", .latest)
                            ForEach(news.topics, id:\.self) { chip($0, .topic($0)) }
                            chip("Saved", .saved)
                        }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if news.topics.isEmpty && scope != .saved {
                    ContentUnavailableView { Label("Headlines on your topics", systemImage:"newspaper") } description: { Text("Follow a few topics and News gathers the latest from Google News, Bing News or Hacker News.") } actions: { Button("Choose topics") { topicsShown = true } }
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if items.isEmpty && (news.loading || !news.loaded) {
                    HStack { Spacer(); ProgressView("Getting headlines…"); Spacer() }.padding(.top, 60).listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if items.isEmpty {
                    ContentUnavailableView(scope == .saved ? "Nothing saved" : "No recent headlines", systemImage:"newspaper", description:Text(scope == .saved ? "Save a story to keep it here." : "Pull down to refresh."))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    if scope == .latest && query.isEmpty { NewsDigest(news:news, agent:notebook.agent).listRowSeparator(.hidden) }
                    ForEach(items) { story in
                        NavigationLink { NewsReader(news:news, agent:notebook.agent, story:story).background(Color.notebookPaper) } label: { NewsRow(story:story, showTopic:scope == .latest, saved:scope != .saved && news.isSaved(story)) }
                            .swipeActions { Button(news.isSaved(story) ? "Unsave" : "Save") { news.toggleSaved(story) }.tint(.orange) }
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(Color.notebookPaper)
            .searchable(text:$query, prompt:"Search headlines")
            .refreshable { await news.refresh(force:true) }
            .navigationTitle("News")
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) { Button { topicsShown = true } label: { Image(systemName:"slider.horizontal.3") }.accessibilityLabel("Topics and sources") }
                ToolbarItem(placement:.bottomBar) { Text(news.updatedLine).font(.caption2).foregroundStyle(.secondary) }
            }
            .sheet(isPresented:$topicsShown) { NewsTopics(news:news) }
            .task { news.reload(); await news.refresh() }
            .alert("News", isPresented:Binding(get:{ news.error != nil }, set:{ if !$0 { news.error = nil } })) { Button("OK") { news.error = nil } } message: { Text(news.error ?? "") }
        }
    }
    private func chip(_ title: String, _ value: NewsScope) -> some View {
        Button(title) { scope = value }
            .font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
            .background(scope == value ? Color.notebookBlue : Color.secondary.opacity(0.12), in:Capsule())
            .foregroundStyle(scope == value ? Color.white : Color.primary)
            .buttonStyle(.plain)
    }
}
#endif
