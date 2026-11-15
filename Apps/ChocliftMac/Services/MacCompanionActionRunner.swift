import AppKit
import ChocliftCore

/// Dispatches extra companion actions by id. Each group file owns its own ids.
enum MacCompanionActionRunner {
    static func run(id: String, preferredPID: pid_t?) -> (success: Bool, message: String) {
        if CompanionActionCatalog.windowPack.contains(where: { $0.id == id }) {
            return MacWindowActionPack.run(id: id, preferredPID: preferredPID)
        }
        if CompanionActionCatalog.mediaPack.contains(where: { $0.id == id }) {
            return MacMediaActionPack.run(id: id)
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
        if id.hasPrefix("apps.") {
            return MacAppsActionPack.run(id: id)
        }
        if id.hasPrefix("display.") {
            return MacDisplayActionPack.run(id: id)
        }
        if id.hasPrefix("session.") {
            return MacSessionActionPack.run(id: id, preferredPID: preferredPID)
        }
        return (false, L10n.tr("不支持此操作", "Unsupported action"))
    }
}
