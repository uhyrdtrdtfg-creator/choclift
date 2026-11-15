import Foundation

public enum MeetingJoinLink {
    public static let maxURLLength = 500

    /// Pure conference URL detector across calendar event fields (`url`, `location`, `notes`).
    /// Prefers the first recognized provider (`Zoom`, `Meet`, `Teams`, `Webex`, `FaceTime`, `Tuple`)
    /// over a generic `https` link containing `"meet"`, `"join"`, or `"call"` (`Link`).
    /// Rejects `http`, `file`, `javascript`, and empty strings, and caps extracted URL length at 500.
    public static func detect(in texts: [String]) -> (provider: String, url: URL)? {
        var firstGeneric: (provider: String, url: URL)?

        for rawText in texts {
            for url in extractHTTPSURLs(from: rawText) {
                guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      components.scheme?.lowercased() == "https",
                      let host = components.host?.lowercased(),
                      !host.isEmpty else {
                    continue
                }

                if let match = classifyProvider(host: host, fullURL: url.absoluteString) {
                    if match.isKnown {
                        return (provider: match.provider, url: url)
                    }
                    if firstGeneric == nil {
                        firstGeneric = (provider: match.provider, url: url)
                    }
                }
            }
        }

        return firstGeneric
    }

    private static func extractHTTPSURLs(from rawText: String) -> [URL] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let loweredWhole = trimmed.lowercased()
        if hasForbiddenSchemePrefix(loweredWhole) {
            return []
        }

        var results: [URL] = []
        var searchStart = trimmed.startIndex

        while searchStart < trimmed.endIndex,
              let match = trimmed.range(
                  of: "https://",
                  options: [.caseInsensitive],
                  range: searchStart..<trimmed.endIndex
              ) {
            let endIndex = scanURLEnd(in: trimmed, from: match.lowerBound)
            defer { searchStart = endIndex }

            if isPrecededByForbiddenTokenPrefix(in: trimmed, matchStart: match.lowerBound) {
                continue
            }

            var candidate = String(trimmed[match.lowerBound..<endIndex])
            candidate = stripTrailingPunctuation(from: candidate)

            if candidate.count > maxURLLength {
                candidate = String(candidate.prefix(maxURLLength))
                candidate = stripIncompletePercentEscape(from: candidate)
                candidate = stripTrailingPunctuation(from: candidate)
            }

            guard candidate.count > "https://".count,
                  candidate.count <= maxURLLength,
                  let components = URLComponents(string: candidate),
                  components.scheme?.lowercased() == "https",
                  let host = components.host?.lowercased(),
                  !host.isEmpty,
                  host.contains("."),
                  let url = components.url,
                  url.absoluteString.count <= maxURLLength else {
                continue
            }

            results.append(url)
        }

        return results
    }

    private static func hasForbiddenSchemePrefix(_ lowered: String) -> Bool {
        lowered.hasPrefix("javascript:")
            || lowered.hasPrefix("file:")
            || lowered.hasPrefix("data:")
            || lowered.hasPrefix("vbscript:")
    }

    private static func isPrecededByForbiddenTokenPrefix(
        in text: String,
        matchStart: String.Index
    ) -> Bool {
        guard matchStart > text.startIndex else { return false }
        var cursor = matchStart
        while cursor > text.startIndex {
            let prev = text.index(before: cursor)
            let ch = text[prev]
            if ch.isWhitespace || ch.isNewline {
                break
            }
            cursor = prev
        }
        let tokenPrefix = text[cursor..<matchStart].lowercased()
        if tokenPrefix.contains("javascript:")
            || tokenPrefix.contains("file:")
            || tokenPrefix.contains("data:")
            || tokenPrefix.contains("vbscript:")
            || tokenPrefix.hasSuffix("http://") {
            return true
        }
        // Reject tokens like `xhttps://zoom.us` where ASCII letters immediately precede `https://`.
        if let prevChar = text[..<matchStart].last,
           prevChar.isLetter || prevChar.isNumber {
            return true
        }
        return false
    }

    private static func scanURLEnd(in text: String, from start: String.Index) -> String.Index {
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if ch.isWhitespace || ch.isNewline {
                break
            }
            if ch == "<" || ch == ">" || ch == "\"" || ch == "'" || ch == "`" {
                break
            }
            if ch.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                break
            }
            idx = text.index(after: idx)
        }
        return idx
    }

    private static func stripTrailingPunctuation(from raw: String) -> String {
        var value = raw
        while let last = value.last {
            if last == "." || last == "," || last == ";" || last == ":" || last == "!" {
                value.removeLast()
                continue
            }
            if last == ")" {
                let opens = value.filter { $0 == "(" }.count
                let closes = value.filter { $0 == ")" }.count
                if closes > opens {
                    value.removeLast()
                    continue
                }
            }
            if last == "]" {
                let opens = value.filter { $0 == "[" }.count
                let closes = value.filter { $0 == "]" }.count
                if closes > opens {
                    value.removeLast()
                    continue
                }
            }
            if last == "}" {
                let opens = value.filter { $0 == "{" }.count
                let closes = value.filter { $0 == "}" }.count
                if closes > opens {
                    value.removeLast()
                    continue
                }
            }
            break
        }
        return value
    }

    private static func stripIncompletePercentEscape(from value: String) -> String {
        if value.hasSuffix("%") {
            return String(value.dropLast())
        }
        if value.count >= 2 {
            let penultimateIndex = value.index(value.endIndex, offsetBy: -2)
            if value[penultimateIndex] == "%" {
                return String(value.dropLast(2))
            }
        }
        return value
    }

    private static func classifyProvider(
        host: String,
        fullURL: String
    ) -> (provider: String, isKnown: Bool)? {
        if hostMatches(host, domain: "zoom.us") || hostMatches(host, domain: "zoom.com") {
            return ("Zoom", true)
        }
        if hostMatches(host, domain: "meet.google.com") {
            return ("Meet", true)
        }
        if hostMatches(host, domain: "teams.microsoft.com") || hostMatches(host, domain: "teams.live.com") {
            return ("Teams", true)
        }
        if hostMatches(host, domain: "webex.com") {
            return ("Webex", true)
        }
        if hostMatches(host, domain: "facetime.apple.com") {
            return ("FaceTime", true)
        }
        if hostMatches(host, domain: "tuple.app") {
            return ("Tuple", true)
        }

        let lowered = fullURL.lowercased()
        if lowered.contains("meet") || lowered.contains("join") || lowered.contains("call") {
            return ("Link", false)
        }
        return nil
    }

    private static func hostMatches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}

public struct MeetingJoinEventKey: Equatable, Hashable, Sendable {
    public let startDate: Date
    public let title: String

    public init(startDate: Date, title: String) {
        self.startDate = startDate
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? "Untitled Event" : String(trimmed.prefix(120))
    }

    public init(event: NextCalendarEventSummary) {
        self.init(startDate: event.startDate, title: event.title)
    }
}

public struct MeetingJoinLinkCache: Equatable, Sendable {
    private var entries: [MeetingJoinEventKey: URL] = [:]

    public init() {}

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    public mutating func store(_ url: URL, startDate: Date, title: String) {
        guard url.scheme?.lowercased() == "https" else { return }
        let key = MeetingJoinEventKey(startDate: startDate, title: title)
        if entries[key] == nil {
            entries[key] = url
        }
    }

    public func url(for event: NextCalendarEventSummary?) -> URL? {
        guard let event, event.hasJoinLink else { return nil }
        return entries[MeetingJoinEventKey(event: event)]
    }

    public func resolveJoinURL(
        expectedEvent: NextCalendarEventSummary?,
        currentEvent: NextCalendarEventSummary?
    ) -> URL? {
        guard let expectedEvent,
              let currentEvent,
              MeetingJoinEventKey(event: expectedEvent) == MeetingJoinEventKey(event: currentEvent) else {
            return nil
        }
        return url(for: currentEvent)
    }
}
