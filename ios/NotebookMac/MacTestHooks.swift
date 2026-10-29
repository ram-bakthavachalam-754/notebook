#if DEBUG
import SwiftUI
import AppKit
import UserNotifications
import NotebookCore
import WebKit

/// Command-line test runs for the DEBUG build (see each flag's comment); each
/// prints its results and quits. Kept out of the window's view code so the
/// compiler checks each one on its own.
@MainActor enum MacTestHooks {
    static func run(_ args: [String], model: NotebookModel, finance: FinanceModel) {
        // --print-finance: print what Finance computes, then quit (for checking a library).
        // --test-links: run Links through add, title fetch, collections, edit, move and delete; print, quit.
        if args.contains("--test-links") { Task { await testLinks(args, 0, model:model, finance:finance) } }
        // --test-family <out.json>: add a child, edit, publish (and a missing key), print, quit.
        if let i = args.firstIndex(of:"--test-family"), i + 1 < args.count {
            let family = model.family
            guard var sam = family.add(name:"Sam", age:9) else { print("add failed", family.error ?? ""); exit(1) }
            print("added:", sam.name, "topics.scary =", sam.section("topics")["scary"] ?? "-", "unpublished:", family.unpublished(sam), "version:", sam.version)
            do { _ = try family.publish(sam) } catch { print("publish without key:", error.localizedDescription) }
            sam = family.children.first { $0.id == sam.id }!
            sam.raw["rules"] = ["No video game cheats or hacks"]; sam.raw["parentName"] = "Dad"
            sam.raw["connection"] = ["provider":"compatible","model":"test-model","baseURL":"http://127.0.0.1:8765/v1","apiKey":""]
            family.save(sam); sam = family.children.first { $0.id == sam.id }!
            print("after edit unpublished:", family.unpublished(sam))
            do {
                let data = try family.publish(sam); try data.write(to:URL(fileURLWithPath:args[i + 1]))
                sam = family.children.first { $0.id == sam.id }!
                print("published v\(sam.version), unpublished now:", family.unpublished(sam), "records:", (try? model.store.revisions(kind:"family").count) ?? -1)
                let joining = try family.enrollment(sam)
                try joining.code.write(toFile:args[i + 1] + ".code", atomically:true, encoding:.utf8)
                print("enrollment confirmation:", joining.confirmation, "same keys after publish:", (try family.enrollment(sam)).confirmation == joining.confirmation)
                if args.contains("--and-release") { try family.release(family.children.first { $0.id == sam.id }!).write(to:URL(fileURLWithPath:args[i + 1] + ".release")) ; print("release file written") }
            } catch { print("publish failed:", error.localizedDescription) }
            exit(0)
        }
        // --test-ask "q1|q2|…": send each question through kid mode, print what the child saw, quit.
        if let i = args.firstIndex(of:"--test-ask"), i + 1 < args.count { Task { await testAsk(args, i, model:model, finance:finance) } }
        // --test-money <png>: a child's savings goals: add, add money, cap at the target, take out,
        // remove; the template and reminder settings; draw Money to an image, print, quit.
        if let i = args.firstIndex(of:"--test-money"), i + 1 < args.count { Task { await testMoney(args, i, model:model, finance:finance) } }
        // --test-trading <dir>: research a small watchlist for real (Yahoo, news, your model), print
        // the notes and ideas, run a price check, draw the overview and first idea to images, quit.
        if let i = args.firstIndex(of:"--test-trading"), i + 1 < args.count { Task { await testTrading(args[i + 1], model:model) } }
        // --test-agent-trading: run the agent's Trading tools against a saved alert, with live
        // quotes and headlines, print PASS/FAIL for each and quit. No model or research run needed.
        if args.contains("--test-agent-trading") { Task { await testAgentTrading(model:model) } }
        // --robinhood-tools <file>: connect Robinhood if needed (opens the browser), write its tool list
        // and sample answers to the file, quit.
        if let i = args.firstIndex(of:"--robinhood-tools"), i + 1 < args.count { Task { await robinhoodTools(args[i + 1], model:model) } }
        // --render-ticker <symbol> <png>: load the ticker page's data, draw it to an image, quit.
        if let i = args.firstIndex(of:"--render-ticker"), i + 2 < args.count { Task { await renderTicker(args, i, model:model, finance:finance) } }
        // --test-sharing <png>: share a note, a links collection and an account without
        // iCloud; edit, move, view-only items, levels, stop and leave; print, draw, quit.
        if let i = args.firstIndex(of:"--test-sharing"), i + 1 < args.count { Task { await testSharing(args, i, model:model, finance:finance) } }
        // --test-agent "question": ask the agent through a local OpenAI-compatible server
        // (NOTEBOOK_TEST_AGENT_URL), print what was shown, restore the settings, quit.
        if let i = args.firstIndex(of:"--test-agent"), i + 1 < args.count { Task { await testAgent(args, i, model:model, finance:finance) } }
        // --perf: fill an empty test library with a large one, then time what each
        // section does when it opens; print milliseconds, quit.
        if args.contains("--test-write") { Task { await testWrite(args, 0, model:model, finance:finance) } }
        if args.contains("--test-delete-chat") { Task { await testDeleteChat(args, 0, model:model, finance:finance) } }
        if args.contains("--test-settings") { Task { await testSettings(args, 0, model:model, finance:finance) } }
        // --snapshot <png>: after a few seconds, write the window as it looks to the file and quit.
        if let i = args.firstIndex(of:"--snapshot"), i + 1 < args.count { Task { NSApp.activate(ignoringOtherApps:true); try? await Task.sleep(for:.seconds(Double(ProcessInfo.processInfo.environment["SNAPSHOT_DELAY"] ?? "") ?? 4)); await snapshot(args[i + 1]); exit(0) } }
        // --show-sheet transaction|account: open that editor in its own window (for --snapshot).
        if let i = args.firstIndex(of:"--show-sheet"), i + 1 < args.count {
            let view: AnyView = args[i + 1] == "account" ? AnyView(AccountEditor(finance:finance, row:FinanceRow(raw:[:]))) : AnyView(TransactionEditor(finance:finance, row:FinanceRow(raw:[:])))
            let window = NSWindow(contentViewController:NSHostingController(rootView:view)); window.title = "Sheet"; window.makeKeyAndOrderFront(nil)
        }
        // --dark: draw in dark mode. --new-chat: start a new agent conversation.
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named:.darkAqua) }
        if args.contains("--new-chat") { model.agent.newChat() }
        // --seed-demo: fill an empty test library with a small, realistic one for screenshots; keeps running.
        if args.contains("--seed-demo") { seedDemo(model:model, finance:finance) }
        if args.contains("--perf") { Task { await perf(args, 0, model:model, finance:finance) } }
        // --test-news <png>: follow topics, fetch live headlines, save one, read and
        // summarize an article with NOTEBOOK_TEST_AGENT_URL's model, draw the list, quit.
        if let i = args.firstIndex(of:"--test-news"), i + 1 < args.count { Task { await testNews(args, i, model:model, finance:finance) } }
        // --render-accounts <png>: draw the all-accounts table with current prices, quit.
        if let i = args.firstIndex(of:"--render-accounts"), i + 1 < args.count { Task {
            await finance.refreshPrices()
            let renderer = ImageRenderer(content:FinanceAccountsTable(finance:finance, openAccount:{ _ in }).page.padding(24).frame(width:1000).background(Color.white)); renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data:tiff)?.representation(using:.png, properties:[:]) { try? png.write(to:URL(fileURLWithPath:args[i + 1])) }
            exit(0)
        } }
        if args.contains("--print-finance") { Task { await printFinance(args, 0, model:model, finance:finance) } }
    }
    private static func testLinks(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
            let links = model.links
            @MainActor func dump(_ label: String) async { try? await Task.sleep(for:.milliseconds(400)); print(label, links.collections.map(\.name), links.links.map { [$0.title, $0.site, $0.url, $0.collection ?? "-", $0.note, $0.tags.joined(separator:","), $0.savedBy] }) }
            let recipes = links.addCollection("Recipes")
            let apple = await links.add("apple.com", collection:nil)
            let wiki = await links.add("https://en.wikipedia.org/wiki/Saturn", collection:recipes?.id)
            _ = await links.add("not a url", collection:nil); print("bad url error:", links.error ?? "none"); links.error = nil
            _ = await links.add("http://192.168.1.1/admin", collection:nil); print("private:", links.links.first { $0.url.contains("192.168") }?.title ?? "missing")
            await dump("added")
            if let apple = links.links.first(where: { $0.id == apple?.id }) { links.update(apple, note:"Home page", tags:["tech"], collection:.some(recipes?.id)) }
            await dump("edited")
            if let recipes { links.rename(recipes, to:"Reading") }
            await dump("renamed")
            if let wiki = links.links.first(where: { $0.id == wiki?.id }) { links.delete(wiki) }
            if let recipes = links.collections.first { links.delete(recipes) }
            await dump("deleted")
            print("revisions:", (try? model.store.revisions(kind:"links").count) ?? -1, "error:", links.error ?? "none")
            exit(0)
    }
    private static func testAsk(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
            let agent = model.agent
            for question in args[i + 1].split(separator:"|").map(String.init) {
                agent.newChat(); agent.send(question, allowWrites:false)
                while agent.busy { try? await Task.sleep(for:.milliseconds(100)) }
                let shown = agent.messages.filter { $0.role != "user" }.map { m in "[\(m.role)\(m.raw["kidReply"].map { "/\($0)" } ?? "")] " + m.content.replacingOccurrences(of:"\n", with:" ") }
                print("Q:", question, "=>", shown.joined(separator:" ¦ "))
            }
            print("sections:", MacSection.visible(agent.policy).map(\.rawValue), "limit:", agent.kidLimit, "settings locked:", (try? agent.saveSettings(["provider":"openai","baseURL":"https://api.openai.com/v1","model":"x"], key:"", clear:false)) == nil)
            exit(0)
    }
    private static func testMoney(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
            let money = model.money, policy = model.agent.policy
            @MainActor func dump(_ label: String) { print(label, money.goals.map { "\($0.name) \($0.saved)/\($0.target)\($0.done ? " done" : "")" }, money.error ?? "") ; money.error = nil }
            money.add(name:"LEGO space shuttle", target:60); money.add(name:"", target:5); money.add(name:"Book", target:0); dump("added")
            if let lego = money.goals.first { money.change(lego, by:5); money.change(money.goals[0], by:1) }; dump("saved")
            money.add(name:"Book", target:12); if let book = money.goals.first(where: { $0.name == "Book" }) { money.change(book, by:100) }; dump("capped")
            if let book = money.goals.first(where: { $0.name == "Book" }) { money.change(book, by:-5); money.change(money.goals.first { $0.name == "Book" }!, by:-50) }; dump("taken out")
            print("sections:", MacSection.visible(policy).map(\.rawValue), "allowance:", KidApps.allowance(policy), "templates:", KidApps.templates(policy), "reminder:", KidApps.reminder(policy) ?? "none")
            let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            print("pending reminders:", pending.map { "\($0.identifier) \(($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents.hour ?? -1):\(($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents.minute ?? -1)" }, "authorization:", await UNUserNotificationCenter.current().notificationSettings().authorizationStatus.rawValue)
            print("template note:", model.newItem(kind:"notes", template:NoteTemplate.named("Reading log")).raw["title"] ?? "", model.newItem(kind:"notes", template:NoteTemplate.named("Reading log")).content)
            let page = KidMoney(money:money, allowance:KidApps.allowance(policy)).content.padding(24).frame(width:620).background(Color.white)
            let renderer = ImageRenderer(content:page); renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data:tiff)?.representation(using:.png, properties:[:]) { try? png.write(to:URL(fileURLWithPath:args[i + 1])) }
            if args.contains("--keep") { exit(0) }
            for goal in money.goals { money.delete(goal) }; dump("removed")
            print("money revisions:", (try? model.store.revisions(kind:"money").count) ?? -1)
            exit(0)
    }
    private static func robinhoodTools(_ file: String, model: NotebookModel) async {
        let link = model.robinhood
        link.openURL = { NSWorkspace.shared.open($0) }
        if !link.connected { print("opening Robinhood sign-in…"); await link.connect() }
        guard link.connected else { print("not connected:", link.error ?? ""); exit(1) }
        var out: [String:Any] = [:]
        do { out["tools"] = try await link.tools() } catch { print("tools failed:", error.localizedDescription) }
        let samples: [(String, [String:Any])] = [("get_equity_quotes", ["symbols":["AAPL", "NVDA"]]), ("get_earnings_calendar", [:]), ("get_option_chains", ["symbol":"AAPL"])]
        for (tool, arguments) in samples {
            do { out[tool] = try await link.call(tool, arguments) } catch { out[tool] = "error: " + error.localizedDescription }
        }
        try? jsonData(out).write(to:URL(fileURLWithPath:file))
        print("wrote", file, "tools:", (out["tools"] as? [[String:Any]])?.count ?? 0)
        exit(0)
    }
    private static func testTrading(_ dir: String, model: NotebookModel) async {
        let trading = model.trading
        trading.saveSettings(["watchlist":["NVDA", "AAPL", "AMD", "MSFT", "TSLA", "META", "AMZN", "GOOGL"], "notify":false])
        print("model:", model.agent.canSummarize ? model.agent.modelLabel : "none (rules only)")
        // With ideas already saved (a second run), just check prices and draw.
        if trading.ideas.isEmpty { await trading.research() }
        for note in trading.notes { print("note:", note.ticker, "-", note.text) }
        for idea in trading.ideas {
            print("idea:", idea.ticker, idea.vehicle, idea.action, "unit", idea.number("unitCost"), "stop", idea.number("stop"), "target", idea.number("target"), "exitBy", idea.text("exitBy"), "|", idea.text("summary"))
        }
        await trading.check()
        print("cash", trading.cash, "statuses:", trading.ideas.map { "\($0.ticker)=\($0.status)" }, "values:", trading.ideas.map { "\($0.ticker)=\(trading.value($0).map { String(format:"%.2f", $0) } ?? "nil")" })
        func draw(_ view: some View, _ name: String) {
            let renderer = ImageRenderer(content:view.frame(width:760).background(Color.white)); renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data:tiff)?.representation(using:.png, properties:[:]) { try? png.write(to:URL(fileURLWithPath:dir + "/" + name)) }
        }
        draw(TradingOverview(trading:trading, agent:model.agent).page, "overview.png")
        for (n, idea) in trading.ideas.prefix(2).enumerated() { draw(TradeIdeaDetail(trading:trading, idea:idea).page, "idea\(n).png") }
        exit(0)
    }
    private static func testAgentTrading(model: NotebookModel) async {
        let trading = model.trading, now = ISO8601DateFormatter().string(from:Date())
        func check(_ label: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", label) }
        func run(_ name: String, _ args: [String:Any] = [:], write: Bool = true) async -> [String:Any] {
            do {
                let result = try await trading.agentTool(name, arguments:args, canWrite:write)
                _ = try jsonString(result)  // what the agent stores must be JSON
                return result
            } catch { return ["error":error.localizedDescription] }
        }
        try? model.store.save(kind:"trading", record:["id":"t-idea", "type":"idea", "ticker":"AAPL", "name":"Apple", "createdAt":now, "modifiedAt":now, "bullish":true, "vehicle":"stock",
                                                      "price":200, "stop":190, "target":215, "exitBy":"2099-01-01", "legs":[], "unitCost":200, "quantity":5, "summary":"Test", "reasons":[], "risks":[]])
        trading.reload()
        let overview = await run("trading_overview")
        check("overview counts the alert as buy", (overview["alerts"] as? [String:Int])?["buy"] == 1 && overview["account"] != nil)
        let open = await run("trading_alerts", ["status":"open"])
        check("alerts list it with its plan", ((open["alerts"] as? [[String:Any]])?.first?["id"] as? String) == "t-idea")
        let ticker = await run("trading_ticker", ["ticker":"aapl"])
        check("ticker quote has volume and market cap", ((ticker["quote"] as? [String:Any])?["averageVolume3Month"] as? Double ?? 0) > 0 && ((ticker["quote"] as? [String:Any])?["marketCap"] as? Double ?? 0) > 0)
        check("research isn't the agent's", await run("trading_research")["error"] != nil)
        check("volume floor setting saved", await run("trading_update", ["action":"settings", "settings":["minVolume":500_000]])["success"] as? Bool == true && trading.setting("minVolume") == 500_000)
        check("ticker has quote, technicals, company and headlines", ticker["quote"] != nil && ticker["technicals"] is [String:Any] && ticker["company"] != nil && ticker["headlines"] != nil)
        print("ticker keys:", ticker.keys.sorted(), "error:", ticker["error"] ?? "none")
        check("read-only refuses changes", await run("trading_update", ["action":"skip", "id":"t-idea"], write:false)["error"] != nil)
        check("bad setting refused", await run("trading_update", ["action":"settings", "settings":["riskPercent":500]])["error"] != nil)
        check("watch adds to the Trading watchlist", await run("trading_update", ["action":"watch", "symbols":["msft"]])["success"] as? Bool == true && trading.watchlist.contains("MSFT"))
        check("unwatch removes it", await run("trading_update", ["action":"unwatch", "symbols":["MSFT"]])["success"] as? Bool == true && !trading.watchlist.contains("MSFT"))
        check("bought logs the trade", await run("trading_update", ["action":"bought", "id":"t-idea", "quantity":5, "price":201])["success"] as? Bool == true && trading.idea("t-idea")?.realOpen == true)
        let holding = await run("trading_alerts", ["status":"holding"])
        check("holding shows profit when priced", ((holding["alerts"] as? [[String:Any]])?.first?["profit"]) != nil)
        check("sold closes it", await run("trading_update", ["action":"sold", "id":"t-idea", "price":210])["success"] as? Bool == true && trading.idea("t-idea")?.status == "Sold")
        check("sold profit is 45", ((await run("trading_alerts", ["status":"sold"])["alerts"] as? [[String:Any]])?.first?["profit"] as? NSNumber)?.doubleValue == 45)
        check("delete removes it", await run("trading_update", ["action":"delete", "id":"t-idea"])["success"] as? Bool == true && trading.idea("t-idea") == nil)
        exit(0)
    }
    private static func renderTicker(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
            let symbol = args[i + 1]
            await finance.refreshPrices()
            let info = await finance.companyInfo(symbol), points = await finance.priceHistory(symbol, range:"1y")
            print("ticker", symbol, "info:", info?["name"] ?? "nil", "points:", points.count, "accounts:", finance.tickerByAccount(symbol).count, "transactions:", finance.tickerTransactions(symbol).count)
            let trading = model.trading
            trading.pages[symbol] = (await trading.candles(symbol), await TradingModel.headlines(symbol, name:info?["name"] as? String ?? symbol))
            print("candles:", trading.pages[symbol]?.candles.count ?? 0, "headlines:", trading.pages[symbol]?.headlines.count ?? 0, "keys:", info?.keys.sorted() ?? [])
            for headline in trading.pages[symbol]?.headlines ?? [] { print("  ", headline["date"]?.prefix(16) ?? "", "·", headline["source"] ?? "", "·", headline["title"] ?? "") }
            try? await Task.sleep(for:.seconds(1))
            let page = TickerDetail(finance:finance, ticker:symbol, openAccount:{ _ in }, trading:trading).page.frame(width:900).background(Color.white)
            let renderer = ImageRenderer(content:page); renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data:tiff)?.representation(using:.png, properties:[:]) { try? png.write(to:URL(fileURLWithPath:args[i + 2])) }
            exit(0)
    }
    private static func testSharing(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
            let sharing = model.sharing, links = model.links, library = model.shareLibrary
            sharing.localOnly = true
            @MainActor func settle() async { model.reload(); links.reload(); try? await Task.sleep(for:.milliseconds(500)) }
            @MainActor func check(_ label: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", label) }
            // A note, shared: it moves into its share.
            let n = try! model.store.save(kind:"notes", record:["id":"t-note", "title":"Groceries", "content":"<p>Milk</p>", "modifiedAt":ISO8601DateFormatter().string(from:Date())])
            await settle()
            guard let note = model.notes.first(where: { $0.id == "t-note" }), let shared = await sharing.shareNote(note) else { print("FAIL share note", sharing.error ?? ""); exit(1) }
            await settle()
            check("note moved out of the notebook", (try? model.store.records("notes", entity:"t-note"))?.isEmpty == true)
            let item = model.notes.first { $0.share == shared.id }
            check("shared note listed once, editable, mine", item != nil && model.notes.filter { $0.title == "Groceries" }.count == 1 && item?.readOnly == false && item?.sharedWithMe == false)
            let draft = NotebookDraft(item:item!, kind:"notes", store:model.store(for:item!))
            draft.change("content", "<p>Milk, eggs</p>"); await draft.flush()
            check("edit saved in the share", (try? library.store(shared.id).records("notes"))?.first?["content"] as? String == "<p>Milk, eggs</p>" && (try? library.store(shared.id).pendingCount()) == 2)
            _ = n
            // A collection, shared, then a link added to it and one moved out.
            let folder = links.addCollection("Trip")!
            _ = await links.add("https://example.com/a", collection:folder.id); _ = await links.add("https://example.com/b", collection:folder.id)
            await settle()
            guard let collection = links.collections.first(where: { $0.id == folder.id }), let linkShare = await sharing.shareCollection(collection) else { print("FAIL share collection", sharing.error ?? ""); exit(1) }
            await settle()
            check("collection and links moved", (try? model.store.records("links"))?.isEmpty == true && (try? library.store(linkShare.id).records("links").count) == 3)
            check("collection shows as shared", links.collections.first?.share == linkShare.id && links.links.allSatisfy { $0.share == linkShare.id })
            _ = await links.add("https://example.com/c", collection:folder.id); await settle()
            check("new link goes into the share", (try? library.store(linkShare.id).records("links").count) == 4)
            if let a = links.links.first(where: { $0.url.hasSuffix("/a") }) { links.update(a, collection:.some(nil)) }; await settle()
            check("link moved out comes back to the notebook", (try? model.store.records("links").count) == 1 && links.links.first { $0.url.hasSuffix("/a") }?.share == nil)
            // Someone else's view-only note and collection.
            let theirs = ShareInfo(id:UUID().uuidString.lowercased(), kind:"note", entity:"their-note", title:"Recipes", owner:false, ownerName:"Priya", canEdit:false, ready:true, published:true)
            try! library.upsert(theirs); try! library.setKey(theirs.id, SyncCrypto.randomKey())
            _ = try! library.store(theirs.id).save(kind:"notes", record:["id":"their-note", "title":"Recipes", "content":"<p>Dal</p>", "modifiedAt":"2026-10-01T00:00:00Z"])
            let theirLinks = ShareInfo(id:UUID().uuidString.lowercased(), kind:"links", entity:"their-folder", title:"Reading", owner:false, ownerName:"Priya", canEdit:false, ready:true, published:true)
            try! library.upsert(theirLinks); try! library.setKey(theirLinks.id, SyncCrypto.randomKey())
            _ = try! library.store(theirLinks.id).save(kind:"links", record:["id":"their-folder", "type":"collection", "name":"Reading", "createdAt":"2026-10-01T00:00:00Z"])
            sharing.reload(); await settle()
            let view = model.notes.first { $0.share == theirs.id }
            check("their note is view only, under Shared with You", view?.readOnly == true && view?.sharedWithMe == true)
            check("their collection is view only", links.collections.first { $0.id == "their-folder" }?.editable == false)
            _ = await links.add("https://example.com/x", collection:"their-folder"); print("view-only add:", links.error ?? "allowed"); links.error = nil
            check("nothing added to a view-only collection", (try? library.store(theirLinks.id).records("links").count) == 1)
            // A kid set to Family only may share only with listed accounts.
            let kid: [String:Any] = ["managed":true, "sharing":["mode":"family", "family":["mom@example.com"]]]
            check("family-only kid rules", SharingModel.allowed("mom@example.com", policy:kid) && !SharingModel.allowed("stranger@example.com", policy:kid) && !SharingModel.allowed("", policy:kid)
                  && !SharingModel.allowed("mom@example.com", policy:["managed":true, "sharing":["mode":"off"]]) && SharingModel.allowed("x@y.z", policy:nil))
            // An account at a level, then a viewer's copy.
            let finance = FinanceModel(store:model.store, shares:library, authorized:{ true })
            finance.save(FinanceRow(raw:["name":"Brokerage", "type":"brokerage", "cashBalance":250]), field:"accounts")
            guard let account = finance.rows("accounts").first(where: { $0.name == "Brokerage" }) else { print("FAIL account"); exit(1) }
            finance.saveTransaction(FinanceRow(raw:["accountId":account.id, "type":"buy", "ticker":"AAPL", "quantity":10, "pricePerShare":150, "date":"2026-09-01"]))
            guard let accountShare = await sharing.shareAccount(account, level:"balance", view:finance.accountView(account.id, level:"balance")!) else { print("FAIL share account", sharing.error ?? ""); exit(1) }
            finance.reload()
            let published = (try? library.store(accountShare.id).records("accountViews"))?.first
            check("balance level has no holdings", published?["holdings"] == nil && published?["transactions"] == nil && published?["name"] as? String == "Brokerage")
            await sharing.setLevel(accountShare, "transactions"); finance.reload()
            let raised = (try? library.store(accountShare.id).records("accountViews"))?.first
            check("raised level adds holdings and transactions", (raised?["holdings"] as? [[String:Any]])?.first?["ticker"] as? String == "AAPL" && (raised?["transactions"] as? [[String:Any]])?.count == 1)
            let revisions = (try? library.store(accountShare.id).revisions(kind:"accountViews").count) ?? 0
            finance.reload(); finance.reload()
            check("unchanged account isn't republished", (try? library.store(accountShare.id).revisions(kind:"accountViews").count) == revisions)
            var viewer = accountShare; viewer.id = UUID().uuidString.lowercased(); viewer.owner = false; viewer.ownerName = "Priya"; viewer.canEdit = false
            try! library.upsert(viewer); try! library.setKey(viewer.id, SyncCrypto.randomKey())
            _ = try! library.store(viewer.id).save(kind:"accountViews", record:raised!)
            finance.reload()
            check("their account appears, outside the totals", finance.sharedAccounts.count == 1 && finance.total("totalValue") == ((finance.accountSummary(account.id)["totalValue"] as? NSNumber)?.doubleValue ?? -1))
            let page = SharedAccountView(info:viewer, view:raised!, price:{ _ in 200 }).page.frame(width:620).background(Color.white)
            let renderer = ImageRenderer(content:page); renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data:tiff)?.representation(using:.png, properties:[:]) { try? png.write(to:URL(fileURLWithPath:args[i + 1])) }
            check("viewer values holdings with its own prices", SharedAccountView(info:viewer, view:raised!, price:{ _ in 200 }).total == 250 - 1500 + 2000)
            // Deleting the account stops its share.
            finance.delete(account, field:"accounts"); try? await Task.sleep(for:.milliseconds(500))
            check("deleted account's share stopped", library.share(accountShare.id) == nil)
            // Stop the note share: it comes back, with the edit, as one note.
            await sharing.stop(sharing.share(shared.id)!); await settle()
            let back = (try? model.store.records("notes", entity:"t-note")) ?? []
            check("stopped note restored with the edit", back.count == 1 && back.first?["content"] as? String == "<p>Milk, eggs</p>" && back.first?["_syncConflict"] as? Bool == false)
            check("its share is gone", library.share(shared.id) == nil && !FileManager.default.fileExists(atPath:library.directory.appendingPathComponent(shared.id + ".sqlite").path))
            // Deleting a shared collection removes it for everyone; leaving theirs keeps nothing.
            if let c = links.collections.first(where: { $0.id == folder.id }) { links.delete(c) }; try? await Task.sleep(for:.milliseconds(500))
            await sharing.leave(sharing.share(theirs.id)!); await sharing.leave(sharing.share(theirLinks.id)!); await sharing.leave(sharing.share(viewer.id)!)
            await settle()
            check("all shares gone", library.shares().isEmpty && sharing.shares.isEmpty)
            check("collection deleted, moved-out link kept", links.collections.isEmpty && links.links.map(\.url) == ["https://example.com/a"])
            print("notes:", model.notes.map(\.title), "errors:", sharing.error ?? "none", links.error ?? "none", finance.error ?? "none")
            exit(0)
    }
    /// --test-settings: save two services and check each keeps its own values, then restore.
    private static func testSettings(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
        let agent = model.agent, defaults = UserDefaults.standard
        let saved = defaults.data(forKey:"notebook-agent-config"), savedAll = defaults.data(forKey:"notebook-agent-configs")
        do {
            try agent.saveSettings(["provider":"compatible", "baseURL":"http://127.0.0.1:8080/v1", "model":"qwen3.8-27b"], key:"", clear:false)
            try agent.saveSettings(["provider":"anthropic", "baseURL":"https://api.anthropic.com/v1", "model":"claude-opus-5-5"], key:"", clear:false)
        } catch { print("FAIL save", error.localizedDescription) }
        let remembered = AgentModel.rememberedSettings
        print(remembered["compatible"]?["model"] == "qwen3.8-27b" && remembered["compatible"]?["baseURL"] == "http://127.0.0.1:8080/v1" ? "PASS" : "FAIL", "local server kept after saving Anthropic", remembered["compatible"] ?? [:])
        print(remembered["anthropic"]?["model"] == "claude-opus-5-5" && agent.config["provider"] == "anthropic" ? "PASS" : "FAIL", "Anthropic is current and kept")
        if let saved { defaults.set(saved, forKey:"notebook-agent-config") } else { defaults.removeObject(forKey:"notebook-agent-config") }
        if let savedAll { defaults.set(savedAll, forKey:"notebook-agent-configs") } else { defaults.removeObject(forKey:"notebook-agent-configs") }
        exit(0)
    }
    /// --test-delete-chat: two conversations with messages; delete one; check what's left.
    private static func testDeleteChat(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
        let agent = model.agent, store = model.store
        agent.newChat(); let first = agent.selected!
        agent.newChat(); let second = agent.selected!
        let now = ISO8601DateFormatter().string(from:Date())
        _ = try? store.setKey("app_agentMessages", value:["messages":[["id":"m1", "threadID":first, "role":"user", "content":"Keep me", "createdAt":now], ["id":"m2", "threadID":second, "role":"user", "content":"Delete me", "createdAt":now], ["id":"m3", "threadID":second, "role":"assistant", "content":"Me too", "createdAt":now]]])
        agent.reload()
        print(agent.threads.count == 2 ? "PASS" : "FAIL", "two conversations")
        agent.deleteThread(second)
        let messages = (try? store.records("agentMessages")) ?? []
        print(agent.threads.map(\.id) == [first] ? "PASS" : "FAIL", "deleted conversation gone, other kept")
        print(messages.map { $0["id"] as? String ?? "" } == ["m1"] ? "PASS" : "FAIL", "its messages gone", messages.map { $0["id"] as? String ?? "" })
        print(agent.selected != second ? "PASS" : "FAIL", "selection moved off it", agent.error ?? "")
        exit(0)
    }
    /// --test-write: News's one-shot model call against NOTEBOOK_TEST_AGENT_URL (and a missing model).
    private static func testWrite(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
        guard let url = ProcessInfo.processInfo.environment["NOTEBOOK_TEST_AGENT_URL"] else { return }
        let agent = model.agent, defaults = UserDefaults.standard
        let saved = defaults.data(forKey:"notebook-agent-config"), savedAll = defaults.data(forKey:"notebook-agent-configs")
        for name in [ProcessInfo.processInfo.environment["NOTEBOOK_TEST_AGENT_MODEL"] ?? "llama3.2", "missing"] {
            try? agent.saveSettings(["provider":"compatible", "baseURL":url, "model":name], key:"", clear:false)
            do { let text = try await agent.write(system:NewsModel.summarySystem, prompt:NewsModel.summaryPrompt(title:"Test", material:"ARTICLE TEXT:\nThe council approved a new park on Tuesday. It opens in May and cost $2 million."), maxTokens:300); print("model", name, "->", text.prefix(200).replacingOccurrences(of:"\n", with:" ")) }
            catch { print("model", name, "-> error:", error.localizedDescription) }
        }
        if let saved { defaults.set(saved, forKey:"notebook-agent-config") } else { defaults.removeObject(forKey:"notebook-agent-config") }
        if let savedAll { defaults.set(savedAll, forKey:"notebook-agent-configs") } else { defaults.removeObject(forKey:"notebook-agent-configs") }
        exit(0)
    }
    private static func testAgent(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
        guard let url = ProcessInfo.processInfo.environment["NOTEBOOK_TEST_AGENT_URL"] else { return }
            let agent = model.agent, saved = UserDefaults.standard.data(forKey:"notebook-agent-config")
            do { try agent.saveSettings(["provider":ProcessInfo.processInfo.environment["NOTEBOOK_TEST_AGENT_PROVIDER"] ?? "compatible", "baseURL":url, "model":ProcessInfo.processInfo.environment["NOTEBOOK_TEST_AGENT_MODEL"] ?? "llama3.2"], key:"", clear:false) } catch { print("settings:", error.localizedDescription) }
            agent.newChat(); agent.send(args[i + 1], allowWrites:false)
            while agent.busy { try? await Task.sleep(for:.milliseconds(100)) }
            print("error:", agent.error ?? "none")
            for message in agent.messages { print("[\(message.role)]", message.content.replacingOccurrences(of:"\n", with:" ")) }
            if let saved { UserDefaults.standard.set(saved, forKey:"notebook-agent-config") } else { UserDefaults.standard.removeObject(forKey:"notebook-agent-config") }
            exit(0)
    }
    /// An app may capture its own windows without Screen Recording permission.
    /// Web views draw out of process, so each is snapshotted and drawn over its place.
    private static func snapshot(_ path: String) async {
        guard let window = NSApp.windows.first(where: { $0.title == "Sheet" }) ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }), let content = window.contentView else { print("snapshot: no window"); return }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { print("snapshot: capture failed"); return }
        let scale = CGFloat(image.width) / window.frame.width
        let rep = NSBitmapImageRep(cgImage:image)
        func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
        for web in webViews(content) {
            guard let shot = try? await web.takeSnapshot(configuration:nil) else { continue }
            let frame = web.convert(web.bounds, to:nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
            shot.draw(in:NSRect(x:frame.minX * scale, y:frame.minY * scale, width:frame.width * scale, height:frame.height * scale), from:.zero, operation:.sourceOver, fraction:1)
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using:.png, properties:[:])?.write(to:URL(fileURLWithPath:path))
        print("snapshot:", path)
    }
    private static func seedDemo(model: NotebookModel, finance: FinanceModel) {
        let store = model.store
        guard (try? store.records("notes").isEmpty) ?? false, (try? store.records("journal").isEmpty) ?? false else { print("seed-demo: library is not empty, left alone"); return }
        let iso = ISO8601DateFormatter()
        func ago(_ hours: Double) -> String { iso.string(from:Date().addingTimeInterval(-hours * 3600)) }
        let notes: [(String, String, [String], Bool)] = [
            ("Q4 planning", "<h2>Goals</h2><ul><li>Ship the native Mac app</li><li>Move the agent to the local model</li><li>Quarterly portfolio rebalance</li></ul><p>Review progress every <b>Friday</b> afternoon.</p>", ["work", "planning"], true),
            ("Reading list", "<p>Books to read before the end of the year:</p><ul><li><i>The Making of the Atomic Bomb</i></li><li><i>Working in Public</i></li><li><i>The Art of Doing Science and Engineering</i></li></ul>", ["books"], true),
            ("Kitchen remodel ideas", "<p>Open shelving on the left wall, quartz counters, warmer under-cabinet lighting. Get three quotes by mid-November.</p>", ["home"], false),
            ("Trip to Kyoto", "<p>Fushimi Inari at sunrise, Arashiyama in the afternoon. Book the ryokan for the second week of April.</p>", ["travel"], false),
            ("Meeting notes — design review", "<p>Agreed to simplify the sidebar and move filters into the toolbar. Follow up with the icon set.</p>", ["work"], false),
            ("Sourdough", "<p>500 g flour, 350 g water, 100 g starter, 10 g salt. Bulk ferment 5 hours, cold proof overnight.</p>", ["recipes"], false),
            ("Gift ideas", "<ul><li>Noise-cancelling headphones</li><li>Pottery class</li><li>A good chef's knife</li></ul>", ["family"], false),
        ]
        _ = try? store.setKey("app_notes", value:["notes":notes.enumerated().map { i, n in ["id":"demo-n\(i)", "title":n.0, "content":n.1, "tags":n.2, "pinned":n.3, "createdAt":ago(Double(i) * 30 + 2), "modifiedAt":ago(Double(i) * 30 + 2)] }])
        let entries: [(Double, String, String, [String])] = [
            (0, "happy", "<p>Long walk by the bay this morning. Finished the timestamp fix and the agent finally feels quick on the local model.</p>", ["walk"]),
            (1, "amazing", "<p>Dinner with the whole family. The kids planned the menu themselves.</p>", ["family"]),
            (3, "neutral", "<p>Quiet day. Caught up on reading and cleaned up the garage.</p>", []),
            (6, "stressed", "<p>Deadline crunch. Need to block focus time next week.</p>", ["work"]),
            (12, "happy", "<p>First cold morning of autumn. Made soup.</p>", []),
            (34, "sad", "<p>Missed the concert, the car wouldn't start.</p>", []),
        ]
        _ = try? store.setKey("app_journal", value:["entries":entries.enumerated().map { i, e in ["id":"demo-j\(i)", "date":JournalDates.stored(Date().addingTimeInterval(-e.0 * 86400)), "mood":e.1, "content":e.2, "tags":e.3, "createdAt":ago(e.0 * 24), "modifiedAt":ago(e.0 * 24)] }])
        let accounts: [[String:Any]] = [["id":"demo-a1", "name":"Brokerage", "type":"brokerage", "cashBalance":4210.55], ["id":"demo-a2", "name":"Roth IRA", "type":"roth_ira", "cashBalance":820.0], ["id":"demo-a3", "name":"401(k)", "type":"401k", "cashBalance":0.0]]
        let buys: [(String, String, Double, Double)] = [("demo-a1", "AAPL", 40, 151.2), ("demo-a1", "NVDA", 60, 48.5), ("demo-a1", "MSFT", 15, 310.0), ("demo-a2", "VTI", 80, 205.4), ("demo-a2", "GOOGL", 25, 121.9), ("demo-a3", "VOO", 55, 380.1), ("demo-a3", "AMZN", 20, 132.6)]
        let txns = buys.enumerated().map { i, b in ["id":"demo-x\(i)", "accountId":b.0, "type":"buy", "ticker":b.1, "quantity":b.2, "pricePerShare":b.3, "date":String(ago(Double(i + 1) * 24 * 90).prefix(10))] as [String:Any] }
        try? store.setFinance(["app_portfolio":["accounts":accounts, "transactions":txns], "app_portfolio-history":["snapshots":(0..<60).map { (n: Int) -> [String:Any] in ["id":String(ago(Double(60 - n) * 24).prefix(10)), "date":String(ago(Double(60 - n) * 24).prefix(10)), "totalValue":104_000 + Double(n) * 260 + sin(Double(n) / 4) * 1_800] }], "app_spending":[String:Any]()])
        let reading = model.links.addCollection("Reading")
        let links: [(String, String, String)] = [("https://www.apple.com/macos/", "macOS — Apple", "apple.com"), ("https://developer.apple.com/design/human-interface-guidelines/", "Human Interface Guidelines", "developer.apple.com"), ("https://en.wikipedia.org/wiki/Saturn", "Saturn — Wikipedia", "en.wikipedia.org"), ("https://www.nytimes.com/section/technology", "Technology — The New York Times", "nytimes.com")]
        for (i, l) in links.enumerated() {
            var raw: [String:Any] = ["id":"demo-l\(i)", "type":"link", "url":l.0, "title":l.1, "site":l.2, "note":"", "tags":[String](), "savedBy":"Mac", "createdAt":ago(Double(i) * 20)]
            if i % 2 == 1, let reading { raw["collection"] = reading.id }
            _ = try? store.save(kind:"links", record:raw)
        }
        _ = try? store.setKey("app_agentThreads", value:["threads":[["id":"demo-t1", "title":"How did my portfolio do this month?", "createdAt":ago(5), "modifiedAt":ago(5)], ["id":"demo-t2", "title":"Plan a weekend in Kyoto", "createdAt":ago(50), "modifiedAt":ago(50)]]])
        _ = try? store.setKey("app_agentMessages", value:["messages":[["id":"demo-m1", "threadID":"demo-t1", "role":"user", "content":"How did my portfolio do this month?", "runID":"r1", "runAt":ago(5), "sequence":0, "createdAt":ago(5)], ["id":"demo-m2", "threadID":"demo-t1", "role":"assistant", "content":"Your portfolio is up **3.8%** this month, led by **NVDA (+11%)** and **MSFT (+5%)**. The Roth IRA lagged slightly because VTI was flat.\n\n- Brokerage: +5.1%\n- Roth IRA: +1.2%\n- 401(k): +2.9%", "runID":"r1", "runAt":ago(5), "sequence":1, "createdAt":ago(5)]]])
        model.reload(); finance.reload(); model.links.reload(); model.agent.reload()
        model.trading.saveSettings(["watchlist":["AAPL", "NVDA", "TSLA", "AMD"]])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Lease renewal.txt")
        try? "Lease renewal\n\nThe lease for 42 Harbor Street renews on January 1, 2027 for twelve months. Monthly rent rises from $2,850 to $2,960. Notice to vacate must be given 60 days before the end of the term. Pets remain allowed with the existing deposit.".write(to:file, atomically:true, encoding:.utf8)
        Task { _ = await model.documents.importFiles([file], source:"documents"); print("seed-demo: seeded") }
    }
    private static func perf(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
            @MainActor func ms(_ label: String, _ body: () -> Void) { let t = Date(); body(); print(String(format:"%-38@ %8.1f ms", label as NSString, Date().timeIntervalSince(t) * 1000)) }
            let store = model.store
            if (try? store.records("notes").isEmpty) ?? true {
                let t = Date(), iso = ISO8601DateFormatter()
                func day(_ i: Int) -> String { iso.string(from:Date(timeIntervalSince1970:1_700_000_000 + Double(i) * 3600 * 7)) }
                let body = String(repeating:"<p>Some notebook text with <b>bold</b> words and a list.</p><ul><li>one</li><li>two</li></ul>", count:12)
                _ = try? store.setKey("app_notes", value:["notes":(0..<1500).map { ["id":"n\($0)", "title":"Note \($0)", "content":body, "tags":["t\($0 % 9)"], "createdAt":day($0), "modifiedAt":day($0)] }])
                _ = try? store.setKey("app_journal", value:["entries":(0..<800).map { ["id":"j\($0)", "date":String(day($0 * 3).prefix(10)), "mood":"good", "content":body, "tags":[String](), "createdAt":day($0), "modifiedAt":day($0)] }])
                let tickers = (0..<40).map { "T\($0)" }
                let accounts: [[String:Any]] = (0..<12).map { (n: Int) -> [String:Any] in ["id":"a\(n)", "name":"Account \(n)", "type":"brokerage", "cashBalance":1000.0] }
                var txns: [[String:Any]] = []
                for i in 0..<3000 {
                    let type: String = i % 7 == 0 ? "sell" : "buy"
                    let quantity: Double = 1 + Double(i % 5), price: Double = 50 + Double(i % 90)
                    txns.append(["id":"x\(i)", "accountId":"a\(i % 12)", "type":type, "ticker":tickers[i % 40], "quantity":quantity, "pricePerShare":price, "date":String(day(i).prefix(10))])
                }
                let snaps: [[String:Any]] = (0..<365).map { (n: Int) -> [String:Any] in let value: Double = 100000 + Double(n) * 50; return ["id":"s\(n)", "date":String(day(n * 24 / 7).prefix(10)), "totalValue":value] }
                try? store.setFinance(["app_portfolio":["accounts":accounts, "transactions":txns], "app_portfolio-history":["snapshots":snaps], "app_spending":[String:Any]()])
                _ = try? store.setKey("app_links", value:["links":(0..<400).map { ["id":"l\($0)", "type":"link", "url":"https://example.com/\($0)", "title":"Link \($0)", "createdAt":day($0)] }])
                _ = try? store.setKey("app_agentThreads", value:["threads":(0..<30).map { ["id":"th\($0)", "title":"Chat \($0)", "createdAt":day($0), "modifiedAt":day($0)] }])
                _ = try? store.setKey("app_agentMessages", value:["messages":(0..<1500).map { ["id":"m\($0)", "threadID":"th\($0 % 30)", "role":$0 % 2 == 0 ? "user" : "assistant", "content":String(repeating:"A reply about my notes. ", count:20), "createdAt":day($0)] }])
                print(String(format:"seeded in %.1f s", Date().timeIntervalSince(t)))
            }
            for (html, expected) in [("<p>Milk &amp; eggs</p><ul><li>bread</li></ul>", "Milk & eggs bread"), ("<h2>Café</h2><p>naïve&nbsp;日本</p>", "Café naïve 日本"), ("  <p></p>", "")] {
                let got = NotebookItem.plainText(html); print(got == expected ? "PASS" : "FAIL", "preview", got.debugDescription)
            }
            print("PASS preview length", NotebookItem.plainText(String(repeating:"<p>日本語のテキスト</p>", count:100)).utf8.count <= 300)
            let finance = FinanceModel(store:store, shares:model.shareLibrary, authorized:{ true })
            ms("store: notes records") { _ = try? store.records("notes") }
            ms("store: journal records") { _ = try? store.records("journal") }
            ms("store: finance blobs") { for key in ["app_portfolio", "app_portfolio-history", "app_spending"] { _ = try? store.getKey(key) } }
            ms("finance.reload (main thread)") { finance.reload() }
            let accounts = finance.rows("accounts")
            ms("Finance sidebar: \(accounts.count) account values") { for a in accounts { _ = finance.accountSummary(a.id)["totalValue"] } }
            ms("Finance All Accounts page") { _ = finance.summary; _ = finance.holdings.sorted { $0.number("currentValue") > $1.number("currentValue") } }
            ms("Finance one account page (8 numbers)") { for _ in 0..<8 { _ = finance.accountSummary(accounts[0].id) }; _ = finance.scopedHoldings(accounts[0].id) }
            ms("agent.reload") { model.agent.reload() }
            let t = Date(); model.reload(); while model.notes.count < 1500 { try? await Task.sleep(for:.milliseconds(5)) }
            print(String(format:"%-38@ %8.1f ms", "model.reload (background)" as NSString, Date().timeIntervalSince(t) * 1000))
            ms("Notes list: filter + previews") { _ = model.notes.filter { $0.preview.lowercased().contains("") }.sorted { $0.modified > $1.modified }.map(\.preview) }
            ms("Journal list: months") { var titles = Set<String>(); for e in model.journal { titles.insert(e.entryDate?.formatted(.dateTime.month(.wide).year()) ?? ""); _ = e.preview } }
            let t2 = Date(); let before = model.reloadVersion; model.reload(); try? await Task.sleep(for:.milliseconds(1)); while model.reloadVersion == before && Date().timeIntervalSince(t2) < 0.2 { try? await Task.sleep(for:.milliseconds(2)) }
            print(String(format:"%-38@ %8.1f ms (reloaded: %@)", "model.reload, nothing changed" as NSString, Date().timeIntervalSince(t2) * 1000, model.reloadVersion != before ? "yes" : "no"))
            let t3 = Date(); await finance.refresh(); print(String(format:"%-38@ %8.1f ms", "finance.refresh, nothing changed" as NSString, Date().timeIntervalSince(t3) * 1000))
            ms("Finance sidebar again (cached)") { for a in accounts { _ = finance.accountSummary(a.id)["totalValue"] } }
            ms("Notes list body (NotesList.notes)") { _ = model.notes.filter { $0.title.lowercased().contains("") || $0.preview.lowercased().contains("") }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.modified > $1.modified } }
            exit(0)
    }
    private static func testNews(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
            let news = model.news, agent = model.agent, saved = UserDefaults.standard.data(forKey:"notebook-agent-config")
            @MainActor func check(_ label: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", label) }
            news.follow("AI"); news.follow("Cricket"); news.follow("ai")
            check("topics saved once", news.topics == ["AI", "Cricket"] && (try? model.store.records("news", entity:"settings").first?["topics"] as? [String]) == ["AI", "Cricket"])
            await news.refresh(force:true)
            for topic in news.topics { print(topic, Dictionary(grouping:news.stories(topic), by:\.via).mapValues(\.count)) }
            check("headlines for each topic", news.topics.allSatisfy { !news.stories($0).isEmpty })
            check("all recent and dated", news.stories.allSatisfy { ($0.publishedAt.map { Date().timeIntervalSince($0) < NewsModel.maxAge }) ?? false })
            check("no repeated story in a topic", news.topics.allSatisfy { t in let s = news.stories(t).map { NewsModel.normalized($0.title) }; return Set(s).count == s.count })
            check("bing links unwrapped", news.stories.filter { $0.via == "bing" }.allSatisfy { !($0.url.contains("bing.com/news/apiclick")) })
            for story in news.latest.prefix(5) { print("  ", story.via, "|", story.byline, "|", story.title.prefix(80), "|", story.url.prefix(60)) }
            if let first = news.latest.first { news.toggleSaved(first); check("saved", news.isSaved(first) && news.saved.count == 1); news.toggleSaved(first); check("unsaved", news.saved.isEmpty) }
            news.toggleSource("hn"); await news.refresh(force:true)
            check("hacker news added", news.sources == ["google", "bing", "hn"] && news.stories.contains { $0.via == "hn" })
            if let url = ProcessInfo.processInfo.environment["NOTEBOOK_TEST_AGENT_URL"] {
                try? agent.saveSettings(["provider":"compatible", "baseURL":url, "model":ProcessInfo.processInfo.environment["NOTEBOOK_TEST_AGENT_MODEL"] ?? "llama3.2"], key:"", clear:false)
                // Google News links turn into the publisher's own address.
                var resolved: [(NewsStory, String)] = []
                for story in news.latest.filter({ $0.via == "google" }).prefix(4) {
                    let link = await NewsModel.resolve(story.url)
                    if !link.contains("news.google.com") { resolved.append((story, link)) }
                }
                check("google links resolved (\(resolved.count) of 4)", resolved.count >= 3)
                for item in resolved.prefix(2) { print("  ", item.1.prefix(90)) }
                // A Google story summarized from its article, with nenva's prompt.
                var done = false
                for (story, link) in resolved where !done {
                    guard let page = try? await agent.readArticle(link), page.text.count >= 400 else { print("   not readable:", URL(string:link)?.host() ?? link); continue }
                    print("read", page.text.count, "chars from", URL(string:link)?.host() ?? "")
                    var partials = 0
                    let started = Date()
                    do {
                        let summary = try await agent.write(system:NewsModel.summarySystem, prompt:NewsModel.summaryPrompt(title:story.title, material:"ARTICLE TEXT:\n" + String(page.text.prefix(agent.summaryInput))), maxTokens:8000) { _ in partials += 1 }
                        let seconds = Int(Date().timeIntervalSince(started))
                        check("article summary streamed (\(partials) updates, \(seconds) s)", summary.count > 200 && summary.contains("Key points"))
                        print(summary.prefix(700))
                    } catch { print("FAIL summary", error.localizedDescription) }
                    done = true
                }
                check("a google article was readable", done)
                // When an article can't be read: other outlets' coverage.
                if let story = news.latest.first {
                    let others = await NewsModel.coverage(story)
                    print("coverage for:", story.title.prefix(70), "->", others.count, "items")
                    check("coverage found", others.count >= 2)
                }
                // Catch me up.
                await news.catchMeUp(agent)
                let lines = news.digest?.split(separator:"\n").count ?? 0
                check("digest written (\(lines) lines)", lines >= 1 && news.error == nil)
                print(news.digest ?? news.error ?? "")
                if let saved { UserDefaults.standard.set(saved, forKey:"notebook-agent-config") } else { UserDefaults.standard.removeObject(forKey:"notebook-agent-config") }
            }
            let page = VStack(alignment:.leading, spacing:6) { ForEach(news.latest.prefix(8)) { NewsRow(story:$0, showTopic:true); Divider() } }.padding(20).frame(width:520).background(Color.white)
            let renderer = ImageRenderer(content:page); renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data:tiff)?.representation(using:.png, properties:[:]) { try? png.write(to:URL(fileURLWithPath:args[i + 1])) }
            exit(0)
    }
    private static func printFinance(_ args: [String], _ i: Int, model: NotebookModel, finance: FinanceModel) async {
            finance.reload()
            if args.contains("--refresh-prices") { await finance.refreshPrices() }
            let accounts = finance.rows("accounts").map { a -> [String:Any] in ["name":a.name, "value":finance.accountSummary(a.id)["totalValue"] ?? 0, "holdings":finance.scopedHoldings(a.id).map { [$0.text("ticker"), $0.number("totalShares")] }] }
            let report: [String:Any] = ["error":finance.error ?? NSNull(), "accounts":accounts, "transactions":finance.rows("transactions").count, "totalValue":finance.total("totalValue"), "cash":finance.total("cash"), "notice":finance.notice ?? NSNull(), "notes":model.notes.count, "journal":model.journal.count, "agentError":model.agent.error ?? NSNull(), "agentTools":model.agent.threads.count]
            if let data = try? JSONSerialization.data(withJSONObject:report, options:[.sortedKeys]) { print(String(decoding:data, as:UTF8.self)) }
            exit(0)
    }
}
#endif
