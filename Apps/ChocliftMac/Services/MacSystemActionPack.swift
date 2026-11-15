import AppKit
import ChocliftCore

enum MacSystemActionPack {
    static func run(id: String) -> (success: Bool, message: String) {
        (false, L10n.tr("尚未实现 \(id)", "Not implemented: \(id)"))
    }
}
