import Foundation

/// How a ticker page asks Google News about one company, and which results
/// aren't news. No network here: the app fetches the feed.
public enum TickerNews {
    /// The name people write in headlines: "CrowdStrike Holdings, Inc." →
    /// "CrowdStrike", "The Walt Disney Company" → "Walt Disney", "Alphabet Inc.
    /// (Class A)" → "Alphabet".
    public static func shortName(_ name: String) -> String {
        var words = name.replacingOccurrences(of:#"\([^)]*\)"#, with:" ", options:.regularExpression).replacingOccurrences(of:",", with:" ").split(separator:" ").map(String.init)
        if words.first?.lowercased() == "the", words.count > 1 { words.removeFirst() }
        let generic: Set<String> = ["inc", "inc.", "incorporated", "corp", "corp.", "corporation", "co", "co.", "company", "ltd", "ltd.", "limited", "plc", "n.v.", "nv", "s.a.", "sa", "ag", "se",
                                    "holdings", "holding", "group", "technologies", "technology", "class", "a", "b", "c", "(the)", "common", "stock", "ordinary", "shares", "adr"]
        while words.count > 1, let last = words.last, generic.contains(last.lowercased()) { words.removeLast() }
        return words.joined(separator:" ")
    }
    /// The Google News search: the company's name in quotes, its ticker too
    /// when it's three letters or more (V, ON or NOW alone would match anything),
    /// "stock", and the last `days` days.
    public static func query(ticker: String, name: String, days: Int) -> String {
        let short = shortName(name), symbol = ticker.uppercased()
        let useTicker = symbol.count >= 3 && symbol.allSatisfy(\.isLetter) && short.uppercased() != symbol
        let who = short.isEmpty || short.uppercased() == symbol ? symbol : useTicker ? "(\"\(short)\" OR \(symbol))" : "\"\(short)\""
        return "\(who) stock when:\(days)d"
    }
    /// Quote pages, filings and option quotes that news searches return as if
    /// they were stories.
    public static func isListing(_ title: String) -> Bool {
        let lower = title.lowercased()
        let phrases = ["stock price, news, quote", "stock price & news", "latest stock news", "stock news & headlines", "stock news and headlines",
                       "stock quote", "quote & history", "quote and history", "form 8k", "form 8-k", "form 10-q", "sec filing",
                       "sentiment score", "stock forecast & analyst predictions", "stock forecast and analyst predictions", "how to buy "]
        if phrases.contains(where:lower.contains) { return true }
        // An option contract: "CRWD Oct 2026 282.500 put" or "(CRWD261023P00282500)".
        return title.range(of:#"[A-Z]{1,6}\d{6}[CP]\d{8}"#, options:.regularExpression) != nil
            || lower.range(of:#"\d+\.\d{3} (put|call)\b"#, options:.regularExpression) != nil
    }
    /// A headline without a syndication tail: "… By Investing.com" → "…".
    public static func clean(_ title: String) -> String {
        guard let range = title.range(of:" By ", options:.backwards), title[range.upperBound...].count < 30, title[range.upperBound...].contains(".") else { return title }
        return String(title[..<range.lowerBound])
    }
    /// The same story syndicated under several names ("… By Investing.com")
    /// shares one key.
    public static func key(_ title: String) -> String {
        String(clean(title).lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).prefix(70))
    }
}
