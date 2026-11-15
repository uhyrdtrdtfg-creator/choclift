import AppKit
import ChocliftCore

enum MacEditActionPack {
    static func run(id: String, preferredPID: pid_t?) -> (success: Bool, message: String) {
        _ = preferredPID
        return (false, L10n.tr("尚未实现 \(id)", "Not implemented: \(id)"))
    }
}
