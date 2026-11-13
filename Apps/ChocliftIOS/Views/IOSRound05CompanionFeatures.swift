import ChocliftCore
import SwiftUI
import UIKit

// MARK: - 1. Sleep Mac Display Pill Button (Round 5 — Display Sleep Only, No Lock, Keeps Awake Toggle Untouched)

public struct IOSSleepDisplayPillButton: View {
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
        let key = "sleep-mac-display"
        let isPressed = (pressedKey == key)

        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            client.sleepMacDisplay()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "powersleep")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.accentEmphasis)

                Text(
                    compact
                        ? L10n.tr("熄屏", "Sleep", language: lang)
                        : L10n.tr("熄灭屏幕", "Sleep Display", language: lang)
                )
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, compact ? 9 : 10)
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
        .accessibilityIdentifier("ios-sleep-display-button")
        .accessibilityLabel(L10n.tr("熄灭 Mac 屏幕（不锁屏）", "Sleep Mac Display", language: lang))
    }
}

// MARK: - 2. Compact Key Row + Recently Triggered Access Bar (Round 5)

public struct IOSCompactKeyAndRecentsBar: View {
    @ObservedObject var client: CompanionClientEngine
    let showInlineRecentChips: Bool
    var onPromptHUD: ((String) -> Void)?

    @State private var pressedKey: String?
    @State private var showRecentsSheet: Bool = false
    @State private var recentConfirmGate = DestructiveActionConfirmGate()

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        showInlineRecentChips: Bool,
        onPromptHUD: ((String) -> Void)? = nil
    ) {
        self.client = client
        self.showInlineRecentChips = showInlineRecentChips
        self.onPromptHUD = onPromptHUD
    }

    public var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(CompanionCompactKey.compactRowOrder) { compactKey in
                    compactKeyCapButton(for: compactKey)
                }

                Rectangle()
                    .fill(palette.subtleCardStroke)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 1)

                recentTilesButton
            }

            if showInlineRecentChips && !client.recentlyTriggeredTiles.isEmpty {
                inlineRecentChipsStrip
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            palette.barSurface.opacity(0.92),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios-compact-key-row")
        .sheet(isPresented: $showRecentsSheet) {
            IOSRecentlyTriggeredSheet(client: client, onPromptHUD: onPromptHUD)
        }
    }

    private func compactKeyCapButton(for compactKey: CompanionCompactKey) -> some View {
        let pressID = "compact-key-\(compactKey.rawValue)"
        let isPressed = (pressedKey == pressID)
        let isWideKey = (compactKey == .space)

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            ChocPressFeedback.completeTap(key: pressID, pressedKey: $pressedKey)
            client.sendCompactKey(compactKey)
        } label: {
            Group {
                if compactKey.isArrowKey {
                    Image(systemName: compactKey.sfSymbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                } else {
                    Text(compactKey.capLabel(in: lang))
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minWidth: isWideKey ? 52 : 34, minHeight: 34)
            .background(
                isPressed ? palette.tileFillBottom : palette.tileFillTop,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isPressed ? palette.accent : palette.subtleCardStroke,
                        lineWidth: isPressed ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: pressID))
        .accessibilityIdentifier("ios-compact-key-\(compactKey.rawValue)")
        .accessibilityLabel(compactKey.title(in: lang))
    }

    private var recentTilesButton: some View {
        let pressID = "open-recent-tiles"
        let isPressed = (pressedKey == pressID)
        let count = min(client.recentlyTriggeredTiles.count, RecentlyTriggeredTileList.maxEntries)

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            ChocPressFeedback.completeTap(key: pressID, pressedKey: $pressedKey)
            showRecentsSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(count > 0 ? palette.accent : palette.secondaryText)

                Text(L10n.tr("最近", "Recent", language: lang))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(palette.accent.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 34)
            .background(
                isPressed ? palette.tileFillBottom : palette.tileFillTop,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isPressed ? palette.accent : palette.subtleCardStroke,
                        lineWidth: isPressed ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: pressID))
        .accessibilityIdentifier("ios-recent-tiles-button")
        .accessibilityLabel(L10n.tr("最近触发的方块", "Recently Triggered Tiles", language: lang))
    }

    private var inlineRecentChipsStrip: some View {
        let entries = Array(client.recentlyTriggeredTiles.prefix(RecentlyTriggeredTileList.maxEntries))

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let chipKey = "recent-inline-\(entry.id.uuidString)"
                    let isPressed = (pressedKey == chipKey)
                    let isAwaitingConfirm = recentConfirmGate.isArmed(
                        targetID: chipKey,
                        at: ProcessInfo.processInfo.systemUptime
                    )

                    Button {
                        ChocPressFeedback.completeTap(key: chipKey, pressedKey: $pressedKey)
                        RecentTileExecutionHelper.runRecentEntry(
                            entry,
                            targetKey: chipKey,
                            client: client,
                            confirmGate: $recentConfirmGate,
                            language: lang,
                            onPromptHUD: onPromptHUD
                        )
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isAwaitingConfirm ? "exclamationmark.triangle.fill" : "bolt.horizontal.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(isAwaitingConfirm ? palette.statusFailure : palette.accent)

                            Text(entry.title)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)

                            if let ago = entry.formattedLastTriggered() {
                                Text(ago)
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.secondaryText)
                            }
                        }
                        .padding(.horizontal, 9)
                        .frame(minHeight: 28)
                        .background(
                            isPressed ? palette.tileFillBottom : palette.tileFillTop,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isAwaitingConfirm
                                        ? palette.statusFailure
                                        : (isPressed ? palette.accent : palette.subtleCardStroke),
                                    lineWidth: isAwaitingConfirm ? 1.6 : 1
                                )
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: chipKey))
                    .accessibilityIdentifier("ios-recent-chip-\(index)")
                    .accessibilityLabel(entry.title)
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("ios-recent-inline-row")
    }
}

// MARK: - 3. Recently Triggered Tiles Sheet (Last 8 Triggered Tiles — Title & ID Only)

public struct IOSRecentlyTriggeredSheet: View {
    @ObservedObject var client: CompanionClientEngine
    var onPromptHUD: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var confirmGate = DestructiveActionConfirmGate()

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine, onPromptHUD: ((String) -> Void)? = nil) {
        self.client = client
        self.onPromptHUD = onPromptHUD
    }

    public var body: some View {
        let entries = Array(client.recentlyTriggeredTiles.prefix(RecentlyTriggeredTileList.maxEntries))

        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(palette.accent)
                        Text(L10n.tr("暂无最近触发记录", "No Recently Triggered Tiles", language: lang))
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                        Text(
                            L10n.tr(
                                "点按任意巧克力栏方块后，最近触发的 8 个方块会显示在这里（仅记录标题与 ID，不记录剪贴板或隐私文本）。",
                                "Trigger any Chocolate Bar tile to list up to 8 recent tiles here (only tile title and ID are recorded).",
                                language: lang
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    }
                    .accessibilityIdentifier("ios-recent-tiles-empty")
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                recentEntryRow(entry: entry, index: index)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(L10n.tr("最近触发（最多 8 个）", "Recently Triggered", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("完成", "Done", language: lang)) {
                        dismiss()
                    }
                    .accessibilityIdentifier("ios-recent-tiles-done")
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(L10n.tr("清空", "Clear", language: lang), role: .destructive) {
                            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                            client.clearRecentlyTriggeredTiles()
                        }
                        .foregroundStyle(palette.statusFailure)
                        .accessibilityIdentifier("ios-recent-tiles-clear")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func recentEntryRow(entry: RecentlyTriggeredTileEntry, index: Int) -> some View {
        let rowKey = "recent-sheet-\(entry.id.uuidString)"
        let isAwaitingConfirm = confirmGate.isArmed(
            targetID: rowKey,
            at: ProcessInfo.processInfo.systemUptime
        )
        let isAvailable = (client.profile.locateBarItem(withID: entry.id) != nil)

        return Button {
            let didRun = RecentTileExecutionHelper.runRecentEntry(
                entry,
                targetKey: rowKey,
                client: client,
                confirmGate: $confirmGate,
                language: lang,
                onPromptHUD: onPromptHUD
            )
            if didRun {
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isAvailable ? "bolt.fill" : "questionmark.square.dashed")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isAvailable ? palette.accent : palette.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(isAvailable ? palette.primaryText : palette.secondaryText)
                        .lineLimit(1)

                    if !isAvailable {
                        Text(L10n.tr("已从页面移除", "Removed from pages", language: lang))
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                    } else if let ago = entry.formattedLastTriggered() {
                        Text(ago)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Spacer(minLength: 8)

                if isAwaitingConfirm {
                    Text(L10n.tr("再点确认", "Tap Again", language: lang))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.emphasisForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(palette.statusFailure, in: Capsule())
                } else if isAvailable {
                    Text(L10n.tr("再运行", "Run", language: lang))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(palette.accent.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isAwaitingConfirm ? palette.statusFailure : palette.subtleCardStroke,
                        lineWidth: isAwaitingConfirm ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-recent-sheet-row-\(index)")
        .accessibilityLabel(entry.title)
    }
}

@MainActor
private enum RecentTileExecutionHelper {
    @discardableResult
    static func runRecentEntry(
        _ entry: RecentlyTriggeredTileEntry,
        targetKey: String,
        client: CompanionClientEngine,
        confirmGate: Binding<DestructiveActionConfirmGate>,
        language: AppLanguage,
        onPromptHUD: ((String) -> Void)?
    ) -> Bool {
        guard let located = client.profile.locateBarItem(withID: entry.id) else {
            CompanionHaptics.notify(enabled: client.shouldPlayOutcomeHaptics(), type: .error)
            client.lastFeedback = CompanionFeedbackToast(
                success: false,
                title: entry.title,
                detail: L10n.tr("该方块已从巧克力栏移除", "This tile was removed from the Chocolate Bar", language: language)
            )
            return false
        }

        if located.item.isSlotReference,
           client.profile.resolveBarItem(located.item, from: located.coordinate).isMissing {
            return false
        }

        let isDestructive = located.item.requiresDestructiveConfirmation(
            in: client.profile,
            from: located.coordinate
        )
        let decision = confirmGate.wrappedValue.registerTap(
            targetID: targetKey,
            isDestructive: isDestructive,
            at: ProcessInfo.processInfo.systemUptime
        )

        switch decision {
        case .requireSecondTap:
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            onPromptHUD?(
                L10n.tr(
                    "3 秒内再点一次确认：\(entry.title)",
                    "Tap again within 3s: \(entry.title)",
                    language: language
                )
            )
            let delay = CompanionInteractionPolicy.destructiveConfirmWindowSeconds + 0.05
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                confirmGate.wrappedValue.expireIfNeeded(at: ProcessInfo.processInfo.systemUptime)
            }
            return false

        case .runImmediately, .confirmedRun:
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            let resolvedTitle = client.profile.displayTitle(for: located.item, from: located.coordinate, in: language)
            if client.connectionState.isConnected {
                client.triggerBarItem(located.item, from: located.coordinate)
            } else {
                client.recordOfflineTileFailure(
                    slot: located.coordinate,
                    title: resolvedTitle,
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: language)
                )
            }
            return true
        }
    }
}

// MARK: - 4. Persistent Strip Pinned Tiles Row (Up to 4 Tiles — Tap Runs, Long-Press Edits)

public struct IOSPinnedStripTilesRow: View {
    @ObservedObject var client: CompanionClientEngine
    var onPromptHUD: ((String) -> Void)?
    var onEditSlot: ((IOSEditSlotSelection) -> Void)?

    @State private var pressedKey: String?
    @State private var suppressedLongPressKey: String?
    @State private var openFolderSelection: IOSTileFolderSelection?
    @State private var confirmGate = DestructiveActionConfirmGate()

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        onPromptHUD: ((String) -> Void)? = nil,
        onEditSlot: ((IOSEditSlotSelection) -> Void)? = nil
    ) {
        self.client = client
        self.onPromptHUD = onPromptHUD
        self.onEditSlot = onEditSlot
    }

    public var body: some View {
        let pinnedSlots = client.profile.resolvedPinnedStripSlots()

        if !pinnedSlots.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                ForEach(Array(pinnedSlots.enumerated()), id: \.element.id) { index, pinned in
                    pinnedTileButton(pinned: pinned, index: index)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios-strip-pinned-row")
            .sheet(item: $openFolderSelection) { selection in
                IOSTileFolderSheet(
                    client: client,
                    pageIndex: selection.pageIndex,
                    slotIndex: selection.slotIndex,
                    onPromptHUD: onPromptHUD
                ) { editTarget in
                    onEditSlot?(editTarget)
                }
            }
        }
    }

    private func pinnedTileButton(pinned: ResolvedPinnedStripSlot, index: Int) -> some View {
        let key = "pinned-\(pinned.id)"
        let isPressed = (pressedKey == key)
        let isAwaitingConfirm = confirmGate.isArmed(
            targetID: key,
            at: ProcessInfo.processInfo.systemUptime
        )
        let outcome = client.tileOutcome(for: pinned.coordinate)
        let effectiveItem = client.profile.resolveBarItem(pinned.item, from: pinned.coordinate).resolvedItem ?? pinned.item
        let title = client.profile.displayTitle(for: pinned.item, from: pinned.coordinate, in: lang)

        let borderStroke: Color = {
            if isAwaitingConfirm {
                return palette.statusFailure
            }
            switch outcome {
            case .success:
                return palette.statusConnected
            case .failure:
                return palette.statusFailure
            case nil:
                return isPressed ? palette.accent : palette.subtleCardStroke
            }
        }()

        return Button {
            if suppressedLongPressKey == key {
                suppressedLongPressKey = nil
                return
            }
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            handlePinnedShortTap(pinned: pinned, key: key, resolvedTitle: title)
        } label: {
            HStack(spacing: 4) {
                pinnedLeadingIcon(for: effectiveItem)

                Text(isAwaitingConfirm ? L10n.tr("再点确认", "Confirm", language: lang) : title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isAwaitingConfirm ? palette.statusFailure : palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let outcome {
                    Spacer(minLength: 0)
                    Image(systemName: outcome == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(outcome == .success ? palette.statusConnected : palette.statusFailure)
                } else if !isAwaitingConfirm,
                          let ago = client.lastTriggeredText(for: pinned.item, from: pinned.coordinate) {
                    Spacer(minLength: 0)
                    Text(ago)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                isPressed ? palette.tileFillBottom : palette.tileFillTop,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        borderStroke,
                        lineWidth: (isAwaitingConfirm || outcome != nil || isPressed) ? 1.7 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(
            TileHoldToEditButtonStyle(
                pressedKey: $pressedKey,
                key: key,
                isSuppressed: false,
                holdDurationSeconds: CompanionInteractionPolicy.tileLongPressDurationSeconds,
                repeatableAction: {
                    guard case .systemAction(let action, _, _) = effectiveItem.kind,
                          HoldToRepeatPolicy.supportsHoldToRepeat(action) else {
                        return nil
                    }
                    return action
                }(),
                onRepeatBegan: {
                    suppressedLongPressKey = key
                    confirmGate.disarm()
                },
                onRepeatFire: {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                    if client.connectionState.isConnected {
                        client.triggerBarItem(pinned.item, from: pinned.coordinate)
                    } else {
                        client.recordOfflineTileFailure(
                            slot: pinned.coordinate,
                            title: title,
                            detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                        )
                    }
                },
                onTouchDown: {
                    suppressedLongPressKey = nil
                },
                onTouchEnded: {
                    if suppressedLongPressKey == key {
                        suppressedLongPressKey = nil
                    }
                },
                onLongPressHold: {
                    suppressedLongPressKey = key
                    confirmGate.disarm()
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                    onEditSlot?(IOSEditSlotSelection(pageIndex: pinned.pageIndex, slotIndex: pinned.slotIndex))
                }
            )
        )
        .accessibilityIdentifier("ios-pinned-tile-\(index)")
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func pinnedLeadingIcon(for item: BarItem) -> some View {
        switch item.kind {
        case .macApp(let bundleID, _, _, _):
            let icon = client.appIconsByBundleID[bundleID] ?? BundledAppIcons.pngData(for: bundleID)
            DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                .frame(width: 16, height: 16)
        case .systemAction(let action, _, _):
            Image(systemName: action.sfSymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.accent)
                .frame(width: 16, height: 16)
        case .shortcut(_, let emoji, _):
            Text(emoji.isEmpty ? "⚡️" : emoji)
                .font(.system(size: 13))
        case .website(_, _, let emoji, _, _):
            Text(emoji.isEmpty ? "🌐" : emoji)
                .font(.system(size: 13))
        case .flow(_, _, let emoji, _, _):
            Text(emoji.isEmpty ? "⚡️" : emoji)
                .font(.system(size: 13))
        case .soundboard(_, _, let emoji, _):
            Text(emoji.isEmpty ? "🔊" : emoji)
                .font(.system(size: 13))
        case .folder(let folder):
            Text(folder.emoji)
                .font(.system(size: 13))
        case .slotReference:
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.accent)
        }
    }

    private func handlePinnedShortTap(
        pinned: ResolvedPinnedStripSlot,
        key: String,
        resolvedTitle: String
    ) {
        if pinned.item.isFolder {
            confirmGate.disarm()
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            openFolderSelection = IOSTileFolderSelection(pageIndex: pinned.pageIndex, slotIndex: pinned.slotIndex)
            return
        }
        if pinned.item.isSlotReference,
           client.profile.resolveBarItem(pinned.item, from: pinned.coordinate).isMissing {
            confirmGate.disarm()
            return
        }

        let isDestructive = pinned.item.requiresDestructiveConfirmation(
            in: client.profile,
            from: pinned.coordinate
        )
        let decision = confirmGate.registerTap(
            targetID: key,
            isDestructive: isDestructive,
            at: ProcessInfo.processInfo.systemUptime
        )

        switch decision {
        case .requireSecondTap:
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            onPromptHUD?(
                L10n.tr(
                    "3 秒内再点一次确认：\(resolvedTitle)",
                    "Tap again within 3s: \(resolvedTitle)",
                    language: lang
                )
            )
            let delay = CompanionInteractionPolicy.destructiveConfirmWindowSeconds + 0.05
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(.easeInOut(duration: 0.18)) {
                    confirmGate.expireIfNeeded(at: ProcessInfo.processInfo.systemUptime)
                }
            }

        case .runImmediately, .confirmedRun:
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            if client.connectionState.isConnected {
                client.triggerBarItem(pinned.item, from: pinned.coordinate)
            } else {
                client.recordOfflineTileFailure(
                    slot: pinned.coordinate,
                    title: resolvedTitle,
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
            }
        }
    }
}
