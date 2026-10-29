import XCTest
@testable import NotebookCore

final class TradingMathTests: XCTestCase {
    func candles(_ closes: [Double], volume: (Int) -> Double = { _ in 1_000_000 }) -> [Candle] {
        closes.enumerated().map { i, c in Candle(date:Date(timeIntervalSince1970:Double(i) * 86400), open:c, high:c + 1, low:c - 1, close:c, volume:volume(i)) }
    }

    func testAverages() {
        XCTAssertEqual(TradingMath.sma([1, 2, 3, 4, 5], 3).compactMap { $0 }, [2, 3, 4])
        let ema = TradingMath.ema([1, 2, 3, 4, 5], 3)
        XCTAssertNil(ema[1]); XCTAssertEqual(ema[2], 2); XCTAssertEqual(ema[3], 3); XCTAssertEqual(ema[4], 4)
    }

    func testRSI() {
        let rising = (0..<30).map { Double($0) }
        XCTAssertEqual(TradingMath.rsi(rising).last!, 100)
        let falling = rising.reversed().map { $0 }
        XCTAssertEqual(TradingMath.rsi(falling).last!!, 0, accuracy:0.001)
        // Equal ups and downs sit at 50.
        let zigzag = (0..<40).map { $0 % 2 == 0 ? 10.0 : 11.0 }
        XCTAssertEqual(TradingMath.rsi(zigzag).last!!, 50, accuracy:5)
    }

    func testATRIsTheDailyRange() {
        let flat = candles(Array(repeating:100, count:30))
        XCTAssertEqual(TradingMath.atr(flat).last!!, 2, accuracy:0.0001)
    }

    func testAverageVolumeIsTheTwentyDaysBeforeToday() {
        // 209K a day for the last 20 days, and a spike today that mustn't count.
        let bars = candles(Array(repeating:100, count:80), volume:{ $0 == 79 ? 5_000_000 : $0 >= 59 ? 209_000 : 2_000_000 })
        XCTAssertEqual(TradingMath.indicators(bars)!.averageVolume, 209_000, accuracy:0.5)
    }

    func testIndicatorsNeedHistory() {
        XCTAssertNil(TradingMath.indicators(candles(Array(repeating:10, count:59))))
        let ind = TradingMath.indicators(candles((0..<260).map { 50 + Double($0) * 0.5 }))!
        XCTAssertEqual(ind.price, 179.5)
        XCTAssertNotNil(ind.sma200)
        XCTAssertGreaterThan(ind.sma20, ind.sma50)
        XCTAssertGreaterThan(ind.change20, 0)
    }

    func testUptrendAndBreakout() {
        // A steady rise, a pause, then a jump through the range on triple volume.
        var closes = (0..<230).map { 50 + Double($0) * 0.4 }
        closes += Array(repeating:closes.last!, count:25)
        closes.append(closes.last! + 6)
        let signals = TradingMath.signals(candles(closes) { $0 == closes.count - 1 ? 3_000_000 : 1_000_000 })
        XCTAssertTrue(signals.contains { $0.name.hasPrefix("Uptrend") })
        XCTAssertTrue(signals.contains { $0.name.hasPrefix("Breakout") })
        XCTAssertGreaterThan(TradingMath.score(signals), 0)
    }

    func testDowntrendIsBearish() {
        let closes = (0..<260).map { 200 - Double($0) * 0.5 }
        let signals = TradingMath.signals(candles(closes))
        XCTAssertTrue(signals.contains { $0.name.hasPrefix("Downtrend") })
        XCTAssertLessThan(TradingMath.score(signals.filter { !$0.name.hasPrefix("RSI") && !$0.name.contains("Bollinger") }), 0)
    }

    func testLevelsAndSensible() {
        let long = TradingMath.levels(price:100, atr:2, bullish:true)
        XCTAssertEqual(long.stop, 96); XCTAssertEqual(long.target, 106)
        XCTAssertTrue(TradingMath.sensible(price:100, atr:2, stop:96, target:106, bullish:true))
        XCTAssertFalse(TradingMath.sensible(price:100, atr:2, stop:101, target:106, bullish:true), "stop above the price")
        XCTAssertFalse(TradingMath.sensible(price:100, atr:2, stop:96, target:102, bullish:true), "reward smaller than risk")
        XCTAssertFalse(TradingMath.sensible(price:100, atr:2, stop:80, target:150, bullish:true), "stop ten ATRs away")
        let short = TradingMath.levels(price:100, atr:2, bullish:false)
        XCTAssertTrue(TradingMath.sensible(price:100, atr:2, stop:short.stop, target:short.target, bullish:false))
    }

    func testSizing() {
        // $10k, 1% risk = $100; $4 to the stop = 25 shares; 20% cap = $2,000 = 20 shares.
        XCTAssertEqual(TradingMath.shares(budget:10_000, cash:10_000, riskPercent:1, maxPositionPercent:20, price:100, stop:96), 20)
        XCTAssertEqual(TradingMath.shares(budget:10_000, cash:10_000, riskPercent:1, maxPositionPercent:50, price:100, stop:96), 25)
        XCTAssertEqual(TradingMath.shares(budget:10_000, cash:500, riskPercent:1, maxPositionPercent:50, price:100, stop:96), 5)
        XCTAssertEqual(TradingMath.shares(budget:10_000, cash:10_000, riskPercent:1, maxPositionPercent:20, price:100, stop:100), 0)
        // 5% of $10k = $500: two contracts at $2.40, none at $6.
        XCTAssertEqual(TradingMath.contracts(budget:10_000, cash:10_000, maxOptionPercent:5, debit:2.4), 2)
        XCTAssertEqual(TradingMath.contracts(budget:10_000, cash:10_000, maxOptionPercent:5, debit:6), 0)
        XCTAssertEqual(TradingMath.contracts(budget:10_000, cash:300, maxOptionPercent:5, debit:1), 3)
    }
}
