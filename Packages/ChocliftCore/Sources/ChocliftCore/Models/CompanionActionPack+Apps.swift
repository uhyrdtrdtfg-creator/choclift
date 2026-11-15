import Foundation

public enum AppsCompanionActionID: String, CaseIterable, Equatable, Hashable, Sendable {
    case openLaunchpad = "apps.open_launchpad"
}

extension CompanionActionCatalog {
    public static let appsPack: [CompanionAction] = [
        CompanionAction(
            id: AppsCompanionActionID.openLaunchpad.rawValue,
            titleZh: "打开启动台",
            titleEn: "Open Launchpad",
            sfSymbol: "square.grid.3x3.fill"
        )
    ]
}

public enum AppsActionFailure: Error, Equatable, Sendable {
    case unknownAction(String)
    case launchpadNotFound
    case openFailed

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .unknownAction(let id):
            return L10n.tr("不支持的应用操作：\(id)", "Unsupported apps action: \(id)", language: language)
        case .launchpadNotFound:
            return L10n.tr("未找到启动台应用", "Launchpad app not found", language: language)
        case .openFailed:
            return L10n.tr("无法打开启动台", "Could not open Launchpad", language: language)
        }
    }
}

public enum AppsActionResolver {
    /// Ordered candidate bundle paths matching `MacInputAndMediaService.toggleLaunchpad` public open paths
    /// (macOS 13–15 Launchpad.app, then macOS 26+ Apps.app), with no synthetic keystroke fallback.
    public static let defaultLaunchpadCandidatePaths: [String] = [
        "/System/Applications/Launchpad.app",
        "/System/Applications/Apps.app"
    ]

    public static func resolveLaunchpadApplicationURL(
        candidatePaths: [String] = defaultLaunchpadCandidatePaths,
        fileManager: FileManager = .default
    ) -> Result<URL, AppsActionFailure> {
        for rawPath in candidatePaths {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: trimmed, isDirectory: &isDirectory), isDirectory.boolValue {
                return .success(URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL)
            }
        }
        return .failure(.launchpadNotFound)
    }

    public static func execute(
        id: String,
        language: AppLanguage = .system,
        candidatePaths: [String] = defaultLaunchpadCandidatePaths,
        fileManager: FileManager = .default,
        openApplication: (URL) -> Bool
    ) -> (success: Bool, message: String) {
        guard let action = AppsCompanionActionID(rawValue: id) else {
            return (false, AppsActionFailure.unknownAction(id).message(in: language))
        }

        switch action {
        case .openLaunchpad:
            switch resolveLaunchpadApplicationURL(candidatePaths: candidatePaths, fileManager: fileManager) {
            case .failure(let failure):
                return (false, failure.message(in: language))
            case .success(let appURL):
                guard openApplication(appURL) else {
                    return (false, AppsActionFailure.openFailed.message(in: language))
                }
                return (true, L10n.tr("已打开启动台", "Opened Launchpad", language: language))
            }
        }
    }
}
