import AppKit
import ChocliftCore

enum MacMediaActionPack {
    static func run(id: String) -> (success: Bool, message: String) {
        (false, L10n.tr("尚未实现 \(id)", "Not implemented: \(id)"))
    }
}
