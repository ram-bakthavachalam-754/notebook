import Foundation
import UserNotifications
import NotebookCore

/// One alert and what became of it: the plan (what to buy, stop, target),
/// then either your trade, once you say you bought it, or why it ended
/// without one ("passed": skipped, stop, target, time or stale). Stored as a
/// "trading" record so it syncs.
struct TradeIdea: Identifiable {
    var raw: [String:Any]
    var id: String { raw["id"] as? String ?? "" }
    func text(_ key: String) -> String { raw[key] as? String ?? "" }
    func number(_ key: String) -> Double { (raw[key] as? NSNumber)?.doubleValue ?? 0 }
    var ticker: String { text("ticker") }
    var bullish: Bool { raw["bullish"] as? Bool ?? true }
    /// "stock", "call", "put", "callSpread" or "putSpread".
    var vehicle: String { text("vehicle") }
    var isOption: Bool { vehicle != "stock" }
    var multiplier: Double { isOption ? 100 : 1 }
    var legs: [[String:Any]] { raw["legs"] as? [[String:Any]] ?? [] }
    func strings(_ key: String) -> [String] { raw[key] as? [String] ?? [] }
    var real: [String:Any]? { raw["real"] as? [String:Any] }
    /// Still to do: buy it, or skip it.
    var pending: Bool { real == nil && text("passed").isEmpty }
    /// You bought it and haven't sold yet; Notebook tells you when to sell.
    var realOpen: Bool { real?["status"] as? String == "open" }
    /// Watched: waiting for you to buy, or waiting to be sold.
    var open: Bool { pending || realOpen }
    /// One or two words for the list: Buy, Holding, Sold, Skipped, Missed.
    var status: String {
        if pending { return "Buy" }
        if realOpen { return "Holding" }
        if real != nil { return "Sold" }
        return text("passed") == "skipped" ? "Skipped" : "Missed"
    }
    var created: Date { ISO8601DateFormatter().date(from:text("createdAt")) ?? .distantPast }
    var symbols: [String] { [ticker] + legs.compactMap { $0["symbol"] as? String } }
    /// "Buy 20 shares" or "Buy 2 NVDA Nov 21 $185/$195 call spreads".
    var action: String {
        let quantity = Int(number("quantity"))
        guard isOption else { return "Buy \(quantity) share\(quantity == 1 ? "" : "s")" }
        let strikes = legs.compactMap { ($0["strike"] as? NSNumber)?.doubleValue }.map { "$" + $0.formatted(.number.precision(.fractionLength(0...2))) }.joined(separator:"/")
        let expiry = (legs.first?["expiration"] as? String).flatMap(TradingModel.day.date).map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
        let kind = ["call":"call", "put":"put", "callSpread":"call spread", "putSpread":"put spread"][vehicle] ?? vehicle
        return "Buy \(quantity) \(ticker) \(expiry) \(strikes) \(kind)\(quantity == 1 ? "" : "s")"
    }
    var vehicleLabel: String { ["stock":"Shares", "call":"Call", "put":"Put", "callSpread":"Call spread", "putSpread":"Put spread"][vehicle] ?? vehicle }
    /// Profit or loss on your trade at a unit value.
    func profit(_ trade: [String:Any], at value: Double?) -> Double? {
        guard let price = (trade["price"] as? NSNumber)?.doubleValue, let quantity = (trade["quantity"] as? NSNumber)?.doubleValue else { return nil }
        let exit = (trade["closePrice"] as? NSNumber)?.doubleValue ?? value
        return exit.map { ($0 - price) * quantity * multiplier }
    }
}

/// A note from the last research run: why a stock was or wasn't an idea.
struct ResearchNote: Identifiable, Codable, Hashable {
    var ticker: String
    var text: String
    var id: String { ticker + text }
}

/// Trading: a budget, a watchlist and daily research that turns technical
/// signals, earnings dates and headlines into stock and defined-risk option
/// alerts, sized by your risk rules: what to buy, then when to sell what you
/// bought. While Notebook is open and unlocked on the Mac it watches prices
/// during market hours and sends notifications.
@MainActor final class TradingModel: ObservableObject {
    @Published private(set) var ideas: [TradeIdea] = []
    @Published private(set) var settings: [String:Any] = TradingModel.defaults
    @Published private(set) var quotes: [String:YahooFinance.Quote] = [:]
    @Published private(set) var researching = false
    @Published private(set) var progress = ""
    @Published private(set) var notes: [ResearchNote] = []
    @Published private(set) var lastResearch: Date?
    @Published private(set) var lastCheck: Date?
    @Published var error: String?
    /// Ticker pages' price history and headlines, kept for this session.
    var pages: [String:(candles: [Candle], headlines: [[String:String]])] = [:]
    /// Why each stock from the last scan was on it, for the model and the notes.
    private var scanReasons: [String:String] = [:]
    /// For opening headlines in the News reader.
    var notebookModel: NotebookModel? { notebook }
    /// Stocks in Finance, set by the app; researched along with the watchlist.
    var heldTickers: [String] = []
    private weak var notebook: NotebookModel?
    private let store: RecordStore
    private var loop: Task<Void,Never>?
    private let alerts = TradingAlerts()
    /// Your Robinhood login, for real-time quotes and option chains.
    let robinhood: RobinhoodLink
    private var cacheURL: URL { store.url.deletingLastPathComponent().appendingPathComponent("trading-cache.json") }

    static let defaults: [String:Any] = ["budget":10_000, "riskPercent":1, "maxPositionPercent":20, "maxOptionPercent":5, "maxRiskPercent":10, "minVolume":1_000_000, "minMarketCap":2_000_000_000, "options":true, "scan":true, "notify":true, "watchlist":[String]()]
    /// Setups looked at closely in one run (each costs a news search and an AI call).
    static let closerLooksPerRun = 8
    /// Research times, in minutes after midnight New York time, whatever this
    /// Mac's time zone: 15 minutes after the open, when option quotes are
    /// live, and 30 minutes before the close, when the day's bar is nearly final.
    static let researchTimes = [9 * 60 + 45, 15 * 60 + 30]
    /// 209K, 1.5M, 2B.
    static func compact(_ value: Double) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
    static let newYork = TimeZone(identifier:"America/New_York")!
    static let day: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = newYork; f.dateFormat = "yyyy-MM-dd"; return f }()

    init(notebook: NotebookModel) {
        self.notebook = notebook; store = notebook.store; robinhood = notebook.robinhood
        loadCache()
        reload()
    }

    // MARK: Records
    func reload() {
        guard notebook?.unlocked == true else { ideas = []; return }
        let rows = (try? store.records("trading")) ?? []
        if let saved = rows.filter({ $0["type"] as? String == "settings" }).max(by: { ($0["modifiedAt"] as? String ?? "") < ($1["modifiedAt"] as? String ?? "") }) {
            settings = Self.defaults.merging(saved) { _, new in new }
        }
        ideas = rows.filter { $0["type"] as? String == "idea" && $0["_syncConflict"] as? Bool != true }.map { TradeIdea(raw:$0) }.sorted { $0.created > $1.created }
    }
    func setting(_ key: String) -> Double { (settings[key] as? NSNumber)?.doubleValue ?? (Self.defaults[key] as? NSNumber)?.doubleValue ?? 0 }
    func flag(_ key: String) -> Bool { settings[key] as? Bool ?? Self.defaults[key] as? Bool ?? false }
    var watchlist: [String] { settings["watchlist"] as? [String] ?? [] }
    func saveSettings(_ changes: [String:Any]) {
        guard notebook?.unlocked == true else { return }
        var record: [String:Any] = (try? store.records("trading", entity:"settings").first) ?? ["id":"settings"]
        for (key, value) in changes { record[key] = value }
        record["type"] = "settings"; record["modifiedAt"] = ISO8601DateFormatter().string(from:Date())
        do { try store.save(kind:"trading", record:record, resolve:true); reload(); Task { await notebook?.sync() } } catch { self.error = error.localizedDescription }
        if changes["notify"] as? Bool == true { alerts.authorize() }
    }
    func addToWatchlist(_ text: String) {
        let symbols = text.uppercased().split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
            .filter { $0.count <= 10 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } }
        let list = watchlist + symbols.filter { !watchlist.contains($0) }
        if list != watchlist { saveSettings(["watchlist":Array(NSOrderedSet(array:list)) as? [String] ?? list]); Task { await refreshQuotes(list) } }
    }
    func removeFromWatchlist(_ ticker: String) { saveSettings(["watchlist":watchlist.filter { $0 != ticker }]) }
    private func save(_ idea: TradeIdea) {
        var record = idea.raw; record["modifiedAt"] = ISO8601DateFormatter().string(from:Date())
        do { try store.save(kind:"trading", record:record); reload(); Task { await notebook?.sync() } } catch { self.error = error.localizedDescription }
    }
    func delete(_ idea: TradeIdea) {
        do { try store.delete(kind:"trading", record:idea.raw); reload(); Task { await notebook?.sync() } } catch { self.error = error.localizedDescription }
    }
    func idea(_ id: String?) -> TradeIdea? { ideas.first { $0.id == id } }
    func locked() { loop?.cancel(); loop = nil; ideas = []; quotes = [:] }

    // MARK: Taking and closing trades
    /// You bought it for real: how many and at what price per share (or per contract share).
    func recordReal(_ idea: TradeIdea, quantity: Double, price: Double) {
        var idea = idea
        idea.raw["real"] = ["status":"open", "quantity":quantity, "price":price, "openedAt":ISO8601DateFormatter().string(from:Date())]
        save(idea)
    }
    func closeReal(_ idea: TradeIdea, price: Double) {
        guard var real = idea.real else { return }
        var idea = idea
        real["status"] = "closed"; real["closePrice"] = price; real["closedAt"] = ISO8601DateFormatter().string(from:Date())
        idea.raw["real"] = real; save(idea)
    }
    /// You're not taking it (or it ran out): it leaves your to-do list.
    func pass(_ idea: TradeIdea, reason: String = "skipped") {
        guard idea.pending else { return }
        var idea = idea; idea.raw["passed"] = reason; save(idea)
    }

    // MARK: Account
    /// What's left of the budget to put into new trades: the budget, plus
    /// closed trades' results, less what open trades cost.
    var cash: Double {
        ideas.reduce(setting("budget")) { cash, idea in
            guard let real = idea.real, let price = (real["price"] as? NSNumber)?.doubleValue, let quantity = (real["quantity"] as? NSNumber)?.doubleValue else { return cash }
            return idea.realOpen ? cash - price * quantity * idea.multiplier : cash + (idea.profit(real, at:nil) ?? 0)
        }
    }
    /// Free cash less what waiting alerts would cost, so the alerts on your
    /// list never add up to more than you have.
    var available: Double { cash - ideas.filter(\.pending).reduce(0) { $0 + $1.number("quantity") * $1.number("unitCost") * $1.multiplier } }
    /// What one alert or trade can lose: to its stop for shares, everything paid for options.
    func risk(_ idea: TradeIdea) -> Double {
        let quantity = (idea.real?["quantity"] as? NSNumber)?.doubleValue ?? idea.number("quantity")
        let paid = (idea.real?["price"] as? NSNumber)?.doubleValue ?? idea.number("unitCost")
        return idea.isOption ? quantity * paid * 100 : max(0, quantity * (paid - idea.number("stop")))
    }
    /// What everything you hold and every waiting alert could lose together.
    var openRisk: Double { ideas.filter(\.open).reduce(0) { $0 + risk($1) } }
    var riskLimit: Double { setting("budget") * setting("maxRiskPercent") / 100 }
    var riskRoom: Double { max(0, riskLimit - openRisk) }
    var realProfit: (closed: Double, open: Double) {
        ideas.reduce((0.0, 0.0)) { sum, idea in
            guard let real = idea.real, let p = idea.profit(real, at:value(idea)) else { return sum }
            return idea.realOpen ? (sum.0, sum.1 + p) : (sum.0 + p, sum.1)
        }
    }
    /// Your closed trades: how many, how many made money.
    var record: (trades: Int, wins: Int) {
        let closed = ideas.filter { $0.real != nil && !$0.realOpen }
        return (closed.count, closed.filter { ($0.profit($0.real!, at:nil) ?? 0) > 0 }.count)
    }
    /// The current value of one share or one contract share of the idea.
    func value(_ idea: TradeIdea) -> Double? {
        guard idea.isOption else { return quotes[idea.ticker]?.price }
        var total = 0.0
        for leg in idea.legs {
            guard let symbol = leg["symbol"] as? String else { return nil }
            var mark = quotes[symbol]?.mark
            // After expiration a contract is worth what it's in the money.
            if expired(leg), let underlying = quotes[idea.ticker]?.price, let strike = (leg["strike"] as? NSNumber)?.doubleValue {
                mark = leg["type"] as? String == "call" ? max(0, underlying - strike) : max(0, strike - underlying)
            }
            guard let mark else { return nil }
            total += leg["side"] as? String == "sell" ? -mark : mark
        }
        return max(0, total)
    }
    private func expired(_ leg: [String:Any]) -> Bool { (leg["expiration"] as? String ?? "9") < Self.day.string(from:Date()) }

    // MARK: Watching
    /// Starts watching on this device: research once each trading morning and
    /// prices every five minutes while the market is open. Paused while locked.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for:.seconds(60))
            }
        }
    }
    var marketHours: Bool {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = Self.newYork
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from:Date())
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return (2...6).contains(parts.weekday ?? 1) && (9 * 60 + 30..<16 * 60 + 5).contains(minutes)
    }
    /// Due when the latest research time today has passed since the last run.
    var researchDue: Bool {
        guard marketHours, let last = Self.researchSlots(Date()).last(where: { $0 <= Date() }) else { return false }
        return (lastResearch ?? .distantPast) < last
    }
    /// Today's research times as dates (New York days and hours).
    static func researchSlots(_ date: Date) -> [Date] {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = newYork
        return researchTimes.compactMap { calendar.date(bySettingHour:$0 / 60, minute:$0 % 60, second:0, of:date) }
    }
    /// "6:45 AM and 12:30 PM" in this Mac's time zone.
    static var researchTimesHere: String { researchSlots(Date()).map { $0.formatted(date:.omitted, time:.shortened) }.joined(separator:" and ") }
    private func tick() async {
        guard let notebook, notebook.unlocked, !notebook.agent.kidMode else { return }
        if researchDue, !researching { await research() }
        if marketHours, Date().timeIntervalSince(lastCheck ?? .distantPast) >= 5 * 60 { await check() }
    }
    /// Names, earnings dates and option quotes come from Yahoo; with Robinhood
    /// connected, stock prices are replaced by its real-time quotes.
    func refreshQuotes(_ symbols: [String]) async {
        async let yahoo = YahooFinance.quotes(symbols)
        async let live = robinhood.stockQuotes(symbols.filter { !YahooFinance.isOption($0) })
        let (found, realtime) = await (yahoo, live)
        for (symbol, quote) in found { quotes[symbol] = quote }
        for (symbol, q) in realtime {
            var quote = quotes[symbol] ?? YahooFinance.Quote(price:q.price, changePercent:0, bid:0, ask:0, name:symbol, marketState:"", earnings:nil)
            quote.price = q.price; quote.bid = q.bid; quote.ask = q.ask; quote.source = "Robinhood"
            let yahoo = found[symbol].map { (day:q.tradeDay, close:$0.price / (1 + $0.changePercent / 100)) }
            let change = q.dayChange(known:yahoo) ?? 0
            quote.changePercent = q.price - change > 0 ? change / (q.price - change) * 100 : 0
            quotes[symbol] = quote
        }
        // Option legs Robinhood knows: its live bid and ask.
        let wanted = Set(symbols)
        var legIDs: [String:String] = [:]
        for idea in ideas { for leg in idea.legs { if let symbol = leg["symbol"] as? String, let id = leg["robinhoodID"] as? String, !id.isEmpty, wanted.contains(symbol) { legIDs[id] = symbol } } }
        for (id, q) in await robinhood.optionQuotes(Array(legIDs.keys)) {
            guard let symbol = legIDs[id] else { continue }
            var quote = quotes[symbol] ?? YahooFinance.Quote(price:q.last, changePercent:0, bid:0, ask:0, name:symbol, marketState:"", earnings:nil)
            quote.price = q.last; quote.bid = q.bid; quote.ask = q.ask; quote.source = "Robinhood"
            quotes[symbol] = quote
        }
    }
    /// Prices for alerts and the watchlist. Tells you to sell what you hold
    /// when it hits its stop, target or time limit; an alert you haven't
    /// acted on ends there too, or after two trading days, since its price
    /// and plan have gone stale.
    func check() async {
        lastCheck = Date()
        let open = ideas.filter(\.open)
        await refreshQuotes(Array(Set(open.flatMap(\.symbols) + watchlist)))
        let today = Self.day.string(from:Date())
        for idea in open {
            guard let price = quotes[idea.ticker]?.price else { continue }
            let stop = idea.number("stop"), target = idea.number("target")
            let hitStop = idea.bullish ? price <= stop : price >= stop, hitTarget = idea.bullish ? price >= target : price <= target
            let late = idea.text("exitBy") <= today
            guard let reason = hitStop ? "stop" : hitTarget ? "target" : late ? "time" : nil else { continue }
            let label = ["stop":"hit its stop", "target":"reached its target", "time":"reached its time limit"][reason]!
            if idea.realOpen, !idea.strings("alerts").contains(reason) {
                var marked = idea; marked.raw["alerts"] = idea.strings("alerts") + [reason]; save(marked)
                send(idea.id + reason, title:"Sell \(idea.ticker): \(label)", body:"\(idea.vehicleLabel) you hold. \(idea.ticker) is at \(price.formatted(.currency(code:"USD"))); the plan was stop \(stop.formatted(.currency(code:"USD"))), target \(target.formatted(.currency(code:"USD"))).")
            }
            if idea.pending { pass(idea, reason:reason) }
        }
        for idea in ideas where idea.pending && Self.tradingDays(since:idea.created) >= 2 { pass(idea, reason:"stale") }
    }
    /// Weekdays that have started since a date, in New York.
    static func tradingDays(since date: Date) -> Int {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = newYork
        var day = calendar.startOfDay(for:date), count = 0
        while let next = calendar.date(byAdding:.day, value:1, to:day), next <= Date() {
            day = next
            if !calendar.isDateInWeekend(day) { count += 1 }
        }
        return count
    }
    private func send(_ id: String, title: String, body: String) { if flag("notify") { alerts.send(id, title:title, body:body) } }

    // MARK: Research
    /// The day's research: score the watchlist, your holdings and (if on)
    /// the market's biggest movers; look closely at the strongest; ask your
    /// model for a plan; size it by your rules; tell you what to buy.
    func research() async {
        guard let notebook, notebook.unlocked, !researching else { return }
        researching = true; notes = []; defer { researching = false; progress = ""; lastResearch = Date(); saveCache() }
        progress = "Finding stocks…"
        var universe = watchlist + heldTickers.filter { !$0.contains(" ") && $0.count <= 6 }
        // The scan: Robinhood's scanner when connected, else Yahoo's movers lists.
        scanReasons = [:]
        if flag("scan") {
            let found = await robinhood.movers()
            for item in found { scanReasons[item.ticker] = item.reason }
            if found.isEmpty {
                let yahoo = await YahooFinance.movers()
                for ticker in yahoo where scanReasons[ticker] == nil { scanReasons[ticker] = "Yahoo's most active, gainers and losers lists" }
                universe += yahoo
            } else { universe += found.map(\.ticker) }
        }
        let busy = Set(ideas.filter(\.open).map(\.ticker))
        universe = Array(NSOrderedSet(array:universe.map { $0.uppercased() })) as? [String] ?? universe
        universe.removeAll { busy.contains($0) }
        guard !universe.isEmpty else { notes = [ResearchNote(ticker:"", text:"Add stocks to your watchlist, or turn on market scans, to get ideas.")]; return }
        progress = "Reading \(universe.count) charts…"
        var scored: [(ticker: String, candles: [Candle], signals: [TradeSignal], score: Int)] = []
        let live = await robinhood.candles(universe)
        for (ticker, candles) in live where candles.count >= 200 {
            scored.append((ticker, candles, TradingMath.signals(candles), TradingMath.score(TradingMath.signals(candles))))
        }
        universe.removeAll { live[$0]?.count ?? 0 >= 200 }
        for chunk in stride(from:0, to:universe.count, by:8).map({ Array(universe[$0..<min($0 + 8, universe.count)]) }) {
            let results = await withTaskGroup(of:(String, [Candle]).self) { group in
                for ticker in chunk { group.addTask { (ticker, await YahooFinance.candles(ticker)) } }
                var out: [(String, [Candle])] = []; for await r in group { out.append(r) }; return out
            }
            for (ticker, candles) in results {
                let signals = TradingMath.signals(candles)
                guard TradingMath.indicators(candles) != nil else { notes.append(.init(ticker:ticker, text:"Not enough price history.")); continue }
                scored.append((ticker, candles, signals, TradingMath.score(signals)))
            }
        }
        // Too thinly traded or too small to trade, however they were found. A
        // market cap Yahoo didn't give doesn't count against a stock.
        await refreshQuotes(scored.map(\.ticker))
        let minVolume = setting("minVolume"), minCap = setting("minMarketCap")
        scored.removeAll { s in
            let volume = TradingMath.indicators(s.candles)?.averageVolume ?? 0, cap = quotes[s.ticker]?.marketCap ?? 0
            let why = volume < minVolume ? "trades about \(Self.compact(volume)) shares a day (20-day average), under your \(Self.compact(minVolume)) minimum"
                : cap > 0 && cap < minCap ? "worth $\(Self.compact(cap)), under your $\(Self.compact(minCap)) minimum" : nil
            guard let why else { return false }
            notes.append(.init(ticker:s.ticker, text:"Skipped: " + why + ".")); return true
        }
        let options = flag("options")
        let candidates = scored.filter { $0.score >= 2 || (options && $0.score <= -2) }.sorted { abs($0.score) > abs($1.score) }.prefix(Self.closerLooksPerRun)
        for s in scored.sorted(by: { abs($0.score) > abs($1.score) }) where !candidates.contains(where: { $0.ticker == s.ticker }) {
            let strong = s.score >= 2 || (options && s.score <= -2)
            notes.append(.init(ticker:s.ticker, text:s.score == 0 ? "No clear signal." : (strong ? "Not among this run's strongest \(Self.closerLooksPerRun) (\(s.score > 0 ? "+" : "")\(s.score)): " : "Signals too weak (\(s.score > 0 ? "+" : "")\(s.score)): ") + s.signals.map(\.name).joined(separator:"; ")))
        }
        for (index, candidate) in candidates.enumerated() {
            guard notebook.unlocked else { return }
            guard riskRoom > 0 else {
                notes.insert(.init(ticker:"", text:"Your total risk limit (\(riskLimit.formatted(.currency(code:"USD").precision(.fractionLength(0))))) is used by what you hold and the alerts waiting. Skip or sell something to make room."), at:0)
                for rest in candidates[index...] { notes.append(.init(ticker:rest.ticker, text:"Not looked at: no room under your total risk limit.")) }
                break
            }
            progress = "Researching \(candidate.ticker) (\(index + 1) of \(candidates.count))…"
            do {
                if let idea = try await plan(candidate.ticker, candles:candidate.candles, signals:candidate.signals, score:candidate.score) {
                    save(idea)
                    send(idea.id, title:"\(idea.action) at about \(idea.number("unitCost").formatted(.currency(code:"USD")))", body:"\(idea.bullish ? "Bullish" : "Bearish") on \(idea.ticker). " + idea.text("summary") + " Stop \(idea.number("stop").formatted(.currency(code:"USD"))), target \(idea.number("target").formatted(.currency(code:"USD"))).")
                }
            } catch { notes.append(.init(ticker:candidate.ticker, text:"Couldn't research: " + error.localizedDescription)) }
        }
        await check()
    }

    private static let system = """
    You are a disciplined swing trader and risk manager helping one person trade a small account. You decide from the data you are given only: price indicators, signals, the earnings date, recent headlines and the trade choices listed. You never invent news, numbers or prices. You protect capital first: pass whenever the setup is unclear, the headlines contradict the chart, or earnings are about to make the move a coin flip. You only choose among the listed choices. Reply with a single JSON object and nothing else.
    """
    /// One candidate, looked at closely: the earnings date, headlines and
    /// option choices, then your model's decision (or the rules alone without a model).
    private func plan(_ ticker: String, candles: [Candle], signals: [TradeSignal], score: Int) async throws -> TradeIdea? {
        guard let notebook, let ind = TradingMath.indicators(candles) else { return nil }
        let bullish = score > 0, quote = quotes[ticker], price = quote?.price ?? ind.price
        let levels = TradingMath.levels(price:price, atr:ind.atr14, bullish:bullish)
        let budget = setting("budget"), cash = available, room = riskRoom
        let earnings = quote?.earnings.flatMap { $0 > Date() ? $0 : nil }
        let earningsDays = earnings.map { Int(($0.timeIntervalSinceNow / 86400).rounded(.up)) }
        let headlines = await Self.headlines(ticker, name:quote?.name ?? ticker, days:2)
        // The choices: shares (long only, so the risk is the stop), and when
        // options are on, a single option and a debit spread.
        var choices: [String:[String:Any]] = [:]
        // Each size also fits what's left under the total risk limit.
        func fit(_ shares: Int, stop: Double) -> Int { price > stop ? min(shares, Int(room / (price - stop))) : 0 }
        func fit(_ contracts: Int, debit: Double) -> Int { debit > 0 ? min(contracts, Int(room / (debit * 100))) : 0 }
        let shares = fit(TradingMath.shares(budget:budget, cash:cash, riskPercent:setting("riskPercent"), maxPositionPercent:setting("maxPositionPercent"), price:price, stop:levels.stop), stop:levels.stop)
        if bullish, shares > 0 { choices["stock"] = ["shares":shares, "price":price, "cost":Double(shares) * price, "lossAtStop":Double(shares) * (price - levels.stop)] }
        var legsFor: [String:[YahooFinance.OptionContract]] = [:]
        var chain: (calls: [YahooFinance.OptionContract], puts: [YahooFinance.OptionContract])?
        if flag("options") {
            chain = await robinhood.optionChain(ticker, price:price, after:earnings)
            // Yahoo's chain when Robinhood's has nothing that passes the liquidity check.
            let side = { (c: (calls: [YahooFinance.OptionContract], puts: [YahooFinance.OptionContract])) in bullish ? c.calls : c.puts }
            if chain.map({ !side($0).contains(where:\.liquid) }) ?? true, let yahoo = await YahooFinance.chain(ticker, after:earnings) { chain = yahoo }
        }
        if let chain {
            let type = bullish ? "call" : "put"
            let contracts = (bullish ? chain.calls : chain.puts).filter(\.liquid)
            if let long = contracts.min(by: { abs($0.strike - price) < abs($1.strike - price) }) {
                let single = fit(TradingMath.contracts(budget:budget, cash:cash, maxOptionPercent:setting("maxOptionPercent"), debit:long.mark), debit:long.mark)
                if single > 0 {
                    legsFor[type] = [long]
                    choices[type] = ["contract":long.label(ticker), "premium":long.mark, "contracts":single, "maxLoss":Double(single) * long.mark * 100, "impliedVolatility":(long.iv * 100).rounded()]
                    if let delta = long.delta { choices[type]?["delta"] = (delta * 100).rounded() / 100 }
                }
                let beyond = contracts.filter { bullish ? $0.strike > long.strike : $0.strike < long.strike }
                if let short = beyond.min(by: { abs($0.strike - levels.target) < abs($1.strike - levels.target) }) {
                    let debit = long.mark - short.mark, width = abs(short.strike - long.strike)
                    let count = fit(TradingMath.contracts(budget:budget, cash:cash, maxOptionPercent:setting("maxOptionPercent"), debit:debit), debit:debit)
                    if debit > 0, debit < width, count > 0 {
                        legsFor[type + "Spread"] = [long, short]
                        choices[type + "Spread"] = ["buy":long.label(ticker), "sell":short.label(ticker), "debit":debit, "contracts":count, "maxLoss":Double(count) * debit * 100, "maxGain":Double(count) * (width - debit) * 100]
                    }
                }
            }
        }
        guard !choices.isEmpty else { notes.append(.init(ticker:ticker, text:bullish ? "Bullish, but no trade fits your budget and risk rules." : "Bearish, but no put fits your budget and risk rules.")); return nil }

        var decision: [String:Any]
        var source = "Rules"
        if notebook.agent.canSummarize {
            let facts: [String:Any] = ["ticker":ticker, "name":quote?.name ?? ticker, "date":Self.day.string(from:Date()), "direction":bullish ? "bullish" : "bearish",
                                       "signals":signals.map { ["signal":$0.name, "weight":$0.weight] }, "indicators":ind.summary, "currentPrice":price, "foundBy":scanReasons[ticker] ?? "watchlist or holdings",
                                       "earningsDate":earnings.map(Self.day.string) ?? "none known", "daysToEarnings":earningsDays ?? -1,
                                       "headlines":headlines, "defaultStop":levels.stop, "defaultTarget":levels.target, "choices":choices,
                                       "account":["budget":budget, "cash":cash, "riskPercentPerStockTrade":setting("riskPercent"), "maxOptionPercent":setting("maxOptionPercent"), "totalRiskLimit":riskLimit, "riskRoomLeft":room]]
            let prompt = """
            Decide whether to trade this setup in the next few days to weeks. Data:
            \(try jsonString(facts))

            Reply with JSON only:
            {"action": one of \(try jsonString(Array(choices.keys).sorted() + ["pass"])), "confidence": "low"|"medium"|"high", "summary": one sentence a beginner understands, "reasons": [up to 4 short strings], "risks": [up to 3 short strings], "stop": price of \(ticker) where the idea is wrong, "target": price of \(ticker) to take profit, "holdDays": trading days to give it (3 to 30)}
            Prefer spreads when implied volatility is high. Avoid single options when earnings fall before expiration unless that is the point of the trade, and say so in risks. Stop and target are prices of the stock, not the option.
            """
            let reply = try await notebook.agent.write(system:Self.system, prompt:prompt, maxTokens:4000)
            guard let start = reply.firstIndex(of:"{"), let end = reply.lastIndex(of:"}"),
                  let parsed = try? jsonObject(String(reply[start...end])) as? [String:Any] else { throw NotebookError.message("The model's answer wasn't a plan.") }
            decision = parsed; source = notebook.agent.modelLabel
        } else {
            // Without a model: only strong setups, and the plainest trade.
            guard abs(score) >= 3 else { notes.append(.init(ticker:ticker, text:"Signals \(score > 0 ? "+" : "")\(score). Set up a model in Agent Settings for a closer look at weaker setups.")); return nil }
            let action = bullish ? (choices["stock"] != nil ? "stock" : choices["callSpread"] != nil ? "callSpread" : "call") : (choices["putSpread"] != nil ? "putSpread" : "put")
            decision = ["action":action, "confidence":"low", "summary":signals.first?.name ?? "", "reasons":signals.map(\.name), "risks":earningsDays.map { $0 <= 30 ? ["Earnings in \($0) days"] : [] } ?? [], "holdDays":15]
        }
        let action = decision["action"] as? String ?? "pass"
        guard action != "pass", let choice = choices[action] else {
            notes.append(.init(ticker:ticker, text:"Passed: " + (decision["summary"] as? String ?? "the model saw no good trade."))); return nil
        }
        var stop = (decision["stop"] as? NSNumber)?.doubleValue ?? levels.stop, target = (decision["target"] as? NSNumber)?.doubleValue ?? levels.target
        if !TradingMath.sensible(price:price, atr:ind.atr14, stop:stop, target:target, bullish:bullish) { (stop, target) = levels }
        // Shares are re-sized to the stop actually chosen.
        var quantity = (choice["shares"] ?? choice["contracts"]) as? Int ?? 0, unit = price
        if action == "stock" {
            quantity = fit(TradingMath.shares(budget:budget, cash:cash, riskPercent:setting("riskPercent"), maxPositionPercent:setting("maxPositionPercent"), price:price, stop:stop), stop:stop)
        } else { unit = (choice["premium"] ?? choice["debit"]) as? Double ?? 0 }
        guard quantity > 0 else { notes.append(.init(ticker:ticker, text:"No position size fits your rules.")); return nil }
        let holdDays = min(30, max(3, (decision["holdDays"] as? NSNumber)?.intValue ?? 15))
        var exitBy = Calendar.current.date(byAdding:.day, value:Int(Double(holdDays) * 1.4), to:Date())!
        func cents(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        (stop, target, unit) = (cents(stop), cents(target), cents(unit))
        let legs: [[String:Any]] = (legsFor[action] ?? []).enumerated().map { i, c in
            ["symbol":c.symbol, "type":c.type, "strike":c.strike, "expiration":Self.day.string(from:c.expiration), "side":i == 0 ? "buy" : "sell", "price":cents(c.mark), "robinhoodID":c.robinhoodID]
        }
        // Options are closed a few days before they expire.
        if let expiration = legsFor[action]?.first?.expiration { exitBy = min(exitBy, expiration.addingTimeInterval(-4 * 86400)) }
        let now = ISO8601DateFormatter().string(from:Date())
        return TradeIdea(raw:["id":UUID().uuidString.lowercased(), "type":"idea", "ticker":ticker, "name":quote?.name ?? ticker, "createdAt":now, "modifiedAt":now,
                              "bullish":bullish, "vehicle":action, "price":price, "stop":stop, "target":target, "exitBy":Self.day.string(from:exitBy), "legs":legs,
                              "unitCost":unit, "quantity":quantity, "confidence":decision["confidence"] as? String ?? "low", "summary":decision["summary"] as? String ?? "",
                              "reasons":(decision["reasons"] as? [String] ?? []).prefix(4).map { $0 }, "risks":(decision["risks"] as? [String] ?? []).prefix(3).map { $0 },
                              "signals":signals.map(\.name), "score":score, "earnings":earnings.map(Self.day.string) ?? "", "source":source, "foundBy":watchlist.contains(ticker) ? "Your watchlist" : heldTickers.contains(ticker) ? "Your holdings" : scanReasons[ticker] ?? "",
                              "headlines":headlines.prefix(6).map { $0 }, "indicators":ind.summary])
    }
    /// A year or more of daily candles: Robinhood's when connected, else Yahoo's.
    func candles(_ ticker: String) async -> [Candle] {
        if let live = await robinhood.candles([ticker])[ticker], live.count >= 200 { return live }
        return await YahooFinance.candles(ticker)
    }
    /// The latest headlines about a company from Google News, newest first:
    /// the last week for ticker pages, the last two days for research. Quote
    /// pages, filings and syndicated copies of one story are left out.
    static func headlines(_ ticker: String, name: String, days: Int = 7) async -> [[String:String]] {
        let (_, found) = await NewsModel.fetch(topic:TickerNews.query(ticker:ticker, name:name, days:days), source:"google")
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        var seen = Set<String>()
        return found.filter { ($0.publishedAt ?? .distantPast) > since && !TickerNews.isListing($0.title) }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
            .filter { seen.insert(TickerNews.key($0.title)).inserted }.prefix(10).map { story in
            ["title":TickerNews.clean(story.title), "source":story.byline, "url":story.url, "date":story.publishedAt.map { ISO8601DateFormatter().string(from:$0) } ?? "", "blurb":String(story.blurb.prefix(240))]
        }
    }

    // MARK: Cache
    private struct Cache: Codable { var lastResearch: Date?; var notes: [ResearchNote] }
    private func loadCache() {
        guard let data = try? Data(contentsOf:cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from:data) else { return }
        lastResearch = cache.lastResearch; notes = cache.notes
    }
    private func saveCache() { try? JSONEncoder().encode(Cache(lastResearch:lastResearch, notes:notes)).write(to:cacheURL, options:.atomic) }
}

// MARK: Agent
/// The agent's Trading tools, declared in agent-core.js: everything Trading
/// shows can be read, and changes (with edits on) go through the same
/// functions as the buttons. Nothing here places a trade.
extension TradingModel {
    func agentTool(_ name: String, arguments: Any, canWrite: Bool) async throws -> [String:Any] {
        let args = arguments as? [String:Any] ?? [:]
        guard notebook?.unlocked == true else { throw NotebookError.message("Unlock Notebook to continue.") }
        switch name {
        case "trading_overview": return await agentOverview()
        case "trading_alerts": return await agentAlerts(args)
        case "trading_ticker": return try await agentTicker(args)
        case "trading_update":
            guard canWrite else { throw NotebookError.message("This conversation is in read-only mode. Ask the user to enable edits.") }
            return try agentUpdate(args)
        default: throw NotebookError.message("Unknown tool.")
        }
    }
    private static func stamp(_ date: Date?) -> Any { date.map { ISO8601DateFormatter().string(from:$0) } ?? NSNull() }
    /// An alert as stored, plus what the screen works out: status, the action, risk, and its value now.
    private func agentIdea(_ idea: TradeIdea) -> [String:Any] {
        var out = idea.raw.filter { !$0.key.hasPrefix("_sync") }
        out["status"] = idea.status.lowercased(); out["action"] = idea.action; out["vehicleLabel"] = idea.vehicleLabel; out["risk"] = risk(idea)
        if let price = quotes[idea.ticker]?.price { out["currentPrice"] = price }
        let now = idea.open ? value(idea) : nil
        if let now { out["currentValue"] = now }
        if let real = idea.real, let profit = idea.profit(real, at:now) { out["profit"] = profit }
        return out
    }
    private func refreshOpen(_ ideas: [TradeIdea]) async {
        let symbols = Set(ideas.filter(\.open).flatMap(\.symbols))
        if !symbols.isEmpty { await refreshQuotes(Array(symbols)) }
    }
    private func agentOverview() async -> [String:Any] {
        await refreshOpen(ideas)
        var counts: [String:Int] = [:]
        for idea in ideas { counts[idea.status.lowercased(), default:0] += 1 }
        let profit = realProfit, tally = record
        let rules = settings.filter { !$0.key.hasPrefix("_sync") && !["id", "type", "modifiedAt", "watchlist"].contains($0.key) }
        return ["settings":rules, "watchlist":watchlist,
                "account":["budget":setting("budget"), "cash":cash, "availableForNewAlerts":available, "openRisk":openRisk, "totalRiskLimit":riskLimit, "riskRoomLeft":riskRoom,
                           "profitOnSoldTrades":profit.closed, "profitOnOpenTrades":profit.open, "soldTrades":tally.trades, "winningTrades":tally.wins],
                "alerts":counts,
                "research":["last":Self.stamp(lastResearch), "researchingNow":researching, "progress":progress, "lastPriceCheck":Self.stamp(lastCheck),
                            "schedule":"Weekdays at 9:45 AM and 3:30 PM New York time (\(Self.researchTimesHere) here), on the Mac while Notebook is open and unlocked",
                            "notes":notes.map { ["ticker":$0.ticker, "text":$0.text] }],
                "marketOpen":marketHours, "robinhoodConnected":robinhood.connected, "heldInFinance":heldTickers,
                "decisionsBy":notebook?.agent.canSummarize == true ? notebook?.agent.modelLabel ?? "your model" : "rules only (no model in Agent Settings)"]
    }
    private func agentAlerts(_ args: [String:Any]) async -> [String:Any] {
        let status = args["status"] as? String ?? "all", ticker = (args["ticker"] as? String)?.uppercased() ?? ""
        let matches = ideas.filter { idea in
            (ticker.isEmpty || idea.ticker == ticker) && (status == "all" || (status == "open" ? idea.open : idea.status.lowercased() == status))
        }
        let offset = max(0, (args["offset"] as? NSNumber)?.intValue ?? 0), limit = min(50, max(1, (args["limit"] as? NSNumber)?.intValue ?? 20))
        let page = Array(matches.dropFirst(offset).prefix(limit))
        await refreshOpen(page)
        return ["total":matches.count, "offset":offset, "nextOffset":offset + limit < matches.count ? offset + limit : NSNull(), "alerts":page.map(agentIdea)]
    }
    private func agentTicker(_ args: [String:Any]) async throws -> [String:Any] {
        let ticker = (args["ticker"] as? String ?? "").trimmingCharacters(in:.whitespaces).uppercased()
        guard !ticker.isEmpty, ticker.count <= 10, ticker.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { throw NotebookError.message("Give a stock ticker such as NVDA.") }
        async let company = FinanceModel.fetchCompanyInfo(ticker)
        await refreshQuotes([ticker] + ideas.filter { $0.ticker == ticker && $0.open }.flatMap(\.symbols))
        var bars = pages[ticker]?.candles ?? []
        if bars.isEmpty { bars = await candles(ticker); pages[ticker, default:([], [])].candles = bars }
        var out: [String:Any] = ["ticker":ticker, "onWatchlist":watchlist.contains(ticker), "heldInFinance":heldTickers.contains(ticker),
                                 "alerts":ideas.filter { $0.ticker == ticker }.map(agentIdea), "researchNotes":notes.filter { $0.ticker == ticker }.map(\.text)]
        if let q = quotes[ticker] {
            out["quote"] = ["price":q.price, "changePercent":q.changePercent, "bid":q.bid, "ask":q.ask, "name":q.name, "marketState":q.marketState, "source":q.source, "volume":q.volume, "averageVolume3Month":q.averageVolume, "marketCap":q.marketCap, "earnings":q.earnings.map(Self.day.string) ?? NSNull()]
        }
        if var info = await company {
            if let earnings = info["earnings"] as? NSNumber { info["earnings"] = Self.day.string(from:Date(timeIntervalSince1970:earnings.doubleValue)) }
            out["company"] = info
        }
        if let ind = TradingMath.indicators(bars) {
            let signals = TradingMath.signals(bars), score = TradingMath.score(signals)
            out["technicals"] = ["indicators":ind.summary, "signals":signals.map { ["signal":$0.name, "weight":$0.weight] }, "score":score,
                                 "reading":score >= 2 ? "bullish" : score <= -2 ? "bearish" : "no clear signal"]
        } else { out["technicals"] = "Not enough price history." }
        if args["news"] as? Bool != false {
            var headlines = pages[ticker]?.headlines ?? []
            if headlines.isEmpty { headlines = await Self.headlines(ticker, name:quotes[ticker]?.name ?? ticker); pages[ticker, default:([], [])].headlines = headlines }
            out["headlines"] = headlines; out["untrusted"] = true
        }
        return out
    }
    private func agentUpdate(_ args: [String:Any]) throws -> [String:Any] {
        let action = args["action"] as? String ?? ""
        func number(_ key: String) -> Double? { (args[key] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
        func alert() throws -> TradeIdea {
            guard let id = args["id"] as? String, let idea = idea(id) else { throw NotebookError.message("Alert not found. List alerts with trading_alerts.") }
            return idea
        }
        error = nil
        let label: String
        switch action {
        case "watch", "unwatch":
            let symbols = (args["symbols"] as? [String] ?? []).map { $0.trimmingCharacters(in:.whitespaces).uppercased() }.filter { !$0.isEmpty }
            guard !symbols.isEmpty else { throw NotebookError.message("Give the symbols to \(action).") }
            let before = watchlist
            if action == "watch" { addToWatchlist(symbols.joined(separator:" ")) } else { saveSettings(["watchlist":watchlist.filter { !symbols.contains($0) }]) }
            let changed = action == "watch" ? watchlist.filter { !before.contains($0) } : before.filter { !watchlist.contains($0) }
            label = changed.isEmpty ? "Watchlist unchanged" : (action == "watch" ? "Watching " : "Stopped watching ") + changed.joined(separator:", ")
        case "settings":
            guard let changes = args["settings"] as? [String:Any], !changes.isEmpty else { throw NotebookError.message("Give the settings to change.") }
            var valid: [String:Any] = [:]
            for (key, value) in changes {
                switch key {
                case "options", "scan", "notify":
                    guard let flag = value as? Bool else { throw NotebookError.message("\(key) must be true or false.") }
                    valid[key] = flag
                case "minVolume", "minMarketCap":
                    guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, n >= 0 else { throw NotebookError.message("\(key) must be 0 (any) or more.") }
                    valid[key] = n
                case "budget", "riskPercent", "maxPositionPercent", "maxOptionPercent", "maxRiskPercent":
                    guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, n > 0, key == "budget" || n <= 100 else { throw NotebookError.message(key == "budget" ? "The budget must be a positive amount." : "\(key) must be a percentage above 0 and at most 100.") }
                    valid[key] = n
                default: throw NotebookError.message("Unknown Trading setting: \(key).")
                }
            }
            saveSettings(valid)
            label = "Settings · " + valid.keys.sorted().joined(separator:", ")
        case "bought":
            let idea = try alert()
            guard idea.real == nil else { throw NotebookError.message("This alert already has a logged trade.") }
            guard let quantity = number("quantity"), quantity > 0, let price = number("price"), price > 0 else { throw NotebookError.message("Give the quantity bought and the price paid.") }
            recordReal(idea, quantity:quantity, price:price)
            label = "Bought \(quantity.formatted()) \(idea.ticker) at \(price.formatted(.currency(code:"USD")))"
        case "sold":
            let idea = try alert()
            guard idea.realOpen else { throw NotebookError.message("Only an open trade can be sold.") }
            guard let price = number("price"), price >= 0 else { throw NotebookError.message("Give the price it sold for.") }
            closeReal(idea, price:price)
            label = "Sold \(idea.ticker) at \(price.formatted(.currency(code:"USD")))"
        case "skip":
            let idea = try alert()
            guard idea.pending else { throw NotebookError.message("Only an alert waiting to be bought can be skipped.") }
            pass(idea); label = "Skipped \(idea.ticker)"
        case "delete":
            let idea = try alert()
            delete(idea); label = "Deleted the \(idea.ticker) alert"
        default: throw NotebookError.message("Unknown Trading action.")
        }
        if let error { throw NotebookError.message(error) }
        return ["success":true, "action":"update_record", "collection":"trading", "id":args["id"] as? String ?? action, "label":label]
    }
}

/// Local notifications for trade ideas and exits. Shown even while Notebook
/// is in front; clicking one opens Trading.
final class TradingAlerts: NSObject, UNUserNotificationCenterDelegate {
    func authorize() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options:[.alert, .sound]) { _, _ in }
    }
    func send(_ id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options:[.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            content.userInfo = ["section":"trading"]
            center.add(UNNotificationRequest(identifier:"trading-" + id, content:content, trigger:nil))
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.userInfo["section"] as? String == "trading" else { return }
        await MainActor.run { NotificationCenter.default.post(name:Notification.Name("notebookShowSection"), object:"trading") }
    }
}

/// Yahoo Finance's public endpoints: quotes (stocks and option contracts),
/// daily candles, option chains and the day's movers. Stock quotes are near
/// real time; option quotes are usually 15 minutes delayed. No account or key.
enum YahooFinance {
    struct Quote: Sendable {
        var price: Double, changePercent: Double, bid: Double, ask: Double
        var name: String, marketState: String, earnings: Date?
        var source = "Yahoo"
        /// From Yahoo; 0 when it didn't say. Volumes are in shares: today's
        /// so far, and the average over three months.
        var marketCap = 0.0, volume = 0.0, averageVolume = 0.0
        /// The middle of the bid and ask when both are set, else the last trade.
        var mark: Double { bid > 0 && ask >= bid ? (bid + ask) / 2 : price }
    }
    struct OptionContract: Sendable {
        var symbol: String, type: String, strike: Double, expiration: Date
        var bid: Double, ask: Double, last: Double, openInterest: Double, iv: Double
        var robinhoodID = ""
        var delta: Double?
        var mark: Double { bid > 0 && ask >= bid ? (bid + ask) / 2 : last }
        /// Enough interest, a real price and a spread under a quarter of it.
        var liquid: Bool { openInterest >= 50 && mark >= 0.1 && (bid <= 0 || (ask - bid) <= mark * 0.25) }
        func label(_ ticker: String) -> String {
            "\(ticker) \(expiration.formatted(.dateTime.month(.abbreviated).day().year())) $\(strike.formatted(.number.precision(.fractionLength(0...2)))) \(type)"
        }
    }
    /// Cookie and crumb, fetched once and renewed when Yahoo refuses them.
    private actor Session {
        static let shared = Session()
        let session = URLSession(configuration:.ephemeral)
        var crumb: String?
        static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        func data(_ address: String, crumbed: Bool) async -> Data? {
            for attempt in 0..<2 {
                var address = address
                if crumbed {
                    if crumb == nil || attempt > 0 { crumb = await fetchCrumb() }
                    guard let crumb else { return nil }
                    address += (address.contains("?") ? "&" : "?") + "crumb=" + (crumb.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? crumb)
                }
                guard let url = URL(string:address) else { return nil }
                var request = URLRequest(url:url); request.timeoutInterval = 15; request.setValue(Self.agent, forHTTPHeaderField:"User-Agent")
                guard let (data, response) = try? await session.data(for:request), let code = (response as? HTTPURLResponse)?.statusCode else { return nil }
                if code == 200 { return data }
                if !(crumbed && (code == 401 || code == 403)) { return nil }
            }
            return nil
        }
        private func fetchCrumb() async -> String? {
            var request = URLRequest(url:URL(string:"https://fc.yahoo.com/")!); request.setValue(Self.agent, forHTTPHeaderField:"User-Agent"); request.timeoutInterval = 15
            _ = try? await session.data(for:request)
            request.url = URL(string:"https://query2.finance.yahoo.com/v1/test/getcrumb")
            guard let (data, response) = try? await session.data(for:request), (response as? HTTPURLResponse)?.statusCode == 200,
                  let crumb = String(data:data, encoding:.utf8), !crumb.isEmpty, crumb.count < 40 else { return nil }
            return crumb
        }
    }
    /// An option contract's symbol (AAPL261120C00250000) rather than a stock's.
    static func isOption(_ symbol: String) -> Bool { symbol.range(of:#"^[A-Z.]{1,6}\d{6}[CP]\d{8}$"#, options:.regularExpression) != nil }
    private static func symbol(_ ticker: String) -> String { ticker.replacingOccurrences(of:".", with:"-").addingPercentEncoding(withAllowedCharacters:.alphanumerics.union(.init(charactersIn:"-"))) ?? ticker }
    private static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }

    static func quotes(_ symbols: [String]) async -> [String:Quote] {
        var out: [String:Quote] = [:]
        for chunk in stride(from:0, to:symbols.count, by:50).map({ Array(symbols[$0..<min($0 + 50, symbols.count)]) }) {
            guard let data = await Session.shared.data("https://query1.finance.yahoo.com/v7/finance/quote?symbols=" + chunk.map(symbol).joined(separator:","), crumbed:true),
                  let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let results = (root["quoteResponse"] as? [String:Any])?["result"] as? [[String:Any]] else { continue }
            for q in results {
                guard let returned = q["symbol"] as? String, let price = (q["regularMarketPrice"] as? NSNumber)?.doubleValue else { continue }
                let ticker = chunk.first { symbol($0) == returned } ?? returned
                let earnings = (q["earningsTimestampStart"] ?? q["earningsTimestamp"]) as? NSNumber
                out[ticker] = Quote(price:price, changePercent:number(q["regularMarketChangePercent"]), bid:number(q["bid"]), ask:number(q["ask"]),
                                    name:q["longName"] as? String ?? q["shortName"] as? String ?? ticker, marketState:q["marketState"] as? String ?? "",
                                    earnings:earnings.map { Date(timeIntervalSince1970:$0.doubleValue) })
                out[ticker]?.marketCap = number(q["marketCap"]); out[ticker]?.volume = number(q["regularMarketVolume"]); out[ticker]?.averageVolume = number(q["averageDailyVolume3Month"])
            }
        }
        return out
    }
    /// A year of daily candles.
    static func candles(_ ticker: String) async -> [Candle] {
        guard let data = await Session.shared.data("https://query1.finance.yahoo.com/v8/finance/chart/\(symbol(ticker))?interval=1d&range=1y", crumbed:false),
              let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let result = ((root["chart"] as? [String:Any])?["result"] as? [[String:Any]])?.first, let stamps = result["timestamp"] as? [NSNumber],
              let q = ((result["indicators"] as? [String:Any])?["quote"] as? [[String:Any]])?.first else { return [] }
        let open = q["open"] as? [Any] ?? [], high = q["high"] as? [Any] ?? [], low = q["low"] as? [Any] ?? [], close = q["close"] as? [Any] ?? [], volume = q["volume"] as? [Any] ?? []
        return stamps.indices.compactMap { i in
            guard i < close.count, i < open.count, i < high.count, i < low.count,
                  let c = (close[i] as? NSNumber)?.doubleValue, let o = (open[i] as? NSNumber)?.doubleValue, let h = (high[i] as? NSNumber)?.doubleValue, let l = (low[i] as? NSNumber)?.doubleValue, c > 0 else { return nil }
            return Candle(date:Date(timeIntervalSince1970:stamps[i].doubleValue), open:o, high:h, low:l, close:c, volume:i < volume.count ? number(volume[i]) : 0)
        }
    }
    /// A year of daily closes for many stocks, 20 a request (Yahoo's limit).
    static func closes(_ tickers: [String]) async -> [String:[(date: Date, close: Double)]] {
        var out: [String:[(date: Date, close: Double)]] = [:]
        for chunk in stride(from:0, to:tickers.count, by:20).map({ Array(tickers[$0..<min($0 + 20, tickers.count)]) }) {
            guard let data = await Session.shared.data("https://query1.finance.yahoo.com/v7/finance/spark?range=1y&interval=1d&symbols=" + chunk.map(symbol).joined(separator:","), crumbed:false),
                  let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let results = (root["spark"] as? [String:Any])?["result"] as? [[String:Any]] else { continue }
            for result in results {
                guard let returned = result["symbol"] as? String, let response = (result["response"] as? [[String:Any]])?.first,
                      let stamps = response["timestamp"] as? [NSNumber],
                      let close = ((response["indicators"] as? [String:Any])?["quote"] as? [[String:Any]])?.first?["close"] as? [Any] else { continue }
                let ticker = chunk.first { symbol($0) == returned } ?? returned
                out[ticker] = zip(stamps, close).compactMap { stamp, value in
                    (value as? NSNumber).map { (date:Date(timeIntervalSince1970:stamp.doubleValue), close:$0.doubleValue) }
                }
            }
        }
        return out
    }
    /// Calls and puts for one expiration three to ten weeks out, after the
    /// earnings date when there is one in that window.
    static func chain(_ ticker: String, after earnings: Date?) async -> (calls: [OptionContract], puts: [OptionContract])? {
        guard let data = await Session.shared.data("https://query2.finance.yahoo.com/v7/finance/options/\(symbol(ticker))", crumbed:true),
              let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let result = ((root["optionChain"] as? [String:Any])?["result"] as? [[String:Any]])?.first,
              let dates = (result["expirationDates"] as? [NSNumber])?.map({ Date(timeIntervalSince1970:$0.doubleValue) }) else { return nil }
        let window = dates.filter { $0.timeIntervalSinceNow > 21 * 86400 && $0.timeIntervalSinceNow < 70 * 86400 }
        guard let pick = window.first(where: { earnings == nil || $0 > earnings! }) ?? window.first else { return nil }
        guard let picked = await Session.shared.data("https://query2.finance.yahoo.com/v7/finance/options/\(symbol(ticker))?date=\(Int(pick.timeIntervalSince1970))", crumbed:true),
              let r = try? JSONSerialization.jsonObject(with:picked) as? [String:Any],
              let options = ((((r["optionChain"] as? [String:Any])?["result"] as? [[String:Any]])?.first)?["options"] as? [[String:Any]])?.first else { return nil }
        func contracts(_ key: String, _ type: String) -> [OptionContract] {
            (options[key] as? [[String:Any]] ?? []).compactMap { c in
                guard let symbol = c["contractSymbol"] as? String, let strike = (c["strike"] as? NSNumber)?.doubleValue else { return nil }
                return OptionContract(symbol:symbol, type:type, strike:strike, expiration:pick, bid:number(c["bid"]), ask:number(c["ask"]), last:number(c["lastPrice"]),
                                      openInterest:number(c["openInterest"]), iv:number(c["impliedVolatility"]))
            }
        }
        return (contracts("calls", "call"), contracts("puts", "put"))
    }
    /// The day's most active stocks, gainers and losers: US companies worth
    /// at least $2 billion, trading above $5.
    static func movers() async -> [String] {
        var out: [String] = []
        for id in ["most_actives", "day_gainers", "day_losers"] {
            guard let data = await Session.shared.data("https://query2.finance.yahoo.com/v1/finance/screener/predefined/saved?scrIds=\(id)&count=15", crumbed:true),
                  let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let quotes = (((root["finance"] as? [String:Any])?["result"] as? [[String:Any]])?.first)?["quotes"] as? [[String:Any]] else { continue }
            out += quotes.filter { $0["quoteType"] as? String == "EQUITY" && number($0["marketCap"]) >= 2e9 && number($0["regularMarketPrice"]) >= 5 }.compactMap { $0["symbol"] as? String }
        }
        return out
    }
}
