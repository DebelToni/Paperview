import Foundation

enum BoardURLImports {
    private static let countryDomains: Set<String> = [
  "youtube.at", "youtube.be", "youtube.ca", "youtube.ch", "youtube.cl", "youtube.co.id",
  "youtube.co.il", "youtube.co.in", "youtube.co.jp", "youtube.co.ke", "youtube.co.kr",
  "youtube.co.ma", "youtube.co.nz", "youtube.co.th", "youtube.co.tz", "youtube.co.ug",
  "youtube.co.uk", "youtube.co.ve", "youtube.co.za", "youtube.com.ar", "youtube.com.au",
  "youtube.com.br", "youtube.com.co", "youtube.com.do", "youtube.com.ec", "youtube.com.eg",
  "youtube.com.es", "youtube.com.gh", "youtube.com.gr", "youtube.com.gt", "youtube.com.hk",
  "youtube.com.hr", "youtube.com.jm", "youtube.com.jo", "youtube.com.kw", "youtube.com.lb",
  "youtube.com.lv", "youtube.com.ly", "youtube.com.mt", "youtube.com.mx", "youtube.com.my",
  "youtube.com.ng", "youtube.com.ni", "youtube.com.om", "youtube.com.pa", "youtube.com.pe",
  "youtube.com.ph", "youtube.com.pk", "youtube.com.pr", "youtube.com.pt", "youtube.com.py",
  "youtube.com.qa", "youtube.com.ro", "youtube.com.sa", "youtube.com.sg", "youtube.com.sv",
  "youtube.com.tn", "youtube.com.tr", "youtube.com.tw", "youtube.com.ua", "youtube.com.uy",
  "youtube.cz", "youtube.de", "youtube.dk", "youtube.es", "youtube.fi", "youtube.fr",
  "youtube.gr", "youtube.hu", "youtube.ie", "youtube.in", "youtube.is", "youtube.it",
  "youtube.jp", "youtube.kr", "youtube.lk", "youtube.lt", "youtube.lu", "youtube.me",
  "youtube.mk", "youtube.nl", "youtube.no", "youtube.pl", "youtube.pt", "youtube.ro",
  "youtube.rs", "youtube.ru", "youtube.se", "youtube.si", "youtube.sk", "youtube.sn",
]

    static func isYouTube(_ raw: String) -> Bool { videoID(raw, depth: 0) != nil }

    private static func videoID(_ raw: String, depth: Int) -> String? {
        guard depth <= 2 else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, "<(\"'".contains(first) { text.removeFirst() }
        while let last = text.last, ">)\"'.,;!?".contains(last) { text.removeLast() }
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let scheme = text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil
        let candidate = scheme ? text : "https://" + text
        guard let components = URLComponents(string: candidate),
              let protocolName = components.scheme?.lowercased(), ["http", "https"].contains(protocolName),
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let short = host == "youtu.be" || host == "www.youtu.be"
        func hostIs(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        guard short || hostIs("youtube.com") || hostIs("youtube-nocookie.com") || countryDomains.contains(where: hostIs) else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/").map(String.init)
        let query = components.queryItems ?? []
        var id: String?
        if short && parts.count == 1 { id = parts[0] }
        else if !short && parts == ["watch"] { id = query.first(where: { $0.name == "v" })?.value }
        else if !short && parts.count == 2 && ["shorts", "live", "embed", "v", "e"].contains(parts[0]) { id = parts[1] }
        else if !short && parts == ["attribution_link"] {
            let target = query.first(where: { $0.name == "u" })?.value.flatMap { $0.isEmpty ? nil : $0 }
                ?? query.first(where: { $0.name == "q" })?.value
            guard let target, let base = components.url,
                  let resolved = URL(string: target, relativeTo: base)?.absoluteURL else { return nil }
            return videoID(resolved.absoluteString, depth: depth + 1)
        }
        guard let id, id.utf8.count == 11,
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return id
    }
}

struct BoardYouTubePreview: Decodable {
    let url: String
    let title: String
    let thumbnail: BoardAsset
}

extension SpaceAPI {
    func youtubePreview(url: String) async throws -> BoardYouTubePreview {
        guard BoardURLImports.isYouTube(url) else { throw PaperError.invalidResponse }
        let body = try JSONEncoder().encode(["url": url])
        let data = try await nativeRequest(target: origin.appendingPathComponent("api/youtube-preview"), method: "POST", body: body)
        let result = try JSONDecoder().decode(BoardYouTubePreview.self, from: data)
        let prefix = "data:image/jpeg;base64,"
        guard BoardURLImports.isYouTube(result.url), result.thumbnail.mimeType == "image/jpeg",
              result.thumbnail.dataURL.hasPrefix(prefix),
              let bytes = Data(base64Encoded: String(result.thumbnail.dataURL.dropFirst(prefix.count))), !bytes.isEmpty else { throw PaperError.invalidResponse }
        return result
    }
}
