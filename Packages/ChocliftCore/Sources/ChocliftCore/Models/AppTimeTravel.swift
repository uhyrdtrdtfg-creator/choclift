import Foundation

public enum AppTimeTravelPinError: String, Error, Codable, Equatable, Hashable, Sendable, LocalizedError {
    case pinLimit = "pin_limit"
    case rejectedBundleID = "rejected_bundle_id"

    public var messageKey: String { rawValue }

    public var errorDescription: String? {
        localizedMessage(in: .system)
    }

    public func localizedMessage(in language: AppLanguage = .system) -> String {
        switch self {
        case .pinLimit:
            return L10n.tr("最多只能固定 5 个 App", "Cannot pin more than 5 apps", language: language)
        case .rejectedBundleID:
            return L10n.tr("无法固定 choclift 自身", "Cannot pin choclift itself", language: language)
        }
    }
}

public struct AppTimeTravelEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var bundleID: String
    public var appName: String
    public var lastUsedAt: Date
    public var pinnedIndex: Int?

    public var id: String { bundleID }
    public var isPinned: Bool { pinnedIndex != nil }

    private enum CodingKeys: String, CodingKey {
        case bundleID
        case appName
        case lastUsedAt
        case pinnedIndex
    }

    public init(
        bundleID: String,
        appName: String,
        lastUsedAt: Date = Date(),
        pinnedIndex: Int? = nil
    ) {
        let trimmedID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleID = trimmedID
        self.appName = trimmedName.isEmpty ? trimmedID : trimmedName
        self.lastUsedAt = lastUsedAt
        if let pinnedIndex, (0..<AppTimeTravelBook.maxPins).contains(pinnedIndex) {
            self.pinnedIndex = pinnedIndex
        } else {
            self.pinnedIndex = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawBundleID = try container.decode(String.self, forKey: .bundleID)
        let rawAppName = try container.decodeIfPresent(String.self, forKey: .appName) ?? rawBundleID
        let rawLastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt) ?? Date(timeIntervalSince1970: 0)
        let rawPinnedIndex = try container.decodeIfPresent(Int.self, forKey: .pinnedIndex)
        self.init(
            bundleID: rawBundleID,
            appName: rawAppName,
            lastUsedAt: rawLastUsedAt,
            pinnedIndex: rawPinnedIndex
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(appName, forKey: .appName)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
        try container.encodeIfPresent(pinnedIndex, forKey: .pinnedIndex)
    }
}

public struct AppTimeTravelBook: Codable, Equatable, Hashable, Sendable {
    public static let maxRecentApps = 20
    public static let maxPins = 5
    public static let pinLimitMessageKey = AppTimeTravelPinError.pinLimit.rawValue
    public static let empty = AppTimeTravelBook()

    public private(set) var entries: [AppTimeTravelEntry]

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    public init(entries: [AppTimeTravelEntry] = []) {
        self.entries = Self.sanitize(entries)
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            self.entries = []
            return
        }
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            let rawEntries = try container.decodeIfPresent([AppTimeTravelEntry].self, forKey: .entries) ?? []
            self.entries = Self.sanitize(rawEntries)
            return
        }
        if let single = try? decoder.singleValueContainer(),
           let rawEntries = try? single.decode([AppTimeTravelEntry].self) {
            self.entries = Self.sanitize(rawEntries)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawEntries = try container.decodeIfPresent([AppTimeTravelEntry].self, forKey: .entries) ?? []
        self.entries = Self.sanitize(rawEntries)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }

    public static func decode(
        from data: Data?,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> AppTimeTravelBook {
        guard let data, !data.isEmpty else {
            return AppTimeTravelBook()
        }
        if let text = String(data: data, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppTimeTravelBook()
        }
        return try decoder.decode(AppTimeTravelBook.self, from: data)
    }

    public static func isChocliftBundleIdentifier(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "com.choclift" || lower.hasPrefix("com.choclift.")
    }

    public static func pinLimitMessage(in language: AppLanguage = .system) -> String {
        AppTimeTravelPinError.pinLimit.localizedMessage(in: language)
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var count: Int {
        entries.count
    }

    public var pinnedEntries: [AppTimeTravelEntry] {
        entries.filter(\.isPinned)
    }

    public var unpinnedEntries: [AppTimeTravelEntry] {
        entries.filter { !$0.isPinned }
    }

    public var pinnedCount: Int {
        entries.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }
    }

    public var canPinMore: Bool {
        pinnedCount < Self.maxPins
    }

    public var nextFreePinIndex: Int? {
        let usedIndices = Set(entries.compactMap(\.pinnedIndex))
        return (0..<Self.maxPins).first { !usedIndices.contains($0) }
    }

    public func entry(for bundleID: String) -> AppTimeTravelEntry? {
        let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return entries.first { $0.bundleID.lowercased() == key }
    }

    public func isPinned(_ bundleID: String) -> Bool {
        entry(for: bundleID)?.isPinned == true
    }

    /// Records activation of an app.
    /// - Unpinned apps move to the most-recent position and excess unpinned apps past 20 total are dropped.
    /// - Pinned apps never move and are never dropped to make room.
    /// - Rejects `com.choclift.*` and empty bundle identifiers.
    @discardableResult
    public mutating func recordActivation(
        bundleID: String,
        appName: String? = nil,
        at date: Date = Date()
    ) -> Bool {
        let trimmedID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !Self.isChocliftBundleIdentifier(trimmedID) else {
            return false
        }
        let trimmedName = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmedID.lowercased()

        if let existingIndex = entries.firstIndex(where: { $0.bundleID.lowercased() == key }) {
            if entries[existingIndex].isPinned {
                entries[existingIndex].lastUsedAt = date
                if let trimmedName, !trimmedName.isEmpty {
                    entries[existingIndex].appName = trimmedName
                }
                return true
            }

            var updated = entries.remove(at: existingIndex)
            updated.lastUsedAt = date
            if let trimmedName, !trimmedName.isEmpty {
                updated.appName = trimmedName
            }
            let pinned = entries.filter(\.isPinned)
            let unpinned = entries.filter { !$0.isPinned }
            entries = Self.sanitize(pinned + [updated] + unpinned)
            return true
        }

        let resolvedName: String
        if let trimmedName, !trimmedName.isEmpty {
            resolvedName = trimmedName
        } else {
            resolvedName = trimmedID
        }
        let inserted = AppTimeTravelEntry(
            bundleID: trimmedID,
            appName: resolvedName,
            lastUsedAt: date,
            pinnedIndex: nil
        )
        let pinned = entries.filter(\.isPinned)
        let unpinned = entries.filter { !$0.isPinned }
        entries = Self.sanitize(pinned + [inserted] + unpinned)
        return true
    }

    @discardableResult
    public mutating func recordActivation(
        _ bundleID: String,
        appName: String? = nil,
        at date: Date = Date()
    ) -> Bool {
        recordActivation(bundleID: bundleID, appName: appName, at: date)
    }

    @discardableResult
    public mutating func recordActivation(
        bundleID: String,
        appName: String,
        lastUsedAt: Date
    ) -> Bool {
        recordActivation(bundleID: bundleID, appName: appName, at: lastUsedAt)
    }

    /// Pins `bundleID` to the next free pin index in `0...4`.
    /// Fails with `.pinLimit` (`messageKey == "pin_limit"`) when 5 apps are already pinned.
    @discardableResult
    public mutating func pin(
        _ bundleID: String,
        appName: String? = nil,
        at date: Date = Date()
    ) -> Result<Int, AppTimeTravelPinError> {
        let trimmedID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !Self.isChocliftBundleIdentifier(trimmedID) else {
            return .failure(.rejectedBundleID)
        }
        let trimmedName = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmedID.lowercased()

        if let existingIndex = entries.firstIndex(where: { $0.bundleID.lowercased() == key }) {
            if let existingPin = entries[existingIndex].pinnedIndex {
                if let trimmedName, !trimmedName.isEmpty {
                    entries[existingIndex].appName = trimmedName
                }
                return .success(existingPin)
            }
            guard let freeIndex = nextFreePinIndex else {
                return .failure(.pinLimit)
            }
            entries[existingIndex].pinnedIndex = freeIndex
            if let trimmedName, !trimmedName.isEmpty {
                entries[existingIndex].appName = trimmedName
            }
            entries = Self.sanitize(entries)
            return .success(freeIndex)
        }

        guard let freeIndex = nextFreePinIndex else {
            return .failure(.pinLimit)
        }
        let resolvedName: String
        if let trimmedName, !trimmedName.isEmpty {
            resolvedName = trimmedName
        } else {
            resolvedName = trimmedID
        }
        let pinnedEntry = AppTimeTravelEntry(
            bundleID: trimmedID,
            appName: resolvedName,
            lastUsedAt: date,
            pinnedIndex: freeIndex
        )
        entries = Self.sanitize(entries + [pinnedEntry])
        return .success(freeIndex)
    }

    @discardableResult
    public mutating func pin(
        bundleID: String,
        appName: String? = nil,
        at date: Date = Date()
    ) -> Result<Int, AppTimeTravelPinError> {
        pin(bundleID, appName: appName, at: date)
    }

    /// Removes the pin on `bundleID` and returns it to recent order sorted by `lastUsedAt`.
    @discardableResult
    public mutating func unpin(_ bundleID: String) -> Bool {
        let trimmedID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !Self.isChocliftBundleIdentifier(trimmedID) else {
            return false
        }
        let key = trimmedID.lowercased()
        guard let existingIndex = entries.firstIndex(where: { $0.bundleID.lowercased() == key }),
              entries[existingIndex].isPinned else {
            return false
        }
        entries[existingIndex].pinnedIndex = nil
        entries = Self.sanitize(entries)
        return true
    }

    @discardableResult
    public mutating func unpin(bundleID: String) -> Bool {
        unpin(bundleID)
    }

    /// Removes all recent apps and pinned apps.
    public mutating func clearHistory() {
        entries.removeAll()
    }

    public static func sanitize(_ rawEntries: [AppTimeTravelEntry]) -> [AppTimeTravelEntry] {
        var deduplicated: [AppTimeTravelEntry] = []
        deduplicated.reserveCapacity(min(rawEntries.count, maxRecentApps))
        var indexByLowerBundleID: [String: Int] = [:]

        for raw in rawEntries {
            let trimmedID = raw.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty, !isChocliftBundleIdentifier(trimmedID) else {
                continue
            }
            let trimmedName = raw.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = trimmedName.isEmpty ? trimmedID : trimmedName
            let validPin = raw.pinnedIndex.flatMap { (0..<maxPins).contains($0) ? $0 : nil }
            let key = trimmedID.lowercased()

            if let existingIndex = indexByLowerBundleID[key] {
                if raw.lastUsedAt > deduplicated[existingIndex].lastUsedAt {
                    deduplicated[existingIndex].lastUsedAt = raw.lastUsedAt
                    if !trimmedName.isEmpty {
                        deduplicated[existingIndex].appName = resolvedName
                    }
                }
                if deduplicated[existingIndex].pinnedIndex == nil, let validPin {
                    deduplicated[existingIndex].pinnedIndex = validPin
                }
            } else {
                indexByLowerBundleID[key] = deduplicated.count
                deduplicated.append(
                    AppTimeTravelEntry(
                        bundleID: trimmedID,
                        appName: resolvedName,
                        lastUsedAt: raw.lastUsedAt,
                        pinnedIndex: validPin
                    )
                )
            }
        }

        var claimedPinIndices = Set<Int>()
        var pinned: [AppTimeTravelEntry] = []
        var unpinned: [AppTimeTravelEntry] = []

        for var entry in deduplicated {
            if let pinIndex = entry.pinnedIndex,
               (0..<maxPins).contains(pinIndex),
               claimedPinIndices.count < maxPins,
               claimedPinIndices.insert(pinIndex).inserted {
                pinned.append(entry)
            } else {
                entry.pinnedIndex = nil
                unpinned.append(entry)
            }
        }

        pinned.sort { ($0.pinnedIndex ?? 0) < ($1.pinnedIndex ?? 0) }
        unpinned.sort { $0.lastUsedAt > $1.lastUsedAt }

        let maxUnpinnedCount = max(0, maxRecentApps - pinned.count)
        let allowedUnpinned = Array(unpinned.prefix(maxUnpinnedCount))
        return pinned + allowedUnpinned
    }
}

public extension KeyedDecodingContainer {
    func decode(_ type: AppTimeTravelBook.Type, forKey key: Key) throws -> AppTimeTravelBook {
        try decodeIfPresent(type, forKey: key) ?? AppTimeTravelBook()
    }
}
