import AppKit
import ApplicationServices
import ChocliftCore
import Foundation

public final class MacEmojiBarInserter {
    @MainActor
    private static let shared = MacEmojiBarInserter()

    private let isAccessibilityTrustedProvider: @MainActor () -> Bool
    private let insertFocusedTextHandler: @MainActor (String, pid_t?, AppLanguage) -> (success: Bool, message: String)

    @MainActor
    public convenience init(
        windowService: MacAccessibilityAndWindowService? = nil,
        inputService: MacInputAndMediaService? = nil
    ) {
        let resolvedWindowService = windowService ?? MacAccessibilityAndWindowService()
        let resolvedInputService = inputService ?? MacInputAndMediaService(windowService: resolvedWindowService)
        self.init(
            isAccessibilityTrusted: {
                resolvedWindowService.isAccessibilityTrusted()
            },
            insertFocusedText: { emoji, preferredPID, language in
                let allowActivatingPreferred = (preferredPID != nil) &&
                    (NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)
                return resolvedInputService.insertText(
                    emoji,
                    preferredPID: preferredPID,
                    allowActivatingPreferredPID: allowActivatingPreferred,
                    language: language
                )
            }
        )
    }

    public init(
        isAccessibilityTrusted: @escaping @MainActor () -> Bool,
        insertFocusedText: @escaping @MainActor (String, pid_t?, AppLanguage) -> (success: Bool, message: String)
    ) {
        self.isAccessibilityTrustedProvider = isAccessibilityTrusted
        self.insertFocusedTextHandler = insertFocusedText
    }

    public static func accessibilityDeniedMessage(in language: AppLanguage = .system) -> String {
        L10n.tr(
            "choclift 需要辅助功能权限，才能为你粘贴表情符号并发送键盘快捷键。你可以在“系统设置”中允许。",
            "choclift needs Accessibility access to paste emojis and send keyboard shortcuts for you. You can allow this in System Settings.",
            language: language
        )
    }

    public func insertEmoji(
        _ emoji: String,
        preferredPID: pid_t? = nil
    ) -> (success: Bool, message: String) {
        insertEmoji(emoji, preferredPID: preferredPID, language: .system)
    }

    public func insertEmoji(
        _ emoji: String,
        preferredPID: pid_t?,
        language: AppLanguage
    ) -> (success: Bool, message: String) {
        Self.runOnMainActor {
            self.insertEmojiOnMain(emoji, preferredPID: preferredPID, language: language)
        }
    }

    public func insertEmoji(
        from book: EmojiBarBook,
        slide: Int,
        index: Int,
        preferredPID: pid_t? = nil,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        Self.runOnMainActor {
            guard self.isAccessibilityTrustedProvider() else {
                return (false, Self.accessibilityDeniedMessage(in: language))
            }
            guard EmojiBarBook.isValidSlot(slide: slide, index: index),
                  let emoji = book.emoji(slide: slide, index: index) else {
                return (
                    false,
                    L10n.tr(
                        "该表情槽位为空或无效",
                        "Emoji slot is empty or out of range",
                        language: language
                    )
                )
            }
            return self.insertFocusedTextHandler(emoji, preferredPID, language)
        }
    }

    public static func insertEmoji(
        _ emoji: String,
        preferredPID: pid_t? = nil
    ) -> (success: Bool, message: String) {
        insertEmoji(emoji, preferredPID: preferredPID, language: .system)
    }

    public static func insertEmoji(
        _ emoji: String,
        preferredPID: pid_t?,
        language: AppLanguage
    ) -> (success: Bool, message: String) {
        runOnMainActor {
            shared.insertEmojiOnMain(emoji, preferredPID: preferredPID, language: language)
        }
    }

    @MainActor
    private func insertEmojiOnMain(
        _ emoji: String,
        preferredPID: pid_t?,
        language: AppLanguage
    ) -> (success: Bool, message: String) {
        guard isAccessibilityTrustedProvider() else {
            return (false, Self.accessibilityDeniedMessage(in: language))
        }

        guard let validatedEmoji = EmojiBarBook.validateEmoji(emoji) else {
            return (
                false,
                L10n.tr(
                    "输入内容不是有效的单个表情符号",
                    "Emoji must be a single valid character",
                    language: language
                )
            )
        }

        return insertFocusedTextHandler(validatedEmoji, preferredPID, language)
    }

    private static func runOnMainActor<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(work)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(work)
        }
    }
}
