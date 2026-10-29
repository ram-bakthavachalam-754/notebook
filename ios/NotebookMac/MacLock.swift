import SwiftUI
import AppKit
import NotebookCore

extension Notification.Name {
    static let notebookLockNow = Notification.Name("notebookLockNow")
}

/// Mac protection: Touch ID or the Mac's login password through LocalAuthentication.
/// Notebook locks on launch, after a chosen idle time, and when the Mac sleeps,
/// locks its screen, or the person presses ⌘L.
enum MacLockSettings {
    static let enabledKey = "notebook-lock", minutesKey = "notebook-lock-minutes"
    static let choices = [1, 5, 15, 30]
    static var minutes: Int {
        get { let value = UserDefaults.standard.integer(forKey:minutesKey); return choices.contains(value) ? value : 5 }
        set { UserDefaults.standard.set(newValue, forKey:minutesKey) }
    }
    /// The first time the native app runs, keep the Electron app's choice:
    /// protection stays on, with the same idle time. Its password isn't
    /// reused; Touch ID or the Mac password unlocks instead.
    static func adoptElectronSetting(from directory: URL) {
        guard UserDefaults.standard.object(forKey:enabledKey) == nil,
              let data = try? Data(contentsOf:directory.appendingPathComponent("security.json")),
              let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return }
        UserDefaults.standard.set(value["enabled"] as? Bool ?? false, forKey:enabledKey)
        if let minutes = value["timeoutMinutes"] as? Int, choices.contains(minutes) { self.minutes = minutes }
    }
}

/// Watches activity, sleep and screen locking while Notebook is unlocked.
@MainActor final class MacLockWatcher: ObservableObject {
    private weak var model: NotebookModel?
    private var lastActivity = Date()
    private var monitor: Any?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    func start(_ model: NotebookModel) {
        guard self.model == nil else { return }
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            self?.lastActivity = Date(); return event
        }
        timer = Timer.scheduledTimer(withTimeInterval:20, repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let model = self.model, model.lockEnabled, model.unlocked else { return }
                if Date().timeIntervalSince(self.lastActivity) >= Double(MacLockSettings.minutes * 60) { self.lock() }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName:name, object:nil, queue:.main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName:.init("com.apple.screenIsLocked"), object:nil, queue:.main) { [weak self] _ in Task { @MainActor in self?.lock() } })
        observers.append(NotificationCenter.default.addObserver(forName:.notebookLockNow, object:nil, queue:.main) { [weak self] _ in Task { @MainActor in self?.lock() } })
    }
    func lock() {
        guard let model, model.lockEnabled, model.unlocked else { return }
        // Editors save their drafts as they disappear behind the lock screen.
        model.background()
    }
    func noteActivity() { lastActivity = Date() }
}

struct MacLockScreen: View {
    @ObservedObject var model: NotebookModel
    var body: some View {
        VStack(spacing:16) {
            Image(systemName:"lock.fill").font(.system(size:30, weight:.medium)).foregroundStyle(.white)
                .frame(width:72, height:72).background(LinearGradient(colors:[.orange, .pink], startPoint:.topLeading, endPoint:.bottomTrailing), in:RoundedRectangle(cornerRadius:20, style:.continuous))
                .shadow(color:.pink.opacity(0.25), radius:16, y:6)
            Text("Notebook is locked").font(.system(size:28, weight:.semibold, design:.serif)).padding(.top, 6)
            Text("Unlock with Touch ID or your Mac password.").foregroundStyle(.secondary)
            Button { Task { await model.unlock(); if model.unlocked { model.startPolling() } } } label: { Label("Unlock", systemImage:"touchid").padding(.horizontal, 10) }
                .keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .frame(maxWidth:.infinity, maxHeight:.infinity)
        .background(.background)
        // Touch ID is asked for only when you open Notebook or switch to it.
        // Locking (idle, sleep, ⌘L) just shows this screen, and logging back
        // into the Mac doesn't ask.
        .task { if !Self.launched { Self.launched = true; await ask() } }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in Task { await ask() } }
    }
    private static var launched = false, prompting = false, promptEnded = Date.distantPast
    private func ask() async {
        // The Touch ID panel can make Notebook inactive and active again as it
        // closes; that isn't you switching back, so it mustn't ask again.
        guard !model.unlocked, NSApp.isActive, !Self.screenLocked, !Self.prompting, Date().timeIntervalSince(Self.promptEnded) > 2 else { return }
        Self.prompting = true
        await model.unlock(); if model.unlocked { model.startPolling() }
        Self.prompting = false; Self.promptEnded = Date()
    }
    /// Whether the Mac's screen is locked or showing its login window.
    static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String:Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true || session[kCGSessionOnConsoleKey as String] as? Bool == false
    }
}

struct MacSettings: View {
    @ObservedObject var model: NotebookModel
    @State private var minutes = MacLockSettings.minutes
    @AppStorage("notebook-settings-tab") private var tab = "privacy"
    /// Opens Settings on a tab (call before `openSettings()`).
    static func show(_ tab: String) { UserDefaults.standard.set(tab, forKey:"notebook-settings-tab") }
    var body: some View {
        TabView(selection:$tab) {
            Form {
                Toggle("Require Touch ID or your Mac password", isOn:Binding(get:{ model.lockEnabled }, set:{ enabled in Task { await model.setProtection(enabled) } }))
                Picker("Lock after", selection:$minutes) { ForEach(MacLockSettings.choices, id:\.self) { Text("\($0) minute\($0 == 1 ? "" : "s") of inactivity").tag($0) } }
                    .disabled(!model.lockEnabled)
                    .onChange(of:minutes) { _, value in MacLockSettings.minutes = value }
                Text("Notebook also locks when your Mac sleeps or locks its screen, and when you press ⌘L. This keeps others from opening Notebook; it doesn't encrypt the files on disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Privacy", systemImage:"lock") }.tag("privacy")
            MacSyncSettings(model:model)
                .tabItem { Label("iCloud", systemImage:"icloud") }.tag("icloud")
            FamilySettings(family:model.family, agent:model.agent)
                .tabItem { Label("Family", systemImage:"person.2") }.tag("family")
            if model.unlocked && !model.agent.kidMode {
                AgentSettingsView(agent:model.agent)
                    .tabItem { Label("AI Agent", systemImage:"sparkles") }.tag("agent")
                TradingSettingsView(trading:model.trading, robinhood:model.robinhood)
                    .tabItem { Label("Trading", systemImage:"chart.bar.xaxis") }.tag("trading")
            }
            if model.unlocked { SharingSettings(sharing:model.sharing).tabItem { Label("Sharing", systemImage:"person.crop.circle.badge.plus") }.tag("sharing") }
        }
        .formStyle(.grouped).frame(width:560, height:480)
    }
}
