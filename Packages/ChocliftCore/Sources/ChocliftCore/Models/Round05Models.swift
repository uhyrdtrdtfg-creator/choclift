import Foundation

// MARK: - Round 5 Public API Note (Keyboard Backlight Skipped on macOS 13)
//
// Item 1 (Keyboard backlight 0...1 slider) was audited against the macOS SDK and skipped per rule
// ("If macOS 13 cannot set it without a private API, skip this item. Do not fake it."):
// - `CoreBrightness.framework` (`KeyboardBrightnessClient`) lives in
//   `/System/Library/PrivateFrameworks/CoreBrightness.framework` (private API).
// - `IOKit` `AppleLMUController` user-client scalar selectors (`kGetLEDBrightnessID` / `kSetLEDBrightnessID`)
//   are undocumented private selectors absent from public `<IOKit/...>` headers and unsupported on Apple Silicon.
// - `<IOKit/hid/IOHIDUsageTables.h>` (`kHIDUsage_Csmr_KeyboardBrightnessIncrement` / `Decrement`) and
//   `NX_KEYTYPE_ILLUMINATION_UP` / `DOWN` only emit step key events and cannot detect backlight hardware
//   or set a normalized `0...1` slider level.
// - `CoreHID.framework` (`HIDUsage.ConsumerUsage.keyboardBacklightSetLevel`) is `@available(macOS 15.0, *)`
//   and only defines USB HID usage constants rather than a macOS system backlight controller.

// MARK: - 1. Compact Key Row Model (Arrows, Escape, Space Only — No Letter Keys)

public enum CompanionCompactKey: String, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case escape
    case leftArrow
    case upArrow
    case downArrow
    case rightArrow
    case space

    public static let compactRowOrder: [CompanionCompactKey] = [
        .escape,
        .leftArrow,
        .upArrow,
        .downArrow,
        .rightArrow,
        .space
    ]

    public var id: String { rawValue }

    public var isArrowKey: Bool {
        switch self {
        case .leftArrow, .upArrow, .downArrow, .rightArrow:
            return true
        case .escape, .space:
            return false
        }
    }

    public var sfSymbol: String {
        switch self {
        case .escape:
            return "escape"
        case .leftArrow:
            return "arrow.left"
        case .upArrow:
            return "arrow.up"
        case .downArrow:
            return "arrow.down"
        case .rightArrow:
            return "arrow.right"
        case .space:
            return "space"
        }
    }

    public func capLabel(in lang: AppLanguage = .system) -> String {
        switch self {
        case .escape:
            return "Esc"
        case .leftArrow:
            return "←"
        case .upArrow:
            return "↑"
        case .downArrow:
            return "↓"
        case .rightArrow:
            return "→"
        case .space:
            return L10n.tr("空格", "Space", language: lang)
        }
    }

    public func title(in lang: AppLanguage = .system) -> String {
        switch self {
        case .escape:
            return "Esc"
        case .leftArrow:
            return L10n.tr("左方向键 ←", "Left Arrow ←", language: lang)
        case .upArrow:
            return L10n.tr("上方向键 ↑", "Up Arrow ↑", language: lang)
        case .downArrow:
            return L10n.tr("下方向键 ↓", "Down Arrow ↓", language: lang)
        case .rightArrow:
            return L10n.tr("右方向键 →", "Right Arrow →", language: lang)
        case .space:
            return L10n.tr("空格键", "Space", language: lang)
        }
    }
}

// MARK: - 2. Persistent Strip Pinned Tiles (Capped at 4)

public struct ResolvedPinnedStripSlot: Equatable, Hashable, Identifiable, Sendable {
    public let coordinate: SlotCoordinate
    public let pageIndex: Int
    public let pageTitle: String
    public let pageEmoji: String
    public let slotIndex: Int
    public let item: BarItem

    public var id: String {
        "\(coordinate.pageID.uuidString)-\(slotIndex)"
    }

    public init(
        coordinate: SlotCoordinate,
        pageIndex: Int,
        pageTitle: String,
        pageEmoji: String,
        slotIndex: Int,
        item: BarItem
    ) {
        self.coordinate = coordinate
        self.pageIndex = pageIndex
        self.pageTitle = pageTitle
        self.pageEmoji = pageEmoji
        self.slotIndex = slotIndex
        self.item = item
    }
}

public enum PinnedStripSlots {
    public static let maxPinnedCount: Int = 4

    /// Deduplicates `coordinates` while preserving order, drops any coordinate whose page or slot is missing/empty,
    /// and enforces the hard cap of 4 pinned tiles.
    public static func sanitize(_ coordinates: [SlotCoordinate], in pages: [BarPage]) -> [SlotCoordinate] {
        var result: [SlotCoordinate] = []
        var seen = Set<SlotCoordinate>()
        for coordinate in coordinates {
            guard !seen.contains(coordinate) else { continue }
            guard isValidOccupiedCoordinate(coordinate, in: pages) else { continue }
            seen.insert(coordinate)
            result.append(coordinate)
            if result.count >= maxPinnedCount {
                break
            }
        }
        return result
    }

    public static func isValidOccupiedCoordinate(_ coordinate: SlotCoordinate, in pages: [BarPage]) -> Bool {
        guard let page = pages.first(where: { $0.id == coordinate.pageID }),
              page.slots.indices.contains(coordinate.slotIndex),
              page.slots[coordinate.slotIndex] != nil else {
            return false
        }
        return true
    }

    public static func pin(
        _ coordinate: SlotCoordinate,
        into existing: [SlotCoordinate],
        in pages: [BarPage]
    ) -> (updated: [SlotCoordinate], didPin: Bool) {
        let normalized = sanitize(existing, in: pages)
        guard isValidOccupiedCoordinate(coordinate, in: pages) else {
            return (normalized, false)
        }
        if normalized.contains(coordinate) {
            return (normalized, true)
        }
        guard normalized.count < maxPinnedCount else {
            return (normalized, false)
        }
        return (normalized + [coordinate], true)
    }

    public static func unpin(
        _ coordinate: SlotCoordinate,
        from existing: [SlotCoordinate],
        in pages: [BarPage]
    ) -> (updated: [SlotCoordinate], didUnpin: Bool) {
        let normalized = sanitize(existing, in: pages)
        let filtered = normalized.filter { $0 != coordinate }
        return (filtered, filtered.count != normalized.count)
    }

    public static func remapAfterSwap(
        coordinates: [SlotCoordinate],
        pageID: UUID,
        fromSlot: Int,
        toSlot: Int,
        in pages: [BarPage]
    ) -> [SlotCoordinate] {
        guard fromSlot != toSlot else {
            return sanitize(coordinates, in: pages)
        }
        let remapped = coordinates.map { coord -> SlotCoordinate in
            guard coord.pageID == pageID else { return coord }
            if coord.slotIndex == fromSlot {
                return SlotCoordinate(pageID: pageID, slotIndex: toSlot)
            } else if coord.slotIndex == toSlot {
                return SlotCoordinate(pageID: pageID, slotIndex: fromSlot)
            }
            return coord
        }
        return sanitize(remapped, in: pages)
    }

    public static func resolve(_ coordinates: [SlotCoordinate], in pages: [BarPage]) -> [ResolvedPinnedStripSlot] {
        let normalized = sanitize(coordinates, in: pages)
        var resolved: [ResolvedPinnedStripSlot] = []
        resolved.reserveCapacity(normalized.count)
        for coord in normalized {
            guard let pageIndex = pages.firstIndex(where: { $0.id == coord.pageID }) else { continue }
            let page = pages[pageIndex]
            guard page.slots.indices.contains(coord.slotIndex),
                  let item = page.slots[coord.slotIndex] else { continue }
            resolved.append(
                ResolvedPinnedStripSlot(
                    coordinate: coord,
                    pageIndex: pageIndex,
                    pageTitle: page.title,
                    pageEmoji: page.iconEmoji,
                    slotIndex: coord.slotIndex,
                    item: item
                )
            )
        }
        return resolved
    }
}

// MARK: - 3. Recently Triggered Tiles (Capped at 8 — Title & ID Only, Never Clipboard or Secrets)

public struct RecentlyTriggeredTileEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let maxEntries: Int = 8
    public static let maxTitleCharacters: Int = 80

    public let id: UUID
    public var title: String

    private enum CodingKeys: String, CodingKey {
        case id
        case title
    }

    public init(id: UUID, title: String) {
        self.id = id
        self.title = Self.sanitizeTitle(title)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        let rawTitle = try container.decode(String.self, forKey: .title)
        self.title = Self.sanitizeTitle(rawTitle)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(Self.sanitizeTitle(title), forKey: .title)
    }

    /// Ensures single-line display labels and strips query/fragment/credential parts if a raw URL was used as title.
    public static func sanitizeTitle(_ raw: String) -> String {
        let singleLine = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !singleLine.isEmpty else { return "" }

        if singleLine.contains("://"),
           let components = URLComponents(string: singleLine),
           let scheme = components.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           let host = components.host,
           !host.isEmpty {
            let cleanHost = host.replacingOccurrences(of: "www.", with: "")
            return String(cleanHost.prefix(maxTitleCharacters))
        }

        if singleLine.count > maxTitleCharacters {
            return String(singleLine.prefix(maxTitleCharacters))
        }
        return singleLine
    }
}

public struct RecentlyTriggeredTileList: Codable, Equatable, Sendable {
    public static let maxEntries: Int = RecentlyTriggeredTileEntry.maxEntries

    public private(set) var entries: [RecentlyTriggeredTileEntry]

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    public init(entries: [RecentlyTriggeredTileEntry] = []) {
        self.entries = Self.normalize(entries)
    }

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let decoded = try keyed.decodeIfPresent([RecentlyTriggeredTileEntry].self, forKey: .entries) {
            self.entries = Self.normalize(decoded)
            return
        }
        let single = try decoder.singleValueContainer()
        let decoded = (try? single.decode([RecentlyTriggeredTileEntry].self)) ?? []
        self.entries = Self.normalize(decoded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.normalize(entries), forKey: .entries)
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var count: Int {
        entries.count
    }

    public mutating func record(id: UUID, title: String) {
        let cleanTitle = RecentlyTriggeredTileEntry.sanitizeTitle(title)
        guard !cleanTitle.isEmpty else { return }
        var next = entries.filter { $0.id != id }
        next.insert(RecentlyTriggeredTileEntry(id: id, title: cleanTitle), at: 0)
        if next.count > Self.maxEntries {
            next = Array(next.prefix(Self.maxEntries))
        }
        entries = next
    }

    public mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    public static func normalize(_ raw: [RecentlyTriggeredTileEntry]) -> [RecentlyTriggeredTileEntry] {
        var result: [RecentlyTriggeredTileEntry] = []
        var seen = Set<UUID>()
        for entry in raw {
            let cleanTitle = RecentlyTriggeredTileEntry.sanitizeTitle(entry.title)
            guard !cleanTitle.isEmpty, !seen.contains(entry.id) else { continue }
            seen.insert(entry.id)
            result.append(RecentlyTriggeredTileEntry(id: entry.id, title: cleanTitle))
            if result.count >= maxEntries {
                break
            }
        }
        return result
    }
}
