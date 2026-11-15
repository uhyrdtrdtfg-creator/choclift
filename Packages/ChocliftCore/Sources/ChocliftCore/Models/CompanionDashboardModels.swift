import Foundation

// MARK: - 1. Clipboard Preview, 5-Item Ring & Safe Plain-Text Filtering (280-Char Max)

public struct ClipboardHistoryEntry: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let isTruncated: Bool

    private enum CodingKeys: String, CodingKey {
        case text
        case isTruncated
    }

    public init?(text: String?, isTruncated: Bool = false) {
        guard let raw = text,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if raw.count > ClipboardPreviewSnapshot.maxPreviewCharacters {
            self.text = String(raw.prefix(ClipboardPreviewSnapshot.maxPreviewCharacters))
            self.isTruncated = true
        } else {
            self.text = raw
            self.isTruncated = isTruncated
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawText = try container.decode(String.self, forKey: .text)
        let rawTruncated = try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
        guard let valid = Self(text: rawText, isTruncated: rawTruncated) else {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: container,
                debugDescription: "ClipboardHistoryEntry text must not be empty"
            )
        }
        self = valid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let safe = text.count > ClipboardPreviewSnapshot.maxPreviewCharacters
            ? String(text.prefix(ClipboardPreviewSnapshot.maxPreviewCharacters))
            : text
        try container.encode(safe, forKey: .text)
        try container.encode(isTruncated, forKey: .isTruncated)
    }

    public var singleLinePreview: String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return isTruncated ? "\(collapsed)…" : collapsed
    }
}

/// Pure ring buffer keeping the last 5 non-empty sanitized clipboard text entries, newest first.
public struct ClipboardHistoryRing: Equatable, Sendable {
    public static let maxEntries = 5

    public private(set) var entries: [ClipboardHistoryEntry]

    public init(entries: [ClipboardHistoryEntry] = []) {
        self.entries = Self.sanitize(entries)
    }

    @discardableResult
    public mutating func record(_ snapshot: ClipboardPreviewSnapshot) -> [ClipboardHistoryEntry] {
        guard let entry = ClipboardHistoryEntry(text: snapshot.previewText, isTruncated: snapshot.isTruncated) else {
            return entries
        }
        entries.removeAll { $0.text == entry.text }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        return entries
    }

    @discardableResult
    public mutating func record(text: String?, isTruncated: Bool = false) -> [ClipboardHistoryEntry] {
        record(ClipboardPreviewSnapshot(previewText: text, isTruncated: isTruncated))
    }

    public static func sanitize(_ candidates: [ClipboardHistoryEntry]) -> [ClipboardHistoryEntry] {
        var seen = Set<String>()
        var result: [ClipboardHistoryEntry] = []
        for candidate in candidates {
            guard let normalized = ClipboardHistoryEntry(
                text: candidate.text,
                isTruncated: candidate.isTruncated
            ) else {
                continue
            }
            if seen.insert(normalized.text).inserted {
                result.append(normalized)
                if result.count >= maxEntries {
                    break
                }
            }
        }
        return result
    }
}

private struct RawClipboardHistoryEntryPayload: Decodable {
    let text: String?
    let isTruncated: Bool?
}

public struct ClipboardPreviewSnapshot: Codable, Equatable, Hashable, Sendable {
    public static let maxPreviewCharacters = 280
    public static let empty = ClipboardPreviewSnapshot(previewText: nil, isTruncated: false)

    public let previewText: String?
    public let isTruncated: Bool
    public let recentEntries: [ClipboardHistoryEntry]

    private enum CodingKeys: String, CodingKey {
        case previewText
        case isTruncated
        case recentEntries
    }

    public init(
        previewText: String?,
        isTruncated: Bool = false,
        recentEntries: [ClipboardHistoryEntry] = []
    ) {
        self.recentEntries = ClipboardHistoryRing.sanitize(recentEntries)
        guard let raw = previewText,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.previewText = nil
            self.isTruncated = false
            return
        }
        if raw.count > Self.maxPreviewCharacters {
            self.previewText = String(raw.prefix(Self.maxPreviewCharacters))
            self.isTruncated = true
        } else {
            self.previewText = raw
            self.isTruncated = isTruncated
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedText = try container.decodeIfPresent(String.self, forKey: .previewText)
        let decodedTruncated = try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
        let rawEntries = try container.decodeIfPresent([RawClipboardHistoryEntryPayload].self, forKey: .recentEntries) ?? []
        let parsedEntries = rawEntries.compactMap {
            ClipboardHistoryEntry(text: $0.text, isTruncated: $0.isTruncated ?? false)
        }
        self.init(
            previewText: decodedText,
            isTruncated: decodedTruncated,
            recentEntries: parsedEntries
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let previewText {
            let safe = previewText.count > Self.maxPreviewCharacters
                ? String(previewText.prefix(Self.maxPreviewCharacters))
                : previewText
            try container.encode(safe, forKey: .previewText)
        }
        try container.encode(isTruncated, forKey: .isTruncated)
        if !recentEntries.isEmpty {
            try container.encode(ClipboardHistoryRing.sanitize(recentEntries), forKey: .recentEntries)
        }
    }

    public func withRecentEntries(_ entries: [ClipboardHistoryEntry]) -> ClipboardPreviewSnapshot {
        ClipboardPreviewSnapshot(
            previewText: previewText,
            isTruncated: isTruncated,
            recentEntries: entries
        )
    }

    public var effectiveRecentEntries: [ClipboardHistoryEntry] {
        if !recentEntries.isEmpty {
            return recentEntries
        }
        if let entry = ClipboardHistoryEntry(text: previewText, isTruncated: isTruncated) {
            return [entry]
        }
        return []
    }

    public var hasText: Bool {
        previewText != nil
    }

    /// Compact single-line representation for dense bars while preserving up to 280 chars.
    public var singleLinePreview: String? {
        guard let previewText else { return nil }
        let collapsed = previewText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

public enum ClipboardPreviewEvaluator {
    /// Standard NSPasteboard markers for passwords, OTPs, password managers, and transient staging.
    public static let concealedOrTransientTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
        "net.antelle.keeweb"
    ]

    public static let plainTextTypes: Set<String> = [
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.utf16-external-plain-text",
        "public.plain-text",
        "NSStringPboardType",
        "public.text"
    ]

    public static let fileCopyTypes: Set<String> = [
        "public.file-url",
        "NSFilenamesPboardType"
    ]

    public static let imageOrBinaryTypes: Set<String> = [
        "public.png",
        "public.tiff",
        "public.jpeg",
        "public.heic",
        "public.heif",
        "com.compuserve.gif",
        "public.webp",
        "com.apple.pict",
        "com.adobe.pdf"
    ]

    public static let richTextTypes: Set<String> = [
        "public.rtf",
        "public.rtfd",
        "com.apple.flat-rtfd"
    ]

    /// Pure evaluation of Mac pasteboard UTI types and string value:
    /// - Rejects passwords / concealed / transient items
    /// - Rejects Finder file copies and image pasteboards
    /// - Rejects empty or whitespace-only text
    /// - Truncates plain text strictly to at most 280 `Character`s
    public static func evaluate(
        pasteboardTypes: Set<String>,
        string: String?
    ) -> ClipboardPreviewSnapshot {
        guard isSafePlainTextPasteboard(pasteboardTypes: pasteboardTypes),
              let raw = string,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        let overLimit = raw.count > ClipboardPreviewSnapshot.maxPreviewCharacters
        let clipped = overLimit ? String(raw.prefix(ClipboardPreviewSnapshot.maxPreviewCharacters)) : raw
        return ClipboardPreviewSnapshot(previewText: clipped, isTruncated: overLimit)
    }

    /// Extracts safe plain text for pasting into the focused Mac text field via the existing insert path.
    /// Rejects passwords/concealed items, file copies, and images.
    public static func extractInsertablePlainText(
        pasteboardTypes: Set<String>,
        string: String?
    ) -> String? {
        guard isSafePlainTextPasteboard(pasteboardTypes: pasteboardTypes),
              let raw = string,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let clamped = TextSnippet.clampBody(raw)
        return clamped.isEmpty ? nil : clamped
    }

    public static func isSafePlainTextPasteboard(pasteboardTypes: Set<String>) -> Bool {
        guard !pasteboardTypes.isEmpty else { return false }
        if !pasteboardTypes.isDisjoint(with: concealedOrTransientTypes) {
            return false
        }
        if !pasteboardTypes.isDisjoint(with: fileCopyTypes) {
            return false
        }
        let hasImage = !pasteboardTypes.isDisjoint(with: imageOrBinaryTypes)
        let hasRichText = !pasteboardTypes.isDisjoint(with: richTextTypes)
        if hasImage && !hasRichText {
            return false
        }
        return !pasteboardTypes.isDisjoint(with: plainTextTypes)
    }
}

// MARK: - 2. Multi-Display Window Snap Target Models

public struct MacDisplayInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let displayID: UInt32
    public let name: String
    public let isMain: Bool

    public var id: UInt32 { displayID }

    private enum CodingKeys: String, CodingKey {
        case displayID
        case name
        case isMain
    }

    public init(displayID: UInt32, name: String, isMain: Bool = false) {
        self.displayID = displayID
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = cleaned.isEmpty ? "Display \(displayID)" : cleaned
        self.isMain = isMain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UInt32.self, forKey: .displayID)
        let rawName = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        let main = try container.decodeIfPresent(Bool.self, forKey: .isMain) ?? false
        self.init(displayID: id, name: rawName, isMain: main)
    }
}

public enum DisplaySnapTargetResolver {
    /// Picker is shown only when more than one display is connected.
    public static func shouldShowPicker(for connectedDisplays: [MacDisplayInfo]) -> Bool {
        connectedDisplays.count > 1
    }

    /// Resolves the chosen display ID when valid and multiple displays are connected;
    /// otherwise returns `nil` so snap/maximize/split defaults to the display containing the frontmost window.
    public static func resolvedTargetDisplayID(
        selectedDisplayID: UInt32?,
        connectedDisplays: [MacDisplayInfo]
    ) -> UInt32? {
        guard connectedDisplays.count > 1,
              let selectedDisplayID,
              connectedDisplays.contains(where: { $0.displayID == selectedDisplayID }) else {
            return nil
        }
        return selectedDisplayID
    }
}

// MARK: - 3. One-Tap Main Display Screenshot Result

public struct ScreenshotCaptureResult: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let capturedAt: Date
    public let success: Bool
    public let fileName: String?
    public let previewJPEGData: Data?
    public let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case capturedAt
        case success
        case fileName
        case previewJPEGData
        case errorMessage
    }

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        success: Bool,
        fileName: String? = nil,
        previewJPEGData: Data? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.success = success
        self.fileName = fileName
        self.previewJPEGData = previewJPEGData
        self.errorMessage = errorMessage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
        self.success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? false
        self.fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        self.previewJPEGData = try container.decodeIfPresent(Data.self, forKey: .previewJPEGData)
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    public static func succeeded(
        fileName: String,
        previewJPEGData: Data?,
        capturedAt: Date = Date()
    ) -> ScreenshotCaptureResult {
        ScreenshotCaptureResult(
            capturedAt: capturedAt,
            success: true,
            fileName: fileName,
            previewJPEGData: previewJPEGData,
            errorMessage: nil
        )
    }

    public static func failed(
        errorMessage: String,
        capturedAt: Date = Date()
    ) -> ScreenshotCaptureResult {
        ScreenshotCaptureResult(
            capturedAt: capturedAt,
            success: false,
            fileName: nil,
            previewJPEGData: nil,
            errorMessage: errorMessage
        )
    }
}

// MARK: - 4. Read-Only Next Calendar Event Models

public enum CalendarPermissionState: String, Codable, Equatable, Hashable, Sendable {
    case unknown
    case authorized
    case denied
}

public struct NextCalendarEventSummary: Codable, Equatable, Hashable, Sendable {
    public let title: String
    public let startDate: Date
    public let isAllDay: Bool
    public let joinProvider: String?
    public let hasJoinLink: Bool

    private enum CodingKeys: String, CodingKey {
        case title
        case startDate
        case isAllDay
        case joinProvider
        case hasJoinLink
    }

    public init(
        title: String,
        startDate: Date,
        isAllDay: Bool = false,
        joinProvider: String? = nil,
        hasJoinLink: Bool? = nil
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? "Untitled Event" : String(trimmed.prefix(120))
        self.startDate = startDate
        self.isAllDay = isAllDay

        let cleanedProvider = joinProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProvider = (cleanedProvider?.isEmpty == false) ? String(cleanedProvider!.prefix(24)) : nil
        let resolvedHasLink = hasJoinLink ?? (normalizedProvider != nil)
        self.hasJoinLink = resolvedHasLink
        self.joinProvider = resolvedHasLink ? (normalizedProvider ?? "Link") : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        let start = try container.decode(Date.self, forKey: .startDate)
        let allDay = try container.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        let provider = try container.decodeIfPresent(String.self, forKey: .joinProvider)
        let hasLink = try container.decodeIfPresent(Bool.self, forKey: .hasJoinLink)
        self.init(
            title: rawTitle,
            startDate: start,
            isAllDay: allDay,
            joinProvider: provider,
            hasJoinLink: hasLink
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(isAllDay, forKey: .isAllDay)
        if let joinProvider {
            try container.encode(joinProvider, forKey: .joinProvider)
        }
        try container.encode(hasJoinLink, forKey: .hasJoinLink)
    }
}

public struct CalendarEventCandidate: Equatable, Sendable {
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let isCanceled: Bool
    public let joinProvider: String?
    public let hasJoinLink: Bool

    public init(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        isCanceled: Bool = false,
        joinProvider: String? = nil,
        hasJoinLink: Bool? = nil
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.isCanceled = isCanceled
        let cleanedProvider = joinProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProvider = (cleanedProvider?.isEmpty == false) ? String(cleanedProvider!.prefix(24)) : nil
        let resolvedHasLink = hasJoinLink ?? (normalizedProvider != nil)
        self.hasJoinLink = resolvedHasLink
        self.joinProvider = resolvedHasLink ? (normalizedProvider ?? "Link") : nil
    }
}

public struct NextCalendarEventSnapshot: Codable, Equatable, Hashable, Sendable {
    public static let initial = NextCalendarEventSnapshot(permission: .unknown, nextEvent: nil)

    public let permission: CalendarPermissionState
    public let nextEvent: NextCalendarEventSummary?

    public var joinProvider: String? { nextEvent?.joinProvider }
    public var hasJoinLink: Bool { nextEvent?.hasJoinLink ?? false }

    private enum CodingKeys: String, CodingKey {
        case permission
        case nextEvent
        case joinProvider
        case hasJoinLink
    }

    public init(permission: CalendarPermissionState, nextEvent: NextCalendarEventSummary? = nil) {
        self.permission = permission
        self.nextEvent = (permission == .authorized) ? nextEvent : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let perm = try container.decodeIfPresent(CalendarPermissionState.self, forKey: .permission) ?? .unknown
        let decodedEvent = try container.decodeIfPresent(NextCalendarEventSummary.self, forKey: .nextEvent)
        let topProvider = try container.decodeIfPresent(String.self, forKey: .joinProvider)
        let topHasLink = try container.decodeIfPresent(Bool.self, forKey: .hasJoinLink)

        let resolvedEvent: NextCalendarEventSummary?
        if let evt = decodedEvent, !evt.hasJoinLink, (topProvider != nil || topHasLink == true) {
            resolvedEvent = NextCalendarEventSummary(
                title: evt.title,
                startDate: evt.startDate,
                isAllDay: evt.isAllDay,
                joinProvider: topProvider,
                hasJoinLink: topHasLink
            )
        } else {
            resolvedEvent = decodedEvent
        }
        self.init(permission: perm, nextEvent: resolvedEvent)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(permission, forKey: .permission)
        if let nextEvent {
            try container.encode(nextEvent, forKey: .nextEvent)
        }
    }

    /// Selects the next relevant event from read-only calendar candidates:
    /// prefers upcoming events starting at or after `now`, falling back to an ongoing non-all-day event.
    public static func selectNextEvent(
        from candidates: [CalendarEventCandidate],
        now: Date
    ) -> NextCalendarEventSummary? {
        let active = candidates.filter { !$0.isCanceled && $0.endDate > now }
        guard !active.isEmpty else { return nil }

        let upcoming = active
            .filter { $0.startDate >= now }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                if lhs.isAllDay != rhs.isAllDay {
                    return !lhs.isAllDay
                }
                if lhs.hasJoinLink != rhs.hasJoinLink {
                    return lhs.hasJoinLink && !rhs.hasJoinLink
                }
                return lhs.title < rhs.title
            }

        if let nextUpcoming = upcoming.first {
            return NextCalendarEventSummary(
                title: nextUpcoming.title,
                startDate: nextUpcoming.startDate,
                isAllDay: nextUpcoming.isAllDay,
                joinProvider: nextUpcoming.joinProvider,
                hasJoinLink: nextUpcoming.hasJoinLink
            )
        }

        let ongoingTimed = active
            .filter { !$0.isAllDay }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                if lhs.hasJoinLink != rhs.hasJoinLink {
                    return lhs.hasJoinLink && !rhs.hasJoinLink
                }
                return lhs.title < rhs.title
            }

        if let currentTimed = ongoingTimed.first {
            return NextCalendarEventSummary(
                title: currentTimed.title,
                startDate: currentTimed.startDate,
                isAllDay: false,
                joinProvider: currentTimed.joinProvider,
                hasJoinLink: currentTimed.hasJoinLink
            )
        }

        if let ongoingAllDay = active.sorted(by: { lhs, rhs in
            if lhs.startDate != rhs.startDate {
                return lhs.startDate < rhs.startDate
            }
            return lhs.hasJoinLink && !rhs.hasJoinLink
        }).first {
            return NextCalendarEventSummary(
                title: ongoingAllDay.title,
                startDate: ongoingAllDay.startDate,
                isAllDay: ongoingAllDay.isAllDay,
                joinProvider: ongoingAllDay.joinProvider,
                hasJoinLink: ongoingAllDay.hasJoinLink
            )
        }
        return nil
    }

    public static func formattedCountdown(
        for event: NextCalendarEventSummary,
        referenceDate: Date = Date(),
        language: AppLanguage = .system
    ) -> String {
        if event.isAllDay {
            return L10n.tr("现在", "Now", language: language)
        }
        let delta = event.startDate.timeIntervalSince(referenceDate)
        if delta < 60 {
            return L10n.tr("现在", "Now", language: language)
        }
        if delta < 3600 {
            let minutes = max(1, Int((delta / 60.0).rounded()))
            if minutes >= 60 {
                return L10n.tr("1小时后", "in 1h", language: language)
            }
            return L10n.tr("\(minutes)分钟后", "in \(minutes)m", language: language)
        }
        if delta < 86_400 {
            let hours = max(1, Int((delta / 3600.0).rounded(.down)))
            return L10n.tr("\(hours)小时后", "in \(hours)h", language: language)
        }
        let days = max(1, Int((delta / 86_400.0).rounded(.down)))
        return L10n.tr("\(days)天后", "in \(days)d", language: language)
    }

    public static func formattedStartTime(
        for event: NextCalendarEventSummary,
        referenceDate: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        language: AppLanguage = .system
    ) -> String {
        let localeIdentifier: String = {
            switch language {
            case .chinese:
                return "zh_CN"
            case .english:
                return "en_US"
            case .system:
                return L10n.isSystemChinese ? "zh_CN" : "en_US"
            }
        }()
        let locale = Locale(identifier: localeIdentifier)
        let isToday = calendar.isDate(event.startDate, inSameDayAs: referenceDate)
        let isTomorrow: Bool = {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: referenceDate) else { return false }
            return calendar.isDate(event.startDate, inSameDayAs: tomorrow)
        }()

        if event.isAllDay {
            if isToday {
                return L10n.tr("今日全天", "All-day", language: language)
            }
            if isTomorrow {
                return L10n.tr("明天全天", "Tomorrow · All-day", language: language)
            }
            let dayFormatter = DateFormatter()
            dayFormatter.locale = locale
            dayFormatter.timeZone = calendar.timeZone
            dayFormatter.setLocalizedDateFormatFromTemplate("MMMd")
            let dayText = dayFormatter.string(from: event.startDate)
            return "\(dayText) · \(L10n.tr("全天", "All-day", language: language))"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let timeString = timeFormatter.string(from: event.startDate)

        if isToday {
            return timeString
        }
        if isTomorrow {
            return L10n.tr("明天 \(timeString)", "Tomorrow \(timeString)", language: language)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = locale
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.setLocalizedDateFormatFromTemplate("EEE")
        let weekday = dateFormatter.string(from: event.startDate)
        return "\(weekday) \(timeString)"
    }
}
