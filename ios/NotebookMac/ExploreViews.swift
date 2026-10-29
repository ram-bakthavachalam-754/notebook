import SwiftUI
import NotebookCore

let exploreAll = "all"

private func percent(_ value: Double?) -> String {
    guard let value else { return "–" }
    return (value > 0.004 ? "+" : value < -0.004 ? "−" : "") + String(format:"%.2f%%", abs(value))
}
/// 209K, 1.5M, 2B.
private func compact(_ value: Double) -> String { value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))) }
private func dollars(_ value: Double) -> String { value > 0 ? "$" + compact(value) : "–" }
/// How far a change goes before its color is full, per period.
private let heatScale: [String:Double] = ["1D":3, "1W":6, "1M":10, "3M":18, "YTD":30, "1Y":40]
/// Red through gray to green, full at the period's scale; gray when unknown.
private func heat(_ change: Double?, _ period: String, dark: Bool) -> Color {
    let flat: [Double] = dark ? [74, 74, 71] : [138, 138, 134]
    guard let change else { return Color(red:flat[0] / 255, green:flat[1] / 255, blue:flat[2] / 255).opacity(0.5) }
    let t = max(-1, min(1, change / (heatScale[period] ?? 3))), amount = pow(abs(t), 0.75)
    let to: [Double] = t >= 0 ? (dark ? [22, 140, 70] : [22, 150, 74]) : (dark ? [200, 52, 52] : [214, 60, 60])
    let c = (0..<3).map { (flat[$0] + (to[$0] - flat[$0]) * amount) / 255 }
    return Color(red:c[0], green:c[1], blue:c[2])
}
private extension ExploreGroup {
    /// The code a selection id points into, for expanding the list.
    static func code(_ id: String) -> String { String(id.dropFirst(2)) }
}

// MARK: Middle column

/// The middle column: the list picker, then sectors, opening into industries
/// and sub-industries as you choose them.
struct ExploreSidebar: View {
    @ObservedObject var explore: ExploreModel
    @Binding var selection: String?
    @State private var search = ""
    var body: some View {
        let tree = explore.tree(), query = search.trimmingCharacters(in:.whitespaces).lowercased()
        let info = ExploreModel.info(explore.list), all = tree.flatMap(\.symbols)
        let open = openCode(tree)
        List(selection:$selection) {
            row(name:"All of " + (info.id == "SP" ? "the " : "") + info.name, count:all.count, change:explore.change(of:all, explore.period), tint:.accentColor, bold:true).tag(exploreAll)
            if !query.isEmpty {
                let stocks = all.compactMap { explore.stocks[$0] }.filter { $0.symbol.lowercased().hasPrefix(query) || $0.name.lowercased().contains(query) }
                    .sorted { explore.cap($0.symbol) > explore.cap($1.symbol) }.prefix(8)
                if !stocks.isEmpty {
                    Section("Stocks") {
                        ForEach(Array(stocks)) { stock in
                            HStack {
                                Text(stock.symbol).fontWeight(.semibold); Text(stock.name).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(); Text(percent(explore.change(stock.symbol, explore.period))).monospacedDigit().foregroundStyle(Color.gain(explore.change(stock.symbol, explore.period) ?? 0)).font(.callout)
                            }.tag("t:" + stock.symbol)
                        }
                    }
                }
            }
            Section(query.isEmpty ? "Sectors" : "Industries") {
                ForEach(tree) { sector in
                    let industries = query.isEmpty ? sector.children : sector.children.filter { matches($0, query) || sector.name.lowercased().contains(query) }
                    if query.isEmpty || !industries.isEmpty {
                        groupRow(sector, indent:0).tag(sector.id)
                        if !query.isEmpty || open.map(GICS.sector) == sector.code {
                            ForEach(industries) { industry in
                                groupRow(industry, indent:1).tag(industry.id)
                                if !query.isEmpty || open.map({ $0.count != 2 && GICS.industry($0) == industry.code }) == true {
                                    ForEach(industry.children.filter { query.isEmpty || matches($0, query) || matches(industry, query) }) { groupRow($0, indent:2).tag($0.id) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .environment(\.defaultMinListRowHeight, 26)
        .safeAreaInset(edge:.top, spacing:0) { header(info) }
        .searchable(text:$search, placement:.sidebar, prompt:"Industries, companies or tickers")
        .navigationTitle("Explore")
        .navigationSubtitle(explore.busy)
        .navigationSplitViewColumnWidth(min:250, ideal:290)
        .toolbar {
            Button { Task { await explore.refreshAll() } } label: { Label("Refresh", systemImage:"arrow.clockwise") }
                .disabled(!explore.busy.isEmpty).help("Check the lists and load prices again")
        }
        // Prices every two minutes while Explore is on screen.
        .task { await explore.start(); while !Task.isCancelled { try? await Task.sleep(for:.seconds(120)); await explore.refreshQuotes() } }
    }
    private func header(_ info: ExploreListInfo) -> some View {
        VStack(alignment:.leading, spacing:4) {
            Picker("List", selection:Binding(get:{ explore.list }, set:{ explore.list = $0; selection = exploreAll })) {
                ForEach(["Market", "Tech"], id:\.self) { group in
                    Section(group) { ForEach(ExploreModel.lists.filter { $0.group == group }) { Text($0.isMarket ? $0.name : "\($0.name) · \($0.etf)").tag($0.id) } }
                }
            }
            .labelsHidden()
            Text(status(info)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
    private func status(_ info: ExploreListInfo) -> String {
        let count = explore.symbols(in:explore.list).count
        guard let checked = explore.listsCheckedAt else { return explore.busy.isEmpty ? "Not loaded yet" : "Loading…" }
        return "\(count) companies · from \(info.source), checked \(checked.formatted(.dateTime.month(.abbreviated).day()))"
    }
    /// The code of what's selected, so its sector and industry show open; ""
    /// is Unclassified, and nil is the whole list.
    private func openCode(_ tree: [ExploreGroup]) -> String? {
        guard let selection, selection != exploreAll else { return nil }
        if selection.hasPrefix("t:") { return explore.stocks[String(selection.dropFirst(2))]?.code }
        return ExploreGroup.code(selection)
    }
    private func matches(_ group: ExploreGroup, _ query: String) -> Bool {
        group.name.lowercased().contains(query) || group.children.contains { $0.name.lowercased().contains(query) }
    }
    private func groupRow(_ group: ExploreGroup, indent: Int) -> some View {
        row(name:group.name, count:group.symbols.count, change:explore.change(of:group.symbols, explore.period),
            tint:indent == 0 ? heat(explore.change(of:group.symbols, explore.period), explore.period, dark:false) : nil, indent:indent)
    }
    private func row(name: String, count: Int, change: Double?, tint: Color?, indent: Int = 0, bold: Bool = false) -> some View {
        HStack(spacing:8) {
            if let tint { RoundedRectangle(cornerRadius:3).fill(tint).frame(width:10, height:10) }
            Text(name).fontWeight(bold ? .semibold : .regular).foregroundStyle(indent == 2 ? .secondary : .primary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength:4)
            Text("\(count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            Text(percent(change)).font(.callout).monospacedDigit().foregroundStyle(Color.gain(change ?? 0)).frame(minWidth:58, alignment:.trailing)
        }
        .padding(.leading, CGFloat(indent) * 14)
    }
}

// MARK: Detail

/// The right-hand pane: a heat map and lists for what's chosen, and ticker
/// pages pushed on top.
struct ExploreDetail: View {
    @ObservedObject var explore: ExploreModel
    @ObservedObject var finance: FinanceModel
    @ObservedObject var trading: TradingModel
    @Binding var selection: String?
    let openAccount: (String) -> Void
    let openAlert: (String) -> Void
    @State private var path: [TickerLink]
    /// A stock chosen from search opens over its sub-industry, so Back leads there.
    private let page: String
    init(explore: ExploreModel, finance: FinanceModel, trading: TradingModel, selection: Binding<String?>, openAccount: @escaping (String) -> Void, openAlert: @escaping (String) -> Void) {
        self.explore = explore; self.finance = finance; self.trading = trading; _selection = selection; self.openAccount = openAccount; self.openAlert = openAlert
        let chosen = selection.wrappedValue ?? exploreAll
        if chosen.hasPrefix("t:") {
            let symbol = String(chosen.dropFirst(2))
            page = "u:" + (explore.stocks[symbol]?.code ?? ""); _path = State(initialValue:[TickerLink(ticker:symbol)])
        } else { page = chosen; _path = State(initialValue:[]) }
    }
    var body: some View {
        NavigationStack(path:$path) {
            ExplorePage(explore:explore, trading:trading, id:page, open:{ selection = $0 }, openStock:{ path.append(TickerLink(ticker:$0)) })
            .navigationDestination(for:TickerLink.self) { link in
                TickerDetail(finance:finance, ticker:link.ticker, openAccount:openAccount, trading:trading, openAlert:openAlert)
            }
        }
    }
}

/// All of a list, a sector, an industry or a sub-industry.
struct ExplorePage: View {
    @ObservedObject var explore: ExploreModel
    @ObservedObject var trading: TradingModel
    let id: String
    let open: (String) -> Void
    let openStock: (String) -> Void
    @State private var moving: ExploreStock?
    var body: some View {
        let tree = explore.tree()
        Group {
            if id == exploreAll || explore.group(id, in:tree) != nil {
                ScrollView { page(tree).pageColumn(1300) }
            } else {
                ContentUnavailableView { Label("Not in \(ExploreModel.info(explore.list).name)", systemImage:"square.grid.3x3") } description: {
                    Text("No company in this list is in that group.")
                } actions: { Button("Show All") { open(exploreAll) } }
            }
        }
        .sheet(item:$moving) { MoveSheet(explore:explore, stock:$0) }
    }
    @ViewBuilder private func page(_ tree: [ExploreGroup]) -> some View {
        let info = ExploreModel.info(explore.list), p = explore.period
        let group = explore.group(id, in:tree)
        let symbols = group?.symbols ?? tree.flatMap(\.symbols)
        VStack(alignment:.leading, spacing:16) {
            if let group { crumbs(group) }
            PageHeader(title:group?.name ?? info.name) {
                Text(percent(explore.change(of:symbols, p))).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(Color.gain(explore.change(of:symbols, p) ?? 0))
            }
            if group == nil, !info.index.isEmpty { Text("The \(info.index) index · tracked by \(info.etf)").font(.callout).foregroundStyle(.secondary) }
            controls
            if group == nil { notices }
            summary(symbols)
            if symbols.isEmpty {
                Text(explore.busy.isEmpty ? "Nothing here yet. Press Refresh to load the lists." : explore.busy).foregroundStyle(.secondary)
            } else {
                HeatMap(groups:mapGroups(group, tree), period:p, height:group?.level == "u" ? 300 : 440)
                legend
                tables(group, tree)
            }
        }
    }
    private func crumbs(_ group: ExploreGroup) -> some View {
        var parts: [(String, String)] = [("All", exploreAll)]
        if group.level != "s" { parts.append((GICS.name(GICS.sector(group.code)), "s:" + GICS.sector(group.code))) }
        if group.level == "u" { parts.append((GICS.name(GICS.industry(group.code)), "i:" + GICS.industry(group.code))) }
        return HStack(spacing:4) {
            ForEach(parts, id:\.1) { part in
                Button(part.0) { open(part.1) }.buttonStyle(.link)
                Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }
    private var controls: some View {
        HStack(spacing:14) {
            Picker("Period", selection:$explore.period) { ForEach(ExplorePeriods.all, id:\.self) { Text($0) } }.pickerStyle(.segmented).fixedSize()
            Picker("Size", selection:$explore.size) { Text("Market cap").tag("cap"); Text("Equal").tag("equal") }.pickerStyle(.segmented).fixedSize()
            Picker("Show", selection:$explore.topOnly) { Text("All").tag(false); Text("Top 5").tag(true) }.pickerStyle(.segmented).fixedSize()
                .help("Top 5 keeps the five largest companies in each sub-industry")
        }
    }
    /// Who joined or left the list lately, and companies waiting for a place.
    @ViewBuilder private var notices: some View {
        if let change = explore.changesLog.first(where: { $0.list == explore.list && Date().timeIntervalSince($0.date) < 30 * 86400 }) {
            Label {
                Text(([change.added.isEmpty ? nil : "Joined: " + change.added.joined(separator:", "), change.removed.isEmpty ? nil : "Left: " + change.removed.joined(separator:", ")]
                    .compactMap { $0 }).joined(separator:" · ") + " (\(change.date.formatted(.dateTime.month(.abbreviated).day())))")
            } icon: { Image(systemName:"arrow.left.arrow.right") }
            .font(.callout).foregroundStyle(.secondary)
        }
        let waiting = explore.unplaced.filter { explore.stocks[$0]?.lists.contains(explore.list) == true }
        if !waiting.isEmpty, explore.busy.isEmpty {
            Label("\(waiting.count) compan\(waiting.count == 1 ? "y isn't" : "ies aren't") placed in an industry yet. Set up a model in Agent Settings to place them, or right-click one to move it yourself.", systemImage:"questionmark.square.dashed")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func summary(_ symbols: [String]) -> some View {
        let p = explore.period, known = symbols.filter { explore.change($0, p) != nil }.sorted { explore.change($0, p)! > explore.change($1, p)! }
        if let best = known.first, let worst = known.last {
            HStack(spacing:22) {
                Text("**\(known.filter { explore.change($0, p)! > 0 }.count)** of \(symbols.count) up")
                Text("Best **\(best) \(percent(explore.change(best, p)))**")
                Text("Worst **\(worst) \(percent(explore.change(worst, p)))**")
                Text("Combined value **\(dollars(symbols.reduce(0) { $0 + explore.cap($1) }))**")
                if p != "1D", symbols.contains(where: { explore.references[$0] == nil }) { Text("Some 1W–1Y changes are still loading").foregroundStyle(.tertiary) }
            }
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private var legend: some View {
        let scale = heatScale[explore.period] ?? 3
        return HStack(spacing:8) {
            Text("−\(Int(scale))%")
            HStack(spacing:0) { ForEach([-1, -0.66, -0.33, 0, 0.33, 0.66, 1], id:\.self) { t in Rectangle().fill(heat(t * scale, explore.period, dark:false)).frame(width:24, height:9) } }
                .clipShape(RoundedRectangle(cornerRadius:3))
            Text("+\(Int(scale))%")
            Spacer()
            Text("Click a tile to look closer").foregroundStyle(.tertiary)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
    private func size(_ symbols: [String]) -> Double { explore.size == "cap" ? symbols.reduce(0) { $0 + max(explore.cap($1), 1) } : Double(symbols.count) }
    private func stockTiles(_ symbols: [String]) -> [HeatMap.Tile] {
        symbols.map { symbol in HeatMap.Tile(id:symbol, label:symbol, change:explore.change(symbol, explore.period), size:size([symbol])) { openStock(symbol) } }
    }
    private func mapGroups(_ group: ExploreGroup?, _ tree: [ExploreGroup]) -> [HeatMap.Group] {
        func make(_ g: ExploreGroup, tiles: [HeatMap.Tile]) -> HeatMap.Group {
            HeatMap.Group(id:g.id, label:g.name, change:explore.change(of:g.symbols, explore.period), size:size(g.symbols), action:{ open(g.id) }, tiles:tiles)
        }
        guard let group else {
            // Short lists (the tech ones) show their stocks; long ones their industries.
            let all = tree.flatMap(\.symbols)
            if all.count <= 80 { return tree.flatMap(\.children).flatMap(\.children).map { make($0, tiles:stockTiles($0.symbols)) } }
            return tree.map { sector in make(sector, tiles:sector.children.map { industry in
                HeatMap.Tile(id:industry.id, label:industry.name, change:explore.change(of:industry.symbols, explore.period), size:size(industry.symbols)) { open(industry.id) } }) }
        }
        switch group.level {
        case "s": return group.children.map { make($0, tiles:stockTiles($0.symbols)) }
        case "i": return group.children.map { make($0, tiles:stockTiles($0.symbols)) }
        default: return [make(group, tiles:stockTiles(group.symbols))]
        }
    }
    @ViewBuilder private func tables(_ group: ExploreGroup?, _ tree: [ExploreGroup]) -> some View {
        let p = explore.period
        if let group {
            switch group.level {
            case "s": SectionBlock("Industries") { GroupTable(explore:explore, groups:group.children, showSector:false, open:open) }
            case "i":
                ForEach(group.children) { sub in
                    SectionBlock(title:sub.name) {
                        HStack(spacing:12) {
                            Text(percent(explore.change(of:sub.symbols, p))).monospacedDigit().foregroundStyle(Color.gain(explore.change(of:sub.symbols, p) ?? 0))
                            Button("Open") { open(sub.id) }.buttonStyle(.link)
                        }
                    } content: { stockTable(sub.symbols) }
                }
            default: SectionBlock("Stocks") { stockTable(group.symbols) }
            }
        } else if tree.flatMap(\.symbols).count <= 80 {
            SectionBlock("Stocks") { stockTable(tree.flatMap(\.symbols)) }
            SectionBlock("Sub-industries") { GroupTable(explore:explore, groups:tree.flatMap(\.children).flatMap(\.children), showSector:true, open:open) }
        } else {
            SectionBlock("Industries by \(p) change") { GroupTable(explore:explore, groups:tree.flatMap(\.children), showSector:true, open:open) }
        }
    }
    private func stockTable(_ symbols: [String]) -> some View {
        StockTable(explore:explore, trading:trading, symbols:symbols, openStock:openStock, move:{ moving = explore.stocks[$0] })
    }
}

// MARK: Heat map

/// Groups of tiles laid out as a treemap: each group's area is its size, and
/// its tiles share that area. A group too small for a heading is one tile.
struct HeatMap: View {
    struct Tile: Identifiable { let id: String; let label: String; let change: Double?; let size: Double; let action: () -> Void }
    struct Group: Identifiable { let id: String; let label: String; let change: Double?; let size: Double; let action: () -> Void; let tiles: [Tile] }
    private struct Cell: Identifiable { let id: String; let rect: CGRect; let label: String; let change: Double?; let heading: Bool; let action: () -> Void }
    let groups: [Group]
    let period: String
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment:.topLeading) {
                ForEach(cells(geometry.size)) { cell in
                    if cell.heading { heading(cell) } else { tile(cell) }
                }
            }
        }
        .frame(height:height)
        .background(Color.cardFill)
        .clipShape(RoundedRectangle(cornerRadius:10, style:.continuous))
    }
    private func cells(_ size: CGSize) -> [Cell] {
        let headingHeight: CGFloat = 18
        var out: [Cell] = []
        let rects = Treemap.layout(groups.map(\.size), in:CGRect(origin:.zero, size:size))
        for (group, rect) in zip(groups, rects) where rect.width > 0 {
            if rect.width < 60 || rect.height < 44 || group.tiles.isEmpty {
                out.append(Cell(id:group.id, rect:rect, label:group.label, change:group.change, heading:false, action:group.action)); continue
            }
            out.append(Cell(id:group.id + "#", rect:CGRect(x:rect.minX, y:rect.minY, width:rect.width, height:headingHeight), label:group.label, change:group.change, heading:true, action:group.action))
            let inner = CGRect(x:rect.minX, y:rect.minY + headingHeight, width:rect.width, height:rect.height - headingHeight)
            for (tile, r) in zip(group.tiles, Treemap.layout(group.tiles.map(\.size), in:inner)) where r.width > 0 {
                out.append(Cell(id:group.id + "/" + tile.id, rect:r, label:tile.label, change:tile.change, heading:false, action:tile.action))
            }
        }
        return out
    }
    private func heading(_ cell: Cell) -> some View {
        HStack(spacing:4) {
            Text(cell.label).fontWeight(.semibold).foregroundStyle(.secondary)
            Text(percent(cell.change)).foregroundStyle(Color.gain(cell.change ?? 0))
            Spacer(minLength:0)
        }
        .font(.system(size:11)).lineLimit(1).padding(.horizontal, 5)
        .frame(width:cell.rect.width, height:cell.rect.height)
        .contentShape(Rectangle()).onTapGesture(perform:cell.action)
        .offset(x:cell.rect.minX, y:cell.rect.minY)
    }
    private func tile(_ cell: Cell) -> some View {
        let w = cell.rect.width, h = cell.rect.height, length = CGFloat(cell.label.count)
        let font = max(10, min(20, sqrt(w * h) / 7))
        return Rectangle().fill(heat(cell.change, period, dark:scheme == .dark))
            .overlay {
                if w > length * font * 0.62, h > 44 {
                    VStack(spacing:1) { Text(cell.label).font(.system(size:font, weight:.semibold)); Text(percent(cell.change)).font(.system(size:max(10, font * 0.7))) }
                } else if w > length * 7, h > 18 {
                    Text(cell.label).font(.system(size:11, weight:.semibold))
                }
            }
            .foregroundStyle(.white).lineLimit(1)
            .frame(width:max(0, w - 1), height:max(0, h - 1))
            .contentShape(Rectangle()).onTapGesture(perform:cell.action)
            .help("\(cell.label) \(percent(cell.change))")
            .offset(x:cell.rect.minX, y:cell.rect.minY)
    }
}

// MARK: Tables

/// Stocks, sortable by any column. Right-click one to move it or watch it.
private struct StockTable: View {
    @ObservedObject var explore: ExploreModel
    @ObservedObject var trading: TradingModel
    let symbols: [String]
    let openStock: (String) -> Void
    let move: (String) -> Void
    @State private var sort = "cap"
    @State private var ascending = false
    var body: some View {
        let p = explore.period
        let rows = symbols.sorted { a, b in
            let order: Bool
            switch sort {
            case "symbol": order = a < b
            case "price": order = (explore.price(a) ?? 0) < (explore.price(b) ?? 0)
            case "change": order = (explore.change(a, p) ?? -.infinity) < (explore.change(b, p) ?? -.infinity)
            case "volume": order = (explore.quotes[a]?.volume ?? 0) < (explore.quotes[b]?.volume ?? 0)
            default: order = explore.cap(a) < explore.cap(b)
            }
            return ascending ? order : !order
        }
        VStack(spacing:0) {
            HStack(spacing:8) {
                header("Stock", "symbol").frame(maxWidth:.infinity, alignment:.leading)
                Text("Lists").frame(width:170, alignment:.trailing)
                header("Price", "price").frame(width:80, alignment:.trailing)
                header("\(p) change", "change").frame(width:86, alignment:.trailing)
                header("Market cap", "cap").frame(width:84, alignment:.trailing)
                header("Volume", "volume").frame(width:64, alignment:.trailing)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 6)
            Divider()
            ForEach(rows, id:\.self) { symbol in row(symbol); Divider().opacity(0.5) }
        }
    }
    private func header(_ title: String, _ key: String) -> some View {
        Button { if sort == key { ascending.toggle() } else { sort = key; ascending = key == "symbol" } } label: {
            Text(title + (sort == key ? (ascending ? " ▲" : " ▼") : "")).foregroundStyle(sort == key ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }
    private func row(_ symbol: String) -> some View {
        let stock = explore.stocks[symbol], change = explore.change(symbol, explore.period)
        return Button { openStock(symbol) } label: {
            HStack(spacing:8) {
                HStack(spacing:6) {
                    Text(symbol).fontWeight(.semibold)
                    Text(stock?.name ?? "").foregroundStyle(.secondary).lineLimit(1)
                    if trading.heldTickers.contains(symbol) { Pill(text:"OWN", tint:.green) }
                    if trading.watchlist.contains(symbol) { Pill(text:"WATCH", tint:.teal) }
                    if stock?.placedBy == "ai" { Pill(text:"AI", tint:.purple).help("Not in the S&P 500, so it has no published industry. Your AI model placed it; right-click to move it.") }
                    if stock?.placedBy == "you" { Pill(text:"MOVED", tint:.secondary).help("You placed this one") }
                }
                .frame(maxWidth:.infinity, alignment:.leading)
                Text((stock?.lists ?? []).map { ExploreModel.info($0).short }.joined(separator:" · ")).foregroundStyle(.secondary).font(.caption).lineLimit(1).frame(width:170, alignment:.trailing)
                Text(explore.price(symbol).map { $0.formatted(.currency(code:"USD")) } ?? "–").frame(width:80, alignment:.trailing)
                Text(percent(change)).font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).frame(minWidth:66, alignment:.trailing)
                    .background(heat(change, explore.period, dark:false), in:RoundedRectangle(cornerRadius:5))
                    .frame(width:86, alignment:.trailing)
                Text(dollars(explore.cap(symbol))).frame(width:84, alignment:.trailing)
                Text(explore.quotes[symbol].map { compact($0.volume) } ?? "–").foregroundStyle(.secondary).frame(width:64, alignment:.trailing)
            }
            .monospacedDigit().padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu {
            Button("Move to Another Sub-industry…") { move(symbol) }
            if trading.watchlist.contains(symbol) { Button("Remove from Trading Watchlist") { trading.removeFromWatchlist(symbol) } }
            else { Button("Add to Trading Watchlist") { trading.addToWatchlist(symbol) } }
        }
    }
}

/// Industries or sub-industries with their change and leaders; click one to open it.
private struct GroupTable: View {
    @ObservedObject var explore: ExploreModel
    let groups: [ExploreGroup]
    let showSector: Bool
    let open: (String) -> Void
    var body: some View {
        let p = explore.period
        let rows = groups.sorted { (explore.change(of:$0.symbols, p) ?? -.infinity) > (explore.change(of:$1.symbols, p) ?? -.infinity) }
        VStack(spacing:0) {
            HStack(spacing:8) {
                Text(showSector ? "Name · sector" : "Name").frame(maxWidth:.infinity, alignment:.leading)
                Text("Stocks").frame(width:50, alignment:.trailing)
                Text("\(p) change").frame(width:86, alignment:.trailing)
                Text("Market cap").frame(width:84, alignment:.trailing)
                Text("Biggest").frame(width:64, alignment:.trailing)
                Text("Best").frame(width:120, alignment:.trailing)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 6)
            Divider()
            ForEach(rows) { group in
                let change = explore.change(of:group.symbols, p)
                let biggest = group.symbols.max { explore.cap($0) < explore.cap($1) } ?? ""
                let best = group.symbols.filter { explore.change($0, p) != nil }.max { explore.change($0, p)! < explore.change($1, p)! }
                Button { open(group.id) } label: {
                    HStack(spacing:8) {
                        HStack(spacing:6) {
                            Text(group.name).fontWeight(.semibold).lineLimit(1)
                            if showSector { Text(GICS.name(GICS.sector(group.code))).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .frame(maxWidth:.infinity, alignment:.leading)
                        Text("\(group.symbols.count)").frame(width:50, alignment:.trailing)
                        Text(percent(change)).font(.callout.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2).frame(minWidth:66, alignment:.trailing)
                            .background(heat(change, p, dark:false), in:RoundedRectangle(cornerRadius:5)).frame(width:86, alignment:.trailing)
                        Text(dollars(group.symbols.reduce(0) { $0 + explore.cap($1) })).frame(width:84, alignment:.trailing)
                        Text(biggest).frame(width:64, alignment:.trailing)
                        HStack(spacing:4) {
                            Text(best ?? "–")
                            if let best { Text(percent(explore.change(best, p))).foregroundStyle(Color.gain(explore.change(best, p) ?? 0)) }
                        }
                        .frame(width:120, alignment:.trailing)
                    }
                    .monospacedDigit().padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                Divider().opacity(0.5)
            }
        }
    }
}

/// A table row that highlights under the pointer and when pressed.
private struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : hovering ? 0.045 : 0), in:RoundedRectangle(cornerRadius:6))
            .onHover { hovering = $0 }
    }
}

/// Puts a company in another sub-industry. Your choice wins over S&P's and your model's.
private struct MoveSheet: View {
    @ObservedObject var explore: ExploreModel
    let stock: ExploreStock
    @State private var code: String
    @Environment(\.dismiss) private var dismiss
    init(explore: ExploreModel, stock: ExploreStock) {
        self.explore = explore; self.stock = stock
        _code = State(initialValue:stock.code.isEmpty ? GICS.subIndustries[0] : stock.code)
    }
    var body: some View {
        EditorSheet(title:"Move \(stock.symbol)", height:260) {
            Section {
                LabeledContent("Company", value:stock.name)
                LabeledContent("Now in", value:stock.code.isEmpty ? "Unclassified" : "\(GICS.name(GICS.sector(stock.code))) › \(GICS.name(stock.code))")
                Picker("Move to", selection:$code) {
                    ForEach(GICS.subIndustries.map(GICS.sector).reduce(into:[String]()) { if !$0.contains($1) { $0.append($1) } }, id:\.self) { sector in
                        Section(GICS.name(sector)) { ForEach(GICS.subIndustries.filter { $0.hasPrefix(sector) }, id:\.self) { Text(GICS.name($0)).tag($0) } }
                    }
                }
            }
        } actions: {
            Spacer()
            Button("Cancel", role:.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Move") { explore.place(stock.symbol, in:code); dismiss() }.keyboardShortcut(.defaultAction).disabled(code == stock.code)
        }
    }
}
