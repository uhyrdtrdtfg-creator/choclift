import ChocliftCore
import SwiftUI

public struct WatchSlotCoordinate: Identifiable {
    public let pageIndex: Int
    public let slotIndex: Int
    public var id: String { "\(pageIndex)-\(slotIndex)" }
}

// MARK: - Shared Watch Non-Connected Status Banner

private struct WatchConnectionStateBanner: View {
    @ObservedObject var client: CompanionClientEngine
    let onTap: () -> Void

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var state: ChocConnectionVisualState { ChocConnectionVisualState.resolve(from: client) }

    var body: some View {
        let tint = state.tintColor(in: palette)

        Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            onTap()
        } label: {
            HStack(spacing: 7) {
                if state.showsProgressSpinner {
                    ProgressView()
                        .scaleEffect(0.68)
                        .frame(width: 15, height: 15)
                        .tint(tint)
                } else {
                    Image(systemName: state.sfSymbol)
                        .font(ChocType.caption)
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.bannerTitle(in: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    if state.isFailure, let detail = state.bannerSubtitle(in: lang) {
                        Text(detail)
                            .font(ChocType.micro)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 2)

                Image(systemName: "chevron.right")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 42)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        state.isFailure ? palette.statusFailure.opacity(0.75) : tint.opacity(0.45),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct WatchOrcaComplicationLine: View {
    @ObservedObject var client: CompanionClientEngine
    let status: OrcaTaskStatusSnapshot

    @State private var pressedRowID: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    var body: some View {
        if !status.isOrcaRunning {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
                Text(L10n.tr("Orca 未运行", "Orca is not running", language: lang))
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(palette.barSurface.opacity(0.85), in: Capsule())
        } else if let primary = status.primaryRow {
            let tint = stateColor(primary.state)
            let summary: String = {
                if let title = primary.title, !title.isEmpty {
                    return "\(primary.state.label(in: lang)) · \(title)"
                }
                return "Orca · \(primary.state.label(in: lang))"
            }()

            if primary.canTapToFocus {
                let isPressed = (pressedRowID == primary.id)
                Button {
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                    ChocPressFeedback.completeTap(key: primary.id, pressedKey: $pressedRowID)
                    client.focusOrcaTask(dispatchID: primary.dispatchID)
                } label: {
                    lineBody(state: primary.state, tint: tint, summary: summary, canFocus: true, isPressed: isPressed)
                }
                .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedRowID, key: primary.id))
            } else {
                lineBody(state: primary.state, tint: tint, summary: summary, canFocus: false, isPressed: false)
            }
        }
    }

    private func lineBody(state: OrcaTaskState, tint: Color, summary: String, canFocus: Bool, isPressed: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: state.sfSymbol)
                .font(ChocType.micro)
                .foregroundStyle(tint)

            Text(summary)
                .font(ChocType.micro)
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)

            Spacer(minLength: 2)

            if canFocus {
                Image(systemName: "macwindow.on.rectangle")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(.horizontal, 9)
        .frame(minHeight: canFocus ? 34 : 28)
        .background(isPressed ? palette.tileFillBottom : palette.barSurface, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(isPressed ? palette.accent : tint.opacity(0.4), lineWidth: isPressed ? 1.6 : 1)
        )
        .contentShape(Capsule())
        .scaleEffect(isPressed ? 0.96 : 1.0)
    }

    private func stateColor(_ state: OrcaTaskState) -> Color {
        switch state {
        case .working:
            return palette.statusConnected
        case .waiting:
            return palette.accentEmphasis
        case .failed:
            return palette.statusFailure
        case .idle:
            return palette.secondaryText
        }
    }
}

private struct WatchCalendarComplicationLine: View {
    @ObservedObject var client: CompanionClientEngine
    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    var body: some View {
        let snapshot = client.calendarSnapshot
        if let event = snapshot.nextEvent {
            let key = "watch-calendar-next"
            let isPressed = (pressedKey == key)
            TimelineView(.periodic(from: .now, by: 30.0)) { context in
                Button {
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                    ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
                    client.openCalendarOnMac()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(ChocType.micro)
                            .foregroundStyle(palette.accent)
                        Text(event.title)
                            .font(ChocType.micro)
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(
                            NextCalendarEventSnapshot.formattedStartTime(
                                for: event,
                                referenceDate: context.date,
                                language: lang
                            )
                        )
                        .font(ChocType.micro)
                        .monospacedDigit()
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .frame(minHeight: 32)
                    .background(isPressed ? palette.tileFillBottom : palette.barSurface, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(isPressed ? palette.accent : palette.subtleCardStroke, lineWidth: isPressed ? 1.5 : 1)
                    )
                    .contentShape(Capsule())
                    .scaleEffect(isPressed ? 0.96 : 1.0)
                }
                .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
                .accessibilityIdentifier("watch-calendar-event-button")
            }
        } else if snapshot.permission == .denied {
            Button {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                client.openCalendarOnMac()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(ChocType.micro)
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("日历权限未开启", "Calendar access off", language: lang))
                        .font(ChocType.micro)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background(palette.barSurface.opacity(0.85), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("watch-calendar-denied-line")
        }
    }
}

// MARK: - 1. Watch Chocolate Bar Surface (8 Synced Pages x 8 Slots)

public struct WatchChocolateBarView: View {
    @ObservedObject var client: CompanionClientEngine
    @Binding var deckFollower: AppDeckFollowerState
    var isDeckSwitchHighlighted: Bool = false
    var isBarVisible: Bool = true
    let onRequestPairing: () -> Void

    @State private var showPagePickerSheet: Bool = false
    @State private var assigningSlot: WatchSlotCoordinate?
    @State private var openFolderSlot: WatchSlotCoordinate?
    @State private var pressedSlotKey: String?
    @State private var confirmGate = DestructiveActionConfirmGate()
    @State private var crownVolume: Double = 0.5
    @State private var isCrownRotating: Bool = false
    @State private var crownThrottle = ControlLevelDragThrottle(minimumInterval: 0.4)
    @FocusState private var isVolumeCrownFocused: Bool

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var isCrownActiveForBar: Bool {
        isBarVisible && !showPagePickerSheet && assigningSlot == nil && openFolderSlot == nil
    }

    private var safePageIndex: Int {
        guard !client.profile.pages.isEmpty else { return 0 }
        return min(max(0, deckFollower.currentPageIndex), client.profile.pages.count - 1)
    }

    private var activePage: BarPage {
        guard !client.profile.pages.isEmpty else {
            return BarPage(index: 0, title: "Daily", iconEmoji: "🍫")
        }
        return client.profile.pages[safePageIndex]
    }

    private var activeBoundDeckContext: (appName: String, page: BarPage)? {
        guard deckFollower.isFollowingFrontmostApp,
              let frontBundleID = client.frontmostBundleID,
              let boundPage = client.profile.boundPage(forBundleIdentifier: frontBundleID) else {
            return nil
        }
        let appName = client.profile.resolvedAppDisplayName(
            forBundleIdentifier: frontBundleID,
            preferredAppName: client.frontmostAppName,
            recentApps: client.recentApps,
            catalogApps: client.macCatalogApps
        )
        return (appName, boundPage)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if !client.connectionState.isConnected {
                    WatchConnectionStateBanner(client: client, onTap: onRequestPairing)
                } else if let orcaStatus = client.orcaStatus {
                    WatchOrcaComplicationLine(client: client, status: orcaStatus)
                }

                if client.controlStripState.nowPlaying?.primaryDisplayText != nil {
                    WatchNowPlayingProgressRow(client: client)
                }
                pageSwitcherBar

                let columns = [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ]

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<BarPage.slotsPerPage, id: \.self) { slotIdx in
                        let item = activePage.slots[slotIdx]
                        let key = "\(safePageIndex)-\(slotIdx)"
                        let slotOrigin = SlotCoordinate(pageID: activePage.id, slotIndex: slotIdx)
                        let effectiveItem = item.flatMap { client.profile.resolveBarItem($0, from: slotOrigin).resolvedItem }
                        let iconData = effectiveItem?.bundleIdentifier.flatMap {
                            client.appIconsByBundleID[$0] ?? BundledAppIcons.pngData(for: $0)
                        }
                        let isFrontmost = (effectiveItem?.bundleIdentifier != nil && effectiveItem?.bundleIdentifier == client.frontmostBundleID)

                        watchSlotButton(
                            pageIndex: safePageIndex,
                            slotIndex: slotIdx,
                            slotOrigin: slotOrigin,
                            key: key,
                            item: item,
                            iconData: iconData,
                            isFrontmost: isFrontmost
                        )
                        .frame(height: 64)
                    }
                }
                .id(activePage.id)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.22), value: safePageIndex)

                watchCrownVolumeBar
                    .padding(.bottom, 2)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .onAppear {
            crownVolume = ControlStripLevel.clamp(client.controlStripState.volume)
            if isCrownActiveForBar {
                isVolumeCrownFocused = true
            }
        }
        .onReceive(client.$controlStripState) { updated in
            guard !isCrownRotating else { return }
            let clamped = ControlStripLevel.clamp(updated.volume)
            if abs(crownVolume - clamped) > 0.004 {
                crownVolume = clamped
            }
        }
        .task(id: isCrownActiveForBar) {
            if isCrownActiveForBar {
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled, isCrownActiveForBar else { return }
                isVolumeCrownFocused = true
            } else {
                isVolumeCrownFocused = false
            }
        }
        .task(id: isVolumeCrownFocused) {
            guard isCrownActiveForBar, !isVolumeCrownFocused else { return }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, isCrownActiveForBar else { return }
            isVolumeCrownFocused = true
        }
        .sheet(isPresented: $showPagePickerSheet) {
            pagePickerSheet
        }
        .sheet(item: $assigningSlot) { coord in
            WatchSlotQuickAssignSheet(
                client: client,
                pageIndex: coord.pageIndex,
                slotIndex: coord.slotIndex
            )
        }
        .sheet(item: $openFolderSlot) { coord in
            WatchTileFolderSheet(
                client: client,
                pageIndex: coord.pageIndex,
                slotIndex: coord.slotIndex
            )
        }
    }

    private var watchCrownVolumeBar: some View {
        let isMuted = client.controlStripState.isVolumeMuted && !isCrownRotating
        let displayedLevel = ControlStripLevel.clamp(isCrownRotating ? crownVolume : client.controlStripState.volume)
        let pct = ControlStripLevel.percentage(for: displayedLevel)
        let muteKey = "watch-volume-mute"
        let isMutePressed = (pressedSlotKey == muteKey)

        return HStack(spacing: 7) {
            Button {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                ChocPressFeedback.completeTap(key: muteKey, pressedKey: $pressedSlotKey)
                if client.connectionState.isConnected {
                    client.performQuickAction(.volumeMute)
                } else {
                    client.lastFeedback = CompanionFeedbackToast(
                        success: false,
                        title: L10n.tr("静音", "Mute", language: lang),
                        detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                    )
                }
                isVolumeCrownFocused = true
            } label: {
                Image(systemName: (isMuted || displayedLevel <= 0.001) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(ChocType.caption)
                    .foregroundStyle(isMuted ? palette.emphasisForeground : palette.accent)
                    .frame(width: 32, height: 30)
                    .background(
                        isMuted
                            ? palette.statusFailure.opacity(isMutePressed ? 0.84 : 1.0)
                            : (isMutePressed ? palette.accent.opacity(0.18) : palette.tileFillBottom),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isMutePressed
                                    ? palette.accent
                                    : (isMuted ? palette.statusFailure : palette.subtleCardStroke),
                                lineWidth: isMutePressed ? 1.6 : 1
                            )
                    )
                    .contentShape(Capsule())
                    .scaleEffect(isMutePressed ? 0.92 : 1.0)
            }
            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedSlotKey, key: muteKey))
            .accessibilityIdentifier("watch-bar-volume-mute")
            .accessibilityLabel(
                isMuted
                    ? L10n.tr("取消静音", "Unmute", language: lang)
                    : L10n.tr("静音", "Mute", language: lang)
            )

            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let fillWidth = max(6, width * CGFloat(displayedLevel))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.tileFillBottom)
                        .frame(height: 6)

                    if displayedLevel > 0.005 {
                        Capsule()
                            .fill(isMuted ? palette.secondaryText.opacity(0.45) : palette.accent)
                            .frame(width: min(width, fillWidth), height: 6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 16)

            Text("\(pct)%")
                .font(ChocType.micro)
                .monospacedDigit()
                .foregroundStyle(isMuted ? palette.secondaryText : palette.primaryText)
                .frame(minWidth: 31, alignment: .trailing)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(palette.barSurface.opacity(0.95), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    isCrownRotating ? palette.accent : palette.subtleCardStroke,
                    lineWidth: isCrownRotating ? 1.4 : 1
                )
        )
        .focusable(isCrownActiveForBar)
        .focused($isVolumeCrownFocused)
        .focusEffectDisabled()
        .digitalCrownRotation(
            detent: $crownVolume,
            from: 0.0,
            through: 1.0,
            by: 0.02,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true,
            onChange: { _ in
                guard isCrownActiveForBar else { return }
                isCrownRotating = true
                let clamped = ControlStripLevel.clamp(crownVolume)
                let now = ProcessInfo.processInfo.systemUptime
                if let throttled = crownThrottle.updateDrag(to: clamped, at: now) {
                    client.setControlLevel(kind: .volume, level: throttled)
                }
            },
            onIdle: {
                guard isCrownRotating else { return }
                isCrownRotating = false
                let clamped = ControlStripLevel.clamp(crownVolume)
                let now = ProcessInfo.processInfo.systemUptime
                let committed = crownThrottle.endDrag(at: clamped, at: now)
                client.setControlLevel(kind: .volume, level: committed)
            }
        )
        .accessibilityIdentifier("watch-bar-crown-volume")
    }

    private var pageSwitcherBar: some View {
        HStack(spacing: 6) {
            Button {
                stepPage(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 36, height: 36)
                    .background(palette.tileFillBottom, in: Circle())
                    .overlay(Circle().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                showPagePickerSheet = true
            } label: {
                HStack(spacing: 5) {
                    Text(activePage.iconEmoji)
                        .font(ChocType.caption)
                    Text(activePage.title)
                        .font(ChocType.caption)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Text("\(safePageIndex + 1)/\(client.profile.pages.count)")
                        .font(ChocType.micro)
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .padding(.horizontal, 6)
                .background(palette.barSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                stepPage(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 36, height: 36)
                    .background(palette.tileFillBottom, in: Circle())
                    .overlay(Circle().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var pageDotsBar: some View {
        HStack(spacing: 2) {
            ForEach(0..<client.profile.pages.count, id: \.self) { dotIdx in
                let isCurrent = (dotIdx == safePageIndex)
                Button {
                    selectPageDot(dotIdx)
                } label: {
                    Capsule()
                        .fill(isCurrent ? palette.accent : palette.secondaryText.opacity(0.35))
                        .frame(width: isCurrent ? 14 : 6, height: 6)
                        .frame(minWidth: 18, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("watch-page-dot-\(dotIdx)")
                .accessibilityLabel(
                    L10n.tr(
                        "第 \(dotIdx + 1) 页：\(client.profile.pages[dotIdx].title)",
                        "Page \(dotIdx + 1): \(client.profile.pages[dotIdx].title)",
                        language: lang
                    )
                )
            }
        }
        .padding(.horizontal, 4)
        .background(palette.barSurface.opacity(0.75), in: Capsule())
    }

    private var followFrontmostAppButton: some View {
        Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            confirmGate.disarm()
            withAnimation(.easeInOut(duration: 0.22)) {
                deckFollower.followFrontmostApp(
                    frontmostBundleIdentifier: client.frontmostBundleID,
                    in: client.profile
                )
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(ChocType.micro)
                Text(L10n.tr("跟随前台应用", "Follow Frontmost App", language: lang))
                    .font(ChocType.micro)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 32)
            .padding(.horizontal, 8)
            .background(palette.accent, in: Capsule())
            .foregroundStyle(palette.accentForeground)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch-follow-frontmost-app-button")
    }

    private func followingAppBadge(appName: String, page: BarPage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "macwindow")
                .font(ChocType.micro)
            Text(
                L10n.tr(
                    "跟随 \(appName) · \(page.iconEmoji) \(page.title)",
                    "Following \(appName) · \(page.iconEmoji) \(page.title)",
                    language: lang
                )
            )
            .font(ChocType.micro)
            .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            palette.accent.opacity(isDeckSwitchHighlighted ? 0.24 : 0.14),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isDeckSwitchHighlighted ? palette.accent : palette.accent.opacity(0.28),
                    lineWidth: isDeckSwitchHighlighted ? 1.4 : 0.8
                )
        )
        .foregroundStyle(palette.accent)
        .scaleEffect(isDeckSwitchHighlighted ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isDeckSwitchHighlighted)
    }

    private func selectPageDot(_ pageOffset: Int) {
        guard client.profile.pages.indices.contains(pageOffset) else { return }
        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
        confirmGate.disarm()
        withAnimation(.easeInOut(duration: 0.2)) {
            deckFollower.selectManualPage(index: pageOffset, in: client.profile)
        }
    }

    private func stepPage(by delta: Int) {
        guard !client.profile.pages.isEmpty else { return }
        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
        confirmGate.disarm()
        withAnimation(.easeInOut(duration: 0.2)) {
            deckFollower.stepManualPage(by: delta, in: client.profile)
        }
    }

    private func watchSlotButton(
        pageIndex: Int,
        slotIndex: Int,
        slotOrigin: SlotCoordinate,
        key: String,
        item: BarItem?,
        iconData: Data?,
        isFrontmost: Bool
    ) -> some View {
        let isPressed = (pressedSlotKey == key)
        let isDestructive = item?.requiresDestructiveConfirmation(in: client.profile, from: slotOrigin) ?? false
        let isAwaitingConfirm = isDestructive && confirmGate.isArmed(
            targetID: key,
            at: ProcessInfo.processInfo.systemUptime
        )

        return Button {
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedSlotKey)
            if let item {
                if item.isFolder {
                    confirmGate.disarm()
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                    openFolderSlot = WatchSlotCoordinate(pageIndex: pageIndex, slotIndex: slotIndex)
                    return
                }
                if item.isSlotReference,
                   client.profile.resolveBarItem(item, from: slotOrigin).isMissing {
                    confirmGate.disarm()
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                let decision = confirmGate.registerTap(
                    targetID: key,
                    isDestructive: isDestructive,
                    at: now
                )
                switch decision {
                case .requireSecondTap:
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(CompanionInteractionPolicy.destructiveConfirmWindowSeconds + 0.05))
                        confirmGate.expireIfNeeded(at: ProcessInfo.processInfo.systemUptime)
                    }
                case .runImmediately, .confirmedRun:
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                    if client.connectionState.isConnected {
                        client.triggerBarItem(item, from: slotOrigin)
                    } else {
                        client.recordOfflineTileFailure(
                            slot: slotOrigin,
                            title: client.profile.displayTitle(for: item, from: slotOrigin, in: lang),
                            detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                        )
                    }
                }
                if isCrownActiveForBar {
                    isVolumeCrownFocused = true
                }
            } else {
                confirmGate.disarm()
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                assigningSlot = WatchSlotCoordinate(pageIndex: pageIndex, slotIndex: slotIndex)
            }
        } label: {
            ChocBarTileCard(
                item: item,
                iconData: iconData,
                isFrontmostApp: isFrontmost,
                isPressed: isPressed,
                isAwaitingConfirmation: isAwaitingConfirm,
                lastRunOutcome: client.tileOutcome(for: slotOrigin),
                palette: palette,
                language: lang,
                compact: true,
                profile: client.profile,
                slotOrigin: slotOrigin,
                lastTriggeredText: client.lastTriggeredText(for: item, from: slotOrigin),
                iconLookup: { bundleID in
                    client.appIconsByBundleID[bundleID] ?? BundledAppIcons.pngData(for: bundleID)
                }
            )
            .scaleEffect(isPressed ? 0.93 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedSlotKey, key: key))
    }

    private var pagePickerSheet: some View {
        List {
            Button {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                deckFollower.followFrontmostApp(
                    frontmostBundleIdentifier: client.frontmostBundleID,
                    in: client.profile
                )
                showPagePickerSheet = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(ChocType.caption)
                        .foregroundStyle(palette.accent)
                    Text(L10n.tr("跟随前台应用", "Follow Frontmost App", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Spacer()
                    if deckFollower.isFollowingFrontmostApp {
                        Image(systemName: "checkmark")
                            .font(ChocType.caption)
                            .foregroundStyle(palette.accent)
                    }
                }
                .frame(minHeight: 38)
            }
            .listRowBackground(palette.barSurface)

            ForEach(Array(client.profile.pages.enumerated()), id: \.element.id) { pageOffset, page in
                let isSelected = (!deckFollower.isFollowingFrontmostApp && pageOffset == safePageIndex)
                Button {
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                    deckFollower.selectManualPage(index: pageOffset, in: client.profile)
                    showPagePickerSheet = false
                } label: {
                    HStack(spacing: 8) {
                        Text(page.iconEmoji)
                            .font(ChocType.body)
                        Text(page.title)
                            .font(ChocType.caption)
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        Spacer()
                        if pageOffset == safePageIndex {
                            Image(systemName: deckFollower.isFollowingFrontmostApp ? "macwindow" : "checkmark")
                                .font(ChocType.caption)
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .frame(minHeight: 38)
                }
                .listRowBackground(palette.barSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }
}

// MARK: - Quick Slot Assignment Sheet on Watch

private struct WatchSlotQuickAssignSheet: View {
    @ObservedObject var client: CompanionClientEngine
    let pageIndex: Int
    let slotIndex: Int
    @Environment(\.dismiss) private var dismiss

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    var body: some View {
        List {
            if !client.profile.flows.isEmpty {
                Section(L10n.tr("动作流 (Flows)", "Action Flows", language: lang)) {
                    ForEach(client.profile.flows) { flow in
                        Button {
                            assign(client.profile.makeBarItem(for: flow))
                        } label: {
                            HStack(spacing: 8) {
                                Text(flow.emoji.isEmpty ? "⚡️" : flow.emoji)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(flow.name)
                                        .font(ChocType.caption)
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                    Text(L10n.tr("\(flow.enabledStepCount) 步", "\(flow.enabledStepCount) steps", language: lang))
                                        .font(ChocType.micro)
                                        .foregroundStyle(palette.secondaryText)
                                }
                            }
                            .frame(minHeight: 38)
                        }
                        .listRowBackground(palette.barSurface)
                    }
                }
            }

            if !client.recentApps.isEmpty {
                Section(L10n.tr("最近 Mac 应用", "Recent Mac Apps", language: lang)) {
                    ForEach(client.recentApps.prefix(8)) { entry in
                        Button {
                            assign(BarItem(kind: .macApp(
                                bundleIdentifier: entry.bundleIdentifier,
                                appName: entry.appName,
                                appPath: entry.appPath
                            )))
                        } label: {
                            HStack(spacing: 8) {
                                DataImageView(
                                    pngData: client.appIconsByBundleID[entry.bundleIdentifier] ?? BundledAppIcons.pngData(for: entry.bundleIdentifier),
                                    fallbackSymbol: "app.fill",
                                    tint: palette.secondaryText
                                )
                                .frame(width: 22, height: 22)
                                Text(entry.appName)
                                    .font(ChocType.caption)
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(1)
                            }
                            .frame(minHeight: 38)
                        }
                        .listRowBackground(palette.barSurface)
                    }
                }
            }

            if !client.profile.soundboardClips.isEmpty {
                Section(L10n.tr("本机音效 (Sounds)", "Soundboard", language: lang)) {
                    ForEach(client.profile.soundboardClips) { clip in
                        Button {
                            assign(client.profile.makeBarItem(for: clip))
                        } label: {
                            HStack(spacing: 8) {
                                Text(clip.emoji)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(clip.name)
                                        .font(ChocType.caption)
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                    Text(clip.formattedDuration)
                                        .font(ChocType.micro.monospacedDigit())
                                        .foregroundStyle(palette.secondaryText)
                                }
                            }
                            .frame(minHeight: 38)
                        }
                        .listRowBackground(palette.barSurface)
                    }
                }
            }

            Section(L10n.tr("系统快捷动作", "Quick Actions", language: lang)) {
                ForEach(SystemQuickAction.allCases) { action in
                    Button {
                        assign(BarItem(kind: .systemAction(action: action)))
                    } label: {
                        HStack(spacing: 6) {
                            Label(action.compactTitle(in: lang), systemImage: action.sfSymbol)
                                .font(ChocType.caption)
                                .foregroundStyle(palette.primaryText)
                            Spacer(minLength: 2)
                            if let shortcut = action.sentKeyboardShortcut {
                                Text(shortcut)
                                    .font(ChocType.micro)
                                    .foregroundStyle(palette.secondaryText)
                            }
                        }
                        .frame(minHeight: 38)
                    }
                    .listRowBackground(palette.barSurface)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private func assign(_ item: BarItem) {
        var updated = client.profile
        guard updated.pages.indices.contains(pageIndex),
              updated.pages[pageIndex].slots.indices.contains(slotIndex) else { return }
        updated.pages[pageIndex].slots[slotIndex] = item
        client.pushUpdatedProfile(updated)
        dismiss()
    }
}

// MARK: - 2. Watch Quick Actions Surface (Wrist Remote for Mac)

public struct WatchQuickActionsView: View {
    @ObservedObject var client: CompanionClientEngine
    let onRequestPairing: () -> Void

    @State private var repeatPressedKey: String?
    @State private var repeatReleaseKey: String?
    @State private var pressedAction: SystemQuickAction?
    @State private var confirmGate = DestructiveActionConfirmGate()
    @State private var showDisplayPickerSheet: Bool = false
    @State private var showAudioOutputSheet: Bool = false

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private let windowActions: [SystemQuickAction] = [
        .maximizeWindow, .minimizeWindow,
        .snapWindowLeft, .snapWindowRight,
        .centerWindow, .toggleFullscreen
    ]

    private let workspaceActions: [SystemQuickAction] = [
        .missionControl, .showDesktop,
        .copySelection, .pasteClipboard,
        .undoAction, .screenshotInteractive,
        .openEmojiPicker, .lockScreen,
        .quitApp
    ]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !client.connectionState.isConnected {
                    WatchConnectionStateBanner(client: client, onTap: onRequestPairing)
                }

                WatchCalendarComplicationLine(client: client)

                // Media & Volume Strip (Clean iconic transport buttons >= 46pt)
                sectionHeader(L10n.tr("媒体与音量", "Media & Volume", language: lang), symbol: "speaker.wave.2.fill")

                if client.controlStripState.nowPlaying != nil {
                    WatchNowPlayingProgressRow(client: client)
                }

                tripleMediaStrip([.volumeDown, .volumeMute, .volumeUp])
                watchAudioOutputButton

                NavigationLink {
                ScrollView {
                VStack(spacing: 10) {
                // Window Snap & Sizing
                sectionHeader(L10n.tr("窗口布局", "Window Layout", language: lang), symbol: "macwindow")

                if client.controlStripState.shouldShowDisplayPicker {
                    watchDisplayPickerButton
                }

                actionTwoColumnGrid(windowActions)
                undoWindowMoveButton

                // Workspace & Clipboard
                sectionHeader(L10n.tr("工作区与编辑", "Workspace & Edit", language: lang), symbol: "sparkles")

                actionTwoColumnGrid(workspaceActions)
                }
                }
                } label: {
                    Label(L10n.tr("窗口与工作区", "Windows & Workspace", language: lang), systemImage: "macwindow")
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .sheet(isPresented: $showDisplayPickerSheet) {
            watchDisplayPickerSheet
        }
        .sheet(isPresented: $showAudioOutputSheet) {
            WatchAudioOutputPickerSheet(client: client)
        }
    }

    private var watchAudioOutputButton: some View {
        let state = client.controlStripState
        let current = state.currentAudioOutputDevice
        let symbol = current?.transportKind.sfSymbol ?? "hifispeaker.2.fill"

        return Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            if client.connectionState.isConnected {
                client.requestControlStripState()
            }
            showAudioOutputSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(ChocType.caption)
                    .foregroundStyle(current != nil ? palette.accent : palette.secondaryText)
                Text(state.currentAudioOutputLabel(in: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: state.canSwitchAudioOutput ? "chevron.up.chevron.down" : "lock.fill")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(current != nil ? palette.accent.opacity(0.55) : palette.subtleCardStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch-audio-output-button")
    }

    private var watchDisplayPickerButton: some View {
        let state = client.controlStripState
        let hasOverride = state.effectiveTargetDisplayID != nil

        return Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            showDisplayPickerSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "display.2")
                    .font(ChocType.caption)
                    .foregroundStyle(hasOverride ? palette.accent : palette.secondaryText)
                Text(state.selectedDisplayLabel(in: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hasOverride ? palette.accent.opacity(0.6) : palette.subtleCardStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch-display-picker-button")
    }

    private var watchDisplayPickerSheet: some View {
        let state = client.controlStripState
        let selectedID = state.effectiveTargetDisplayID

        return List {
            Button {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                client.setTargetDisplay(displayID: nil)
                showDisplayPickerSheet = false
            } label: {
                HStack(spacing: 8) {
                    Text(L10n.tr("当前窗口屏幕", "Frontmost Window", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    if selectedID == nil {
                        Image(systemName: "checkmark")
                            .font(ChocType.caption)
                            .foregroundStyle(palette.accent)
                    }
                }
                .frame(minHeight: 38)
            }
            .listRowBackground(palette.barSurface)

            ForEach(state.connectedDisplays) { display in
                let isSelected = (selectedID == display.displayID)
                Button {
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                    client.setTargetDisplay(displayID: display.displayID)
                    showDisplayPickerSheet = false
                } label: {
                    HStack(spacing: 8) {
                        Text(display.name)
                            .font(ChocType.caption)
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(ChocType.caption)
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .frame(minHeight: 38)
                }
                .listRowBackground(palette.barSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private var undoWindowMoveButton: some View {
        let canUndo = client.controlStripState.canUndoWindowMove
        return Button {
            guard canUndo else { return }
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
            client.undoLastWindowMove()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward")
                    .font(ChocType.caption)
                    .foregroundStyle(canUndo ? palette.accent : palette.secondaryText)
                Text(L10n.tr("撤销上次窗口移动", "Undo Last Window Move", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(canUndo ? palette.primaryText : palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(
                LinearGradient(
                    colors: [palette.tileFillTop, palette.tileFillBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(canUndo ? palette.accent.opacity(0.55) : palette.subtleCardStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(canUndo ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch-undo-window-move")
    }

    private func sectionHeader(_ text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)
            Text(text)
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.top, 2)
    }

    private func tripleMediaStrip(_ actions: [SystemQuickAction]) -> some View {
        HStack(spacing: 6) {
            ForEach(actions) { action in
                let isPrimary = (action == .mediaPlayPause)
                let isPressed = (pressedAction == action)
                let tileTone = ChocSwatch.resolvedTileColor(hex: action.accentHex, fallbackHex: ChocPalette.coreTileBottomHex)

                Button {
                    if repeatReleaseKey == action.rawValue { repeatReleaseKey = nil; return }
                    trigger(action)
                } label: {
                    Image(systemName: action.sfSymbol)
                        .font(ChocType.title)
                        .foregroundStyle(palette.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            LinearGradient(
                                colors: [
                                    isPressed ? palette.tileFillBottom : palette.tileFillTop,
                                    tileTone
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    isPressed ? palette.accent : (isPrimary ? palette.accent.opacity(0.65) : palette.subtleCardStroke),
                                    lineWidth: isPressed ? 1.8 : 1
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .scaleEffect(isPressed ? 0.94 : 1.0)
                }
                .buttonStyle(WatchRepeatableQuickActionButtonStyle(pressedKey: $repeatPressedKey, key: action.rawValue, action: action, suppressReleaseKey: $repeatReleaseKey) { trigger(action) })
                .accessibilityLabel(action.compactTitle(in: lang))
            }
        }
    }

    private func actionTwoColumnGrid(_ actions: [SystemQuickAction]) -> some View {
        return VStack(spacing: 7) {
            ForEach(actions) { action in
                let tileTone = ChocSwatch.resolvedTileColor(hex: action.accentHex, fallbackHex: ChocPalette.coreTileBottomHex)
                let isPressed = (pressedAction == action)
                let isArmed = action.requiresDestructiveConfirmation && confirmGate.isArmed(
                    targetID: action.rawValue,
                    at: ProcessInfo.processInfo.systemUptime
                )

                Button {
                    trigger(action)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isArmed ? "exclamationmark.triangle.fill" : action.sfSymbol)
                            .font(ChocType.caption)
                            .foregroundStyle(isArmed ? palette.statusFailure : palette.primaryText)
                            .frame(width: 18)

                        Text(
                            isArmed
                                ? L10n.tr("再点确认", "Tap Again", language: lang)
                                : action.compactTitle(in: lang)
                        )
                        .font(ChocType.body)
                        .foregroundStyle(isArmed ? palette.statusFailure : palette.primaryText)
                        .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 48)
                    .background(
                        LinearGradient(
                            colors: [isPressed ? palette.tileFillBottom : palette.tileFillTop, tileTone],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(
                                isArmed ? palette.statusFailure : (isPressed ? palette.accent : palette.subtleCardStroke),
                                lineWidth: (isArmed || isPressed) ? 1.8 : 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .scaleEffect(isPressed ? 0.94 : 1.0)
                }
                .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedAction, key: action))
            }
        }
    }

    private func trigger(_ action: SystemQuickAction) {
        ChocPressFeedback.completeTap(key: action, pressedKey: $pressedAction)
        let now = ProcessInfo.processInfo.systemUptime
        let decision = confirmGate.registerTap(
            targetID: action.rawValue,
            isDestructive: action.requiresDestructiveConfirmation,
            at: now
        )
        switch decision {
        case .requireSecondTap:
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(CompanionInteractionPolicy.destructiveConfirmWindowSeconds + 0.05))
                confirmGate.expireIfNeeded(at: ProcessInfo.processInfo.systemUptime)
            }
        case .runImmediately, .confirmedRun:
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .rigid)
            if client.connectionState.isConnected {
                client.performQuickAction(action)
            } else {
                client.lastFeedback = CompanionFeedbackToast(
                    success: false,
                    title: action.compactTitle(in: lang),
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
            }
        }
    }
}

public struct WatchNowPlayingProgressRow: View {
    @ObservedObject var client: CompanionClientEngine
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    public init(client: CompanionClientEngine) { self.client = client }
    public var body: some View {
        if let media = client.controlStripState.nowPlaying, let title = media.primaryDisplayText {
            NavigationLink {
                WatchMediaPlayer(client: client)
            } label: {
                Label(title, systemImage: media.isPlaying ? "waveform" : "music.note")
                    .font(ChocType.title).lineLimit(2).frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(palette.primaryText)
            }
            .listRowBackground(palette.barSurface)
            .accessibilityIdentifier("watch-now-playing-row")
        }
    }
}

private struct WatchMediaPlayer: View {
    @ObservedObject var client: CompanionClientEngine
    @State private var pressedKey: String?
    @State private var suppressReleaseKey: String?
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let media = client.controlStripState.nowPlaying {
                    Text(media.primaryDisplayText ?? "").font(ChocType.title).lineLimit(2)
                    if let artist = media.artist { Text(artist).font(ChocType.caption) }
                    HStack(spacing: 6) {
                        transport(.mediaPrevious, symbol: "backward.fill")
                        transport(.mediaPlayPause, symbol: media.isPlaying ? "pause.fill" : "play.fill")
                        transport(.mediaNext, symbol: "forward.fill")
                    }
                    if media.isSeekable, let fraction = client.nowPlayingScrub.effectiveProgressFraction(for: media) {
                        Slider(value: Binding(get: { fraction }, set: {
                            _ = client.updateNowPlayingScrub(normalizedProgress: $0)
                        }), in: 0...1, onEditingChanged: { editing in
                            if !editing { _ = client.commitNowPlayingScrub(normalizedProgress: client.nowPlayingScrub.effectiveProgressFraction(for: client.controlStripState.nowPlaying) ?? fraction) }
                        }).tint(palette.accent)
                    }
                    if let times = NowPlayingProgressFormatter.rowDisplayContent(for: media, overrideElapsedSeconds: client.nowPlayingScrub.effectiveElapsedSeconds(for: media))?.progressText {
                        Text(times).font(ChocType.caption.monospacedDigit())
                    }
                }
            }.padding(8)
        }
        .foregroundStyle(palette.primaryText).background(palette.backgroundTop)
    }
    private func transport(_ action: SystemQuickAction, symbol: String) -> some View {
        Button {
            if suppressReleaseKey == action.rawValue { suppressReleaseKey = nil; return }
            client.performQuickAction(action)
        } label: {
            Image(systemName: symbol).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(WatchRepeatableQuickActionButtonStyle(pressedKey: $pressedKey, key: action.rawValue, action: action, suppressReleaseKey: $suppressReleaseKey) {
            client.performQuickAction(action)
        })
    }
}

private struct WatchRepeatableQuickActionButtonStyle: ButtonStyle {
    @Binding var pressedKey: String?
    let key: String
    let action: SystemQuickAction
    @Binding var suppressReleaseKey: String?
    let onRepeat: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { suppressReleaseKey = nil }
            }
            .task(id: configuration.isPressed) {
                guard configuration.isPressed, action == .mediaNext || action == .volumeUp || action == .volumeDown else { return }
                try? await Task.sleep(for: .milliseconds(400))
                while !Task.isCancelled {
                    suppressReleaseKey = key
                    onRepeat()
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
    }
}

// MARK: - 3. Watch App Time Travel Surface

public struct WatchTimeTravelView: View {
    @ObservedObject var client: CompanionClientEngine
    let onRequestPairing: () -> Void

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if !client.connectionState.isConnected {
                    WatchConnectionStateBanner(client: client, onTap: onRequestPairing)
                }

                Label(L10n.tr("最近应用", "Recent Apps", language: lang), systemImage: "clock.arrow.circlepath")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)

                if client.recentApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(ChocType.title)
                            .foregroundStyle(palette.secondaryText)
                        Text(
                            client.connectionState.isConnected
                                ? L10n.tr("在 Mac 上切换窗口后即会同步至此", "Switch windows on your Mac to sync here", language: lang)
                                : L10n.tr("连接 Mac 后可腕上一键切换窗口", "Connect your Mac to switch windows from your wrist", language: lang)
                        )
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    ForEach(client.recentApps) { entry in
                        recentAppRow(entry)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }

    private func recentAppRow(_ entry: RecentAppEntry) -> some View {
        let icon = client.appIconsByBundleID[entry.bundleIdentifier] ?? BundledAppIcons.pngData(for: entry.bundleIdentifier)

        return HStack(spacing: 6) {
            Button {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                client.activateRecentApp(entry)
            } label: {
                HStack(spacing: 8) {
                    DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                        .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.appName)
                            .font(ChocType.caption)
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        Text(
                            entry.isFrontmost
                                ? L10n.tr("当前前台", "Active", language: lang)
                                : (entry.isRunning ? L10n.tr("运行中", "Running", language: lang) : L10n.tr("已固定", "Pinned", language: lang))
                        )
                        .font(ChocType.micro)
                        .foregroundStyle(entry.isFrontmost ? palette.accent : palette.secondaryText)
                    }

                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                client.togglePinRecentApp(entry)
            } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                    .font(ChocType.caption)
                    .foregroundStyle(entry.isPinned ? palette.accent : palette.secondaryText.opacity(0.75))
                    .frame(width: 36, height: 36)
                    .background(palette.tileFillBottom.opacity(0.7), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(entry.isFrontmost ? palette.accent : palette.subtleCardStroke, lineWidth: entry.isFrontmost ? 1.6 : 1)
        )
    }
}

// MARK: - 4. Watch Emoji & Snippets Bar Surface (8 Synced Slides + Saved Snippet Slots)

public struct WatchEmojiBarView: View {
    private enum WatchTextMode: String, CaseIterable, Identifiable {
        case emoji
        case snippets
        var id: String { rawValue }
    }

    @ObservedObject var client: CompanionClientEngine
    @Binding var currentSlideIndex: Int
    let onRequestPairing: () -> Void

    @State private var mode: WatchTextMode = .emoji
    @State private var pressedEmojiIndex: Int?
    @State private var pressedSnippetID: UUID?
    @State private var pressedPasteKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var safeSlideIndex: Int {
        guard !client.profile.emojiSlides.isEmpty else { return 0 }
        return min(max(0, currentSlideIndex), client.profile.emojiSlides.count - 1)
    }

    private var activeSlide: EmojiSlide {
        guard !client.profile.emojiSlides.isEmpty else {
            return EmojiSlide(index: 0, title: "Favorites", iconEmoji: "⭐️", emojis: ["👍", "🔥", "✨", "❤️", "😂", "🙌", "🚀", "🍫"])
        }
        return client.profile.emojiSlides[safeSlideIndex]
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if !client.connectionState.isConnected {
                    WatchConnectionStateBanner(client: client, onTap: onRequestPairing)
                } else if client.isEditingTextOnMac {
                    HStack(spacing: 4) {
                        Image(systemName: "character.cursor.ibeam")
                            .font(ChocType.micro)
                        Text(L10n.tr("正在 \(client.focusedMacAppName ?? "Mac") 输入", "Typing in \(client.focusedMacAppName ?? "Mac")", language: lang))
                            .font(ChocType.micro)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(palette.statusConnected.opacity(0.22), in: Capsule())
                    .foregroundStyle(palette.statusConnected)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "character.cursor.ibeam")
                            .font(ChocType.micro)
                        Text(L10n.tr("请先在 Mac 点击输入框", "Focus a Mac text field", language: lang))
                            .font(ChocType.micro)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(palette.tileFillBottom, in: Capsule())
                    .foregroundStyle(palette.secondaryText)
                }

                watchPasteClipboardButton

                modeSegmentBar

                switch mode {
                case .emoji:
                    emojiSlideControlsAndGrid
                case .snippets:
                    savedSnippetsSlotsList
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }

    private var watchPasteClipboardButton: some View {
        let key = "watch-paste-clipboard"
        let isPressed = (pressedPasteKey == key)

        return Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedPasteKey)
            if client.connectionState.isConnected {
                client.pasteMacClipboard()
            } else {
                onRequestPairing()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.accent)
                Text(L10n.tr("粘贴剪贴板", "Paste Clipboard", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                LinearGradient(
                    colors: [isPressed ? palette.tileFillBottom : palette.tileFillTop, palette.tileFillBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isPressed ? palette.accent : palette.subtleCardStroke, lineWidth: isPressed ? 1.8 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedPasteKey, key: key))
        .accessibilityIdentifier("watch-paste-clipboard-button")
    }

    private var modeSegmentBar: some View {
        HStack(spacing: 4) {
            segmentPill(
                target: .emoji,
                symbol: "face.smiling.fill",
                label: L10n.tr("表情", "Emoji", language: lang)
            )
            segmentPill(
                target: .snippets,
                symbol: "text.quote",
                label: L10n.tr("片段", "Snippets", language: lang)
            )
        }
        .padding(3)
        .background(palette.tileFillBottom, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
    }

    private func segmentPill(target: WatchTextMode, symbol: String, label: String) -> some View {
        let selected = (mode == target)
        return Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            mode = target
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(ChocType.micro)
                Text(label)
                    .font(ChocType.micro)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? palette.accentForeground : palette.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(selected ? palette.accent : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emojiSlideControlsAndGrid: some View {
        HStack(spacing: 6) {
            Button {
                stepSlide(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 36, height: 36)
                    .background(palette.tileFillBottom, in: Circle())
                    .overlay(Circle().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 5) {
                Text(activeSlide.iconEmoji)
                    .font(ChocType.caption)
                Text(activeSlide.title)
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .padding(.horizontal, 6)
            .background(palette.barSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))

            Button {
                stepSlide(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 36, height: 36)
                    .background(palette.tileFillBottom, in: Circle())
                    .overlay(Circle().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }

        let cols = [
            GridItem(.flexible(), spacing: 7),
            GridItem(.flexible(), spacing: 7)
        ]

        LazyVGrid(columns: cols, spacing: 7) {
            ForEach(Array(activeSlide.emojis.enumerated()), id: \.offset) { idx, emoji in
                let isPressed = (pressedEmojiIndex == idx)

                Button {
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                    ChocPressFeedback.completeTap(key: idx, pressedKey: $pressedEmojiIndex)
                    if client.connectionState.isConnected {
                        client.insertEmoji(emoji)
                    } else {
                        onRequestPairing()
                    }
                } label: {
                    Text(emoji)
                        .font(ChocType.title)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            LinearGradient(
                                colors: [isPressed ? palette.tileFillBottom : palette.tileFillTop, palette.tileFillBottom],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(
                                    isPressed ? palette.accent : palette.tileBorderHighlight.opacity(0.48),
                                    lineWidth: isPressed ? 1.8 : 1
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .scaleEffect(isPressed ? 0.93 : 1.0)
                }
                .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedEmojiIndex, key: idx))
            }
        }
    }

    @ViewBuilder
    private var savedSnippetsSlotsList: some View {
        if client.profile.snippets.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(ChocType.title)
                    .foregroundStyle(palette.secondaryText)
                Text(
                    L10n.tr(
                        "在 iPhone 或 iPad 上新建片段后即可在腕上一键输入",
                        "Create snippets on iPhone or iPad to trigger them here",
                        language: lang
                    )
                )
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else {
            ForEach(client.profile.snippets) { snippet in
                let isPressed = (pressedSnippetID == snippet.id)

                Button {
                    if snippet.insertMode == .typeKeys,
                       !SnippetInsertPolicy.isModeAvailable(.typeKeys, isFieldFocused: client.isEditingTextOnMac) {
                        return
                    }
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                    ChocPressFeedback.completeTap(key: snippet.id, pressedKey: $pressedSnippetID)
                    if client.connectionState.isConnected {
                        _ = client.triggerSnippet(snippet)
                    } else {
                        onRequestPairing()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snippet.displayTitle(in: lang))
                            .font(ChocType.caption)
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)

                        Text(snippet.singleLinePreview)
                            .font(ChocType.micro)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 46)
                    .background(
                        LinearGradient(
                            colors: [isPressed ? palette.tileFillBottom : palette.tileFillTop, palette.tileFillBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(
                                isPressed ? palette.accent : palette.tileBorderHighlight.opacity(0.55),
                                lineWidth: isPressed ? 1.8 : 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .scaleEffect(isPressed ? 0.94 : 1.0)
                }
                .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedSnippetID, key: snippet.id))
            }
        }
    }

    private func stepSlide(by delta: Int) {
        let count = client.profile.emojiSlides.count
        guard count > 0 else { return }
        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
        currentSlideIndex = (safeSlideIndex + delta + count) % count
    }
}

private struct WatchTileFolderSheet: View {
    @ObservedObject var client: CompanionClientEngine
    let pageIndex: Int
    let slotIndex: Int
    @Environment(\.dismiss) private var dismiss

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var folderContext: (page: BarPage, folder: TileFolder)? {
        guard client.profile.pages.indices.contains(pageIndex) else { return nil }
        let page = client.profile.pages[pageIndex]
        guard page.slots.indices.contains(slotIndex),
              case .folder(let folder) = page.slots[slotIndex]?.kind else { return nil }
        return (page, folder)
    }

    var body: some View {
        List {
            if let ctx = folderContext {
                let origin = SlotCoordinate(pageID: ctx.page.id, slotIndex: slotIndex)
                Section("\(ctx.folder.emoji) \(ctx.folder.displayTitle(in: lang))") {
                    if ctx.folder.children.isEmpty {
                        Text(L10n.tr("暂无子动作", "No Child Actions", language: lang))
                            .font(ChocType.caption)
                            .foregroundStyle(palette.secondaryText)
                    } else {
                        ForEach(ctx.folder.children) { child in
                            Button {
                                CompanionFeedbackHaptics.tap(
                                    enabled: client.profile.settings.hapticFeedbackEnabled,
                                    intensity: .medium
                                )
                                if client.connectionState.isConnected {
                                    client.triggerBarItem(child, from: origin)
                                } else {
                                    client.recordOfflineTileFailure(
                                        slot: origin,
                                        title: client.profile.displayTitle(for: child, in: lang),
                                        detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                                    )
                                }
                                dismiss()
                            } label: {
                                HStack {
                                    Text(client.profile.displayTitle(for: child, in: lang))
                                        .font(ChocType.caption)
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                    Spacer()
                                    if let ago = client.lastTriggeredText(for: child) {
                                        Text(ago)
                                            .font(ChocType.micro.monospacedDigit())
                                            .foregroundStyle(palette.secondaryText)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Watch Audio Output Picker Sheet

public struct WatchAudioOutputPickerSheet: View {
    @ObservedObject var client: CompanionClientEngine

    @State private var awaitingSwitchFeedback: Bool = false
    @State private var sheetFeedback: CompanionFeedbackToast?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var state: ControlStripState { client.controlStripState }
    private var isConnected: Bool { client.connectionState.isConnected }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        let selectedID = state.currentAudioOutputDevice?.id

        List {
            if let feedback = sheetFeedback {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: feedback.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(ChocType.caption)
                        .foregroundStyle(feedback.success ? palette.statusConnected : palette.statusFailure)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(feedback.title)
                            .font(ChocType.micro)
                            .foregroundStyle(palette.primaryText)
                        if let detail = feedback.detail, !detail.isEmpty {
                            Text(detail)
                                .font(ChocType.micro)
                                .foregroundStyle(feedback.success ? palette.secondaryText : palette.statusFailure)
                        }
                    }
                }
                .listRowBackground((feedback.success ? palette.statusConnected : palette.statusFailure).opacity(0.14))
            }

            if !isConnected {
                Text(L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    .listRowBackground(palette.barSurface)
            } else if !state.canSwitchAudioOutput {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(ChocType.micro)
                        .foregroundStyle(palette.accentEmphasis)
                    Text(L10n.tr("音频输出只读", "Audio Output Read-Only", language: lang))
                        .font(ChocType.micro)
                        .foregroundStyle(palette.secondaryText)
                }
                .listRowBackground(palette.tileFillBottom)
            }

            if isConnected && state.audioOutputDevices.isEmpty {
                Text(L10n.tr("无可用音频输出设备", "No Audio Outputs", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    .listRowBackground(palette.barSurface)
            } else if isConnected {
                ForEach(state.audioOutputDevices) { device in
                    let isSelected = (device.id == selectedID)
                    let isRowEnabled = state.canSwitchAudioOutput && device.isSelectable
                    Button {
                        guard isRowEnabled else { return }
                        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                        sheetFeedback = nil
                        awaitingSwitchFeedback = true
                        client.selectAudioOutputDevice(id: device.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Image(systemName: device.sfSymbol)
                                    .font(ChocType.caption)
                                    .foregroundStyle(isSelected ? palette.statusConnected : (isRowEnabled ? palette.accent : palette.secondaryText))
                                Text(device.name)
                                    .font(ChocType.caption)
                                    .foregroundStyle(isRowEnabled || isSelected ? palette.primaryText : palette.secondaryText)
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(ChocType.caption)
                                        .foregroundStyle(palette.statusConnected)
                                } else if !isRowEnabled {
                                    Image(systemName: device.isAirPlay ? "airplayaudio" : "lock")
                                        .font(ChocType.micro)
                                        .foregroundStyle(palette.secondaryText.opacity(0.65))
                                }
                            }
                            if let unavailableDetail = device.selectionUnavailableReason(in: lang) {
                                Text(unavailableDetail)
                                    .font(ChocType.micro)
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(2)
                            }
                        }
                        .frame(minHeight: 38)
                        .opacity(isRowEnabled || isSelected ? 1.0 : 0.72)
                    }
                    .disabled(!isRowEnabled)
                    .listRowBackground(palette.barSurface)
                    .accessibilityIdentifier("watch-audio-output-device-\(device.id)")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .onReceive(client.$lastFeedback) { newFeedback in
            guard awaitingSwitchFeedback, let newFeedback else { return }
            awaitingSwitchFeedback = false
            sheetFeedback = newFeedback
            CompanionFeedbackHaptics.notify(
                enabled: client.profile.settings.hapticFeedbackEnabled,
                kind: newFeedback.success ? .success : .error
            )
        }
    }
}
