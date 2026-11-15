import AppKit
import ChocliftCore

/// Dispatches extra companion actions by id. Each group file owns its own ids.
enum MacCompanionActionRunner {
    static func run(id: String, preferredPID: pid_t?) -> (success: Bool, message: String) {
        if id == SessionShowCompanionAction.showAllApps.rawValue {
            return MacSessionShowActionPack.run(id: id)
        }
        if CompanionActionCatalog.windowPack.contains(where: { $0.id == id }) {
            return MacWindowActionPack.run(id: id, preferredPID: preferredPID)
        }
        if CompanionActionCatalog.displayMovePack.contains(where: { $0.id == id }) {
            return MacDisplayMoveActionPack.run(id: id, preferredPID: preferredPID)
        }
        if CompanionActionCatalog.mediaPack.contains(where: { $0.id == id }) {
            return MacMediaActionPack.run(id: id)
        }
        if id == FilesRecentCompanionActionID.openRecent.rawValue
            || id == FilesRecentCompanionActionID.openLatestDownload.rawValue {
            return MacFilesRecentActionPack.run(id: id)
        }
        if CompanionActionCatalog.filesPack.contains(where: { $0.id == id }) {
            return MacFilesActionPack.run(id: id)
        }
        if CompanionActionCatalog.editPack.contains(where: { $0.id == id }) {
            return MacEditActionPack.run(id: id, preferredPID: preferredPID)
        }
        if CompanionActionCatalog.systemPack.contains(where: { $0.id == id }) {
            return MacSystemActionPack.run(id: id)
        }
        if CompanionActionCatalog.finderDockPack.contains(where: { $0.id == id }) {
            return MacFinderDockActionPack.run(id: id)
        if id == AppSettingsCompanionActionID.openSettings {
            return MacAppSettingsActionPack.run(id: id, preferredPID: preferredPID)
        }
        if id.hasPrefix("apps.") {
            return MacAppsActionPack.run(id: id)
        }
        if id.hasPrefix("display.") {
            return MacDisplayActionPack.run(id: id)
        }
        if id.hasPrefix("session.") {
            return MacSessionActionPack.run(id: id, preferredPID: preferredPID)
        }
        if CompanionActionCatalog.speechPack.contains(where: { $0.id == id }) {
            return MacSpeechActionPack.run(id: id)
        if CompanionActionCatalog.capturePack.contains(where: { $0.id == id }) || id.hasPrefix("capture.") {
            return MacCaptureActionPack.run(id: id, preferredPID: preferredPID)
        if CompanionActionCatalog.windowTitlePack.contains(where: { $0.id == id }) {
            return MacWindowTitleActionPack.run(id: id, preferredPID: preferredPID)
        }
        return (false, L10n.tr("不支持此操作", "Unsupported action"))
    }
}
