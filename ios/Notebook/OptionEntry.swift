import SwiftUI
import NotebookCore

/// A call or put entered by hand: the parts of its contract symbol.
struct OptionDraft: Equatable {
    var underlying = "", type = "call", expiration = "", strike = ""
    init() {}
    /// From `FinanceModel.optionMeta`, to edit a logged trade.
    init(_ meta: [String:Any]?) {
        guard let meta else { return }
        underlying = meta["underlying"] as? String ?? ""; type = meta["optionType"] as? String == "put" ? "put" : "call"
        expiration = meta["expiration"] as? String ?? ""
        strike = (meta["strike"] as? NSNumber).map { Self.strikeText($0.doubleValue) } ?? ""
    }
    var root: String { underlying.trimmingCharacters(in:.whitespaces).uppercased() }
    var strikeValue: Double? { Double(strike.replacingOccurrences(of:",", with:"").replacingOccurrences(of:"$", with:"")).flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
    static func strikeText(_ strike: Double) -> String { strike.formatted(.number.precision(.fractionLength(0...3)).grouping(.never).locale(Locale(identifier:"en_US_POSIX"))) }
    /// The contract symbol Finance stores (AAPL261218C00250000).
    func symbol() throws -> String {
        guard root.wholeMatch(of:/[A-Z.]{1,6}/) != nil else { throw NotebookError.message("Enter the stock the option is on, like AAPL.") }
        guard expiration.wholeMatch(of:/20\d\d-\d\d-\d\d/) != nil else { throw NotebookError.message("Choose the expiration date.") }
        guard let strikeValue, strikeValue < 100_000 else { throw NotebookError.message("Enter the strike price, like 250.") }
        return RobinhoodLink.occ(root, expiration:expiration, type, strikeValue)
    }
}

/// Underlying, call or put, expiration and strike. With Robinhood connected
/// the expirations and strikes come from its chain, with the live bid and ask,
/// and the mid can fill the price. Otherwise they're typed in.
struct OptionContractFields: View {
    @ObservedObject var finance: FinanceModel
    @Binding var draft: OptionDraft
    @Binding var price: String
    @State private var expirations: [String] = []
    @State private var contracts: [RobinhoodLink.ListedOption] = []
    @State private var loading = false
    private static let local: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    private var chosen: RobinhoodLink.ListedOption? { draft.strikeValue.flatMap { s in contracts.first { abs($0.strike - s) < 0.0005 } } }
    private var chainKey: String { "\(draft.root)|\(draft.expiration)|\(draft.type)|\(expirations.count)" }
    var body: some View {
        underlyingField
            .task(id:draft.root) { await loadExpirations() }
            .task(id:chainKey) { await loadContracts() }
        Picker("Type", selection:$draft.type) { Text("Call").tag("call"); Text("Put").tag("put") }.pickerStyle(.segmented)
        if expirations.isEmpty {
            DatePicker("Expiration", selection:expirationDate, displayedComponents:.date)
        } else {
            Picker("Expiration", selection:$draft.expiration) {
                if !expirations.contains(draft.expiration) { Text(draft.expiration.isEmpty ? "Choose" : Self.label(draft.expiration)).tag(draft.expiration) }
                ForEach(expirations, id:\.self) { Text(Self.label($0)).tag($0) }
            }
        }
        if contracts.isEmpty {
            TextField("Strike", text:$draft.strike, prompt:Text("250")).accessibilityIdentifier("finance-strike")
        } else {
            Picker("Strike", selection:$draft.strike) {
                if chosen == nil { Text(draft.strike.isEmpty ? "Choose" : "$" + draft.strike).tag(draft.strike) }
                ForEach(contracts) { c in Text(Self.strikeLabel(c)).tag(OptionDraft.strikeText(c.strike)) }
            }
        }
        if let q = chosen?.quote {
            HStack {
                Text("Bid \(Self.money(q.bid)) · Ask \(Self.money(q.ask))").foregroundStyle(.secondary)
                Spacer(minLength:8)
                Button("Use \(Self.money(q.mark))") { price = String(format:"%.2f", q.mark) }.help("Fill in the middle of the bid and ask")
            }.font(.callout)
        } else if loading {
            HStack(spacing:8) { ProgressView().controlSize(.small); Text("Looking up Robinhood…").foregroundStyle(.secondary) }.font(.callout)
        }
    }
    @ViewBuilder private var underlyingField: some View {
        #if os(iOS)
        TextField("Underlying stock", text:$draft.underlying, prompt:Text("AAPL")).textInputAutocapitalization(.characters).autocorrectionDisabled().accessibilityIdentifier("finance-underlying")
        #else
        TextField("Underlying stock", text:$draft.underlying, prompt:Text("AAPL")).autocorrectionDisabled()
        #endif
    }
    private var expirationDate: Binding<Date> {
        Binding(get:{ Self.local.date(from:draft.expiration) ?? Date() }, set:{ draft.expiration = Self.local.string(from:$0) })
    }
    private func loadExpirations() async {
        if draft.expiration.isEmpty { draft.expiration = Self.local.string(from:Date()) }
        let root = draft.root
        guard let robinhood = finance.robinhood, robinhood.connected, root.wholeMatch(of:/[A-Z.]{1,6}/) != nil else { expirations = []; return }
        try? await Task.sleep(for:.milliseconds(400))
        guard !Task.isCancelled else { return }
        loading = true
        let found = await robinhood.optionExpirations(root)
        loading = false
        guard !Task.isCancelled else { return }
        expirations = found
        // A new trade starts on the nearest listed date on or after the one shown; a logged
        // contract that has already expired keeps its date.
        let today = TradingModel.day.string(from:Date())
        if !found.isEmpty, !found.contains(draft.expiration), draft.expiration >= today { draft.expiration = found.first { $0 >= draft.expiration } ?? found[0] }
    }
    private func loadContracts() async {
        let root = draft.root, expiration = draft.expiration, type = draft.type
        guard let robinhood = finance.robinhood, robinhood.connected, expirations.contains(expiration) else { contracts = []; return }
        loading = true
        let found = await robinhood.optionContracts(root, expiration:expiration, type:type)
        loading = false
        guard !Task.isCancelled else { return }
        contracts = found
    }
    private static func label(_ day: String) -> String {
        guard let date = local.date(from:day) else { return day }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
    private static func strikeLabel(_ c: RobinhoodLink.ListedOption) -> String {
        "$" + OptionDraft.strikeText(c.strike) + (c.quote.map { "  ·  " + money($0.mark) } ?? "")
    }
    private static func money(_ value: Double) -> String { value.formatted(.currency(code:"USD")) }
}
