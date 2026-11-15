import CoreGraphics
import Foundation

public enum DisplayMoveCompanionActionID {
    public static let previousDisplay = "window.previous_display"
}

public enum DisplayMoveActionFailure: Error, Equatable, Sendable, LocalizedError {
    case unsupportedAction(String)
    case singleDisplay

    public var errorDescription: String? {
        message(in: .system)
    }

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .unsupportedAction(let id):
            return L10n.tr(
                "不支持此屏幕移动操作：\(id)",
                "Unsupported display move action: \(id)",
                language: language
            )
        case .singleDisplay:
            return L10n.tr(
                "当前仅连接一块屏幕，无法移到上一块屏幕",
                "Only one display connected; cannot move to previous display",
                language: language
            )
        }
    }
}

public enum DisplayMoveCompanionExecution {
    public static func execute<WindowID: Hashable & Sendable>(
        id: String,
        coordinator: inout WindowMoveCoordinator<WindowID>,
        windowID: WindowID,
        appName: String,
        appKitScreens: [WindowScreenDescriptor],
        screenNames: [String] = [],
        allowResize: Bool = true,
        language: AppLanguage = .system,
        readFrame: () -> Result<CGRect, WindowAXStatusError>,
        writeFrame: (CGRect) -> Int32
    ) -> (success: Bool, message: String, plan: NextDisplayTargetPlan?) {
        guard id == DisplayMoveCompanionActionID.previousDisplay else {
            return (false, DisplayMoveActionFailure.unsupportedAction(id).message(in: language), nil)
        }

        let result = coordinator.performMoveToPreviousDisplay(
            windowID: windowID,
            appName: appName,
            appKitScreens: appKitScreens,
            allowResize: allowResize,
            readFrame: readFrame,
            writeFrame: writeFrame
        )
        switch result {
        case .success(let plan):
            let destinationName = screenNames.indices.contains(plan.targetScreenIndex)
                ? screenNames[plan.targetScreenIndex]
                : L10n.tr("上一块屏幕", "Previous Display", language: language)
            let summary = L10n.tr(
                "已将 \(appName) 窗口移至 \(destinationName)",
                "Moved \(appName) window to \(destinationName)",
                language: language
            )
            return (true, summary, plan)
        case .failure(let err):
            switch err {
            case .noSecondaryDisplay:
                return (false, DisplayMoveActionFailure.singleDisplay.message(in: language), nil)
            case .axError:
                return (false, err.message(in: language), nil)
            }
        }
    }
}

extension CompanionActionCatalog {
    public static let displayMovePack: [CompanionAction] = [
        CompanionAction(
            id: DisplayMoveCompanionActionID.previousDisplay,
            titleZh: "移到上一块屏幕",
            titleEn: "Previous Display",
            sfSymbol: "display.2"
        )
    ]
}
