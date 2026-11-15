import Foundation

public struct WatchPinnedAppCandidate: Equatable, Hashable, Identifiable, Sendable {
    public let bundleIdentifier: String
    public let appName: String
    public let appPath: String?

    public var id: String { bundleIdentifier.lowercased() }

    public init(bundleIdentifier: String, appName: String, appPath: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appPath = appPath
    }
}

public enum WatchPinnedApps {
    public static let maxCount = 4

    public static func isChocliftBundleIdentifier(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "com.choclift" || lower.hasPrefix("com.choclift.")
    }

    /// Sanitizes Watch pinned bundle IDs: trims whitespace, drops empty values and `com.choclift.*`,
    /// deduplicates case-insensitively while preserving first-seen order, and caps at 4.
    public static func sanitize(_ bundleIDs: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(min(bundleIDs.count, maxCount))
        var seenLowercased = Set<String>()

        for raw in bundleIDs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isChocliftBundleIdentifier(trimmed) else {
                continue
            }
            let key = trimmed.lowercased()
            guard seenLowercased.insert(key).inserted else {
                continue
            }
            result.append(trimmed)
            if result.count >= maxCount {
                break
            }
        }
        return result
    }

    /// Builds a sorted list of selectable Mac apps from installed catalog, recent apps, and synced profile metadata,
    /// excluding Choclift itself and any already-excluded bundle IDs.
    public static func candidateApps(
        catalogApps: [InstalledAppSummary] = [],
        recentApps: [RecentAppEntry] = [],
        profile: ChocliftWorkspaceProfile? = nil,
        excludingBundleIDs: [String] = []
    ) -> [WatchPinnedAppCandidate] {
        var seenLowercased = Set(
            excludingBundleIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        var candidates: [WatchPinnedAppCandidate] = []

        func appendCandidate(bundleID: String, preferredName: String?, appPath: String?) {
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isChocliftBundleIdentifier(trimmed) else { return }
            let key = trimmed.lowercased()
            guard seenLowercased.insert(key).inserted else { return }

            let resolvedName: String
            if let profile {
                resolvedName = profile.resolvedAppDisplayName(
                    forBundleIdentifier: trimmed,
                    preferredAppName: preferredName,
                    recentApps: recentApps,
                    catalogApps: catalogApps
                )
            } else if let name = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                resolvedName = name
            } else {
                resolvedName = trimmed
            }

            candidates.append(
                WatchPinnedAppCandidate(
                    bundleIdentifier: trimmed,
                    appName: resolvedName,
                    appPath: appPath
                )
            )
        }

        for app in catalogApps {
            appendCandidate(bundleID: app.bundleIdentifier, preferredName: app.appName, appPath: app.appPath)
        }

        for recent in recentApps {
            appendCandidate(bundleID: recent.bundleIdentifier, preferredName: recent.appName, appPath: recent.appPath)
        }

        if let profile {
            for bundleID in profile.referencedAppBundleIdentifiers.sorted() {
                appendCandidate(bundleID: bundleID, preferredName: nil, appPath: nil)
            }
        }

        return candidates.sorted { lhs, rhs in
            let order = lhs.appName.localizedStandardCompare(rhs.appName)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.bundleIdentifier.localizedStandardCompare(rhs.bundleIdentifier) == .orderedAscending
        }
    }
}
