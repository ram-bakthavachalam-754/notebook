import Foundation
import CoreGraphics

/// The industry standard Explore groups stocks by (GICS): 11 sectors (two-digit
/// codes), 74 industries (six digits) and 163 sub-industries (eight digits). A
/// code's prefixes are its parents: 45301020 Semiconductors is in 453010
/// Semiconductors & Semiconductor Equipment, in 45 Information Technology.
public enum GICS {
    public static let names: [String:String] = Dictionary(uniqueKeysWithValues:table)
    public static func name(_ code: String) -> String { names[code] ?? (code.isEmpty ? "Unclassified" : code) }
    public static func sector(_ code: String) -> String { String(code.prefix(2)) }
    public static func industry(_ code: String) -> String { String(code.prefix(6)) }
    /// Every sub-industry, in code order.
    public static let subIndustries: [String] = table.map(\.0).filter { $0.count == 8 }
    private static let byName: [String:String] = Dictionary(subIndustries.map { (key(names[$0]!), $0) }, uniquingKeysWith:{ a, _ in a })
    /// The sub-industry with this name ("Application Software"), ignoring case,
    /// punctuation and "and" against "&".
    public static func code(forSubIndustry name: String) -> String? { byName[key(name)] }
    private static func key(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of:" and ", with:" & ").filter { $0.isLetter }
    }
    static let table: [(String, String)] = [
        ("10", "Energy"),
        ("101010", "Energy Equipment & Services"),
        ("10101010", "Oil & Gas Drilling"),
        ("10101020", "Oil & Gas Equipment & Services"),
        ("101020", "Oil, Gas & Consumable Fuels"),
        ("10102010", "Integrated Oil & Gas"),
        ("10102020", "Oil & Gas Exploration & Production"),
        ("10102030", "Oil & Gas Refining & Marketing"),
        ("10102040", "Oil & Gas Storage & Transportation"),
        ("10102050", "Coal & Consumable Fuels"),
        ("15", "Materials"),
        ("151010", "Chemicals"),
        ("15101010", "Commodity Chemicals"),
        ("15101020", "Diversified Chemicals"),
        ("15101030", "Fertilizers & Agricultural Chemicals"),
        ("15101040", "Industrial Gases"),
        ("15101050", "Specialty Chemicals"),
        ("151020", "Construction Materials"),
        ("15102010", "Construction Materials"),
        ("151030", "Containers & Packaging"),
        ("15103010", "Metal, Glass & Plastic Containers"),
        ("15103020", "Paper & Plastic Packaging Products & Materials"),
        ("151040", "Metals & Mining"),
        ("15104010", "Aluminum"),
        ("15104020", "Diversified Metals & Mining"),
        ("15104025", "Copper"),
        ("15104030", "Gold"),
        ("15104040", "Precious Metals & Minerals"),
        ("15104045", "Silver"),
        ("15104050", "Steel"),
        ("151050", "Paper & Forest Products"),
        ("15105010", "Forest Products"),
        ("15105020", "Paper Products"),
        ("20", "Industrials"),
        ("201010", "Aerospace & Defense"),
        ("20101010", "Aerospace & Defense"),
        ("201020", "Building Products"),
        ("20102010", "Building Products"),
        ("201030", "Construction & Engineering"),
        ("20103010", "Construction & Engineering"),
        ("201040", "Electrical Equipment"),
        ("20104010", "Electrical Components & Equipment"),
        ("20104020", "Heavy Electrical Equipment"),
        ("201050", "Industrial Conglomerates"),
        ("20105010", "Industrial Conglomerates"),
        ("201060", "Machinery"),
        ("20106010", "Construction Machinery & Heavy Transportation Equipment"),
        ("20106015", "Agricultural & Farm Machinery"),
        ("20106020", "Industrial Machinery & Supplies & Components"),
        ("201070", "Trading Companies & Distributors"),
        ("20107010", "Trading Companies & Distributors"),
        ("202010", "Commercial Services & Supplies"),
        ("20201010", "Commercial Printing"),
        ("20201050", "Environmental & Facilities Services"),
        ("20201060", "Office Services & Supplies"),
        ("20201070", "Diversified Support Services"),
        ("20201080", "Security & Alarm Services"),
        ("202020", "Professional Services"),
        ("20202010", "Human Resource & Employment Services"),
        ("20202020", "Research & Consulting Services"),
        ("20202030", "Data Processing & Outsourced Services"),
        ("203010", "Air Freight & Logistics"),
        ("20301010", "Air Freight & Logistics"),
        ("203020", "Passenger Airlines"),
        ("20302010", "Passenger Airlines"),
        ("203030", "Marine Transportation"),
        ("20303010", "Marine Transportation"),
        ("203040", "Ground Transportation"),
        ("20304010", "Rail Transportation"),
        ("20304030", "Cargo Ground Transportation"),
        ("20304040", "Passenger Ground Transportation"),
        ("203050", "Transportation Infrastructure"),
        ("20305010", "Airport Services"),
        ("20305020", "Highways & Railtracks"),
        ("20305030", "Marine Ports & Services"),
        ("25", "Consumer Discretionary"),
        ("251010", "Automobile Components"),
        ("25101010", "Automotive Parts & Equipment"),
        ("25101020", "Tires & Rubber"),
        ("251020", "Automobiles"),
        ("25102010", "Automobile Manufacturers"),
        ("25102020", "Motorcycle Manufacturers"),
        ("252010", "Household Durables"),
        ("25201010", "Consumer Electronics"),
        ("25201020", "Home Furnishings"),
        ("25201030", "Homebuilding"),
        ("25201040", "Household Appliances"),
        ("25201050", "Housewares & Specialties"),
        ("252020", "Leisure Products"),
        ("25202010", "Leisure Products"),
        ("252030", "Textiles, Apparel & Luxury Goods"),
        ("25203010", "Apparel, Accessories & Luxury Goods"),
        ("25203020", "Footwear"),
        ("25203030", "Textiles"),
        ("253010", "Hotels, Restaurants & Leisure"),
        ("25301010", "Casinos & Gaming"),
        ("25301020", "Hotels, Resorts & Cruise Lines"),
        ("25301030", "Leisure Facilities"),
        ("25301040", "Restaurants"),
        ("253020", "Diversified Consumer Services"),
        ("25302010", "Education Services"),
        ("25302020", "Specialized Consumer Services"),
        ("255010", "Distributors"),
        ("25501010", "Distributors"),
        ("255030", "Broadline Retail"),
        ("25503030", "Broadline Retail"),
        ("255040", "Specialty Retail"),
        ("25504010", "Apparel Retail"),
        ("25504020", "Computer & Electronics Retail"),
        ("25504030", "Home Improvement Retail"),
        ("25504040", "Other Specialty Retail"),
        ("25504050", "Automotive Retail"),
        ("25504060", "Homefurnishing Retail"),
        ("30", "Consumer Staples"),
        ("301010", "Consumer Staples Distribution & Retail"),
        ("30101010", "Drug Retail"),
        ("30101020", "Food Distributors"),
        ("30101030", "Food Retail"),
        ("30101040", "Consumer Staples Merchandise Retail"),
        ("302010", "Beverages"),
        ("30201010", "Brewers"),
        ("30201020", "Distillers & Vintners"),
        ("30201030", "Soft Drinks & Non-alcoholic Beverages"),
        ("302020", "Food Products"),
        ("30202010", "Agricultural Products & Services"),
        ("30202030", "Packaged Foods & Meats"),
        ("302030", "Tobacco"),
        ("30203010", "Tobacco"),
        ("303010", "Household Products"),
        ("30301010", "Household Products"),
        ("303020", "Personal Care Products"),
        ("30302010", "Personal Care Products"),
        ("35", "Health Care"),
        ("351010", "Health Care Equipment & Supplies"),
        ("35101010", "Health Care Equipment"),
        ("35101020", "Health Care Supplies"),
        ("351020", "Health Care Providers & Services"),
        ("35102010", "Health Care Distributors"),
        ("35102015", "Health Care Services"),
        ("35102020", "Health Care Facilities"),
        ("35102030", "Managed Health Care"),
        ("351030", "Health Care Technology"),
        ("35103010", "Health Care Technology"),
        ("352010", "Biotechnology"),
        ("35201010", "Biotechnology"),
        ("352020", "Pharmaceuticals"),
        ("35202010", "Pharmaceuticals"),
        ("352030", "Life Sciences Tools & Services"),
        ("35203010", "Life Sciences Tools & Services"),
        ("40", "Financials"),
        ("401010", "Banks"),
        ("40101010", "Diversified Banks"),
        ("40101015", "Regional Banks"),
        ("402010", "Financial Services"),
        ("40201020", "Diversified Financial Services"),
        ("40201030", "Multi-Sector Holdings"),
        ("40201040", "Specialized Finance"),
        ("40201050", "Commercial & Residential Mortgage Finance"),
        ("40201060", "Transaction & Payment Processing Services"),
        ("402020", "Consumer Finance"),
        ("40202010", "Consumer Finance"),
        ("402030", "Capital Markets"),
        ("40203010", "Asset Management & Custody Banks"),
        ("40203020", "Investment Banking & Brokerage"),
        ("40203030", "Diversified Capital Markets"),
        ("40203040", "Financial Exchanges & Data"),
        ("402040", "Mortgage Real Estate Investment Trusts (REITs)"),
        ("40204010", "Mortgage REITs"),
        ("403010", "Insurance"),
        ("40301010", "Insurance Brokers"),
        ("40301020", "Life & Health Insurance"),
        ("40301030", "Multi-line Insurance"),
        ("40301040", "Property & Casualty Insurance"),
        ("40301050", "Reinsurance"),
        ("45", "Information Technology"),
        ("451020", "IT Services"),
        ("45102010", "IT Consulting & Other Services"),
        ("45102030", "Internet Services & Infrastructure"),
        ("451030", "Software"),
        ("45103010", "Application Software"),
        ("45103020", "Systems Software"),
        ("452010", "Communications Equipment"),
        ("45201020", "Communications Equipment"),
        ("452020", "Technology Hardware, Storage & Peripherals"),
        ("45202030", "Technology Hardware, Storage & Peripherals"),
        ("452030", "Electronic Equipment, Instruments & Components"),
        ("45203010", "Electronic Equipment & Instruments"),
        ("45203015", "Electronic Components"),
        ("45203020", "Electronic Manufacturing Services"),
        ("45203030", "Technology Distributors"),
        ("453010", "Semiconductors & Semiconductor Equipment"),
        ("45301010", "Semiconductor Materials & Equipment"),
        ("45301020", "Semiconductors"),
        ("50", "Communication Services"),
        ("501010", "Diversified Telecommunication Services"),
        ("50101010", "Alternative Carriers"),
        ("50101020", "Integrated Telecommunication Services"),
        ("501020", "Wireless Telecommunication Services"),
        ("50102010", "Wireless Telecommunication Services"),
        ("502010", "Media"),
        ("50201010", "Advertising"),
        ("50201020", "Broadcasting"),
        ("50201030", "Cable & Satellite"),
        ("50201040", "Publishing"),
        ("502020", "Entertainment"),
        ("50202010", "Movies & Entertainment"),
        ("50202020", "Interactive Home Entertainment"),
        ("502030", "Interactive Media & Services"),
        ("50203010", "Interactive Media & Services"),
        ("55", "Utilities"),
        ("551010", "Electric Utilities"),
        ("55101010", "Electric Utilities"),
        ("551020", "Gas Utilities"),
        ("55102010", "Gas Utilities"),
        ("551030", "Multi-Utilities"),
        ("55103010", "Multi-Utilities"),
        ("551040", "Water Utilities"),
        ("55104010", "Water Utilities"),
        ("551050", "Independent Power and Renewable Electricity Producers"),
        ("55105010", "Independent Power Producers & Energy Traders"),
        ("55105020", "Renewable Electricity"),
        ("60", "Real Estate"),
        ("601010", "Diversified REITs"),
        ("60101010", "Diversified REITs"),
        ("601025", "Industrial REITs"),
        ("60102510", "Industrial REITs"),
        ("601030", "Hotel & Resort REITs"),
        ("60103010", "Hotel & Resort REITs"),
        ("601040", "Office REITs"),
        ("60104010", "Office REITs"),
        ("601050", "Health Care REITs"),
        ("60105010", "Health Care REITs"),
        ("601060", "Residential REITs"),
        ("60106010", "Multi-Family Residential REITs"),
        ("60106020", "Single-Family Residential REITs"),
        ("601070", "Retail REITs"),
        ("60107010", "Retail REITs"),
        ("601080", "Specialized REITs"),
        ("60108010", "Other Specialized REITs"),
        ("60108020", "Self-Storage REITs"),
        ("60108030", "Telecom Tower REITs"),
        ("60108040", "Timber REITs"),
        ("60108050", "Data Center REITs"),
        ("602010", "Real Estate Management & Development"),
        ("60201010", "Diversified Real Estate Activities"),
        ("60201020", "Real Estate Operating Companies"),
        ("60201030", "Real Estate Development"),
        ("60201040", "Real Estate Services"),    ]
}

/// One company in a list, as the list's source names it.
public struct ExploreMember: Equatable, Sendable {
    public var symbol: String
    public var name: String
    /// The sub-industry the source gives (S&P 500 only), else empty.
    public var code: String
    public init(symbol: String, name: String, code: String = "") { self.symbol = symbol; self.name = name; self.code = code }
}

/// Reading each list's source. No network here: the app fetches the pages and
/// hands them over, so every format is tested with saved copies.
public enum ExploreSources {
    /// Wikipedia's "List of S&P 500 companies", as wikitext: the table with
    /// id="constituents", one row per company with its sector and sub-industry.
    public static func sp500(wikitext: String) -> [ExploreMember] {
        guard let start = wikitext.range(of:"id=\"constituents\"") else { return [] }
        var table = String(wikitext[start.upperBound...])
        if let end = table.range(of:"\n|}") { table = String(table[..<end.lowerBound]) }
        var out: [ExploreMember] = []
        for row in table.components(separatedBy:"\n|-").dropFirst() {
            // Cells start a line with "|" or "||", or follow "||" on one line.
            let cells = row.replacingOccurrences(of:#"\n\|(?!\|)"#, with:"||", options:.regularExpression)
                .components(separatedBy:"||").map(clean).filter { !$0.isEmpty }
            guard cells.count >= 4, let symbol = ticker(cells[0]), let code = GICS.code(forSubIndustry:cells[3]) else { continue }
            out.append(ExploreMember(symbol:symbol, name:cells[1], code:code))
        }
        return out
    }
    /// Nasdaq's list of Nasdaq-100 members (api.nasdaq.com, list-type/nasdaq100).
    public static func nasdaq100(json: Data) -> [ExploreMember] {
        guard let root = try? JSONSerialization.jsonObject(with:json) as? [String:Any],
              let rows = (((root["data"] as? [String:Any])?["data"] as? [String:Any])?["rows"]) as? [[String:Any]] else { return [] }
        return rows.compactMap { row in
            guard let symbol = (row["symbol"] as? String).flatMap(ticker) else { return nil }
            return ExploreMember(symbol:symbol, name:companyName(row["companyName"] as? String ?? symbol))
        }
    }
    /// An index's members from Nasdaq's index site (Index/WeightingData). Foreign
    /// listings come with their home tickers (Trend Micro is "4704"); those that
    /// aren't US tickers are dropped here, and the rest are checked against US
    /// quotes by name, since a foreign ticker can match a different US company.
    public static func nasdaqIndex(json: Data) -> [ExploreMember] {
        guard let root = try? JSONSerialization.jsonObject(with:json) as? [String:Any], let rows = root["aaData"] as? [[String:Any]] else { return [] }
        return rows.compactMap { row in
            guard let symbol = (row["Symbol"] as? String).flatMap(ticker) else { return nil }
            return ExploreMember(symbol:symbol, name:row["Name"] as? String ?? symbol)
        }
    }
    /// Amplify ETFs' daily holdings file, which holds every Amplify fund: the
    /// rows for one fund, without cash and money-market lines.
    public static func amplify(csv: String, fund: String) -> [ExploreMember] {
        let lines = csv.components(separatedBy:.newlines)
        guard let header = lines.first?.components(separatedBy:","), let account = header.firstIndex(of:"Account"),
              let symbolColumn = header.firstIndex(of:"StockTicker"), let nameColumn = header.firstIndex(of:"SecurityName") else { return [] }
        let money = header.firstIndex(of:"MoneyMarketFlag")
        return lines.dropFirst().compactMap { line in
            let cells = csvCells(line)
            guard cells.count > max(account, symbolColumn, nameColumn), cells[account] == fund,
                  money.map({ $0 >= cells.count || cells[$0] != "Y" }) ?? true,
                  let symbol = ticker(cells[symbolColumn]) else { return nil }
            return ExploreMember(symbol:symbol, name:cells[nameColumn])
        }
    }
    /// An ETF's holdings page on stockanalysis.com: the stock links in its
    /// holdings table, in order. It shows the top 25, enough for FANG+'s 10.
    public static func stockAnalysis(html: String) -> [ExploreMember] {
        guard let regex = try? NSRegularExpression(pattern:#"href="/stocks/([a-z0-9.\-]+)/""#) else { return [] }
        var seen = Set<String>(), out: [ExploreMember] = []
        for match in regex.matches(in:html, range:NSRange(html.startIndex..., in:html)) {
            guard let range = Range(match.range(at:1), in:html), let symbol = ticker(html[range].uppercased()), seen.insert(symbol).inserted else { continue }
            out.append(ExploreMember(symbol:symbol, name:symbol))
        }
        return out
    }
    /// True when two names for one ticker are plausibly the same company: their
    /// first three letters agree ("ADV MICRO DEVICES" and "Advanced Micro
    /// Devices", but not "Atos" and "Atmos Energy"), or one starts with the
    /// other's initials ("IBM" and "INTL BUSINESS MACH").
    public static func sameCompany(_ a: String, _ b: String) -> Bool {
        func start(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter }.prefix(3)) }
        func initials(_ s: String) -> String { String(s.lowercased().split { !$0.isLetter }.compactMap(\.first)) }
        guard start(a).count == 3 || start(b).count == 3 else { return false }
        return start(a) == start(b) || (start(b).count == 3 && initials(a).hasPrefix(start(b))) || (start(a).count == 3 && initials(b).hasPrefix(start(a)))
    }
    /// A model's answer to "which sub-industry is each of these in?": the first
    /// JSON object in the reply, kept only for the tickers asked about and only
    /// where the code is a real sub-industry.
    public static func placements(reply: String, asked: [String]) -> [String:String] {
        guard let start = reply.firstIndex(of:"{"), let end = reply.lastIndex(of:"}"), start < end,
              let answer = try? JSONSerialization.jsonObject(with:Data(reply[start...end].utf8)) as? [String:Any] else { return [:] }
        var out: [String:String] = [:]
        for symbol in asked {
            guard let code = (answer[symbol] as? String) ?? (answer[symbol] as? NSNumber)?.stringValue, code.count == 8, GICS.names[code] != nil else { continue }
            out[symbol] = code
        }
        return out
    }
    /// "Shopify Inc. Class A Subordinate Voting Shares" → "Shopify Inc".
    public static func companyName(_ name: String) -> String {
        var text = name.trimmingCharacters(in:.whitespaces)
        for marker in [" Common Stock", " Class A", " Class B", " Class C", " Series A", " American Depositary", " Ordinary Shares", " Ordinary Share", " Common Shares", " New York Registry"] {
            if let range = text.range(of:marker) { text = String(text[..<range.lowerBound]) }
        }
        return text.trimmingCharacters(in:CharacterSet(charactersIn:" ,."))
    }
    /// A US ticker as quotes use it ("BRK.B"), or nil for anything else
    /// ("4704 JP", "Cash&Other").
    static func ticker(_ raw: String) -> String? {
        let text = raw.replacingOccurrences(of:#"\{\{[^|}]*\|([^}]*)\}\}"#, with:"$1", options:.regularExpression)
            .replacingOccurrences(of:#"<!--.*?-->"#, with:"", options:.regularExpression).trimmingCharacters(in:.whitespaces).uppercased()
        return text.range(of:#"^[A-Z]{1,5}(\.[A-Z])?$"#, options:.regularExpression) != nil ? text : nil
    }
    /// Wikitext to plain text: links show their label, templates their last
    /// part, and footnotes and comments go.
    static func clean(_ cell: String) -> String {
        var text = cell
        text = text.replacingOccurrences(of:#"<!--[\s\S]*?-->"#, with:"", options:.regularExpression)
        text = text.replacingOccurrences(of:#"<ref[^>]*/>|<ref[\s\S]*?</ref>"#, with:"", options:.regularExpression)
        text = text.replacingOccurrences(of:#"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]"#, with:"$1", options:.regularExpression)
        text = text.replacingOccurrences(of:#"\{\{[^{}]*\|([^{}|]*)\}\}"#, with:"$1", options:.regularExpression)
        return text.replacingOccurrences(of:#"\s+"#, with:" ", options:.regularExpression).trimmingCharacters(in:.whitespaces)
    }
    /// One CSV line's cells, honoring quoted cells with commas in them.
    static func csvCells(_ line: String) -> [String] {
        var cells: [String] = [], cell = "", quoted = false
        for c in line {
            if c == "\"" { quoted.toggle() } else if c == ",", !quoted { cells.append(cell); cell = "" } else { cell.append(c) }
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in:.whitespaces) }
    }
}

/// Price changes over Explore's periods, from a year of daily closes.
public enum ExplorePeriods {
    public static let all = ["1D", "1W", "1M", "3M", "YTD", "1Y"]
    /// Trading days back for each fixed period.
    static let days = ["1W":5, "1M":21, "3M":63]
    /// The close each period is measured from: 1W, 1M and 3M of trading days
    /// before the latest close, the last close of last year (YTD) and the first
    /// close (1Y). `closes` are oldest first; a period the history doesn't reach
    /// is left out. Kept for the day, so live prices give live changes.
    public static func references(closes: [(date: Date, close: Double)], calendar: Calendar = .current, now: Date = Date()) -> [String:Double] {
        guard closes.count > 1 else { return [:] }
        var out: [String:Double] = [:]
        for (period, back) in days where closes.count > back { out[period] = closes[closes.count - 1 - back].close }
        let year = calendar.component(.year, from:now)
        if let last = closes.last(where: { calendar.component(.year, from:$0.date) < year }) { out["YTD"] = last.close }
        if let first = closes.first, now.timeIntervalSince(first.date) > 300 * 86400 { out["1Y"] = first.close }
        return out.filter { $0.value > 0 }
    }
    /// Percent change from a reference close to `price`.
    public static func change(from reference: Double?, to price: Double) -> Double? {
        guard let reference, reference > 0, price > 0 else { return nil }
        return (price / reference - 1) * 100
    }
    /// Percent changes to `price` over each period the closes reach.
    public static func changes(closes: [(date: Date, close: Double)], price: Double, calendar: Calendar = .current, now: Date = Date()) -> [String:Double] {
        references(closes:closes, calendar:calendar, now:now).compactMapValues { change(from:$0, to:price) }
    }
    /// The market-cap-weighted average change of a group; stocks without a cap
    /// or a change don't count.
    public static func weighted(_ items: [(change: Double?, cap: Double)]) -> Double? {
        var total = 0.0, weight = 0.0
        for item in items { if let change = item.change, item.cap > 0 { total += change * item.cap; weight += item.cap } }
        return weight > 0 ? total / weight : nil
    }
}

/// Squarified treemap layout: rectangles with areas in proportion to the
/// values, as close to square as it can make them (Bruls, Huizing and van Wijk).
public enum Treemap {
    /// One rectangle per value, in the order given. Zero or negative values get
    /// an empty rectangle.
    public static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var out = Array(repeating:CGRect.zero, count:values.count)
        let total = values.reduce(0) { $0 + max($1, 0) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        var items = values.indices.filter { values[$0] > 0 }.map { (index:$0, area:values[$0] * scale) }.sorted { $0.area > $1.area }[...]
        var free = rect, row: [(index: Int, area: Double)] = []
        func worst(_ row: [(index: Int, area: Double)], _ side: Double) -> Double {
            let sum = row.reduce(0) { $0 + $1.area }, big = row.map(\.area).max() ?? 0, small = row.map(\.area).min() ?? 0
            guard sum > 0, small > 0, side > 0 else { return .infinity }
            return max(side * side * big / (sum * sum), sum * sum / (side * side * small))
        }
        func place(_ row: [(index: Int, area: Double)]) {
            let sum = row.reduce(0) { $0 + $1.area }
            if free.width >= free.height {
                let width = sum / Double(free.height); var y = Double(free.minY)
                for item in row { let h = item.area / width; out[item.index] = CGRect(x:Double(free.minX), y:y, width:width, height:h); y += h }
                free = CGRect(x:free.minX + width, y:free.minY, width:max(0, free.width - width), height:free.height)
            } else {
                let height = sum / Double(free.width); var x = Double(free.minX)
                for item in row { let w = item.area / height; out[item.index] = CGRect(x:x, y:Double(free.minY), width:w, height:height); x += w }
                free = CGRect(x:free.minX, y:free.minY + height, width:free.width, height:max(0, free.height - height))
            }
        }
        while let next = items.first {
            let side = Double(min(free.width, free.height))
            if row.isEmpty || worst(row + [next], side) <= worst(row, side) { row.append(next); items = items.dropFirst() }
            else { place(row); row = [] }
        }
        if !row.isEmpty { place(row) }
        return out
    }
}
