import Foundation

public enum FilesRecentCompanionActionID: String, CaseIterable, Sendable {
    case openRecent = "files.open_recent"
    case openLatestDownload = "files.open_latest_download"
}

extension CompanionActionCatalog {
    public static let filesRecentPack: [CompanionAction] = [
        CompanionAction(
            id: FilesRecentCompanionActionID.openRecent.rawValue,
            titleZh: "打开最近使用",
            titleEn: "Open Recent Items",
            sfSymbol: "clock.arrow.circlepath"
        ),
        CompanionAction(
            id: FilesRecentCompanionActionID.openLatestDownload.rawValue,
            titleZh: "打开最新下载",
            titleEn: "Open Latest Download",
            sfSymbol: "arrow.down.doc.fill"
        )
    ]
}

public enum FilesRecentActionFailure: Error, Equatable, Sendable {
    case unknownAction(String)
    case downloadsMissing
    case downloadsEmpty
    case openFailed(path: String)

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .unknownAction(let id):
            return L10n.tr("不支持的最近文件操作：\(id)", "Unsupported recent files action: \(id)", language: language)
        case .downloadsMissing:
            return L10n.tr("下载文件夹不存在", "Downloads folder does not exist", language: language)
        case .downloadsEmpty:
            return L10n.tr("下载文件夹中没有可打开的文件", "No regular files found in Downloads", language: language)
        case .openFailed(let path):
            return L10n.tr("无法打开 \(path)", "Could not open \(path)", language: language)
        }
    }
}

public enum FilesRecentSelection {
    public struct Candidate: Equatable, Hashable, Sendable {
        public var url: URL
        public var modificationDate: Date
        public var isRegularFile: Bool
        public var isPackage: Bool
        public var isHidden: Bool

        public init(
            url: URL,
            modificationDate: Date,
            isRegularFile: Bool = true,
            isPackage: Bool = false,
            isHidden: Bool = false
        ) {
            self.url = url
            self.modificationDate = modificationDate
            self.isRegularFile = isRegularFile
            self.isPackage = isPackage
            self.isHidden = isHidden
        }
    }

    public static func recentFiles(in candidates: [Candidate], limit: Int = 8) -> [URL] {
        guard limit > 0 else { return [] }
        let eligible = candidates.filter { candidate in
            let name = candidate.url.lastPathComponent
            guard !name.isEmpty, !name.hasPrefix(".") else { return false }
            return candidate.isRegularFile && !candidate.isPackage && !candidate.isHidden
        }
        let sorted = eligible.sorted { lhs, rhs in
            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate > rhs.modificationDate
            }
            return lhs.url.path < rhs.url.path
        }
        return Array(sorted.prefix(limit).map(\.url))
    }

    public static func newestFile(in candidates: [Candidate]) -> URL? {
        recentFiles(in: candidates, limit: 1).first
    }

    public static func resolveRecentFolderTarget(
        homeDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> (url: URL, usedHomeFallback: Bool) {
        let recentAliasDir = homeDirectoryURL.appendingPathComponent("Library/Recent", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: recentAliasDir.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return (recentAliasDir, false)
        }
        return (homeDirectoryURL, true)
    }

    public static func candidates(
        inDirectory directoryURL: URL,
        fileManager: FileManager = .default
    ) -> [Candidate] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isPackageKey,
            .isHiddenKey,
            .contentModificationDateKey
        ]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        let keySet = Set(keys)
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: keySet)
            let isRegularFile = values?.isRegularFile ?? false
            let isPackage = values?.isPackage ?? false
            let isHidden = (values?.isHidden ?? false) || url.lastPathComponent.hasPrefix(".")
            let modDate = values?.contentModificationDate
                ?? ((try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
            guard let modificationDate = modDate else { return nil }
            return Candidate(
                url: url.standardizedFileURL,
                modificationDate: modificationDate,
                isRegularFile: isRegularFile,
                isPackage: isPackage,
                isHidden: isHidden
            )
        }
    }

    public static func recentUserFiles(
        homeDirectoryURL: URL,
        limit: Int = 8,
        fileManager: FileManager = .default
    ) -> [URL] {
        let folderNames = ["Documents", "Desktop", "Downloads"]
        let allCandidates = folderNames.flatMap { name in
            candidates(
                inDirectory: homeDirectoryURL.appendingPathComponent(name, isDirectory: true),
                fileManager: fileManager
            )
        }
        return recentFiles(in: allCandidates, limit: limit)
    }

    public static func resolveLatestDownload(
        inDownloadsDirectory downloadsURL: URL,
        fileManager: FileManager = .default
    ) -> Result<URL, FilesRecentActionFailure> {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: downloadsURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.downloadsMissing)
        }
        let items = candidates(inDirectory: downloadsURL, fileManager: fileManager)
        guard let newest = newestFile(in: items) else {
            return .failure(.downloadsEmpty)
        }
        return .success(newest)
    }
}
