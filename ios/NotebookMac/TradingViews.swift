import SwiftUI
import Charts
import NotebookCore

private func money(_ value: Double) -> String { value.formatted(.currency(code:"USD")) }
private func signed(_ value: Double) -> String { (value > 0 ? "+" : "") + money(value) }
private func parsePrice(_ text: String) -> Double? { Double(text.replacingOccurrences(of:",", with:"").replacingOccurrences(of:"$", with:"").trimmingCharacters(in:.whitespaces)).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
let tradingOverview = "__overview__", tradingWatchlist = "__watchlist__"

/// The middle column: what to buy, what you hold, then past alerts.
struct TradingList: View {
    @ObservedObject var trading: TradingModel
    @Binding var selection: String?
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        let buy = trading.ideas.filter(\.pending), holding = trading.ideas.filter(\.realOpen), past = trading.ideas.filter { !$0.open }
        List(selection:$selection) {
            pageRow("Overview", detail:buy.isEmpty ? "Nothing to buy" : "\(buy.count) to buy", icon:"gauge.with.dots.needle.33percent").tag(tradingOverview)
            pageRow("Watchlist", detail:"\(trading.watchlist.count) stocks", icon:"eye").tag(tradingWatchlist)
            if !buy.isEmpty { Section("To Buy") { ForEach(buy) { IdeaRow(trading:trading, idea:$0).tag($0.id) } } }
            if !holding.isEmpty { Section("Holding") { ForEach(holding) { IdeaRow(trading:trading, idea:$0).tag($0.id) } } }
            if !past.isEmpty { Section("Past Alerts") { ForEach(past.prefix(60)) { IdeaRow(trading:trading, idea:$0).tag($0.id) } } }
        }
        // Rows in sections otherwise stay one line tall.
        .environment(\.defaultMinListRowHeight, 48)
        .navigationTitle("Trading")
        .navigationSubtitle(trading.researching ? trading.progress : "")
        .navigationSplitViewColumnWidth(min:260, ideal:300)
        .toolbar {
            Button { Task { await trading.research() } } label: { Label("Research Now", systemImage:"sparkle.magnifyingglass") }.disabled(trading.researching).help("Look for trade ideas now")
            Button { MacSettings.show("trading"); openSettings() } label: { Label("Trading Settings", systemImage:"slider.horizontal.3") }.help("Budget, risk rules, alerts and Robinhood")
        }
        // Quotes for the list while Trading is on screen, any time of day.
        .task { while !Task.isCancelled { await trading.refreshQuotes(Array(Set(trading.ideas.filter(\.open).flatMap(\.symbols) + trading.watchlist))); try? await Task.sleep(for:.seconds(120)) } }
    }
    private func pageRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing:10) {
            Image(systemName:icon).font(.system(size:13, weight:.medium)).foregroundStyle(.teal)
                .frame(width:28, height:28).background(Color.teal.opacity(0.12), in:RoundedRectangle(cornerRadius:8, style:.continuous))
            VStack(alignment:.leading, spacing:1) { Text(title).font(.system(.body, weight:.semibold)); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }
}

private struct IdeaRow: View {
    @ObservedObject var trading: TradingModel
    let idea: TradeIdea
    var body: some View {
        let result = idea.real.flatMap { idea.profit($0, at:trading.value(idea)) }
        HStack(alignment:.top, spacing:10) {
            Monogram(text:idea.ticker, tint:Monogram.tint(for:idea.ticker), size:28)
            VStack(alignment:.leading, spacing:2) {
                HStack(spacing:6) {
                    Text(idea.ticker).font(.system(.body, weight:.semibold))
                    Image(systemName:idea.bullish ? "arrow.up.right" : "arrow.down.right").font(.caption.weight(.bold)).foregroundStyle(idea.bullish ? .green : .red)
                    Pill(text:idea.status, tint:idea.pending ? .orange : idea.realOpen ? .blue : .secondary)
                }
                Text(idea.action).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(idea.created.formatted(.dateTime.month(.abbreviated).day())).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if let result { Text(signed(result)).monospacedDigit().foregroundStyle(result >= 0 ? .green : .red) }
        }
        .padding(.vertical, 3)
    }
}

/// Your trades at a glance, today's research and what was passed over.
struct TradingOverview: View {
    @ObservedObject var trading: TradingModel
    @ObservedObject var agent: AgentModel
    var body: some View { ScrollView { page } }
    /// The page without scrolling (also drawn to an image when checking the layout).
    var page: some View {
        let budget = trading.setting("budget"), record = trading.record, real = trading.realProfit, buy = trading.ideas.filter(\.pending).count
        return VStack(alignment:.leading, spacing:24) {
                PageHeader(title:"Trading", subtitle:"Alerts for what to buy, from price signals, earnings dates and headlines, sized by your risk rules. Tell Notebook when you buy, and it tells you when to sell.")
                LazyVGrid(columns:[GridItem(.adaptive(minimum:150), spacing:12)], spacing:12) {
                    StatTile(title:"To buy", value:buy == 0 ? "–" : "\(buy)", detail:buy == 0 ? "No alerts waiting" : "alert\(buy == 1 ? "" : "s") waiting", tint:buy == 0 ? .primary : .orange)
                    StatTile(title:"Profit", value:signed(real.closed + real.open), detail:"\(signed(real.closed)) closed · \(signed(real.open)) open", tint:real.closed + real.open == 0 ? .primary : .gain(real.closed + real.open))
                    StatTile(title:"Record", value:record.trades == 0 ? "–" : "\(record.wins) of \(record.trades)", detail:record.trades == 0 ? "No sold trades yet" : "trades made money")
                    StatTile(title:"Available", value:money(trading.available), detail:"of \(money(budget)), after waiting alerts")
                    StatTile(title:"Risk in use", value:money(trading.openRisk), detail:"of \(money(trading.riskLimit)) limit", tint:trading.riskRoom > 0 ? .primary : .orange)
                }
                VStack(alignment:.leading, spacing:12) {
                    HStack(spacing:8) {
                        Circle().fill(trading.marketHours ? Color.green : Color.secondary).frame(width:8, height:8)
                        Text(trading.marketHours ? "Market open" : "Market closed").font(.headline)
                        Spacer()
                        if trading.researching { ProgressView().controlSize(.small); Text(trading.progress).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                        Button { Task { await trading.research() } } label: { Label(trading.researching ? "Researching…" : "Research Now", systemImage:"sparkle.magnifyingglass") }
                            .buttonStyle(.borderedProminent).tint(.teal).disabled(trading.researching)
                    }
                    Text(status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false, vertical:true)
                    if !agent.canSummarize { Label("No AI model is set up, so only the strongest setups become ideas, without reading the news. Set one up in Agent Settings.", systemImage:"exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
                }
                .card()
                if !trading.notes.isEmpty {
                    SectionBlock("Last research") {
                        let quiet = trading.notes.filter { $0.text == "No clear signal." }.map(\.ticker)
                        VStack(alignment:.leading, spacing:0) {
                            ForEach(Array(trading.notes.filter { $0.text != "No clear signal." }.enumerated()), id:\.element.id) { index, note in
                                if index > 0 { Divider() }
                                HStack(alignment:.top, spacing:12) {
                                    NavigationLink(value:TickerLink(ticker:note.ticker)) {
                                        HStack(spacing:8) { Monogram(text:note.ticker, tint:Monogram.tint(for:note.ticker), size:24); Text(note.ticker).font(.callout.weight(.semibold)).foregroundStyle(.primary) }
                                    }
                                    .buttonStyle(.plain).frame(width:92, alignment:.leading).disabled(note.ticker.isEmpty)
                                    Text(note.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity, alignment:.leading)
                                }
                                .padding(.vertical, 9)
                            }
                            if !quiet.isEmpty { Divider(); Text("No clear signal: " + quiet.joined(separator:", ")).font(.callout).foregroundStyle(.tertiary).padding(.vertical, 9) }
                        }
                        .card(padding:16)
                    }
                }
                Text("Not investment advice. Ideas come from rules and your AI model, which can be wrong; options can lose everything you pay. \(trading.robinhood.connected ? "Stock and option quotes are real time from Robinhood." : "Stock quotes are near real time, option quotes about 15 minutes delayed (Yahoo Finance). Connect Robinhood in Settings → Trading for real-time quotes.") Check the price and the news before you trade.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .pageColumn()
    }
    private var status: String {
        let holding = trading.ideas.filter(\.realOpen).count
        var parts = [trading.marketHours ? "The market is open." : "The market is closed."]
        parts.append(holding == 0 ? "You're not holding any alerted trades." : "\(holding) trade\(holding == 1 ? "" : "s") you hold, checked every five minutes for when to sell.")
        parts.append("Research runs each trading day at 9:45 a.m. and 3:30 p.m. Eastern" + (TimeZone.current.secondsFromGMT() == TradingModel.newYork.secondsFromGMT() ? "" : " (\(TradingModel.researchTimesHere) your time)")
                     + (trading.lastResearch.map { "; last run " + $0.formatted(.relative(presentation:.named)) + "." } ?? "."))
        parts.append("Alerts need Notebook open and unlocked on this Mac.")
        parts.removeFirst() // The heading says whether the market is open.
        return parts.joined(separator:" ")
    }
    private func stat(_ title: String, _ value: String, detail: String, tint: Color) -> some View {
        VStack(alignment:.leading, spacing:4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size:26, weight:.semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(tint == .primary ? .secondary : tint).monospacedDigit()
        }
    }
}

/// Stocks to research every day, with today's price.
struct TradingWatchlist: View {
    @ObservedObject var trading: TradingModel
    @State private var adding = ""
    var body: some View {
        ScrollView {
            VStack(alignment:.leading, spacing:20) {
                PageHeader(title:"Watchlist", subtitle:"Researched twice each trading day, along with the stocks you hold in Finance" + (trading.flag("scan") ? " and a market scan." : "."))
                HStack(spacing:10) {
                    Image(systemName:"plus.magnifyingglass").foregroundStyle(.teal)
                    TextField("Add tickers, like AAPL, MSFT", text:$adding).textFieldStyle(.plain).onSubmit(add)
                    Button("Add", action:add).buttonStyle(.borderedProminent).tint(.teal).controlSize(.small).disabled(adding.trimmingCharacters(in:.whitespaces).isEmpty)
                }
                .card(padding:12)
                if trading.watchlist.isEmpty {
                    ContentUnavailableView("No stocks yet", systemImage:"eye", description:Text("Add the stocks you want ideas for.")).frame(maxWidth:.infinity).padding(.top, 30)
                } else {
                    VStack(spacing:0) {
                        ForEach(Array(trading.watchlist.enumerated()), id:\.element) { index, ticker in
                            if index > 0 { Divider() }
                            WatchlistRow(trading:trading, ticker:ticker)
                        }
                    }
                    .card(padding:16)
                }
            }
            .pageColumn()
        }
        .task { await trading.refreshQuotes(trading.watchlist) }
    }
    private func add() { trading.addToWatchlist(adding); adding = "" }
}

/// A watched stock: its name and today's price; it opens the ticker page.
private struct WatchlistRow: View {
    @ObservedObject var trading: TradingModel
    let ticker: String
    @State private var hovering = false
    var body: some View {
        HStack(spacing:10) {
            NavigationLink(value:TickerLink(ticker:ticker)) {
                HStack(spacing:10) {
                    Monogram(text:ticker, tint:Monogram.tint(for:ticker), size:30)
                    VStack(alignment:.leading, spacing:1) { Text(ticker).font(.system(.body, weight:.semibold)); Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength:8)
                    if let q = trading.quotes[ticker] {
                        VStack(alignment:.trailing, spacing:1) {
                            Text(money(q.price)).monospacedDigit()
                            Text(String(format:"%+.2f%%", q.changePercent)).font(.caption).foregroundStyle(q.changePercent >= 0 ? .green : .red).monospacedDigit()
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { trading.removeFromWatchlist(ticker) } label: { Image(systemName:"minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove from watchlist").opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 8)
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove", role:.destructive) { trading.removeFromWatchlist(ticker) } }
    }
    /// The company and how much it trades: "Apple · Vol 41M, avg 52M".
    private var caption: String {
        guard let q = trading.quotes[ticker] else { return "" }
        let volume = q.volume > 0 ? "Vol " + TradingModel.compact(q.volume) + (q.averageVolume > 0 ? ", avg " + TradingModel.compact(q.averageVolume) : "") : ""
        return [q.name, volume].filter { !$0.isEmpty }.joined(separator:" · ")
    }
}

/// One alert: what to do now, the plan, your trade, and why.
struct TradeIdeaDetail: View {
    @ObservedObject var trading: TradingModel
    let idea: TradeIdea
    @State private var candles: [Candle] = []
    @State private var buying = false
    @State private var selling = false
    @State private var deleting = false
    var body: some View {
        ScrollView { page }
        .toolbar { Button(role:.destructive) { deleting = true } label: { Label("Delete Alert", systemImage:"trash") }.help("Delete this alert and any trade you logged for it") }
        .confirmationDialog("Delete this alert?", isPresented:$deleting) { Button("Delete", role:.destructive) { trading.delete(idea) } } message: { Text(idea.real == nil ? "It leaves your list." : "Your logged trade leaves your profit and record too.") }
        .sheet(isPresented:$buying) { TradeEntry(title:"I bought this", quantity:String(Int(idea.number("quantity"))), price:String(format:"%.2f", trading.value(idea) ?? idea.number("unitCost")), unit:idea.isOption ? "Price per contract share (the quoted price)" : "Price per share", askQuantity:true) { q, p in trading.recordReal(idea, quantity:q, price:p) } }
        .sheet(isPresented:$selling) { TradeEntry(title:"I sold this", quantity:"", price:String(format:"%.2f", trading.value(idea) ?? 0), unit:idea.isOption ? "Price per contract share" : "Price per share", askQuantity:false) { _, p in trading.closeReal(idea, price:p) } }
        .task(id:idea.ticker) { candles = await YahooFinance.candles(idea.ticker) }
    }
    /// The page without scrolling (also drawn to an image when checking the layout).
    var page: some View {
        let value = trading.value(idea), underlying = trading.quotes[idea.ticker]?.price
        return VStack(alignment:.leading, spacing:22) {
                VStack(alignment:.leading, spacing:6) {
                    HStack(alignment:.firstTextBaseline) {
                        Text("\(idea.ticker) · \(idea.bullish ? "Bullish" : "Bearish") · \(idea.vehicleLabel)").font(MacStyle.titleFont)
                        Spacer()
                        NavigationLink(value:TickerLink(ticker:idea.ticker)) { Text("About \(idea.ticker)") }.buttonStyle(.link)
                    }
                    Text([idea.text("name"), idea.created.formatted(date:.abbreviated, time:.shortened), "\(idea.text("confidence").capitalized) confidence", "by " + idea.text("source")].joined(separator:" · ")).font(.callout).foregroundStyle(.secondary)
                    if !idea.text("summary").isEmpty { Text(idea.text("summary")).font(.title3).padding(.top, 4) }
                }
                todo(value:value)
                plan(value:value, underlying:underlying)
                chart
                lists
            }
            .pageColumn()
    }
    private func plan(value: Double?, underlying: Double?) -> some View {
        let quantity = idea.number("quantity"), unit = idea.number("unitCost"), cost = quantity * unit * idea.multiplier
        return VStack(alignment:.leading, spacing:8) {
            Text("The plan").font(.headline)
            Text(idea.action + " at about " + money(unit) + (idea.isOption ? " (\(money(unit * 100)) a contract)" : "")).font(.body.weight(.medium))
            Grid(alignment:.leading, horizontalSpacing:18, verticalSpacing:5) {
                row("Cost", money(cost) + (idea.isOption ? " — the most you can lose" : ""))
                if !idea.isOption { row("Loss if stopped out", money(quantity * (idea.number("price") - idea.number("stop")))) }
                row("\(idea.ticker) when alerted", money(idea.number("price")) + (underlying.map { " · now " + money($0) } ?? ""))
                if let average = TradingMath.indicators(candles)?.averageVolume { row("Average volume", TradingModel.compact(average) + " shares a day (20 days)") }
                if let cap = trading.quotes[idea.ticker]?.marketCap, cap > 0 { row("Market cap", "$" + TradingModel.compact(cap)) }
                row("Stop", money(idea.number("stop")) + " — \(idea.isOption ? "sell the option" : "sell") if \(idea.ticker) \(idea.bullish ? "falls" : "rises") to here")
                row("Target", money(idea.number("target")) + " — take profit if \(idea.ticker) gets here")
                row("Exit by", (TradingModel.day.date(from:idea.text("exitBy"))?.formatted(date:.abbreviated, time:.omitted) ?? idea.text("exitBy")) + (idea.isOption ? ", before expiration" : ""))
                if !idea.text("earnings").isEmpty { row("Earnings", idea.text("earnings")) }
                if !idea.text("foundBy").isEmpty { row("Found by", idea.text("foundBy")) }
                ForEach(Array(idea.legs.enumerated()), id:\.offset) { _, leg in
                    row(leg["side"] as? String == "sell" ? "Sell" : "Buy", "\(leg["symbol"] as? String ?? "") at " + money((leg["price"] as? NSNumber)?.doubleValue ?? 0) + (trading.quotes[leg["symbol"] as? String ?? ""].map { " · now " + money($0.mark) } ?? ""))
                }
            }
            .font(.callout)
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).monospacedDigit().textSelection(.enabled) }
    }
    @ViewBuilder private var chart: some View {
        let recent = Array(candles.suffix(90))
        if recent.count >= 2 {
            let lows = recent.map(\.close) + [idea.number("stop"), idea.number("target")]
            let low = lows.min()!, high = lows.max()!, pad = (high - low) * 0.06
            Chart {
                ForEach(recent, id:\.date) { c in LineMark(x:.value("Date", c.date), y:.value("Price", c.close)).interpolationMethod(.monotone) }
                RuleMark(y:.value("Stop", idea.number("stop"))).foregroundStyle(.red).lineStyle(StrokeStyle(lineWidth:1, dash:[4, 3])).annotation(position:.top, alignment:.leading) { Text("Stop").font(.caption2).foregroundStyle(.red) }
                RuleMark(y:.value("Target", idea.number("target"))).foregroundStyle(.green).lineStyle(StrokeStyle(lineWidth:1, dash:[4, 3])).annotation(position:.top, alignment:.leading) { Text("Target").font(.caption2).foregroundStyle(.green) }
                PointMark(x:.value("Date", idea.created), y:.value("Price", idea.number("price"))).foregroundStyle(.orange)
            }
            .chartYScale(domain:(low - pad)...(high + pad))
            .chartYAxis { AxisMarks(position:.trailing) { AxisGridLine(); AxisValueLabel(format:.currency(code:"USD").precision(.fractionLength(0))) } }
            .frame(height:200)
        }
    }
    /// What to do now: buy or skip, sell when told, or how it ended.
    @ViewBuilder private func todo(value: Double?) -> some View {
        VStack(alignment:.leading, spacing:10) {
            if idea.pending {
                Text("To do: \(idea.action)").font(.headline)
                Text("Buy at your broker if it still looks right, then tell Notebook so it can tell you when to sell. This alert ends if \(idea.ticker) reaches the stop or target first, or after two trading days.").font(.callout).foregroundStyle(.secondary)
                HStack { Button("I Bought This…") { buying = true }.buttonStyle(.borderedProminent); Button("Skip") { trading.pass(idea) } }
            } else if let real = idea.real {
                let quantity = (real["quantity"] as? NSNumber)?.doubleValue ?? 0, paid = (real["price"] as? NSNumber)?.doubleValue ?? 0, result = idea.profit(real, at:value)
                HStack {
                    Text(idea.realOpen ? "Holding: Notebook alerts you when to sell" : "Sold at " + money((real["closePrice"] as? NSNumber)?.doubleValue ?? 0)).font(.headline)
                    Spacer()
                    if let result { Text(signed(result)).font(.headline).monospacedDigit().foregroundStyle(result >= 0 ? .green : .red) }
                }
                Text("You bought \(quantity.formatted()) at \(money(paid))" + (idea.realOpen && value != nil ? "; now \(money(value!))." : ".")).font(.callout).monospacedDigit()
                if idea.realOpen { Button("I Sold This…") { selling = true } }
            } else {
                Text(["skipped":"You skipped this alert.", "stop":"Ended: \(idea.ticker) reached the stop before you bought.", "target":"Ended: \(idea.ticker) reached the target before you bought.",
                      "time":"Ended: its time ran out.", "stale":"Ended after two trading days without a buy."][idea.text("passed")] ?? "Ended.").font(.headline)
                Button("I Bought It Anyway…") { buying = true }
            }
        }
    }
    @ViewBuilder private var lists: some View {
        ForEach([("Why", "reasons"), ("Risks", "risks"), ("Signals", "signals")], id:\.1) { title, key in
            if !idea.strings(key).isEmpty {
                VStack(alignment:.leading, spacing:5) {
                    Text(title).font(.headline)
                    ForEach(idea.strings(key), id:\.self) { Text("• " + $0).font(.callout) }
                }
            }
        }
        if let headlines = idea.raw["headlines"] as? [[String:String]], !headlines.isEmpty {
            VStack(alignment:.leading, spacing:5) {
                Text("Headlines it read").font(.headline)
                ForEach(headlines, id:\.self) { HeadlineLink(headline:$0, topic:idea.ticker, notebook:trading.notebookModel) }
            }
        }
    }
}

/// How many and at what price, for a real buy or sell.
private struct TradeEntry: View {
    let title: String
    @State var quantity: String
    @State var price: String
    let unit: String
    let askQuantity: Bool
    let save: (Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    var body: some View {
        EditorSheet(title:title, width:420, height:askQuantity ? 260 : 220) {
            Section {
                if askQuantity { TextField("Quantity", text:$quantity) }
                TextField(unit, text:$price)
            } footer: { if let problem { Text(problem).foregroundStyle(.red) } }
        } actions: {
            Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { done() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
    }
    private func done() {
        let q = askQuantity ? Double(quantity.trimmingCharacters(in:.whitespaces)) : 1
        guard let q, q > 0 else { problem = "Enter how many you bought."; return }
        guard let p = parsePrice(price) else { problem = "Enter the price, like 4.20."; return }
        save(q, p); dismiss()
    }
}

/// Settings → Trading: the budget, risk rules, ideas, alerts and the
/// Robinhood connection. Each change is saved as it's made.
struct TradingSettingsView: View {
    @ObservedObject var trading: TradingModel
    @ObservedObject var robinhood: RobinhoodLink
    @State private var budget = 10_000.0
    @State private var risk = 1.0
    @State private var position = 20.0
    @State private var option = 5.0
    @State private var total = 10.0
    @State private var copying = false
    @State private var copied = false
    var body: some View {
        Form {
            Section {
                TextField("Budget", value:$budget, format:.currency(code:"USD").precision(.fractionLength(0)))
                    .onChange(of:budget) { _, value in if value > 0 { trading.saveSettings(["budget":value]) } }
                Stepper(value:$risk, in:0.25...5, step:0.25) { LabeledContent("Risk per stock trade", value:percent(risk)) }
                    .onChange(of:risk) { _, value in trading.saveSettings(["riskPercent":value]) }
                Stepper(value:$position, in:5...100, step:5) { LabeledContent("Largest stock position", value:percent(position)) }
                    .onChange(of:position) { _, value in trading.saveSettings(["maxPositionPercent":value]) }
                Stepper(value:$option, in:1...25, step:1) { LabeledContent("Most per option trade", value:percent(option)) }
                    .onChange(of:option) { _, value in trading.saveSettings(["maxOptionPercent":value]) }
                Stepper(value:$total, in:1...25, step:1) { LabeledContent("Total risk at once", value:percent(total)) }
                    .onChange(of:total) { _, value in trading.saveSettings(["maxRiskPercent":value]) }
            } header: { Text("Budget and risk") } footer: {
                Text("A stock trade loses about \(money(budget * risk / 100)) if its stop is hit and uses at most \(money(budget * position / 100)). An option trade costs at most \(money(budget * option / 100)), which is also the most it can lose. Everything you hold plus the alerts waiting can lose at most \(money(budget * total / 100)) together; new alerts wait until there's room.")
            }
            Section("Ideas") {
                Toggle("Suggest options", isOn:binding("options"))
                Text("Calls, puts and debit spreads only: the most you can lose is what you pay.").font(.caption).foregroundStyle(.secondary)
                Toggle("Also scan the market", isOn:binding("scan"))
                Text("Robinhood's scanner when connected: big moves on heavy volume, unusual volume, and oversold stocks in an uptrend. Otherwise Yahoo's movers lists.").font(.caption).foregroundStyle(.secondary)
                Picker("Minimum average volume", selection:number("minVolume")) {
                    ForEach(choices("minVolume", [0, 250_000, 500_000, 1_000_000, 2_000_000, 5_000_000]), id:\.self) { Text($0 == 0 ? "Any" : TradingModel.compact($0) + " shares a day").tag($0) }
                }
                Picker("Minimum market cap", selection:number("minMarketCap")) {
                    ForEach(choices("minMarketCap", [0, 2e9, 10e9, 50e9, 200e9]), id:\.self) { Text($0 == 0 ? "Any" : "$" + TradingModel.compact($0)).tag($0) }
                }
                Text("Research skips stocks below these, including ones on your watchlist or in Finance. Volume is the 20-day average.").font(.caption).foregroundStyle(.secondary)
                Toggle("Notifications for new ideas, stops and targets", isOn:binding("notify"))
            }
            Section {
                LabeledContent("Status") {
                    if robinhood.connecting { HStack(spacing:6) { ProgressView().controlSize(.small); Text("Finish signing in in your browser…") } }
                    else { Text(robinhood.connected ? "Connected, read-only" : "Not connected").foregroundStyle(robinhood.connected ? .primary : .secondary) }
                }
                if let error = robinhood.error { Text(error).foregroundStyle(.red) }
                HStack {
                    if robinhood.connected {
                        Button("Disconnect") { robinhood.disconnect() }
                        Button(copied ? "Copied" : copying ? "Copying…" : "Copy Diagnostics") { copyDiagnostics() }.disabled(copying)
                    } else {
                        Button("Connect Robinhood…") { Task { await robinhood.connect() } }.disabled(robinhood.connecting)
                    }
                }
            } header: { Text("Robinhood") } footer: {
                Text("Real-time stock and option quotes, price history and option chains for Trading and Finance. You sign in with Robinhood in your browser; Notebook never sees your password, can't place orders, and keeps its access in this Mac's keychain. Without it, quotes come from Yahoo Finance.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            budget = trading.setting("budget"); risk = trading.setting("riskPercent")
            position = trading.setting("maxPositionPercent"); option = trading.setting("maxOptionPercent"); total = trading.setting("maxRiskPercent")
        }
    }
    private func percent(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) + "%" }
    /// The usual choices, plus the current value if the agent set another.
    private func choices(_ key: String, _ usual: [Double]) -> [Double] { Set(usual + [trading.setting(key)]).sorted() }
    private func number(_ key: String) -> Binding<Double> { Binding(get:{ trading.setting(key) }, set:{ trading.saveSettings([key:$0]) }) }
    private func binding(_ key: String) -> Binding<Bool> { Binding(get:{ trading.flag(key) }, set:{ trading.saveSettings([key:$0]) }) }
    private func copyDiagnostics() {
        copying = true
        Task {
            let text = await robinhood.diagnostics()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType:.string)
            copying = false; copied = true
            try? await Task.sleep(for:.seconds(2)); copied = false
        }
    }
}
