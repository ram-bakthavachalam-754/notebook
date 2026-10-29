import Foundation
import NotebookCore

/// One savings goal in a child's Money app (the `money` kind).
struct SavingsGoal: Identifiable, Equatable {
    var raw: [String:Any]
    var id: String { raw["id"] as? String ?? "" }
    var name: String { raw["name"] as? String ?? "" }
    var target: Double { (raw["target"] as? NSNumber)?.doubleValue ?? 0 }
    var saved: Double { (raw["saved"] as? NSNumber)?.doubleValue ?? 0 }
    var done: Bool { target > 0 && saved >= target }
    var progress: Double { target > 0 ? min(1, saved / target) : 0 }
    var modifiedAt: String { raw["modifiedAt"] as? String ?? "" }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.modifiedAt == rhs.modifiedAt }
}

/// A child's savings goals. Money here is counted, never moved: the allowance
/// is handed over at home and the child adds what they put aside.
@MainActor final class MoneyModel: ObservableObject {
    @Published var goals: [SavingsGoal] = []
    @Published var error: String?
    private weak var notebook: NotebookModel?
    private let store: RecordStore
    init(notebook: NotebookModel) { self.notebook = notebook; store = notebook.store; reload() }
    func reload() {
        guard notebook?.unlocked == true else { goals = []; return }
        do {
            // One version of each goal: the most recently changed.
            var newest: [String:[String:Any]] = [:]
            for row in try store.records("money") {
                let entity = row["_syncEntity"] as? String ?? row["id"] as? String ?? ""
                if let kept = newest[entity], (kept["modifiedAt"] as? String ?? "") >= (row["modifiedAt"] as? String ?? "") { continue }
                newest[entity] = row
            }
            goals = newest.values.map(SavingsGoal.init).sorted { ($0.done ? 1 : 0, $0.raw["createdAt"] as? String ?? "") < ($1.done ? 1 : 0, $1.raw["createdAt"] as? String ?? "") }
        } catch { self.error = error.localizedDescription }
    }
    private func write(_ raw: [String:Any]) {
        guard notebook?.unlocked == true else { error = "Unlock Notebook to continue."; return }
        var record = raw; record["modifiedAt"] = ISO8601DateFormatter().string(from:Date())
        do { try store.save(kind:"money", record:record, resolve:true); reload(); Task { await notebook?.sync() } }
        catch { self.error = error.localizedDescription }
    }
    func add(name: String, target: Double) {
        let trimmed = String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(60))
        guard !trimmed.isEmpty else { error = "Give your goal a name."; return }
        guard target > 0, target <= 100_000 else { error = "Enter how much it costs."; return }
        let now = ISO8601DateFormatter().string(from:Date())
        write(["id":UUID().uuidString.lowercased(), "type":"goal", "name":trimmed, "target":(target * 100).rounded() / 100, "saved":0, "createdAt":now])
    }
    /// Adds (or, with a negative amount, takes out) money, kept between 0 and the target.
    func change(_ goal: SavingsGoal, by amount: Double) {
        guard var row = try? store.records("money", entity:goal.id).first else { return }
        row["saved"] = (max(0, min(goal.target, goal.saved + amount)) * 100).rounded() / 100
        write(row)
    }
    func delete(_ goal: SavingsGoal) {
        do {
            if var row = try store.records("money", entity:goal.id).first { row["_syncHeads"] = row["_syncAllHeads"]; try store.delete(kind:"money", record:row) }
            reload(); Task { await notebook?.sync() }
        } catch { self.error = error.localizedDescription }
    }
}
