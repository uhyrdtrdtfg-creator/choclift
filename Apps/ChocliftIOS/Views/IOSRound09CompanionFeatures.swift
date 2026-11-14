import ChocliftCore
import SwiftUI

// MARK: - 1. Lock Screen Pill Button (3-Second Second-Tap Confirm — Separate from Sleep Display)

public struct IOSLockScreenPillButton: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool
    var onPromptHUD: ((String) -> Void)?

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        compact: Bool = false,
        onPromptHUD: ((String) -> Void)? = nil
    ) {
        self.client = client
        self.compact = compact
        self.onPromptHUD = onPromptHUD
    }

    public var body: some View {
        let key = "round09-lock-screen-pill"
        let isPressed = (pressedKey == key)
        let now = ProcessInfo.processInfo.systemUptime
        let isArmed = client.isLockMacScreenArmed(at: now)
        let displayTitle = isArmed
            ? Round09LockScreenConfirmController.armedTitle(compact: compact, in: lang)
            : Round09LockScreenConfirmController.title(compact: compact, in: lang)

        Button {
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            let outcome = client.tapLockMacScreen(at: ProcessInfo.processInfo.systemUptime)
            switch outcome {
            case .requireSecondTap:
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                onPromptHUD?(Round09LockScreenConfirmController.promptMessage(in: lang))
            case .confirmedExecute:
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isArmed ? "exclamationmark.triangle.fill" : "lock.fill")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(isArmed ? palette.emphasisForeground : palette.statusFailure)

                Text(displayTitle)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(isArmed ? palette.emphasisForeground : palette.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, compact ? 9 : 10)
            .frame(minHeight: 44)
            .background(
                isArmed
                    ? palette.statusFailure
                    : (isPressed ? palette.tileFillBottom : palette.tileFillTop.opacity(0.94)),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isArmed
                            ? palette.statusFailure
                            : (isPressed ? palette.accent : palette.subtleCardStroke),
                        lineWidth: (isArmed || isPressed) ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
        .accessibilityIdentifier("ios-lock-screen-button")
        .accessibilityLabel(Round09LockScreenConfirmController.title(compact: false, in: lang))
        .accessibilityValue(
            isArmed
                ? L10n.tr("等待第二次点按确认", "Awaiting second tap confirmation", language: lang)
                : ""
        )
    }
}

// MARK: - 2. Hide Other Windows Pill Button (Hides Other Apps Without Quitting; Leaves Window Undo Untouched)

public struct IOSHideOtherWindowsPillButton: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine, compact: Bool = false) {
        self.client = client
        self.compact = compact
    }

    public var body: some View {
        let key = "round09-hide-other-windows-pill"
        let isPressed = (pressedKey == key)
        let title = HideOtherWindowsPolicy.buttonTitle(compact: compact, in: lang)

        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            client.hideOtherWindows()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(palette.accent)

                Text(title)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, compact ? 9 : 10)
            .frame(minHeight: 44)
            .background(
                isPressed ? palette.tileFillBottom : palette.tileFillTop.opacity(0.94),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isPressed ? palette.accent : palette.subtleCardStroke,
                        lineWidth: isPressed ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
        .accessibilityIdentifier("ios-hide-other-windows-button")
        .accessibilityLabel(HideOtherWindowsPolicy.buttonTitle(compact: false, in: lang))
    }
}

// MARK: - 3. Read-Only Frontmost Mac App Strip Badge (Shown Next to Battery; Tapping Does Not Launch Anything)

public struct IOSFrontmostAppStripBadge: View {
    @ObservedObject var client: CompanionClientEngine

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        let isConnected = client.connectionState.isConnected
        let resolvedName = client.resolvedStripFrontmostAppName
        let hasActiveApp = isConnected && resolvedName != nil
        let labelText = FrontmostAppStripFormatter.displayText(
            appName: resolvedName,
            isConnected: isConnected,
            in: lang
        )

        HStack(spacing: 5) {
            Image(systemName: "macwindow")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(hasActiveApp ? palette.accent : palette.secondaryText.opacity(0.75))

            Text(labelText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isConnected ? palette.primaryText : palette.secondaryText.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(palette.tileFillBottom.opacity(0.72), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ios-strip-frontmost-app")
        .accessibilityLabel(L10n.tr("Mac 前台应用", "Mac Frontmost App", language: lang))
        .accessibilityValue(labelText)
    }
}

// MARK: - 4. Pinned Clipboard Controls & Shelf (Max 8 Items, <= 280 Chars, Focused-Field Insert, No History Browser)

public struct IOSPinClipboardButton: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine, compact: Bool = false) {
        self.client = client
        self.compact = compact
    }

    public var body: some View {
        let key = compact ? "pin-clipboard-compact" : "pin-clipboard-full"
        let isPressed = (pressedKey == key)
        let isConnected = client.connectionState.isConnected
        let hasPreviewText = isConnected && client.clipboardPreview.hasText
        let isPinned = hasPreviewText && client.isCurrentClipboardPreviewPinned
        let isCapReached = !isPinned && !client.profile.canPinMoreClipboardItems
        let isActionable = hasPreviewText && (isPinned || !isCapReached)

        let buttonLabel: String = {
            if isPinned {
                return compact
                    ? L10n.tr("已定", "Pinned", language: lang)
                    : L10n.tr("已固定", "Pinned", language: lang)
            }
            if hasPreviewText && isCapReached {
                return "\(PinnedClipboardItem.maxPinnedCount)/\(PinnedClipboardItem.maxPinnedCount)"
            }
            return L10n.tr("固定", "Pin", language: lang)
        }()

        let iconName: String = {
            if isPinned { return "pin.fill" }
            if hasPreviewText && isCapReached { return "pin.slash" }
            return "pin"
        }()

        Button {
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            guard isConnected else {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                client.lastFeedback = CompanionFeedbackToast(
                    success: false,
                    title: L10n.tr("固定剪贴板", "Pin Clipboard", language: lang),
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
                return
            }
            guard client.clipboardPreview.hasText else {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                return
            }
            if !isPinned && !client.profile.canPinMoreClipboardItems {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                client.lastFeedback = CompanionFeedbackToast(
                    success: false,
                    title: L10n.tr("已达 8 条上限", "8-Pin Limit Reached", language: lang),
                    detail: L10n.tr(
                        "最多可固定 8 条剪贴板文本，请先取消固定一条。",
                        "Up to 8 clipboard items can be pinned. Unpin one first.",
                        language: lang
                    )
                )
                return
            }
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            _ = client.togglePinCurrentClipboardPreview()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: compact ? 10.5 : 11, weight: .bold))
                if !compact || isPinned || (hasPreviewText && isCapReached) {
                    Text(buttonLabel)
                        .font(.system(size: compact ? 10.5 : 11.5, weight: .bold, design: .rounded))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(
                isPinned
                    ? palette.emphasisForeground
                    : (isActionable ? palette.accent : palette.secondaryText)
            )
            .padding(.horizontal, compact ? 8 : 10)
            .frame(minHeight: compact ? 26 : 34)
            .background(
                isPinned
                    ? palette.accentEmphasis
                    : (isPressed ? palette.tileFillBottom : palette.tileFillTop),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isPinned
                            ? palette.accentEmphasis
                            : (isActionable ? palette.accent.opacity(0.45) : palette.subtleCardStroke),
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
        .accessibilityIdentifier(compact ? "ios-pin-clipboard-compact-button" : "ios-pin-clipboard-button")
        .accessibilityLabel(
            isPinned
                ? L10n.tr("取消固定当前剪贴板文本", "Unpin Current Clipboard Text", language: lang)
                : L10n.tr("固定当前剪贴板文本", "Pin Current Clipboard Text", language: lang)
        )
    }
}

/// Compact one-row chip strip of pinned clipboard items for the collapsed portrait clipboard preview card.
public struct IOSPinnedClipboardCompactStrip: View {
    @ObservedObject var client: CompanionClientEngine

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        let pins = client.profile.activePinnedClipboardItems
        if !pins.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(palette.accentEmphasis)
                        Text("\(pins.count)/\(PinnedClipboardItem.maxPinnedCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.secondaryText)
                    }
                    .padding(.trailing, 2)

                    ForEach(Array(pins.enumerated()), id: \.element.id) { index, item in
                        let chipKey = "compact-pin-\(item.id.uuidString)"
                        let isPressed = (pressedKey == chipKey)

                        HStack(spacing: 2) {
                            Button {
                                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                                ChocPressFeedback.completeTap(key: chipKey, pressedKey: $pressedKey)
                                _ = client.insertPinnedClipboardItem(item)
                            } label: {
                                Text(item.singleLinePreview)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: 140, alignment: .leading)
                                    .padding(.leading, 8)
                                    .padding(.trailing, 4)
                                    .frame(minHeight: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: chipKey))
                            .accessibilityIdentifier("ios-compact-pinned-clipboard-item-\(index)")

                            Button {
                                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                _ = client.unpinClipboardItem(id: item.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(palette.secondaryText)
                                    .frame(width: 24, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ios-compact-unpin-clipboard-item-\(index)")
                            .accessibilityLabel(L10n.tr("取消固定", "Unpin", language: lang))
                        }
                        .background(
                            isPressed ? palette.tileFillBottom : palette.tileFillTop,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isPressed ? palette.accent : palette.subtleCardStroke,
                                    lineWidth: 1
                                )
                        )
                        .scaleEffect(isPressed ? 0.95 : 1.0)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios-compact-pinned-clipboard-strip")
        }
    }
}

/// Expanded pinned clipboard shelf shown inside the Clipboard segment (up to 8 pinned plain-text items,
/// no unpinned clipboard history browser). Tapping a pin inserts via `.focusedFieldInsert`.
public struct IOSPinnedClipboardShelfView: View {
    @ObservedObject var client: CompanionClientEngine

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        let pins = client.profile.activePinnedClipboardItems

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.accentEmphasis)

                Text(L10n.tr("已固定剪贴板", "Pinned Clipboard", language: lang))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)

                Text("\(pins.count)/\(PinnedClipboardItem.maxPinnedCount)")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(palette.tileFillBottom, in: Capsule())

                Spacer(minLength: 4)
            }

            if pins.isEmpty {
                Text(
                    L10n.tr(
                        "可将上方 Mac 剪贴板预览中的文本固定（最多 8 条、每条 ≤280 字），点按即可向聚焦输入框插入。",
                        "Pin up to 8 plain-text items (≤280 chars) from the Mac clipboard preview above for one-tap insert.",
                        language: lang
                    )
                )
                .font(.system(size: 11.5, weight: .regular, design: .rounded))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ios-pinned-clipboard-empty")
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(pins.enumerated()), id: \.element.id) { index, item in
                            pinnedRow(item: item, index: index)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios-pinned-clipboard-shelf")
    }

    private func pinnedRow(item: PinnedClipboardItem, index: Int) -> some View {
        let rowKey = "pinned-clipboard-row-\(item.id.uuidString)"
        let isPressed = (pressedKey == rowKey)

        return HStack(spacing: 6) {
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                ChocPressFeedback.completeTap(key: rowKey, pressedKey: $pressedKey)
                _ = client.insertPinnedClipboardItem(item)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "character.cursor.ibeam")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.accent)

                    Text(item.singleLinePreview)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 10)
                .padding(.vertical, 7)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: rowKey))
            .accessibilityIdentifier("ios-pinned-clipboard-item-\(index)")

            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                _ = client.unpinClipboardItem(id: item.id)
            } label: {
                Image(systemName: "pin.slash")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(palette.tileFillBottom, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityIdentifier("ios-unpin-clipboard-item-\(index)")
            .accessibilityLabel(L10n.tr("取消固定", "Unpin", language: lang))
        }
        .background(
            isPressed ? palette.tileFillBottom : palette.tileFillTop,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isPressed ? palette.accent : palette.subtleCardStroke,
                    lineWidth: isPressed ? 1.5 : 1
                )
        )
        .scaleEffect(isPressed ? 0.97 : 1.0)
    }
}
