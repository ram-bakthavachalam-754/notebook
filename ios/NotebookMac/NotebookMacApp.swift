import SwiftUI
import UserNotifications
import NotebookCore
import CloudKit

extension Notification.Name {
    static let notebookNewNote = Notification.Name("notebookNewNote")
    static let notebookNewEntry = Notification.Name("notebookNewEntry")
    static let notebookShowSection = Notification.Name("notebookShowSection")
}

/// Receives invitations the person opens (a shared note's link, say). They're
/// held until Notebook is unlocked, then accepted.
final class NotebookMacDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var pending: [CKShare.Metadata] = []
    @MainActor static var accept: ((CKShare.Metadata) -> Void)?
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        MainActor.assumeIsolated { if let accept = Self.accept { accept(metadata) } else { Self.pending.append(metadata) } }
    }
}

@main struct NotebookMacApp: App {
    @NSApplicationDelegateAdaptor(NotebookMacDelegate.self) var delegate
    private let model: NotebookModel?
    private let startupError: String?
    init() {
        do {
            let directory = Self.dataDirectory()
            try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
            MacLockSettings.adoptElectronSetting(from:directory)
            let store = try RecordStore(url:directory.appendingPathComponent("notebook.sqlite"))
            model = NotebookModel(store:store); startupError = nil
        } catch { model = nil; startupError = error.localizedDescription }
    }
    /// The same folder the Electron app has always used, so existing notes,
    /// journal entries and finance records open in place. NOTEBOOK_DATA_ROOT
    /// points at a test or backup copy instead, exactly as it does for Electron.
    static func dataDirectory() -> URL {
        if let root = ProcessInfo.processInfo.environment["NOTEBOOK_DATA_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath:root).appendingPathComponent("userData")
        }
        return FileManager.default.urls(for:.applicationSupportDirectory, in:.userDomainMask)[0].appendingPathComponent("Notebook")
    }
    var body: some Scene {
        WindowGroup {
            if let model { MacWindow(model:model).frame(minWidth:820, minHeight:540) }
            else { ContentUnavailableView("Notebook could not open", systemImage:"externaldrive.badge.exclamationmark", description:Text(startupError ?? "Your data has not been changed.")) }
        }
        .defaultSize(width:1200, height:820)
        .commands {
            CommandGroup(replacing:.newItem) {
                Button("New Note") { NotificationCenter.default.post(name:.notebookNewNote, object:nil) }.keyboardShortcut("n")
                Button("New Journal Entry") { NotificationCenter.default.post(name:.notebookNewEntry, object:nil) }.keyboardShortcut("n", modifiers:[.command, .shift])
            }
            CommandGroup(before:.sidebar) {
                ForEach(Array(MacSection.visible(model?.agent.policy).enumerated()), id:\.offset) { index, item in
                    Button(item.title) { NotificationCenter.default.post(name:.notebookShowSection, object:item.rawValue) }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Divider()
            }
            CommandGroup(after:.appSettings) {
                Button("Lock Notebook") { NotificationCenter.default.post(name:.notebookLockNow, object:nil) }.keyboardShortcut("l").disabled(model?.lockEnabled != true)
            }
        }
        Settings {
            if let model { MacSettings(model:model) }
        }
    }
}

/// Shows the lock screen instead of any notebook content while locked.
struct MacWindow: View {
    @ObservedObject var model: NotebookModel
    @StateObject private var watcher = MacLockWatcher()
    var body: some View {
        Group { if model.unlocked { MacRoot(model:model) } else { MacLockScreen(model:model) } }
            .onAppear { watcher.start(model); if model.unlocked { model.startPolling() }; acceptInvitations() }
            .onChange(of:model.unlocked) { _, _ in acceptInvitations() }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in if model.unlocked { Task { await model.sync() } } }
    }
}

extension MacWindow {
    /// Invitations wait while Notebook is locked, then are accepted.
    func acceptInvitations() {
        guard model.unlocked else { NotebookMacDelegate.accept = nil; return }
        let sharing = model.sharing
        NotebookMacDelegate.accept = { metadata in Task { await sharing.accept(metadata) } }
        for metadata in NotebookMacDelegate.pending { Task { await sharing.accept(metadata) } }
        NotebookMacDelegate.pending = []
    }
}

enum MacSection: String, CaseIterable, Identifiable {
    case notes, journal, finance, trading, explore, news, links, documents, agent, money
    var id: Self { self }
    /// The sections a child's policy leaves on; everything but Money for
    /// adults. Finance tracks investments, which kids never get; a child's
    /// Money is savings goals only.
    static func visible(_ policy: [String:Any]?) -> [MacSection] {
        // News is for adults: kids' policies have no News app.
        guard let policy, policy["managed"] as? Bool == true else { return allCases.filter { $0 != .money } }
        let apps = policy["apps"] as? [String:[String:Any]] ?? [:]
        return allCases.filter { item in
            switch item {
            case .finance, .trading, .explore, .news: false
            case .agent: apps["agent"]?["on"] as? Bool ?? true
            default: apps[item.rawValue]?["on"] as? Bool ?? false
            }
        }
    }
    var title: String { ["notes":"Notes", "journal":"Journal", "finance":"Finance", "trading":"Trading", "explore":"Explore", "news":"News", "links":"Links", "agent":"Agent", "documents":"Documents", "money":"Money"][rawValue]! }
    var icon: String { ["notes":"note.text", "journal":"book.closed", "finance":"chart.line.uptrend.xyaxis", "trading":"chart.bar.xaxis", "explore":"square.grid.3x3.fill", "news":"newspaper", "links":"link", "agent":"sparkles", "documents":"doc.text", "money":"dollarsign.circle"][rawValue]! }
    /// Each section's own color in the sidebar.
    var tint: Color {
        switch self {
        case .notes: .orange
        case .journal: .pink
        case .finance: .green
        case .trading: .teal
        case .explore: .cyan
        case .news: .red
        case .links: .blue
        case .documents: .indigo
        case .agent: .purple
        case .money: .green
        }
    }
    /// The sidebar groups sections under these headings, in this order.
    var group: String {
        switch self {
        case .notes, .journal: "Notebook"
        case .finance, .trading, .explore, .news, .money: "Money"
        case .links, .documents: "Library"
        case .agent: "Assistant"
        }
    }
}

struct MacRoot: View {
    @ObservedObject var model: NotebookModel
    @StateObject private var finance: FinanceModel
    @State private var selectedAccount: String? = allAccounts
    @State private var selectedDocument: String?
    @State private var selectedCollection: String? = allLinks
    @State private var selectedStory: String?
    @State private var selectedTrade: String? = tradingOverview
    @State private var selectedExplore: String? = exploreAll
    init(model: NotebookModel) {
        self.model = model
        _finance = StateObject(wrappedValue:FinanceModel(store:model.store, shares:model.shareLibrary, authorized:{ [weak model] in model?.unlocked ?? false }))
    }
    @State private var section: MacSection? = .notes
    @State private var selectedNote: String?
    @State private var newNote: NotebookItem?
    @State private var selectedEntry: String?
    @State private var newEntry: NotebookItem?
    var body: some View { withAlerts(withEvents(split)) }
    private var split: some View {
        NavigationSplitView {
            List(selection:$section) {
                let visible = MacSection.visible(model.agent.policy)
                ForEach(visible.reduce(into:[String]()) { if !$0.contains($1.group) { $0.append($1.group) } }, id:\.self) { group in
                    Section(group) {
                        ForEach(visible.filter { $0.group == group }) { item in
                            Label { Text(kid && item == .agent ? "Ask" : item.title) } icon: { Image(systemName:item.icon).foregroundStyle(item.tint) }
                                .badge(count(item)).tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min:180, ideal:210)
        } content: {
            content
        } detail: {
            detail
        }
    }
    private func withEvents(_ view: some View) -> some View {
        view
            .onReceive(NotificationCenter.default.publisher(for:.notebookNewNote)) { note in newNoteRequested(note) }
            #if DEBUG
            .onAppear { runTestFlags() }
            #endif
            .onReceive(NotificationCenter.default.publisher(for:.notebookNewEntry)) { _ in createEntry() }
            .onReceive(NotificationCenter.default.publisher(for:.notebookShowSection)) { note in showSection(note) }
            .onChange(of:kid) { _, _ in keepVisibleSection() }
            .onChange(of:model.reloadVersion) { _, _ in notebookReloaded() }
            .onReceive(NotificationCenter.default.publisher(for:.notebookSharesChanged)) { _ in finance.reload(); model.links.reload() }
            // Trading watches prices and researches in the background while unlocked.
            .onAppear { if !kid { model.robinhood.openURL = { NSWorkspace.shared.open($0) }; finance.robinhood = model.robinhood; model.trading.reload(); model.trading.start() } }
            .onReceive(finance.$holdings) { rows in model.trading.heldTickers = rows.filter { $0.number("totalShares") > 0 && $0.raw["option"] == nil }.map { $0.text("ticker") } }
    }
    private func withAlerts(_ view: some View) -> some View {
        view
            .alert("Shared with you", isPresented:Binding(get:{ !model.sharing.notices.isEmpty }, set:{ if !$0 { model.sharing.dismissNotices() } })) { } message: { Text(model.sharing.notices.joined(separator:"\n")) }
            .alert("Trading", isPresented:Binding(get:{ model.trading.error != nil }, set:{ if !$0 { model.trading.error = nil } })) { } message: { Text(model.trading.error ?? "") }
            .alert("Explore", isPresented:Binding(get:{ !kid && model.explore.error != nil }, set:{ if !$0 { model.explore.error = nil } })) { } message: { Text(model.explore.error ?? "") }
            .alert("Finance", isPresented:Binding(get:{ finance.error != nil }, set:{ if !$0 { finance.error = nil } })) { } message: { Text(finance.error ?? "") }
            .alert("Notebook", isPresented:Binding(get:{ model.error != nil }, set:{ if !$0 { model.error = nil } })) { } message: { Text(model.error ?? "") }
    }
    private func newNoteRequested(_ note: Notification) {
        if MacSection.visible(model.agent.policy).contains(.notes) { createNote(template:NoteTemplate.named(note.object as? String)) }
    }
    private func showSection(_ note: Notification) {
        if let raw = note.object as? String, let item = MacSection(rawValue:raw), MacSection.visible(model.agent.policy).contains(item) { section = item }
    }
    private func keepVisibleSection() {
        if let section, !MacSection.visible(model.agent.policy).contains(section) { self.section = MacSection.visible(model.agent.policy).first }
    }
    /// Keep a new note in place until its first save shows up in the list.
    private func notebookReloaded() {
        if let newNote, model.notes.contains(where:{ $0.id == newNote.id }) { self.newNote = nil }
        if let newEntry, model.journal.contains(where:{ $0.id == newEntry.id }) { self.newEntry = nil }
        Task { await finance.refresh() }; model.links.reload(); if !kid { model.trading.reload(); model.explore.reload() }; if kid { model.money.reload() }
    }
    #if DEBUG
    /// Tests open a note directly (--open-note <id>), and more; see MacTestHooks.
    private func runTestFlags() {
        let args = CommandLine.arguments
        setvbuf(stdout, nil, _IONBF, 0) // Test output survives the app being stopped.
        if let i = args.firstIndex(of:"--open-note"), i + 1 < args.count { selectedNote = args[i + 1] }
        if let i = args.firstIndex(of:"--open-entry"), i + 1 < args.count { section = .journal; selectedEntry = args[i + 1] }
        if let i = args.firstIndex(of:"--section"), i + 1 < args.count { section = MacSection(rawValue:args[i + 1]) ?? section }
        if let i = args.firstIndex(of:"--open-document"), i + 1 < args.count { section = .documents; selectedDocument = args[i + 1] }
        if args.contains("--open-watchlist") { section = .trading; selectedTrade = tradingWatchlist }
        // --explore <list> [all|s:45|i:453010|u:45301020|t:NVDA]: open Explore on that list and page.
        if let i = args.firstIndex(of:"--explore"), i + 1 < args.count { section = .explore; model.explore.list = args[i + 1]; selectedExplore = i + 2 < args.count && !args[i + 2].hasPrefix("--") ? args[i + 2] : exploreAll; print("explore: model can place:", model.agent.canSummarize) }
        if args.contains("--open-first-trade") { section = .trading; selectedTrade = model.trading.ideas.first?.id ?? tradingOverview }
        // --join-family <file>: join a family with the code saved in the file.
        if let i = args.firstIndex(of:"--join-family"), i + 1 < args.count {
            do { print("joined, confirmation:", try model.agent.joinFamily(String(contentsOfFile:args[i + 1], encoding:.utf8))) }
            catch { print("join refused:", error.localizedDescription) }
        }
        // --install-policy <file.json>: install a family policy by hand, as a parent's
        // published rules would arrive (versions must increase; "managed": false releases).
        if let i = args.firstIndex(of:"--install-policy"), i + 1 < args.count {
            do { try model.agent.installPolicy(Data(contentsOf:URL(fileURLWithPath:args[i + 1]))); section = MacSection.visible(model.agent.policy).first; print("policy installed:", model.agent.kidMode ? "kid mode" : "released") }
            catch { print("policy not installed:", error.localizedDescription) }
        }
        MacTestHooks.run(args, model:model, finance:finance)
    }
    #endif
    /// The middle column for the selected section.
    @ViewBuilder private var content: some View {
        switch section ?? .notes {
        case .notes: NotesList(model:model, selection:$selectedNote, newNote:$newNote)
        case .journal: JournalList(model:model, selection:$selectedEntry, newEntry:$newEntry)
        case .finance: FinanceAccounts(finance:finance, sharing:model.sharing, selection:$selectedAccount)
        case .trading: TradingList(trading:model.trading, selection:$selectedTrade)
        case .explore: ExploreSidebar(explore:model.explore, selection:$selectedExplore)
        case .news: MacNewsList(news:model.news, agent:model.agent, selection:$selectedStory)
        case .links: LinksCollections(links:model.links, sharing:model.sharing, selection:$selectedCollection)
        case .agent: MacAgentThreads(agent:model.agent)
        case .documents: MacDocumentsList(documents:model.documents, selection:$selectedDocument)
        case .money: MacMoneySummary(money:model.money, allowance:KidApps.allowance(model.agent.policy))
        }
    }
    /// The right-hand pane for the selected section.
    @ViewBuilder private var detail: some View {
        if section == .notes, let item = currentNote {
            NoteDetail(model:model, item:item, onSaved:{ model.reload() }, onDiscard:{ if newNote?.id == item.id { newNote = nil } }).id(item.id)
        } else if section == .journal, let item = currentEntry {
            JournalDetail(model:model, item:item, onSaved:{ model.reload() }, onDiscard:{ if newEntry?.id == item.id { newEntry = nil } }).id(item.id)
        } else if section == .finance, let shared = finance.sharedAccounts.first(where: { "shared:" + $0.id == selectedAccount }) {
            SharedAccountView(info:shared.info, view:shared.view, price:finance.price).id(shared.id)
        } else if section == .finance {
            NavigationStack { FinanceDetail(finance:finance, sharing:model.sharing, accountID:selectedAccount ?? allAccounts, openAccount:{ selectedAccount = $0 },
                                            trading:kid ? nil : model.trading, openAlert:{ section = .trading; selectedTrade = $0 }) }
                .id(selectedAccount ?? allAccounts)
        } else if section == .trading {
            // Tickers on these pages open the shared ticker page.
            NavigationStack {
                Group {
                    if let idea = model.trading.idea(selectedTrade) { TradeIdeaDetail(trading:model.trading, idea:idea) }
                    else if selectedTrade == tradingWatchlist { TradingWatchlist(trading:model.trading) }
                    else { TradingOverview(trading:model.trading, agent:model.agent) }
                }
                .navigationDestination(for:TickerLink.self) { link in
                    TickerDetail(finance:finance, ticker:link.ticker, openAccount:{ section = .finance; selectedAccount = $0 }, trading:model.trading, openAlert:{ selectedTrade = $0 })
                }
            }
            .id(selectedTrade ?? tradingOverview)
        } else if section == .explore {
            ExploreDetail(explore:model.explore, finance:finance, trading:model.trading, selection:$selectedExplore,
                          openAccount:{ section = .finance; selectedAccount = $0 }, openAlert:{ section = .trading; selectedTrade = $0 })
                .id(selectedExplore ?? exploreAll)
        } else if section == .news {
            if let story = currentStory {
                NewsReader(news:model.news, agent:model.agent, story:story).id(story.url)
            } else { EmptyDetail(title:"No Story Selected", systemImage:"newspaper", message:"Choose a headline to read it here.") }
        } else if section == .links {
            LinksList(links:model.links, sharing:model.sharing, scope:selectedCollection ?? allLinks).id(selectedCollection ?? allLinks)
        } else if section == .agent {
            if kid { KidAsk(agent:model.agent, documents:model.documents) }
            else { MacAgentChat(notebook:model, agent:model.agent, documents:model.documents) }
        } else if section == .money {
            KidMoney(money:model.money, allowance:KidApps.allowance(model.agent.policy))
        } else if section == .documents, let item = model.documents.documents.first(where:{ $0.id == selectedDocument }) {
            MacDocumentDetail(documents:model.documents, item:item).id(item.id + (item.raw["modifiedAt"] as? String ?? ""))
        } else {
            switch section {
            case .journal: EmptyDetail(title:"No Entry Selected", systemImage:"book.closed", message:"Choose an entry, or press ⇧⌘N to write about today.")
            case .documents: EmptyDetail(title:"No Document Selected", systemImage:"doc.text", message:"Choose a document, or drop files into the list.")
            default: EmptyDetail(title:"No Note Selected", systemImage:"note.text", message:"Choose a note, or press ⌘N to start a new one.")
            }
        }
    }
    private var currentStory: NewsStory? {
        guard let selectedStory else { return nil }
        return model.news.stories.first { $0.url == selectedStory } ?? model.news.saved.first { $0.url == selectedStory }
    }
    private var kid: Bool { model.agent.kidMode }
    private var currentNote: NotebookItem? {
        model.notes.first { $0.id == selectedNote } ?? (newNote?.id == selectedNote ? newNote : nil)
    }
    private var currentEntry: NotebookItem? {
        model.journal.first { $0.id == selectedEntry } ?? (newEntry?.id == selectedEntry ? newEntry : nil)
    }
    /// Today's entry starts unsaved, like a note; it's written once something is typed.
    private func createEntry() {
        let now = ISO8601DateFormatter().string(from:Date())
        let item = NotebookItem(raw:["id":UUID().uuidString.lowercased(), "date":JournalDates.stored(Date()), "mood":"neutral", "content":"", "tags":[String](), "createdAt":now, "modifiedAt":now])
        section = .journal; newEntry = item; selectedEntry = item.id
    }
    private func count(_ item: MacSection) -> Int {
        switch item {
        case .notes: model.notes.count
        case .journal: model.journal.count
        case .finance: finance.rows("accounts").count
        case .trading: model.trading.ideas.filter(\.pending).count
        case .explore: 0
        case .news: 0
        case .links: model.links.links.count
        case .agent: 0
        case .documents: model.documents.documents.count
        case .money: model.money.goals.count
        }
    }
    /// A new note is saved only once something is typed into it.
    private func createNote(template: NoteTemplate? = nil) {
        let now = ISO8601DateFormatter().string(from:Date())
        let item = NotebookItem(raw:["id":UUID().uuidString.lowercased(), "title":template?.name ?? "", "content":template?.html ?? "", "tags":[String](), "pinned":false, "createdAt":now, "modifiedAt":now])
        section = .notes; newNote = item; selectedNote = item.id
    }
}
