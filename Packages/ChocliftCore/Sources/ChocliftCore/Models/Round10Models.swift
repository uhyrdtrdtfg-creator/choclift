import Foundation

// MARK: - 1. Tile Folders (At Most 1 Folder Tile Per Page, Up to 8 Child Actions, Does Not Change 8-Page Limit)

private struct SafeFolderChildDecodeWrapper: Decodable {
    let item: BarItem?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self.item = nil
            return
        }
        self.item = try? BarItem(from: decoder)
    }
}

/// A folder tile payload stored inside a `BarPage` slot (`BarItemKind.folder`).
/// - Strictly capped at `maxChildren == 8` concrete non-folder child actions.
/// - Never creates a new `BarPage` and never alters `BarPage.maxPages == 8`.
public struct TileFolder: Codable, Equatable, Hashable, Sendable {
    public static let maxChildren: Int = 8
    public static let maxFoldersPerPage: Int = 1
    public static let maxTitleCharacters: Int = 36
    public static let defaultEmoji: String = "📁"
    public static let defaultBackgroundHex: String = "#FFF6E3"

    public var title: String
    public var emoji: String
    public var backgroundHex: String
    public var children: [BarItem] {
        didSet {
            let sanitized = Self.sanitizeChildren(children)
            if children != sanitized {
                children = sanitized
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case emoji
        case backgroundHex
        case children
    }

    public init(
        title: String = "",
        emoji: String = TileFolder.defaultEmoji,
        backgroundHex: String = TileFolder.defaultBackgroundHex,
        children: [BarItem] = []
    ) {
        self.title = Self.sanitizeTitle(title)
        self.emoji = Self.sanitizeEmoji(emoji)
        self.backgroundHex = Self.sanitizeBackgroundHex(backgroundHex)
        self.children = Self.sanitizeChildren(children)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        let rawEmoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? Self.defaultEmoji
        let rawHex = try container.decodeIfPresent(String.self, forKey: .backgroundHex) ?? Self.defaultBackgroundHex
        let wrapped = try container.decodeIfPresent([SafeFolderChildDecodeWrapper].self, forKey: .children) ?? []
        self.title = Self.sanitizeTitle(rawTitle)
        self.emoji = Self.sanitizeEmoji(rawEmoji)
        self.backgroundHex = Self.sanitizeBackgroundHex(rawHex)
        self.children = Self.sanitizeChildren(wrapped.compactMap(\.item))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.sanitizeTitle(title), forKey: .title)
        try container.encode(Self.sanitizeEmoji(emoji), forKey: .emoji)
        try container.encode(Self.sanitizeBackgroundHex(backgroundHex), forKey: .backgroundHex)
        try container.encode(Self.sanitizeChildren(children), forKey: .children)
    }

    public var canAddMoreChildren: Bool {
        children.count < Self.maxChildren
    }

    public func displayTitle(in language: AppLanguage = .system) -> String {
        let cleaned = Self.sanitizeTitle(title)
        if cleaned.isEmpty {
            return L10n.tr("文件夹", "Folder", language: language)
        }
        return cleaned
    }

    /// Appends a concrete non-folder child action if under the 8-child cap.
    @discardableResult
    public mutating func addChild(_ item: BarItem) -> Bool {
        guard Self.isAllowedChild(item) else { return false }
        let current = Self.sanitizeChildren(children)
        if current.contains(where: { $0.id == item.id }) {
            children = current
            return false
        }
        guard current.count < Self.maxChildren else {
            children = current
            return false
        }
        children = current + [item]
        return true
    }

    @discardableResult
    public mutating func replaceChild(at index: Int, with item: BarItem) -> Bool {
        var current = Self.sanitizeChildren(children)
        guard current.indices.contains(index), Self.isAllowedChild(item) else {
            return false
        }
        if current.enumerated().contains(where: { $0.offset != index && $0.element.id == item.id }) {
            return false
        }
        current[index] = item
        children = current
        return true
    }

    @discardableResult
    public mutating func removeChild(at index: Int) -> Bool {
        var current = Self.sanitizeChildren(children)
        guard current.indices.contains(index) else { return false }
        current.remove(at: index)
        children = current
        return true
    }

    @discardableResult
    public mutating func removeChild(id: UUID) -> Bool {
        let current = Self.sanitizeChildren(children)
        let filtered = current.filter { $0.id != id }
        guard filtered.count != current.count else { return false }
        children = filtered
        return true
    }

    @discardableResult
    public mutating func moveChild(from sourceIndex: Int, to destinationIndex: Int) -> Bool {
        var current = Self.sanitizeChildren(children)
        guard current.indices.contains(sourceIndex),
              current.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else {
            return false
        }
        let moving = current.remove(at: sourceIndex)
        current.insert(moving, at: destinationIndex)
        children = current
        return true
    }

    public static func isAllowedChild(_ item: BarItem) -> Bool {
        !item.isFolder && !item.isSlotReference
    }

    /// Strips nested folders and slot references, deduplicates by `id`, and enforces `<= 8` children.
    public static func sanitizeChildren(_ raw: [BarItem]) -> [BarItem] {
        var seenIDs = Set<UUID>()
        var result: [BarItem] = []
        result.reserveCapacity(min(raw.count, maxChildren))
        for candidate in raw {
            guard isAllowedChild(candidate) else { continue }
            guard !seenIDs.contains(candidate.id) else { continue }
            seenIDs.insert(candidate.id)
            result.append(candidate)
            if result.count >= maxChildren {
                break
            }
        }
        return result
    }

    public static func sanitizeTitle(_ raw: String) -> String {
        let singleLine = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return "" }
        if singleLine.count > maxTitleCharacters {
            return String(singleLine.prefix(maxTitleCharacters))
        }
        return singleLine
    }

    public static func sanitizeEmoji(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultEmoji }
        return String(trimmed.prefix(2))
    }

    public static func sanitizeBackgroundHex(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultBackgroundHex : trimmed
    }
}

// MARK: - 2. Hold to Repeat Policy & Deterministic Controller (Volume Up, Volume Down, Media Next Only; >= 400 ms)

public enum HoldToRepeatPolicy {
    /// Minimum repeat interval while a finger stays down: 400 ms (`0.4` seconds).
    public static let minimumRepeatIntervalSeconds: TimeInterval = 0.4
    public static let minimumRepeatIntervalMilliseconds: Int = 400

    /// Only Volume Up, Volume Down, and Media Next repeat while held.
    public static let repeatableActions: Set<SystemQuickAction> = [
        .volumeUp,
        .volumeDown,
        .mediaNext
    ]

    public static func supportsHoldToRepeat(_ action: SystemQuickAction) -> Bool {
        repeatableActions.contains(action)
    }

    public static func repeatableSystemAction(
        for item: BarItem?,
        in profile: ChocliftWorkspaceProfile? = nil,
        from origin: SlotCoordinate? = nil
    ) -> SystemQuickAction? {
        guard let item else { return nil }
        switch item.kind {
        case .systemAction(let action, _, _):
            return supportsHoldToRepeat(action) ? action : nil
        case .slotReference:
            guard let profile,
                  case .resolved(_, _, _, _, _, let target) = profile.resolveBarItem(item, from: origin),
                  case .systemAction(let action, _, _) = target.kind,
                  supportsHoldToRepeat(action) else {
                return nil
            }
            return action
        default:
            return nil
        }
    }

    public static func supportsHoldToRepeat(
        _ item: BarItem?,
        in profile: ChocliftWorkspaceProfile? = nil,
        from origin: SlotCoordinate? = nil
    ) -> Bool {
        repeatableSystemAction(for: item, in: profile, from: origin) != nil
    }
}

/// Pure, deterministic hold-to-repeat state machine:
/// - Accepts ONLY `.volumeUp`, `.volumeDown`, and `.mediaNext` (all other tiles/actions are rejected).
/// - Fires once when the hold begins, then never fires again before `400 ms` (`0.4 s`) have elapsed.
/// - Releasing (`endHold()`) immediately halts all further repeats.
public struct HoldToRepeatController: Equatable, Sendable {
    public let minimumIntervalSeconds: TimeInterval
    public private(set) var isHolding: Bool = false
    public private(set) var activeAction: SystemQuickAction?
    public private(set) var lastFiredAt: TimeInterval?
    public private(set) var fireCount: Int = 0

    public init(minimumIntervalSeconds: TimeInterval = HoldToRepeatPolicy.minimumRepeatIntervalSeconds) {
        self.minimumIntervalSeconds = max(
            HoldToRepeatPolicy.minimumRepeatIntervalSeconds,
            minimumIntervalSeconds
        )
    }

    /// Starts holding `action` at monotonic timestamp `now`.
    /// Returns `true` and records the initial fire when `action` supports hold-to-repeat;
    /// returns `false` and stays inactive for all non-repeatable actions.
    @discardableResult
    public mutating func beginHold(for action: SystemQuickAction, at now: TimeInterval) -> Bool {
        guard now.isFinite, HoldToRepeatPolicy.supportsHoldToRepeat(action) else {
            endHold()
            return false
        }
        isHolding = true
        activeAction = action
        lastFiredAt = now
        fireCount = 1
        return true
    }

    /// Starts holding `item` at monotonic timestamp `now`.
    /// Returns `true` ONLY when `item` resolves to `.volumeUp`, `.volumeDown`, or `.mediaNext`.
    @discardableResult
    public mutating func beginHold(
        for item: BarItem?,
        in profile: ChocliftWorkspaceProfile? = nil,
        from origin: SlotCoordinate? = nil,
        at now: TimeInterval
    ) -> Bool {
        guard let action = HoldToRepeatPolicy.repeatableSystemAction(for: item, in: profile, from: origin) else {
            endHold()
            return false
        }
        return beginHold(for: action, at: now)
    }

    /// Evaluates whether a held repeatable tile may fire again at monotonic timestamp `now`.
    /// Strictly returns `false` if fewer than `400 ms` (`minimumIntervalSeconds`) have elapsed since `lastFiredAt`
    /// or if the finger has been released.
    public mutating func shouldFireRepeat(at now: TimeInterval) -> Bool {
        guard isHolding,
              activeAction != nil,
              let previousFire = lastFiredAt,
              now.isFinite,
              now >= previousFire else {
            return false
        }
        // Guard against 1e-16 IEEE-754 binary fraction drift at exact multiples of 0.4 (e.g. 1.2 - 0.8)
        // while still rejecting sub-400ms intervals (even 399.999 ms).
        let elapsed = now - previousFire
        guard elapsed + 1e-9 >= minimumIntervalSeconds else {
            return false
        }
        lastFiredAt = now
        fireCount += 1
        return true
    }

    /// Stops repeating immediately when the finger lifts or drifts away.
    public mutating func endHold() {
        isHolding = false
        activeAction = nil
        lastFiredAt = nil
    }
}

// MARK: - 3. Quiet Hours for Haptics (Phone Setting — Mutes Success & Failure Haptics Locally, Default Off)

/// Phone-local setting that mutes success and failure haptics between two local clock times
/// while Mac actions continue to execute normally. Default is OFF (`isEnabled == false`).
public struct HapticQuietHoursSettings: Codable, Equatable, Hashable, Sendable {
    public static let minutesPerDay: Int = 24 * 60
    public static let defaultStartMinuteOfDay: Int = 22 * 60 // 22:00
    public static let defaultEndMinuteOfDay: Int = 7 * 60    // 07:00

    public var isEnabled: Bool
    public var startMinuteOfDay: Int
    public var endMinuteOfDay: Int

    public static let disabled = HapticQuietHoursSettings()

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case startMinuteOfDay
        case endMinuteOfDay
    }

    public init(
        isEnabled: Bool = false,
        startMinuteOfDay: Int = HapticQuietHoursSettings.defaultStartMinuteOfDay,
        endMinuteOfDay: Int = HapticQuietHoursSettings.defaultEndMinuteOfDay
    ) {
        self.isEnabled = isEnabled
        self.startMinuteOfDay = Self.normalizeMinuteOfDay(startMinuteOfDay)
        self.endMinuteOfDay = Self.normalizeMinuteOfDay(endMinuteOfDay)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let rawStart = try container.decodeIfPresent(Int.self, forKey: .startMinuteOfDay) ?? Self.defaultStartMinuteOfDay
        let rawEnd = try container.decodeIfPresent(Int.self, forKey: .endMinuteOfDay) ?? Self.defaultEndMinuteOfDay
        self.startMinuteOfDay = Self.normalizeMinuteOfDay(rawStart)
        self.endMinuteOfDay = Self.normalizeMinuteOfDay(rawEnd)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(Self.normalizeMinuteOfDay(startMinuteOfDay), forKey: .startMinuteOfDay)
        try container.encode(Self.normalizeMinuteOfDay(endMinuteOfDay), forKey: .endMinuteOfDay)
    }

    public static func normalizeMinuteOfDay(_ raw: Int) -> Int {
        let mod = raw % minutesPerDay
        return mod < 0 ? (mod + minutesPerDay) : mod
    }

    public static func minuteOfDay(from date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return normalizeMinuteOfDay(hour * 60 + minute)
    }

    public static func date(
        forMinuteOfDay minuteOfDay: Int,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let normalized = normalizeMinuteOfDay(minuteOfDay)
        let hour = normalized / 60
        let minute = normalized % 60
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: referenceDate) ?? referenceDate
    }

    /// Returns `true` when `isEnabled` is on and `date` falls inside `[startMinuteOfDay, endMinuteOfDay)`
    /// in `calendar`'s local time zone (supporting both same-day and overnight spans).
    public func isQuietTime(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        let start = Self.normalizeMinuteOfDay(startMinuteOfDay)
        let end = Self.normalizeMinuteOfDay(endMinuteOfDay)
        guard start != end else { return false }

        let current = Self.minuteOfDay(from: date, calendar: calendar)
        if start < end {
            return current >= start && current < end
        } else {
            return current >= start || current < end
        }
    }

    /// Determines whether success or failure notification haptics should play on the phone.
    public func shouldPlayOutcomeHaptics(
        hapticFeedbackEnabled: Bool,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard hapticFeedbackEnabled else { return false }
        return !isQuietTime(at: date, calendar: calendar)
    }

    public static func formatClockTime(minuteOfDay: Int) -> String {
        let normalized = normalizeMinuteOfDay(minuteOfDay)
        let hour = normalized / 60
        let minute = normalized % 60
        return String(format: "%02d:%02d", hour, minute)
    }

    public var formattedTimeRange: String {
        "\(Self.formatClockTime(minuteOfDay: startMinuteOfDay)) – \(Self.formatClockTime(minuteOfDay: endMinuteOfDay))"
    }
}

// MARK: - 4. Last Triggered Time Formatter (Compact Elapsed Badge Backed by Existing Recent List)

public enum LastTriggeredTimeFormatter {
    /// Formats how long ago a tile ran in compact form (e.g. `"now"`, `"15s"`, `"2m"`, `"3h"`, `"2d"`).
    public static func compactRelativeString(
        since triggeredAt: Date?,
        now: Date = Date()
    ) -> String? {
        guard let triggeredAt,
              triggeredAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite else {
            return nil
        }
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(triggeredAt).rounded(.down)))
        if elapsedSeconds < 5 {
            return "now"
        }
        if elapsedSeconds < 60 {
            return "\(elapsedSeconds)s"
        }
        let minutes = elapsedSeconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }
        let days = hours / 24
        return "\(days)d"
    }
}

// MARK: - 5. Page Reorder Direction (Phone Move Left / Move Right, Preserving Page UUID Bindings)

public enum PageReorderDirection: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case left
    case right

    public var indexDelta: Int {
        switch self {
        case .left:
            return -1
        case .right:
            return 1
        }
    }
}
