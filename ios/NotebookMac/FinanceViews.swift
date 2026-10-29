import SwiftUI
import Charts
import NotebookCore

/// "All accounts" or one account's id.
let allAccounts = "__all__"

private let accountTypes = ["brokerage", "401k", "ira", "roth_ira", "hsa", "cash", "other"]
private func typeLabel(_ type: String) -> String {
    ["brokerage":"Brokerage", "401k":"401(k)", "ira":"IRA", "roth_ira":"Roth IRA", "hsa":"HSA", "cash":"Cash", "other":"Other"][type] ?? type.replacingOccurrences(of:"_", with:" ").capitalized
}
private func typeIcon(_ type: String) -> String {
    ["brokerage":"chart.line.uptrend.xyaxis", "401k":"briefcase", "ira":"building.columns", "roth_ira":"building.columns", "hsa":"cross.case", "cash":"banknote"][type] ?? "wallet.bifold"
}
private func money(_ value: Double) -> String { value.formatted(.currency(code:"USD")) }
private func signed(_ value: Double) -> String { (value > 0 ? "+" : "") + money(value) }
private func percent(_ value: Double) -> String { (value > 0 ? "+" : "") + (value / 100).formatted(.percent.precision(.fractionLength(2))) }

struct FinanceAccounts: View {
    @ObservedObject var finance: FinanceModel
    @ObservedObject var sharing: SharingModel
    @Binding var selection: String?
    private func detail(_ account: FinanceRow) -> String {
        let count = finance.scopedHoldings(account.id).count
        let label = typeLabel(account.text("type")), holdings = count == 0 ? "No holdings" : count == 1 ? "1 holding" : "\(count) holdings"
        let type = label.caseInsensitiveCompare(account.name) == .orderedSame ? holdings : label + " · " + holdings
        return sharing.share(kind:"account", entity:account.id) == nil ? type : type + " · Shared"
    }
    private func value(_ account: FinanceRow) -> Double { (finance.accountSummary(account.id)["totalValue"] as? NSNumber)?.doubleValue ?? 0 }
    var body: some View {
        let accounts = finance.rows("accounts").sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        List(selection:$selection) {
            AccountRow(name:"All Accounts", detail:"\(accounts.count) accounts", value:finance.total("totalValue") - finance.total("realEstateValue"), icon:"square.stack.3d.up.fill").tag(allAccounts)
            Section("Accounts") {
                ForEach(accounts) { account in
                    AccountRow(name:account.name, detail:detail(account), value:value(account), icon:typeIcon(account.text("type"))).tag(account.id)
                }
            }
            if !finance.sharedAccounts.isEmpty {
                Section("Shared with You") {
                    ForEach(finance.sharedAccounts) { shared in
                        AccountRow(name:shared.view["name"] as? String ?? shared.info.title, detail:"From \(shared.info.ownerName.isEmpty ? "someone" : shared.info.ownerName) · View only",
                                   value:SharedAccountView(info:shared.info, view:shared.view, price:finance.price).total, icon:"person.2").tag("shared:" + shared.id)
                    }
                }
            }
        }
        .overlay { if !finance.loaded { ProgressView() } else if accounts.isEmpty { ContentUnavailableView("No accounts yet", systemImage:"building.columns", description:Text("Add an account to start tracking your holdings.")) } }
        // Rows in sections otherwise stay one line tall.
        .environment(\.defaultMinListRowHeight, 48)
        .navigationTitle("Finance")
        .navigationSubtitle(finance.refreshing ? "Updating prices…" : finance.robinhood?.connected == true ? "Live prices from Robinhood" : "")
        .navigationSplitViewColumnWidth(min:240, ideal:280)
        // Fetch prices on opening and keep them current while Finance is shown.
        // With Robinhood connected, real-time quotes every 15 seconds.
        .task { while !Task.isCancelled { await finance.refreshIfStale(); try? await Task.sleep(for:.seconds(finance.robinhood?.connected == true ? 15 : 60)) } }
    }
}

private struct AccountRow: View {
    let name: String, detail: String, value: Double, icon: String
    var body: some View {
        HStack(spacing:10) {
            Image(systemName:icon).font(.system(size:13, weight:.medium)).foregroundStyle(.green)
                .frame(width:28, height:28).background(Color.green.opacity(0.12), in:RoundedRectangle(cornerRadius:8, style:.continuous))
            VStack(alignment:.leading, spacing:1) { Text(name).font(.system(.body, weight:.semibold)).lineLimit(1); Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength:6)
            Text(money(value)).font(.callout.weight(.medium)).monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

/// Edits open as sheets: an account (nil id for new) or a transaction.
enum FinanceSheet: Identifiable {
    case account(FinanceRow), transaction(FinanceRow)
    var id: String { switch self { case .account(let r): "a-" + r.id; case .transaction(let r): "t-" + r.id } }
}

/// Holdings table columns; each header sorts by its column.
private enum HoldingSort: String { case symbol, shares, price, value, today, gain }

struct FinanceDetail: View {
    @ObservedObject var finance: FinanceModel
    var sharing: SharingModel? = nil
    let accountID: String
    @State private var sharingSheet = false
    var openAccount: (String) -> Void = { _ in }
    /// For ticker pages: Trading's alerts and watchlist (nil in kid mode).
    var trading: TradingModel?
    var openAlert: (String) -> Void = { _ in }
    @State private var sheet: FinanceSheet?
    @State private var ticker: String?
    @State private var showingAccounts = false
    @AppStorage("finance-holdings-sort") private var sortKey = HoldingSort.value.rawValue
    @AppStorage("finance-holdings-ascending") private var ascending = false
    @State private var deleting: FinanceRow?
    private var account: FinanceRow? { finance.rows("accounts").first { $0.id == accountID } }
    private var summary: [String:Any] { accountID == allAccounts ? finance.summary : finance.accountSummary(accountID) }
    private func number(_ key: String) -> Double { (summary[key] as? NSNumber)?.doubleValue ?? 0 }
    var body: some View {
        let holdings = sorted(accountID == allAccounts ? finance.holdings : finance.scopedHoldings(accountID))
        let transactions = finance.rows("transactions").filter { accountID == allAccounts || $0.text("accountId") == accountID }.sorted { $0.text("date") > $1.text("date") }
        let names = Dictionary(uniqueKeysWithValues:finance.rows("accounts").map { ($0.id, $0.name) })
        let priced = holdings.isEmpty || finance.fullyPriced
        ScrollView {
            VStack(alignment:.leading, spacing:24) {
                VStack(alignment:.leading, spacing:4) {
                    Text(account.map { typeLabel($0.text("type")).uppercased() } ?? "\(finance.rows("accounts").count) ACCOUNTS").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.green)
                    Text(account?.name ?? "All Accounts").font(MacStyle.titleFont)
                    Text(money(number("totalValue") - number("realEstateValue"))).font(.system(size:40, weight:.semibold, design:.rounded)).monospacedDigit().padding(.top, 6)
                    if !priced { Label("Some holdings have no current price yet, so totals leave them out. Refresh prices to update them.", systemImage:"exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).padding(.top, 2) }
                }
                HStack(alignment:.top, spacing:12) {
                    StatTile(title:"Today", value:priced ? signed(number("totalDayChange")) : "—", detail:priced ? percent(number("totalDayChangePercent")) : "Waiting for prices", tint:priced ? .gain(number("totalDayChange")) : .secondary)
                    StatTile(title:"Total gain", value:priced ? signed(number("totalPL")) : "—", detail:priced ? percent(number("totalPLPercent")) : "Waiting for prices", tint:priced ? .gain(number("totalPL")) : .secondary)
                    Button { showingAccounts = true } label: {
                        StatTile(title:"Cash", value:money(number("cash")), detail:"Ready to invest")
                            .overlay(alignment:.topTrailing) { Image(systemName:"chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(14) }
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain).help("Show every account's value, cash and gains")
                    StatTile(title:"Holdings", value:"\(holdings.count)", detail:holdings.count == 1 ? "position" : "positions")
                }
                valueChart(finance.valueHistory(accountID == allAccounts ? nil : accountID))
                SectionBlock("Holdings") {
                    if holdings.isEmpty { Text("No holdings yet. Add a buy or an existing holding.").foregroundStyle(.secondary).card() }
                    else {
                        holdingsTable(holdings)
                        .card(padding:16)
                    }
                }
                SectionBlock("Transactions") {
                    if transactions.isEmpty { Text("No transactions yet.").foregroundStyle(.secondary).card() }
                    else {
                        VStack(spacing:0) {
                            ForEach(Array(transactions.enumerated()), id:\.element.id) { index, t in
                                if index > 0 { Divider() }
                                TransactionRow(transaction:t, ticker:finance.displayTicker(t.text("ticker")), account:accountID == allAccounts ? names[t.text("accountId")] : nil,
                                               open:{ ticker = t.text("ticker") }, edit:{ sheet = .transaction(t) })
                                    .contextMenu { Button("Edit") { sheet = .transaction(t) }; Button("Delete", role:.destructive) { deleting = t } }
                            }
                        }
                        .card(padding:16)
                    }
                }
            }
            .pageColumn(1000)
        }
        .navigationDestination(item:$ticker) { TickerDetail(finance:finance, ticker:$0, openAccount:openAccount, trading:trading, openAlert:openAlert) }
        .navigationDestination(isPresented:$showingAccounts) { FinanceAccountsTable(finance:finance, openAccount:openAccount) }
        .navigationTitle(account?.name ?? "All Accounts")
        .navigationSubtitle(finance.notice ?? "")
        .toolbar { toolbar }
        .sheet(isPresented:$sharingSheet) { shareSheet }
        .sheet(item:$sheet) { item in
            switch item {
            case .account(let row): AccountEditor(finance:finance, row:row)
            case .transaction(let row): TransactionEditor(finance:finance, row:row)
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented:Binding(get:{ deleting != nil }, set:{ if !$0 { deleting = nil } }), presenting:deleting) { row in
            Button("Delete", role:.destructive) { finance.delete(row, field:row.raw["accountId"] == nil ? "accounts" : "transactions") }
        } message: { row in Text(row.raw["accountId"] == nil ? "This also removes the account's transactions. Your other accounts are kept." : "The account's cash is adjusted as if this transaction never happened.") }
    }
    private func holdingsTable(_ holdings: [FinanceRow]) -> some View {
        Grid(alignment:.trailing, horizontalSpacing:18, verticalSpacing:0) {
            GridRow {
                header("Symbol", .symbol).gridColumnAlignment(.leading); header("Shares", .shares); header("Price", .price)
                header("Value", .value); header("Today", .today); header("Gain/Loss", .gain)
            }
            .padding(.bottom, 8)
            ForEach(holdings) { h in
                Divider().gridCellUnsizedAxes(.horizontal)
                holdingRow(h).monospacedDigit().padding(.vertical, 9)
            }
        }
    }
    private func holdingRow(_ h: FinanceRow) -> some View {
        let known = h.number("currentPrice") > 0, symbol = h.text("ticker")
        let day = h.number("dayChange"), gain = h.number("profitLoss")
        return GridRow {
            Button { ticker = symbol } label: {
                HStack(spacing:9) {
                    Monogram(text:symbol, tint:Monogram.tint(for:symbol), size:26)
                    Text(finance.displayTicker(symbol)).font(.body.weight(.semibold)).foregroundStyle(.primary)
                }
                .frame(maxWidth:.infinity, alignment:.leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Show \(symbol) details").gridColumnAlignment(.leading)
            Text(h.number("totalShares").formatted(.number.precision(.fractionLength(0...8)))).foregroundStyle(.secondary)
            Text(known ? money(h.number("currentPrice")) : "—")
            Text(known ? money(h.number("currentValue")) : "—").fontWeight(.medium)
            Text(known ? signed(day) : "—").foregroundStyle(known ? Color.gain(day) : .secondary)
            VStack(alignment:.trailing, spacing:1) {
                Text(known ? signed(gain) : "—").foregroundStyle(known ? Color.gain(gain) : .secondary)
                if known { Text(percent(h.number("profitLossPercent"))).font(.caption).foregroundStyle(Color.gain(gain).opacity(0.8)) }
            }
        }
    }
    /// The value in each daily snapshot. Finance saves one while it's open.
    @ViewBuilder private func valueChart(_ data: [(date: Date, value: Double)]) -> some View {
        if data.count == 1 { Label("A value chart appears here after a second day of snapshots.", systemImage:"chart.xyaxis.line").font(.callout).foregroundStyle(.secondary).card() }
        else if data.count > 1 {
            let up = (data.last?.value ?? 0) >= (data.first?.value ?? 0)
            let low = data.map(\.value).min() ?? 0, high = data.map(\.value).max() ?? 0
            let pad = max((high - low) * 0.08, 1)
            VStack(alignment:.leading, spacing:8) {
                HStack(alignment:.firstTextBaseline) {
                    Text("Value over time").font(.headline)
                    Spacer()
                    Text("\(signed((data.last?.value ?? 0) - (data.first?.value ?? 0))) since \(data[0].date.formatted(date:.abbreviated, time:.omitted))")
                        .font(.callout).monospacedDigit().foregroundStyle(up ? .green : .red)
                }
                Chart(data, id:\.date) { point in
                    AreaMark(x:.value("Date", point.date), yStart:.value("Low", low - pad), yEnd:.value("Value", point.value))
                        .foregroundStyle(LinearGradient(colors:[(up ? Color.green : .red).opacity(0.22), (up ? Color.green : .red).opacity(0)], startPoint:.top, endPoint:.bottom)).interpolationMethod(.monotone)
                    LineMark(x:.value("Date", point.date), y:.value("Value", point.value)).foregroundStyle(up ? Color.green : Color.red).lineStyle(StrokeStyle(lineWidth:2)).interpolationMethod(.monotone)
                }
                .chartYScale(domain:(low - pad)...(high + pad))
                .chartYAxis { AxisMarks(position:.trailing) { AxisGridLine(stroke:StrokeStyle(lineWidth:0.5, dash:[2, 3])); AxisValueLabel(format:.currency(code:"USD").precision(.fractionLength(0))) } }
                .frame(height:200)
                .accessibilityLabel("Value over time")
            }
            .card()
        }
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { sheet = .account(FinanceRow(raw:[:])) } label: { Label("Add Account", systemImage:"plus.rectangle.on.folder") }.help("Add an account")
            Button { sheet = .transaction(FinanceRow(raw:accountID == allAccounts ? [:] : ["accountId":accountID])) } label: { Label("Add Transaction", systemImage:"plus") }
                .disabled(finance.rows("accounts").isEmpty).help("Add a buy, sell or existing holding")
            Button { Task { await finance.refreshPrices() } } label: { Label("Refresh Prices", systemImage:"arrow.clockwise") }.disabled(finance.refreshing).help("Refresh prices")
        }
        if let account {
            ToolbarItemGroup {
                if let sharing {
                    let shared = sharing.share(kind:"account", entity:account.id)
                    Button { sharingSheet = true } label: { Label("Share", systemImage:shared == nil ? "person.crop.circle.badge.plus" : "person.2.fill") }.help(shared.map(shareLine) ?? "Share a view-only copy of this account")
                }
                Button { sheet = .account(account) } label: { Label("Edit Account", systemImage:"pencil") }.help("Edit account")
                Button(role:.destructive) { deleting = account } label: { Label("Delete Account", systemImage:"trash") }.help("Delete account")
            }
        }
    }
    @ViewBuilder private var shareSheet: some View {
        if let sharing, let account {
            ShareSheet(sharing:sharing, kind:"account", title:account.name, existing:sharing.share(kind:"account", entity:account.id)?.id) { level in
                guard let view = finance.accountView(account.id, level:level) else { return nil }
                return await sharing.shareAccount(account, level:level, view:view)
            }
        }
    }
    private func header(_ title: String, _ key: HoldingSort) -> some View {
        Button {
            if sortKey == key.rawValue { ascending.toggle() } else { sortKey = key.rawValue; ascending = key == .symbol }
        } label: {
            HStack(spacing:3) {
                Text(title)
                if sortKey == key.rawValue { Image(systemName:ascending ? "chevron.up" : "chevron.down").font(.system(size:8, weight:.bold)) }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(sortKey == key.rawValue ? .primary : .secondary)
        }
        .buttonStyle(.plain).help("Sort by \(title.lowercased())")
    }
    private func sorted(_ rows: [FinanceRow]) -> [FinanceRow] {
        let key = HoldingSort(rawValue:sortKey) ?? .value
        if key == .symbol {
            return rows.sorted { let order = $0.text("ticker").localizedStandardCompare($1.text("ticker")); return ascending ? order == .orderedAscending : order == .orderedDescending }
        }
        let field = ["shares":"totalShares", "price":"currentPrice", "value":"currentValue", "today":"dayChange", "gain":"profitLoss"][key.rawValue]!
        return rows.sorted { a, b in
            let x = a.number(field), y = b.number(field)
            return x == y ? a.text("ticker") < b.text("ticker") : ascending ? x < y : x > y
        }
    }
}

/// Accounts table columns; each header sorts by its column.
private enum AccountSort: String { case name, value, cash, gain, gainPercent, today }

/// Every account side by side: value, cash, gain/loss and today's change, with a totals row.
struct FinanceAccountsTable: View {
    @ObservedObject var finance: FinanceModel
    let openAccount: (String) -> Void
    @AppStorage("finance-accounts-sort") private var sortKey = AccountSort.value.rawValue
    @AppStorage("finance-accounts-ascending") private var ascending = false
    private struct Line: Identifiable {
        let id: String, name: String, type: String, value: Double, cash: Double, gain: Double, gainPercent: Double, today: Double, todayPercent: Double, priced: Bool
    }
    private func line(_ account: FinanceRow) -> Line {
        let s = finance.accountSummary(account.id)
        func n(_ key: String) -> Double { (s[key] as? NSNumber)?.doubleValue ?? 0 }
        return Line(id:account.id, name:account.name, type:account.text("type"), value:n("totalValue") - n("realEstateValue"), cash:n("cash"), gain:n("totalPL"), gainPercent:n("totalPLPercent"),
                    today:n("totalDayChange"), todayPercent:n("totalDayChangePercent"), priced:finance.scopedHoldings(account.id).allSatisfy { $0.number("currentPrice") > 0 })
    }
    var body: some View {
        ScrollView { page.pageColumn(1000) }
            .navigationTitle("All Accounts")
    }
    /// The page without its scroll view, so it can also be rendered to an image.
    var page: some View {
        let lines = sorted(finance.rows("accounts").map(line))
        return VStack(alignment:.leading, spacing:24) {
            VStack(alignment:.leading, spacing:4) {
                Text("\(lines.count) ACCOUNTS").font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.green)
                Text("All Accounts").font(MacStyle.titleFont)
            }
            if lines.isEmpty { Text("No accounts yet.").foregroundStyle(.secondary).card() }
            else { table(lines).card(padding:16) }
        }
    }
    private func table(_ lines: [Line]) -> some View {
        let priced = finance.fullyPriced
        return Grid(alignment:.trailing, horizontalSpacing:18, verticalSpacing:0) {
            GridRow {
                header("Account", .name).gridColumnAlignment(.leading); header("Total value", .value); header("Cash", .cash)
                header("Gain/Loss", .gain); header("Gain %", .gainPercent); header("Today", .today)
            }
            .padding(.bottom, 8)
            ForEach(lines) { l in
                Divider().gridCellUnsizedAxes(.horizontal)
                row(l).monospacedDigit().padding(.vertical, 9)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text("Total").gridColumnAlignment(.leading)
                Text(money(finance.total("totalValue") - finance.total("realEstateValue")))
                Text(money(finance.total("cash")))
                change(finance.total("totalPL"), known:priced)
                Text(priced ? percent(finance.total("totalPLPercent")) : "—").foregroundStyle(priced ? Color.gain(finance.total("totalPL")) : .secondary)
                todayCell(finance.total("totalDayChange"), finance.total("totalDayChangePercent"), known:priced)
            }
            .fontWeight(.semibold).monospacedDigit().padding(.vertical, 9)
        }
    }
    private func row(_ l: Line) -> some View {
        GridRow {
            Button { openAccount(l.id) } label: {
                HStack(spacing:9) {
                    Text(l.name).font(.body.weight(.semibold)).foregroundStyle(.link).lineLimit(1)
                    if typeLabel(l.type).caseInsensitiveCompare(l.name) != .orderedSame { Text(typeLabel(l.type)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(maxWidth:.infinity, alignment:.leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open \(l.name)").gridColumnAlignment(.leading)
            Text(money(l.value)).fontWeight(.medium)
            Text(money(l.cash)).foregroundStyle(.secondary)
            change(l.gain, known:l.priced)
            Text(l.priced ? percent(l.gainPercent) : "—").foregroundStyle(l.priced ? Color.gain(l.gain) : .secondary)
            todayCell(l.today, l.todayPercent, known:l.priced)
        }
    }
    private func change(_ value: Double, known: Bool) -> some View {
        Text(known ? signed(value) : "—").foregroundStyle(known ? Color.gain(value) : .secondary)
    }
    private func todayCell(_ value: Double, _ pct: Double, known: Bool) -> some View {
        VStack(alignment:.trailing, spacing:1) {
            change(value, known:known)
            if known { Text(percent(pct)).font(.caption).foregroundStyle(Color.gain(value).opacity(0.8)) }
        }
    }
    private func header(_ title: String, _ key: AccountSort) -> some View {
        Button {
            if sortKey == key.rawValue { ascending.toggle() } else { sortKey = key.rawValue; ascending = key == .name }
        } label: {
            HStack(spacing:3) {
                Text(title)
                if sortKey == key.rawValue { Image(systemName:ascending ? "chevron.up" : "chevron.down").font(.system(size:8, weight:.bold)) }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(sortKey == key.rawValue ? .primary : .secondary)
        }
        .buttonStyle(.plain).help("Sort by \(title.lowercased())")
    }
    private func sorted(_ lines: [Line]) -> [Line] {
        let key = AccountSort(rawValue:sortKey) ?? .value
        if key == .name {
            return lines.sorted { let order = $0.name.localizedStandardCompare($1.name); return ascending ? order == .orderedAscending : order == .orderedDescending }
        }
        let field: (Line) -> Double = switch key { case .cash: \.cash; case .gain: \.gain; case .gainPercent: \.gainPercent; case .today: \.today; default: \.value }
        return lines.sorted { a, b in
            let x = field(a), y = field(b)
            return x == y ? a.name < b.name : ascending ? x < y : x > y
        }
    }
}

/// One buy, sell or existing holding in the list.
private struct TransactionRow: View {
    let transaction: FinanceRow
    let ticker: String
    let account: String?
    let open: () -> Void
    let edit: () -> Void
    @State private var hovering = false
    var body: some View {
        let t = transaction, kind = t.text("type")
        HStack(spacing:12) {
            Pill(text:kind == "holding" ? "Holding" : kind.capitalized, tint:kind == "buy" ? .green : kind == "sell" ? .red : .secondary).frame(width:62, alignment:.leading)
            Button(action:open) { Text(ticker).font(.body.weight(.semibold)) }.buttonStyle(.plain).frame(width:64, alignment:.leading)
            Text("\(t.number("quantity").formatted(.number.precision(.fractionLength(0...8)))) × \(money(t.number("pricePerShare")))").monospacedDigit()
            if let account { Text(account).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength:8)
            Text(JournalDates.date(t.text("date"))?.formatted(date:.abbreviated, time:.omitted) ?? String(t.text("date").prefix(10))).foregroundStyle(.secondary).monospacedDigit()
            Button(action:edit) { Image(systemName:"pencil") }.buttonStyle(.borderless).help("Edit").opacity(hovering ? 1 : 0)
        }
        .font(.callout).padding(.vertical, 9).contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct AccountEditor: View {
    @ObservedObject var finance: FinanceModel
    let row: FinanceRow
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var type: String
    @State private var cash: String
    @State private var problem: String?
    init(finance: FinanceModel, row: FinanceRow) {
        self.finance = finance; self.row = row
        _name = State(initialValue:row.text("name")); _type = State(initialValue:row.text("type").isEmpty ? "brokerage" : row.text("type"))
        _cash = State(initialValue:row.raw["cashBalance"] == nil ? "" : String(row.number("cashBalance")))
    }
    var body: some View {
        EditorSheet(title:row.id.isEmpty ? "New Account" : "Edit Account", width:420, height:300) {
            Section {
                TextField("Name", text:$name, prompt:Text("Brokerage"))
                Picker("Type", selection:$type) { ForEach(accountTypes + (accountTypes.contains(type) ? [] : [type]), id:\.self) { Text(typeLabel($0)).tag($0) } }
                TextField("Cash balance", text:$cash, prompt:Text("0.00"))
            } footer: { if let problem { Text(problem).foregroundStyle(.red) } }
        } actions: {
            Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(row.id.isEmpty ? "Add Account" : "Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
    }
    private func save() {
        guard !name.trimmingCharacters(in:.whitespaces).isEmpty else { problem = "Enter a name."; return }
        let amount = cash.trimmingCharacters(in:.whitespaces).isEmpty ? 0 : Double(cash.replacingOccurrences(of:",", with:""))
        guard let amount, amount.isFinite else { problem = "Enter a cash balance, like 1250.00."; return }
        var updated = row
        updated.raw["name"] = name.trimmingCharacters(in:.whitespaces); updated.raw["type"] = type; updated.raw["cashBalance"] = amount
        if finance.save(updated, field:"accounts") { dismiss() }
    }
}

struct TransactionEditor: View {
    @ObservedObject var finance: FinanceModel
    let row: FinanceRow
    @Environment(\.dismiss) private var dismiss
    @State private var kind: String
    @State private var account: String
    @State private var ticker: String
    @State private var quantity: String
    @State private var price: String
    @State private var date: Date
    @State private var notes: String
    @State private var problem: String?
    init(finance: FinanceModel, row: FinanceRow) {
        self.finance = finance; self.row = row
        _kind = State(initialValue:row.text("type").isEmpty ? "buy" : row.text("type"))
        _account = State(initialValue:row.text("accountId").isEmpty ? (finance.rows("accounts").first?.id ?? "") : row.text("accountId"))
        _ticker = State(initialValue:row.text("ticker"))
        _quantity = State(initialValue:row.raw["quantity"] == nil ? "" : String(row.number("quantity")))
        _price = State(initialValue:row.raw["pricePerShare"] == nil ? "" : String(row.number("pricePerShare")))
        _date = State(initialValue:JournalDates.date(row.text("date")) ?? Date())
        _notes = State(initialValue:row.text("notes"))
    }
    var body: some View {
        EditorSheet(title:row.id.isEmpty ? "New Transaction" : "Edit Transaction", width:460, height:470) {
            Section {
                Picker("Kind", selection:$kind) { Text("Buy").tag("buy"); Text("Sell").tag("sell"); Text("Existing holding").tag("holding") }.pickerStyle(.segmented)
                Picker("Account", selection:$account) { ForEach(finance.rows("accounts")) { Text($0.name).tag($0.id) } }
            } footer: {
                Text(kind == "holding" ? "Records shares you already own. Cash isn't changed." : kind == "buy" ? "Takes the cost out of the account's cash." : "Adds the proceeds to the account's cash.")
            }
            Section {
                TextField("Symbol", text:$ticker, prompt:Text("VTI"))
                TextField("Shares", text:$quantity, prompt:Text("10"))
                TextField("Price per share", text:$price, prompt:Text("250.00"))
                DatePicker("Date", selection:$date, displayedComponents:.date)
                TextField("Notes", text:$notes, prompt:Text("Optional"))
            } footer: { if let problem { Text(problem).foregroundStyle(.red) } }
        } actions: {
            if !row.id.isEmpty { Button("Delete", role:.destructive) { if finance.saveTransaction(row, deleting:true) { dismiss() } } }
            Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(row.id.isEmpty ? "Add" : "Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
    }
    private func save() {
        let symbol = ticker.trimmingCharacters(in:.whitespaces).uppercased()
        guard !symbol.isEmpty else { problem = "Enter a symbol, like VTI."; return }
        guard let shares = Double(quantity.replacingOccurrences(of:",", with:"")), shares > 0, shares.isFinite else { problem = "Enter how many shares."; return }
        guard let each = Double(price.replacingOccurrences(of:",", with:"")), each > 0, each.isFinite else { problem = "Enter the price per share."; return }
        guard !account.isEmpty else { problem = "Choose an account."; return }
        var updated = row
        updated.raw["type"] = kind; updated.raw["accountId"] = account; updated.raw["ticker"] = symbol
        updated.raw["quantity"] = shares; updated.raw["pricePerShare"] = each
        // A plain local date, as the iPhone and the original Mac app store it.
        let day = DateFormatter(); day.locale = Locale(identifier:"en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        updated.raw["date"] = day.string(from:date); updated.raw["notes"] = notes
        if finance.saveTransaction(updated) { dismiss() }
    }
}
