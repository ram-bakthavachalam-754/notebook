import Foundation
import Darwin

public struct AgentWebDocument: Sendable {
    public var url: String
    public var contentType: String
    public var body: String
}
private final class AgentWebRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The transport follows redirects only after validating their destination.
        completionHandler(nil)
    }
}

/// Public, unauthenticated web reads. This session is separate from AI-provider
/// requests and never supplies provider keys, saved credentials, or cookies.
public final class AgentWebTransport: @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
        session = URLSession(configuration:config,delegate:AgentWebRedirectDelegate(),delegateQueue:nil)
    }
    deinit { session.invalidateAndCancel() }
    public static func publicAddress(_ address: String) -> Bool {
        let address = address.trimmingCharacters(in:CharacterSet(charactersIn:"[]"))
        var ipv4 = in_addr(), ipv6 = in6_addr()
        if inet_pton(AF_INET,address,&ipv4) == 1 {
            let bytes = withUnsafeBytes(of:&ipv4) { Array($0) }, a = Int(bytes[0]), b = Int(bytes[1]), c = Int(bytes[2])
            return !(a == 0 || a == 10 || a == 127 || a >= 224 || a == 169 && b == 254 || a == 172 && (16...31).contains(b) || a == 192 && (b == 168 || b == 0 || b == 88 && c == 99) || a == 100 && (64...127).contains(b) || a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) || a == 203 && b == 0 && c == 113)
        }
        if inet_pton(AF_INET6,address,&ipv6) == 1 {
            let bytes = withUnsafeBytes(of:&ipv6) { Array($0) }
            let first = Int(bytes[0]) * 256 + Int(bytes[1]), second = Int(bytes[2]) * 256 + Int(bytes[3])
            return (0x2000...0x3fff).contains(first) && first != 0x2002 && !(first == 0x2001 && (second == 0 || second == 0x0db8))
        }
        return false
    }
    public static func validateURL(_ address: String) throws -> URL {
        if address.range(of:"^https?://(?:[0-9]+\\.)*0[0-9]+(?:\\.|(?::[0-9]+)?(?:/|$))",options:[.regularExpression,.caseInsensitive]) != nil { throw NotebookError.message("Web browsing cannot access ambiguous numeric addresses.") }
        guard address.count <= 2048, !address.contains("\\"), address.rangeOfCharacter(from:.whitespacesAndNewlines) == nil,
              let parts = URLComponents(string:address), let scheme = parts.scheme?.lowercased(), ["http","https"].contains(scheme),
              parts.user == nil, parts.password == nil, let host = parts.host?.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:".")),
              let url = parts.url, parts.port == nil || parts.port == (scheme == "https" ? 443 : 80) else { throw NotebookError.message("Enter a public HTTP or HTTPS URL without credentials, using a standard port.") }
        if host.contains(":") || host.range(of:"^[0-9.]+$",options:.regularExpression) != nil {
            guard publicAddress(host) else { throw NotebookError.message("Web browsing cannot access private or reserved addresses.") }
        } else {
            let labels = host.split(separator:".",omittingEmptySubsequences:false).map(String.init)
            guard labels.count > 1, !["localhost","local","internal","lan","home","test","invalid","onion"].contains(labels.last!),
                  labels.allSatisfy({ $0.range(of:"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$",options:.regularExpression) != nil }),
                  host.range(of:"^0x[0-9a-f.]+$",options:.regularExpression) == nil else { throw NotebookError.message("Web browsing requires a public website.") }
        }
        return url
    }
    private static func validateDNS(_ host: String) throws {
        if publicAddress(host) { return }
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host,nil,&hints,&first) == 0, let first else { throw NotebookError.message("This website's address could not be resolved.") }
        defer { freeaddrinfo(first) }
        var row: UnsafeMutablePointer<addrinfo>? = first, count = 0
        while let current = row {
            var buffer = [CChar](repeating:0,count:Int(NI_MAXHOST))
            guard getnameinfo(current.pointee.ai_addr,current.pointee.ai_addrlen,&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST) == 0,
                  publicAddress(String(cString:buffer)) else { throw NotebookError.message("Web browsing cannot connect to private or reserved addresses.") }
            count += 1; row = current.pointee.ai_next
        }
        guard count > 0 else { throw NotebookError.message("This website has no public address.") }
    }
    /// `truncate` returns the first `maxBytes` of a longer page instead of
    /// failing, for callers that only need its head (a link's title).
    public func read(_ address: String, maxBytes: Int, duckDuckGo: Bool = false, truncate: Bool = false) async throws -> AgentWebDocument {
        guard (1...2 * 1024 * 1024).contains(maxBytes) else { throw NotebookError.message("Invalid web response size limit.") }
        var address = address
        for redirect in 0...5 {
            try Task.checkCancellation()
            let url = try Self.validateURL(address), host = URLComponents(url:url,resolvingAgainstBaseURL:false)!.host!
            if duckDuckGo && (host != "api.duckduckgo.com" || url.scheme != "https") { throw NotebookError.message("DuckDuckGo redirected outside its API.") }
            try await Task.detached(priority:.userInitiated) { try Self.validateDNS(host) }.value
            try Task.checkCancellation()
            var request = URLRequest(url:url); request.httpMethod = "GET"
            request.setValue("application/json, text/html, text/plain;q=0.9",forHTTPHeaderField:"Accept")
            request.setValue("Notebook/0.2 (Agent web reader)",forHTTPHeaderField:"User-Agent")
            let (bytes, response) = try await session.bytes(for:request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw NotebookError.message("This website returned an invalid response.") }
            if (300..<400).contains(response.statusCode) {
                guard redirect < 5, let location = response.value(forHTTPHeaderField:"Location"), let target = URL(string:location,relativeTo:url)?.absoluteURL else { throw NotebookError.message("This website redirected too many times.") }
                address = target.absoluteString; continue
            }
            guard response.statusCode == 200 else { throw NotebookError.message("Website returned HTTP \(response.statusCode).") }
            let contentType = response.value(forHTTPHeaderField:"Content-Type") ?? ""
            let readable = contentType.range(of:"^(?:text/(?:html|plain|markdown)|application/(?:json|xhtml\\+xml))\\b",options:[.regularExpression,.caseInsensitive]) != nil
            let apiJSON = duckDuckGo && contentType.range(of:"^application/(?:x-)?javascript\\b",options:[.regularExpression,.caseInsensitive]) != nil
            guard readable || apiJSON else { throw NotebookError.message("This URL is not an HTML or text page.") }
            guard truncate || response.expectedContentLength <= maxBytes else { throw NotebookError.message("This page is too large to read.") }
            var data = Data(); data.reserveCapacity(min(maxBytes,max(0,Int(response.expectedContentLength))))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maxBytes else { if truncate { break }; throw NotebookError.message("This page is too large to read.") }
                data.append(byte)
            }
            return AgentWebDocument(url:url.absoluteString,contentType:contentType,body:String(data:data,encoding:.utf8) ?? String(decoding:data,as:UTF8.self))
        }
        throw NotebookError.message("This website redirected too many times.")
    }
}
