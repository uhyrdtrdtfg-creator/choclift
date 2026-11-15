import AppKit
import ChocliftCore
import Foundation

enum MacDisplayMoveActionPack {
    @MainActor
    private static let fallbackWindowService = MacAccessibilityAndWindowService()

    static func run(
        id: String,
        preferredPID: pid_t?,
        windowService: MacAccessibilityAndWindowService? = nil
    ) -> (success: Bool, message: String) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                runOnMainActor(id: id, preferredPID: preferredPID, windowService: windowService)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                runOnMainActor(id: id, preferredPID: preferredPID, windowService: windowService)
            }
        }
    }

    @MainActor
    private static func runOnMainActor(
        id: String,
        preferredPID: pid_t?,
        windowService: MacAccessibilityAndWindowService?
    ) -> (success: Bool, message: String) {
        guard id == DisplayMoveCompanionActionID.previousDisplay else {
            return (false, DisplayMoveActionFailure.unsupportedAction(id).message())
        }
        let targetService = windowService
            ?? MacAccessibilityAndWindowService.activeCoordinatorInstance
            ?? fallbackWindowService
        return targetService.performWindowOperation(
            .moveToPreviousDisplay,
            preferredPID: preferredPID
        )
    }
}
