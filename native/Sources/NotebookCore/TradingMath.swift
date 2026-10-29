import Foundation

/// One trading day (or week) of prices.
public struct Candle: Sendable, Equatable {
    public var date: Date
    public var open: Double, high: Double, low: Double, close: Double, volume: Double
    public init(date: Date, open: Double, high: Double, low: Double, close: Double, volume: Double) {
        self.date = date; self.open = open; self.high = high; self.low = low; self.close = close; self.volume = volume
    }
}

/// The technical picture of one stock on its latest day.
public struct Indicators: Sendable, Equatable {
    public var price: Double
    public var sma20: Double, sma50: Double, sma200: Double?
    public var rsi14: Double, atr14: Double
    public var macd: Double, macdSignal: Double
    public var bollingerUpper: Double, bollingerLower: Double
    /// Today's volume against the 20-day average (1.0 is normal).
    public var volumeRatio: Double
    /// Shares traded a day, averaged over the 20 days before today.
    public var averageVolume: Double
    public var high52: Double, low52: Double
    /// The highest high and lowest low of the 20 days before today.
    public var high20: Double, low20: Double
    public var change5: Double, change20: Double
    public var macdHistogram: Double { macd - macdSignal }
    /// Plain values for the model's prompt and the screen.
    public var summary: [String:Any] {
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        var out: [String:Any] = ["price":r(price), "sma20":r(sma20), "sma50":r(sma50), "rsi14":r(rsi14), "atr14":r(atr14), "macd":r(macd), "macdSignal":r(macdSignal),
                                 "bollingerUpper":r(bollingerUpper), "bollingerLower":r(bollingerLower), "volumeVs20DayAverage":r(volumeRatio), "averageVolume20d":averageVolume.rounded(), "high52w":r(high52), "low52w":r(low52),
                                 "changePercent5d":r(change5), "changePercent20d":r(change20)]
        if let sma200 { out["sma200"] = r(sma200) }
        return out
    }
}

/// A rule that fired, leaning bullish (positive weight) or bearish (negative).
public struct TradeSignal: Sendable, Equatable {
    public var name: String
    public var weight: Int
    public init(_ name: String, _ weight: Int) { self.name = name; self.weight = weight }
}

/// Indicators, signal rules and position sizing. No network, no storage: the
/// app hands it prices and gets numbers back, so every rule is testable.
public enum TradingMath {
    public static func sma(_ values: [Double], _ period: Int) -> [Double?] {
        guard period > 0 else { return values.map { _ in nil } }
        var out = [Double?](repeating:nil, count:values.count), sum = 0.0
        for (i, v) in values.enumerated() {
            sum += v
            if i >= period { sum -= values[i - period] }
            if i >= period - 1 { out[i] = sum / Double(period) }
        }
        return out
    }
    /// Exponential average seeded with the simple average of the first period.
    public static func ema(_ values: [Double], _ period: Int) -> [Double?] {
        guard period > 0, values.count >= period else { return values.map { _ in nil } }
        var out = [Double?](repeating:nil, count:values.count)
        let k = 2 / Double(period + 1)
        var current = values[0..<period].reduce(0, +) / Double(period)
        out[period - 1] = current
        for i in period..<values.count { current = values[i] * k + current * (1 - k); out[i] = current }
        return out
    }
    /// Wilder's RSI.
    public static func rsi(_ closes: [Double], _ period: Int = 14) -> [Double?] {
        guard closes.count > period else { return closes.map { _ in nil } }
        var out = [Double?](repeating:nil, count:closes.count), gain = 0.0, loss = 0.0
        for i in 1...period { let d = closes[i] - closes[i - 1]; if d > 0 { gain += d } else { loss -= d } }
        gain /= Double(period); loss /= Double(period)
        func value() -> Double { loss == 0 ? 100 : 100 - 100 / (1 + gain / loss) }
        out[period] = value()
        for i in (period + 1)..<closes.count {
            let d = closes[i] - closes[i - 1]
            gain = (gain * Double(period - 1) + max(d, 0)) / Double(period)
            loss = (loss * Double(period - 1) + max(-d, 0)) / Double(period)
            out[i] = value()
        }
        return out
    }
    /// Wilder's average true range.
    public static func atr(_ candles: [Candle], _ period: Int = 14) -> [Double?] {
        guard candles.count > period else { return candles.map { _ in nil } }
        let ranges = candles.indices.map { i -> Double in
            let c = candles[i]
            guard i > 0 else { return c.high - c.low }
            let prev = candles[i - 1].close
            return max(c.high - c.low, abs(c.high - prev), abs(c.low - prev))
        }
        var out = [Double?](repeating:nil, count:candles.count)
        var current = ranges[1...period].reduce(0, +) / Double(period)
        out[period] = current
        for i in (period + 1)..<candles.count { current = (current * Double(period - 1) + ranges[i]) / Double(period); out[i] = current }
        return out
    }
    public static func macd(_ closes: [Double]) -> (line: [Double?], signal: [Double?]) {
        let fast = ema(closes, 12), slow = ema(closes, 26)
        let line = zip(fast, slow).map { f, s -> Double? in guard let f, let s else { return nil }; return f - s }
        let start = line.firstIndex { $0 != nil } ?? line.count
        let values = line[start...].compactMap { $0 }
        let signal = ema(values, 9)
        return (line, [Double?](repeating:nil, count:start) + signal)
    }

    /// The indicators on the last candle, or on an earlier one with `back`.
    /// Needs at least 60 days of history.
    public static func indicators(_ candles: [Candle], back: Int = 0) -> Indicators? {
        let candles = Array(candles.dropLast(back))
        guard candles.count >= 60 else { return nil }
        let closes = candles.map(\.close), n = candles.count - 1
        let sma20s = sma(closes, 20), sma50s = sma(closes, 50), sma200s = sma(closes, 200)
        let (line, signal) = macd(closes)
        guard let sma20 = sma20s[n], let sma50 = sma50s[n], let rsi = rsi(closes)[n], let atr = atr(candles)[n], let m = line[n], let s = signal[n] else { return nil }
        let last20 = closes[(n - 19)...n]
        let deviation = (last20.map { pow($0 - sma20, 2) }.reduce(0, +) / 20).squareRoot()
        let volumes = candles[(n - 20)..<n].map(\.volume), average = volumes.reduce(0, +) / Double(volumes.count)
        let year = candles.suffix(252), prior = candles[(n - 20)..<n]
        func change(_ days: Int) -> Double { closes[n - days] > 0 ? (closes[n] / closes[n - days] - 1) * 100 : 0 }
        return Indicators(price:closes[n], sma20:sma20, sma50:sma50, sma200:sma200s[n], rsi14:rsi, atr14:atr, macd:m, macdSignal:s,
                          bollingerUpper:sma20 + 2 * deviation, bollingerLower:sma20 - 2 * deviation,
                          volumeRatio:average > 0 ? candles[n].volume / average : 1, averageVolume:average,
                          high52:year.map(\.high).max() ?? closes[n], low52:year.map(\.low).min() ?? closes[n],
                          high20:prior.map(\.high).max() ?? closes[n], low20:prior.map(\.low).min() ?? closes[n],
                          change5:change(5), change20:change(20))
    }

    /// The rules that fire today. Crossovers look back a few days so a signal
    /// from yesterday's close still counts this morning.
    public static func signals(_ candles: [Candle]) -> [TradeSignal] {
        guard let now = indicators(candles) else { return [] }
        let earlier = (1...3).compactMap { indicators(candles, back:$0) }
        var out: [TradeSignal] = []
        if let sma200 = now.sma200 {
            if now.price > now.sma50, now.sma50 > sma200 { out.append(.init("Uptrend: price above the 50-day, 50-day above the 200-day", 1)) }
            if now.price < now.sma50, now.sma50 < sma200 { out.append(.init("Downtrend: price below the 50-day, 50-day below the 200-day", -1)) }
            if let last = earlier.last, let old200 = last.sma200 {
                if last.sma50 <= old200, now.sma50 > sma200 { out.append(.init("Golden cross: the 50-day moved above the 200-day", 2)) }
                if last.sma50 >= old200, now.sma50 < sma200 { out.append(.init("Death cross: the 50-day moved below the 200-day", -2)) }
            }
        }
        if earlier.contains(where: { $0.macd <= $0.macdSignal }), now.macd > now.macdSignal { out.append(.init("MACD crossed above its signal line", 1)) }
        if earlier.contains(where: { $0.macd >= $0.macdSignal }), now.macd < now.macdSignal { out.append(.init("MACD crossed below its signal line", -1)) }
        if now.rsi14 < 30 { out.append(.init("RSI \(Int(now.rsi14)): oversold", 1)) }
        else if earlier.contains(where: { $0.rsi14 < 30 }) { out.append(.init("RSI recovered from oversold (now \(Int(now.rsi14)))", 2)) }
        if now.rsi14 > 75 { out.append(.init("RSI \(Int(now.rsi14)): overbought", -1)) }
        if now.price > now.high20, now.volumeRatio >= 1.5 { out.append(.init("Breakout above the 20-day high on \(String(format:"%.1f", now.volumeRatio))× volume", 2)) }
        if now.price < now.low20, now.volumeRatio >= 1.5 { out.append(.init("Breakdown below the 20-day low on \(String(format:"%.1f", now.volumeRatio))× volume", -2)) }
        if let sma200 = now.sma200, now.price > sma200, now.sma20 > now.sma50, abs(now.price - now.sma20) <= now.atr14, (38...52).contains(now.rsi14) {
            out.append(.init("Pullback to the 20-day average in an uptrend", 1))
        }
        if now.price < now.bollingerLower { out.append(.init("Closed below the lower Bollinger band", 1)) }
        if now.price > now.bollingerUpper, now.rsi14 > 70 { out.append(.init("Stretched above the upper Bollinger band", -1)) }
        return out
    }
    public static func score(_ signals: [TradeSignal]) -> Int { signals.reduce(0) { $0 + $1.weight } }

    /// Default levels for a trade on the underlying: the stop two ATRs away,
    /// the target three (risking 1 to make 1.5).
    public static func levels(price: Double, atr: Double, bullish: Bool) -> (stop: Double, target: Double) {
        bullish ? (price - 2 * atr, price + 3 * atr) : (price + 2 * atr, price - 3 * atr)
    }
    /// Whether a stop and target make sense for the direction: on the right
    /// sides of the price, the stop within 0.5–5 ATRs and the reward at least the risk.
    public static func sensible(price: Double, atr: Double, stop: Double, target: Double, bullish: Bool) -> Bool {
        let risk = bullish ? price - stop : stop - price, reward = bullish ? target - price : price - target
        return risk >= 0.5 * atr && risk <= 5 * atr && reward >= risk
    }
    /// Shares to buy: lose at most `riskPercent` of the budget if the stop is
    /// hit, spend at most `maxPositionPercent` of it, and never more than the cash.
    public static func shares(budget: Double, cash: Double, riskPercent: Double, maxPositionPercent: Double, price: Double, stop: Double) -> Int {
        let perShare = price - stop
        guard price > 0, perShare > 0 else { return 0 }
        let byRisk = budget * riskPercent / 100 / perShare, bySize = budget * maxPositionPercent / 100 / price, byCash = cash / price
        return max(0, Int(min(byRisk, bySize, byCash).rounded(.down)))
    }
    /// Contracts to buy when the whole debit can be lost: at most
    /// `maxOptionPercent` of the budget, and never more than the cash.
    public static func contracts(budget: Double, cash: Double, maxOptionPercent: Double, debit: Double) -> Int {
        let cost = debit * 100
        guard cost > 0 else { return 0 }
        return max(0, Int(min(budget * maxOptionPercent / 100, cash).rounded(.down) / cost))
    }
}
