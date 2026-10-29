import XCTest
@testable import NotebookCore

final class ExploreTests: XCTestCase {
    func testGICSTreeAndNames() {
        XCTAssertEqual(GICS.names.keys.filter { $0.count == 2 }.count, 11)
        XCTAssertEqual(GICS.subIndustries.count, 163)
        XCTAssertEqual(GICS.name("45301020"), "Semiconductors")
        XCTAssertEqual(GICS.name(GICS.industry("45301020")), "Semiconductors & Semiconductor Equipment")
        XCTAssertEqual(GICS.name(GICS.sector("45301020")), "Information Technology")
        XCTAssertEqual(GICS.code(forSubIndustry:"Internet Services & Infrastructure"), "45102030")
        XCTAssertEqual(GICS.code(forSubIndustry:"independent power producers and energy traders"), GICS.code(forSubIndustry:"Independent Power Producers & Energy Traders"))
        XCTAssertNil(GICS.code(forSubIndustry:"Norwalk, Connecticut"))
        XCTAssertEqual(GICS.name(""), "Unclassified")
    }

    func testSP500Wikitext() {
        // Rows as Wikipedia writes them: cells on their own lines, a row whose
        // first cell starts with a single "|", one with cells joined on a line,
        // and a ticker with a comment beside it.
        let text = """
        Intro
        {| class="wikitable sortable" id="constituents"
        |-
        ! Symbol !! Security !! GICS Sector !! GICS Sub-Industry !! Headquarters
        |-
        || {{NyseSymbol|MMM}}
        || [[3M]]
        || Industrials
        || Industrial Conglomerates
        || [[Saint Paul, Minnesota]]
        |-
        | {{NyseSymbol|RDDT}}
        || [[Reddit]]
        || Communication Services
        || Interactive Media & Services
        || [[San Francisco]], California
        |-
        || {{NyseSymbol|EME}}
        || [[Emcor]]|| Industrials
        || Construction & Engineering
        || [[Norwalk, Connecticut]]
        |-
        || {{NyseSymbol|BRK.B <!-- DO NOT CHANGE THIS TICKER -->}}
        || [[Berkshire Hathaway]]<ref>note</ref>
        || Financials
        || Multi-Sector Holdings
        || [[Omaha, Nebraska]]
        |}
        """
        let rows = ExploreSources.sp500(wikitext:text)
        XCTAssertEqual(rows.map(\.symbol), ["MMM", "RDDT", "EME", "BRK.B"])
        XCTAssertEqual(rows.map(\.name), ["3M", "Reddit", "Emcor", "Berkshire Hathaway"])
        XCTAssertEqual(rows[1].code, "50203010")
        XCTAssertEqual(rows[2].code, GICS.code(forSubIndustry:"Construction & Engineering"))
    }

    func testNasdaqFormats() {
        let list = #"{"data":{"data":{"rows":[{"symbol":"SHOP","companyName":"Shopify Inc. Class A Subordinate Voting Shares"},{"symbol":"AAPL","companyName":"Apple Inc. Common Stock"}]}}}"#
        XCTAssertEqual(ExploreSources.nasdaq100(json:Data(list.utf8)), [ExploreMember(symbol:"SHOP", name:"Shopify Inc"), ExploreMember(symbol:"AAPL", name:"Apple Inc")])
        let index = #"{"aaData":[{"Name":"Trend Micro Rg","Symbol":"4704"},{"Name":"Atos Grp","Symbol":"ATO"},{"Name":"ZSCALER INC","Symbol":"ZS"}]}"#
        XCTAssertEqual(ExploreSources.nasdaqIndex(json:Data(index.utf8)).map(\.symbol), ["ATO", "ZS"])
        XCTAssertTrue(ExploreSources.sameCompany("ADV MICRO DEVICES", "Advanced Micro Devices, Inc."))
        XCTAssertTrue(ExploreSources.sameCompany("INTL BUSINESS MACH", "International Business Machines"))
        XCTAssertTrue(ExploreSources.sameCompany("INTL BUSINESS MACH", "IBM"))
        XCTAssertFalse(ExploreSources.sameCompany("Atos Grp", "Atmos Energy Corporation"))
        XCTAssertFalse(ExploreSources.sameCompany("Atos Grp", "AE"))
    }

    func testAmplifyAndStockAnalysis() {
        let csv = """
        Date,Account,StockTicker,CUSIP,SecurityName,Shares,Price,MarketValue,Weightings,NetAssets,SharesOutstanding,CreationUnits,MoneyMarketFlag
        10/26/2026,BDRY,AGPXX,825252885,Invesco Government,1,100,1,1%,1,1,1,Y
        10/26/2026,HACK,4704 JP,6125286,Trend Micro Inc/Japan,1,1,1,1%,1,1,1,
        10/26/2026,HACK,AGPXX,825252885,"Invesco Government, Agency",1,100,1,1%,1,1,1,Y
        10/26/2026,HACK,ATEN,002121101,A10 Networks Inc,1,25,1,2.8%,1,1,1,
        10/26/2026,HACK,Cash&Other,Cash&Other,Cash & Other,1,1,1,0%,1,1,1,
        10/26/2026,HACK,CRWD,22788C105,"CrowdStrike Holdings, Inc.",1,1,1,5%,1,1,1,
        """
        XCTAssertEqual(ExploreSources.amplify(csv:csv, fund:"HACK"), [ExploreMember(symbol:"ATEN", name:"A10 Networks Inc"), ExploreMember(symbol:"CRWD", name:"CrowdStrike Holdings, Inc.")])
        let html = #"<a href="/stocks/screener/">x</a><a href="/stocks/pltr/">PLTR</a><a href="/stocks/brk.b/">B</a><a href="/stocks/pltr/">again</a>"#
        XCTAssertEqual(ExploreSources.stockAnalysis(html:html).map(\.symbol), ["PLTR", "BRK.B"])
    }

    func testPlacementsFromAModelReply() {
        let reply = "Here you go:\n```json\n{\"ZS\": \"45103020\", \"NET\": 45102030, \"OKTA\": \"99999999\", \"XYZ\": \"45103010\", \"S\": \"4510\"}\n```"
        XCTAssertEqual(ExploreSources.placements(reply:reply, asked:["ZS", "NET", "OKTA", "S"]), ["ZS":"45103020", "NET":"45102030"])
        XCTAssertEqual(ExploreSources.placements(reply:"I can't tell.", asked:["ZS"]), [:])
    }

    func testPeriodChanges() {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:"UTC")!
        let now = calendar.date(from:DateComponents(year:2026, month:10, day:26))!
        // 300 daily closes ending today, rising 1 a day from 100.
        let closes = (0..<300).map { (date:now.addingTimeInterval(Double($0 - 299) * 86400 * 1.2), close:100 + Double($0)) }
        let changes = ExplorePeriods.changes(closes:closes, price:400, calendar:calendar, now:now)
        XCTAssertEqual(changes["1W"]!, (400 / 394 - 1) * 100, accuracy:1e-9)
        XCTAssertEqual(changes["3M"]!, (400 / 336 - 1) * 100, accuracy:1e-9)
        XCTAssertEqual(changes["1Y"]!, 300, accuracy:1e-9)
        let lastOfYear = closes.last { calendar.component(.year, from:$0.date) < 2026 }!.close
        XCTAssertEqual(changes["YTD"]!, (400 / lastOfYear - 1) * 100, accuracy:1e-9)
        XCTAssertTrue(ExplorePeriods.changes(closes:Array(closes.suffix(3)), price:400, calendar:calendar, now:now).isEmpty)
        XCTAssertEqual(ExplorePeriods.weighted([(change:1, cap:3), (change:-1, cap:1), (change:nil, cap:5), (change:9, cap:0)])!, 0.5, accuracy:1e-9)
        XCTAssertNil(ExplorePeriods.weighted([]))
    }

    func testTreemapFillsTheRectangle() {
        let rect = CGRect(x:10, y:20, width:600, height:400)
        let values = [500.0, 200, 120, 80, 50, 30, 0, 20]
        let tiles = Treemap.layout(values, in:rect)
        XCTAssertEqual(tiles.count, values.count)
        XCTAssertEqual(tiles[6], .zero)
        let total = values.reduce(0, +)
        for (value, tile) in zip(values, tiles) where value > 0 {
            XCTAssertEqual(Double(tile.width * tile.height), value / total * 240_000, accuracy:0.5)
            XCTAssertTrue(rect.insetBy(dx:-0.01, dy:-0.01).contains(tile))
        }
        // No two tiles overlap.
        for i in tiles.indices { for j in tiles.indices where j > i { XCTAssertLessThan(tiles[i].intersection(tiles[j]).width * tiles[i].intersection(tiles[j]).height, 0.01) } }
        XCTAssertEqual(Treemap.layout([1, 2], in:.zero), [.zero, .zero])
    }
}
