import SwiftUI

struct FinanceEditor: View {
    @ObservedObject var model: FinanceModel
    let edit: FinanceEdit
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = "brokerage"
    @State private var value = ""
    @State private var account = ""
    @State private var ticker = ""
    @State private var asset = "stock"
    @State private var option = OptionDraft()
    @State private var quantity = ""
    @State private var price = ""
    @State private var date = Date()
    @State private var address = ""
    @State private var lender = ""
    @State private var interest = ""
    @State private var payment = ""
    @State private var property = ""
    @State private var notes = ""
    @State private var deleting = false
    @State private var validation: String?
    var transaction: Bool { edit.field == "transactions" }
    var title: String { transaction ? "Transaction" : edit.field == "accounts" ? "Account" : edit.field == "properties" ? "Property" : "Loan or mortgage" }
    var body: some View {
        NavigationStack {
            Form {
                if transaction {
                    Section {
                        Picker("Kind",selection:$type) { Text("Buy").tag("buy"); Text("Sell").tag("sell"); Text("Holding").tag("holding") }.pickerStyle(.segmented)
                        Picker("Account",selection:$account) { ForEach(model.rows("accounts")) { row in Text(row.name).tag(row.id) } }
                        Picker("Asset",selection:$asset) { Text("Stock").tag("stock"); Text("Option").tag("option") }.pickerStyle(.segmented).accessibilityIdentifier("finance-asset")
                    }
                    Section {
                        if asset == "option" {
                            OptionContractFields(finance:model,draft:$option,price:$price)
                        } else {
                            TextField("Ticker",text:$ticker).textInputAutocapitalization(.characters).autocorrectionDisabled().accessibilityIdentifier("finance-ticker")
                        }
                        TextField(asset == "option" ? "Contracts" : "Shares",text:$quantity).keyboardType(.decimalPad).accessibilityIdentifier("finance-quantity")
                        TextField(asset == "option" ? "Premium per share" : "Price per share",text:$price).keyboardType(.decimalPad).accessibilityIdentifier("finance-price")
                        DatePicker("Date",selection:$date,displayedComponents:.date)
                    } footer: { Text(footer) }
                } else {
                    Section {
                        TextField("Name",text:$name).accessibilityIdentifier("finance-name")
                        if edit.field == "accounts" {
                            Picker("Type",selection:$type) { ForEach(["brokerage","401k","ira","roth_ira","hsa","cash","other"],id:\.self) { Text($0.replacingOccurrences(of:"_",with:" ").capitalized).tag($0) } }
                            TextField("Cash balance",text:$value).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("finance-value")
                        } else if edit.field == "properties" {
                            TextField("Current value",text:$value).keyboardType(.decimalPad).accessibilityIdentifier("finance-value")
                            TextField("Address",text:$address)
                        } else {
                            Picker("Type",selection:$type) { ForEach(["mortgage","loan","credit_line","other"],id:\.self) { Text($0.replacingOccurrences(of:"_",with:" ").capitalized).tag($0) } }
                            TextField("Balance owed",text:$value).keyboardType(.decimalPad).accessibilityIdentifier("finance-value")
                            TextField("Lender",text:$lender)
                            TextField("Interest rate (%)",text:$interest).keyboardType(.decimalPad)
                            TextField("Monthly payment",text:$payment).keyboardType(.decimalPad)
                            Picker("Property",selection:$property) { Text("None").tag(""); ForEach(model.rows("properties")) { Text($0.name).tag($0.id) } }
                        }
                    }
                }
                Section("Notes") { TextEditor(text:$notes).frame(minHeight:90) }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if !edit.row.id.isEmpty { Section { Button("Delete \(title.lowercased())",role:.destructive) { deleting=true } } }
            }
            .navigationTitle((edit.row.id.isEmpty ? "New " : "Edit ") + title.lowercased())
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Save") { save() }.accessibilityIdentifier("finance-save") }
            }
            .onAppear { load() }
            .confirmationDialog("Delete this \(title.lowercased())?",isPresented:$deleting,titleVisibility:.visible) {
                Button("Delete",role:.destructive) { if transaction { if model.saveTransaction(edit.row,deleting:true) { dismiss() } } else { model.delete(edit.row,field:edit.field); if model.error == nil { dismiss() } } }
            } message: { Text(edit.field == "accounts" ? "This also removes its transactions. Other accounts are kept." : "This record will be removed from Finance on your paired devices.") }
            .alert("Could not save",isPresented:Binding(get:{model.error != nil},set:{if !$0{model.error=nil}})) { Button("OK") {model.error=nil} } message: { Text(model.error ?? "") }
        }
        .interactiveDismissDisabled(!name.isEmpty || !ticker.isEmpty || !option.underlying.isEmpty)
        .onChange(of:model.accessLocked) { _,locked in if locked { dismiss() } }
    }
    var footer: String {
        let cash = type == "holding" ? "Records an existing position at its average cost without changing cash." : type == "buy" ? "Takes the cost out of the account's cash." : "Adds the proceeds to the account's cash."
        guard asset == "option" else { return cash }
        let each = Double(price) ?? 0, count = Double(quantity) ?? 0
        let total = each > 0 && count > 0 ? " Here: \(model.money(each * count * 100))." : ""
        return "\(type == "sell" ? "Sell to close" : "Buy to open") a call or put. One contract covers 100 shares, so it costs the premium × 100.\(total) \(cash)"
    }
    func load() {
        let row=edit.row
        name=row.name == row.id ? "" : row.name; notes=row.text("notes")
        type=row.text("type").isEmpty ? (transaction ? "buy" : edit.field == "liabilities" ? "mortgage" : "brokerage") : row.text("type")
        account=row.text("accountId").isEmpty ? (model.rows("accounts").first?.id ?? "") : row.text("accountId")
        ticker=row.text("ticker"); if let meta=model.optionMeta(ticker) { asset="option"; option=OptionDraft(meta) }
        quantity=row.raw["quantity"].map{String(describing:$0)} ?? ""; price=row.raw["pricePerShare"].map{String(describing:$0)} ?? ""
        let key=edit.field == "accounts" ? "cashBalance" : edit.field == "properties" ? "currentValue" : "balance"
        value=row.raw[key].flatMap{$0 is NSNull ? nil : String(describing:$0)} ?? ""
        address=row.text("address"); lender=row.text("lender"); property=row.text("propertyId")
        interest=row.raw["interestRate"].map{String(describing:$0)} ?? ""; payment=row.raw["monthlyPayment"].map{String(describing:$0)} ?? ""
        date=ISO8601DateFormatter().date(from:row.text("date") + "T12:00:00Z") ?? Date()
    }
    func save() {
        var row=edit.row
        row.raw["notes"]=notes
        if transaction {
            if asset == "option" { do { ticker=try option.symbol() } catch { validation=error.localizedDescription; return } }
            guard !account.isEmpty, !ticker.trimmingCharacters(in:.whitespaces).isEmpty, let shares=Double(quantity), shares.isFinite, shares>0, let cost=Double(price), cost.isFinite, cost>=0 else {validation="Enter an account, ticker, positive quantity, and a valid price.";return}
            row.raw["accountId"]=account; row.raw["ticker"]=ticker.trimmingCharacters(in:.whitespaces).uppercased(); row.raw["type"]=type; row.raw["quantity"]=shares; row.raw["pricePerShare"]=cost
            let formatter=DateFormatter(); formatter.locale=Locale(identifier:"en_US_POSIX"); formatter.dateFormat="yyyy-MM-dd"; row.raw["date"]=formatter.string(from:date)
            if model.saveTransaction(row) {dismiss()}
        } else {
            guard !name.trimmingCharacters(in:.whitespaces).isEmpty else {validation="Enter a name.";return}
            let amount=value.isEmpty && edit.field == "accounts" ? 0 : Double(value)
            guard let amount, amount.isFinite, edit.field == "accounts" || amount>=0 else {validation="Enter a valid value.";return}
            row.raw["name"]=name.trimmingCharacters(in:.whitespaces); row.raw["type"]=type
            row.raw[edit.field == "accounts" ? "cashBalance" : edit.field == "properties" ? "currentValue" : "balance"]=amount
            if edit.field == "properties" {row.raw["address"]=address}
            if edit.field == "liabilities" {
                guard (interest.isEmpty || (Double(interest).map{$0.isFinite && $0>=0} ?? false)), (payment.isEmpty || (Double(payment).map{$0.isFinite && $0>=0} ?? false)) else {validation="Enter valid interest and payment amounts.";return}
                row.raw["lender"]=lender; row.raw["propertyId"]=property.isEmpty ? NSNull() : property as Any
                row.raw["interestRate"]=Double(interest) ?? 0; row.raw["monthlyPayment"]=Double(payment) ?? 0
            }
            if model.save(row,field:edit.field) {dismiss()}
        }
    }
}
