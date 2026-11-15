import AppKit
import ChocliftCore

enum MacSystemActionPack {
    static func run(
        id: String,
        language: AppLanguage = .system,
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> (success: Bool, message: String) {
        SystemSettingsAction.execute(id: id, language: language, openURL: openURL)
    }
}
