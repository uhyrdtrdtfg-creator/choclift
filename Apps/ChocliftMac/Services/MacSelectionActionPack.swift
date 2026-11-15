import AppKit
import ChocliftCore
import Foundation

enum MacSelectionActionPack {
    @MainActor
    private static let fallbackWindowService = MacAccessibilityAndWindowService()
    @MainActor
    private static var configuredWindowService: MacAccessibilityAndWindowService?
    @MainActor
    private static var languageProvider: (() -> AppLanguage)?
    @MainActor
    private static var onSelectionPreviewCaptured: ((String, Date) -> Void)?

    @MainActor
    static func configure(
        windowService: MacAccessibilityAndWindowService,
        languageProvider: @escaping () -> AppLanguage,
        onSelectionPreviewCaptured: @escaping (String, Date) -> Void
    ) {
        configuredWindowService = windowService
        self.languageProvider = languageProvider
        self.onSelectionPreviewCaptured = onSelectionPreviewCaptured
    }

    static func run(id: String, preferredPID: pid_t?) -> (success: Bool, message: String) {
        guard id == SelectionCompanionAction.copyToPhone.rawValue else {
            return (false, L10n.tr("不支持此操作", "Unsupported action"))
        }

        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                runOnMainActor(preferredPID: preferredPID)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                runOnMainActor(preferredPID: preferredPID)
            }
        }
    }

    @MainActor
    private static func runOnMainActor(preferredPID: pid_t?) -> (success: Bool, message: String) {
        let lang = languageProvider?() ?? .system
        let service = configuredWindowService ?? fallbackWindowService
        switch service.readFocusedSelectionPreview(preferredPID: preferredPID, language: lang) {
        case .success(let previewText):
            let capturedAt = Date()
            onSelectionPreviewCaptured?(previewText, capturedAt)
            return (
                true,
                L10n.tr(
                    "已发送选中预览到手机（\(previewText.count) 字）",
                    "Sent selection preview to phone (\(previewText.count) chars)",
                    language: lang
                )
            )
        case .failure(let error):
            return (
                false,
                error.errorDescription ?? L10n.tr(
                    "当前没有选中的文本",
                    "No text selected in the focused element",
                    language: lang
                )
            )
        }
    }
}
