import AppKit
import ChocliftCore
import CoreFoundation
import Foundation

enum MacFilesActionPack {
    private static let finderBundleIdentifier = "com.apple.finder"
    private static let screencaptureDomain = "com.apple.screencapture" as CFString
    private static let screencaptureLocationKey = "location" as CFString

    static func run(id: String) -> (success: Bool, message: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let action = FilesCompanionActionID(rawValue: trimmed) else {
            return (false, FilesActionFailure.unknownAction(trimmed).message())
        }

        switch action {
        case .openHome:
            return openResolvedFolder(for: .openHome, targetNameZh: "个人目录", targetNameEn: "Home")
        case .openDesktop:
            return openResolvedFolder(for: .openDesktop, targetNameZh: "桌面文件夹", targetNameEn: "Desktop")
        case .openDocuments:
            return openResolvedFolder(for: .openDocuments, targetNameZh: "文稿", targetNameEn: "Documents")
        case .openDownloads:
            return openResolvedFolder(for: .openDownloads, targetNameZh: "下载", targetNameEn: "Downloads")
        case .openApplications:
            return openResolvedFolder(for: .openApplications, targetNameZh: "应用程序", targetNameEn: "Applications")
        case .openScreenshots:
            let configuredLocation = CFPreferencesCopyAppValue(
                screencaptureLocationKey,
                screencaptureDomain
            ) as? String
            return openResolvedFolder(
                for: .openScreenshots,
                configuredScreenshotLocation: configuredLocation,
                targetNameZh: "截屏文件夹",
                targetNameEn: "Screenshots"
            )
        case .openICloud:
            return openResolvedFolder(for: .openICloud, targetNameZh: "iCloud 云盘", targetNameEn: "iCloud Drive")
        case .newFinderWindow:
            return openFinderApplication()
        case .revealFrontmostApp:
            return revealFrontmostApplication()
        case .openTrash:
            return openResolvedFolder(for: .openTrash, targetNameZh: "废纸篓", targetNameEn: "Trash")
        }
    }

    private static func openResolvedFolder(
        for action: FilesCompanionActionID,
        configuredScreenshotLocation: String? = nil,
        targetNameZh: String,
        targetNameEn: String
    ) -> (success: Bool, message: String) {
        let resolved = FilesActionResolver.resolveFolderURL(
            for: action,
            configuredScreenshotLocation: configuredScreenshotLocation
        )
        switch resolved {
        case .failure(let failure):
            return (false, failure.message())
        case .success(let folderURL):
            guard folderURL.isFileURL else {
                return (false, FilesActionFailure.openFailed(targetNameZh: targetNameZh, targetNameEn: targetNameEn).message())
            }
            guard NSWorkspace.shared.open(folderURL) else {
                return (false, FilesActionFailure.openFailed(targetNameZh: targetNameZh, targetNameEn: targetNameEn).message())
            }
            return (true, L10n.tr("已在访达中打开\(targetNameZh)", "Opened \(targetNameEn) in Finder"))
        }
    }

    private static func openFinderApplication() -> (success: Bool, message: String) {
        let fm = FileManager.default
        let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderBundleIdentifier)
            ?? fm.urls(for: .coreServiceDirectory, in: .systemDomainMask).first?
                .appendingPathComponent("Finder.app", isDirectory: true)

        guard let finderURL, finderURL.isFileURL, fm.fileExists(atPath: finderURL.path) else {
            return (false, FilesActionFailure.finderNotFound.message())
        }
        guard NSWorkspace.shared.open(finderURL) else {
            return (false, FilesActionFailure.openFailed(targetNameZh: "访达", targetNameEn: "Finder").message())
        }
        return (true, L10n.tr("已打开访达", "Opened Finder"))
    }

    private static func revealFrontmostApplication() -> (success: Bool, message: String) {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return (false, FilesActionFailure.noFrontmostApplication.message())
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let resolved = FilesActionResolver.resolveFrontmostAppRevealURL(
            bundleIdentifier: frontmost.bundleIdentifier,
            bundleURL: frontmost.bundleURL,
            isCurrentProcess: frontmost.processIdentifier == myPID
        )
        switch resolved {
        case .failure(let failure):
            return (false, failure.message())
        case .success(let appURL):
            guard FileManager.default.fileExists(atPath: appURL.path) else {
                return (false, FilesActionFailure.frontmostAppBundleMissing.message())
            }
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
            let appName = frontmost.localizedName ?? FileManager.default.displayName(atPath: appURL.path)
            return (true, L10n.tr("已在访达中显示 \(appName)", "Revealed \(appName) in Finder"))
        }
    }
}
