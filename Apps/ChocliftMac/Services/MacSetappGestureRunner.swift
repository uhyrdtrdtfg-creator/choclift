import AppKit
import ChocliftCore
import Foundation

@MainActor
public final class MacSetappGestureRunner {
    private let windowService: MacAccessibilityAndWindowService
    private let inputService: MacInputAndMediaService
    private let clipboardService: MacClipboardMonitorService

    public init(
        windowService: MacAccessibilityAndWindowService? = nil,
        inputService: MacInputAndMediaService? = nil,
        clipboardService: MacClipboardMonitorService? = nil
    ) {
        let resolvedWindowService = windowService ?? MacAccessibilityAndWindowService()
        self.windowService = resolvedWindowService
        self.inputService = inputService ?? MacInputAndMediaService(windowService: resolvedWindowService)
        self.clipboardService = clipboardService ?? MacClipboardMonitorService()
    }

    public func perform(
        fingers: SetappFingerCount,
        direction: SetappSwipeDirection,
        preferredPID: pid_t? = nil,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        let effect = SetappGestureMap.effect(fingers: fingers, direction: direction)
        return perform(effect, preferredPID: preferredPID, language: language)
    }

    public func perform(
        _ effect: SetappGestureEffect,
        preferredPID: pid_t? = nil,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        switch effect {
        case .minimizeApp:
            return performMinimize(preferredPID: preferredPID, language: language)
        case .maximizeApp:
            return performMaximize(preferredPID: preferredPID, language: language)
        case .copySelection:
            return performCopySelection(preferredPID: preferredPID, language: language)
        case .pasteClipboard:
            return performPasteClipboard(preferredPID: preferredPID, language: language)
        }
    }

    public static func run(
        fingers: SetappFingerCount,
        direction: SetappSwipeDirection,
        windowService: MacAccessibilityAndWindowService? = nil,
        inputService: MacInputAndMediaService? = nil,
        clipboardService: MacClipboardMonitorService? = nil,
        preferredPID: pid_t? = nil,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        let runner = MacSetappGestureRunner(
            windowService: windowService,
            inputService: inputService,
            clipboardService: clipboardService
        )
        return runner.perform(
            fingers: fingers,
            direction: direction,
            preferredPID: preferredPID,
            language: language
        )
    }

    public static func run(
        _ effect: SetappGestureEffect,
        windowService: MacAccessibilityAndWindowService? = nil,
        inputService: MacInputAndMediaService? = nil,
        clipboardService: MacClipboardMonitorService? = nil,
        preferredPID: pid_t? = nil,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        let runner = MacSetappGestureRunner(
            windowService: windowService,
            inputService: inputService,
            clipboardService: clipboardService
        )
        return runner.perform(effect, preferredPID: preferredPID, language: language)
    }

    private func performMinimize(
        preferredPID: pid_t?,
        language: AppLanguage
    ) -> (success: Bool, message: String) {
        let hideResult = MacSessionActionPack.run(
            id: SessionCompanionActionID.hideFrontmostApp,
            preferredPID: preferredPID,
            language: language
        )
        if hideResult.success {
            return hideResult
        }

        if let target = resolveExternalAppTarget(preferredPID: preferredPID) {
            let minimizeResult = windowService.performWindowOperation(
                .minimize,
                preferredPID: pid_t(target.pid),
                strictTargetPID: true
            )
            if minimizeResult.success {
                return minimizeResult
            }
        }
        return hideResult
    }

    private func performMaximize(
        preferredPID: pid_t?,
        language: AppLanguage
    ) -> (success: Bool, message: String) {
        let zoomResult = MacWindowActionPack.run(
            id: WindowCompanionActionID.zoom,
            preferredPID: preferredPID
        )
        if zoomResult.success || !windowService.isAccessibilityTrusted() {
            return zoomResult
        }

        // Fallback: unhide hidden apps via MacSessionShowActionPack and zoom/maximize via MacWindowActionPack.
        let unhideResult = MacSessionShowActionPack.run(
            id: SessionShowCompanionAction.showAllApps.rawValue,
            language: language
        )
        let retryZoom = MacWindowActionPack.run(
            id: WindowCompanionActionID.zoom,
            preferredPID: preferredPID
        )
        if retryZoom.success {
            return retryZoom
        }
        return unhideResult.success ? unhideResult : zoomResult
    }

    private func performCopySelection(
        preferredPID: pid_t?,
        language: AppLanguage
    ) -> (success: Bool, message: String) {
        switch windowService.readFocusedSelectionPreview(preferredPID: preferredPID, language: language) {
        case .success(let previewText):
            let fullSelection = (try? windowService.readFrontmostSelection().text) ?? previewText
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(fullSelection, forType: .string) else {
                return (
                    false,
                    L10n.tr("无法写入剪贴板", "Could not copy selection to clipboard", language: language)
                )
            }
            clipboardService.refreshImmediately()
            return (
                true,
                L10n.tr("已复制选中内容到剪贴板", "Copied selection to clipboard", language: language)
            )
        case .failure(.emptySelection):
            return (
                false,
                L10n.tr("当前没有选中的文本", "no selection", language: language)
            )
        case .failure(let error):
            return (
                false,
                error.errorDescription ?? L10n.tr("当前没有选中的文本", "no selection", language: language)
            )
        }
    }

    private func performPasteClipboard(
        preferredPID: pid_t?,
        language: AppLanguage
    ) -> (success: Bool, message: String) {
        clipboardService.pollIfNeeded()
        guard let clipboardText = clipboardService.currentInsertablePlainText() else {
            return (
                false,
                L10n.tr(
                    "Mac 剪贴板当前没有可粘贴的纯文本",
                    "Mac clipboard has no plain text to paste",
                    language: language
                )
            )
        }
        return inputService.insertText(
            clipboardText,
            preferredPID: preferredPID,
            allowActivatingPreferredPID: false,
            language: language
        )
    }

    private func resolveExternalAppTarget(preferredPID: pid_t?) -> SessionAppTarget? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let preferredApp: NSRunningApplication? = {
            guard let preferredPID, preferredPID > 0 else { return nil }
            return NSRunningApplication(processIdentifier: preferredPID)
        }()
        return SessionCompanionActionRouting.resolveHideTarget(
            frontmost: frontApp.map(Self.makeSessionTarget),
            preferred: preferredApp.map(Self.makeSessionTarget),
            selfPID: Int32(ProcessInfo.processInfo.processIdentifier),
            hostBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    private static func makeSessionTarget(_ app: NSRunningApplication) -> SessionAppTarget {
        SessionAppTarget(
            pid: Int32(app.processIdentifier),
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            isRegular: app.activationPolicy == .regular,
            isTerminated: app.isTerminated
        )
    }
}
