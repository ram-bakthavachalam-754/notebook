import Foundation
import NotebookCore

/// One headline, quoted from its source. Notebook never writes headlines.
struct NewsStory: Identifiable, Hashable, Codable {
    var title: String
    var url: String
    /// The publisher ("Reuters"); `via` is where the headline came from.
    var source: String
    var via: String
    var topic: String
    var publishedAt: Date?
    /// The source's own one-line description, when it gives one (Bing does).
    var blurb: String = ""
    var discussionURL: String = ""
    var points: Int = 0
    var id: String { url }
    var host: String { URL(string:url)?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "" }
    var byline: String { source.isEmpty ? host : source }
}
extension NewsStory {
    /// A headline Trading saved ("title", "url", "source", "date"), as a story for the reader.
    init(headline: [String:String], topic: String) {
        self.init(title:headline["title"] ?? "", url:headline["url"] ?? "", source:headline["source"] ?? "", via:"google", topic:topic,
                  publishedAt:(headline["date"]).flatMap { ISO8601DateFormatter().date(from:$0) }, blurb:headline["blurb"] ?? "")
    }
}

/// News: headlines on the topics you follow, from Google News, Bing News and
/// Hacker News. Headlines are fetched when News is open (at most every 30
/// minutes) and kept on this device; your topics and saved stories sync.
@MainActor final class NewsModel: ObservableObject {
    @Published private(set) var topics: [String] = []
    @Published private(set) var sources: [String] = NewsModel.defaultSources
    @Published private(set) var stories: [NewsStory] = []
    @Published private(set) var saved: [NewsStory] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published var error: String?
    private weak var notebook: NotebookModel?
    private let store: RecordStore
    private var cacheURL: URL { store.url.deletingLastPathComponent().appendingPathComponent("news-cache.json") }

    static let sourceNames = ["google":"Google News", "bing":"Bing News", "hn":"Hacker News"]
    static let sourceDetails = ["google":"Thousands of publishers, searched by topic. Articles open in your browser more often than here.",
                                "bing":"A second news index. Its links go straight to the publisher, so more articles can be read here.",
                                "hn":"Stories from the last two days, ranked by readers. Best for technology and science."]
    static let defaultSources = ["google", "bing"]
    static let catalog: [(group: String, topics: [String])] = [
        ("World", ["World news", "US politics", "Europe", "UK", "India", "China", "Japan", "Middle East", "Africa", "Latin America", "Canada", "Australia"]),
        ("Tech & Science", ["Technology", "AI", "Science", "Space", "Climate", "Cybersecurity", "Gadgets"]),
        ("Business", ["Business", "Stock markets", "Startups", "Real estate", "Crypto", "Economy"]),
        ("Sports", ["Football", "Basketball", "Baseball", "Tennis", "Formula 1", "Soccer", "Golf", "Cricket", "Hockey", "Olympics"]),
        ("Culture & Life", ["Movies", "Television", "Music", "Books", "Gaming", "Food", "Travel", "Fashion", "Health", "Fitness"])
    ]
    static let maxTopics = 15, perTopic = 20
    static let maxAge: TimeInterval = 48 * 3600, ttl: TimeInterval = 30 * 60

    init(notebook: NotebookModel) {
        self.notebook = notebook; store = notebook.store
        loadCache()
        reload()
    }
    /// Topics, sources and saved stories, from the notebook (they sync).
    func reload() {
        guard notebook?.unlocked == true else { saved = []; return }
        let rows = (try? store.records("news")) ?? []
        var newest: [String:[String:Any]] = [:]
        for row in rows {
            let entity = row["_syncEntity"] as? String ?? ""
            if let kept = newest[entity], (kept["modifiedAt"] as? String ?? "") >= (row["modifiedAt"] as? String ?? "") { continue }
            newest[entity] = row
        }
        if let settings = newest["settings"] {
            topics = settings["topics"] as? [String] ?? []
            let picked = (settings["sources"] as? [String] ?? []).filter { Self.sourceNames[$0] != nil }
            sources = picked.isEmpty ? Self.defaultSources : picked
        }
        saved = newest.values.filter { $0["type"] as? String == "saved" }.compactMap(Self.story).sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    // MARK: Topics and sources
    private func saveSettings() {
        guard notebook?.unlocked == true else { return }
        var record: [String:Any] = (try? store.records("news", entity:"settings").first) ?? ["id":"settings"]
        record["type"] = "settings"; record["topics"] = topics; record["sources"] = sources
        record["modifiedAt"] = ISO8601DateFormatter().string(from:Date())
        do { try store.save(kind:"news", record:record, resolve:true); Task { await notebook?.sync() } } catch { self.error = error.localizedDescription }
    }
    func follow(_ topic: String) {
        let name = String(topic.trimmingCharacters(in:.whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, !topics.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        guard topics.count < Self.maxTopics else { error = "You can follow up to \(Self.maxTopics) topics."; return }
        topics.append(name); saveSettings()
        Task { await refresh(force:true) }
    }
    func unfollow(_ topic: String) {
        topics.removeAll { $0 == topic }; stories.removeAll { $0.topic == topic }; saveSettings()
    }
    func following(_ topic: String) -> Bool { topics.contains { $0.caseInsensitiveCompare(topic) == .orderedSame } }
    func toggleSource(_ id: String) {
        if sources.contains(id) { guard sources.count > 1 else { return }; sources.removeAll { $0 == id } } else { sources.append(id) }
        sources = Self.sourceNames.keys.sorted { ["google", "bing", "hn"].firstIndex(of:$0)! < ["google", "bing", "hn"].firstIndex(of:$1)! }.filter(sources.contains)
        saveSettings(); Task { await refresh(force:true) }
    }

    // MARK: Saved stories
    func isSaved(_ story: NewsStory) -> Bool { saved.contains { $0.url == story.url } }
    func toggleSaved(_ story: NewsStory) {
        guard notebook?.unlocked == true else { return }
        let entity = "saved:" + Self.key(story.url)
        do {
            if let row = try store.records("news", entity:entity).first {
                var row = row; row["_syncHeads"] = row["_syncAllHeads"]; try store.delete(kind:"news", record:row)
            } else {
                var record = Self.record(story); record["id"] = entity; record["type"] = "saved"; record["savedAt"] = ISO8601DateFormatter().string(from:Date())
                try store.save(kind:"news", record:record)
            }
            reload(); Task { await notebook?.sync() }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Headlines
    var stale: Bool { fetchedAt.map { Date().timeIntervalSince($0) > Self.ttl } ?? true }
    /// Called when News opens. Within 30 minutes of the last fetch it shows what it has.
    func refresh(force: Bool = false) async {
        guard notebook?.unlocked == true, !loading, !topics.isEmpty else { loaded = true; return }
        let missing = topics.contains { topic in !stories.contains { $0.topic == topic } }
        guard force || stale || missing else { loaded = true; return }
        loading = true; defer { loading = false; loaded = true }
        let topics = topics, sources = sources
        let fetched = await withTaskGroup(of:(Bool, [NewsStory]).self) { group in
            for topic in topics { for source in sources { group.addTask { await Self.fetch(topic:topic, source:source) } } }
            var all: [NewsStory] = [], failures = 0, total = 0
            for await (ok, items) in group { total += 1; if !ok { failures += 1 }; all += items }
            return (all, failures == total)
        }
        if fetched.1 { error = "Couldn't get headlines. Check your internet connection and try again."; return }
        stories = Self.merge(fetched.0, topics:topics)
        fetchedAt = Date(); digest = nil
        saveCache()
    }
    /// One list per topic, newest first, the same story once. Old or undated stories are left out.
    static func merge(_ items: [NewsStory], topics: [String]) -> [NewsStory] {
        let now = Date()
        var seen = Set<String>(), out: [NewsStory] = []
        for story in items.sorted(by: { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }) {
            guard let date = story.publishedAt, now.timeIntervalSince(date) < maxAge else { continue }
            let key = story.topic.lowercased() + "|" + normalized(story.title)
            guard seen.insert(key).inserted, seen.insert(story.topic.lowercased() + "|" + story.url).inserted else { continue }
            out.append(story)
        }
        var counts: [String:Int] = [:]
        return out.filter { story in counts[story.topic, default:0] += 1; return counts[story.topic]! <= perTopic }
    }
    static func normalized(_ title: String) -> String { String(title.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).prefix(80)) }
    /// Latest across every topic, each story once.
    var latest: [NewsStory] {
        var seen = Set<String>()
        return stories.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }.filter { seen.insert(Self.normalized($0.title)).inserted }
    }
    func stories(_ topic: String) -> [NewsStory] { stories.filter { $0.topic == topic } }

    nonisolated static func fetch(topic: String, source: String) async -> (Bool, [NewsStory]) {
        var components: URLComponents
        switch source {
        case "google":
            components = URLComponents(string:"https://news.google.com/rss/search")!
            components.queryItems = [.init(name:"q", value:topic), .init(name:"hl", value:"en-US"), .init(name:"gl", value:"US"), .init(name:"ceid", value:"US:en")]
        case "bing":
            components = URLComponents(string:"https://www.bing.com/news/search")!
            components.queryItems = [.init(name:"q", value:topic), .init(name:"format", value:"rss"), .init(name:"mkt", value:"en-US")]
        default:
            components = URLComponents(string:"https://hn.algolia.com/api/v1/search")!
            components.queryItems = [.init(name:"query", value:topic), .init(name:"tags", value:"story"), .init(name:"hitsPerPage", value:String(perTopic)),
                                     .init(name:"numericFilters", value:"created_at_i>\(Int(Date().timeIntervalSince1970 - maxAge)),points>=10")]
        }
        guard let url = components.url else { return (false, []) }
        var request = URLRequest(url:url); request.timeoutInterval = 15
        // Only the topic travels; no cookies, a plain user agent.
        request.setValue("Mozilla/5.0 (Notebook news reader)", forHTTPHeaderField:"User-Agent")
        let session = URLSession(configuration:.ephemeral)
        guard let (data, response) = try? await session.data(for:request), (response as? HTTPURLResponse)?.statusCode == 200 else { return (false, []) }
        let items = source == "hn" ? hn(data, topic:topic) : NewsRSS.parse(data).map { item in
            // Google's description only repeats the headline; Bing's is a real summary line.
            var story = NewsStory(title:item.title, url:item.link, source:item.source, via:source, topic:topic, publishedAt:item.date, blurb:source == "bing" ? item.description : "")
            // Bing wraps each link in a click tracker; the publisher's address is inside it.
            if source == "bing", let wrapped = URLComponents(string:item.link), wrapped.host?.hasSuffix("bing.com") == true,
               let target = wrapped.queryItems?.first(where: { $0.name == "url" })?.value, target.hasPrefix("http") { story.url = target }
            // Google adds " - Publisher" to every title.
            if !story.source.isEmpty, story.title.lowercased().hasSuffix(" - " + story.source.lowercased()) { story.title = String(story.title.dropLast(story.source.count + 3)) }
            if story.source.isEmpty { story.source = story.host }
            return story
        }
        return (true, Array(items.filter { $0.url.hasPrefix("http") && !$0.title.isEmpty }.prefix(perTopic)))
    }
    nonisolated private static func hn(_ data: Data, topic: String) -> [NewsStory] {
        guard let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let hits = root["hits"] as? [[String:Any]] else { return [] }
        return hits.compactMap { hit in
            guard let id = hit["objectID"] as? String, let title = hit["title"] as? String, !title.isEmpty else { return nil }
            let thread = "https://news.ycombinator.com/item?id=" + id
            let link = (hit["url"] as? String).flatMap { $0.hasPrefix("http") ? $0 : nil } ?? thread
            let created = (hit["created_at_i"] as? NSNumber).map { Date(timeIntervalSince1970:$0.doubleValue) }
            var story = NewsStory(title:title, url:link, source:"", via:"hn", topic:topic, publishedAt:created, discussionURL:thread, points:(hit["points"] as? NSNumber)?.intValue ?? 0)
            story.source = story.host.isEmpty ? "Hacker News" : story.host
            return story
        }
    }

    // MARK: Reading and summaries
    /// Google News feed links are a page of Google's scripts, not a redirect.
    /// Ask Google for the publisher's address the way that page does; on any
    /// failure the link is returned as it was.
    nonisolated static func resolve(_ url: String) async -> String {
        guard let link = URL(string:url), link.host() == "news.google.com", link.path().contains("/articles/") else { return url }
        let id = link.path().components(separatedBy:"/articles/").last?.components(separatedBy:"/").first ?? ""
        guard !id.isEmpty else { return url }
        if let cached = await ResolvedLinks.shared.get(id) { return cached }
        let session = URLSession(configuration:.ephemeral), agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        var page = URLRequest(url:link); page.timeoutInterval = 12; page.setValue(agent, forHTTPHeaderField:"User-Agent")
        guard let (data, _) = try? await session.data(for:page) else { return url }
        let html = String(decoding:data, as:UTF8.self)
        func attribute(_ name: String) -> String? {
            guard let start = html.range(of:name + "=\""), let end = html[start.upperBound...].firstIndex(of:"\"") else { return nil }
            return String(html[start.upperBound..<end])
        }
        guard let signature = attribute("data-n-a-sg"), let stamp = attribute("data-n-a-ts").flatMap(Int.init) else { return url }
        let inner: [Any] = ["garturlreq", [["X", "X", ["X", "X"], NSNull(), NSNull(), 1, 1, "US:en", NSNull(), 1, NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), 0, 1], "X", "X", 1, [1, 1, 1], 1, 1, NSNull(), 0, 0, NSNull(), 0], id, stamp, signature]
        guard let innerJSON = try? jsonString(inner), let outer = try? jsonString([[["Fbv4je", innerJSON, NSNull(), "generic"]]]) else { return url }
        var request = URLRequest(url:URL(string:"https://news.google.com/_/DotsSplashUi/data/batchexecute")!); request.httpMethod = "POST"; request.timeoutInterval = 12
        request.setValue(agent, forHTTPHeaderField:"User-Agent")
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField:"Content-Type")
        var form = URLComponents(); form.queryItems = [URLQueryItem(name:"f.req", value:outer)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of:"+", with:"%2B").utf8)
        guard let (reply, response) = try? await session.data(for:request), (response as? HTTPURLResponse)?.statusCode == 200 else { return url }
        // The answer is JSON inside JSON; the address is the first non-Google URL in it.
        let body = String(decoding:reply.prefix(65536), as:UTF8.self)
        guard let regex = try? NSRegularExpression(pattern:#"https?://(?!news\.google\.com)[^\s"\\]+"#),
              let match = regex.firstMatch(in:body, range:NSRange(body.startIndex..., in:body)), let range = Range(match.range, in:body) else { return url }
        let resolved = String(body[range])
        await ResolvedLinks.shared.set(id, resolved)
        return resolved
    }
    /// Other outlets' coverage of a headline, from Bing News: their titles and
    /// one-line descriptions. Used when the article itself can't be read.
    nonisolated static func coverage(_ story: NewsStory) async -> [NewsStory] {
        let (_, items) = await fetch(topic:story.title, source:"bing")
        return items.filter { !$0.blurb.isEmpty && $0.url != story.url }.prefix(6).map { $0 }
    }
    static let summarySystem = "You are a news journalist writing for a reader who has not followed this story. You write only from the source material you are given. You never invent facts, numbers, names, dates, or quotes that are not in that material."
    static func summaryPrompt(title: String, material: String) -> String {
        """
        Headline: \(title)

        \(material)

        Give me a detailed summary of this news with full background, details and insights, in simple language, written like a human journalist, grounded on the information from the source material above. No exaggerations. No filler words. Just facts.

        How to write it:
        - Open with what happened and why it matters, in plain language.
        - Then the background a newcomer needs to follow the story.
        - Then the specifics: the numbers, names, dates and quotes that are actually in the material.
        - Close with what it means or what happens next, but ONLY where the material supports it. If it does not, leave it out rather than speculating.
        - Finish with a line containing just **Key points**, then up to five bullets carrying the hard facts.

        Rules: plain markdown, no preamble, do not repeat the headline as a title, do not pad. Use ONLY the material above; if something is not in it, do not write it. Do not write a source, link, or date line at the end - the app adds that itself.

        If the material is not actually article content (a cookie or consent notice, a redirect stub, a paywall or sign-in wall, an error page, unrelated boilerplate), reply with exactly: UNUSABLE
        """
    }

    // MARK: Catch me up
    /// An AI digest of the headlines on screen, topic by topic. Written when
    /// you ask, labeled as AI-written, and dropped when headlines refresh.
    @Published private(set) var digest: String?
    @Published private(set) var digesting = false
    func catchMeUp(_ agent: AgentModel) async {
        guard !digesting, agent.canSummarize else { return }
        let rows = topics.flatMap { topic in stories(topic).prefix(8) }
        guard rows.count >= 3 else { error = "There aren't enough headlines for a digest yet."; return }
        digesting = true; defer { digesting = false }
        let blocks = topics.compactMap { topic -> String? in
            let titles = stories(topic).prefix(8).map { "- " + $0.title }
            return titles.isEmpty ? nil : topic.uppercased() + ":\n" + titles.joined(separator:"\n")
        }.joined(separator:"\n\n")
        let prompt = """
        Current headlines, grouped by the user's chosen topics:

        \(blocks)

        Catch the user up, topic by topic. For each topic with something notable, write exactly one line: the topic name, a colon, then one or two short sentences summarizing that topic's headlines. Keep every sentence inside its topic — never combine different topics in one sentence, and skip a topic entirely rather than stretching to include it. Every statement must come strictly from a headline above. Plain text: one line per topic, no bullet points, no markdown, no preamble.
        """
        do {
            let text = try await agent.write(system:"You write a brief digest of news headlines. Use ONLY the headlines provided; never add facts they do not contain.", prompt:prompt, maxTokens:3000) { [weak self] partial in self?.digest = partial }
            digest = text.isEmpty ? nil : text
            if text.isEmpty { error = "Your model didn't write a digest. Try again." }
        } catch { digest = nil; self.error = "Couldn't write a digest: \(error.localizedDescription)" }
    }
    func hideDigest() { digest = nil }

    // MARK: This device's headline cache
    private struct Cache: Codable { var fetchedAt: Date; var stories: [NewsStory] }
    private func loadCache() {
        guard let data = try? Data(contentsOf:cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from:data) else { return }
        stories = cache.stories; fetchedAt = cache.fetchedAt
    }
    private func saveCache() {
        guard let fetchedAt, let data = try? JSONEncoder().encode(Cache(fetchedAt:fetchedAt, stories:stories)) else { return }
        try? data.write(to:cacheURL, options:[.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func locked() { stories = []; saved = [] ; loaded = false }

    static func key(_ url: String) -> String { String(url.unicodeScalars.reduce(into:UInt64(1469598103934665603)) { $0 = ($0 ^ UInt64($1.value)) &* 1099511628211 }, radix:36) }
    static func record(_ story: NewsStory) -> [String:Any] {
        var record: [String:Any] = ["title":story.title, "url":story.url, "source":story.source, "via":story.via, "topic":story.topic, "blurb":story.blurb, "discussionURL":story.discussionURL, "points":story.points]
        if let date = story.publishedAt { record["publishedAt"] = ISO8601DateFormatter().string(from:date) }
        return record
    }
    static func story(_ row: [String:Any]) -> NewsStory? {
        guard let title = row["title"] as? String, let url = row["url"] as? String else { return nil }
        return NewsStory(title:title, url:url, source:row["source"] as? String ?? "", via:row["via"] as? String ?? "", topic:row["topic"] as? String ?? "",
                         publishedAt:(row["publishedAt"] as? String).flatMap(ISO8601DateFormatter().date), blurb:row["blurb"] as? String ?? "",
                         discussionURL:row["discussionURL"] as? String ?? "", points:(row["points"] as? NSNumber)?.intValue ?? 0)
    }
}

/// Google News links already turned into publisher addresses.
actor ResolvedLinks {
    static let shared = ResolvedLinks()
    private var links: [String:String] = [:]
    func get(_ id: String) -> String? { links[id] }
    func set(_ id: String, _ url: String) { if links.count > 500 { links.removeAll() }; links[id] = url }
}

/// A small RSS reader for Google News and Bing News feeds.
final class NewsRSS: NSObject, XMLParserDelegate {
    struct Item { var title = "", link = "", source = "", description = "", date: Date? }
    private var items: [Item] = []
    private var current: Item?
    private var text = ""
    static func parse(_ data: Data) -> [Item] {
        let reader = NewsRSS(), parser = XMLParser(data:data)
        parser.delegate = reader; parser.parse()
        return reader.items
    }
    private static let dates: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z"].map { format in
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = format; return formatter
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String] = [:]) {
        if name == "item" { current = Item() }
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(decoding:data, as:UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines)
        switch name {
        case "item": if let current { items.append(current) }; current = nil
        case "title": current?.title = String(value.prefix(300))
        case "link": current?.link = String(value.prefix(2000))
        case "source", "News:Source": current?.source = String(value.prefix(100))
        case "description": current?.description = String(NotebookItem.plainText(value).prefix(300))
        case "pubDate": current?.date = Self.dates.lazy.compactMap { $0.date(from:value) }.first
        default: break
        }
        text = ""
    }
}
