import AppKit
import ChocliftCore
import Foundation

enum MacFilesRecentActionPack {
    static func run(id: String) -> (success: Bool, message: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let action = FilesRecentCompanionActionID(rawValue: trimmed) else {
            return (false, FilesRecentActionFailure.unknownAction(trimmed).message())
        }

        switch action {
        case .openRecent:
            return openRecentFolder()
        case .openLatestDownload:
            return openLatestDownload()
        }
    }

    private static func openRecentFolder() -> (success: Bool, message: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let recentAliasDir = home.appendingPathComponent("Library/Recent", isDirectory: true)

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: recentAliasDir.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            guard NSWorkspace.shared.open(recentAliasDir) else {
                return (false, FilesRecentActionFailure.openFailed(path: recentAliasDir.path).message())
            }
            return (
                true,
                L10n.tr(
                    "已在访达中打开最近使用（\(recentAliasDir.path)）",
                    "Opened Recent Items in Finder (\(recentAliasDir.path))"
                )
            )
        }

        guard NSWorkspace.shared.open(home) else {
            return (false, FilesRecentActionFailure.openFailed(path: home.path).message())
        }
        return (
            true,
            L10n.tr(
                "未找到 \(recentAliasDir.path)，已在访达中打开个人目录（\(home.path)）",
                "\(recentAliasDir.path) not found; opened Home in Finder (\(home.path))"
            )
        )
    }

    private static func openLatestDownload() -> (success: Bool, message: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloadsURL = home.appendingPathComponent("Downloads", isDirectory: true)
        switch FilesRecentSelection.resolveLatestDownload(inDownloadsDirectory: downloadsURL) {
        case .failure(let failure):
            return (false, failure.message())
        case .success(let newestURL):
            guard NSWorkspace.shared.open(newestURL) else {
                return (false, FilesRecentActionFailure.openFailed(path: newestURL.path).message())
            }
            let displayName = FileManager.default.displayName(atPath: newestURL.path)
            return (
                true,
                L10n.tr(
                    "已打开最新下载：\(displayName)",
                    "Opened latest download: \(displayName)"
                )
            )
        }
    }
}
