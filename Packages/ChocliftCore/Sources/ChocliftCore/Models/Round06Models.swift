import Foundation

// MARK: - 1. Snippet Insert Mode & Pure Focus Policy (Round 6)

/// Controls how a saved `TextSnippet` is delivered to the Mac.
public enum SnippetInsertMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    /// Default: inserts into the focused Mac text field via Accessibility (or transient clipboard-preserving paste),
    /// leaving the user's Mac clipboard untouched.
    case focusedFieldInsert
    /// Copies the snippet onto the Mac clipboard and pastes (`⌘V`) through the clipboard.
    case clipboardPaste
    /// Types characters through the existing `CGEvent` key path. Only available when a text field is focused;
    /// if no field is focused, does nothing.
    case typeKeys

    public static let defaultMode: SnippetInsertMode = .focusedFieldInsert

    public var id: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .focusedFieldInsert:
            return "character.cursor.ibeam"
        case .clipboardPaste:
            return "doc.on.clipboard"
        case .typeKeys:
            return "keyboard"
        }
    }

    public func badgeTitle(in language: AppLanguage = .system) -> String {
        switch self {
        case .focusedFieldInsert:
            return L10n.tr("聚焦输入", "Focused Insert", language: language)
        case .clipboardPaste:
            return L10n.tr("剪贴板粘贴", "Clipboard Paste", language: language)
        case .typeKeys:
            return L10n.tr("模拟按键", "Type Keys", language: language)
        }
    }

    public func title(in language: AppLanguage = .system) -> String {
        switch self {
        case .focusedFieldInsert:
            return L10n.tr("聚焦框输入（保留剪贴板）", "Focused-Field Insert (Preserves Clipboard)", language: language)
        case .clipboardPaste:
            return L10n.tr("通过剪贴板粘贴 (⌘V)", "Paste via Clipboard (⌘V)", language: language)
        case .typeKeys:
            return L10n.tr("按键逐字输入（仅聚焦时可用）", "Type via Keys (Focused Field Only)", language: language)
        }
    }

    public func subtitle(in language: AppLanguage = .system) -> String {
        switch self {
        case .focusedFieldInsert:
            return L10n.tr(
                "默认方式：输入到当前聚焦文本框，自动保留原有剪贴板。",
                "Default: inserts into the focused text field while keeping your clipboard intact.",
                language: language
            )
        case .clipboardPaste:
            return L10n.tr(
                "将片段写入 Mac 剪贴板并发送 ⌘V 粘贴。",
                "Copies the snippet to the Mac clipboard and pastes with ⌘V.",
                language: language
            )
        case .typeKeys:
            return L10n.tr(
                "通过按键通道逐字键入；仅当文本框已聚焦时可用，未聚焦时不执行任何操作。",
                "Types through the key path; only available when a field is focused, and does nothing otherwise.",
                language: language
            )
        }
    }
}

/// Pure execution decision produced by `SnippetInsertPolicy`.
public enum SnippetExecutionPlan: Equatable, Sendable {
    case focusedFieldInsertPreservingClipboard(String)
    case pasteThroughClipboard(String)
    case typeThroughKeyPath(String)
    case rejectedEmptyText
    case rejectedNoFocusedField

    public var isExecutable: Bool {
        switch self {
        case .focusedFieldInsertPreservingClipboard, .pasteThroughClipboard, .typeThroughKeyPath:
            return true
        case .rejectedEmptyText, .rejectedNoFocusedField:
            return false
        }
    }
}

/// Pure, platform-independent rules for snippet insert modes and text-field focus gating.
public enum SnippetInsertPolicy {
    public static var defaultMode: SnippetInsertMode {
        SnippetInsertMode.defaultMode
    }

    /// Typing mode is only available when a text field is focused on the Mac.
    public static func isModeAvailable(_ mode: SnippetInsertMode, isFieldFocused: Bool) -> Bool {
        switch mode {
        case .focusedFieldInsert, .clipboardPaste:
            return true
        case .typeKeys:
            return isFieldFocused
        }
    }

    /// Evaluates how a snippet should be executed given the current text-field focus state.
    /// - Note: When `mode == .typeKeys` and `isFieldFocused == false`, returns `.rejectedNoFocusedField`
    ///   so callers perform a strict no-op without sending keystrokes or touching the clipboard.
    public static func evaluate(
        body: String,
        mode: SnippetInsertMode,
        isFieldFocused: Bool
    ) -> SnippetExecutionPlan {
        let clamped = TextSnippet.clampBody(body)
        guard !clamped.isEmpty else {
            return .rejectedEmptyText
        }

        switch mode {
        case .focusedFieldInsert:
            guard isFieldFocused else {
                return .rejectedNoFocusedField
            }
            return .focusedFieldInsertPreservingClipboard(clamped)

        case .clipboardPaste:
            return .pasteThroughClipboard(clamped)

        case .typeKeys:
            guard isFieldFocused else {
                return .rejectedNoFocusedField
            }
            return .typeThroughKeyPath(clamped)
        }
    }
}

// MARK: - 2. Empty-Slot Hint Policy (Round 6)

/// Pure descriptor ensuring empty tiles show a quiet plus and `"Add"`, while filled tiles never show `"Add"`.
public enum EmptySlotHintPolicy {
    public static func shouldShowAddHint(for item: BarItem?) -> Bool {
        item == nil
    }

    public static func plusSymbolName(for item: BarItem?) -> String? {
        item == nil ? "plus" : nil
    }

    public static func hintLabel(for item: BarItem?, language: AppLanguage = .system) -> String? {
        guard item == nil else { return nil }
        return L10n.tr("添加", "Add", language: language)
    }

    public static func accessibilityLabel(
        for item: BarItem?,
        slotIndex: Int,
        resolvedFilledTitle: String?,
        language: AppLanguage = .system
    ) -> String {
        if item != nil, let resolvedFilledTitle, !resolvedFilledTitle.isEmpty {
            return resolvedFilledTitle
        }
        return L10n.tr("添加 · 空槽位 #\(slotIndex + 1)", "Add · Empty Slot #\(slotIndex + 1)", language: language)
    }
}

// MARK: - 3. Page Switcher Name & Truncation Formatter (Round 6)

public enum PageSwitcherTitleFormatter {
    public static let defaultMaxDisplayCharacters: Int = 24

    /// Returns a clean single-line page name for the page switcher (falling back to `"Page N"` only when blank)
    /// and truncating overly long titles with an ellipsis.
    public static func displayTitle(
        rawTitle: String,
        pageIndex: Int,
        maxCharacters: Int = defaultMaxDisplayCharacters,
        language: AppLanguage = .system
    ) -> String {
        let normalized = rawTitle
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let effective = normalized.isEmpty
            ? L10n.tr("第 \(pageIndex + 1) 页", "Page \(pageIndex + 1)", language: language)
            : normalized

        let safeLimit = max(4, maxCharacters)
        guard effective.count > safeLimit else {
            return effective
        }
        return "\(effective.prefix(safeLimit - 1))…"
    }
}

// MARK: - 4. Menu-Bar Status Summary (Round 6)

/// Pure representation of the Mac menu-bar item's status display (connected companion count + keep-awake state).
public struct MacMenuBarStatusSummary: Equatable, Sendable {
    public let connectedCompanionCount: Int
    public let isKeepAwakeOn: Bool

    public init(connectedCompanionCount: Int, isKeepAwakeOn: Bool) {
        self.connectedCompanionCount = max(0, connectedCompanionCount)
        self.isKeepAwakeOn = isKeepAwakeOn
    }

    public var symbolName: String {
        connectedCompanionCount > 0 ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2"
    }

    public func keepAwakeShortText(in language: AppLanguage = .system) -> String {
        if isKeepAwakeOn {
            return L10n.tr("常亮开", "Awake On", language: language)
        } else {
            return L10n.tr("常亮关", "Awake Off", language: language)
        }
    }

    /// Compact title rendered directly in the macOS menu bar item alongside the Choclift icon.
    public func menuBarTitle(in language: AppLanguage = .system) -> String {
        "\(connectedCompanionCount) · \(keepAwakeShortText(in: language))"
    }

    public func companionDetailText(in language: AppLanguage = .system) -> String {
        if connectedCompanionCount == 0 {
            return L10n.tr("0 台伴侣已连接", "0 Companions Connected", language: language)
        } else if connectedCompanionCount == 1 {
            return L10n.tr("1 台伴侣已连接", "1 Companion Connected", language: language)
        } else {
            return L10n.tr("\(connectedCompanionCount) 台伴侣已连接", "\(connectedCompanionCount) Companions Connected", language: language)
        }
    }

    public func keepAwakeDetailText(in language: AppLanguage = .system) -> String {
        if isKeepAwakeOn {
            return L10n.tr("保持唤醒：开启", "Keep Awake: On", language: language)
        } else {
            return L10n.tr("保持唤醒：关闭", "Keep Awake: Off", language: language)
        }
    }

    /// Explicit reason line shown ONLY while Choclift's keep-awake assertion is active (`nil` when off).
    public func awakeReasonLine(in language: AppLanguage = .system) -> String? {
        MacAwakeReasonFormatter.reasonLine(
            isAssertionActive: isKeepAwakeOn,
            language: language
        )
    }

    /// Read-only status lines rendered in the Mac menu-bar item's menu; includes the awake reason
    /// strictly when `isKeepAwakeOn == true`.
    public func menuStatusLines(in language: AppLanguage = .system) -> [String] {
        var lines = [
            companionDetailText(in: language),
            keepAwakeDetailText(in: language)
        ]
        if let reason = awakeReasonLine(in: language) {
            lines.append(reason)
        }
        return lines
    }

    public func tooltipText(in language: AppLanguage = .system) -> String {
        if let reason = awakeReasonLine(in: language) {
            return L10n.tr(
                "Choclift — \(companionDetailText(in: language)) · \(keepAwakeDetailText(in: language)) · \(reason)（点击打开窗口）",
                "Choclift — \(companionDetailText(in: language)) · \(keepAwakeDetailText(in: language)) · \(reason) (Click to open window)",
                language: language
            )
        }
        return L10n.tr(
            "Choclift — \(companionDetailText(in: language)) · \(keepAwakeDetailText(in: language))（点击打开窗口）",
            "Choclift — \(companionDetailText(in: language)) · \(keepAwakeDetailText(in: language)) (Click to open window)",
            language: language
        )
    }
}

// MARK: - 5. Launch at Login State & Testable Service Abstraction (Round 6)

/// Mirrors macOS 13 `SMAppService.Status` in a platform-independent model for deterministic testing.
public enum LaunchAtLoginRegistrationStatus: String, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    public var isEnabled: Bool {
        self == .enabled
    }

    public var needsSystemSettingsApproval: Bool {
        self == .requiresApproval
    }
}

public protocol LaunchAtLoginServing {
    func currentStatus() -> LaunchAtLoginRegistrationStatus
    func register() throws
    func unregister() throws
}

/// Manages Choclift's Launch-at-Login state (default off; adds/removes login item via `LaunchAtLoginServing`).
public struct LaunchAtLoginStateMachine {
    public private(set) var status: LaunchAtLoginRegistrationStatus

    public var isEnabled: Bool {
        status.isEnabled
    }

    public var requiresApproval: Bool {
        status.needsSystemSettingsApproval
    }

    /// Default off (`notRegistered`) until explicitly enabled by the user or already enabled in macOS Login Items.
    public init(initialStatus: LaunchAtLoginRegistrationStatus = .notRegistered) {
        self.status = initialStatus
    }

    public mutating func refresh(using service: LaunchAtLoginServing) {
        status = service.currentStatus()
    }

    public mutating func setEnabled(_ enabled: Bool, using service: LaunchAtLoginServing) throws {
        if enabled {
            if service.currentStatus() != .enabled {
                try service.register()
            }
        } else {
            let current = service.currentStatus()
            if current == .enabled || current == .requiresApproval {
                try service.unregister()
            }
        }
        status = service.currentStatus()
    }
}
