// Router — owner: Module B (PLAN.md §6.2).
//
// Decides where a navigation goes: stay (`allow`), the player view, the browse view, or Safari.
// Every case in TestVectors/routing.json is checked against this file (RoutingTests) and against
// router.js's classifier, which mirrors `classify`/`decide` for in-page taps. Keep the two in
// step: a rule added here needs the same rule in router.js's CONFIG and a vector.
//
// The decision depends on the role and the link kind only; `trigger` is carried for logging and
// for the caller (a `history` route also needs the view to go back).

import Foundation

public enum Router {
    // ── Tables (PLAN.md §6.2; router.js CONFIG mirrors these) ─────────────────────────────────

    /// Hosts that normalize to m.youtube.com (`youtu.be` additionally rewrites to /watch).
    static let youtubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"]
    static let shortLinkHost = "youtu.be"
    static let canonicalHost = "m.youtube.com"
    /// Google sign-in and consent: always allowed in place. Provisional until spike S-B1.
    static let signInHosts: Set<String> = ["accounts.google.com", "accounts.youtube.com", "consent.youtube.com"]
    /// Schemes that never leave the view (WebViewStore blanks the player with about:blank;
    /// YouTube uses javascript: hrefs on buttons; blob:/data: are page-internal).
    static let inPlaceSchemes: Set<String> = ["about", "javascript", "blob", "data"]
    static let webSchemes: Set<String> = ["http", "https"]
    static let redirectPath = "/redirect"
    /// Caps that keep `t` and `index` well inside Int and identical to router.js.
    static let maxComponentDigits = 7

    // ── API ───────────────────────────────────────────────────────────────────────────────────

    /// www./music./bare youtube.com → m.youtube.com, http → https, youtu.be/ID?q → /watch?v=ID&q.
    /// Path, query and fragment are kept byte for byte. Other URLs come back unchanged.
    public static func normalize(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), webSchemes.contains(scheme),
              let host = url.host?.lowercased(), youtubeHosts.contains(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }

        components.scheme = "https"
        components.host = canonicalHost
        components.port = nil
        components.user = nil
        components.password = nil
        if host == shortLinkHost {
            let id = components.percentEncodedPath.split(separator: "/").first.map(String.init)
            if let id {
                let rest = components.percentEncodedQuery ?? ""
                components.percentEncodedPath = "/watch"
                components.percentEncodedQuery = "v=" + id + (rest.isEmpty ? "" : "&" + rest)
            }
        }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        return components.url ?? url
    }

    public static func classify(_ url: URL) -> LinkKind {
        guard let scheme = url.scheme?.lowercased() else { return .ignore }
        if inPlaceSchemes.contains(scheme) { return .ignore }
        guard webSchemes.contains(scheme) else { return .external(url) }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .ignore }
        if signInHosts.contains(host) { return .signIn(url) }
        guard youtubeHosts.contains(host) else { return .external(url) }

        let normalized = normalize(url)
        guard let components = URLComponents(url: normalized, resolvingAgainstBaseURL: false) else {
            return .youtubePage(normalized)
        }
        let path = components.percentEncodedPath
        let query = parseQuery(components.percentEncodedQuery)

        if path == redirectPath {
            if let target = first("q", in: query), let targetURL = URL(string: target),
               let targetScheme = targetURL.scheme?.lowercased(), webSchemes.contains(targetScheme) {
                return .external(targetURL)
            }
            return .external(url)
        }
        if let request = videoRequest(path: path, query: query) {
            return .video(request)
        }
        return .youtubePage(normalized)
    }

    public static func decide(_ url: URL, role: WebRole, trigger: NavigationTrigger) -> RouteDecision {
        switch classify(url) {
        case .ignore, .signIn:
            return .allow
        case .external(let target):
            return .openExternally(target)
        case .video(let request):
            return role == .browse ? .openInPlayer(request) : .allow
        case .youtubePage(let page):
            return role == .browse ? .allow : .openInBrowse(page)
        }
    }

    // ── Video links ───────────────────────────────────────────────────────────────────────────

    /// `path` and `query` are from an already-normalized m.youtube.com URL.
    static func videoRequest(path: String, query: [(String, String)]) -> VideoRequest? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // "/watch" → ["", "watch"]; "/shorts/ID" → ["", "shorts", "ID"]; "/shorts/ID/" → [..., ""]
        if path == "/watch" {
            guard let id = first("v", in: query), isVideoID(id) else { return nil }
            return request(id: id, kind: .video, query: query)
        }
        guard segments.count >= 3, segments[0].isEmpty, isVideoID(segments[2]),
              segments.count == 3 || (segments.count == 4 && segments[3].isEmpty)
        else { return nil }
        switch segments[1] {
        case "shorts":
            let id = segments[2]
            return VideoRequest(id: id, kind: .short, watchURL: URL(string: "https://\(canonicalHost)/shorts/\(id)")!)
        case "live":
            return request(id: segments[2], kind: .live, query: query)
        default:
            return nil
        }
    }

    /// A `video` or `live` request with the canonical watch URL (PLAN.md §6.2).
    static func request(id: String, kind: VideoRequest.Kind, query: [(String, String)]) -> VideoRequest {
        let start = first("t", in: query).flatMap(parseStartSeconds)
        let list = first("list", in: query).flatMap { isPlaylistID($0) ? $0 : nil }
        let index = first("index", in: query).flatMap(parseIndex)
        var text = "https://\(canonicalHost)/watch?v=\(id)"
        if let start { text += "&t=\(start)s" }
        if let list { text += "&list=\(list)" }
        if let index { text += "&index=\(index)" }
        return VideoRequest(id: id, kind: kind, startSeconds: start, playlistID: list, playlistIndex: index,
                            watchURL: URL(string: text)!)
    }

    static func isVideoID(_ text: String) -> Bool {
        text.utf8.count == 11 && text.utf8.allSatisfy(isIDByte)
    }

    static func isPlaylistID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy(isIDByte)
    }

    static func isIDByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
            return true
        default:
            return false
        }
    }

    /// `90`, `90s`, `1m30s`, `1h2m3s`, `2h`, `5m` → seconds. Units in h, m, s order, each at most
    /// once; anything else is nil.
    static func parseStartSeconds(_ text: String) -> Int? {
        if let plain = digits(Substring(text)) { return plain }
        var total = 0
        var sawComponent = false
        var allowed: [Character] = ["h", "m", "s"]
        var number = ""
        for character in text {
            if character.isASCII, character.isNumber {
                number.append(character)
                continue
            }
            guard let unitIndex = allowed.firstIndex(of: character), let value = digits(Substring(number)) else {
                return nil
            }
            let multiplier = character == "h" ? 3600 : character == "m" ? 60 : 1
            total += value * multiplier
            allowed.removeFirst(unitIndex + 1)
            number = ""
            sawComponent = true
        }
        return sawComponent && number.isEmpty ? total : nil
    }

    static func parseIndex(_ text: String) -> Int? {
        digits(Substring(text))
    }

    /// 1–7 ASCII digits as an Int.
    static func digits(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= maxComponentDigits, text.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return Int(text)
    }

    // ── Query parsing (mirrors URLSearchParams) ──────────────────────────────────────────────

    /// `a=1&b=x+y&c` → [("a","1"), ("b","x y"), ("c","")]. `+` is a space and invalid percent
    /// escapes are kept as-is, as URLSearchParams does.
    static func parseQuery(_ percentEncodedQuery: String?) -> [(String, String)] {
        guard let query = percentEncodedQuery, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decodeComponent(parts[0])
            let value = parts.count > 1 ? decodeComponent(parts[1]) : ""
            return (name, value)
        }
    }

    static func decodeComponent(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    static func first(_ name: String, in query: [(String, String)]) -> String? {
        query.first { $0.0 == name }?.1
    }
}
