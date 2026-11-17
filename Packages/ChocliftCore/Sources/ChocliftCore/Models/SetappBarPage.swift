import Foundation

public let SetappBarPageCount = 8

public enum SetappBarTileLayout: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case one
    case two
    case three
    case four

    public var id: String { rawValue }

    public var slotCount: Int {
        switch self {
        case .one: return 1
        case .two: return 2
        case .three: return 3
        case .four: return 4
        }
    }

    public var columnsPerRow: Int {
        switch self {
        case .one: return 1
        case .two: return 2
        case .three: return 3
        case .four: return 2
        }
    }

    public var rowCount: Int {
        switch self {
        case .one, .two, .three: return 1
        case .four: return 2
        }
    }

    public init?(slotCount: Int) {
        switch slotCount {
        case 1: self = .one
        case 2: self = .two
        case 3: self = .three
        case 4: self = .four
        default: return nil
        }
    }

    public var next: SetappBarTileLayout {
        switch self {
        case .one: return .two
        case .two: return .three
        case .three: return .four
        case .four: return .one
        }
    }

    public func title(in language: AppLanguage = .system) -> String {
        switch self {
        case .one: return L10n.tr("1 个分区", "One tile", language: language)
        case .two: return L10n.tr("2 个分区", "Two tiles", language: language)
        case .three: return L10n.tr("3 个分区", "Three tiles", language: language)
        case .four: return L10n.tr("4 个分区", "Four tiles", language: language)
        }
    }

    public func nextTitle(in language: AppLanguage = .system) -> String {
        switch self {
        case .one: return L10n.tr("接下来：2 个分区", "Next: Two tiles", language: language)
        case .two: return L10n.tr("接下来：3 个分区", "Next: Three tiles", language: language)
        case .three: return L10n.tr("接下来：4 个分区", "Next: Four tiles", language: language)
        case .four: return L10n.tr("接下来：1 个分区", "Next: One tile", language: language)
        }
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let rawString = try? single.decode(String.self) {
            let normalized = rawString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let matched = Self(rawValue: normalized) {
                self = matched
                return
            }
            if let count = Int(normalized), let matched = Self(slotCount: count) {
                self = matched
                return
            }
        } else if let count = try? single.decode(Int.self), let matched = Self(slotCount: count) {
            self = matched
            return
        }
        throw DecodingError.dataCorruptedError(
            in: single,
            debugDescription: "Invalid SetappBarTileLayout value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        try single.encode(rawValue)
    }
}

public enum SetappBarSlotKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case app
    case shortcut
    case website
    case emoji
    case empty
}

public struct SetappBarSlot: Codable, Equatable, Hashable, Identifiable, Sendable {
    public typealias Kind = SetappBarSlotKind

    public var id: UUID
    public private(set) var kind: SetappBarSlotKind
    public private(set) var bundleID: String?
    public private(set) var shortcutName: String?
    public private(set) var url: URL?
    public private(set) var emoji: String?
    public private(set) var displayName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case bundleID
        case bundleIdentifier
        case shortcutName
        case shortcutEmoji
        case url
        case emoji
        case displayName
    }

    private init(
        validatedID id: UUID,
        kind: SetappBarSlotKind,
        bundleID: String?,
        shortcutName: String?,
        url: URL?,
        emoji: String?,
        displayName: String?
    ) {
        self.id = id
        self.kind = kind
        self.bundleID = bundleID
        self.shortcutName = shortcutName
        self.url = url
        self.emoji = emoji
        self.displayName = displayName
    }

    public init(id: UUID = UUID()) {
        self.init(
            validatedID: id,
            kind: .empty,
            bundleID: nil,
            shortcutName: nil,
            url: nil,
            emoji: nil,
            displayName: nil
        )
    }

    public init?(
        id: UUID = UUID(),
        kind: SetappBarSlotKind,
        bundleID: String? = nil,
        shortcutName: String? = nil,
        url: URL? = nil,
        emoji: String? = nil,
        displayName: String? = nil
    ) {
        switch kind {
        case .empty:
            self.init(id: id)
        case .app:
            guard let bundleID,
                  let built = Self.app(id: id, bundleID: bundleID, displayName: displayName) else {
                return nil
            }
            self = built
        case .shortcut:
            guard let shortcutName,
                  let built = Self.shortcut(
                      id: id,
                      shortcutName: shortcutName,
                      emoji: emoji,
                      displayName: displayName
                  ) else {
                return nil
            }
            self = built
        case .website:
            guard let url else { return nil }
            self = Self.website(id: id, url: url, displayName: displayName)
        case .emoji:
            guard let emoji,
                  let built = Self.emoji(id: id, emoji, displayName: displayName) else {
                return nil
            }
            self = built
        }
    }

    public static var empty: SetappBarSlot {
        SetappBarSlot()
    }

    public static func makeEmpty(id: UUID = UUID()) -> SetappBarSlot {
        SetappBarSlot(id: id)
    }

    public static func isChocliftBundleID(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "com.choclift" || lower.hasPrefix("com.choclift.")
    }

    public static func isChocliftBundleIdentifier(_ raw: String) -> Bool {
        isChocliftBundleID(raw)
    }

    public static func app(
        id: UUID = UUID(),
        bundleID: String,
        displayName: String? = nil
    ) -> SetappBarSlot? {
        let trimmedBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleID.isEmpty, !isChocliftBundleID(trimmedBundleID) else {
            return nil
        }
        return SetappBarSlot(
            validatedID: id,
            kind: .app,
            bundleID: trimmedBundleID,
            shortcutName: nil,
            url: nil,
            emoji: nil,
            displayName: cleanText(displayName)
        )
    }

    public static func shortcut(
        id: UUID = UUID(),
        shortcutName: String,
        emoji: String? = nil,
        displayName: String? = nil
    ) -> SetappBarSlot? {
        let trimmedShortcut = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShortcut.isEmpty else {
            return nil
        }
        return SetappBarSlot(
            validatedID: id,
            kind: .shortcut,
            bundleID: nil,
            shortcutName: trimmedShortcut,
            url: nil,
            emoji: cleanSingleCharacter(emoji),
            displayName: cleanText(displayName)
        )
    }

    public static func shortcut(
        id: UUID = UUID(),
        name: String,
        emoji: String? = nil,
        displayName: String? = nil
    ) -> SetappBarSlot? {
        shortcut(id: id, shortcutName: name, emoji: emoji, displayName: displayName)
    }

    public static func website(
        id: UUID = UUID(),
        url: URL,
        displayName: String? = nil
    ) -> SetappBarSlot {
        SetappBarSlot(
            validatedID: id,
            kind: .website,
            bundleID: nil,
            shortcutName: nil,
            url: url,
            emoji: nil,
            displayName: cleanText(displayName)
        )
    }

    public static func website(
        id: UUID = UUID(),
        urlString: String,
        displayName: String? = nil
    ) -> SetappBarSlot? {
        guard let parsedURL = parseWebsiteURL(urlString) else {
            return nil
        }
        return website(id: id, url: parsedURL, displayName: displayName)
    }

    public static func emoji(
        id: UUID = UUID(),
        _ character: String,
        displayName: String? = nil
    ) -> SetappBarSlot? {
        guard let single = cleanSingleCharacter(character) else {
            return nil
        }
        return SetappBarSlot(
            validatedID: id,
            kind: .emoji,
            bundleID: nil,
            shortcutName: nil,
            url: nil,
            emoji: single,
            displayName: cleanText(displayName)
        )
    }

    public static func emoji(
        id: UUID = UUID(),
        emoji: String,
        displayName: String? = nil
    ) -> SetappBarSlot? {
        Self.emoji(id: id, emoji, displayName: displayName)
    }

    public static func emoji(
        id: UUID = UUID(),
        character: Character,
        displayName: String? = nil
    ) -> SetappBarSlot? {
        Self.emoji(id: id, String(character), displayName: displayName)
    }

    public var bundleIdentifier: String? { bundleID }
    public var urlString: String? { url?.absoluteString }
    public var emojiCharacter: Character? { emoji?.first }
    public var shortcutEmoji: String? { kind == .shortcut ? emoji : nil }
    public var isEmpty: Bool { kind == .empty }

    public var hasPayload: Bool {
        bundleID != nil || shortcutName != nil || url != nil || emoji != nil || displayName != nil
    }

    public var resolvedDisplayName: String? {
        if let displayName {
            return displayName
        }
        switch kind {
        case .app:
            return bundleID
        case .shortcut:
            return shortcutName
        case .website:
            if let host = url?.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            return url?.absoluteString
        case .emoji:
            return emoji
        case .empty:
            return nil
        }
    }

    public func sanitized() -> SetappBarSlot {
        SetappBarSlot(
            id: id,
            kind: kind,
            bundleID: bundleID,
            shortcutName: shortcutName,
            url: url,
            emoji: emoji,
            displayName: displayName
        ) ?? SetappBarSlot(id: id)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedKind = (try? container.decodeIfPresent(SetappBarSlotKind.self, forKey: .kind)) ?? .empty
        let rawBundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
            ?? container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        let rawShortcutName = try container.decodeIfPresent(String.self, forKey: .shortcutName)
        let rawURL: URL? = {
            if let direct = try? container.decodeIfPresent(URL.self, forKey: .url) {
                return direct
            }
            if let rawString = try? container.decodeIfPresent(String.self, forKey: .url) {
                return Self.parseWebsiteURL(rawString)
            }
            return nil
        }()
        let rawEmoji = try container.decodeIfPresent(String.self, forKey: .emoji)
            ?? container.decodeIfPresent(String.self, forKey: .shortcutEmoji)
        let rawDisplayName = try container.decodeIfPresent(String.self, forKey: .displayName)

        if let valid = SetappBarSlot(
            id: decodedID,
            kind: decodedKind,
            bundleID: rawBundleID,
            shortcutName: rawShortcutName,
            url: rawURL,
            emoji: rawEmoji,
            displayName: rawDisplayName
        ) {
            self = valid
        } else {
            self = SetappBarSlot(id: decodedID)
        }
    }

    public func encode(to encoder: Encoder) throws {
        let clean = sanitized()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clean.id, forKey: .id)
        try container.encode(clean.kind, forKey: .kind)
        if clean.kind != .empty {
            try container.encodeIfPresent(clean.bundleID, forKey: .bundleID)
            try container.encodeIfPresent(clean.shortcutName, forKey: .shortcutName)
            try container.encodeIfPresent(clean.url, forKey: .url)
            try container.encodeIfPresent(clean.emoji, forKey: .emoji)
            try container.encodeIfPresent(clean.displayName, forKey: .displayName)
        }
    }

    private static func cleanText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func cleanSingleCharacter(_ raw: String?) -> String? {
        guard let trimmed = cleanText(raw), let first = trimmed.first else {
            return nil
        }
        return String(first)
    }

    private static func parseWebsiteURL(_ raw: String) -> URL? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "https://", clean != "http://" else {
            return nil
        }
        if clean.contains("://") {
            guard let url = URL(string: clean),
                  let scheme = url.scheme,
                  !scheme.isEmpty else {
                return nil
            }
            if scheme == "http" || scheme == "https" {
                guard let host = url.host, !host.isEmpty else { return nil }
            }
            return url
        }
        let normalized = "https://\(clean)"
        guard let url = URL(string: normalized),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }
}

private struct SafeSetappBarSlotWrapper: Decodable {
    let slot: SetappBarSlot

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self.slot = .empty
            return
        }
        self.slot = (try? SetappBarSlot(from: decoder)) ?? .empty
    }
}

public struct SetappBarPage: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let pageCount = SetappBarPageCount
    public static let validIndexRange: ClosedRange<Int> = 0...(SetappBarPageCount - 1)

    public var id: UUID
    private var _index: Int
    public var index: Int {
        get { _index }
        set { _index = Self.clampIndex(newValue) }
    }
    public var layout: SetappBarTileLayout {
        didSet {
            slots = Self.sanitizeSlots(slots, for: layout)
        }
    }
    public var slots: [SetappBarSlot]

    private enum CodingKeys: String, CodingKey {
        case id
        case index
        case layout
        case slots
    }

    public init(
        id: UUID = UUID(),
        index: Int = 0,
        layout: SetappBarTileLayout = .one,
        slots: [SetappBarSlot] = []
    ) {
        self.id = id
        self._index = Self.clampIndex(index)
        self.layout = layout
        self.slots = Self.sanitizeSlots(slots, for: layout)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedIndex = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        self._index = Self.clampIndex(decodedIndex)
        let decodedLayout = (try? container.decodeIfPresent(SetappBarTileLayout.self, forKey: .layout)) ?? .one
        self.layout = decodedLayout
        let wrappedSlots = try container.decodeIfPresent([SafeSetappBarSlotWrapper].self, forKey: .slots) ?? []
        self.slots = Self.sanitizeSlots(wrappedSlots.map(\.slot), for: decodedLayout)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(_index, forKey: .index)
        try container.encode(layout, forKey: .layout)
        try container.encode(Self.sanitizeSlots(slots, for: layout), forKey: .slots)
    }

    public static func clampIndex(_ index: Int) -> Int {
        min(max(validIndexRange.lowerBound, index), validIndexRange.upperBound)
    }

    public static func sanitizeSlots(
        _ slots: [SetappBarSlot],
        for layout: SetappBarTileLayout
    ) -> [SetappBarSlot] {
        let targetCount = layout.slotCount
        var seenIDs = Set<UUID>()
        var result: [SetappBarSlot] = []
        result.reserveCapacity(targetCount)

        for candidate in slots.prefix(targetCount) {
            var clean = candidate.sanitized()
            if !seenIDs.insert(clean.id).inserted {
                clean.id = UUID()
                seenIDs.insert(clean.id)
            }
            result.append(clean)
        }

        while result.count < targetCount {
            var pad = SetappBarSlot.empty
            while !seenIDs.insert(pad.id).inserted {
                pad.id = UUID()
            }
            result.append(pad)
        }

        return result
    }

    public mutating func sanitize() {
        _index = Self.clampIndex(_index)
        slots = Self.sanitizeSlots(slots, for: layout)
    }

    public func sanitized() -> SetappBarPage {
        var copy = self
        copy.sanitize()
        return copy
    }

    public static func sanitize(_ page: SetappBarPage) -> SetappBarPage {
        page.sanitized()
    }

    public mutating func setLayout(_ newLayout: SetappBarTileLayout) {
        layout = newLayout
    }

    public mutating func cycleLayout() {
        layout = layout.next
    }

    public mutating func clear() {
        slots = (0..<layout.slotCount).map { _ in SetappBarSlot.empty }
    }

    @discardableResult
    public mutating func setSlot(_ slot: SetappBarSlot, at slotIndex: Int) -> Bool {
        sanitize()
        guard slots.indices.contains(slotIndex) else { return false }
        if slot.kind == .app {
            guard let bundleID = slot.bundleID,
                  !bundleID.isEmpty,
                  !SetappBarSlot.isChocliftBundleID(bundleID) else {
                return false
            }
        }
        var replacement = slot.sanitized()
        let collidesWithSibling = slots.enumerated().contains { offset, existing in
            offset != slotIndex && existing.id == replacement.id
        }
        if collidesWithSibling {
            replacement.id = UUID()
        }
        slots[slotIndex] = replacement
        return true
    }

    @discardableResult
    public mutating func setSlot(_ slot: SetappBarSlot?, at slotIndex: Int) -> Bool {
        guard let slot else { return false }
        return setSlot(slot, at: slotIndex)
    }

    @discardableResult
    public mutating func setSlot(at slotIndex: Int, to slot: SetappBarSlot) -> Bool {
        setSlot(slot, at: slotIndex)
    }

    @discardableResult
    public mutating func setSlot(at slotIndex: Int, to slot: SetappBarSlot?) -> Bool {
        setSlot(slot, at: slotIndex)
    }

    @discardableResult
    public mutating func moveSlot(from sourceIndex: Int, to destinationIndex: Int) -> Bool {
        sanitize()
        guard slots.indices.contains(sourceIndex),
              slots.indices.contains(destinationIndex) else {
            return false
        }
        guard sourceIndex != destinationIndex else {
            return true
        }
        let moved = slots.remove(at: sourceIndex)
        slots.insert(moved, at: destinationIndex)
        return true
    }

    public var isEmpty: Bool {
        slots.allSatisfy(\.isEmpty)
    }

    public var filledSlotCount: Int {
        slots.reduce(0) { $0 + ($1.isEmpty ? 0 : 1) }
    }

    public func title(in language: AppLanguage = .system) -> String {
        L10n.tr("第 \(_index + 1) 页", "Page \(_index + 1)", language: language)
    }

    public static func clearPageTitle(in language: AppLanguage = .system) -> String {
        L10n.tr("清空页面", "Clear Page", language: language)
    }

    public static func clearPageConfirmationMessage(in language: AppLanguage = .system) -> String {
        L10n.tr("要移除此页面的所有组件吗？", "Do you want to remove all pieces from this page?", language: language)
    }

    public static func movePageTitle(in language: AppLanguage = .system) -> String {
        L10n.tr("移动页面", "Move Page", language: language)
    }
}

private struct SafeSetappBarPageWrapper: Decodable {
    let page: SetappBarPage

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self.page = SetappBarPage(layout: .one)
            return
        }
        self.page = (try? SetappBarPage(from: decoder)) ?? SetappBarPage(layout: .one)
    }
}

public struct SetappBarBook: Codable, Equatable, Hashable, Sendable {
    public static let pageCount = SetappBarPageCount
    public static var empty: SetappBarBook { SetappBarBook() }

    private var _pages: [SetappBarPage]
    public var pages: [SetappBarPage] {
        get { _pages }
        set { _pages = Self.sanitizePages(newValue) }
    }

    private enum CodingKeys: String, CodingKey {
        case pages
        case book
    }

    public init(pages: [SetappBarPage] = []) {
        self._pages = Self.sanitizePages(pages)
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            self._pages = Self.sanitizePages([])
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let wrappedPages = try container.decodeIfPresent([SafeSetappBarPageWrapper].self, forKey: .pages) {
            self._pages = Self.sanitizePages(wrappedPages.map(\.page))
        } else if let nestedBook = try container.decodeIfPresent(SetappBarBook.self, forKey: .book) {
            self = nestedBook
        } else {
            self._pages = Self.sanitizePages([])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.sanitizePages(_pages), forKey: .pages)
    }

    public static func makeDefault() -> SetappBarBook {
        SetappBarBook()
    }

    public static func sanitizePages(_ candidates: [SetappBarPage]) -> [SetappBarPage] {
        var seenPageIDs = Set<UUID>()
        var result: [SetappBarPage] = []
        result.reserveCapacity(SetappBarPageCount)

        for candidate in candidates.prefix(SetappBarPageCount) {
            var clean = candidate.sanitized()
            if !seenPageIDs.insert(clean.id).inserted {
                clean.id = UUID()
                seenPageIDs.insert(clean.id)
            }
            clean.index = result.count
            result.append(clean)
        }

        while result.count < SetappBarPageCount {
            var pad = SetappBarPage(index: result.count, layout: .one)
            while !seenPageIDs.insert(pad.id).inserted {
                pad.id = UUID()
            }
            result.append(pad)
        }

        return result
    }

    public var isEmpty: Bool {
        _pages.allSatisfy(\.isEmpty)
    }

    public var filledSlotCount: Int {
        _pages.reduce(0) { $0 + $1.filledSlotCount }
    }

    public func page(at index: Int) -> SetappBarPage? {
        guard _pages.indices.contains(index) else { return nil }
        return _pages[index]
    }

    @discardableResult
    public mutating func setLayout(_ layout: SetappBarTileLayout, forPage pageIndex: Int) -> Bool {
        guard _pages.indices.contains(pageIndex) else { return false }
        _pages[pageIndex].setLayout(layout)
        return true
    }

    @discardableResult
    public mutating func movePage(from sourceIndex: Int, to destinationIndex: Int) -> Bool {
        guard _pages.indices.contains(sourceIndex),
              _pages.indices.contains(destinationIndex) else {
            return false
        }
        if sourceIndex != destinationIndex {
            let moved = _pages.remove(at: sourceIndex)
            _pages.insert(moved, at: destinationIndex)
        }
        for idx in _pages.indices {
            _pages[idx].index = idx
        }
        return true
    }

    @discardableResult
    public mutating func clearPage(index: Int) -> Bool {
        guard _pages.indices.contains(index) else { return false }
        _pages[index].clear()
        return true
    }

    @discardableResult
    public mutating func clearPage(at index: Int) -> Bool {
        clearPage(index: index)
    }

    @discardableResult
    public mutating func moveSlot(
        page pageIndex: Int,
        from sourceIndex: Int,
        to destinationIndex: Int
    ) -> Bool {
        guard _pages.indices.contains(pageIndex) else { return false }
        return _pages[pageIndex].moveSlot(from: sourceIndex, to: destinationIndex)
    }

    @discardableResult
    public mutating func setSlot(
        _ slot: SetappBarSlot,
        page pageIndex: Int,
        slot slotIndex: Int
    ) -> Bool {
        guard _pages.indices.contains(pageIndex) else { return false }
        return _pages[pageIndex].setSlot(slot, at: slotIndex)
    }

    @discardableResult
    public mutating func setSlot(
        _ slot: SetappBarSlot?,
        page pageIndex: Int,
        slot slotIndex: Int
    ) -> Bool {
        guard let slot else { return false }
        return setSlot(slot, page: pageIndex, slot: slotIndex)
    }

    @discardableResult
    public mutating func setSlot(
        page pageIndex: Int,
        slot slotIndex: Int,
        to value: SetappBarSlot
    ) -> Bool {
        setSlot(value, page: pageIndex, slot: slotIndex)
    }

    @discardableResult
    public mutating func setSlot(
        page pageIndex: Int,
        slot slotIndex: Int,
        to value: SetappBarSlot?
    ) -> Bool {
        setSlot(value, page: pageIndex, slot: slotIndex)
    }

    @discardableResult
    public mutating func clearSlot(page pageIndex: Int, slot slotIndex: Int) -> Bool {
        setSlot(.empty, page: pageIndex, slot: slotIndex)
    }
}

public extension KeyedDecodingContainer {
    func decode(_ type: SetappBarBook.Type, forKey key: Key) throws -> SetappBarBook {
        try decodeIfPresent(type, forKey: key) ?? SetappBarBook()
    }
}
