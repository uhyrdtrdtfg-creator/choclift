import ChocliftCore
import SwiftUI
import UIKit

// MARK: - 1. Top Bar Ribbon: Next Calendar Event + One-Tap Main Display Screenshot (+ Optional Landscape Clipboard)

public struct IOSCompanionBarRibbon: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool
    let includeInlineClipboard: Bool
    let allowMultiRow: Bool
    var onOpenClipboardSegment: (() -> Void)?
    var onPromptHUD: ((String) -> Void)?

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        compact: Bool,
        includeInlineClipboard: Bool = false,
        allowMultiRow: Bool = true,
        onOpenClipboardSegment: (() -> Void)? = nil,
        onPromptHUD: ((String) -> Void)? = nil
    ) {
        self.client = client
        self.compact = compact
        self.includeInlineClipboard = includeInlineClipboard
        self.allowMultiRow = allowMultiRow
        self.onOpenClipboardSegment = onOpenClipboardSegment
        self.onPromptHUD = onPromptHUD
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            singleRowRibbon

            if allowMultiRow {
                twoRowPortraitRibbon
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    singleRowRibbon
                }
            }
        }
    }

    private var singleRowRibbon: some View {
        HStack(spacing: 6) {
            calendarEventButton

            if includeInlineClipboard && client.connectionState.isConnected {
                inlineClipboardCluster
            }

            IOSKeepMacAwakeTogglePill(client: client, compact: compact)

            IOSSleepDisplayPillButton(client: client, compact: compact)

            IOSLockScreenPillButton(client: client, compact: compact, onPromptHUD: onPromptHUD)

            IOSShowDesktopPillButton(client: client, compact: compact)

            IOSHideOtherWindowsPillButton(client: client, compact: compact)

            IOSFinderDesktopIconsPillButton(client: client, compact: compact)

            IOSEmptyTrashPillButton(client: client, compact: compact, onPromptHUD: onPromptHUD)

            IOSEjectExternalDisksPillButton(client: client, compact: compact, onPromptHUD: onPromptHUD)

            IOSFrontmostWindowsRibbonButton(client: client, compact: compact)

            screenshotCaptureButton
        }
    }

    private var twoRowPortraitRibbon: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                calendarEventButton

                if includeInlineClipboard && client.connectionState.isConnected {
                    inlineClipboardCluster
                }

                IOSKeepMacAwakeTogglePill(client: client, compact: compact)

                screenshotCaptureButton
            }

            HStack(spacing: 6) {
                IOSShowDesktopPillButton(client: client, compact: compact)

                IOSFinderDesktopIconsPillButton(client: client, compact: compact)

                Spacer(minLength: 0)

                IOSSleepDisplayPillButton(client: client, compact: compact)

                IOSFrontmostWindowsRibbonButton(client: client, compact: compact)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    IOSHideOtherWindowsPillButton(client: client, compact: compact)

                    IOSLockScreenPillButton(client: client, compact: compact, onPromptHUD: onPromptHUD)

                    IOSEmptyTrashPillButton(client: client, compact: compact, onPromptHUD: onPromptHUD)

                    IOSEjectExternalDisksPillButton(client: client, compact: compact, onPromptHUD: onPromptHUD)

                    Spacer(minLength: 0)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        IOSHideOtherWindowsPillButton(client: client, compact: compact)

                        IOSLockScreenPillButton(client: client, compact: compact, onPromptHUD: onPromptHUD)

                        IOSEmptyTrashPillButton(client: client, compact: compact, onPromptHUD: onPromptHUD)

                        IOSEjectExternalDisksPillButton(client: client, compact: compact, onPromptHUD: onPromptHUD)
                    }
                }
            }
        }
    }

    private var calendarEventButton: some View {
        let key = "calendar-bar"
        let isPressed = (pressedKey == key)

        return TimelineView(.periodic(from: .now, by: 30.0)) { context in
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
                if client.connectionState.isConnected {
                    client.openCalendarOnMac()
                } else {
                    client.lastFeedback = CompanionFeedbackToast(
                        success: false,
                        title: L10n.tr("日历", "Calendar", language: lang),
                        detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                    )
                }
            } label: {
                calendarButtonLabel(referenceDate: context.date, isPressed: isPressed)
            }
            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
            .accessibilityIdentifier("ios-calendar-event-button")
        }
    }

    private func calendarButtonLabel(referenceDate: Date, isPressed: Bool) -> some View {
        let snapshot = client.calendarSnapshot
        let isConnected = client.connectionState.isConnected
        let isDenied = isConnected && snapshot.permission == .denied
        let event = isConnected ? snapshot.nextEvent : nil

        let symbolName = isDenied ? "calendar.badge.exclamationmark" : "calendar"
        let symbolTint = (event != nil) ? palette.accent : palette.secondaryText

        return HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(symbolTint)

            if let event {
                Text(event.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(
                    NextCalendarEventSnapshot.formattedStartTime(
                        for: event,
                        referenceDate: referenceDate,
                        language: lang
                    )
                )
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            } else if isDenied {
                Text(L10n.tr("日历权限未开启", "Calendar access off", language: lang))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            } else if isConnected {
                Text(L10n.tr("近期无日程", "No upcoming events", language: lang))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            } else {
                Text(L10n.tr("下一日程", "Next Event", language: lang))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(
            isPressed ? palette.tileFillBottom : palette.barSurface.opacity(0.92),
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
        .scaleEffect(isPressed ? 0.97 : 1.0)
    }

    private var inlineClipboardCluster: some View {
        let preview = client.clipboardPreview
        let pasteKey = "inline-clipboard-paste"
        let isPastePressed = (pressedKey == pasteKey)

        return HStack(spacing: 5) {
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                onOpenClipboardSegment?()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(preview.hasText ? palette.accent : palette.secondaryText)

                    if let singleLine = preview.singleLinePreview {
                        Text(singleLine)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text(L10n.tr("剪贴板为空", "Clipboard empty", language: lang))
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.leading, 9)
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-bar-clipboard-preview")

            if preview.hasText {
                IOSPinClipboardButton(client: client, compact: true)
            }

            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                ChocPressFeedback.completeTap(key: pasteKey, pressedKey: $pressedKey)
                client.pasteMacClipboard()
            } label: {
                Text(L10n.tr("粘贴", "Paste", language: lang))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(preview.hasText ? palette.accentForeground : palette.secondaryText)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(
                        preview.hasText ? palette.accent : palette.tileFillBottom,
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                    .scaleEffect(isPastePressed ? 0.94 : 1.0)
            }
            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: pasteKey))
            .padding(.trailing, 4)
            .accessibilityIdentifier("ios-paste-clipboard-button")
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .background(palette.barSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var screenshotCaptureButton: some View {
        let key = "capture-screenshot"
        let isPressed = (pressedKey == key)
        let isBusy = client.isCapturingScreenshot

        return Button {
            guard !isBusy else { return }
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            if client.connectionState.isConnected {
                client.captureMainDisplayScreenshot()
            } else {
                client.lastFeedback = CompanionFeedbackToast(
                    success: false,
                    title: L10n.tr("主屏幕截图", "Main Display Screenshot", language: lang),
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
            }
        } label: {
            HStack(spacing: 5) {
                if isBusy {
                    ProgressView()
                        .scaleEffect(0.68)
                        .frame(width: 13, height: 13)
                        .tint(palette.accent)
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(palette.accent)
                }

                Text(compact ? L10n.tr("截屏", "Shot", language: lang) : L10n.tr("截屏", "Screenshot", language: lang))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 34)
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
        .accessibilityIdentifier("ios-capture-screenshot-button")
        .accessibilityLabel(L10n.tr("截取 Mac 主显示器", "Capture Mac Main Display Screenshot", language: lang))
    }
}

// MARK: - 2. Clipboard Preview Card (Truncated to 280 Chars + Paste via Existing Insert Path)

public struct IOSClipboardPreviewCard: View {
    @ObservedObject var client: CompanionClientEngine
    let expanded: Bool
    var onTapExpand: (() -> Void)?

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        expanded: Bool = false,
        onTapExpand: (() -> Void)? = nil
    ) {
        self.client = client
        self.expanded = expanded
        self.onTapExpand = onTapExpand
    }

    public var body: some View {
        let preview = client.clipboardPreview
        let isConnected = client.connectionState.isConnected
        let pasteKey = expanded ? "clipboard-paste-expanded" : "clipboard-paste-bar"
        let isPastePressed = (pressedKey == pasteKey)

        VStack(alignment: .leading, spacing: expanded ? 10 : 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(preview.hasText ? palette.accent : palette.secondaryText)

                    Text(L10n.tr("Mac 剪贴板", "Mac Clipboard", language: lang))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)

                    if let text = preview.previewText {
                        Text(preview.isTruncated ? "280+" : "\(text.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(palette.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(palette.tileFillBottom, in: Capsule())
                    }
                }

                Spacer(minLength: 6)

                IOSPinClipboardButton(client: client, compact: !expanded)

                Button {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                    ChocPressFeedback.completeTap(key: pasteKey, pressedKey: $pressedKey)
                    if isConnected {
                        client.pasteMacClipboard()
                    } else {
                        client.lastFeedback = CompanionFeedbackToast(
                            success: false,
                            title: L10n.tr("剪贴板", "Clipboard", language: lang),
                            detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                        )
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "character.cursor.ibeam")
                            .font(.system(size: 11, weight: .bold))
                        Text(L10n.tr("粘贴到 Mac", "Paste", language: lang))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle((isConnected && preview.hasText) ? palette.accentForeground : palette.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(
                        (isConnected && preview.hasText) ? palette.accent : palette.tileFillBottom,
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                (isConnected && preview.hasText) ? .clear : palette.subtleCardStroke,
                                lineWidth: 1
                            )
                    )
                    .contentShape(Capsule())
                    .scaleEffect(isPastePressed ? 0.94 : 1.0)
                }
                .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: pasteKey))
                .accessibilityIdentifier(
                    expanded ? "ios-clipboard-surface-paste-button" : "ios-paste-clipboard-button"
                )
            }

            if let text = preview.previewText, isConnected {
                let displayString = preview.isTruncated ? "\(text)…" : text
                if expanded {
                    ScrollView {
                        Text(displayString)
                            .font(.system(size: 13.5, weight: .regular, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(
                        maxHeight: client.profile.activePinnedClipboardItems.isEmpty ? 110 : 72,
                        alignment: .topLeading
                    )
                    .accessibilityIdentifier("ios-clipboard-preview-text")
                } else if let onTapExpand {
                    Button {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                        onTapExpand()
                    } label: {
                        Text(displayString)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios-clipboard-preview-text")
                } else {
                    Text(displayString)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("ios-clipboard-preview-text")
                }
            } else {
                Text(
                    isConnected
                        ? L10n.tr("剪贴板为空或非纯文本", "Clipboard is empty or not plain text", language: lang)
                        : L10n.tr("配对连接 Mac 后在此预览剪贴板文本（最多 280 字）", "Pair with your Mac to preview clipboard text (up to 280 chars)", language: lang)
                )
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(expanded ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ios-clipboard-empty-state")
            }

            if expanded {
                Rectangle()
                    .fill(palette.subtleCardStroke)
                    .frame(height: 1)

                IOSPinnedClipboardShelfView(client: client)
            } else if !client.profile.activePinnedClipboardItems.isEmpty {
                IOSPinnedClipboardCompactStrip(client: client)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, expanded ? 12 : 8)
        .background(
            palette.barSurface.opacity(0.92),
            in: RoundedRectangle(cornerRadius: expanded ? 18 : 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: expanded ? 18 : 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios-clipboard-preview-card")
    }
}

// MARK: - 3. Small Main Display Screenshot Preview Card (Non-Blocking)

public struct IOSScreenshotPreviewOverlayCard: View {
    @ObservedObject var client: CompanionClientEngine

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        if let result = client.latestScreenshotPreview,
           result.success,
           let jpegData = result.previewJPEGData,
           let uiImage = UIImage(data: jpegData) {
            HStack(spacing: 10) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 88, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("已存至 Mac 桌面", "Saved to Mac Desktop", language: lang))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    if let fileName = result.fileName {
                        Text(fileName)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: 180, alignment: .leading)

                Button {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                    client.dismissScreenshotPreview()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 34, height: 34)
                        .background(palette.tileFillBottom, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ios-dismiss-screenshot-preview")
                .accessibilityLabel(L10n.tr("关闭截图预览", "Dismiss Screenshot Preview", language: lang))
            }
            .padding(8)
            .background(palette.barSurface.opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.tileBorderHighlight, lineWidth: 1.2)
            )
            .shadow(color: palette.primaryText.opacity(0.10), radius: 8, x: 0, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios-screenshot-preview-card")
        }
    }
}

// MARK: - 4. Display Picker for Window Snap (Hidden When <= 1 Display)

public struct IOSDisplayTargetPickerMenu: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var state: ControlStripState { client.controlStripState }

    public init(client: CompanionClientEngine, compact: Bool = true) {
        self.client = client
        self.compact = compact
    }

    public var body: some View {
        if state.shouldShowDisplayPicker {
            let selectedID = state.effectiveTargetDisplayID
            let selectedDisplay = selectedID.flatMap { id in
                state.connectedDisplays.first(where: { $0.displayID == id })
            }

            Menu {
                Button {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                    client.setTargetDisplay(displayID: nil)
                } label: {
                    HStack {
                        Text(L10n.tr("当前窗口所在屏幕（默认）", "Frontmost Window Display (Default)", language: lang))
                        if selectedID == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(state.connectedDisplays) { display in
                    Button {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                        client.setTargetDisplay(displayID: display.displayID)
                    } label: {
                        HStack {
                            Text(display.name)
                            if selectedID == display.displayID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "display.2")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selectedDisplay != nil ? palette.accent : palette.secondaryText)

                    if !compact || selectedDisplay != nil {
                        Text(
                            selectedDisplay?.name
                                ?? L10n.tr("当前屏幕", "Active Display", language: lang)
                        )
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .frame(maxWidth: compact ? 86 : 140)
                    }
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 34, minHeight: 34)
                .background(
                    (selectedDisplay != nil ? palette.accent.opacity(0.14) : palette.tileFillBottom),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            selectedDisplay != nil ? palette.accent.opacity(0.6) : palette.subtleCardStroke,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-display-picker-menu")
            .accessibilityLabel(L10n.tr("窗口贴靠目标显示器", "Target Display for Window Snap", language: lang))
            .accessibilityValue(state.selectedDisplayLabel(in: lang))
        }
    }
}
