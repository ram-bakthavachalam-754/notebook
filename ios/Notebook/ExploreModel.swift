import Foundation
import NotebookCore

/// A list Explore follows: an index, where its members come from, and an ETF
/// that tracks it.
struct ExploreListInfo: Identifiable, Hashable {
    let id: String, name: String, short: String
    /// "Market" (broad indexes) or "Tech".
    let group: String
    let etf: String
    /// The index's full name, for the tech lists.
    var index = ""
    var source = ""
    var isMarket: Bool { group == "Market" }
}

/// One company in Explore. Its sub-industry comes from S&P for S&P 500
/// members; anything else is placed by your AI model, or by you.
struct ExploreStock: Identifiable {
    let symbol: String
    var name: String
    /// The eight-digit sub-industry, or "" while unplaced.
    var code = ""
    /// Who placed it: "sp" (S&P's own), "ai", "you", or "" (no one yet).
    var placedBy = ""
    var lists: [String] = []
    var id: String { symbol }
}

/// A sector, industry or sub-industry in one list, and the stocks under it.
struct ExploreGroup: Identifiable {
    /// "s:45", "i:453010" or "u:45301020"; an empty code is Unclassified.
    let id: String
    let code: String
    var children: [ExploreGroup] = []
    var symbols: [String] = []
    var name: String { GICS.name(code) }
    var level: Character { id.first ?? "s" }
}

/// Explore: every company in the S&P 500, the Nasdaq-100 and a few tech
/// indexes, grouped by sector, industry and sub-industry, with live prices.
/// The lists are checked weekly and kept in a cache file; where you or your
/// model place a company is an "explore" record, so it syncs.
@MainActor final class ExploreModel: ObservableObject {
    static let lists: [ExploreListInfo] = [
        ExploreListInfo(id:"SP", name:"S&P 500", short:"S&P", group:"Market", etf:"SPY", source:"Wikipedia's S&P 500 list"),
        ExploreListInfo(id:"NDX", name:"Nasdaq-100", short:"NDX", group:"Market", etf:"QQQ", source:"Nasdaq's Nasdaq-100 list"),
        ExploreListInfo(id:"SOX", name:"Semiconductors", short:"SOX", group:"Tech", etf:"SOXX", index:"PHLX Semiconductor", source:"Nasdaq's index data"),
        ExploreListInfo(id:"NQCYBR", name:"Cybersecurity", short:"CIBR", group:"Tech", etf:"CIBR", index:"Nasdaq CTA Cybersecurity", source:"Nasdaq's index data"),
        ExploreListInfo(id:"HACK", name:"Cyber Security (ISE)", short:"HACK", group:"Tech", etf:"HACK", index:"ISE Cyber Security", source:"Amplify's daily holdings"),
        ExploreListInfo(id:"EMCLOUD", name:"Cloud Software", short:"Cloud", group:"Tech", etf:"WCLD", index:"BVP Nasdaq Emerging Cloud", source:"Nasdaq's index data"),
        ExploreListInfo(id:"FANG", name:"FANG+", short:"FANG+", group:"Tech", etf:"FNGS", index:"NYSE FANG+", source:"the FANG+ ETN's holdings"),
    ]
    static func info(_ id: String) -> ExploreListInfo { lists.first { $0.id == id } ?? lists[0] }
    /// A company's other share class counts once, under its main ticker, so
    /// Alphabet isn't twice its size on the map.
    static let folded = ["GOOG":"GOOGL", "FOX":"FOXA", "NWS":"NWSA"]
    static let listsMaxAge: TimeInterval = 7 * 86400

    @Published private(set) var stocks: [String:ExploreStock] = [:]
    /// Each list's members, in its source's order.
    @Published private(set) var members: [String:[String]] = [:]
    @Published private(set) var quotes: [String:YahooFinance.Quote] = [:]
    /// The close each period is measured from, per stock (see ExplorePeriods).
    @Published private(set) var references: [String:[String:Double]] = [:]
    @Published private(set) var changesLog: [MembershipChange] = []
    @Published private(set) var listsCheckedAt: Date?
    @Published private(set) var quotesAt: Date?
    @Published private(set) var busy = ""
    @Published var error: String?
    /// What the pages show: the list, the period, tile sizes and the top-5 filter.
    @Published var list = UserDefaults.standard.string(forKey:"explore-list") ?? "SP" {
        didSet { UserDefaults.standard.set(list, forKey:"explore-list"); size = Self.info(list).isMarket ? "cap" : "equal" }
    }
    @Published var period = "1D"
    /// "cap" or "equal". Tech lists hold a few giants (Microsoft is in
    /// Cybersecurity), so they start at equal sizes.
    @Published var size = ExploreModel.info(UserDefaults.standard.string(forKey:"explore-list") ?? "SP").isMarket ? "cap" : "equal"
    @Published var topOnly = false

    struct MembershipChange: Codable, Identifiable, Hashable {
        var list: String, date: Date, added: [String], removed: [String]
        var id: String { list + date.description }
    }
    private struct Cache: Codable {
        var members: [String:[String]] = [:]
        var names: [String:String] = [:]
        var spCodes: [String:String] = [:]
        var listsCheckedAt: Date?
        var changes: [MembershipChange] = []
        var references: [String:[String:Double]] = [:]
        var historyDay: String?
        /// The last prices seen, so the map draws right away at launch.
        var snapshot: [String:[Double]] = [:]
    }
    private var cache = Cache()
    private weak var notebook: NotebookModel?
    private let store: RecordStore
    private var placements: [String:[String:Any]] = [:]
    private var classifyTried = false
    private var cacheURL: URL { store.url.deletingLastPathComponent().appendingPathComponent("explore-cache.json") }

    init(notebook: NotebookModel) {
        self.notebook = notebook; store = notebook.store
        if let data = try? Data(contentsOf:cacheURL), let saved = try? JSONDecoder().decode(Cache.self, from:data) { cache = saved }
        for (symbol, s) in cache.snapshot where s.count == 4 {
            quotes[symbol] = YahooFinance.Quote(price:s[0], changePercent:s[1], bid:0, ask:0, name:cache.names[symbol] ?? symbol, marketState:"", earnings:nil, marketCap:s[2], volume:s[3])
        }
        reload()
    }

    // MARK: Records
    /// Rebuilds the stocks from the cached lists and your placements.
    func reload() {
        guard notebook?.unlocked == true else { placements = [:]; stocks = [:]; return }
        placements = Dictionary(((try? store.records("explore")) ?? []).filter { $0["_syncConflict"] as? Bool != true }.compactMap { r in (r["id"] as? String).map { ($0, r) } }, uniquingKeysWith:{ a, _ in a })
        var out: [String:ExploreStock] = [:]
        for info in Self.lists {
            for symbol in cache.members[info.id] ?? [] {
                var stock = out[symbol] ?? ExploreStock(symbol:symbol, name:cache.names[symbol] ?? symbol)
                stock.lists.append(info.id)
                out[symbol] = stock
            }
        }
        for (symbol, var stock) in out {
            let placed = placements[symbol], placedCode = placed?["code"] as? String ?? "", by = placed?["by"] as? String ?? ""
            if by == "you", GICS.names[placedCode] != nil { stock.code = placedCode; stock.placedBy = "you" }
            else if let code = cache.spCodes[symbol] { stock.code = code; stock.placedBy = "sp" }
            else if GICS.names[placedCode] != nil { stock.code = placedCode; stock.placedBy = by.isEmpty ? "ai" : by }
            out[symbol] = stock
        }
        stocks = out; members = cache.members; references = cache.references; changesLog = cache.changes; listsCheckedAt = cache.listsCheckedAt
    }
    /// Moves a company to another sub-industry; your choice wins over S&P's and your model's.
    func place(_ symbol: String, in code: String) {
        save(symbol, code:code, by:"you")
        reload(); Task { await notebook?.sync() }
    }
    private func save(_ symbol: String, code: String, by: String, model: String? = nil) {
        var record: [String:Any] = ["id":symbol, "ticker":symbol, "code":code, "by":by, "modifiedAt":ISO8601DateFormatter().string(from:Date())]
        if let model { record["model"] = model }
        do { try store.save(kind:"explore", record:record, resolve:true) } catch { self.error = error.localizedDescription }
    }

    // MARK: Reading
    var unplaced: [String] { stocks.values.filter { $0.code.isEmpty }.map(\.symbol).sorted() }
    func symbols(in list: String) -> [String] { stocks.values.filter { $0.lists.contains(list) }.map(\.symbol) }
    func cap(_ symbol: String) -> Double { quotes[symbol]?.marketCap ?? 0 }
    func price(_ symbol: String) -> Double? { quotes[symbol]?.price }
    /// A stock's change over a period, in percent.
    func change(_ symbol: String, _ period: String) -> Double? {
        guard let quote = quotes[symbol] else { return nil }
        if period == "1D" { return quote.changePercent }
        return ExplorePeriods.change(from:references[symbol]?[period], to:quote.price)
    }
    /// A group's market-cap-weighted change.
    func change(of symbols: [String], _ period: String) -> Double? {
        ExplorePeriods.weighted(symbols.map { (change:change($0, period), cap:cap($0)) })
    }
    /// The chosen list as sectors → industries → sub-industries → stocks. With
    /// "top only", each sub-industry keeps its five largest companies.
    func tree() -> [ExploreGroup] {
        var bySub: [String:[String]] = [:]
        for symbol in symbols(in:list) { bySub[stocks[symbol]?.code ?? "", default:[]].append(symbol) }
        if topOnly { bySub = bySub.mapValues { Array($0.sorted { cap($0) > cap($1) }.prefix(5)) } }
        var sectors: [String:ExploreGroup] = [:]
        for (code, symbols) in bySub {
            let sector = GICS.sector(code), industry = GICS.industry(code)
            var s = sectors[sector] ?? ExploreGroup(id:"s:" + sector, code:sector)
            if let i = s.children.firstIndex(where: { $0.code == industry }) { s.children[i].children.append(ExploreGroup(id:"u:" + code, code:code, symbols:symbols)) }
            else { s.children.append(ExploreGroup(id:"i:" + industry, code:industry, children:[ExploreGroup(id:"u:" + code, code:code, symbols:symbols)])) }
            sectors[sector] = s
        }
        return sectors.values.map { sector in
            var sector = sector
            sector.children = sector.children.map { industry in
                var industry = industry
                industry.children.sort { $0.code < $1.code }
                industry.symbols = industry.children.flatMap(\.symbols)
                return industry
            }.sorted { $0.code < $1.code }
            sector.symbols = sector.children.flatMap(\.symbols)
            return sector
        }
        // Unclassified sorts last.
        .sorted { ($0.code.isEmpty ? "99" : $0.code) < ($1.code.isEmpty ? "99" : $1.code) }
    }
    func group(_ id: String, in tree: [ExploreGroup]) -> ExploreGroup? {
        for sector in tree {
            if sector.id == id { return sector }
            for industry in sector.children {
                if industry.id == id { return industry }
                if let sub = industry.children.first(where: { $0.id == id }) { return sub }
            }
        }
        return nil
    }

    // MARK: Updating
    /// When Explore opens: lists if they're a week old, placements for new
    /// companies, the day's history, then prices.
    func start() async {
        guard notebook?.unlocked == true, busy.isEmpty else { return }
        if cache.members.isEmpty || Date().timeIntervalSince(cache.listsCheckedAt ?? .distantPast) > Self.listsMaxAge { await refreshLists() }
        await refreshQuotes()
        if cache.historyDay != TradingModel.day.string(from:Date()) { await refreshHistory() }
        if !classifyTried { classifyTried = true; await classify() }
    }
    /// Everything now, from the Refresh button.
    func refreshAll() async {
        guard busy.isEmpty else { return }
        await refreshLists(); await refreshQuotes(); await refreshHistory(); classifyTried = true; await classify()
    }
    /// Prices for every company, through Trading's quotes: Robinhood's live
    /// prices when it's connected, Yahoo's otherwise, and Yahoo's market caps.
    func refreshQuotes() async {
        guard let trading = notebook?.trading, !stocks.isEmpty else { return }
        let symbols = Array(stocks.keys)
        await trading.refreshQuotes(symbols)
        for symbol in symbols {
            guard var quote = trading.quotes[symbol] else { continue }
            // Robinhood's quotes have no market cap or volume; keep the last ones.
            if quote.marketCap == 0, let old = quotes[symbol] { quote.marketCap = old.marketCap; quote.volume = max(quote.volume, old.volume) }
            quotes[symbol] = quote
        }
        quotesAt = Date()
        cache.snapshot = quotes.filter { stocks[$0.key] != nil }.mapValues { [$0.price, $0.changePercent, $0.marketCap, $0.volume] }
        saveCache()
    }
    /// A year of daily closes for every company, once a day, for 1W–1Y.
    func refreshHistory() async {
        let symbols = Array(stocks.keys).sorted()
        guard !symbols.isEmpty else { return }
        busy = "Loading a year of prices…"
        defer { busy = "" }
        var refs = cache.references
        for chunk in stride(from:0, to:symbols.count, by:100).map({ Array(symbols[$0..<min($0 + 100, symbols.count)]) }) {
            for (symbol, closes) in await YahooFinance.closes(chunk) {
                let found = ExplorePeriods.references(closes:closes, calendar:Self.newYorkCalendar)
                if !found.isEmpty { refs[symbol] = found }
            }
        }
        cache.references = refs; cache.historyDay = TradingModel.day.string(from:Date()); references = refs
        saveCache()
    }
    private static let newYorkCalendar: Calendar = { var c = Calendar(identifier:.gregorian); c.timeZone = TradingModel.newYork; return c }()

    // MARK: Lists
    /// Every list from its source. A list that can't be read keeps its last members.
    func refreshLists() async {
        busy = "Checking the lists…"
        defer { busy = "" }
        async let sp = Self.text("https://en.wikipedia.org/w/api.php?action=parse&page=List_of_S%26P_500_companies&prop=wikitext&format=json&formatversion=2")
        async let ndx = Self.data("https://api.nasdaq.com/api/quote/list-type/nasdaq100")
        async let sox = Self.nasdaqIndex("SOX")
        async let cyber = Self.nasdaqIndex("NQCYBR")
        async let cloud = Self.nasdaqIndex("EMCLOUD")
        async let amplify = Self.text("https://amplifyetfs.com/wp-content/uploads/feeds/AmplifyWeb.40XL.XL_Holdings.csv")
        async let fang = Self.text("https://stockanalysis.com/etf/fngs/holdings/")
        var found: [String:[ExploreMember]] = [:]
        if let page = await sp, let root = try? JSONSerialization.jsonObject(with:Data(page.utf8)) as? [String:Any],
           let wikitext = (root["parse"] as? [String:Any])?["wikitext"] as? String {
            found["SP"] = ExploreSources.sp500(wikitext:wikitext)
        }
        if let data = await ndx { found["NDX"] = ExploreSources.nasdaq100(json:data) }
        found["SOX"] = await sox; found["NQCYBR"] = await cyber; found["EMCLOUD"] = await cloud
        if let csv = await amplify { found["HACK"] = ExploreSources.amplify(csv:csv, fund:"HACK") }
        if let html = await fang { found["FANG"] = ExploreSources.stockAnalysis(html:html) }
        // A list this short is a broken page, not a real change.
        let minimum = ["SP":450, "NDX":90, "FANG":8]
        found = found.filter { $0.value.count >= minimum[$0.key, default:5] }
        guard !found.isEmpty else { error = "Couldn't reach the lists' sources. Explore keeps the lists it has."; return }

        var names = cache.names, spCodes = cache.spCodes
        for member in found["SP"] ?? [] { names[member.symbol] = member.name; spCodes[member.symbol] = member.code }
        if let sp = found["SP"] { spCodes = spCodes.filter { code in sp.contains { $0.symbol == code.key } } }
        for member in found["NDX"] ?? [] where names[member.symbol] == nil || spCodes[member.symbol] == nil { names[member.symbol] = member.name }
        // Index members outside the S&P 500 and Nasdaq-100 are checked against
        // US quotes: one with no US quote is listed only abroad, and one whose
        // name doesn't match is a different company with the same ticker
        // (Atos's ATO is Atmos Energy's in the US).
        let known = Set((found["SP"] ?? []).map(\.symbol) + (found["NDX"] ?? []).map(\.symbol))
        let checked = Set(["SOX", "NQCYBR", "EMCLOUD", "HACK"])
        let unknown = Set(found.filter { checked.contains($0.key) || $0.key == "FANG" }.flatMap { $0.value.map(\.symbol) }).subtracting(known)
        let usQuotes = await YahooFinance.quotes(Array(unknown))
        var members = cache.members
        for (list, rows) in found {
            var symbols: [String] = []
            for member in rows {
                let symbol = Self.folded[member.symbol] ?? member.symbol
                if checked.contains(list) {
                    let reference = names[symbol] ?? usQuotes[symbol]?.name
                    guard let reference, ExploreSources.sameCompany(member.name, reference) else { continue }
                }
                if names[symbol] == nil, let quote = usQuotes[symbol] { names[symbol] = quote.name }
                if names[symbol] == nil, list == "FANG" { continue }
                if !symbols.contains(symbol) { symbols.append(symbol) }
            }
            if let before = cache.members[list], !before.isEmpty {
                let added = symbols.filter { !before.contains($0) }, removed = before.filter { !symbols.contains($0) }
                if !added.isEmpty || !removed.isEmpty { cache.changes.insert(MembershipChange(list:list, date:Date(), added:added, removed:removed), at:0) }
            }
            members[list] = symbols
        }
        cache.changes = Array(cache.changes.prefix(30))
        cache.members = members; cache.names = names; cache.spCodes = spCodes; cache.listsCheckedAt = Date()
        saveCache(); reload()
    }
    private static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static func data(_ address: String, body: String? = nil) async -> Data? {
        guard let url = URL(string:address) else { return nil }
        var request = URLRequest(url:url); request.timeoutInterval = 30
        request.setValue(agent, forHTTPHeaderField:"User-Agent"); request.setValue("application/json, text/csv, text/html, */*", forHTTPHeaderField:"Accept")
        if let body { request.httpMethod = "POST"; request.httpBody = Data(body.utf8); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField:"Content-Type") }
        guard let (data, response) = try? await URLSession.shared.data(for:request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
    private static func text(_ address: String) async -> String? { await data(address).map { String(decoding:$0, as:UTF8.self) } }
    /// An index's members on Nasdaq's index site, from the latest trading day
    /// it has (weekends and holidays have none).
    private static func nasdaqIndex(_ id: String) async -> [ExploreMember] {
        for back in 0..<7 {
            let day = TradingModel.day.string(from:Date().addingTimeInterval(Double(-back) * 86400))
            guard let data = await data("https://indexes.nasdaqomx.com/Index/WeightingData", body:"id=\(id)&tradeDate=\(day)T00:00:00.000&timeOfDay=SOD") else { return [] }
            let rows = ExploreSources.nasdaqIndex(json:data)
            if !rows.isEmpty { return rows }
        }
        return []
    }

    // MARK: Placing
    /// Companies outside the S&P 500 have no published sub-industry. Your model
    /// places each one once; the answer is saved, and you can move it.
    func classify() async {
        guard let notebook, notebook.agent.canSummarize else { return }
        let waiting = unplaced
        guard !waiting.isEmpty else { return }
        busy = "Placing \(waiting.count) companies in industries…"
        defer { busy = "" }
        let options = GICS.subIndustries.map { "\($0) \(GICS.name(GICS.sector($0))) > \(GICS.name($0))" }.joined(separator:"\n")
        let system = "You classify US-listed companies into GICS sub-industries, the way S&P and MSCI would. Reply with one JSON object and nothing else."
        for chunk in stride(from:0, to:waiting.count, by:40).map({ Array(waiting[$0..<min($0 + 40, waiting.count)]) }) {
            let companies = chunk.map { "\($0): \(stocks[$0]?.name ?? $0)" }.joined(separator:"\n")
            let prompt = "Sub-industries (code, sector > name):\n\(options)\n\nCompanies (ticker: name):\n\(companies)\n\nReply with a JSON object mapping each ticker to the 8-digit code of its sub-industry, e.g. {\"ZS\": \"45103020\"}."
            do {
                let reply = try await notebook.agent.write(system:system, prompt:prompt, maxTokens:3000)
                for (symbol, code) in ExploreSources.placements(reply:reply, asked:chunk) { save(symbol, code:code, by:"ai", model:notebook.agent.modelLabel) }
            } catch { self.error = error.localizedDescription; break }
        }
        reload(); Task { await notebook.sync() }
    }

    private func saveCache() { try? JSONEncoder().encode(cache).write(to:cacheURL, options:.atomic) }
}
