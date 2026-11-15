import AppKit
import Carbon.HIToolbox
import ChocliftCore
import CoreGraphics
import Foundation

enum MacEditActionPack {
    @MainActor
    private static let inputService = MacInputAndMediaService(
        windowService: MacAccessibilityAndWindowService()
    )

    static func run(id: String, preferredPID: pid_t?) -> (success: Bool, message: String) {
        guard let action = CompanionActionCatalog.editPack.first(where: { $0.id == id }),
              let stroke = EditCompanionActionRouting.keystroke(for: id) else {
            return (false, L10n.tr("不支持此操作", "Unsupported action"))
        }

        let sendResult: (success: Bool, message: String)
        if Thread.isMainThread {
            sendResult = MainActor.assumeIsolated {
                inputService.sendCompanionKeystroke(
                    virtualKey: stroke.virtualKey,
                    flags: stroke.flags,
                    preferredPID: preferredPID
                )
            }
        } else {
            sendResult = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    inputService.sendCompanionKeystroke(
                        virtualKey: stroke.virtualKey,
                        flags: stroke.flags,
                        preferredPID: preferredPID
                    )
                }
            }
        }

        guard sendResult.success else {
            return sendResult
        }

        return (
            true,
            L10n.tr(
                "已执行\(action.titleZh) (\(stroke.shortcutDisplay))",
                "Executed \(action.titleEn) (\(stroke.shortcutDisplay))"
            )
        )
    }
}
