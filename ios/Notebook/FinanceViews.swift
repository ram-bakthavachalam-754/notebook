import SwiftUI
import Charts
import UniformTypeIdentifiers

private enum FinanceTone {
    static let gain = Color(uiColor:UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red:0.34,green:0.84,blue:0.59,alpha:1)
        : UIColor(red:0.08,green:0.43,blue:0.28,alpha:1) })
    static let loss = Color(uiColor:UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red:1,green:0.48,blue:0.47,alpha:1)
        : UIColor(red:0.75,green:0.18,blue:0.21,alpha:1) })
    static func color(_ value: Double) -> Color { value > 0 ? gain : value < 0 ? loss : .secondary }
}

/// Color reinforces the sign and direction; unchanged values stay neutral.
private struct FinanceChange: View {
    let amount: Double
    var percent: Double?
    private var rounded: Double { (amount * 100).rounded() / 100 }
    private var direction: String { rounded > 0 ? "Gain" : rounded < 0 ? "Loss" : "Unchanged" }
    private var value: String {
        let money = abs(rounded).formatted(.currency(code:"USD"))
        let signed = (rounded > 0 ? "+" : rounded < 0 ? "−" : "") + money
        guard let percent, percent.isFinite else { return signed }
        let percentage = (percent * 100).rounded() / 100
        let sign = percentage > 0 ? "+" : percentage < 0 ? "−" : ""
        return "\(signed) (\(sign)\(abs(percentage).formatted(.number.precision(.fractionLength(2))))%)"
    }
    var body: some View {
        HStack(alignment:.firstTextBaseline,spacing:4) {
            Image(systemName:rounded > 0 ? "arrow.up.right" : rounded < 0 ? "arrow.down.right" : "minus").accessibilityHidden(true)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .fontWeight(.medium).foregroundStyle(FinanceTone.color(rounded))
        .accessibilityElement(children:.ignore).accessibilityLabel("\(direction), \(value)")
    }
}

private struct FinancePerformance: View {
    let title: String
    let amount: Double
    var percent: Double?
    var body: some View {
        LabeledContent { FinanceChange(amount:amount,percent:percent) } label: { Text(title).foregroundStyle(.secondary) }
            .font(.subheadline)
    }
}

struct FinanceEdit: Identifiable {
    let id = UUID()
    var field: String
    var row: FinanceRow
}
struct NotebookFinance: View {
    @ObservedObject var notebook: NotebookModel
    @StateObject private var model: FinanceModel
    @State private var section = "Investments"
    @State private var edit: FinanceEdit?
    @State private var importing = false
    @State private var exporting = false
    @State private var document: FinanceDocument?
    @State private var pendingImport: [String:Any]?
    @State private var spendingCategory: FinanceRow?
    @State private var settings = false
    init(notebook: NotebookModel) {
        self.notebook = notebook
        _model = StateObject(wrappedValue:FinanceModel(store:notebook.store,shares:notebook.shareLibrary,authorized:{ [weak notebook] in notebook?.unlocked == true }))
    }
    var body: some View {
        NavigationStack {
            List {
                Section { Picker("Finance section",selection:$section) { Text("Investments").tag("Investments"); Text("Spending").tag("Spending") }.pickerStyle(.segmented) }
                if let notice = model.notice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
                if !model.loaded { Section { HStack { Spacer(); ProgressView(); Spacer() } }.listRowBackground(Color.clear) }
                else if section == "Investments" { investments }
                else { FinanceSpending(model:model,selected:$spendingCategory) }
            }
            .navigationTitle("Finance")
            .scrollContentBackground(.hidden).background(Color.notebookPaper)
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Button { settings = true } label: { Image(systemName:"gearshape") }.accessibilityLabel("Finance sync settings") }
                ToolbarItem(placement:.topBarTrailing) {
                    Menu {
                        Button("New account",systemImage:"plus") { edit = FinanceEdit(field:"accounts",row:FinanceRow(raw:[:])) }
                        Button("Add transaction",systemImage:"plus.circle") { edit = FinanceEdit(field:"transactions",row:FinanceRow(raw:[:])) }.disabled(model.rows("accounts").isEmpty)
                        Button("Add property",systemImage:"house") { edit = FinanceEdit(field:"properties",row:FinanceRow(raw:[:])) }
                        Button("Add loan or mortgage",systemImage:"banknote") { edit = FinanceEdit(field:"liabilities",row:FinanceRow(raw:[:])) }
                        Divider()
                        Button("Refresh prices",systemImage:"arrow.clockwise") { Task { await model.refreshPrices() } }.disabled(model.refreshing)
                        Button("Take snapshot",systemImage:"camera") { model.takeSnapshot() }
                        Divider()
                        Button("Import Finance data",systemImage:"square.and.arrow.down") { importing = true }
                        Button("Export Finance data",systemImage:"square.and.arrow.up") { do { document = try model.exportDocument(); exporting = true } catch { model.error = error.localizedDescription } }
                    } label: { Image(systemName:"ellipsis.circle") }.accessibilityLabel("Finance actions")
                }
            }
            .refreshable { await notebook.sync(); model.reload(); await model.refreshPrices() }
            .task { while !Task.isCancelled { await model.refreshIfStale(); try? await Task.sleep(for:.seconds(60)) } }
            .sheet(item:$edit) { FinanceEditor(model:model,edit:$0) }
            .sheet(item:$spendingCategory) { FinanceCategoryEditor(model:model,row:$0) }
            .sheet(isPresented:$settings) { NotebookSettings(model:notebook) }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.json]) { result in
                do {
                    let url = try result.get(); let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    guard size <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    pendingImport = try model.parseImport(Data(contentsOf:url))
                } catch { model.error = error.localizedDescription }
            }
            .fileExporter(isPresented:$exporting,document:document,contentType:.json,defaultFilename:"nenva-finance-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { result in
                if case .failure(let error) = result { model.error = error.localizedDescription }
            }
            .alert("Import Finance data?",isPresented:Binding(get:{pendingImport != nil},set:{if !$0 {pendingImport=nil}})) {
                Button("Cancel",role:.cancel) { pendingImport = nil }
                Button("Import") { if let pendingImport { model.applyImport(pendingImport) }; pendingImport = nil }
            } message: { Text("\(pendingImport.map(model.importSummary) ?? ""). Newer records are merged with what is here. Existing records are not removed. Bank connections do not transfer.") }
            .alert("Finance",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) { Button("OK") {model.error=nil} } message: { Text(model.error ?? "") }
            .onChange(of:notebook.reloadVersion) { _,_ in Task { await model.refresh() } }
            .onReceive(NotificationCenter.default.publisher(for:.notebookSharesChanged)) { _ in model.reload() }
            .onChange(of:notebook.unlocked) { _,unlocked in model.accessLocked = !unlocked; if !unlocked { spendingCategory=nil; edit=nil; importing=false; exporting=false; pendingImport=nil; settings=false } }
        }
    }
    private func accountDetail(_ row: FinanceRow) -> String {
        let type = row.text("type").capitalized
        return notebook.sharing.share(kind:"account",entity:row.id) == nil ? type : type + " · Shared"
    }
    @ViewBuilder var investments: some View {
        Section {
            VStack(alignment:.leading,spacing:10) {
                Text("Net worth").font(.subheadline).foregroundStyle(.secondary)
                Text(model.fullyPriced ? model.money(model.total("netWorth")) : "—").font(.system(size:36,weight:.regular,design:.serif)).minimumScaleFactor(0.5).lineLimit(1).accessibilityIdentifier("finance-net-worth")
                if !model.fullyPriced { Text("Refresh prices to value every holding.").font(.footnote).foregroundStyle(.secondary) }
                if model.fullyPriced && !model.holdings.isEmpty {
                    FinancePerformance(title:"Today",amount:model.total("totalDayChange"),percent:model.total("totalDayBase") > 0 ? model.total("totalDayChangePercent") : nil)
                    FinancePerformance(title:"Unrealized gain / loss",amount:model.total("totalPL"),percent:model.total("totalCost") > 0 ? model.total("totalPLPercent") : nil)
                    Divider()
                }
                HStack { Text("Cash"); Spacer(); Text(model.money(model.total("cash"))) }.font(.subheadline)
                if model.total("realEstateValue") != 0 { HStack { Text("Property"); Spacer(); Text(model.money(model.total("realEstateValue"))) }.font(.subheadline) }
                if model.total("liabilitiesTotal") != 0 { HStack { Text("Debt"); Spacer(); Text(model.money(model.total("liabilitiesTotal"))) }.font(.subheadline) }
            }.padding(.vertical,8)
            if model.snapshots.count > 1 { FinanceHistoryChart(rows:model.snapshots).frame(height:170) }
            NavigationLink("Snapshots (\(model.snapshots.count))") { FinanceSnapshots(model:model) }
        }
        if model.rows("accounts").isEmpty && model.rows("properties").isEmpty {
            Section {
                ContentUnavailableView("Your money, together.",systemImage:"chart.line.uptrend.xyaxis",description:Text("Import a Finance export file, or start with an account."))
                Button("Import Finance file") { importing = true }
                Button("New account") { edit = FinanceEdit(field:"accounts",row:FinanceRow(raw:[:])) }
            }
        }
        Section("Accounts") {
            ForEach(model.rows("accounts")) { row in
                NavigationLink { FinanceAccount(model:model,accountID:row.id,sharing:notebook.sharing) } label: { FinanceNameValue(name:row.name,detail:accountDetail(row),value:model.money(row.number("cashBalance")) + " cash") }
            }
        }
        if !model.sharedAccounts.isEmpty {
            Section("Shared with you") {
                ForEach(model.sharedAccounts) { shared in
                    let view = SharedAccountView(info:shared.info, view:shared.view, price:model.price)
                    NavigationLink { view } label: { FinanceNameValue(name:shared.view["name"] as? String ?? shared.info.title,detail:"From \(shared.info.ownerName.isEmpty ? "someone" : shared.info.ownerName) · View only",value:model.money(view.total)) }
                }
            }
        }
        if !model.holdings.isEmpty {
            Section("Holdings") { ForEach(model.holdings) { row in NavigationLink { FinanceHolding(model:model,ticker:row.text("ticker")) } label: { FinanceHoldingRow(model:model,row:row) } } }
        }
        ForEach(["properties","liabilities"],id:\.self) { field in
            if !model.rows(field).isEmpty {
                Section(field == "properties" ? "Property" : "Loans and mortgages") {
                    ForEach(model.rows(field)) { row in
                        Button { edit = FinanceEdit(field:field,row:row) } label: { FinanceNameValue(name:row.name,detail:row.text("address").isEmpty ? row.text("lender") : row.text("address"),value:model.money(row.number(field == "properties" ? "currentValue" : "balance"))) }.foregroundStyle(.primary)
                    }
                }
            }
        }
        if !model.rows("strategies").isEmpty {
            Section("Strategies") { ForEach(model.rows("strategies")) { row in NavigationLink(row.name) { FinanceStrategy(model:model,row:row) } } }
        }
    }
}
struct FinanceNameValue: View {
    var name: String
    var detail = ""
    var value: String
    var body: some View {
        HStack(alignment:.firstTextBaseline) {
            VStack(alignment:.leading,spacing:4) { Text(name); if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) } }
            Spacer(minLength:12); Text(value).monospacedDigit().foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }.padding(.vertical,4)
    }
}
struct FinanceHoldingRow: View {
    @ObservedObject var model: FinanceModel
    let row: FinanceRow
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            FinanceNameValue(name:row.text("ticker"),detail:"\(row.number("totalShares").formatted(.number.precision(.fractionLength(0...8)))) shares · \(model.money(row.number("avgCostBasis"))) average cost",value:row.number("currentPrice") > 0 ? model.money(row.number("currentValue")) : "Unpriced")
            if row.number("currentPrice") > 0 {
                HStack(alignment:.firstTextBaseline) {
                    Text("Gain / loss").foregroundStyle(.secondary)
                    Spacer(minLength:8)
                    FinanceChange(amount:row.number("profitLoss"),percent:row.number("costBasis") > 0 ? row.number("profitLossPercent") : nil)
                }.font(.caption)
            }
        }.padding(.vertical,3)
    }
}
struct FinanceHistoryChart: View {
    let rows: [FinanceRow]
    var body: some View {
        Chart(rows) { row in
            if let date = ISO8601DateFormatter().date(from:row.id + "T12:00:00Z") {
                LineMark(x:.value("Date",date),y:.value("Net worth",row.raw["netWorth"] as? Double ?? row.number("totalValue") - row.number("liabilities"))).foregroundStyle(Color.notebookBlue)
            }
        }.chartYScale(domain:.automatic(includesZero:false)).accessibilityLabel("Net worth history")
    }
}
/// An account's value in each daily snapshot.
struct FinanceValueChart: View {
    let points: [(date: Date, value: Double)]
    var body: some View {
        Chart(points, id:\.date) { point in LineMark(x:.value("Date",point.date),y:.value("Value",point.value)).foregroundStyle(Color.notebookBlue) }
            .chartYScale(domain:.automatic(includesZero:false)).accessibilityLabel("Value history")
    }
}
struct FinanceSnapshots: View {
    @ObservedObject var model: FinanceModel
    @State private var deleting: FinanceRow?
    var body: some View {
        List {
            if model.snapshots.count > 1 { FinanceHistoryChart(rows:model.snapshots).frame(height:200) }
            ForEach(model.snapshots.reversed()) { row in
                NavigationLink { List {
                    LabeledContent("Total assets",value:model.money(row.number("totalValue")))
                    LabeledContent("Net worth",value:model.money(row.raw["netWorth"] as? Double ?? row.number("totalValue") - row.number("liabilities")))
                    ForEach(["cash","stockValue","realEstateValue","liabilities"],id:\.self) { key in LabeledContent(key == "stockValue" ? "Investments" : key == "realEstateValue" ? "Property" : key.capitalized,value:model.money(row.number(key))) }
                    if let tickers=row.raw["tickers"] as? [String:[String:Any]] { Section("Holdings that day") { ForEach(tickers.keys.sorted(),id:\.self) { ticker in FinanceNameValue(name:ticker,detail:"\((tickers[ticker]?["shares"] as? Double ?? 0).formatted()) shares",value:model.money(tickers[ticker]?["value"] as? Double ?? 0)) } } }
                }.navigationTitle(row.id) } label: { FinanceNameValue(name:row.id,value:model.money(row.raw["netWorth"] as? Double ?? row.number("totalValue") - row.number("liabilities"))) }
                .swipeActions { Button("Delete",role:.destructive) { deleting=row } }
            }
        }.navigationTitle("Snapshots")
        .toolbar { Button("Take snapshot") { model.takeSnapshot() } }
        .confirmationDialog("Delete this snapshot?",isPresented:Binding(get:{deleting != nil},set:{if !$0{deleting=nil}})) { Button("Delete",role:.destructive) { if let deleting { model.delete(deleting,field:"snapshots") }; deleting=nil } }
    }
}
struct FinanceAccount: View {
    @ObservedObject var model: FinanceModel
    let accountID: String
    var sharing: SharingModel? = nil
    @State private var edit: FinanceEdit?
    @State private var sharingSheet = false
    var account: FinanceRow { model.rows("accounts").first { $0.id == accountID } ?? FinanceRow(raw:[:]) }
    var body: some View {
        List {
            Section {
                let history = model.valueHistory(accountID)
                if history.count > 1 { FinanceValueChart(points:history).frame(height:170) }
                LabeledContent("Value",value:model.money((model.accountSummary(accountID)["totalValue"] as? NSNumber)?.doubleValue ?? 0))
                LabeledContent("Cash",value:model.money(account.number("cashBalance"))); Button("Edit account") { edit=FinanceEdit(field:"accounts",row:account) }
            }
            Section("Holdings") { ForEach(model.scopedHoldings(accountID)) { row in NavigationLink { FinanceHolding(model:model,ticker:row.text("ticker")) } label: { FinanceHoldingRow(model:model,row:row) } } }
            Section("Transactions") { ForEach(model.rows("transactions").filter{$0.text("accountId")==accountID}.sorted{$0.text("date")>$1.text("date")}) { row in Button { edit=FinanceEdit(field:"transactions",row:row) } label: { FinanceNameValue(name:row.text("ticker"),detail:"\(row.text("type").capitalized) · \(row.text("date"))",value:"\(row.number("quantity").formatted(.number.precision(.fractionLength(0...8)))) × \(model.money(row.number("pricePerShare")))") }.foregroundStyle(.primary) } }
        }.navigationTitle(account.name)
        .toolbar {
            if let sharing { Button { sharingSheet = true } label: { Image(systemName:sharing.share(kind:"account",entity:accountID) == nil ? "person.crop.circle.badge.plus" : "person.2.fill") }.accessibilityLabel("Share") }
            Button { edit=FinanceEdit(field:"transactions",row:FinanceRow(raw:["accountId":accountID])) } label: { Image(systemName:"plus") }.accessibilityLabel("Add transaction")
        }
        .sheet(item:$edit) { FinanceEditor(model:model,edit:$0) }
        .sheet(isPresented:$sharingSheet) {
            if let sharing {
                ShareSheet(sharing:sharing, kind:"account", title:account.name, existing:sharing.share(kind:"account",entity:accountID)?.id) { level in
                    guard let view = model.accountView(accountID, level:level) else { return nil }
                    return await sharing.shareAccount(account, level:level, view:view)
                }
            }
        }
    }
}
struct FinanceHolding: View {
    @ObservedObject var model: FinanceModel
    let ticker: String
    var holding: FinanceRow { model.holdings.first{$0.text("ticker")==ticker} ?? FinanceRow(raw:[:]) }
    var body: some View {
        List {
            Section {
                FinanceHoldingRow(model:model,row:holding)
                LabeledContent("Cost basis",value:model.money(holding.number("costBasis")))
                if holding.number("currentPrice") > 0 {
                    LabeledContent("Share price",value:model.money(holding.number("currentPrice")))
                    FinancePerformance(title:"Today",amount:holding.number("dayChange"),percent:holding.number("dayBase") > 0 ? holding.number("dayChangePercent") : nil)
                    FinancePerformance(title:"Unrealized gain / loss",amount:holding.number("profitLoss"),percent:holding.number("costBasis") > 0 ? holding.number("profitLossPercent") : nil)
                }
            }
            Section("By account") { ForEach(model.rows("accounts").filter{a in model.scopedHoldings(a.id).contains{$0.text("ticker")==ticker}}) { account in NavigationLink(account.name) { FinanceAccount(model:model,accountID:account.id) } } }
            Section("Transactions") { ForEach(model.rows("transactions").filter{$0.text("ticker")==ticker}.sorted{$0.text("date")>$1.text("date")}) { row in FinanceNameValue(name:row.text("type").capitalized,detail:row.text("date"),value:"\(row.number("quantity").formatted(.number.precision(.fractionLength(0...8)))) × \(model.money(row.number("pricePerShare")))") } }
        }.navigationTitle(ticker)
    }
}
struct FinanceStrategy: View {
    @ObservedObject var model: FinanceModel
    let row: FinanceRow
    var body: some View {
        List {
            if !row.text("objective").isEmpty { Section("Objective") { Text(row.text("objective")) } }
            ForEach(["horizon","riskLevel","thesis","reviewCadence","notes"],id:\.self) { key in if !row.text(key).isEmpty { Section(key == "riskLevel" ? "Risk" : key == "reviewCadence" ? "Review cadence" : key.capitalized) { Text(row.text(key)) } } }
            let report = model.strategyReport(row)
            if let headline=report["headline"] as? String { Section("Against your holdings") { Text(headline); if !model.fullyPriced { Text("Some holdings have no current price.").foregroundStyle(.secondary) } } }
            if let targets=row.raw["targets"] as? [[String:Any]] { Section("Target mix") { ForEach(Array(targets.enumerated()),id:\.offset) { _,target in VStack(alignment:.leading) { Text(target["name"] as? String ?? target["label"] as? String ?? "Target"); Text((target["symbols"] as? [String] ?? target["tickers"] as? [String] ?? []).joined(separator:", ")).font(.caption).foregroundStyle(.secondary); Text("\((target["targetPct"] as? Double ?? target["weight"] as? Double ?? target["target"] as? Double ?? target["pct"] as? Double ?? 0).formatted())%").font(.subheadline) } } } }
            if let rules=row.raw["rules"] as? [[String:Any]] { Section("Guardrails") { ForEach(Array(rules.enumerated()),id:\.offset) { _,rule in Text(rule["text"] as? String ?? rule["description"] as? String ?? rule["label"] as? String ?? rule["kind"] as? String ?? "Guardrail") } } }
        }.navigationTitle(row.name)
    }
}
struct FinanceSpending: View {
    @ObservedObject var model: FinanceModel
    @State private var month = Date().formatted(.iso8601.year().month().dateSeparator(.dash))
    @State private var filter = ""
    @Binding var selected: FinanceRow?
    var months: [String] { Array(Set(model.rows("transactions",bank:true).map{String($0.text("date").prefix(7))} + [Date().formatted(.iso8601.year().month().dateSeparator(.dash))])).sorted(by:>) }
    var transactions: [FinanceRow] { model.rows("transactions",bank:true).filter { $0.text("date").hasPrefix(month) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.text("merchant").localizedCaseInsensitiveContains(filter)) }.sorted{$0.text("date")>$1.text("date")} }
    var body: some View {
        if model.rows("accounts",bank:true).isEmpty { Section { Text("Import bank and card spending from a Finance export file using the Finance actions menu.").foregroundStyle(.secondary) } }
        else {
            Section {
                Picker("Month",selection:$month) { ForEach(months,id:\.self) { Text($0).tag($0) } }
                TextField("Search merchant",text:$filter)
            }
            Section("This month") {
                let summary = model.spendingSummary(month)
                LabeledContent("Spent",value:model.money(summary["spend"] as? Double ?? 0))
                LabeledContent("Refunds",value:model.money(summary["refunds"] as? Double ?? 0))
                LabeledContent("Income",value:model.money(summary["income"] as? Double ?? 0))
                if let categories=summary["byCategory"] as? [[String:Any]] {
                    ForEach(Array(categories.enumerated()),id:\.offset) { _,category in FinanceNameValue(name:category["label"] as? String ?? "Other",value:model.money(category["total"] as? Double ?? 0)) }
                }
            }
            Section("Bank and card accounts") { ForEach(model.rows("accounts",bank:true)) { row in FinanceNameValue(name:row.name,detail:row.text("type").capitalized,value:model.money((row.raw["balance"] as? [String:Any])?["current"] as? Double ?? 0)) } }
            Section("Transactions · \(transactions.count)") { ForEach(transactions) { row in Button { selected=row } label: { FinanceNameValue(name:row.text("merchant").isEmpty ? row.name : row.text("merchant"),detail:"\(row.text("date")) · \(model.spendingCategory(row))",value:model.money(row.number("amount"))) }.foregroundStyle(.primary) } }
            Section("Category rules") { ForEach(model.rows("rules",bank:true)) { row in FinanceNameValue(name:row.text("merchant"),value:row.text("category").replacingOccurrences(of:"_",with:" ").capitalized) } }
        }
    }
}
struct FinanceCategoryEditor: View {
    @ObservedObject var model: FinanceModel
    var row: FinanceRow
    @State private var category = "OTHER"
    @State private var allFromMerchant = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Picker("Category",selection:$category) {
                    ForEach(model.categories.keys.sorted(),id:\.self) { key in
                        Text(model.categories[key] ?? key).tag(key)
                    }
                }
                Toggle("Apply to this merchant",isOn:$allFromMerchant)
            }
            .navigationTitle("Category")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button("Save") { if model.setCategory(row,category:category,allFromMerchant:allFromMerchant) { dismiss() } }
                }
            }
            .alert("Could not save",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) {
                Button("OK") {model.error=nil}
            } message: { Text(model.error ?? "") }
        }
        .onAppear { category=model.categoryID(row) }
        .onChange(of:model.accessLocked) { _,locked in if locked { dismiss() } }
    }
}
