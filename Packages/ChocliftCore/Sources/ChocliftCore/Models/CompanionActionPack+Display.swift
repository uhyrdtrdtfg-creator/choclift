import Foundation

public enum DisplayCompanionAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case startScreenSaver = "display.start_screensaver"

    public static let screenSaverEnginePath = "/System/Library/CoreServices/ScreenSaverEngine.app"

    public static var screenSaverEngineURL: URL {
        URL(fileURLWithPath: screenSaverEnginePath)
    }

    public var companionAction: CompanionAction {
        switch self {
        case .startScreenSaver:
            return CompanionAction(
                id: rawValue,
                titleZh: "启动屏幕保护",
                titleEn: "Start Screen Saver",
                sfSymbol: "sparkles.tv"
            )
        }
    }

    public static func execute(
        id: String,
        language: AppLanguage = .system,
        screenSaverEngineURL: URL = DisplayCompanionAction.screenSaverEngineURL,
        urlExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        openURL: (URL) -> Bool
    ) -> (success: Bool, message: String) {
        guard let action = DisplayCompanionAction(rawValue: id) else {
            return (
                false,
                L10n.tr("不支持的显示操作", "Unsupported display action", language: language)
            )
        }

        switch action {
        case .startScreenSaver:
            guard screenSaverEngineURL.isFileURL, urlExists(screenSaverEngineURL) else {
                return (
                    false,
                    L10n.tr("未找到屏幕保护程序", "ScreenSaverEngine.app not found", language: language)
                )
            }
            guard openURL(screenSaverEngineURL) else {
                return (
                    false,
                    L10n.tr("无法启动屏幕保护", "Could not start screen saver", language: language)
                )
            }
            return (
                true,
                L10n.tr("已启动屏幕保护", "Started Screen Saver", language: language)
            )
        }
    }
}

extension CompanionActionCatalog {
    public static let displayPack: [CompanionAction] = DisplayCompanionAction.allCases.map(\.companionAction)
}
