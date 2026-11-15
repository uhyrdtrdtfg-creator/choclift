import AppKit
import ChocliftCore
import Foundation

enum MacDisplayActionPack {
    private static let screenSaverEngineURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"
    )

    static func run(
        id: String,
        language: AppLanguage = .system,
        urlExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> (success: Bool, message: String) {
        DisplayCompanionAction.execute(
            id: id,
            language: language,
            screenSaverEngineURL: screenSaverEngineURL,
            urlExists: urlExists,
            openURL: openURL
        )
    }
}
