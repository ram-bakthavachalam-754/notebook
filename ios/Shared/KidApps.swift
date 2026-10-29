import SwiftUI
import UserNotifications

/// What a child's policy turns on beyond which apps they see.
enum KidApps {
    static func apps(_ policy: [String:Any]?) -> [String:[String:Any]] {
        guard policy?["managed"] as? Bool == true else { return [:] }
        return policy?["apps"] as? [String:[String:Any]] ?? [:]
    }
    static func templates(_ policy: [String:Any]?) -> Bool { apps(policy)["notes"]?["templates"] as? Bool == true }
    static func reminder(_ policy: [String:Any]?) -> String? { apps(policy)["journal"]?["on"] as? Bool == true ? apps(policy)["journal"]?["reminder"] as? String : nil }
    static func allowance(_ policy: [String:Any]?) -> Double { (apps(policy)["money"]?["allowance"] as? NSNumber)?.doubleValue ?? 0 }
    static func money(_ value: Double) -> String { value.formatted(.currency(code:"USD").precision(.fractionLength(value.rounded() == value ? 0 : 2))) }
    /// "19:30" as the child's clock shows it, like "7:30 PM".
    static func clock(_ time: String) -> String {
        let parts = time.split(separator:":").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(from:DateComponents(hour:parts[0], minute:parts[1])) else { return time }
        return date.formatted(date:.omitted, time:.shortened)
    }
}

/// Starting points for a child's new note.
struct NoteTemplate: Identifiable {
    let name: String, detail: String, icon: String, html: String
    var id: String { name }
    static let all = [
        NoteTemplate(name:"I wonder", detail:"A question to explore", icon:"questionmark.bubble", html:"<p><b>I wonder:</b> </p><p><b>My guess:</b> </p><p><b>What I found out:</b> </p>"),
        NoteTemplate(name:"Reading log", detail:"Book, pages, favorite part", icon:"book", html:"<p><b>Book:</b> </p><p><b>Pages read:</b> </p><p><b>Favorite part:</b> </p>"),
        NoteTemplate(name:"Big idea", detail:"Something cool to remember", icon:"lightbulb", html:"<p><b>My idea:</b> </p><p><b>Why it’s cool:</b> </p>"),
        NoteTemplate(name:"Checklist", detail:"Things to do", icon:"checklist", html:"<p>☐ </p><p>☐ </p><p>☐ </p>")
    ]
    static func named(_ name: String?) -> NoteTemplate? { all.first { $0.name == name } }
}

/// The evening journal reminder a parent can turn on. It's a local
/// notification on the child's device; nothing about it is sent anywhere.
enum JournalReminder {
    static let id = "notebook-journal-reminder"
    static func update(_ policy: [String:Any]?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers:[id])
        guard let time = KidApps.reminder(policy) else { return }
        let parts = time.split(separator:":").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        center.requestAuthorization(options:[.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Journal time"
            content.body = ["What made you smile today?", "What’s something new you learned?", "Who was kind to you today?"].randomElement()!
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching:DateComponents(hour:parts[0], minute:parts[1]), repeats:true)
            center.add(UNNotificationRequest(identifier:id, content:content, trigger:trigger))
        }
    }
}

/// A child's Money app: savings goals, and the allowance their parent set.
struct KidMoney: View {
    @ObservedObject var money: MoneyModel
    let allowance: Double
    @State private var adding = false
    @State private var name = ""
    @State private var target = ""
    @State private var removing: SavingsGoal?
    private let accent = Color(red:0.95, green:0.48, blue:0.22)
    var body: some View {
        ScrollView { content.padding(24).frame(maxWidth:620).frame(maxWidth:.infinity) }
            .fontDesign(.rounded)
            .navigationTitle("Money")
            .onAppear { money.reload() }
            .alert("Add a Goal", isPresented:$adding) {
                TextField("What it is", text:$name)
                TextField("How much it costs", text:$target)
                Button("Cancel", role:.cancel) { }
                Button("Add", action:addGoal)
            } message: { Text("For example: LEGO set, 60") }
            .confirmationDialog("Remove \(removing?.name ?? "this goal")?", isPresented:removingShown, titleVisibility:.visible) {
                Button("Remove", role:.destructive) { if let removing { money.delete(removing) } }
            }
            .alert("Money", isPresented:errorShown) { } message: { Text(money.error ?? "") }
    }
    private var removingShown: Binding<Bool> { Binding(get:{ removing != nil }, set:{ if !$0 { removing = nil } }) }
    private var errorShown: Binding<Bool> { Binding(get:{ money.error != nil }, set:{ if !$0 { money.error = nil } }) }
    private func addGoal() { money.add(name:name, target:Double(target.filter { "0123456789.".contains($0) }) ?? 0) }
    var content: some View {
        VStack(alignment:.leading, spacing:14) {
            if allowance > 0 { allowanceCard }
            if money.goals.isEmpty {
                VStack(alignment:.leading, spacing:6) {
                    Text("What are you saving for?").font(.title3.weight(.semibold))
                    Text("Add a goal, then add money each time you put some aside.").foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            ForEach(money.goals) { goal in card(goal) }
            Button { name = ""; target = ""; adding = true } label: { Label("Add a Goal", systemImage:"plus") }
                .buttonStyle(.borderedProminent).tint(accent)
        }
    }
    private var allowanceCard: some View {
        HStack(spacing:12) {
            Text(KidApps.money(allowance)).font(.system(size:28, weight:.bold, design:.rounded))
            Text("Your allowance arrives every Saturday").foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth:.infinity, alignment:.leading)
        .background(accent.opacity(0.12), in:RoundedRectangle(cornerRadius:18))
    }
    private func card(_ goal: SavingsGoal) -> some View {
        VStack(alignment:.leading, spacing:8) {
            HStack {
                Text(goal.name).font(.headline)
                Spacer()
                Menu {
                    Button("Take Out $1") { money.change(goal, by:-1) }.disabled(goal.saved <= 0)
                    Button("Take Out $5") { money.change(goal, by:-5) }.disabled(goal.saved <= 0)
                    Divider()
                    Button("Remove Goal…", role:.destructive) { removing = goal }
                } label: { Image(systemName:"ellipsis.circle") }
                .menuIndicator(.hidden).fixedSize()
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
            }
            GeometryReader { geometry in
                ZStack(alignment:.leading) {
                    Capsule().fill(accent.opacity(0.15))
                    Capsule().fill(accent).frame(width:goal.saved > 0 ? max(12, geometry.size.width * goal.progress) : 0)
                }
            }
            .frame(height:12)
            HStack {
                Text(goal.done ? "You did it!" : "\(KidApps.money(goal.saved)) saved").fontWeight(.bold)
                Spacer()
                Text("of \(KidApps.money(goal.target))").foregroundStyle(.secondary)
            }
            .font(.subheadline).monospacedDigit()
            if !goal.done {
                HStack {
                    Button("+ $1") { money.change(goal, by:1) }
                    Button("+ $5") { money.change(goal, by:5) }
                }
                .buttonStyle(.bordered).tint(accent)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08), in:RoundedRectangle(cornerRadius:18))
    }
}

#if os(macOS)
/// The Mac's middle column for Money: each goal at a glance.
struct MacMoneySummary: View {
    @ObservedObject var money: MoneyModel
    let allowance: Double
    var body: some View {
        List {
            if allowance > 0 { LabeledContent("Allowance", value:"\(KidApps.money(allowance)) a week") }
            Section("Goals") {
                ForEach(money.goals) { goal in
                    LabeledContent(goal.name, value:goal.done ? "Done!" : "\(Int(goal.progress * 100))%")
                }
            }
        }
        .navigationTitle("Money")
        .onAppear { money.reload() }
    }
}
#endif
