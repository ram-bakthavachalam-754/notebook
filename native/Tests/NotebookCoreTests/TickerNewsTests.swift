import XCTest
@testable import NotebookCore

final class TickerNewsTests: XCTestCase {
    func testShortNames() {
        XCTAssertEqual(TickerNews.shortName("CrowdStrike Holdings, Inc."), "CrowdStrike")
        XCTAssertEqual(TickerNews.shortName("The Walt Disney Company"), "Walt Disney")
        XCTAssertEqual(TickerNews.shortName("Advanced Micro Devices, Inc."), "Advanced Micro Devices")
        XCTAssertEqual(TickerNews.shortName("Micron Technology, Inc."), "Micron")
        XCTAssertEqual(TickerNews.shortName("Bank of America Corporation"), "Bank of America")
        XCTAssertEqual(TickerNews.shortName("Alphabet Inc. (Class A)"), "Alphabet")
        XCTAssertEqual(TickerNews.shortName("Visa Inc."), "Visa")
        XCTAssertEqual(TickerNews.shortName("Group"), "Group")
    }
    func testQueries() {
        XCTAssertEqual(TickerNews.query(ticker:"CRWD", name:"CrowdStrike Holdings, Inc.", days:7), "(\"CrowdStrike\" OR CRWD) stock when:7d")
        XCTAssertEqual(TickerNews.query(ticker:"V", name:"Visa Inc.", days:2), "\"Visa\" stock when:2d")
        XCTAssertEqual(TickerNews.query(ticker:"ON", name:"ON Semiconductor Corporation", days:7), "\"ON Semiconductor\" stock when:7d")
        XCTAssertEqual(TickerNews.query(ticker:"BRK.B", name:"Berkshire Hathaway Inc.", days:7), "\"Berkshire Hathaway\" stock when:7d")
        XCTAssertEqual(TickerNews.query(ticker:"IBM", name:"IBM", days:7), "IBM stock when:7d")
        XCTAssertEqual(TickerNews.query(ticker:"ZZZ", name:"", days:7), "ZZZ stock when:7d")
    }
    func testListingsAndDuplicates() {
        XCTAssertTrue(TickerNews.isListing("SentinelOne, Inc. (S) Stock Price, News, Quote & History"))
        XCTAssertTrue(TickerNews.isListing("ON Semiconductor Corporation (ON) Latest Stock News & Headlines"))
        XCTAssertTrue(TickerNews.isListing("Form 8K SentinelOne Inc For: 26 October By Investing.com"))
        XCTAssertTrue(TickerNews.isListing("CRWD Oct 2026 282.500 put (CRWD261023P00282500) stock price, news, quote and history"))
        XCTAssertTrue(TickerNews.isListing("CRWD Oct 2026 282.500 put"))
        XCTAssertTrue(TickerNews.isListing("Crowdstrike Holdings Inc (CRWD) sentiment score, message volume, participation score and buzz level"))
        XCTAssertTrue(TickerNews.isListing("SentinelOne (NYSE:S) Stock Forecast & Analyst Predictions"))
        XCTAssertTrue(TickerNews.isListing("How to Buy Visa Stock (V) in 2026"))
        XCTAssertEqual(TickerNews.clean("Rosenblatt raises SentinelOne stock price target By Investing.com"), "Rosenblatt raises SentinelOne stock price target")
        XCTAssertEqual(TickerNews.clean("Stand By Me"), "Stand By Me")
        XCTAssertFalse(TickerNews.isListing("CrowdStrike Stock Rose Friday Amid Cyber Rally. Here's a Look at the Week"))
        XCTAssertFalse(TickerNews.isListing("Susquehanna raises Visa stock price target on AI agent opportunity"))
        XCTAssertEqual(TickerNews.key("On Semiconductor options suggest 8.4% move on earnings By Investing.com"), TickerNews.key("On Semiconductor options suggest 8.4% move on earnings"))
        XCTAssertNotEqual(TickerNews.key("Visa beats"), TickerNews.key("Visa misses"))
    }
}
