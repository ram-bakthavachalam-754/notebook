import SwiftUI
import Charts
import NotebookCore

private func money(_ value: Double) -> String { value.formatted(.currency(code:"USD")) }
private func signed(_ value: Double) -> String { (value > 0 ? "+" : "") + money(value) }
private func shares(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...8))) }

/// Opens a ticker page from a NavigationLink(value:) in Trading.
struct TickerLink: Hashable { let ticker: String }

/// One ticker, shared by Finance and Trading: who it is, the price and your
/// position, one chart (the market price, or your value), where you hold it
/// and what you did, key numbers, technicals, Trading's alerts and watchlist,
/// recent news, what the business is, and research links.
struct TickerDetail: View {
    @ObservedObject var finance: FinanceModel
    let ticker: String
    let openAccount: (String) -> Void
    /// Trading, when it's available (not in kid mode): technicals use its
    /// price history, and its alerts and watchlist show here.
    var trading: TradingModel?
    var openAlert: (String) -> Void
    @State private var candles: [Candle] = []
    @State private var headlines: [[String:String]] = []
    @State private var info: [String:Any]?
    @State private var loadingInfo = true
    @State private var range = "1y"
    @State private var mode = "price"
    @State private var points: [(date: Date, price: Double)] = []
    @State private var loadingChart = true
    @State private var tab = "accounts"
    @State private var aboutOpen = false
    @State private var sheet: FinanceSheet?
    private static let sites: [(String, (String) -> String)] = [
        ("Perplexity Finance", { "https://www.perplexity.ai/finance/\($0)" }),
        ("Robinhood", { "https://robinhood.com/stocks/\($0)" }),
        ("TradingView", { "https://www.tradingview.com/symbols/\($0)/" }),
        ("Yahoo Finance", { "https://finance.yahoo.com/quote/\($0.replacingOccurrences(of:".", with:"-"))" }),
        ("Finviz", { "https://finviz.com/quote.ashx?t=\($0.replacingOccurrences(of:".", with:"-"))" })
    ]
    init(finance: FinanceModel, ticker: String, openAccount: @escaping (String) -> Void, trading: TradingModel? = nil, openAlert: @escaping (String) -> Void = { _ in }) {
        self.finance = finance; self.ticker = ticker; self.openAccount = openAccount; self.trading = trading; self.openAlert = openAlert
        // Revisiting a ticker shows what was already fetched right away.
        let info = finance.cachedCompanyInfo(ticker)
        _info = State(initialValue:info); _loadingInfo = State(initialValue:info == nil)
        _candles = State(initialValue:trading?.pages[ticker]?.candles ?? []); _headlines = State(initialValue:trading?.pages[ticker]?.headlines ?? [])
        let points = finance.cachedPriceHistory(ticker, range:"1y")
        _points = State(initialValue:points); _loadingChart = State(initialValue:points.isEmpty)
    }
    var body: some View {
        ScrollView { page }
            .backBar()
            .navigationTitle(finance.displayTicker(ticker))
            .sheet(item:$sheet) { item in
                if case .transaction(let row) = item { TransactionEditor(finance:finance, row:row) }
            }
            .task { await finance.ensureQuote(ticker) }
            .task {
                guard finance.optionMeta(ticker) == nil else { loadingInfo = false; return }
                info = await finance.companyInfo(ticker); loadingInfo = false
                guard headlines.isEmpty else { return }
                headlines = await TradingModel.headlines(ticker, name:info?["name"] as? String ?? ticker)
                trading?.pages[ticker, default:([], [])].headlines = headlines
            }
            .task {
                guard finance.optionMeta(ticker) == nil, candles.isEmpty else { return }
                if let trading { candles = await trading.candles(ticker); trading.pages[ticker, default:([], [])].candles = candles }
                else { candles = await YahooFinance.candles(ticker) }
            }
            .task(id:range) {
                let cached = finance.cachedPriceHistory(ticker, range:range)
                if !cached.isEmpty { points = cached; loadingChart = false; return }
                loadingChart = true
                points = await finance.priceHistory(ticker, range:range)
                loadingChart = false
            }
    }
    /// The page itself, without scrolling (also drawn to an image when checking the layout).
    var page: some View {
        let option = finance.optionMeta(ticker)
        let holding = finance.holdings.first { $0.text("ticker") == ticker }
        let quote = finance.cachedQuote(ticker)
        let byAccount = finance.tickerByAccount(ticker)
        let transactions = finance.tickerTransactions(ticker)
        let history = finance.tickerHistory(ticker)
        return VStack(alignment:.leading, spacing:22) {
                VStack(alignment:.leading, spacing:6) {
                    HStack(spacing:12) {
                        Monogram(text:option?["underlying"] as? String ?? ticker, tint:Monogram.tint(for:option?["underlying"] as? String ?? ticker), size:40)
                        VStack(alignment:.leading, spacing:2) {
                            Text(finance.displayTicker(ticker)).font(MacStyle.titleFont)
                            lede(option).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 6)
                    masthead(holding:holding, quote:quote)
                }
                chart(history:holding == nil ? [] : history)
                positions(byAccount:byAccount, transactions:transactions)
                if option == nil {
                    HStack(alignment:.top, spacing:16) { keyNumbers; technicals }
                    if let trading { TickerTrading(trading:trading, ticker:ticker, openAlert:openAlert).card() }
                    news
                    about
                }
                HStack(spacing:6) {
                    Text("Open in").foregroundStyle(.secondary)
                    ForEach(Self.sites, id:\.0) { site in
                        if let url = URL(string:site.1((option?["underlying"] as? String ?? ticker).addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? ticker)) {
                            Link(site.0, destination:url)
                            if site.0 != Self.sites.last?.0 { Text("·").foregroundStyle(.tertiary) }
                        }
                    }
                }
                .font(.callout)
            }
            .pageColumn(1000)
    }

    @ViewBuilder private func lede(_ option: [String:Any]?) -> some View {
        if let option {
            let expiration = option["expiration"] as? String ?? ""
            let parts = expiration.split(separator:"-").compactMap { Int($0) }
            let day = parts.count == 3 ? Calendar.current.date(from:DateComponents(year:parts[0], month:parts[1], day:parts[2])) : nil
            let days = day.flatMap { Calendar.current.dateComponents([.day], from:Calendar.current.startOfDay(for:Date()), to:$0).day } ?? 0
            let note = days < 0 ? "expired" : days == 0 ? "expires today" : "\(days) day\(days == 1 ? "" : "s") to expiration"
            Text([(option["optionType"] as? String == "put" ? "Put" : "Call") + " option on " + (option["underlying"] as? String ?? ""),
                  "strike " + money((option["strike"] as? NSNumber)?.doubleValue ?? 0), "expires " + expiration, note, "1 contract = 100 shares"].joined(separator:" · "))
        } else if loadingInfo {
            Text("Loading…")
        } else if let info {
            Text([info["name"] as? String, info["sector"] as? String].compactMap { $0 }.joined(separator:" · "))
        }
    }

    @ViewBuilder private func masthead(holding: FinanceRow?, quote: [String:Any]?) -> some View {
        let price = holding.map { $0.number("currentPrice") }.flatMap { $0 > 0 ? $0 : nil } ?? (quote?["price"] as? NSNumber)?.doubleValue ?? 0
        if price > 0 {
            let change = (quote?["change"] as? NSNumber)?.doubleValue
            let pct = (quote?["changePercent"] as? NSNumber)?.doubleValue ?? holding?.number("dayChangePercent") ?? 0
            Text(((holding?.raw["priceEstimated"] as? Bool ?? false) ? "~" : "") + money(price)).font(.system(size:40, weight:.semibold, design:.rounded)).monospacedDigit()
            Text("\(change.map { signed($0) + " " } ?? "")(\(abs(pct).formatted(.number.precision(.fractionLength(2))))%) today")
                .foregroundStyle(pct >= 0 ? .green : .red).font(.callout).monospacedDigit()
            if let holding {
                let total = finance.total("totalValue") - finance.total("realEstateValue")
                let weight = total > 0 ? holding.number("currentValue") / total * 100 : 0
                HStack(spacing:6) {
                    Text("You own \(shares(holding.number("totalShares"))) \(holding.number("totalShares") == 1 ? "share" : "shares"), worth \(money(holding.number("currentValue")))")
                    if holding.number("costBasis") > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(signed(holding.number("profitLoss"))) (\(abs(holding.number("profitLossPercent")).formatted(.number.precision(.fractionLength(1))))%) all time").foregroundStyle(holding.number("profitLoss") >= 0 ? .green : .red)
                    }
                    if total > 0 { Text("·").foregroundStyle(.tertiary); Text("\(weight.formatted(.number.precision(.fractionLength(1))))% of your portfolio") }
                }
                .font(.callout).monospacedDigit()
            }
        } else {
            Text("No price yet").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func chart(history: [(date: String, value: Double)]) -> some View {
        let canValue = history.count >= 2
        let showing = canValue ? mode : "price"
        VStack(alignment:.leading, spacing:10) {
            HStack {
                if canValue {
                    Picker("Chart", selection:$mode) { Text("Price").tag("price"); Text("Your value").tag("value") }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Spacer()
                if showing == "price" {
                    Picker("Range", selection:$range) { ForEach([("1m","1M"), ("3m","3M"), ("1y","1Y"), ("5y","5Y"), ("max","Max")], id:\.0) { Text($0.1).tag($0.0) } }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            Group {
                if showing == "value" {
                    let values = history.compactMap { row in (try? Date(row.date + "T12:00:00Z", strategy:.iso8601)).map { ($0, row.value) } }
                    lineChart(values.map { (date:$0.0, price:$0.1) })
                } else if loadingChart {
                    ProgressView().frame(maxWidth:.infinity, maxHeight:.infinity)
                } else if points.isEmpty {
                    Text("No price history available.").foregroundStyle(.secondary).frame(maxWidth:.infinity, maxHeight:.infinity)
                } else {
                    lineChart(points)
                }
            }
            .frame(height:220)
        }
        .card()
    }

    private func lineChart(_ data: [(date: Date, price: Double)]) -> some View {
        let up = (data.last?.price ?? 0) >= (data.first?.price ?? 0)
        let low = data.map(\.price).min() ?? 0, high = data.map(\.price).max() ?? 0
        let pad = max((high - low) * 0.08, 0.01)
        let tint = up ? Color.green : Color.red
        return Chart(data, id:\.date) { point in
            AreaMark(x:.value("Date", point.date), yStart:.value("Low", low - pad), yEnd:.value("Price", point.price))
                .foregroundStyle(LinearGradient(colors:[tint.opacity(0.2), tint.opacity(0)], startPoint:.top, endPoint:.bottom)).interpolationMethod(.monotone)
            LineMark(x:.value("Date", point.date), y:.value("Price", point.price)).foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth:2)).interpolationMethod(.monotone)
        }
        .chartYScale(domain:(low - pad)...(high + pad))
        .chartYAxis { AxisMarks(position:.trailing) { AxisGridLine(stroke:StrokeStyle(lineWidth:0.5, dash:[2, 3])); AxisValueLabel(format:.currency(code:"USD").precision(.fractionLength(0))) } }
    }

    @ViewBuilder private func positions(byAccount: [FinanceRow], transactions: [FinanceRow]) -> some View {
        if !byAccount.isEmpty || !transactions.isEmpty {
            let current = transactions.isEmpty ? "accounts" : tab
            VStack(alignment:.leading, spacing:10) {
                if !transactions.isEmpty {
                    Picker("Show", selection:$tab) { Text("Accounts").tag("accounts"); Text("Transactions").tag("transactions") }.pickerStyle(.segmented).labelsHidden().fixedSize()
                } else {
                    Text("Accounts").font(.headline)
                }
                if current == "accounts" {
                    Grid(alignment:.trailing, horizontalSpacing:18, verticalSpacing:8) {
                        GridRow { Text("Account").gridColumnAlignment(.leading); Text("Shares"); Text("Avg cost"); Text("Value"); Text("All time") }.font(.caption).foregroundStyle(.secondary)
                        Divider()
                        // Every row has the same ticker, so rows are identified by position,
                        // whatever form the account ids take.
                        ForEach(Array(byAccount.enumerated()), id:\.offset) { _, h in
                            let account = h.raw["account"] as? [String:Any] ?? [:]
                            GridRow {
                                Button { if let id = account["id"].map({ "\($0)" }) { openAccount(id) } } label: { Text(account["name"] as? String ?? "Account") }.buttonStyle(.link).gridColumnAlignment(.leading)
                                Text(shares(h.number("totalShares")))
                                Text(money(h.number("avgCostBasis"))).foregroundStyle(.secondary)
                                Text(h.number("currentPrice") > 0 ? money(h.number("currentValue")) : "—")
                                Text(h.number("currentPrice") > 0 ? signed(h.number("profitLoss")) : "—").foregroundStyle(h.number("currentPrice") == 0 ? Color.secondary : h.number("profitLoss") >= 0 ? .green : .red)
                            }
                            .monospacedDigit().lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal:false, vertical:true)
                } else {
                    let names = Dictionary(uniqueKeysWithValues:finance.rows("accounts").map { ($0.id, $0.name) })
                    ForEach(transactions) { t in
                        HStack(spacing:14) {
                            Text(String(t.text("date").prefix(10))).foregroundStyle(.secondary).monospacedDigit()
                            Text(t.text("type").capitalized).frame(width:60, alignment:.leading)
                            Text("\(shares(t.number("quantity"))) × \(money(t.number("pricePerShare")))").monospacedDigit()
                            Text(names[t.text("accountId")] ?? "").foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit") { sheet = .transaction(t) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            .card()
        }
    }

    @ViewBuilder private var about: some View {
        if let info {
            VStack(alignment:.leading, spacing:6) {
                Text("About").font(.headline)
                if let text = info["description"] as? String, !text.isEmpty {
                    Text(text).lineLimit(aboutOpen ? nil : 2).textSelection(.enabled)
                    Button(aboutOpen ? "Less" : "More") { aboutOpen.toggle() }.buttonStyle(.link)
                }
                let facts = [info["industry"] as? String, info["country"] as? String, (info["employees"] as? NSNumber).map { "\($0.intValue.formatted()) employees" }].compactMap { $0 }
                HStack(spacing:6) {
                    if !facts.isEmpty { Text(facts.joined(separator:" · ")).foregroundStyle(.secondary) }
                    if let site = info["website"] as? String, let url = URL(string:site), ["http","https"].contains(url.scheme ?? "") {
                        if !facts.isEmpty { Text("·").foregroundStyle(.tertiary) }
                        Link(site.replacingOccurrences(of:#"^https?://(www\.)?"#, with:"", options:.regularExpression).trimmingCharacters(in:CharacterSet(charactersIn:"/")), destination:url)
                    }
                }
                .font(.callout)
            }
            .card()
        }
    }

    private func number(_ key: String) -> Double? { (info?[key] as? NSNumber)?.doubleValue }
    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).monospacedDigit().textSelection(.enabled) }
    }
    /// $3.1T, $45.2B, $800M.
    private func big(_ value: Double) -> String {
        for (size, unit) in [(1e12, "T"), (1e9, "B"), (1e6, "M")] where value >= size { return "$" + (value / size).formatted(.number.precision(.fractionLength(1))) + unit }
        return money(value)
    }
    @ViewBuilder private var keyNumbers: some View {
        if info?["marketCap"] != nil || info?["pe"] != nil || info?["analyst"] != nil {
            VStack(alignment:.leading, spacing:8) {
                Text("Key numbers").font(.headline)
                Grid(alignment:.leading, horizontalSpacing:18, verticalSpacing:5) {
                    if let cap = number("marketCap") { row("Market cap", big(cap)) }
                    if let pe = number("pe") { row("P/E", pe.formatted(.number.precision(.fractionLength(1))) + (number("forwardPE").map { " · \($0.formatted(.number.precision(.fractionLength(1)))) expected" } ?? "")) }
                    if let low = number("low52"), let high = number("high52") { row("52-week range", money(low) + " – " + money(high)) }
                    if let yield = number("dividendYield"), yield > 0 { row("Dividend yield", (yield * 100).formatted(.number.precision(.fractionLength(2))) + "%") }
                    if let next = number("earnings") { row("Next earnings", Date(timeIntervalSince1970:next).formatted(date:.abbreviated, time:.omitted)) }
                    if let key = info?["analyst"] as? String {
                        let label = key.replacingOccurrences(of:"_", with:" ").capitalized
                        row("Analysts", label + (number("analysts").map { " (\(Int($0)) analysts)" } ?? "") + (number("targetPrice").map { ", average target " + money($0) } ?? ""))
                    }
                }
                .font(.callout)
            }
            .card()
        }
    }
    /// The same indicators and signal score Trading's research uses.
    @ViewBuilder private var technicals: some View {
        if let ind = TradingMath.indicators(candles) {
            let signals = TradingMath.signals(candles), score = TradingMath.score(signals)
            let fixed: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(2))) }
            VStack(alignment:.leading, spacing:8) {
                HStack(alignment:.firstTextBaseline) {
                    Text("Technicals").font(.headline)
                    Spacer()
                    Text("Signal score \(score > 0 ? "+" : "")\(score)" + (score >= 2 ? ", bullish" : score <= -2 ? ", bearish" : ", no clear signal"))
                        .font(.callout.weight(.medium)).foregroundStyle(score >= 2 ? .green : score <= -2 ? .red : .secondary)
                }
                Grid(alignment:.leading, horizontalSpacing:18, verticalSpacing:5) {
                    row("RSI (14)", ind.rsi14.formatted(.number.precision(.fractionLength(0))) + (ind.rsi14 >= 70 ? ", overbought" : ind.rsi14 <= 30 ? ", oversold" : ""))
                    row("MACD", fixed(ind.macd) + " vs signal " + fixed(ind.macdSignal) + (ind.macdHistogram >= 0 ? ", above" : ", below"))
                    row("20-day average", money(ind.sma20))
                    row("50-day average", money(ind.sma50) + (ind.price >= ind.sma50 ? ", price above" : ", price below"))
                    if let sma200 = ind.sma200 { row("200-day average", money(sma200) + (ind.price >= sma200 ? ", price above" : ", price below")) }
                    row("Bollinger bands", money(ind.bollingerLower) + " – " + money(ind.bollingerUpper))
                    row("Daily range (ATR)", money(ind.atr14))
                    row("Volume", (candles.last.map { TradingModel.compact($0.volume) + ", " } ?? "") + fixed(ind.volumeRatio) + "× the 20-day average of " + TradingModel.compact(ind.averageVolume))
                }
                .font(.callout)
                ForEach(signals, id:\.name) { Text("• " + $0.name).font(.callout) }
            }
            .card()
        }
    }
    @ViewBuilder private var news: some View {
        if !headlines.isEmpty {
            VStack(alignment:.leading, spacing:5) {
                Text("News").font(.headline)
                ForEach(headlines.prefix(8), id:\.self) { HeadlineLink(headline:$0, topic:ticker, notebook:trading?.notebookModel).padding(.vertical, 2) }
            }
            .card()
        }
    }
}

/// A headline that opens in the News reader (with its AI summary), or in the
/// browser when there's no reader to use (kid mode).
struct HeadlineLink: View {
    let headline: [String:String]
    let topic: String
    let notebook: NotebookModel?
    var body: some View {
        let story = NewsStory(headline:headline, topic:topic)
        let label = Text(story.title).font(.callout) + Text("  " + story.byline + (story.publishedAt.map { "  " + $0.formatted(.relative(presentation:.named)) } ?? "")).font(.caption).foregroundColor(.secondary)
        if let notebook {
            NavigationLink { NewsReader(news:notebook.news, agent:notebook.agent, story:story).backBar() } label: { label.multilineTextAlignment(.leading) }.buttonStyle(.link)
        } else if let url = URL(string:story.url) {
            Link(destination:url) { label }
        }
    }
}

/// Trading on a ticker page: watch it or not, and its alerts.
private struct TickerTrading: View {
    @ObservedObject var trading: TradingModel
    let ticker: String
    let openAlert: (String) -> Void
    var body: some View {
        let alerts = trading.ideas.filter { $0.ticker == ticker }, watching = trading.watchlist.contains(ticker)
        VStack(alignment:.leading, spacing:8) {
            HStack {
                Text("Trading").font(.headline)
                Spacer()
                Button(watching ? "Remove from Watchlist" : "Add to Watchlist") { watching ? trading.removeFromWatchlist(ticker) : trading.addToWatchlist(ticker) }
            }
            if alerts.isEmpty { Text(watching ? "On your watchlist. No alerts yet." : "No alerts. Add it to your watchlist to have it researched every trading morning.").font(.callout).foregroundStyle(.secondary) }
            ForEach(alerts) { idea in
                Button { openAlert(idea.id) } label: {
                    HStack {
                        Pill(text:idea.status, tint:idea.pending ? .orange : idea.realOpen ? .blue : .secondary)
                        Text(idea.action).font(.callout)
                        Spacer()
                        Text(idea.created.formatted(.dateTime.month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
