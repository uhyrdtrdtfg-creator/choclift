import Foundation

// MARK: - Snippet Placeholder Tokens & Expander

/// Supported placeholder tokens that expand on the Mac at snippet insert time.
public enum SnippetPlaceholderToken: String, CaseIterable, Identifiable, Hashable, Sendable {
    case date = "{{date}}"
    case time = "{{time}}"
    case isoDate = "{{iso_date}}"
    case weekday = "{{weekday}}"
    case clipboard = "{{clipboard}}"

    public var id: String { rawValue }

    public var token: String { rawValue }

    public var name: String {
        switch self {
        case .date:
            return "date"
        case .time:
            return "time"
        case .isoDate:
            return "iso_date"
        case .weekday:
            return "weekday"
        case .clipboard:
            return "clipboard"
        }
    }
}

/// Pure, single-pass placeholder expander for `TextSnippet` bodies.
public enum SnippetPlaceholderExpander {
    public static let maxClipboardCharacters = 280
    public static let previewClipboardPlaceholder = "[clipboard]"

    public static var supportedTokens: [SnippetPlaceholderToken] {
        SnippetPlaceholderToken.allCases
    }

    /// Expands supported case-sensitive `{{token}}` placeholders in a single pass.
    /// Unknown or differently-cased tokens remain unchanged.
    public static func expand(
        _ body: String,
        now: Date,
        calendar: Calendar,
        clipboard: String?
    ) -> String {
        guard body.contains("{{") else {
            return body
        }

        let posixLocale = Locale(identifier: "en_US_POSIX")

        let dateFormatter = DateFormatter()
        dateFormatter.locale = posixLocale
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let formattedDate = dateFormatter.string(from: now)

        let timeFormatter = DateFormatter()
        timeFormatter.locale = posixLocale
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateFormat = "HH:mm"
        let formattedTime = timeFormatter.string(from: now)

        let weekdayLocale: Locale = {
            if let locale = calendar.locale, !locale.identifier.isEmpty {
                return locale
            }
            return posixLocale
        }()
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = weekdayLocale
        weekdayFormatter.calendar = calendar
        weekdayFormatter.timeZone = calendar.timeZone
        weekdayFormatter.dateFormat = "EEE"
        let formattedWeekday = weekdayFormatter.string(from: now)

        let formattedClipboard: String = {
            guard let raw = clipboard else { return "" }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            return String(trimmed.prefix(maxClipboardCharacters))
        }()

        var result = ""
        result.reserveCapacity(body.count)
        var index = body.startIndex

        while index < body.endIndex {
            if body[index] == "{" {
                let remaining = body[index...]
                if remaining.hasPrefix(SnippetPlaceholderToken.date.rawValue) {
                    result.append(formattedDate)
                    index = body.index(index, offsetBy: SnippetPlaceholderToken.date.rawValue.count)
                    continue
                }
                if remaining.hasPrefix(SnippetPlaceholderToken.time.rawValue) {
                    result.append(formattedTime)
                    index = body.index(index, offsetBy: SnippetPlaceholderToken.time.rawValue.count)
                    continue
                }
                if remaining.hasPrefix(SnippetPlaceholderToken.isoDate.rawValue) {
                    result.append(formattedDate)
                    index = body.index(index, offsetBy: SnippetPlaceholderToken.isoDate.rawValue.count)
                    continue
                }
                if remaining.hasPrefix(SnippetPlaceholderToken.weekday.rawValue) {
                    result.append(formattedWeekday)
                    index = body.index(index, offsetBy: SnippetPlaceholderToken.weekday.rawValue.count)
                    continue
                }
                if remaining.hasPrefix(SnippetPlaceholderToken.clipboard.rawValue) {
                    result.append(formattedClipboard)
                    index = body.index(index, offsetBy: SnippetPlaceholderToken.clipboard.rawValue.count)
                    continue
                }
            }
            result.append(body[index])
            index = body.index(after: index)
        }

        return result
    }

    /// Produces a single-line expansion preview using `[clipboard]` in place of live pasteboard contents.
    public static func preview(
        _ body: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let expanded = expand(
            body,
            now: now,
            calendar: calendar,
            clipboard: previewClipboardPlaceholder
        )
        return expanded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Appends a token string to `body` when it fits within `TextSnippet.maxBodyLength`.
    public static func appendToken(_ token: SnippetPlaceholderToken, to body: String) -> String {
        let candidate = body + token.rawValue
        guard candidate.count <= TextSnippet.maxBodyLength else {
            return body
        }
        return candidate
    }
}
