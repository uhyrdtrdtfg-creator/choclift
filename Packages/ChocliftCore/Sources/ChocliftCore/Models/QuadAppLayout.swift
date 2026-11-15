import CoreGraphics
import Foundation

public enum QuadCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// Visual 2×2 order: top row left-to-right, then bottom row.
    public static let editorOrder: [QuadCorner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    public var windowQuarterCorner: WindowQuarterCorner {
        switch self {
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        }
    }

    public var sfSymbol: String {
        switch self {
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        }
    }

    public func title(in lang: AppLanguage = .system) -> String {
        switch self {
        case .topLeft: return L10n.tr("左上", "Top Left", language: lang)
        case .topRight: return L10n.tr("右上", "Top Right", language: lang)
        case .bottomLeft: return L10n.tr("左下", "Bottom Left", language: lang)
        case .bottomRight: return L10n.tr("右下", "Bottom Right", language: lang)
        }
    }
}

public struct QuadAppSlot: Codable, Equatable, Hashable, Sendable {
    public var bundleIdentifier: String
    public var appName: String

    public init(bundleIdentifier: String, appName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
    }

    public static func isChocliftBundleIdentifier(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "com.choclift.mac" || lower.hasPrefix("com.choclift.")
    }

    public static func sanitized(_ slot: QuadAppSlot?) -> QuadAppSlot? {
        guard let slot else { return nil }
        let trimmedBundle = slot.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundle.isEmpty, !isChocliftBundleIdentifier(trimmedBundle) else {
            return nil
        }
        let trimmedName = slot.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? trimmedBundle : trimmedName
        return QuadAppSlot(bundleIdentifier: trimmedBundle, appName: resolvedName)
    }

    public static func resolveCompanionInput(
        _ rawText: String,
        recentApps: [RecentAppEntry]
    ) -> QuadAppSlot? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let matched = recentApps.first(where: {
            !isChocliftBundleIdentifier($0.bundleIdentifier) && (
                $0.appName.caseInsensitiveCompare(trimmed) == .orderedSame ||
                $0.bundleIdentifier.caseInsensitiveCompare(trimmed) == .orderedSame
            )
        }) {
            return sanitized(QuadAppSlot(bundleIdentifier: matched.bundleIdentifier, appName: matched.appName))
        }
        return sanitized(QuadAppSlot(bundleIdentifier: trimmed, appName: trimmed))
    }
}

public struct QuadAppLayout: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let maxLibraryCount = 6
    public static let maxNameLength = 24

    public var id: UUID
    public var name: String
    public var topLeft: QuadAppSlot?
    public var topRight: QuadAppSlot?
    public var bottomLeft: QuadAppSlot?
    public var bottomRight: QuadAppSlot?

    public init(
        id: UUID = UUID(),
        name: String,
        topLeft: QuadAppSlot? = nil,
        topRight: QuadAppSlot? = nil,
        bottomLeft: QuadAppSlot? = nil,
        bottomRight: QuadAppSlot? = nil
    ) {
        self.id = id
        self.name = name
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    public func slot(for corner: QuadCorner) -> QuadAppSlot? {
        switch corner {
        case .topLeft: return topLeft
        case .topRight: return topRight
        case .bottomLeft: return bottomLeft
        case .bottomRight: return bottomRight
        }
    }

    public mutating func setSlot(_ slot: QuadAppSlot?, for corner: QuadCorner) {
        switch corner {
        case .topLeft: topLeft = slot
        case .topRight: topRight = slot
        case .bottomLeft: bottomLeft = slot
        case .bottomRight: bottomRight = slot
        }
    }

    public var occupiedCorners: [(corner: QuadCorner, slot: QuadAppSlot)] {
        QuadCorner.allCases.compactMap { corner in
            guard let slot = slot(for: corner) else { return nil }
            return (corner, slot)
        }
    }

    public var containsChocliftBundle: Bool {
        QuadCorner.allCases.contains { corner in
            guard let slot = slot(for: corner) else { return false }
            return QuadAppSlot.isChocliftBundleIdentifier(slot.bundleIdentifier)
        }
    }

    public func summaryLine(in lang: AppLanguage = .system) -> String {
        occupiedCorners
            .map { "\($0.corner.title(in: lang)) \($0.slot.appName)" }
            .joined(separator: " · ")
    }

    public func quarterFrames(in visibleQuartz: CGRect) -> [(corner: QuadCorner, slot: QuadAppSlot, frame: CGRect)] {
        QuadCorner.allCases.compactMap { corner in
            guard let slot = slot(for: corner) else { return nil }
            let frame = WindowDisplayGeometry.quarterFrame(for: corner.windowQuarterCorner, visibleQuartz: visibleQuartz)
            return (corner: corner, slot: slot, frame: frame)
        }
    }

    public static func sanitized(_ layout: QuadAppLayout) -> QuadAppLayout? {
        let trimmedName = layout.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let clampedName = String(trimmedName.prefix(maxNameLength))

        let tl = QuadAppSlot.sanitized(layout.topLeft)
        let tr = QuadAppSlot.sanitized(layout.topRight)
        let bl = QuadAppSlot.sanitized(layout.bottomLeft)
        let br = QuadAppSlot.sanitized(layout.bottomRight)

        guard tl != nil || tr != nil || bl != nil || br != nil else {
            return nil
        }

        return QuadAppLayout(
            id: layout.id,
            name: clampedName,
            topLeft: tl,
            topRight: tr,
            bottomLeft: bl,
            bottomRight: br
        )
    }

    public static func sanitize(_ layouts: [QuadAppLayout]) -> [QuadAppLayout] {
        var seenIDs = Set<UUID>()
        var result: [QuadAppLayout] = []
        result.reserveCapacity(min(layouts.count, maxLibraryCount))
        for candidate in layouts {
            guard !seenIDs.contains(candidate.id) else { continue }
            guard let clean = sanitized(candidate) else { continue }
            seenIDs.insert(clean.id)
            result.append(clean)
            if result.count >= maxLibraryCount {
                break
            }
        }
        return result
    }
}
