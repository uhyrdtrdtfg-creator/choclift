import AppKit
import ChocliftCore
import Foundation

enum MacAppsActionPack {
    static func run(
        id: String,
        language: AppLanguage = .system,
        openApplication: (URL) -> Bool = { appURL in
            guard appURL.isFileURL else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        }
    ) -> (success: Bool, message: String) {
        AppsActionResolver.execute(
            id: id,
            language: language,
            openApplication: openApplication
        )
    }
}
