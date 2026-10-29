import Foundation
import SwiftUI
import JavaScriptCore
import UniformTypeIdentifiers
import NotebookCore

struct FinanceRow: Identifiable {
    var raw: [String:Any]
    var id: String { raw["id"] as? String ?? raw["ticker"] as? String ?? raw["date"] as? String ?? "" }
    func text(_ key: String) -> String { raw[key] as? String ?? "" }
    func number(_ key: String) -> Double { (raw[key] as? NSNumber)?.doubleValue ?? 0 }
    var name: String { text("name").isEmpty ? (text("ticker").isEmpty ? id : text("ticker")) : text("name") }
}
/// An account someone shared with you: their published view of it.
struct SharedAccount: Identifiable {
    let info: ShareInfo
    let view: [String:Any]
    var id: String { info.id }
}
struct FinanceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

/// The same JS calculations and transfer parser ship as resources on both platforms.
/// Swift owns the UI, files, network, storage and authentication.
@MainActor final class FinanceModel: ObservableObject {
    @Published var portfolio: [String:Any] = [:]
    @Published var history: [String:Any] = [:]
    @Published var spending: [String:Any] = [:]
    @Published var holdings: [FinanceRow] = []
    @Published var summary: [String:Any] = [:]
    @Published var error: String?
    @Published var notice: String?
    @Published var refreshing = false
    @Published var accessLocked = false
    /// Accounts others shared with you. Never part of your totals.
    @Published var sharedAccounts: [SharedAccount] = []
    /// Set by the app so shared accounts can be read and published.
    var shares: ShareLibrary?
    /// Set by the Mac app: with Robinhood connected, holdings get its real-time quotes.
    var robinhood: RobinhoodLink?
    let store: RecordStore
    var authorized: () -> Bool
    private let context: JSContext
    private var engineError: String?
    private var prices: [String:Any] = [:]
    private var cacheURL: URL { Self.priceCacheURL(store) }
    /// The price cache Finance and the agent share, next to the notebook.
    nonisolated static func priceCacheURL(_ store: RecordStore) -> URL { store.url.deletingLastPathComponent().appendingPathComponent("finance-prices.json") }
    /// Refreshes quotes older than five minutes for these tickers in the shared
    /// cache, and returns the cache. Used by the agent before it values holdings.
    nonisolated static func refreshQuotes(_ tickers: [String], store: RecordStore) async -> [String:Any] {
        let url = priceCacheURL(store)
        var prices = ((try? Data(contentsOf:url)).flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [String:Any]) ?? [:]
        let now = Date().timeIntervalSince1970 * 1000
        let stale = Set(tickers).filter { ticker in
            guard let updated = ((prices[ticker] as? [String:Any])?["updatedAt"] as? NSNumber)?.doubleValue else { return true }
            return now - updated > 5 * 60 * 1000
        }
        guard !stale.isEmpty else { return prices }
        let fetched = await withTaskGroup(of:(String, [String:Any]?).self) { group in
            for ticker in stale { group.addTask { (ticker, await quote(ticker)) } }
            var found: [String:[String:Any]] = [:]
            for await (ticker, value) in group { if let value { found[ticker] = value } }
            return found
        }
        guard !fetched.isEmpty else { return prices }
        for (ticker, value) in fetched { prices[ticker] = value }
        try? jsonData(prices).write(to:url, options:.atomic)
        return prices
    }
    init(store: RecordStore, shares: ShareLibrary? = nil, authorized: @escaping () -> Bool) {
        self.store = store; self.shares = shares; self.authorized = authorized; context = JSContext()!
        context.exceptionHandler = { [weak self] _, value in self?.engineError = value?.toString() }
        context.evaluateScript("""
        var financeData = {}, financeQuotes = {}, input = null;
        const AppManager = {register(){}};
        const StorageManager = {get:k=>financeData[k] || null, set:(k,v)=>{financeData[k]=v;return true;}};
        const localStorage = {getItem:k=>k==='portfolio-price-cache'?JSON.stringify(financeQuotes):null,setItem(){}};
        var window = {};
        const UIUtils = {showToast(){},todayISO:()=>{const d=new Date();return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;}};
        """)
        do {
            for file in ["portfolio-app", "portfolio-strategy", "spending-app", "finance-transfer"] {
                guard let url = Bundle.main.url(forResource:file,withExtension:"js") else { throw NotebookError.message("Finance resources are missing.") }
                _ = try evaluate(String(contentsOf:url,encoding:.utf8))
            }
            if let data = try? Data(contentsOf:cacheURL) { prices = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:] }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let quotes = ProcessInfo.processInfo.environment["NOTEBOOK_FINANCE_TEST_QUOTES"] {
                prices = (try? JSONSerialization.jsonObject(with:Data(quotes.utf8))) as? [String:Any] ?? [:]
            }
            #endif
            Task { await refresh() }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult private func evaluate(_ script: String, input: Any? = nil) throws -> JSValue {
        engineError = nil; context.exception = nil
        if let input { context.setObject(input,forKeyedSubscript:"input" as NSString) }
        let result = context.evaluateScript(script)
        if let engineError { throw NotebookError.message(engineError) }
        guard let result else { throw NotebookError.message("Finance could not calculate this value.") }
        return result
    }
    /// False until Finance has been read once, so the screen can show progress.
    @Published private(set) var loaded = false
    private var summaryCache: [String:[String:Any]] = [:]
    private var holdingsCache: [String:[FinanceRow]] = [:]
    private var stamp: String?
    private func currentStamp() -> String {
        let shares = self.shares?.shares().filter { $0.kind == "account" } ?? []
        return ((try? store.changeStamp(kind:"finance")) ?? "") + "|" + shares.map { "\($0.id):\($0.level):\($0.ready):" + ((try? self.shares?.store($0.id).changeStamp()) ?? "") }.joined(separator:",")
    }
    /// Reads and recalculates now, on this thread. Used right after a change.
    func reload() {
        do {
            stamp = currentStamp()
            apply(portfolio:try store.getKey("app_portfolio") as? [String:Any] ?? [:], history:try store.getKey("app_portfolio-history") as? [String:Any] ?? [:], spending:try store.getKey("app_spending") as? [String:Any] ?? [:])
        } catch { self.error = error.localizedDescription }
    }
    /// For background triggers (a sync, another section saving): skips the
    /// work when Finance didn't change, and reads the database off the main thread.
    func refresh() async {
        let store = store, shares = shares, known = loaded ? stamp : nil
        let read = await Task.detached(priority:.userInitiated) { () -> (String, [String:Any], [String:Any], [String:Any])? in
            let stamp = ((try? store.changeStamp(kind:"finance")) ?? "") + "|" + (shares?.shares().filter { $0.kind == "account" } ?? []).map { "\($0.id):\($0.level):\($0.ready):" + ((try? shares?.store($0.id).changeStamp()) ?? "") }.joined(separator:",")
            if stamp == known { return nil }
            guard let portfolio = try? store.getKey("app_portfolio") as? [String:Any], let history = try? store.getKey("app_portfolio-history") as? [String:Any],
                  let spending = try? store.getKey("app_spending") as? [String:Any] else { return nil }
            return (stamp, portfolio, history, spending)
        }.value
        // A save while this was reading has already shown newer data.
        guard let read, read.0 != stamp || !loaded, read.0 == currentStamp() else { return }
        stamp = read.0
        apply(portfolio:read.1, history:read.2, spending:read.3)
    }
    private func apply(portfolio: [String:Any], history: [String:Any], spending: [String:Any]) {
        do {
            summaryCache = [:]; holdingsCache = [:]
            self.portfolio = portfolio; self.history = history; self.spending = spending
            context.setObject(["portfolio":portfolio,"portfolio-history":history,"spending":spending],forKeyedSubscript:"financeData" as NSString)
            context.setObject(prices,forKeyedSubscript:"financeQuotes" as NSString)
            try evaluate("PortfolioApp.loadData(); SpendingApp.loadData();")
            holdings = (try evaluate("PortfolioApp.computeHoldings()").toArray() as? [[String:Any]] ?? []).map { FinanceRow(raw:$0) }
            summary = try evaluate("PortfolioApp.getSummary(PortfolioApp.computeHoldings())").toDictionary() as? [String:Any] ?? [:]
            loadShares()
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
    // MARK: Shared accounts
    /// What a shared account shows at a level: the balance, then holdings,
    /// then transactions. Nothing else about the account or Finance is in it.
    func accountView(_ accountID: String, level: String) -> [String:Any]? {
        guard let account = rows("accounts").first(where: { $0.id == accountID }) else { return nil }
        let summary = accountSummary(accountID)
        func number(_ key: String) -> Double { (summary[key] as? NSNumber)?.doubleValue ?? 0 }
        var view: [String:Any] = ["id":accountID, "name":account.name, "type":account.text("type"), "value":number("totalValue"), "cash":number("cash"), "level":level,
                                  "updatedAt":ISO8601DateFormatter().string(from:Date())]
        if level != "balance" {
            view["holdings"] = scopedHoldings(accountID).filter { $0.number("totalShares") > 0 }.map { h -> [String:Any] in
                ["ticker":h.text("ticker"), "display":displayTicker(h.text("ticker")), "shares":h.number("totalShares"), "price":h.number("currentPrice"), "value":h.number("currentValue")]
            }
        }
        if level == "transactions" {
            view["transactions"] = rows("transactions").filter { $0.text("accountId") == accountID }.sorted { $0.text("date") > $1.text("date") }.prefix(1000).map { t -> [String:Any] in
                ["date":t.text("date"), "type":t.text("type"), "ticker":t.text("ticker"), "display":displayTicker(t.text("ticker")), "quantity":t.number("quantity"), "price":t.number("pricePerShare")]
            }
        }
        return view
    }
    /// The parts of a view that matter when deciding to republish: prices move
    /// all day, so they alone republish at most once an hour.
    private static func shape(_ view: [String:Any]) -> String {
        var copy = view.filter { !$0.key.hasPrefix("_sync") && !["updatedAt", "value", "cash"].contains($0.key) }
        copy["holdings"] = (view["holdings"] as? [[String:Any]])?.map { $0.filter { !["price", "value"].contains($0.key) } }
        return (try? jsonString(copy)) ?? ""
    }
    private func loadShares() {
        guard let shares, authorized() else { sharedAccounts = []; return }
        var theirs: [SharedAccount] = []
        for info in shares.shares() where info.kind == "account" && info.ready {
            guard let store = try? shares.store(info.id) else { continue }
            let current = (try? store.records("accountViews", entity:info.entity))?.first
            if !info.owner {
                if let current { theirs.append(SharedAccount(info:info, view:current)) }
                continue
            }
            // Your own shared account: keep its view up to date.
            guard let view = accountView(info.entity, level:info.level) else { continue }
            if let current, Self.shape(current) == Self.shape(view),
               let updated = (current["updatedAt"] as? String).flatMap(ISO8601DateFormatter().date), Date().timeIntervalSince(updated) < 3600 { continue }
            var record = view
            if let current { record["_syncHeads"] = current["_syncAllHeads"]; record["_syncEntity"] = info.entity }
            _ = try? store.save(kind:"accountViews", record:record)
        }
        sharedAccounts = theirs.sorted { $0.info.title.localizedCaseInsensitiveCompare($1.info.title) == .orderedAscending }
    }
    /// This device's price for a ticker, to value someone else's holdings.
    func price(_ ticker: String) -> Double? { ((prices[ticker] as? [String:Any])?["price"] as? NSNumber)?.doubleValue }
    func rows(_ field: String, bank: Bool = false) -> [FinanceRow] { ((bank ? spending : portfolio)[field] as? [[String:Any]] ?? []).map { FinanceRow(raw:$0) } }
    var snapshots: [FinanceRow] { (history["snapshots"] as? [[String:Any]] ?? []).map { FinanceRow(raw:$0) }.sorted { $0.id < $1.id } }
    var fullyPriced: Bool { holdings.allSatisfy { $0.number("currentPrice") > 0 } }
    func money(_ amount: Double) -> String { amount.formatted(.currency(code:"USD")) }
    func total(_ key: String) -> Double { (summary[key] as? NSNumber)?.doubleValue ?? 0 }
    /// Views ask for these on every redraw, so each is calculated once per reload.
    func scopedHoldings(_ account: String) -> [FinanceRow] {
        if let cached = holdingsCache[account] { return cached }
        let rows = (try? evaluate("PortfolioApp.computeHoldings(input)",input:account).toArray() as? [[String:Any]])?.map { FinanceRow(raw:$0) } ?? []
        holdingsCache[account] = rows; return rows
    }
    /// Value, cash, day change and gain/loss for one account, with the same calculation as the totals.
    func accountSummary(_ account: String) -> [String:Any] {
        if let cached = summaryCache[account] { return cached }
        let value = (try? evaluate("PortfolioApp.getSummary(PortfolioApp.computeHoldings(input),input)",input:account).toDictionary() as? [String:Any]) ?? [:]
        summaryCache[account] = value; return value
    }
    func strategyReport(_ row: FinanceRow) -> [String:Any] {
        (try? evaluate("PortfolioStrategy.evaluate(input)",input:row.raw).toDictionary() as? [String:Any]) ?? [:]
    }
    func spendingSummary(_ month: String) -> [String:Any] {
        (try? evaluate("SpendingApp.summary(input)",input:month).toDictionary() as? [String:Any]) ?? [:]
    }
    func spendingCategory(_ row: FinanceRow) -> String {
        (try? evaluate("SpendingApp.categoryLabel(SpendingApp.categoryOf(input,SpendingApp.rulesByKey(SpendingApp.data.rules)))",input:row.raw).toString()) ?? row.text("category")
    }
    func categoryID(_ row: FinanceRow) -> String {
        (try? evaluate("SpendingApp.categoryOf(input,SpendingApp.rulesByKey(SpendingApp.data.rules))",input:row.raw).toString()) ?? "OTHER"
    }
    var categories: [String:String] { (try? evaluate("SpendingApp.CATEGORIES").toDictionary() as? [String:String]) ?? [:] }
    @discardableResult func setCategory(_ row: FinanceRow, category: String, allFromMerchant: Bool) -> Bool {
        do {
            try checkAccess(); reload()
            try evaluate("SpendingApp.setCategory(input.id,input.category,{allFromMerchant:input.all})",input:["id":row.id,"category":category,"all":allFromMerchant])
            let blob = try evaluate("financeData.spending").toDictionary() ?? [:]
            _ = try store.setKey("app_spending",value:blob); reload(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func checkAccess() throws { if !authorized() { throw NotebookError.message("Unlock Notebook to continue.") } }
    @discardableResult func save(_ row: FinanceRow, field: String, bank: Bool = false) -> Bool {
        do {
            try checkAccess(); reload()
            var record = row.raw
            let stamp = ISO8601DateFormatter().string(from:Date())
            if record["id"] == nil { record["id"] = UUID().uuidString.lowercased(); record["createdAt"] = stamp }
            record["updatedAt"] = stamp
            var blob = bank ? spending : portfolio
            var records = blob[field] as? [[String:Any]] ?? []
            if let i = records.firstIndex(where: { $0["id"] as? String == record["id"] as? String }) { records[i] = record } else { records.append(record) }
            blob[field] = records
            _ = try store.setKey(bank ? "app_spending" : "app_portfolio",value:blob)
            reload(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func saveTransaction(_ row: FinanceRow, deleting: Bool = false) -> Bool {
        do {
            try checkAccess(); reload()
            var record = row.raw
            let stamp = ISO8601DateFormatter().string(from:Date())
            if record["id"] == nil { record["id"] = UUID().uuidString.lowercased(); record["createdAt"] = stamp }
            record["updatedAt"] = stamp
            let script = """
            (()=>{
                const row=input.row, old=PortfolioApp.transactions.find(t=>t.id===row.id);
                if (!input.deleting && !PortfolioApp.accounts.some(a=>a.id===row.accountId)) throw new Error("This account is no longer available. Choose another account.");
                if (old) PortfolioApp.adjustCash(old.accountId, old.type, -PortfolioApp.txnAmount(old));
                PortfolioApp.transactions=PortfolioApp.transactions.filter(t=>t.id!==row.id);
                if(input.deleting) PortfolioApp._tombstone(row.id);
                else { PortfolioApp.transactions.push(row); PortfolioApp.adjustCash(row.accountId,row.type,PortfolioApp.txnAmount(row)); }
                return {...financeData.portfolio,accounts:PortfolioApp.accounts,transactions:PortfolioApp.transactions,tombstones:PortfolioApp.tombstones};
            })()
            """
            guard let blob = try evaluate(script,input:["row":record,"deleting":deleting]).toDictionary() as? [String:Any] else { throw NotebookError.message("Transaction could not be saved.") }
            _ = try store.setKey("app_portfolio",value:blob); reload(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func delete(_ row: FinanceRow, field: String) {
        do {
            try checkAccess(); reload()
            if field == "transactions" { _ = saveTransaction(row,deleting:true); return }
            var blob = field == "snapshots" ? history : portfolio
            var tombstones = blob["tombstones"] as? [String:String] ?? [:]
            let stamp = ISO8601DateFormatter().string(from:Date()); tombstones[row.id] = stamp
            blob[field] = (blob[field] as? [[String:Any]] ?? []).filter { ($0["id"] as? String ?? $0["date"] as? String) != row.id }
            if field == "accounts" {
                let transactions = blob["transactions"] as? [[String:Any]] ?? []
                for txn in transactions where txn["accountId"] as? String == row.id { if let id = txn["id"] as? String { tombstones[id] = stamp } }
                blob["transactions"] = transactions.filter { $0["accountId"] as? String != row.id }
            }
            blob["tombstones"] = tombstones
            _ = try store.setKey(field == "snapshots" ? "app_portfolio-history" : "app_portfolio",value:blob); reload()
            // A deleted account stops being shared.
            if field == "accounts" { NotificationCenter.default.post(name:.notebookAccountDeleted, object:row.id) }
        } catch { self.error = error.localizedDescription }
    }
    func parseImport(_ data: Data) throws -> [String:Any] {
        try checkAccess()
        guard data.count <= 64 * 1024 * 1024, let text = String(data:data,encoding:.utf8) else { throw NotebookError.message("Choose a Finance JSON export smaller than 64 MB.") }
        let parsed = try evaluate("FinanceTransfer.parse(input)",input:text).toDictionary() as? [String:Any] ?? [:]
        if let error = parsed["error"] as? String { throw NotebookError.message(error) }
        return parsed
    }
    func importSummary(_ file: [String:Any]) -> String { (try? evaluate("FinanceTransfer.summary(FinanceTransfer.counts(input))",input:file).toString()) ?? "Finance records" }
    func applyImport(_ file: [String:Any]) {
        do {
            try checkAccess(); reload()
            let script = """
            (()=>{const m=FinanceTransfer.plan(input,{portfolio:financeData.portfolio,history:financeData['portfolio-history'],spending:financeData.spending});
            for(const [a,t] of [[m.portfolio.accounts,m.portfolio.transactions],[m.spending.accounts,m.spending.transactions]]) {
                const ids=new Set(a.map(r=>r.id)); if(t.some(r=>!ids.has(r.accountId))) throw new Error('A transaction refers to a missing account. Nothing was imported.');
            } return m;})()
            """
            guard let merged = try evaluate(script,input:file).toDictionary() as? [String:Any] else { throw NotebookError.message("Could not merge Finance data.") }
            try store.setFinance(["app_portfolio":merged["portfolio"]!,"app_portfolio-history":merged["history"]!,"app_spending":merged["spending"]!])
            notice = try evaluate("FinanceTransfer.sentence(input)",input:merged["report"]!).toString(); reload()
        } catch { self.error = error.localizedDescription }
    }
    func exportDocument() throws -> FinanceDocument {
        try checkAccess(); reload()
        let json = try evaluate("JSON.stringify(FinanceTransfer.build({portfolio:financeData.portfolio,history:financeData['portfolio-history'],spending:financeData.spending}),null,2)").toString() ?? ""
        return FinanceDocument(data:Data(json.utf8))
    }
    func takeSnapshot() {
        do {
            try checkAccess(); reload()
            guard try evaluate("PortfolioApp.recordSnapshot()").toBool() else { throw NotebookError.message("Refresh prices for all holdings before taking a snapshot.") }
            let value = try evaluate("financeData['portfolio-history']").toDictionary() ?? [:]
            _ = try store.setKey("app_portfolio-history",value:value); reload(); notice = "Snapshot saved"
        } catch { self.error = error.localizedDescription }
    }
    // MARK: Ticker detail, from the same calculations as the JS ticker page.
    /// This ticker's position in each account; each row carries its account under "account".
    func tickerByAccount(_ ticker: String) -> [FinanceRow] {
        (try? evaluate("PortfolioApp.computeHoldingsForTickerByAccount(input)",input:ticker).toArray() as? [[String:Any]])?.map { FinanceRow(raw:$0) } ?? []
    }
    func tickerTransactions(_ ticker: String) -> [FinanceRow] {
        (try? evaluate("PortfolioApp.getTickerTransactions(input)",input:ticker).toArray() as? [[String:Any]])?.map { FinanceRow(raw:$0) } ?? []
    }
    /// The position's value in each saved snapshot, oldest first.
    func tickerHistory(_ ticker: String) -> [(date: String, value: Double)] {
        ((try? evaluate("PortfolioApp.getTickerHistory(input)",input:ticker).toArray() as? [[String:Any]]) ?? [])
            .compactMap { row in guard let date = row["date"] as? String, let value = (row["value"] as? NSNumber)?.doubleValue else { return nil }; return (date, value) }
    }
    /// An option contract's underlying, strike, expiration and type, or nil for a stock.
    func optionMeta(_ ticker: String) -> [String:Any]? {
        guard let value = try? evaluate("PortfolioApp.optionMeta(input)",input:ticker), value.isObject else { return nil }
        return value.toDictionary() as? [String:Any]
    }
    func displayTicker(_ ticker: String) -> String { (try? evaluate("PortfolioApp.displayTicker(input)",input:ticker).toString()) ?? ticker }
    func cachedQuote(_ ticker: String) -> [String:Any]? { prices[ticker] as? [String:Any] }
    /// A quote for one ticker that isn't held any more (or was just added).
    func ensureQuote(_ ticker: String) async {
        if let cached = prices[ticker] as? [String:Any], let updated = (cached["updatedAt"] as? NSNumber)?.doubleValue, Date().timeIntervalSince1970*1000 - updated < 5*60*1000 { return }
        if robinhood?.connected == true, optionMeta(ticker) == nil, let q = await robinhood?.stockQuotes([ticker])[ticker],
           let change = q.dayChange(known:nil) {
            prices[ticker] = ["price":q.price, "change":change, "changePercent":q.price - change > 0 ? change / (q.price - change) * 100 : 0, "previousClose":q.price - change,
                              "sessionDay":q.tradeDay, "updatedAt":Date().timeIntervalSince1970 * 1000, "source":"robinhood"]
            try? jsonData(prices).write(to:cacheURL,options:.atomic); reload(); return
        }
        guard authorized(), let quote = await Self.quote(ticker) else { return }
        prices[ticker] = quote
        try? jsonData(prices).write(to:cacheURL,options:.atomic)
        reload()
    }
    private var historyCache: [String:[(date: Date, price: Double)]] = [:]
    func cachedPriceHistory(_ ticker: String, range: String) -> [(date: Date, price: Double)] { historyCache[ticker + "|" + range] ?? [] }
    /// Market price history from Yahoo's chart endpoint; ranges match the JS page.
    func priceHistory(_ ticker: String, range: String) async -> [(date: Date, price: Double)] {
        let key = ticker + "|" + range
        if let cached = historyCache[key] { return cached }
        let config = ["1m":("1mo","1d"), "3m":("3mo","1d"), "1y":("1y","1d"), "5y":("5y","1wk"), "max":("max","1mo")][range] ?? ("1y","1d")
        guard let encoded = ticker.replacingOccurrences(of:".",with:"-").addingPercentEncoding(withAllowedCharacters:.urlPathAllowed),
              let url = URL(string:"https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=\(config.1)&range=\(config.0)"),
              let (data,response) = try? await URLSession.shared.data(from:url), (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let chart = root["chart"] as? [String:Any],
              let result = (chart["result"] as? [[String:Any]])?.first, let stamps = result["timestamp"] as? [NSNumber],
              let closes = ((result["indicators"] as? [String:Any])?["quote"] as? [[String:Any]])?.first?["close"] as? [Any] else { return [] }
        let points = zip(stamps, closes).compactMap { stamp, close -> (date: Date, price: Double)? in
            guard let price = (close as? NSNumber)?.doubleValue, price.isFinite else { return nil }
            return (Date(timeIntervalSince1970:stamp.doubleValue), price)
        }
        if points.count >= 2 { historyCache[key] = points }
        return points.count >= 2 ? points : []
    }
    private var companyCache: [String:[String:Any]] = [:]
    func cachedCompanyInfo(_ ticker: String) -> [String:Any]? { companyCache[ticker].flatMap { $0.isEmpty ? nil : $0 } }
    /// Yahoo's company profile (name, sector, industry, description, website),
    /// key numbers (market cap, P/E, 52-week range, dividend yield), the next
    /// earnings date and the analysts' consensus.
    /// It needs a session cookie and crumb, like the Electron app's main process.
    func companyInfo(_ ticker: String) async -> [String:Any]? {
        if let cached = companyCache[ticker] { return cached.isEmpty ? nil : cached }
        guard let info = await Self.fetchCompanyInfo(ticker) else { return nil }
        companyCache[ticker] = info
        return info
    }
    /// The same, fetched fresh: also for the agent, which has no Finance screen.
    static func fetchCompanyInfo(_ ticker: String) async -> [String:Any]? {
        let session = URLSession(configuration:.ephemeral)
        let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
        func get(_ string: String) async -> Data? {
            guard let url = URL(string:string) else { return nil }
            var request = URLRequest(url:url); request.setValue(agent, forHTTPHeaderField:"User-Agent"); request.timeoutInterval = 12
            guard let (data,response) = try? await session.data(for:request) else { return nil }
            return (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil
        }
        _ = await get("https://fc.yahoo.com/")
        guard let crumbData = await get("https://query2.finance.yahoo.com/v1/test/getcrumb"), let crumb = String(data:crumbData, encoding:.utf8), !crumb.isEmpty,
              let symbol = ticker.replacingOccurrences(of:".",with:"-").addingPercentEncoding(withAllowedCharacters:.urlPathAllowed),
              let data = await get("https://query2.finance.yahoo.com/v10/finance/quoteSummary/\(symbol)?modules=assetProfile,quoteType,summaryDetail,financialData,calendarEvents&crumb=\(crumb.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed) ?? crumb)"),
              let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let result = ((root["quoteSummary"] as? [String:Any])?["result"] as? [[String:Any]])?.first else { return nil }
        let profile = result["assetProfile"] as? [String:Any] ?? [:], type = result["quoteType"] as? [String:Any] ?? [:]
        var info: [String:Any] = ["name":type["longName"] as? String ?? type["shortName"] as? String ?? ticker]
        for (key, value) in [("sector",profile["sector"]), ("industry",profile["industry"]), ("description",profile["longBusinessSummary"]), ("website",profile["website"]), ("country",profile["country"]), ("employees",profile["fullTimeEmployees"])] { if let value { info[key] = value } }
        // Numbers come as {"raw": 123.4, "fmt": "123.40"}.
        func raw(_ module: String, _ key: String) -> NSNumber? { ((result[module] as? [String:Any])?[key] as? [String:Any])?["raw"] as? NSNumber }
        for (key, module, field) in [("marketCap","summaryDetail","marketCap"), ("pe","summaryDetail","trailingPE"), ("forwardPE","summaryDetail","forwardPE"),
                                     ("low52","summaryDetail","fiftyTwoWeekLow"), ("high52","summaryDetail","fiftyTwoWeekHigh"), ("dividendYield","summaryDetail","dividendYield"),
                                     ("analystMean","financialData","recommendationMean"), ("targetPrice","financialData","targetMeanPrice"), ("analysts","financialData","numberOfAnalystOpinions")] {
            if let value = raw(module, field) { info[key] = value }
        }
        if let key = (result["financialData"] as? [String:Any])?["recommendationKey"] as? String, key != "none" { info["analyst"] = key }
        if let next = (((result["calendarEvents"] as? [String:Any])?["earnings"] as? [String:Any])?["earningsDate"] as? [[String:Any]])?.first?["raw"] as? NSNumber { info["earnings"] = next }
        return info
    }
    /// Holdings that need a quote: none yet, or older than five minutes (the
    /// Electron app's cache lifetime). Expired options are skipped, since
    /// Yahoo stops quoting them; their last price stands.
    private var staleSymbols: [String] {
        let now = Date().timeIntervalSince1970*1000
        let day = Calendar.current.dateComponents([.year,.month,.day], from:Date())
        let today = String(format:"%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return holdings.filter { row in
            guard row.number("totalShares") > 0 else { return false }
            if let option = row.raw["option"] as? [String:Any], let expiration = option["expiration"] as? String, expiration < today { return false }
            guard let cached = prices[row.text("ticker")] as? [String:Any], let updated = (cached["updatedAt"] as? NSNumber)?.doubleValue else { return true }
            return now - updated > 5*60*1000
        }.map { $0.text("ticker") }
    }
    private var lastAutomaticRefresh = Date.distantPast
    /// Called while Finance is on screen. Without it the cache starts empty
    /// and holdings count as $0 until someone presses Refresh. Runs at most
    /// once a minute so an unpriceable symbol can't cause constant fetching.
    func refreshIfStale() async {
        if robinhood?.connected == true, Date().timeIntervalSince(lastLive) >= 14 { await refreshLive() }
        if !staleSymbols.isEmpty, Date().timeIntervalSince(lastAutomaticRefresh) > 60 {
            lastAutomaticRefresh = Date()
            await refreshPrices(quiet:true)
        }
        recordDailySnapshot()
    }
    private var lastAutomaticSnapshot = Date.distantPast
    /// Keeps today's snapshot current while Finance is open, like the Electron
    /// app did: one per day, rewritten at most every 30 minutes so price
    /// refreshes don't sync a new copy of the history to every device.
    private func recordDailySnapshot(force: Bool = false) {
        let day = Calendar.current.dateComponents([.year,.month,.day], from:Date())
        let today = String(format:"%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        guard authorized(), fullyPriced, force || !snapshots.contains(where: { $0.id == today }) || Date().timeIntervalSince(lastAutomaticSnapshot) > 30*60 else { return }
        lastAutomaticSnapshot = Date()
        do {
            reload()
            guard try evaluate("PortfolioApp.recordSnapshot()").toBool() else { return }
            _ = try store.setKey("app_portfolio-history",value:try evaluate("financeData['portfolio-history']").toDictionary() ?? [:]); reload()
        } catch { self.error = error.localizedDescription }
    }
    /// Value over time from the saved snapshots, oldest first: an account's
    /// value and cash, or with no account, everything but property (the
    /// figure Finance shows as the total). Days an account is missing are skipped.
    func valueHistory(_ account: String? = nil) -> [(date: Date, value: Double)] {
        snapshots.compactMap { row in
            guard let date = ISO8601DateFormatter().date(from:row.id + "T12:00:00Z") else { return nil }
            if let account {
                guard let value = ((row.raw["accounts"] as? [String:Any])?[account] as? [String:Any])?["value"] as? NSNumber else { return nil }
                return (date, value.doubleValue)
            }
            return (date, row.number("totalValue") - row.number("realEstateValue"))
        }
    }
    private var lastLive = Date.distantPast
    /// Real-time regular-session quotes from Robinhood for every holding it
    /// knows, stocks and options. They count as fresh, so Yahoo is only asked
    /// for what Robinhood didn't answer. Run every 15 seconds while Finance is open.
    func refreshLive() async {
        guard let robinhood, robinhood.connected, authorized() else { return }
        lastLive = Date()
        let day = Calendar.current.dateComponents([.year,.month,.day], from:Date())
        let today = String(format:"%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let held = Array(Set(holdings.filter { row in
            guard row.number("totalShares") > 0 else { return false }
            if let option = row.raw["option"] as? [String:Any], let expiration = option["expiration"] as? String, expiration < today { return false }
            return true
        }.map { $0.text("ticker") })).filter { !$0.isEmpty }
        let options = held.filter { optionMeta($0) != nil }, stocks = held.filter { optionMeta($0) == nil }
        async let stockQuotes = robinhood.stockQuotes(stocks)
        async let ids = robinhood.optionIDs(options)
        let (live, idMap) = await (stockQuotes, ids)
        let optionQuotes = await robinhood.optionQuotes(Array(idMap.values))
        guard authorized() else { return }
        let now = Date().timeIntervalSince1970 * 1000
        func entry(_ price: Double, previousClose: Double, day: String) -> [String:Any] {
            ["price":price, "change":price - previousClose, "changePercent":previousClose > 0 ? (price / previousClose - 1) * 100 : 0,
             "previousClose":previousClose, "sessionDay":day, "updatedAt":now, "source":"robinhood"]
        }
        var updated = 0
        for (symbol, q) in live {
            let old = prices[symbol] as? [String:Any]
            let known = (old?["sessionDay"] as? String).flatMap { day in (old?["previousClose"] as? NSNumber).map { (day:day, close:$0.doubleValue) } }
            guard let change = q.dayChange(known:known) else { continue }
            prices[symbol] = entry(q.price, previousClose:q.price - change, day:q.tradeDay); updated += 1
        }
        // Options: the middle of the bid and ask, against the last price of the day before.
        let session = TradingModel.day.string(from:Date())
        for (symbol, id) in idMap {
            guard let q = optionQuotes[id] else { continue }
            let mark = q.bid > 0 && q.ask >= q.bid ? (q.bid + q.ask) / 2 : q.last
            guard mark > 0 else { continue }
            let old = prices[symbol] as? [String:Any], oldPrice = (old?["price"] as? NSNumber)?.doubleValue
            let previous = old?["sessionDay"] as? String == session ? (old?["previousClose"] as? NSNumber)?.doubleValue : (old?["previousClose"] == nil ? oldPrice.map { $0 - ((old?["change"] as? NSNumber)?.doubleValue ?? 0) } : oldPrice)
            prices[symbol] = entry(mark, previousClose:previous ?? mark, day:session); updated += 1
        }
        guard updated > 0 else { return }
        try? jsonData(prices).write(to:cacheURL, options:.atomic)
        reload()
    }
    func refreshPrices(quiet: Bool = false) async {
        guard !refreshing, authorized() else { return }
        refreshing = true; defer { refreshing = false }
        if robinhood?.connected == true { await refreshLive() }
        // Holdings Robinhood just priced keep that quote.
        let live = Date().timeIntervalSince1970 * 1000 - 60 * 1000
        let symbols = Array(Set(holdings.filter { $0.number("totalShares") > 0 }.map { $0.text("ticker") })).filter { symbol in
            guard !symbol.isEmpty else { return false }
            guard let entry = prices[symbol] as? [String:Any], entry["source"] as? String == "robinhood" else { return true }
            return ((entry["updatedAt"] as? NSNumber)?.doubleValue ?? 0) < live
        }
        let quotes = await withTaskGroup(of:(String,[String:Any]?).self) { group in
            for symbol in symbols { group.addTask { (symbol, await Self.quote(symbol)) } }
            var found: [String:[String:Any]] = [:]
            for await (symbol, quote) in group { if let quote { found[symbol] = quote } }
            return found
        }
        for (symbol, quote) in quotes { prices[symbol] = quote }
        guard authorized() else { return }
        do { try jsonData(prices).write(to:cacheURL,options:.atomic) } catch { self.error = error.localizedDescription }
        reload()
        let fetched = quotes.count
        if !quiet { recordDailySnapshot(force:true) }
        if !quiet || fetched < symbols.count {
            notice = symbols.isEmpty ? "No holdings to price" : fetched == symbols.count ? "Prices updated" : fetched == 0 ? "Couldn't get prices. Check your internet connection and try Refresh Prices." : "Updated \(fetched) of \(symbols.count) prices. Other holdings keep their last available quote."
        }
    }
    /// One Yahoo Finance chart quote, the same endpoint the Electron app used.
    nonisolated static func quote(_ symbol: String) async -> [String:Any]? {
        guard let encoded = symbol.replacingOccurrences(of:".",with:"-").addingPercentEncoding(withAllowedCharacters:.urlPathAllowed), let url = URL(string:"https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1d&range=1d") else { return nil }
        var request = URLRequest(url:url); request.timeoutInterval = 12
        guard let (data,response) = try? await URLSession.shared.data(for:request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let chart = root["chart"] as? [String:Any],
              let result = (chart["result"] as? [[String:Any]])?.first, let meta = result["meta"] as? [String:Any],
              let price = (meta["regularMarketPrice"] as? NSNumber)?.doubleValue, price > 0 else { return nil }
        let previous = (meta["chartPreviousClose"] as? NSNumber)?.doubleValue ?? (meta["previousClose"] as? NSNumber)?.doubleValue ?? price
        return ["price":price,"change":price-previous,"changePercent":previous > 0 ? (price-previous)/previous*100 : 0,"updatedAt":Date().timeIntervalSince1970*1000]
    }
}
