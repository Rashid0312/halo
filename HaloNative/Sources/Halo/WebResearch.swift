import Foundation

enum WebResearchError: LocalizedError {
    case invalidRequest, blockedAddress, badResponse, unsupportedContent, emptyResult
    var errorDescription: String? {
        switch self {
        case .invalidRequest: "The web request was invalid."
        case .blockedAddress: "Local and private network addresses cannot be read."
        case .badResponse: "The website did not return a usable response."
        case .unsupportedContent: "That page is not readable HTML or plain text."
        case .emptyResult: "No readable search results were returned."
        }
    }
}

struct WebSearchResult: Codable, Equatable {
    let title: String
    let url: String
    let snippet: String
}

final class PublicWebDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap(WebResearch.publicURL) == nil ? nil : request)
    }
}

enum WebResearch {
    static let maximumDownload = 2 * 1024 * 1024
    static let maximumText = 24_000

    static func search(_ query: String) async throws -> [WebSearchResult] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 500,
              var parts = URLComponents(string: "https://www.bing.com/search") else { throw WebResearchError.invalidRequest }
        parts.queryItems = [URLQueryItem(name: "q", value: clean), URLQueryItem(name: "format", value: "rss")]
        guard let url = parts.url else { throw WebResearchError.invalidRequest }
        let data = try await fetch(url, accepted: ["application/rss+xml", "application/xml", "text/xml", "text/plain"])
        let results = RSSParser.parse(data).prefix(8)
        guard !results.isEmpty else { throw WebResearchError.emptyResult }
        return Array(results)
    }

    static func read(_ rawURL: String) async throws -> (url: String, title: String, text: String) {
        guard let url = publicURL(rawURL) else { throw WebResearchError.blockedAddress }
        let data = try await fetch(url, accepted: ["text/html", "text/plain", "application/xhtml+xml"])
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw WebResearchError.unsupportedContent
        }
        let title = firstMatch(#"(?is)<title[^>]*>(.*?)</title>"#, in: html).map(cleanText) ?? url.host ?? "Web page"
        let stripped = html
            .replacingOccurrences(of: #"(?is)<(script|style|svg|noscript|nav|footer|form)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</li>|</h[1-6]>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
        let text = String(cleanText(stripped).prefix(maximumText))
        guard text.count >= 80 else { throw WebResearchError.emptyResult }
        return (url.absoluteString, title, text)
    }

    static func publicURL(_ raw: String) -> URL? { URL(string: raw).flatMap(publicURL) }

    static func publicURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              host != "localhost", !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              !host.contains(":"), host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil else { return nil }
        return url
    }

    private static func fetch(_ url: URL, accepted: [String]) async throws -> Data {
        guard publicURL(url) != nil else { throw WebResearchError.blockedAddress }
        var request = URLRequest(url: url, timeoutInterval: 7)
        request.setValue("Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15 Halo/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(accepted.joined(separator: ", "), forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 9
        configuration.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: configuration, delegate: PublicWebDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = http.url, publicURL(finalURL) != nil else { throw WebResearchError.badResponse }
        let mime = (http.mimeType ?? "").lowercased()
        guard accepted.contains(where: { mime == $0 || ($0 == "text/html" && mime == "application/xhtml+xml") }) else {
            throw WebResearchError.unsupportedContent
        }
        var data = Data()
        data.reserveCapacity(min(Int(http.expectedContentLength), maximumDownload))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumDownload else { throw WebResearchError.badResponse }
            data.append(byte)
        }
        return data
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func cleanText(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: #"&#(\d+);"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t\r]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class RSSParser: NSObject, XMLParserDelegate {
    private var results: [WebSearchResult] = []
    private var field = ""
    private var title = ""
    private var link = ""
    private var descriptionText = ""
    private var inItem = false

    static func parse(_ data: Data) -> [WebSearchResult] {
        let delegate = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        field = elementName.lowercased()
        if field == "item" { inItem = true; title = ""; link = ""; descriptionText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        switch field { case "title": title += string; case "link": link += string; case "description": descriptionText += string; default: break }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "item" {
            inItem = false
            if WebResearch.publicURL(link.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
                results.append(WebSearchResult(title: WebResearch.cleanText(title), url: link.trimmingCharacters(in: .whitespacesAndNewlines), snippet: WebResearch.cleanText(descriptionText)))
            }
        }
        field = ""
    }
}
