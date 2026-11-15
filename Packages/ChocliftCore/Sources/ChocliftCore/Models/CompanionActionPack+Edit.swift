import Foundation
#if os(macOS)
import Carbon.HIToolbox
import CoreGraphics
#endif

extension CompanionActionCatalog {
    public static let editPack: [CompanionAction] = [
        CompanionAction(
            id: "edit.select_all",
            titleZh: "全选",
            titleEn: "Select All",
            sfSymbol: "selection.pin.in.out"
        ),
        CompanionAction(
            id: "edit.find",
            titleZh: "查找",
            titleEn: "Find",
            sfSymbol: "magnifyingglass"
        ),
        CompanionAction(
            id: "edit.save",
            titleZh: "保存",
            titleEn: "Save",
            sfSymbol: "square.and.arrow.down"
        ),
        CompanionAction(
            id: "edit.bold",
            titleZh: "加粗",
            titleEn: "Bold",
            sfSymbol: "bold"
        ),
        CompanionAction(
            id: "edit.italic",
            titleZh: "斜体",
            titleEn: "Italic",
            sfSymbol: "italic"
        ),
        CompanionAction(
            id: "edit.underline",
            titleZh: "下划线",
            titleEn: "Underline",
            sfSymbol: "underline"
        ),
        CompanionAction(
            id: "edit.paste_match_style",
            titleZh: "粘贴并匹配样式",
            titleEn: "Paste and Match Style",
            sfSymbol: "doc.on.clipboard"
        ),
        CompanionAction(
            id: "edit.emoji",
            titleZh: "表情符号",
            titleEn: "Emoji Picker",
            sfSymbol: "face.smiling"
        ),
        CompanionAction(
            id: "edit.page_up",
            titleZh: "上一页",
            titleEn: "Page Up",
            sfSymbol: "arrow.up.doc"
        ),
        CompanionAction(
            id: "edit.page_down",
            titleZh: "下一页",
            titleEn: "Page Down",
            sfSymbol: "arrow.down.doc"
        )
    ]
}

public struct EditTargetCandidate: Equatable, Sendable {
    public var pid: Int32
    public var bundleIdentifier: String?
    public var localizedName: String?
    public var isTerminated: Bool

    public init(
        pid: Int32,
        bundleIdentifier: String?,
        localizedName: String? = nil,
        isTerminated: Bool = false
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.isTerminated = isTerminated
    }
}

#if os(macOS)
public struct EditCompanionKeystroke: Equatable, Sendable {
    public let virtualKey: CGKeyCode
    public let flags: CGEventFlags
    public let shortcutDisplay: String

    public init(virtualKey: CGKeyCode, flags: CGEventFlags, shortcutDisplay: String) {
        self.virtualKey = virtualKey
        self.flags = flags
        self.shortcutDisplay = shortcutDisplay
    }
}
#endif

public enum EditCompanionActionRouting {
    public static let chocliftBundleIdentifier = "com.choclift.mac"
    public static let chocliftBundlePrefix = "com.choclift."

    public static func isAllowedTargetBundle(
        _ bundleIdentifier: String?,
        selfBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> Bool {
        guard let raw = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return false
        }
        let lower = raw.lowercased()
        if lower == "com.choclift"
            || lower == chocliftBundleIdentifier
            || lower.hasPrefix(chocliftBundlePrefix)
            || lower == "com.apple.loginwindow" {
            return false
        }
        if let selfRaw = selfBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selfRaw.isEmpty,
           lower == selfRaw.lowercased() {
            return false
        }
        return true
    }

    public static func isEligibleTarget(
        _ candidate: EditTargetCandidate,
        selfPID: Int32,
        selfBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> Bool {
        !candidate.isTerminated
            && candidate.pid != selfPID
            && isAllowedTargetBundle(candidate.bundleIdentifier, selfBundleIdentifier: selfBundleIdentifier)
    }

    public static func resolveTarget(
        frontmost: EditTargetCandidate?,
        preferred: EditTargetCandidate?,
        selfPID: Int32,
        selfBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> EditTargetCandidate? {
        if let frontmost, isEligibleTarget(frontmost, selfPID: selfPID, selfBundleIdentifier: selfBundleIdentifier) {
            return frontmost
        }
        if let preferred, isEligibleTarget(preferred, selfPID: selfPID, selfBundleIdentifier: selfBundleIdentifier) {
            return preferred
        }
        return nil
    }

    #if os(macOS)
    public static let keystrokeTable: [String: EditCompanionKeystroke] = [
        "edit.select_all": EditCompanionKeystroke(
            virtualKey: CGKeyCode(kVK_ANSI_A),
            flags: .maskCommand,
            shortcutDisplay: "⌘A"
        ),
        "edit.find": EditCompanionKeystroke(
            virtualKey: CGKeyCode(kVK_ANSI_F),
            flags: .maskCommand,
            shortcutDisplay: "⌘F"
        ),
        "edit.save": EditCompanionKeystroke(
            virtualKey: CGKeyCode(kVK_ANSI_S),
            flags: .maskCommand,
            shortcutDisplay: "⌘S"
        ),
        "edit.bold": EditCompanionKeystroke(
            virtualKey: CGKeyCode(kVK_ANSI_B),
            flags: .maskCommand,
            shortcutDisplay: "⌘B"
        ),
        "edit.italic": EditCompanionKeystroke(
            virtualKey: CGKeyCode(kVK_ANSI_I),
            flags: .maskCommand,
            shortcutDisplay: "⌘I"
        ),
        "edit.underline": EditCompanionKeystroke(
            virtualKey: CGKeyCode(kVK_ANSI_U),
            flags: .maskCommand,
            shortcutDisplay: "⌘U"
        ),
        "edit.paste_match_style": EditCompanionKeystroke(
            virtualKey: CGKeyCode(kVK_ANSI_V),
            flags: [.maskAlternate, .maskShift, .maskCommand],
            shortcutDisplay: "⌥⇧⌘V"
        ),
        "edit.emoji": EditCompanionKeystroke(
            virtualKey: CGKeyCode(kVK_Space),
            flags: [.maskControl, .maskCommand],
            shortcutDisplay: "⌃⌘Space"
        ),
        "edit.page_up": EditCompanionKeystroke(
            virtualKey: CGKeyCode(kVK_PageUp),
            flags: [],
            shortcutDisplay: "Page Up"
        ),
        "edit.page_down": EditCompanionKeystroke(
            virtualKey: CGKeyCode(kVK_PageDown),
            flags: [],
            shortcutDisplay: "Page Down"
        )
    ]

    public static func keystroke(for id: String) -> EditCompanionKeystroke? {
        keystrokeTable[id]
    }

    public static func execute(
        id: String,
        frontmostBundleIdentifier: String?,
        selfBundleIdentifier: String? = chocliftBundleIdentifier,
        ensureAccessibility: () -> Bool,
        deniedResult: () -> (success: Bool, message: String),
        postKeystroke: (CGKeyCode, CGEventFlags) -> Void
    ) -> (success: Bool, message: String) {
        guard let action = CompanionActionCatalog.editPack.first(where: { $0.id == id }),
              let stroke = keystroke(for: id) else {
            return (false, L10n.tr("不支持此操作", "Unsupported action"))
        }
        guard ensureAccessibility() else {
            return deniedResult()
        }
        guard isAllowedTargetBundle(frontmostBundleIdentifier, selfBundleIdentifier: selfBundleIdentifier) else {
            return (false, L10n.tr("当前没有可接收快捷键的前台应用", "No frontmost application available for shortcut"))
        }
        postKeystroke(stroke.virtualKey, stroke.flags)
        return (
            true,
            L10n.tr(
                "已执行\(action.titleZh) (\(stroke.shortcutDisplay))",
                "Executed \(action.titleEn) (\(stroke.shortcutDisplay))"
            )
        )
    }
    #endif
}
