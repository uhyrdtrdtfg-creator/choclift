import Foundation

public enum FilesCompanionActionID: String, CaseIterable, Sendable {
    case openHome = "files.open_home"
    case openDesktop = "files.open_desktop"
    case openDocuments = "files.open_documents"
    case openDownloads = "files.open_downloads"
    case openApplications = "files.open_applications"
    case openScreenshots = "files.open_screenshots"
    case openICloud = "files.open_icloud"
    case newFinderWindow = "files.new_finder_window"
    case revealFrontmostApp = "files.reveal_frontmost_app"
    case openTrash = "files.open_trash"
}

extension CompanionActionCatalog {
    public static let filesPack: [CompanionAction] = [
        CompanionAction(
            id: FilesCompanionActionID.openHome.rawValue,
            titleZh: "打开个人目录",
            titleEn: "Open Home",
            sfSymbol: "house.fill"
        ),
        CompanionAction(
            id: FilesCompanionActionID.openDesktop.rawValue,
            titleZh: "打开桌面文件夹",
            titleEn: "Open Desktop",
            sfSymbol: "desktopcomputer"
        ),
        CompanionAction(
            id: FilesCompanionActionID.openDocuments.rawValue,
            titleZh: "打开文稿",
            titleEn: "Open Documents",
            sfSymbol: "folder.fill"
        ),
        CompanionAction(
            id: FilesCompanionActionID.openDownloads.rawValue,
            titleZh: "打开下载",
            titleEn: "Open Downloads",
            sfSymbol: "arrow.down.circle.fill"
        ),
        CompanionAction(
            id: FilesCompanionActionID.openApplications.rawValue,
            titleZh: "打开应用程序",
            titleEn: "Open Applications",
            sfSymbol: "square.grid.2x2.fill"
        ),
        CompanionAction(
            id: FilesCompanionActionID.openScreenshots.rawValue,
            titleZh: "打开截屏文件夹",
            titleEn: "Open Screenshots",
            sfSymbol: "photo.on.rectangle"
        ),
        CompanionAction(
            id: FilesCompanionActionID.openICloud.rawValue,
            titleZh: "打开 iCloud 云盘",
            titleEn: "Open iCloud Drive",
            sfSymbol: "icloud.fill"
        ),
        CompanionAction(
            id: FilesCompanionActionID.newFinderWindow.rawValue,
            titleZh: "新建访达窗口",
            titleEn: "New Finder Window",
            sfSymbol: "folder.badge.plus"
        ),
        CompanionAction(
            id: FilesCompanionActionID.revealFrontmostApp.rawValue,
            titleZh: "在访达中显示当前应用",
            titleEn: "Reveal Frontmost App",
            sfSymbol: "magnifyingglass.circle.fill"
        ),
        CompanionAction(
            id: FilesCompanionActionID.openTrash.rawValue,
            titleZh: "打开废纸篓",
            titleEn: "Open Trash",
            sfSymbol: "trash.fill"
        )
    ]
}

public enum FilesActionFailure: Error, Equatable, Sendable {
    case unknownAction(String)
    case directoryMissing(folderNameZh: String, folderNameEn: String)
    case screenshotsAndDesktopMissing
    case noFrontmostApplication
    case frontmostAppIsChoclift
    case frontmostAppMissingBundleURL
    case frontmostAppBundleMissing
    case finderNotFound
    case openFailed(targetNameZh: String, targetNameEn: String)

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .unknownAction(let id):
            return L10n.tr("不支持的文件操作：\(id)", "Unsupported files action: \(id)", language: language)
        case .directoryMissing(let zh, let en):
            return L10n.tr("\(zh)不存在", "\(en) does not exist", language: language)
        case .screenshotsAndDesktopMissing:
            return L10n.tr("截屏文件夹与桌面文件夹均不存在", "Screenshots folder and Desktop folder do not exist", language: language)
        case .noFrontmostApplication:
            return L10n.tr("未找到当前前台应用", "No frontmost application found", language: language)
        case .frontmostAppIsChoclift:
            return L10n.tr("当前前台应用是 Choclift，请先切换到其他应用", "Frontmost app is Choclift; switch to another app first", language: language)
        case .frontmostAppMissingBundleURL:
            return L10n.tr("当前前台应用没有应用包路径", "Frontmost app has no bundle URL", language: language)
        case .frontmostAppBundleMissing:
            return L10n.tr("找不到当前前台应用的应用包", "Frontmost app bundle does not exist", language: language)
        case .finderNotFound:
            return L10n.tr("未找到访达应用", "Finder app not found", language: language)
        case .openFailed(let zh, let en):
            return L10n.tr("无法在访达中打开\(zh)", "Could not open \(en) in Finder", language: language)
        }
    }
}

public enum FilesActionResolver {
    public static func resolveScreenshotsFolder(
        configuredLocation: String?,
        homeDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Result<URL, FilesActionFailure> {
        let baseHome = (homeDirectoryURL ?? defaultHomeDirectoryURL(fileManager: fileManager)).standardizedFileURL
        if let raw = configuredLocation?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let candidateURL = resolveConfiguredLocationURL(raw, homeDirectoryURL: baseHome),
           isExistingDirectory(candidateURL, fileManager: fileManager) {
            return .success(candidateURL.standardizedFileURL)
        }

        let desktopURL = userSubdirectoryURL(
            searchPath: .desktopDirectory,
            componentName: "Desktop",
            homeDirectoryURL: homeDirectoryURL,
            fileManager: fileManager
        )
        guard isExistingDirectory(desktopURL, fileManager: fileManager) else {
            return .failure(.screenshotsAndDesktopMissing)
        }
        return .success(desktopURL.standardizedFileURL)
    }

    public static func resolveFrontmostAppRevealURL(
        bundleIdentifier: String?,
        bundleURL: URL?,
        isCurrentProcess: Bool = false
    ) -> Result<URL, FilesActionFailure> {
        if isCurrentProcess {
            return .failure(.frontmostAppIsChoclift)
        }
        if let bundleIdentifier, ActionFlowStep.isChocliftBundleIdentifier(bundleIdentifier) {
            return .failure(.frontmostAppIsChoclift)
        }
        guard let bundleURL, bundleURL.isFileURL, !bundleURL.path.isEmpty else {
            return .failure(.frontmostAppMissingBundleURL)
        }
        return .success(bundleURL.standardizedFileURL)
    }

    public static func resolveFolderURL(
        for action: FilesCompanionActionID,
        configuredScreenshotLocation: String? = nil,
        homeDirectoryURL: URL? = nil,
        applicationsDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Result<URL, FilesActionFailure> {
        switch action {
        case .openHome:
            let url = (homeDirectoryURL ?? defaultHomeDirectoryURL(fileManager: fileManager)).standardizedFileURL
            return verifiedDirectory(url, folderNameZh: "个人目录", folderNameEn: "Home folder", fileManager: fileManager)

        case .openDesktop:
            let url = userSubdirectoryURL(
                searchPath: .desktopDirectory,
                componentName: "Desktop",
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )
            return verifiedDirectory(url, folderNameZh: "桌面文件夹", folderNameEn: "Desktop folder", fileManager: fileManager)

        case .openDocuments:
            let url = userSubdirectoryURL(
                searchPath: .documentDirectory,
                componentName: "Documents",
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )
            return verifiedDirectory(url, folderNameZh: "文稿文件夹", folderNameEn: "Documents folder", fileManager: fileManager)

        case .openDownloads:
            let url = userSubdirectoryURL(
                searchPath: .downloadsDirectory,
                componentName: "Downloads",
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )
            return verifiedDirectory(url, folderNameZh: "下载文件夹", folderNameEn: "Downloads folder", fileManager: fileManager)

        case .openApplications:
            guard let url = applicationsDirectoryURL
                ?? fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first else {
                return .failure(.directoryMissing(folderNameZh: "应用程序文件夹", folderNameEn: "Applications folder"))
            }
            return verifiedDirectory(url, folderNameZh: "应用程序文件夹", folderNameEn: "Applications folder", fileManager: fileManager)

        case .openScreenshots:
            return resolveScreenshotsFolder(
                configuredLocation: configuredScreenshotLocation,
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )

        case .openICloud:
            let libraryURL = userSubdirectoryURL(
                searchPath: .libraryDirectory,
                componentName: "Library",
                homeDirectoryURL: homeDirectoryURL,
                fileManager: fileManager
            )
            let icloudURL = libraryURL.appendingPathComponent("Mobile Documents", isDirectory: true)
            return verifiedDirectory(icloudURL, folderNameZh: "iCloud 云盘目录", folderNameEn: "iCloud Drive folder", fileManager: fileManager)

        case .openTrash:
            let baseHome = (homeDirectoryURL ?? defaultHomeDirectoryURL(fileManager: fileManager)).standardizedFileURL
            let trashURL = baseHome.appendingPathComponent(".Trash", isDirectory: true)
            return verifiedDirectory(trashURL, folderNameZh: "废纸篓目录", folderNameEn: "Trash folder", fileManager: fileManager)

        case .newFinderWindow, .revealFrontmostApp:
            return .failure(.unknownAction(action.rawValue))
        }
    }

    private static func defaultHomeDirectoryURL(fileManager: FileManager) -> URL {
        #if os(macOS)
        return fileManager.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    private static func userSubdirectoryURL(
        searchPath: FileManager.SearchPathDirectory,
        componentName: String,
        homeDirectoryURL: URL?,
        fileManager: FileManager
    ) -> URL {
        if let homeDirectoryURL {
            return homeDirectoryURL.appendingPathComponent(componentName, isDirectory: true)
        }
        return fileManager.urls(for: searchPath, in: .userDomainMask).first
            ?? defaultHomeDirectoryURL(fileManager: fileManager).appendingPathComponent(componentName, isDirectory: true)
    }

    private static func verifiedDirectory(
        _ url: URL,
        folderNameZh: String,
        folderNameEn: String,
        fileManager: FileManager
    ) -> Result<URL, FilesActionFailure> {
        guard url.isFileURL, isExistingDirectory(url, fileManager: fileManager) else {
            return .failure(.directoryMissing(folderNameZh: folderNameZh, folderNameEn: folderNameEn))
        }
        return .success(url.standardizedFileURL)
    }

    private static func isExistingDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func resolveConfiguredLocationURL(_ raw: String, homeDirectoryURL: URL) -> URL? {
        if raw == "~" {
            return homeDirectoryURL.standardizedFileURL
        }
        if raw.hasPrefix("~") {
            let components = (raw as NSString).pathComponents
            if components.first == "~" {
                var resolved = homeDirectoryURL
                for component in components.dropFirst() where !component.isEmpty && component != "/" {
                    resolved = resolved.appendingPathComponent(component, isDirectory: true)
                }
                return resolved.standardizedFileURL
            }
            let expanded = (raw as NSString).expandingTildeInPath
            guard (expanded as NSString).isAbsolutePath else { return nil }
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        guard (raw as NSString).isAbsolutePath else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }
}
