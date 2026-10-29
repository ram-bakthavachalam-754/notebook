import Foundation
import Network
import CryptoKit
import NotebookCore

/// Robinhood's official Trading MCP server, read-only: quotes, option chains,
/// price history, earnings and news from your own Robinhood login. You sign
/// in once in the browser (OAuth with PKCE; Notebook never sees your
/// password); the tokens stay in this Mac's keychain. Order tools are never
/// called: only the tools in `readOnly` can be.
@MainActor final class RobinhoodLink: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published var error: String?
    /// Opens the sign-in page; the Mac app sets it to the default browser.
    var openURL: (URL) -> Void = { _ in }
    static let server = URL(string:"https://agent.robinhood.com/mcp/trading")!
    static let readOnly: Set<String> = ["get_accounts", "get_portfolio", "search", "get_equity_quotes", "get_equity_historicals", "get_equity_fundamentals",
                                        "get_equity_technical_indicators", "get_earnings_results", "get_earnings_calendar", "get_equity_news", "get_equity_analyst_ratings",
                                        "get_index_quotes", "get_option_chains", "get_option_instruments", "get_option_quotes", "get_option_historicals",
                                        "get_equity_positions", "get_option_positions", "get_scans", "get_scanner_filter_specs", "run_scan", "preview_scan", "get_scanner_datapoints",
                                        "get_popular_watchlists", "get_watchlist_items"]
    private struct Token: Codable { var clientID: String; var access: String; var refresh: String; var expires: Date }
    private static let keychain = ["provider":"robinhood", "baseURL":"oauth"]
    private var token: Token?
    private var sessionID: String?
    private var nextID = 1
    private let session = URLSession(configuration:.ephemeral)

    init() {
        token = (try? AgentKeychain.read(Self.keychain)).flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(Token.self, from:Data($0.utf8)) }
        connected = token != nil
    }

    // MARK: Signing in
    func connect() async {
        guard !connecting else { return }
        connecting = true; error = nil; defer { connecting = false }
        do {
            let receiver = try LoopbackReceiver()
            defer { receiver.stop() }
            let port = try await receiver.start()
            let redirect = "http://127.0.0.1:\(port)/callback"
            let registration = try await post(URL(string:"https://agent.robinhood.com/oauth/trading/register")!, json:["client_name":"Notebook", "redirect_uris":[redirect],
                "grant_types":["authorization_code", "refresh_token"], "response_types":["code"], "token_endpoint_auth_method":"none"])
            guard let clientID = registration["client_id"] as? String else { throw NotebookError.message("Robinhood didn't register Notebook.") }
            let verifier = Self.randomString(), state = Self.randomString()
            let challenge = Data(SHA256.hash(data:Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of:"+", with:"-").replacingOccurrences(of:"/", with:"_").replacingOccurrences(of:"=", with:"")
            var authorize = URLComponents(string:"https://robinhood.com/oauth")!
            authorize.queryItems = [.init(name:"response_type", value:"code"), .init(name:"client_id", value:clientID), .init(name:"redirect_uri", value:redirect),
                                    .init(name:"code_challenge", value:challenge), .init(name:"code_challenge_method", value:"S256"), .init(name:"state", value:state),
                                    .init(name:"scope", value:"internal"), .init(name:"resource", value:Self.server.absoluteString)]
            openURL(authorize.url!)
            let reply = try await receiver.receive()
            guard reply["state"] == state else { throw NotebookError.message("The sign-in reply didn't match. Try again.") }
            guard let code = reply["code"] else { throw NotebookError.message(reply["error_description"] ?? reply["error"].map { "Robinhood said: \($0)" } ?? "Sign-in was cancelled.") }
            let granted = try await post(URL(string:"https://api.robinhood.com/oauth2/token/")!, form:["grant_type":"authorization_code", "code":code, "redirect_uri":redirect,
                                                                                                      "client_id":clientID, "code_verifier":verifier, "resource":Self.server.absoluteString])
            try store(granted, clientID:clientID)
            sessionID = nil
            connected = true
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() {
        try? AgentKeychain.remove(Self.keychain)
        token = nil; sessionID = nil; connected = false
    }
    private func store(_ granted: [String:Any], clientID: String) throws {
        guard let access = granted["access_token"] as? String else { throw NotebookError.message((granted["error_description"] ?? granted["error"]) as? String ?? "Robinhood didn't grant access.") }
        let refresh = granted["refresh_token"] as? String ?? token?.refresh ?? ""
        let token = Token(clientID:clientID, access:access, refresh:refresh, expires:Date().addingTimeInterval((granted["expires_in"] as? NSNumber)?.doubleValue ?? 3600))
        try AgentKeychain.save(String(decoding:try JSONEncoder().encode(token), as:UTF8.self), config:Self.keychain)
        self.token = token
    }
    /// A fresh access token, refreshing it when it's about to expire.
    private func accessToken(force: Bool = false) async throws -> String {
        guard let token else { throw NotebookError.message("Connect Robinhood in Settings → Trading.") }
        if !force, token.expires.timeIntervalSinceNow > 60 { return token.access }
        guard !token.refresh.isEmpty, let granted = try? await post(URL(string:"https://api.robinhood.com/oauth2/token/")!, form:["grant_type":"refresh_token", "refresh_token":token.refresh,
                                                                                                                                  "client_id":token.clientID, "resource":Self.server.absoluteString]),
              (try? store(granted, clientID:token.clientID)) != nil, let access = self.token?.access else {
            disconnect(); error = "Robinhood signed Notebook out. Connect again in Settings → Trading."
            throw NotebookError.message(error!)
        }
        return access
    }

    // MARK: MCP
    /// Calls one read-only tool and returns its result: the structured
    /// content, or the text parsed as JSON, or the text.
    func call(_ tool: String, _ arguments: [String:Any] = [:]) async throws -> Any {
        guard Self.readOnly.contains(tool) else { throw NotebookError.message("Notebook only reads from Robinhood.") }
        let result = try await request("tools/call", ["name":tool, "arguments":arguments])
        let text = (result["content"] as? [[String:Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator:"\n")
        if result["isError"] as? Bool == true { throw NotebookError.message("Robinhood: " + (text.isEmpty ? "the request failed." : String(text.prefix(300)))) }
        if let structured = result["structuredContent"] { return structured }
        return (try? jsonObject(text)) ?? text
    }
    func tools() async throws -> [[String:Any]] { try await request("tools/list", [:])["tools"] as? [[String:Any]] ?? [] }
    private func request(_ method: String, _ params: [String:Any], retried: Bool = false) async throws -> [String:Any] {
        if sessionID == nil, method != "initialize" { try await initialize() }
        do { return try await send(method, params) }
        catch RobinhoodError.unauthorized where !retried { _ = try await accessToken(force:true); return try await request(method, params, retried:true) }
        catch RobinhoodError.sessionExpired where !retried { sessionID = nil; return try await request(method, params, retried:true) }
    }
    private enum RobinhoodError: Error { case unauthorized, sessionExpired }
    private func initialize() async throws {
        _ = try await send("initialize", ["protocolVersion":"2025-06-18", "capabilities":[String:Any](), "clientInfo":["name":"Notebook", "version":"1"]])
        _ = try? await send("notifications/initialized", nil)
    }
    private func send(_ method: String, _ params: [String:Any]?) async throws -> [String:Any] {
        var body: [String:Any] = ["jsonrpc":"2.0", "method":method]
        let id = nextID; if params != nil { body["id"] = id; body["params"] = params!; nextID += 1 }
        var request = URLRequest(url:Self.server); request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField:"Content-Type"); request.setValue("application/json, text/event-stream", forHTTPHeaderField:"Accept")
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField:"Authorization")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField:"Mcp-Session-Id"); request.setValue("2025-06-18", forHTTPHeaderField:"MCP-Protocol-Version") }
        request.httpBody = try jsonData(body)
        let (data, response) = try await session.data(for:request)
        let http = response as? HTTPURLResponse, code = http?.statusCode ?? 0
        if code == 401 { throw RobinhoodError.unauthorized }
        if code == 404, sessionID != nil { throw RobinhoodError.sessionExpired }
        guard (200..<300).contains(code) else { throw NotebookError.message(code == 429 ? "Robinhood is limiting requests. Try again in a minute." : "Robinhood returned HTTP \(code).") }
        if method == "initialize", let session = http?.value(forHTTPHeaderField:"Mcp-Session-Id") { sessionID = session }
        guard params != nil else { return [:] }
        // A plain JSON reply, or a stream of events with the reply among them.
        let text = String(decoding:data, as:UTF8.self)
        let messages: [[String:Any]] = (http?.value(forHTTPHeaderField:"Content-Type") ?? "").contains("text/event-stream")
            ? text.split(separator:"\n").filter { $0.hasPrefix("data:") }.compactMap { try? jsonObject(String($0.dropFirst(5)).trimmingCharacters(in:.whitespaces)) as? [String:Any] }
            : [(try? jsonObject(text)) as? [String:Any] ?? [:]]
        guard let reply = messages.first(where: { ($0["id"] as? NSNumber)?.intValue == id }) else { throw NotebookError.message("Robinhood sent no answer.") }
        if let failure = reply["error"] as? [String:Any] { throw NotebookError.message("Robinhood: " + (failure["message"] as? String ?? "request failed.")) }
        return reply["result"] as? [String:Any] ?? [:]
    }

    // MARK: Data
    // Argument names and answer shapes are Robinhood's (see Copy Diagnostics).
    // Answers are read by field name wherever they're nested, so an added
    // wrapper doesn't break them; anything not answered falls back to Yahoo.
    /// A stock's regular-session quote. Extended-hours trades are ignored.
    struct StockQuote {
        var price: Double, bid: Double, ask: Double, previousClose: Double
        /// The day of the last regular trade, and the day `previousClose` closed (New York dates).
        var tradeDay: String, previousCloseDay: String
        /// The move since the session before the last trade. Once a session
        /// closes Robinhood's previous close becomes that day's close, so the
        /// caller's own earlier previous close for the same day is used instead.
        func dayChange(known: (day: String, close: Double)?) -> Double? {
            if previousCloseDay < tradeDay, previousClose > 0 { return price - previousClose }
            if let known, known.day == tradeDay { return price - known.close }
            return nil
        }
    }
    /// Real-time stock quotes in bulk: one call for up to 100 symbols. (Above
    /// 20 Robinhood leaves out the official closes, which aren't used here.)
    func stockQuotes(_ symbols: [String]) async -> [String:StockQuote] {
        guard connected, !symbols.isEmpty else { return [:] }
        var out: [String:StockQuote] = [:]
        for chunk in Self.chunks(symbols, 100) {
            guard let result = try? await call("get_equity_quotes", ["symbols":chunk]) else { continue }
            for row in Self.objects(result) {
                guard let q = row["quote"] as? [String:Any], let symbol = (q["symbol"] as? String)?.uppercased(), q["has_traded"] as? Bool != false,
                      (q["state"] as? String ?? "active") == "active", let price = Self.number(q, ["last_trade_price"]), price > 0 else { continue }
                let traded = (q["venue_last_trade_time"] as? String).flatMap { ISO8601DateFormatter().date(from:$0) ?? Self.fractional.date(from:$0) }
                out[symbol] = StockQuote(price:price, bid:Self.number(q, ["bid_price"]) ?? 0, ask:Self.number(q, ["ask_price"]) ?? 0,
                                         previousClose:Self.number(q, ["adjusted_previous_close", "previous_close"]) ?? 0,
                                         tradeDay:traded.map(TradingModel.day.string) ?? TradingModel.day.string(from:Date()), previousCloseDay:q["previous_close_date"] as? String ?? "")
            }
        }
        return out
    }
    /// About 13 months of daily candles, 10 symbols a call.
    func candles(_ symbols: [String]) async -> [String:[Candle]] {
        guard connected, !symbols.isEmpty else { return [:] }
        let start = ISO8601DateFormatter().string(from:Date().addingTimeInterval(-400 * 86400))
        var out: [String:[Candle]] = [:]
        for chunk in Self.chunks(symbols, 10) {
            guard let result = try? await call("get_equity_historicals", ["symbols":chunk, "start_time":start, "interval":"day", "bounds":"regular", "adjustment_type":"split"]) else { continue }
            for row in Self.objects(result) {
                guard let symbol = (row["symbol"] as? String)?.uppercased(), chunk.contains(symbol) else { continue }
                // The bars are the list in this entry whose items have prices.
                for case let bars as [[String:Any]] in row.values {
                    let candles = bars.compactMap(Self.candle).sorted { $0.date < $1.date }
                    if candles.count > out[symbol]?.count ?? 0 { out[symbol] = candles }
                }
            }
        }
        return out
    }
    private static func candle(_ bar: [String:Any]) -> Candle? {
        guard let close = number(bar, ["close_price", "close", "c"]), close > 0,
              let stamp = (bar["begins_at"] ?? bar["timestamp"] ?? bar["time"] ?? bar["date"] ?? bar["t"]) as? String,
              let date = ISO8601DateFormatter().date(from:stamp) ?? fractional.date(from:stamp) ?? TradingModel.day.date(from:String(stamp.prefix(10))) else { return nil }
        return Candle(date:date, open:number(bar, ["open_price", "open", "o"]) ?? close, high:number(bar, ["high_price", "high", "h"]) ?? close,
                      low:number(bar, ["low_price", "low", "l"]) ?? close, close:close, volume:number(bar, ["volume", "v"]) ?? 0)
    }
    private static let fractional: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    /// One expiration's calls and puts, three to ten weeks out (after earnings
    /// when possible), within 25% of the price, with live quotes.
    func optionChain(_ ticker: String, price: Double, after earnings: Date?) async -> (calls: [YahooFinance.OptionContract], puts: [YahooFinance.OptionContract])? {
        guard connected, price > 0, let chains = try? await call("get_option_chains", ["underlying_symbol":ticker]) else { return nil }
        let dates = Self.objects(chains).flatMap { $0["expiration_dates"] as? [String] ?? [] }.compactMap { TradingModel.day.date(from:$0) }
        let window = Set(dates).sorted().filter { $0.timeIntervalSinceNow > 21 * 86400 && $0.timeIntervalSinceNow < 70 * 86400 }
        guard let pick = window.first(where: { earnings == nil || $0 > earnings! }) ?? window.first else { return nil }
        let expiration = TradingModel.day.string(from:pick)
        // Every active contract for that date, page by page.
        var instruments: [[String:Any]] = [], cursor: String?
        for _ in 0..<10 {
            var arguments: [String:Any] = ["chain_symbol":ticker, "expiration_dates":expiration, "state":"active"]
            if let cursor { arguments["cursor"] = cursor }
            guard let page = try? await call("get_option_instruments", arguments) else { break }
            instruments += Self.objects(page).filter { $0["strike_price"] != nil && $0["id"] is String && ($0["expiration_date"] as? String ?? expiration) == expiration }
            cursor = Self.objects(page).compactMap { ($0["next_cursor"] ?? $0["next"] ?? $0["cursor"]) as? String }.first { !$0.isEmpty }
            if cursor == nil { break }
        }
        let near = instruments.filter { abs((Self.number($0, ["strike_price"]) ?? 0) / price - 1) <= 0.25 }
        let quotes = await optionQuotes(near.compactMap { $0["id"] as? String })
        var calls: [YahooFinance.OptionContract] = [], puts: [YahooFinance.OptionContract] = []
        for instrument in near {
            guard let id = instrument["id"] as? String, let strike = Self.number(instrument, ["strike_price"]), let type = instrument["type"] as? String, let q = quotes[id] else { continue }
            let contract = YahooFinance.OptionContract(symbol:Self.occ(ticker, pick, type, strike), type:type, strike:strike, expiration:pick, bid:q.bid, ask:q.ask, last:q.last,
                                                       openInterest:q.openInterest, iv:q.iv, robinhoodID:id, delta:q.delta)
            if type == "call" { calls.append(contract) } else if type == "put" { puts.append(contract) }
        }
        return calls.isEmpty && puts.isEmpty ? nil : (calls.sorted { $0.strike < $1.strike }, puts.sorted { $0.strike < $1.strike })
    }
    /// The market scan: four screens of US stocks worth $2 billion or more and
    /// priced at $5 or more, run live with Robinhood's scanner (nothing is
    /// saved to your account). Changes are regular-session. The scanner lists
    /// rows by price, so each screen is ranked here and its strongest kept.
    struct Row { var ticker: String, change: Double, volume: Double, rsi: Double? }
    func movers(perScreen: Int = 10) async -> [(ticker: String, reason: String)] {
        guard connected else { return [] }
        let change = #"changeFromPrevDayRatio(session="regular")"#
        let volume = #"dayVolume / volumeAvg(candleCount=30, candlePeriod="1d", session="regular")"#
        let base: [[String:Any]] = [["filter_type":"FILTER_TYPE_INSTRUMENT_TYPE", "predicate":"=", "values":["STOCK"]],
                                    ["filter_type":"FILTER_TYPE_MARKET_CAP", "predicate":">=", "values":["2000000000"]],
                                    ["filter_type":"FILTER_TYPE_LAST", "predicate":">=", "values":["5"]]]
        func filter(_ expression: String, _ predicate: String, _ value: String) -> [String:Any] { ["expression":expression, "predicate":predicate, "values":[value]] }
        // Each screen: its filters, the column it's ranked by (largest first) and how a row is described.
        let screens: [(name: String, filters: [[String:Any]], rank: (Row) -> Double)] = [
            ("up on heavy volume", [filter(change, ">=", "0.04"), filter(volume, ">=", "1.5")], { $0.change }),
            ("down on heavy volume", [filter(change, "<=", "-0.04"), filter(volume, ">=", "1.5")], { -$0.change }),
            ("unusual volume", [filter(volume, ">=", "3")], { $0.volume }),
            ("oversold in an uptrend", [["filter_type":"FILTER_TYPE_RSI", "predicate":"<", "values":["35"], "interval":"1d", "length":14],
                                        filter(#"tradeAllDay.price > closeAvg(candleCount=200, candlePeriod="1d", session="regular")"#, "=", "True")], { -($0.rsi ?? 50) })
        ]
        let results = await withTaskGroup(of:(Int, [Row]).self) { group in
            for (index, screen) in screens.enumerated() {
                group.addTask { @MainActor [self] in
                    guard let answer = try? await call("preview_scan", ["filters":base + screen.filters, "columns":[["display_name":"Change", "expression":change], ["display_name":"Relative volume", "expression":volume]]]) else { return (index, []) }
                    let rows = Self.objects(answer).compactMap { row -> Row? in
                        guard let ticker = row["ticker"] as? String, let columns = row["columns"] as? [String:Any] else { return nil }
                        return Row(ticker:ticker.uppercased(), change:Self.number(columns, ["Change", change, "% Change"]) ?? 0,
                                   volume:Self.number(columns, ["Relative volume", volume]) ?? 0, rsi:columns.first { $0.key.hasPrefix("RSI") }.flatMap { Self.number(columns, [$0.key]) })
                    }
                    return (index, rows)
                }
            }
            var out: [Int:[Row]] = [:]; for await (index, rows) in group { out[index] = rows }; return out
        }
        var found: [(ticker: String, reason: String)] = [], seen = Set<String>()
        for (index, screen) in screens.enumerated() {
            let rows = (results[index] ?? []).sorted { screen.rank($0) > screen.rank($1) }.prefix(perScreen)
            for row in rows where seen.insert(row.ticker).inserted {
                found.append((row.ticker, "Robinhood scan, \(screen.name): " + String(format:"%+.1f%% today, %.1f× normal volume", row.change * 100, row.volume) + (row.rsi.map { String(format:", RSI %.0f", $0) } ?? "")))
            }
        }
        return found
    }
    struct OptionQuote { var bid: Double, ask: Double, last: Double, openInterest: Double, iv: Double, delta: Double? }
    /// Live option quotes by Robinhood instrument id, in bulk: up to 100 a call.
    func optionQuotes(_ ids: [String]) async -> [String:OptionQuote] {
        guard connected, !ids.isEmpty else { return [:] }
        var out: [String:OptionQuote] = [:]
        for chunk in Self.chunks(ids, 100) {
            guard let result = try? await call("get_option_quotes", ["instrument_ids":chunk]) else { continue }
            for row in Self.objects(result) {
                let instrument = (row["instrument_id"] as? String) ?? (row["instrument"] as? String).flatMap { url in chunk.first { url.contains($0) } } ?? (row["id"] as? String)
                guard let id = instrument, chunk.contains(id), let bid = Self.number(row, ["bid_price", "bid"]), let ask = Self.number(row, ["ask_price", "ask"]) else { continue }
                out[id] = OptionQuote(bid:bid, ask:ask, last:Self.number(row, ["mark_price", "adjusted_mark_price", "last_trade_price"]) ?? (bid + ask) / 2,
                                      openInterest:Self.number(row, ["open_interest"]) ?? 0, iv:Self.number(row, ["implied_volatility"]) ?? 0, delta:Self.number(row, ["delta"]))
            }
        }
        return out
    }
    private var optionIDCache = UserDefaults.standard.dictionary(forKey:"notebook-robinhood-option-ids") as? [String:String] ?? [:]
    /// Robinhood's instrument ids for contract symbols (AAPL261120C00250000),
    /// one lookup per underlying, expiration and type, remembered on this Mac.
    func optionIDs(_ symbols: [String]) async -> [String:String] {
        guard connected else { return [:] }
        var out: [String:String] = [:], missing: [String:[(symbol: String, strike: Double)]] = [:]
        for symbol in symbols {
            if let id = optionIDCache[symbol] { out[symbol] = id; continue }
            guard let match = symbol.wholeMatch(of:/([A-Z.]{1,6})(\d{2})(\d{2})(\d{2})([CP])(\d{8})/), let strike = Double(match.6) else { continue }
            let key = "\(match.1)|20\(match.2)-\(match.3)-\(match.4)|\(match.5 == "P" ? "put" : "call")"
            missing[key, default:[]].append((symbol, strike / 1000))
        }
        for (key, wanted) in missing {
            let parts = key.split(separator:"|").map(String.init)
            guard let page = try? await call("get_option_instruments", ["chain_symbol":parts[0], "expiration_dates":parts[1], "type":parts[2], "state":"active"]) else { continue }
            for instrument in Self.objects(page) {
                guard let id = instrument["id"] as? String, let strike = Self.number(instrument, ["strike_price"]),
                      let symbol = wanted.first(where: { abs($0.strike - strike) < 0.0005 })?.symbol else { continue }
                out[symbol] = id; optionIDCache[symbol] = id
            }
        }
        UserDefaults.standard.set(optionIDCache, forKey:"notebook-robinhood-option-ids")
        return out
    }
    /// The standard contract symbol (AAPL261120C00250000), the same one Yahoo uses.
    static func occ(_ ticker: String, _ expiration: Date, _ type: String, _ strike: Double) -> String {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TradingModel.newYork
        let d = calendar.dateComponents([.year, .month, .day], from:expiration)
        return ticker.replacingOccurrences(of:".", with:"") + String(format:"%02d%02d%02d", (d.year ?? 0) % 100, d.month ?? 0, d.day ?? 0) + (type == "put" ? "P" : "C") + String(format:"%08d", Int((strike * 1000).rounded()))
    }
    private static func chunks(_ items: [String], _ size: Int) -> [[String]] { stride(from:0, to:items.count, by:size).map { Array(items[$0..<min($0 + size, items.count)]) } }
    /// Every dictionary inside an answer, however it's nested.
    private static func objects(_ value: Any) -> [[String:Any]] {
        if let dictionary = value as? [String:Any] { return [dictionary] + dictionary.values.flatMap(objects) }
        if let array = value as? [Any] { return array.flatMap(objects) }
        return []
    }
    /// The first of these keys holding a number (Robinhood sends prices as strings).
    private static func number(_ row: [String:Any], _ keys: [String]) -> Double? {
        for key in keys {
            if let n = row[key] as? NSNumber { return n.doubleValue }
            if let s = row[key] as? String, let d = Double(s) { return d }
        }
        return nil
    }
    /// Sample answers from each tool Trading reads, and what Notebook made of them.
    func diagnostics() async -> String {
        var out: [String:Any] = [:]
        func sample(_ tool: String, _ arguments: [String:Any], as key: String? = nil, limit: Int = 3000) async -> Any? {
            do { let answer = try await call(tool, arguments); out[key ?? tool] = String(((try? jsonString(answer)) ?? "\(answer)").prefix(limit)); return answer }
            catch { out[key ?? tool] = "error: " + error.localizedDescription; return nil }
        }
        _ = await sample("get_equity_historicals", ["symbols":["AAPL"], "start_time":ISO8601DateFormatter().string(from:Date().addingTimeInterval(-10 * 86400)), "interval":"day"])
        if let chains = await sample("get_option_chains", ["underlying_symbol":"AAPL"]),
           let date = Self.objects(chains).flatMap({ $0["expiration_dates"] as? [String] ?? [] }).sorted().first(where: { $0 > TradingModel.day.string(from:Date().addingTimeInterval(20 * 86400)) }),
           let instruments = await sample("get_option_instruments", ["chain_symbol":"AAPL", "expiration_dates":date, "type":"call", "state":"active"]) {
            let ids = Self.objects(instruments).compactMap { $0["strike_price"] != nil ? $0["id"] as? String : nil }.prefix(2)
            _ = await sample("get_option_quotes", ["instrument_ids":Array(ids)])
        }
        let stocks = await stockQuotes(["AAPL"]), bars = await candles(["AAPL"])
        var reads: [String:Any] = ["AAPL price":stocks["AAPL"]?.price ?? 0, "AAPL daily candles":bars["AAPL"]?.count ?? 0, "last candle close":bars["AAPL"]?.last?.close ?? 0]
        if let chain = await optionChain("AAPL", price:stocks["AAPL"]?.price ?? 0, after:nil) {
            reads["AAPL calls"] = chain.calls.count; reads["AAPL puts"] = chain.puts.count
            reads["sample call"] = chain.calls.first.map { "\($0.symbol) bid \($0.bid) ask \($0.ask) oi \($0.openInterest) iv \($0.iv)" } ?? ""
        }
        let found = await movers()
        reads["scan"] = found.map { "\($0.ticker): \($0.reason)" }
        out["notebook reads"] = reads
        return (try? String(decoding:JSONSerialization.data(withJSONObject:out, options:[.prettyPrinted, .sortedKeys]), as:UTF8.self)) ?? ""
    }

    // MARK: HTTP
    private func post(_ url: URL, json: [String:Any]? = nil, form: [String:String]? = nil) async throws -> [String:Any] {
        var request = URLRequest(url:url); request.httpMethod = "POST"; request.timeoutInterval = 30
        if let json { request.setValue("application/json", forHTTPHeaderField:"Content-Type"); request.httpBody = try jsonData(json) }
        if let form {
            var components = URLComponents(); components.queryItems = form.map { URLQueryItem(name:$0.key, value:$0.value) }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField:"Content-Type")
            request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of:"+", with:"%2B").utf8)
        }
        let (data, response) = try await session.data(for:request)
        let object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) < 300 else {
            throw NotebookError.message((object["error_description"] ?? object["error"]) as? String ?? "Robinhood returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return object
    }
    private static func randomString() -> String {
        var bytes = [UInt8](repeating:0, count:32); _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of:"+", with:"-").replacingOccurrences(of:"/", with:"_").replacingOccurrences(of:"=", with:"")
    }
}

/// Waits on 127.0.0.1 for the browser to come back from signing in, and
/// returns the query of that one request (code and state, or an error).
private final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label:"notebook.robinhood.signin")
    private var waiting: CheckedContinuation<[String:String], Error>?
    private var early: [String:String]?
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback), port:.any)
        listener = try NWListener(using:parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; ready.resume(returning:listener.port?.rawValue ?? 0)
                case .failed(let error): resumed = true; ready.resume(throwing:error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue:queue)
        }
    }
    /// The sign-in reply, or an error after 15 minutes.
    func receive() async throws -> [String:String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let early = self.early { continuation.resume(returning:early); return }
                self.waiting = continuation
                self.queue.asyncAfter(deadline:.now() + 900) { self.finish(.failure(NotebookError.message("Sign-in timed out. Try again."))) }
            }
        }
    }
    func stop() { listener.cancel() }
    private func finish(_ result: Result<[String:String], Error>) {
        guard let waiting else { if case .success(let value) = result { early = value }; return }
        self.waiting = nil
        waiting.resume(with:result)
    }
    private func handle(_ connection: NWConnection) {
        connection.start(queue:queue)
        connection.receive(minimumIncompleteLength:1, maximumLength:16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let head = String(decoding:data ?? Data(), as:UTF8.self).split(separator:"\r\n").first.map(String.init) ?? ""
            let target = head.split(separator:" ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string:"http://127.0.0.1" + target)
            let matched = components?.path == "/callback"
            let page = matched ? "<h2 style='font-family:-apple-system'>Robinhood is connected.</h2><p style='font-family:-apple-system'>You can close this tab and go back to Notebook.</p>" : "Not found"
            let response = "HTTP/1.1 \(matched ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
            connection.send(content:Data(response.utf8), completion:.contentProcessed { _ in connection.cancel() })
            if matched {
                var query: [String:String] = [:]
                for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
                self.finish(.success(query))
            }
        }
    }
}
