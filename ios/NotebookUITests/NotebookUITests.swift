import XCTest

final class NotebookUITests: XCTestCase {
    func testOfflineWritingSurvivesRelaunchAndJournalStaysIndependent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-test-data"]
        app.launch()
        XCTAssertTrue(app.buttons["New note"].waitForExistence(timeout:15))
        app.buttons["New note"].tap()
        let title = app.textFields["Untitled"]
        XCTAssertTrue(title.waitForExistence(timeout:5))
        title.tap(); title.typeText("Offline iPhone note")
        let editor = app.webViews.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout:10), app.debugDescription)
        editor.tap(); editor.typeText("Written without the Mac.\nFormatting stays with this note.")
        let shot = XCTAttachment(screenshot:app.screenshot()); shot.name = "iPhone note editor"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.staticTexts["Saved on this device"].waitForExistence(timeout:5))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons.containing(.staticText,identifier:"Offline iPhone note").firstMatch.waitForExistence(timeout:10))
        app.buttons.containing(.staticText,identifier:"Offline iPhone note").firstMatch.tap()
        XCTAssertTrue(app.webViews.textViews.firstMatch.waitForExistence(timeout:10))
        XCTAssertTrue(app.webViews.textViews.firstMatch.value.debugDescription.contains("Written without the Mac."))
        app.navigationBars.buttons["Notes"].tap()
        app.tabBars.buttons["Journal"].tap()
        app.buttons["New journal entry"].tap()
        let journalEditor = app.webViews.textViews.firstMatch
        XCTAssertTrue(journalEditor.waitForExistence(timeout:10))
        journalEditor.tap(); journalEditor.typeText("A journal entry saved offline.")
        app.navigationBars.buttons["Journal"].tap()
        XCTAssertTrue(app.staticTexts["A journal entry saved offline."].waitForExistence(timeout:5))
        app.buttons["Settings and sync"].tap()
        XCTAssertTrue(app.staticTexts["Your notebook, together."].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["Scan pairing code"].exists)
        let settingsShot = XCTAttachment(screenshot:app.screenshot()); settingsShot.name = "iPhone pairing settings"; settingsShot.lifetime = .keepAlways; add(settingsShot)
    }
}

extension NotebookUITests {
    func testFinanceImportsEditsAndPersistsOffline() throws {
        let app=XCUIApplication()
        app.launchArguments=["--ui-testing","--reset-ui-test-data"]
        app.launchEnvironment["NOTEBOOK_FINANCE_TEST_EXPORT"] = #"{"format":"nenva-finance","version":1,"portfolio":{"accounts":[{"id":"a1","name":"Brokerage","type":"brokerage","cashBalance":5000}],"transactions":[{"id":"t1","accountId":"a1","type":"holding","ticker":"AAPL","quantity":10,"pricePerShare":150,"date":"2026-10-01"}],"properties":[{"id":"p1","name":"Home","currentValue":450000}],"liabilities":[{"id":"d1","name":"Mortgage","type":"mortgage","balance":200000}],"strategies":[{"id":"s1","name":"Retirement","objective":"Long term","targets":[],"rules":[]}],"watchlist":[]},"history":{"snapshots":[{"date":"2026-10-01","totalValue":456500,"netWorth":256500,"cash":5000,"stockValue":1500,"realEstateValue":450000,"liabilities":200000,"tickers":{"AAPL":{"price":150,"shares":10,"value":1500}},"accounts":{"a1":{"value":6500,"cash":5000}}}]},"spending":{"accounts":[{"id":"b1","name":"Checking","type":"depository","balance":{"current":2500}}],"transactions":[{"id":"bt1","accountId":"b1","name":"Cafe","merchant":"Cafe","amount":6.5,"date":"2026-10-01","category":"FOOD_AND_DRINK"}],"rules":[]}}"#
        let dateFormatter=DateFormatter(); dateFormatter.dateFormat="yyyy-MM-dd"
        app.launchEnvironment["NOTEBOOK_FINANCE_TEST_EXPORT"] = app.launchEnvironment["NOTEBOOK_FINANCE_TEST_EXPORT"]?.replacingOccurrences(of:#""date":"2026-10-01","category""#,with:"\"date\":\"\(dateFormatter.string(from:Date()))\",\"category\"")
        app.launchEnvironment["NOTEBOOK_FINANCE_TEST_QUOTES"] = #"{"AAPL":{"price":200,"change":0,"updatedAt":9999999999999}}"#
        app.launch()
        continueAfterFailure = false
        let finance=app.buttons["Finance"].firstMatch
        XCTAssertTrue(finance.waitForExistence(timeout:15)); finance.tap()
        XCTAssertTrue(app.staticTexts["$257,000.00"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Brokerage"].exists)
        app.buttons["Finance actions"].tap()
        app.buttons["Add transaction"].tap()
        let ticker=app.textFields["finance-ticker"]
        XCTAssertTrue(ticker.waitForExistence(timeout:5)); ticker.tap(); ticker.typeText("AAPL")
        app.textFields["finance-quantity"].tap(); app.textFields["finance-quantity"].typeText("2")
        app.textFields["finance-price"].tap(); app.textFields["finance-price"].typeText("100")
        app.buttons["finance-save"].tap()
        XCTAssertTrue(app.staticTexts["$257,200.00"].waitForExistence(timeout:10))
        let shot=XCTAttachment(screenshot:app.screenshot()); shot.name="Finance native overview"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Finance actions"].tap(); app.buttons["Take snapshot"].tap()
        XCTAssertTrue(app.buttons["Snapshots (2)"].waitForExistence(timeout:5))
        app.buttons["Spending"].tap()
        XCTAssertTrue(app.staticTexts["Checking"].waitForExistence(timeout:5))
        for _ in 0..<5 { if app.staticTexts["Cafe"].isHittable { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Cafe"].exists)
        app.staticTexts["Cafe"].tap()
        XCTAssertTrue(app.switches["Apply to this merchant"].waitForExistence(timeout:5))
        app.switches["Apply to this merchant"].tap()
        app.buttons["Save"].tap()
        let spending=XCTAttachment(screenshot:app.screenshot()); spending.name="Finance native spending"; spending.lifetime = .keepAlways; add(spending)
        app.terminate()
        app.launchArguments=["--ui-testing"]
        app.launchEnvironment.removeValue(forKey:"NOTEBOOK_FINANCE_TEST_EXPORT")
        app.launch()
        XCTAssertTrue(app.buttons["Finance"].firstMatch.waitForExistence(timeout:10)); app.buttons["Finance"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["$257,200.00"].waitForExistence(timeout:10))
        app.buttons["Finance actions"].tap(); app.buttons["Export Finance data"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout:10),app.debugDescription)
        app.buttons["Save"].tap()
        if app.buttons["Replace"].waitForExistence(timeout:2) {app.buttons["Replace"].tap()}
        let returned=XCTNSPredicateExpectation(predicate:NSPredicate(format:"isHittable == true"),object:app.buttons["Finance actions"])
        XCTAssertEqual(XCTWaiter.wait(for:[returned],timeout:20),.completed,app.debugDescription)
        app.buttons["Finance actions"].tap(); app.buttons["Import Finance data"].tap()
        XCTAssertTrue(app.buttons["Browse"].waitForExistence(timeout:10) || app.buttons["Cancel"].exists,app.debugDescription)
        let file=app.cells.containing(NSPredicate(format:"label CONTAINS %@","nenva-finance")).firstMatch
        if !file.exists {
            if app.cells["DOC.sidebar.item.On My iPad"].exists { app.cells["DOC.sidebar.item.On My iPad"].tap() }
            else if app.cells["DOC.sidebar.item.On My iPhone"].exists { app.cells["DOC.sidebar.item.On My iPhone"].tap() }
            else if app.buttons["Recents"].exists { app.buttons["Recents"].tap() }
        }
        XCTAssertTrue(file.waitForExistence(timeout:10),app.debugDescription)
        file.tap()
        XCTAssertTrue(app.alerts["Import Finance data?"].waitForExistence(timeout:5),app.debugDescription)
        app.alerts.buttons["Import"].tap()
        XCTAssertTrue(app.staticTexts["$257,200.00"].waitForExistence(timeout:5))
    }
}


extension NotebookUITests {
    func testTypingDuringSlowSavePreservesLatestTextAndFlushesOnLeaving() throws {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchArguments=["--ui-testing","--reset-ui-test-data"]
        app.launchEnvironment["NOTEBOOK_TEST_LIBRARY_SIZE"]="1000"
        app.launchEnvironment["NOTEBOOK_TEST_SAVE_DELAY_MS"]="1000"
        app.launch()
        XCTAssertTrue(app.buttons["New note"].waitForExistence(timeout:30))
        app.buttons["New note"].tap()
        let title=app.textFields["Untitled"]
        XCTAssertTrue(title.waitForExistence(timeout:5))
        title.tap(); title.typeText("Responsive draft")
        let editor=app.webViews.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout:10))
        editor.tap()
        let first="Typing stays responsive while a save is running. "
        editor.typeText(first)
        // Continue typing while the deliberately slow background save is in flight.
        Thread.sleep(forTimeInterval:0.4)
        let last="These newest characters must survive navigation."
        let started=Date()
        editor.typeText(last)
        XCTAssertLessThan(Date().timeIntervalSince(started),8,"Typing was blocked by storage work")
        XCTAssertTrue(editor.value.debugDescription.contains(last))
        app.navigationBars.buttons["Notes"].tap()
        let row=app.buttons.containing(.staticText,identifier:"Responsive draft").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:10))
        app.terminate(); app.launchArguments=["--ui-testing"]; app.launch()
        XCTAssertTrue(row.waitForExistence(timeout:15)); row.tap()
        XCTAssertTrue(editor.waitForExistence(timeout:10))
        XCTAssertTrue(editor.value.debugDescription.contains(first + last),editor.value.debugDescription)
    }
}
