import ChocliftCore
import SwiftUI

public struct IOSEditSlotSelection: Identifiable {
    public let pageIndex: Int
    public let slotIndex: Int
    public var id: String { "\(pageIndex)-\(slotIndex)" }

    public init(pageIndex: Int, slotIndex: Int) {
        self.pageIndex = pageIndex
        self.slotIndex = slotIndex
    }
}

struct TileHoldToEditButtonStyle: ButtonStyle {
    @Binding var pressedKey: String?
    let key: String
    let isSuppressed: Bool
    let holdDurationSeconds: TimeInterval
    var repeatableAction: SystemQuickAction? = nil
    var onRepeatBegan: (() -> Void)? = nil
    var onRepeatFire: (() -> Void)? = nil
    let onTouchDown: () -> Void
    let onTouchEnded: () -> Void
    let onLongPressHold: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        TileHoldToEditLabelView(
            configuration: configuration,
            pressedKey: $pressedKey,
            key: key,
            isSuppressed: isSuppressed,
            holdDurationSeconds: holdDurationSeconds,
            repeatableAction: repeatableAction,
            onRepeatBegan: onRepeatBegan,
            onRepeatFire: onRepeatFire,
            onTouchDown: onTouchDown,
            onTouchEnded: onTouchEnded,
            onLongPressHold: onLongPressHold
        )
    }
}

private struct TileHoldToEditLabelView: View {
    let configuration: ButtonStyle.Configuration
    @Binding var pressedKey: String?
    let key: String
    let isSuppressed: Bool
    let holdDurationSeconds: TimeInterval
    let repeatableAction: SystemQuickAction?
    let onRepeatBegan: (() -> Void)?
    let onRepeatFire: (() -> Void)?
    let onTouchDown: () -> Void
    let onTouchEnded: () -> Void
    let onLongPressHold: () -> Void

    var body: some View {
        let isHolding = configuration.isPressed && !isSuppressed

        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    guard !isSuppressed else { return }
                    onTouchDown()
                    ChocPressFeedback.beginPress(key: key, pressedKey: $pressedKey)
                } else {
                    let keySnapshot = key
                    let binding = $pressedKey
                    let ended = onTouchEnded
                    DispatchQueue.main.async {
                        if !ChocPressFeedback.hasActiveHold(for: keySnapshot) {
                            ChocPressFeedback.cancelPressImmediately(key: keySnapshot, pressedKey: binding)
                        }
                        ended()
                    }
                }
            }
            .onChange(of: isSuppressed) { _, suppressed in
                if suppressed {
                    ChocPressFeedback.cancelPressImmediately(key: key, pressedKey: $pressedKey)
                }
            }
            .task(id: isHolding) {
                guard isHolding else { return }
                if let repeatableAction, HoldToRepeatPolicy.supportsHoldToRepeat(repeatableAction) {
                    // Brief stationary slop so horizontal page swipes cancel cleanly and quick taps run once on release.
                    try? await Task.sleep(for: .milliseconds(70))
                    guard !Task.isCancelled, configuration.isPressed, !isSuppressed else { return }

                    var repeatController = HoldToRepeatController()
                    let startedAt = ProcessInfo.processInfo.systemUptime
                    guard repeatController.beginHold(for: repeatableAction, at: startedAt) else { return }
                    onRepeatBegan?()
                    onRepeatFire?()

                    while !Task.isCancelled && configuration.isPressed && !isSuppressed {
                        try? await Task.sleep(for: .milliseconds(40))
                        guard !Task.isCancelled, configuration.isPressed, !isSuppressed else {
                            repeatController.endHold()
                            return
                        }
                        let now = ProcessInfo.processInfo.systemUptime
                        if repeatController.shouldFireRepeat(at: now) {
                            onRepeatFire?()
                        }
                    }
                    repeatController.endHold()
                } else {
                    try? await Task.sleep(for: .seconds(max(0.25, holdDurationSeconds)))
                    guard !Task.isCancelled, configuration.isPressed, !isSuppressed else { return }
                    ChocPressFeedback.cancelPressImmediately(key: key, pressedKey: $pressedKey)
                    onLongPressHold()
                }
            }
            .onDisappear {
                ChocPressFeedback.cancelPressImmediately(key: key, pressedKey: $pressedKey)
            }
    }
}

// MARK: - 1. Chocolate Bar Surface (8 Pages x 8 Slots)

public struct IOSChocolateBarSurfaceView: View {
    @ObservedObject var client: CompanionClientEngine
    @Binding var currentPageIndex: Int
    var isFollowingFrontmostApp: Bool
    var isDeckSwitchHighlighted: Bool
    var onFollowFrontmostApp: (() -> Void)?
    let isLandscape: Bool
    var onPromptHUD: ((String) -> Void)?
    let onEditSlot: (IOSEditSlotSelection) -> Void

    @State private var pressedKey: String?
    @State private var confirmGate = DestructiveActionConfirmGate()
    @State private var suppressedLongPressKey: String?
    @State private var openFolderSelection: IOSTileFolderSelection?
    @GestureState private var activePageDragTranslation: CGSize = .zero
    @State private var didCancelTapInActiveDrag: Bool = false

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        currentPageIndex: Binding<Int>,
        isFollowingFrontmostApp: Bool = true,
        isDeckSwitchHighlighted: Bool = false,
        onFollowFrontmostApp: (() -> Void)? = nil,
        isLandscape: Bool,
        onPromptHUD: ((String) -> Void)? = nil,
        onEditSlot: @escaping (IOSEditSlotSelection) -> Void
    ) {
        self.client = client
        self._currentPageIndex = currentPageIndex
        self.isFollowingFrontmostApp = isFollowingFrontmostApp
        self.isDeckSwitchHighlighted = isDeckSwitchHighlighted
        self.onFollowFrontmostApp = onFollowFrontmostApp
        self.isLandscape = isLandscape
        self.onPromptHUD = onPromptHUD
        self.onEditSlot = onEditSlot
    }

    private var activeBoundDeckContext: (appName: String, page: BarPage)? {
        guard isFollowingFrontmostApp,
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
        VStack(spacing: 0) {
            if !isFollowingFrontmostApp, let onFollowFrontmostApp {
                manualPinnedHeader(onFollow: onFollowFrontmostApp)
            } else if let bound = activeBoundDeckContext {
                followingAppHeader(appName: bound.appName, page: bound.page)
            }

            barHorizontalPager
        }
        .onChange(of: currentPageIndex) { _, _ in
            confirmGate.disarm()
        }
        .onChange(of: activePageDragTranslation == .zero) { _, isIdle in
            if isIdle && didCancelTapInActiveDrag {
                DispatchQueue.main.async {
                    didCancelTapInActiveDrag = false
                }
            }
        }
        .sheet(item: $openFolderSelection) { selection in
            IOSTileFolderSheet(
                client: client,
                pageIndex: selection.pageIndex,
                slotIndex: selection.slotIndex,
                onPromptHUD: onPromptHUD,
                onEditFolderSlot: onEditSlot
            )
        }
    }

    private var barHorizontalPager: some View {
        GeometryReader { pagerGeo in
            let pageWidth = max(1, pagerGeo.size.width)
            let pageHeight = max(1, pagerGeo.size.height)
            let pages = client.profile.pages
            let pageCount = pages.count
            let safeIdx = pageCount > 0 ? min(max(0, currentPageIndex), pageCount - 1) : 0
            let dragOffset = interactiveDragOffset(
                translation: activePageDragTranslation,
                safeIndex: safeIdx,
                pageCount: pageCount,
                pageWidth: pageWidth
            )

            HStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { pageOffset, page in
                    pageGrid(for: page, pageOffset: pageOffset)
                        .frame(width: pageWidth, height: pageHeight)
                        .allowsHitTesting(pageOffset == safeIdx)
                        .accessibilityHidden(pageOffset != safeIdx)
                }
            }
            .offset(x: -CGFloat(safeIdx) * pageWidth + dragOffset)
            .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.88), value: activePageDragTranslation)
            .frame(width: pageWidth, height: pageHeight, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(
                    minimumDistance: BarTouchGestureThresholds.maxTapMovementPoints,
                    coordinateSpace: .local
                )
                .updating($activePageDragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onChanged { value in
                    if BarTouchGestureThresholds.shouldCancelPress(translation: value.translation) {
                        if !didCancelTapInActiveDrag {
                            didCancelTapInActiveDrag = true
                        }
                        if let currentKey = pressedKey {
                            ChocPressFeedback.cancelPressImmediately(key: currentKey, pressedKey: $pressedKey)
                        }
                    }
                }
                .onEnded { value in
                    let targetIdx = BarTouchGestureThresholds.resolvedPageIndex(
                        currentIndex: safeIdx,
                        pageCount: pageCount,
                        translation: value.translation
                    )
                    if targetIdx != safeIdx {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            currentPageIndex = targetIdx
                        }
                    }
                    DispatchQueue.main.async {
                        didCancelTapInActiveDrag = false
                    }
                }
            )
        }
    }

    private func interactiveDragOffset(
        translation: CGSize,
        safeIndex: Int,
        pageCount: Int,
        pageWidth: CGFloat
    ) -> CGFloat {
        guard BarTouchGestureThresholds.shouldCancelPress(translation: translation),
              abs(translation.width) >= abs(translation.height) else {
            return 0
        }
        let raw = translation.width
        let atLeadingEdge = safeIndex <= 0 && raw > 0
        let atTrailingEdge = safeIndex >= max(0, pageCount - 1) && raw < 0
        let damped = (atLeadingEdge || atTrailingEdge) ? (raw * 0.28) : raw
        return min(max(damped, -pageWidth * 0.92), pageWidth * 0.92)
    }

    private func manualPinnedHeader(onFollow: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "pin.fill")
                    .font(.caption2.bold())
                Text(L10n.tr("已固定当前页", "Page Pinned", language: lang))
                    .font(.caption2.bold())
                    .lineLimit(1)
            }
            .foregroundStyle(palette.secondaryText)

            Spacer(minLength: 6)

            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                onFollow()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2.bold())
                    Text(L10n.tr("跟随前台应用", "Follow Frontmost App", language: lang))
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(palette.accent, in: Capsule())
                .foregroundStyle(palette.accentForeground)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-follow-frontmost-app-button")
        }
        .padding(.horizontal, isLandscape ? 14 : 16)
        .padding(.top, 8)
    }

    private func followingAppHeader(appName: String, page: BarPage) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "macwindow")
                    .font(.caption2.bold())
                Text(
                    L10n.tr(
                        "正跟随 \(appName) · \(page.iconEmoji) \(page.title)",
                        "Following \(appName) · \(page.iconEmoji) \(page.title)",
                        language: lang
                    )
                )
                .font(.caption2.bold())
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                palette.accent.opacity(isDeckSwitchHighlighted ? 0.24 : 0.14),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isDeckSwitchHighlighted ? palette.accent : palette.accent.opacity(0.28),
                        lineWidth: isDeckSwitchHighlighted ? 1.5 : 0.8
                    )
            )
            .foregroundStyle(palette.accent)
            .scaleEffect(isDeckSwitchHighlighted ? 1.03 : 1.0)
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isDeckSwitchHighlighted)
            .accessibilityIdentifier("ios-following-app-header")

            Spacer()
        }
        .padding(.horizontal, isLandscape ? 14 : 16)
        .padding(.top, 8)
    }

    private func pageGrid(for page: BarPage, pageOffset: Int) -> some View {
        let colCount = isLandscape ? 4 : 2
        let rowCount = isLandscape ? 2 : 4

        return GeometryReader { geo in
            let spacing: CGFloat = isLandscape ? 12 : 12
            let horizontalPad: CGFloat = isLandscape ? 14 : 16
            let verticalPad: CGFloat = isLandscape ? 12 : 10
            let availW = max(80, geo.size.width - horizontalPad * 2 - spacing * CGFloat(colCount - 1))
            let availH = max(80, geo.size.height - verticalPad * 2 - spacing * CGFloat(rowCount - 1))
            let tileW = availW / CGFloat(colCount)
            let tileH = availH / CGFloat(rowCount)

            TimelineView(.periodic(from: .now, by: 15.0)) { timeline in
                VStack(spacing: spacing) {
                    ForEach(0..<rowCount, id: \.self) { row in
                        HStack(spacing: spacing) {
                            ForEach(0..<colCount, id: \.self) { col in
                                let slotIdx = row * colCount + col
                                let item = page.slots[slotIdx]
                                let key = "\(pageOffset)-\(slotIdx)"
                                let slotOrigin = SlotCoordinate(pageID: page.id, slotIndex: slotIdx)
                                let effectiveItem = item.flatMap { client.profile.resolveBarItem($0, from: slotOrigin).resolvedItem }
                                let iconData = effectiveItem?.bundleIdentifier.flatMap {
                                    client.appIconsByBundleID[$0] ?? BundledAppIcons.pngData(for: $0)
                                }
                                let isFrontmost = (effectiveItem?.bundleIdentifier != nil && effectiveItem?.bundleIdentifier == client.frontmostBundleID)

                                tileButton(
                                    pageIndex: pageOffset,
                                    slotIndex: slotIdx,
                                    slotOrigin: slotOrigin,
                                    key: key,
                                    item: item,
                                    effectiveItem: effectiveItem,
                                    iconData: iconData,
                                    isFrontmost: isFrontmost,
                                    now: timeline.date
                                )
                                .frame(width: tileW, height: tileH)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, horizontalPad)
                .padding(.vertical, verticalPad)
            }
        }
    }

    private func tileButton(
        pageIndex: Int,
        slotIndex: Int,
        slotOrigin: SlotCoordinate,
        key: String,
        item: BarItem?,
        effectiveItem: BarItem?,
        iconData: Data?,
        isFrontmost: Bool,
        now: Date
    ) -> some View {
        let isPressed = (pressedKey == key)
        let isAwaitingConfirm = (item != nil) && confirmGate.isArmed(
            targetID: key,
            at: ProcessInfo.processInfo.systemUptime
        )
        let lastRunOutcome = client.tileOutcome(for: slotOrigin)
        let lastTriggeredText = client.lastTriggeredText(for: item, from: slotOrigin, now: now)
        let repeatableAction: SystemQuickAction? = {
            guard let effectiveItem,
                  case .systemAction(let action, _, _) = effectiveItem.kind,
                  HoldToRepeatPolicy.supportsHoldToRepeat(action) else {
                return nil
            }
            return action
        }()

        return Button {
            handleTileShortTap(
                pageIndex: pageIndex,
                slotIndex: slotIndex,
                slotOrigin: slotOrigin,
                key: key,
                item: item
            )
        } label: {
            ChocBarTileCard(
                item: item,
                iconData: iconData,
                isFrontmostApp: isFrontmost,
                isPressed: isPressed,
                isAwaitingConfirmation: isAwaitingConfirm,
                lastRunOutcome: lastRunOutcome,
                palette: palette,
                language: lang,
                compact: true,
                profile: client.profile,
                slotOrigin: slotOrigin,
                lastTriggeredText: lastTriggeredText,
                iconLookup: { bundleID in
                    client.appIconsByBundleID[bundleID] ?? BundledAppIcons.pngData(for: bundleID)
                }
            )
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(
            TileHoldToEditButtonStyle(
                pressedKey: $pressedKey,
                key: key,
                isSuppressed: didCancelTapInActiveDrag,
                holdDurationSeconds: CompanionInteractionPolicy.tileLongPressDurationSeconds,
                repeatableAction: repeatableAction,
                onRepeatBegan: {
                    suppressedLongPressKey = key
                    confirmGate.disarm()
                },
                onRepeatFire: {
                    guard let item else { return }
                    fireTileActionImmediately(item: item, slotOrigin: slotOrigin)
                },
                onTouchDown: {
                    suppressedLongPressKey = nil
                    if activePageDragTranslation == .zero {
                        didCancelTapInActiveDrag = false
                    }
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
                    onEditSlot(IOSEditSlotSelection(pageIndex: pageIndex, slotIndex: slotIndex))
                }
            )
        )
        .accessibilityIdentifier("ios-slot-\(pageIndex)-\(slotIndex)")
        .accessibilityLabel(
            EmptySlotHintPolicy.accessibilityLabel(
                for: item,
                slotIndex: slotIndex,
                resolvedFilledTitle: item.map { client.profile.displayTitle(for: $0, from: slotOrigin, in: lang) },
                language: lang
            )
        )
    }

    private func handleTileShortTap(
        pageIndex: Int,
        slotIndex: Int,
        slotOrigin: SlotCoordinate,
        key: String,
        item: BarItem?
    ) {
        if suppressedLongPressKey == key {
            suppressedLongPressKey = nil
            return
        }
        guard !didCancelTapInActiveDrag,
              !BarTouchGestureThresholds.shouldCancelPress(translation: activePageDragTranslation) else {
            return
        }

        ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)

        guard let item else {
            confirmGate.disarm()
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            onEditSlot(IOSEditSlotSelection(pageIndex: pageIndex, slotIndex: slotIndex))
            return
        }

        if item.isFolder {
            confirmGate.disarm()
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            openFolderSelection = IOSTileFolderSelection(pageIndex: pageIndex, slotIndex: slotIndex)
            return
        }

        // If a reference tile's target slot was deleted, stay quiet and do not run anything.
        if item.isSlotReference,
           client.profile.resolveBarItem(item, from: slotOrigin).isMissing {
            confirmGate.disarm()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let isDestructive = item.requiresDestructiveConfirmation(in: client.profile, from: slotOrigin)
        let decision = confirmGate.registerTap(
            targetID: key,
            isDestructive: isDestructive,
            at: now
        )
        let resolvedTitle = client.profile.displayTitle(for: item, from: slotOrigin, in: lang)

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
            fireTileActionImmediately(item: item, slotOrigin: slotOrigin)
        }
    }

    private func fireTileActionImmediately(item: BarItem, slotOrigin: SlotCoordinate) {
        let resolvedTitle = client.profile.displayTitle(for: item, from: slotOrigin, in: lang)
        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
        if client.connectionState.isConnected {
            client.triggerBarItem(item, from: slotOrigin)
        } else {
            client.recordOfflineTileFailure(
                slot: slotOrigin,
                title: resolvedTitle,
                detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
            )
        }
    }
}

// MARK: - 2. App Time Travel Surface

public struct IOSTimeTravelSurfaceView: View {
    @ObservedObject var client: CompanionClientEngine
    let isLandscape: Bool
    let currentBarPageIndex: Int
    var onRequestPairing: (() -> Void)?
    var onPromptHUD: ((String) -> Void)?

    @State private var quitConfirmGate = DestructiveActionConfirmGate()

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        isLandscape: Bool,
        currentBarPageIndex: Int,
        onRequestPairing: (() -> Void)? = nil,
        onPromptHUD: ((String) -> Void)? = nil
    ) {
        self.client = client
        self.isLandscape = isLandscape
        self.currentBarPageIndex = currentBarPageIndex
        self.onRequestPairing = onRequestPairing
        self.onPromptHUD = onPromptHUD
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.tr("应用时间旅行", "App Time Travel", language: lang), systemImage: "clock.arrow.circlepath")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                Spacer()

                Text(L10n.tr("点按切换 · 长按固定或退出", "Tap to switch · Hold to Pin or Quit", language: lang))
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if client.recentApps.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: client.connectionState.isConnected ? "clock" : "laptopcomputer.slash")
                        .font(.system(size: 30))
                        .foregroundStyle(palette.secondaryText)

                    Text(
                        client.connectionState.isConnected
                            ? L10n.tr("暂无最近切换的 Mac 应用", "No Recent Mac Apps Yet", language: lang)
                            : L10n.tr("连接 Mac 后开启时间旅行", "Connect Your Mac for Time Travel", language: lang)
                    )
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                    Text(
                        client.connectionState.isConnected
                            ? L10n.tr("在 Mac 上任意切换窗口后，最近使用的应用会立即出现在这里。", "Switch windows on your Mac and recent apps will appear here automatically.", language: lang)
                            : L10n.tr("配对并连接 Mac 后，无需按 ⌘Tab 即可在此一键穿梭最近打开的窗口。", "Pair your Mac to jump across recently active windows with a single tap.", language: lang)
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                    if !client.connectionState.isConnected, let onRequestPairing {
                        Button {
                            onRequestPairing()
                        } label: {
                            Text(L10n.tr("连接 Mac", "Connect to Mac", language: lang))
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(palette.accentForeground)
                                .padding(.horizontal, 16)
                                .frame(height: 38)
                                .background(palette.accent, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                Spacer()
            } else {
                let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: isLandscape ? 4 : 2)
                ScrollView {
                    VStack(spacing: 12) {
                        IOSFrontmostWindowsInlineCard(client: client)

                        LazyVGrid(columns: cols, spacing: 12) {
                            ForEach(client.recentApps) { entry in
                                recentAppCard(entry)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private func recentAppCard(_ entry: RecentAppEntry) -> some View {
        let icon = client.appIconsByBundleID[entry.bundleIdentifier] ?? BundledAppIcons.pngData(for: entry.bundleIdentifier)
        let quitKey = "quit-\(entry.bundleIdentifier)"
        let isAwaitingQuitConfirm = quitConfirmGate.isArmed(
            targetID: quitKey,
            at: ProcessInfo.processInfo.systemUptime
        )

        return Button {
            if isAwaitingQuitConfirm {
                let decision = quitConfirmGate.registerTap(
                    targetID: quitKey,
                    isDestructive: true,
                    at: ProcessInfo.processInfo.systemUptime
                )
                if decision == .confirmedRun {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                    client.quitOrHideApp(bundleIdentifier: entry.bundleIdentifier, shouldQuit: true)
                }
                return
            }
            quitConfirmGate.disarm()
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            client.activateRecentApp(entry)
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                        .frame(width: 46, height: 46)

                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.secondaryText)
                            .padding(4)
                            .background(palette.backgroundBottom.opacity(0.85), in: Circle())
                            .offset(x: 6, y: -4)
                    }
                }

                Text(entry.appName)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                if isAwaitingQuitConfirm {
                    Text(L10n.tr("再点确认退出", "Tap Again to Quit", language: lang))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.emphasisForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(palette.statusFailure, in: Capsule())
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(entry.isFrontmost ? palette.accent : (entry.isRunning ? palette.statusConnected : palette.secondaryText.opacity(0.5)))
                            .frame(width: 5.5, height: 5.5)
                        Text(
                            entry.isFrontmost
                                ? L10n.tr("当前窗口", "Active", language: lang)
                                : (entry.isRunning ? L10n.tr("运行中", "Running", language: lang) : L10n.tr("已固定", "Pinned", language: lang))
                        )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [palette.tileFillTop, palette.tileFillBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isAwaitingQuitConfirm
                                    ? palette.statusFailure
                                    : (entry.isFrontmost ? palette.accent : palette.tileBorderHighlight.opacity(0.45)),
                                lineWidth: (isAwaitingQuitConfirm || entry.isFrontmost) ? 2 : 1
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                client.togglePinRecentApp(entry)
            } label: {
                Label(
                    entry.isPinned ? L10n.tr("取消固定", "Unpin", language: lang) : L10n.tr("固定到最前", "Pin Favorite", language: lang),
                    systemImage: entry.isPinned ? "pin.slash" : "pin.fill"
                )
            }

            Button {
                addRecentAppToBar(entry)
            } label: {
                Label(L10n.tr("添加到当前巧克力栏页", "Add to Chocolate Bar Page", language: lang), systemImage: "plus.square.on.square")
            }

            if entry.isRunning {
                Divider()
                Button {
                    client.quitOrHideApp(bundleIdentifier: entry.bundleIdentifier, shouldQuit: false)
                } label: {
                    Label(L10n.tr("隐藏窗口", "Hide App on Mac", language: lang), systemImage: "eye.slash")
                }

                Button(role: .destructive) {
                    handleQuitRecentApp(entry)
                } label: {
                    Label(L10n.tr("退出应用", "Quit App on Mac", language: lang), systemImage: "xmark.octagon")
                }
            }
        }
    }

    private func handleQuitRecentApp(_ entry: RecentAppEntry) {
        let quitKey = "quit-\(entry.bundleIdentifier)"
        let decision = quitConfirmGate.registerTap(
            targetID: quitKey,
            isDestructive: true,
            at: ProcessInfo.processInfo.systemUptime
        )
        switch decision {
        case .requireSecondTap:
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            onPromptHUD?(
                L10n.tr(
                    "3 秒内点按 \(entry.appName) 确认退出",
                    "Tap \(entry.appName) within 3s to confirm Quit",
                    language: lang
                )
            )
            let delay = CompanionInteractionPolicy.destructiveConfirmWindowSeconds + 0.05
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(.easeInOut(duration: 0.18)) {
                    quitConfirmGate.expireIfNeeded(at: ProcessInfo.processInfo.systemUptime)
                }
            }
        case .runImmediately, .confirmedRun:
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            client.quitOrHideApp(bundleIdentifier: entry.bundleIdentifier, shouldQuit: true)
        }
    }

    private func addRecentAppToBar(_ entry: RecentAppEntry) {
        var updated = client.profile
        guard updated.pages.indices.contains(currentBarPageIndex),
              let emptyIdx = updated.pages[currentBarPageIndex].slots.firstIndex(where: { $0 == nil }) else {
            return
        }
        updated.pages[currentBarPageIndex].slots[emptyIdx] = BarItem(
            kind: .macApp(bundleIdentifier: entry.bundleIdentifier, appName: entry.appName, appPath: entry.appPath)
        )
        client.pushUpdatedProfile(updated)
    }
}

// MARK: - 3. Emoji Bar & Snippets Surface (8 Slides + Quick Catalog + One-Tap Snippets)

public enum IOSEmojiBarSegment: String, CaseIterable, Identifiable, Sendable {
    case emoji
    case snippets
    case clipboard

    public var id: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .emoji: return "face.smiling.fill"
        case .snippets: return "text.quote"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .emoji: return L10n.tr("表情", "Emoji", language: lang)
        case .snippets: return L10n.tr("片段", "Snippets", language: lang)
        case .clipboard: return L10n.tr("剪贴板", "Clipboard", language: lang)
        }
    }
}

private enum IOSSnippetEditorSession: Identifiable {
    case create
    case rename(TextSnippet)
    case edit(TextSnippet)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .rename(let snippet):
            return "rename-\(snippet.id.uuidString)"
        case .edit(let snippet):
            return "edit-\(snippet.id.uuidString)"
        }
    }
}

public struct IOSEmojiBarSurfaceView: View {
    @ObservedObject var client: CompanionClientEngine
    @Binding var currentSlideIndex: Int
    @Binding var activeSegment: IOSEmojiBarSegment
    let isLandscape: Bool

    @State private var showAllCatalogSheet = false
    @State private var customizingSlotIndex: Int?
    @State private var snippetEditorSession: IOSSnippetEditorSession?
    @State private var pressedSnippetID: UUID?
    @State private var pressedEmojiKey: String?
    @GestureState private var activeEmojiDragTranslation: CGSize = .zero
    @State private var didCancelEmojiTapInActiveDrag: Bool = false

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        currentSlideIndex: Binding<Int>,
        activeSegment: Binding<IOSEmojiBarSegment> = .constant(.emoji),
        isLandscape: Bool
    ) {
        self.client = client
        self._currentSlideIndex = currentSlideIndex
        self._activeSegment = activeSegment
        self.isLandscape = isLandscape
    }

    public var body: some View {
        VStack(spacing: 6) {
            emojiAndSnippetsHeader
                .padding(.horizontal, 16)
                .padding(.top, 8)

            switch activeSegment {
            case .emoji:
                emojiHorizontalPager

            case .snippets:
                snippetsSurfaceContent

            case .clipboard:
                IOSClipboardPreviewCard(client: client, expanded: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onChange(of: activeEmojiDragTranslation == .zero) { _, isIdle in
            if isIdle && didCancelEmojiTapInActiveDrag {
                DispatchQueue.main.async {
                    didCancelEmojiTapInActiveDrag = false
                }
            }
        }
        .sheet(isPresented: $showAllCatalogSheet) {
            emojiBrowserSheet
        }
        .sheet(item: $snippetEditorSession) { session in
            IOSSnippetEditorSheet(client: client, session: session)
        }
    }

    private var emojiHorizontalPager: some View {
        GeometryReader { pagerGeo in
            let pageWidth = max(1, pagerGeo.size.width)
            let pageHeight = max(1, pagerGeo.size.height)
            let slides = client.profile.emojiSlides
            let slideCount = slides.count
            let safeIdx = slideCount > 0 ? min(max(0, currentSlideIndex), slideCount - 1) : 0
            let dragOffset: CGFloat = {
                guard BarTouchGestureThresholds.shouldCancelPress(translation: activeEmojiDragTranslation),
                      abs(activeEmojiDragTranslation.width) >= abs(activeEmojiDragTranslation.height) else {
                    return 0
                }
                let raw = activeEmojiDragTranslation.width
                let atStart = safeIdx <= 0 && raw > 0
                let atEnd = safeIdx >= max(0, slideCount - 1) && raw < 0
                let damped = (atStart || atEnd) ? (raw * 0.28) : raw
                return min(max(damped, -pageWidth * 0.92), pageWidth * 0.92)
            }()

            HStack(spacing: 0) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { slideOffset, slide in
                    emojiSlideGrid(slide, slideOffset: slideOffset)
                        .frame(width: pageWidth, height: pageHeight)
                        .allowsHitTesting(slideOffset == safeIdx)
                        .accessibilityHidden(slideOffset != safeIdx)
                }
            }
            .offset(x: -CGFloat(safeIdx) * pageWidth + dragOffset)
            .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.88), value: activeEmojiDragTranslation)
            .frame(width: pageWidth, height: pageHeight, alignment: .leading)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(
                    minimumDistance: BarTouchGestureThresholds.maxTapMovementPoints,
                    coordinateSpace: .local
                )
                .updating($activeEmojiDragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onChanged { value in
                    if BarTouchGestureThresholds.shouldCancelPress(translation: value.translation) {
                        if !didCancelEmojiTapInActiveDrag {
                            didCancelEmojiTapInActiveDrag = true
                        }
                        if let currentKey = pressedEmojiKey {
                            ChocPressFeedback.cancelPressImmediately(key: currentKey, pressedKey: $pressedEmojiKey)
                        }
                    }
                }
                .onEnded { value in
                    let targetIdx = BarTouchGestureThresholds.resolvedPageIndex(
                        currentIndex: safeIdx,
                        pageCount: slideCount,
                        translation: value.translation
                    )
                    if targetIdx != safeIdx {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            currentSlideIndex = targetIdx
                        }
                    }
                    DispatchQueue.main.async {
                        didCancelEmojiTapInActiveDrag = false
                    }
                }
            )
        }
    }

    private var emojiAndSnippetsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                segmentSwitcher
                macCursorFocusHintPill
                Spacer(minLength: 4)
                trailingHeaderControl
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    segmentSwitcher
                    Spacer(minLength: 6)
                    trailingHeaderControl
                }

                HStack(spacing: 8) {
                    macCursorFocusHintPill
                    Spacer(minLength: 0)
                    secondaryMetadataLabel
                }
            }
        }
    }

    private var segmentSwitcher: some View {
        HStack(spacing: 3) {
            ForEach(IOSEmojiBarSegment.allCases) { segment in
                let isSelected = (activeSegment == segment)
                Button {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                        activeSegment = segment
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: segment.sfSymbol)
                            .font(.system(size: 11.5, weight: .bold))
                        Text(segment.title(in: lang))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? palette.accentForeground : palette.secondaryText)
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(
                        isSelected ? palette.accent : Color.clear,
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ios-emoji-segment-\(segment.rawValue)")
            }
        }
        .padding(3)
        .background(palette.tileFillBottom, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
    }

    @ViewBuilder
    private var macCursorFocusHintPill: some View {
        if client.isEditingTextOnMac {
            HStack(spacing: 5) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.caption2.bold())
                Text(L10n.tr("正在 \(client.focusedMacAppName ?? "Mac") 输入", "Typing in \(client.focusedMacAppName ?? "Mac")", language: lang))
                    .font(.caption2.bold())
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(palette.statusConnected.opacity(0.20), in: Capsule())
            .foregroundStyle(palette.statusConnected)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "character.cursor.ibeam")
                    .font(.caption2.bold())
                Text(L10n.tr("请先在 Mac 点击输入框", "Focus a Mac text field", language: lang))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(palette.tileFillBottom, in: Capsule())
            .foregroundStyle(palette.secondaryText)
        }
    }

    @ViewBuilder
    private var secondaryMetadataLabel: some View {
        switch activeSegment {
        case .emoji:
            if !client.profile.emojiSlides.isEmpty {
                let safeIdx = min(max(0, currentSlideIndex), client.profile.emojiSlides.count - 1)
                HStack(spacing: 4) {
                    Text(client.profile.emojiSlides[safeIdx].iconEmoji)
                        .font(.caption2)
                    Text(client.profile.emojiSlides[safeIdx].title)
                        .font(.system(.caption2, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
        case .snippets:
            if !client.profile.snippets.isEmpty {
                Text("\(client.profile.snippets.count)/\(TextSnippet.maxLibraryCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
            }
        case .clipboard:
            let pinCount = client.profile.activePinnedClipboardItems.count
            HStack(spacing: 6) {
                if pinCount > 0 {
                    Text("\(pinCount)/\(PinnedClipboardItem.maxPinnedCount)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                if let text = client.clipboardPreview.previewText, client.connectionState.isConnected {
                    Text(client.clipboardPreview.isTruncated ? "280+" : "\(text.count)/280")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private var trailingHeaderControl: some View {
        switch activeSegment {
        case .emoji:
            Button {
                customizingSlotIndex = nil
                showAllCatalogSheet = true
            } label: {
                Label(L10n.tr("全部分类", "All Emojis", language: lang), systemImage: "magnifyingglass")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(palette.tileFillTop, in: Capsule())
                    .foregroundStyle(palette.primaryText)
                    .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

        case .snippets:
            let canAdd = client.profile.canAddMoreSnippets
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                snippetEditorSession = .create
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.caption.bold())
                    Text(
                        canAdd
                            ? L10n.tr("新建", "New", language: lang)
                            : "\(TextSnippet.maxLibraryCount)/\(TextSnippet.maxLibraryCount)"
                    )
                    .font(.caption.bold())
                    .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(canAdd ? palette.accent : palette.tileFillBottom, in: Capsule())
                .foregroundStyle(canAdd ? palette.accentForeground : palette.secondaryText)
                .overlay(
                    Capsule()
                        .strokeBorder(canAdd ? .clear : palette.subtleCardStroke, lineWidth: 1)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canAdd)
            .accessibilityIdentifier("ios-snippets-new-button")

        case .clipboard:
            EmptyView()
        }
    }

    // MARK: - Snippets Segment Content

    @ViewBuilder
    private var snippetsSurfaceContent: some View {
        if client.profile.snippets.isEmpty {
            VStack(spacing: 10) {
                Spacer(minLength: 6)

                Image(systemName: "text.quote")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(palette.accent)

                Text(L10n.tr("暂无常用文本片段", "No Saved Snippets Yet", language: lang))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                Text(
                    L10n.tr(
                        "保存常用回复、链接、邮箱签名或终端命令，在 Mac 聚焦文本框时一键输入。",
                        "Save frequent replies, links, signatures, or shell commands for one-tap typing at your Mac cursor.",
                        language: lang
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

                Button {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                    snippetEditorSession = .create
                } label: {
                    Label(L10n.tr("新建文本片段", "New Snippet", language: lang), systemImage: "plus")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.accentForeground)
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(palette.accent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

                Spacer(minLength: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
        } else {
            GeometryReader { geo in
                let columnsCount = geo.size.width >= 500 ? 2 : 1
                let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: columnsCount)

                ScrollView {
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(client.profile.snippets) { snippet in
                            snippetTileCard(snippet)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func snippetTileCard(_ snippet: TextSnippet) -> some View {
        let isPressed = (pressedSnippetID == snippet.id)
        let isTypingBlockedUnfocused = (snippet.insertMode == .typeKeys && !client.isEditingTextOnMac)

        return HStack(spacing: 6) {
            Button {
                triggerSnippet(snippet)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(snippet.displayTitle(in: lang))
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .foregroundStyle(isTypingBlockedUnfocused ? palette.secondaryText : palette.primaryText)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        HStack(spacing: 3) {
                            Image(systemName: snippet.insertMode.sfSymbol)
                                .font(.system(size: 9.5, weight: .bold))
                            Text(
                                isTypingBlockedUnfocused
                                    ? L10n.tr("需聚焦框", "Focus Field", language: lang)
                                    : snippet.insertMode.badgeTitle(in: lang)
                            )
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        }
                        .foregroundStyle(isTypingBlockedUnfocused ? palette.secondaryText : palette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            (isTypingBlockedUnfocused ? palette.tileFillBottom : palette.accent.opacity(0.14)),
                            in: Capsule()
                        )
                    }

                    Text(snippet.singleLinePreview)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedSnippetID, key: snippet.id))
            .accessibilityIdentifier("ios-snippet-card-\(snippet.id.uuidString)")

            Menu {
                snippetActionsMenuContent(for: snippet)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 38, height: 38)
                    .background(palette.tileFillBottom.opacity(0.75), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .accessibilityLabel(L10n.tr("管理片段", "Manage Snippet", language: lang))
        }
        .frame(minHeight: 60)
        .opacity(isTypingBlockedUnfocused ? 0.76 : 1.0)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [isPressed ? palette.tileFillBottom : palette.tileFillTop, palette.tileFillBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isPressed ? palette.accent : palette.tileBorderHighlight.opacity(0.65),
                            lineWidth: isPressed ? 1.8 : 1.1
                        )
                )
        )
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .contextMenu {
            snippetActionsMenuContent(for: snippet)
        }
    }

    @ViewBuilder
    private func snippetActionsMenuContent(for snippet: TextSnippet) -> some View {
        let canRunCurrentMode = SnippetInsertPolicy.isModeAvailable(
            snippet.insertMode,
            isFieldFocused: client.isEditingTextOnMac
        )

        Button {
            triggerSnippet(snippet)
        } label: {
            Label(
                snippet.insertMode.title(in: lang),
                systemImage: snippet.insertMode.sfSymbol
            )
        }
        .disabled(!canRunCurrentMode)

        Menu {
            ForEach(SnippetInsertMode.allCases) { candidate in
                let isModeAvailable = SnippetInsertPolicy.isModeAvailable(
                    candidate,
                    isFieldFocused: client.isEditingTextOnMac
                )
                Button {
                    updateSnippetInsertMode(snippet, mode: candidate)
                } label: {
                    if snippet.insertMode == candidate {
                        Label(candidate.title(in: lang), systemImage: "checkmark")
                    } else {
                        Label(candidate.title(in: lang), systemImage: candidate.sfSymbol)
                    }
                }
                .disabled(!isModeAvailable)
            }
        } label: {
            Label(
                L10n.tr("输入模式：\(snippet.insertMode.badgeTitle(in: lang))", "Insert Mode: \(snippet.insertMode.badgeTitle(in: lang))", language: lang),
                systemImage: "slider.horizontal.3"
            )
        }

        Button {
            snippetEditorSession = .rename(snippet)
        } label: {
            Label(L10n.tr("重命名…", "Rename…", language: lang), systemImage: "pencil.line")
        }

        Button {
            snippetEditorSession = .edit(snippet)
        } label: {
            Label(L10n.tr("编辑内容…", "Edit Snippet…", language: lang), systemImage: "square.and.pencil")
        }

        Divider()

        Button(role: .destructive) {
            deleteSnippet(snippet)
        } label: {
            Label(L10n.tr("删除", "Delete", language: lang), systemImage: "trash")
        }
    }

    private func updateSnippetInsertMode(_ snippet: TextSnippet, mode: SnippetInsertMode) {
        if mode == .typeKeys, !SnippetInsertPolicy.isModeAvailable(.typeKeys, isFieldFocused: client.isEditingTextOnMac) {
            return
        }
        var updated = client.profile
        guard updated.setSnippetInsertMode(id: snippet.id, mode: mode) else { return }
        client.pushUpdatedProfile(updated)
    }

    private func triggerSnippet(_ snippet: TextSnippet) {
        // Typing mode is only available when a field is focused. If no field is focused, do nothing.
        if snippet.insertMode == .typeKeys,
           !SnippetInsertPolicy.isModeAvailable(.typeKeys, isFieldFocused: client.isEditingTextOnMac) {
            return
        }
        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
        ChocPressFeedback.completeTap(key: snippet.id, pressedKey: $pressedSnippetID)
        if client.connectionState.isConnected {
            _ = client.triggerSnippet(snippet)
        } else {
            client.lastFeedback = CompanionFeedbackToast(
                success: false,
                title: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang),
                detail: L10n.tr("请先连接 Mac 后再输入文本片段", "Connect to your Mac to insert snippets", language: lang)
            )
        }
    }

    private func deleteSnippet(_ snippet: TextSnippet) {
        var updated = client.profile
        guard updated.deleteSnippet(id: snippet.id) else { return }
        client.pushUpdatedProfile(updated)
    }

    private func emojiSlideGrid(_ slide: EmojiSlide, slideOffset: Int) -> some View {
        let colCount = isLandscape ? 4 : 2
        let rowCount = isLandscape ? 2 : 4

        return GeometryReader { geo in
            let spacing: CGFloat = 12
            let hPad: CGFloat = 14
            let vPad: CGFloat = 8
            let tileW = max(50, (geo.size.width - hPad * 2 - spacing * CGFloat(colCount - 1)) / CGFloat(colCount))
            let tileH = max(50, (geo.size.height - vPad * 2 - spacing * CGFloat(rowCount - 1)) / CGFloat(rowCount))

            VStack(spacing: spacing) {
                ForEach(0..<rowCount, id: \.self) { r in
                    HStack(spacing: spacing) {
                        ForEach(0..<colCount, id: \.self) { c in
                            let idx = r * colCount + c
                            let emoji = slide.emojis[idx]
                            let key = "\(slideOffset)-\(idx)"
                            let isPressed = (pressedEmojiKey == key)

                            Button {
                                guard !didCancelEmojiTapInActiveDrag,
                                      !BarTouchGestureThresholds.shouldCancelPress(translation: activeEmojiDragTranslation) else {
                                    return
                                }
                                ChocPressFeedback.completeTap(key: key, pressedKey: $pressedEmojiKey)
                                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                if client.connectionState.isConnected {
                                    client.insertEmoji(emoji)
                                } else {
                                    client.lastFeedback = CompanionFeedbackToast(
                                        success: false,
                                        title: emoji,
                                        detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                                    )
                                }
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [isPressed ? palette.tileFillBottom : palette.tileFillTop, palette.tileFillBottom],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                                .strokeBorder(
                                                    isPressed ? palette.accent : palette.tileBorderHighlight.opacity(0.5),
                                                    lineWidth: isPressed ? 2.0 : 1.1
                                                )
                                        )

                                    Text(emoji)
                                        .font(.system(size: min(tileW, tileH) * 0.48))
                                }
                                .frame(width: tileW, height: tileH)
                                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .scaleEffect(isPressed ? 0.94 : 1.0)
                            }
                            .buttonStyle(
                                ChocPressedKeyButtonStyle(
                                    pressedKey: $pressedEmojiKey,
                                    key: key,
                                    isSuppressed: didCancelEmojiTapInActiveDrag,
                                    onTouchDown: {
                                        if activeEmojiDragTranslation == .zero {
                                            didCancelEmojiTapInActiveDrag = false
                                        }
                                    }
                                )
                            )
                            .contextMenu {
                                Button {
                                    customizingSlotIndex = idx
                                    showAllCatalogSheet = true
                                } label: {
                                    Label(L10n.tr("更换此格表情…", "Replace Emoji…", language: lang), systemImage: "face.smiling")
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
        }
    }

    private var emojiBrowserSheet: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(EmojiCatalog.categories) { cat in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(cat.icon) \(cat.title(in: lang))")
                                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                                    .foregroundStyle(palette.primaryText)

                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                                    ForEach(cat.emojis, id: \.self) { em in
                                        Button {
                                            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                            if let slotIdx = customizingSlotIndex {
                                                var updated = client.profile
                                                updated.emojiSlides[currentSlideIndex].emojis[slotIdx] = em
                                                client.pushUpdatedProfile(updated)
                                                showAllCatalogSheet = false
                                            } else {
                                                client.insertEmoji(em)
                                            }
                                        } label: {
                                            Text(em)
                                                .font(.system(size: 28))
                                                .frame(height: 44)
                                                .frame(maxWidth: .infinity)
                                                .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(
                customizingSlotIndex != nil
                    ? L10n.tr("选择替换表情", "Pick Replacement Emoji", language: lang)
                    : L10n.tr("点击直接输入到 Mac", "Tap to Type on Mac", language: lang)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("关闭", "Close", language: lang)) {
                        showAllCatalogSheet = false
                    }
                    .foregroundStyle(palette.accent)
                }
            }
        }
        .preferredColorScheme(.light)
    }
}

// MARK: - Snippet Create / Rename / Edit Sheet

private struct IOSSnippetEditorSheet: View {
    private enum FocusedField: Hashable {
        case title
        case body
    }

    @ObservedObject var client: CompanionClientEngine
    let session: IOSSnippetEditorSession
    @Environment(\.dismiss) private var dismiss

    @State private var titleText: String = ""
    @State private var bodyText: String = ""
    @State private var selectedInsertMode: SnippetInsertMode = .focusedFieldInsert
    @FocusState private var focusedField: FocusedField?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var existingSnippet: TextSnippet? {
        switch session {
        case .create:
            return nil
        case .rename(let snippet), .edit(let snippet):
            return snippet
        }
    }

    private var isRenameOnly: Bool {
        if case .rename = session { return true }
        return false
    }

    private var canSave: Bool {
        if existingSnippet == nil && !client.profile.canAddMoreSnippets {
            return false
        }
        return !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sheetTitle: String {
        switch session {
        case .create:
            return L10n.tr("新建文本片段", "New Snippet", language: lang)
        case .rename:
            return L10n.tr("重命名文本片段", "Rename Snippet", language: lang)
        case .edit:
            return L10n.tr("编辑文本片段", "Edit Snippet", language: lang)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        L10n.tr("标题（可选，最多 40 字）", "Title (optional, max 40 chars)", language: lang),
                        text: Binding(
                            get: { titleText },
                            set: { titleText = TextSnippet.clampTitle($0) }
                        )
                    )
                    .focused($focusedField, equals: .title)
                    .submitLabel(isRenameOnly ? .done : .next)
                    .onSubmit {
                        if isRenameOnly {
                            saveAndDismiss()
                        } else {
                            focusedField = .body
                        }
                    }
                } header: {
                    HStack {
                        Text(L10n.tr("名称", "Title", language: lang))
                        Spacer()
                        Text("\(titleText.count)/\(TextSnippet.maxTitleLength)")
                            .font(.caption2.monospacedDigit())
                    }
                }
                .listRowBackground(palette.barSurface)

                if !isRenameOnly {
                    Section {
                        ZStack(alignment: .topLeading) {
                            if bodyText.isEmpty {
                                Text(
                                    L10n.tr(
                                        "输入回复、网址链接、签名或终端命令…",
                                        "Enter a reply, link, signature, or shell command…",
                                        language: lang
                                    )
                                )
                                .font(.body)
                                .foregroundStyle(palette.secondaryText.opacity(0.65))
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                            }

                            TextEditor(
                                text: Binding(
                                    get: { bodyText },
                                    set: { bodyText = TextSnippet.clampBody($0) }
                                )
                            )
                            .focused($focusedField, equals: .body)
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(palette.primaryText)
                            .frame(minHeight: 150)
                        }
                    } header: {
                        HStack {
                            Text(L10n.tr("片段内容", "Snippet Body", language: lang))
                            Spacer()
                            Text("\(bodyText.count)/\(TextSnippet.maxBodyLength)")
                                .font(.caption2.monospacedDigit())
                        }
                    } footer: {
                        Text(selectedInsertMode.subtitle(in: lang))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .listRowBackground(palette.barSurface)

                    Section {
                        ForEach(SnippetInsertMode.allCases) { candidate in
                            let isModeAvailable = SnippetInsertPolicy.isModeAvailable(
                                candidate,
                                isFieldFocused: client.isEditingTextOnMac
                            )
                            let isSelected = (selectedInsertMode == candidate)

                            Button {
                                guard isModeAvailable else { return }
                                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                selectedInsertMode = candidate
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: candidate.sfSymbol)
                                        .font(.system(size: 13.5, weight: .bold))
                                        .foregroundStyle(isSelected ? palette.accent : palette.secondaryText)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.title(in: lang))
                                            .font(.system(.subheadline, design: .rounded, weight: isSelected ? .bold : .medium))
                                            .foregroundStyle(isModeAvailable || isSelected ? palette.primaryText : palette.secondaryText)

                                        if candidate == .typeKeys && !isModeAvailable {
                                            Text(
                                                L10n.tr(
                                                    "需先在 Mac 中点击任意文本输入框后才可选择模拟按键模式",
                                                    "Focus a text field on your Mac to select Typing mode",
                                                    language: lang
                                                )
                                            )
                                            .font(.caption2)
                                            .foregroundStyle(palette.secondaryText)
                                        }
                                    }

                                    Spacer()

                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(palette.accent)
                                    }
                                }
                            }
                            .disabled(!isModeAvailable)
                            .accessibilityIdentifier("ios-snippet-mode-\(candidate.rawValue)")
                        }
                    } header: {
                        Text(L10n.tr("输入模式", "Insert Mode", language: lang))
                    }
                    .listRowBackground(palette.barSurface)
                }

                if let existing = existingSnippet {
                    Section {
                        Button(role: .destructive) {
                            var updated = client.profile
                            _ = updated.deleteSnippet(id: existing.id)
                            client.pushUpdatedProfile(updated)
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Label(L10n.tr("删除此片段", "Delete Snippet", language: lang), systemImage: "trash")
                                    .font(.body.weight(.semibold))
                                Spacer()
                            }
                        }
                        .foregroundStyle(palette.statusFailure)
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
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "Cancel", language: lang)) {
                        dismiss()
                    }
                    .foregroundStyle(palette.secondaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("保存", "Save", language: lang)) {
                        saveAndDismiss()
                    }
                    .font(.body.weight(.bold))
                    .foregroundStyle(canSave ? palette.accent : palette.secondaryText)
                    .disabled(!canSave)
                    .accessibilityIdentifier("ios-snippet-save-button")
                }
            }
            .onAppear {
                if let existing = existingSnippet {
                    titleText = existing.title
                    bodyText = existing.body
                    selectedInsertMode = existing.insertMode
                } else {
                    selectedInsertMode = .focusedFieldInsert
                }
                switch session {
                case .create:
                    focusedField = .body
                case .rename, .edit:
                    focusedField = .title
                }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
    }

    private func saveAndDismiss() {
        guard canSave else { return }
        var updated = client.profile
        switch session {
        case .create:
            let created = TextSnippet(
                title: TextSnippet.resolvedTitle(title: titleText, body: bodyText, language: lang),
                body: bodyText,
                insertMode: selectedInsertMode,
                updatedAt: Date()
            )
            guard updated.upsertSnippet(created) else { return }
        case .rename(let existing):
            guard updated.renameSnippet(id: existing.id, title: titleText) else { return }
        case .edit(let existing):
            let edited = TextSnippet(
                id: existing.id,
                title: TextSnippet.resolvedTitle(title: titleText, body: bodyText, language: lang),
                body: bodyText,
                insertMode: selectedInsertMode,
                updatedAt: Date()
            )
            guard updated.upsertSnippet(edited) else { return }
        }
        client.pushUpdatedProfile(updated)
        dismiss()
    }
}

// MARK: - 4. Finger Gestures & Quick Trackpad Surface

public struct IOSGesturePadSurfaceView: View {
    @ObservedObject var client: CompanionClientEngine
    let isLandscape: Bool
    let onTriggerGesture: (TouchGestureType) -> Void

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        isLandscape: Bool,
        onTriggerGesture: @escaping (TouchGestureType) -> Void
    ) {
        self.client = client
        self.isLandscape = isLandscape
        self.onTriggerGesture = onTriggerGesture
    }

    public var body: some View {
        let layout = isLandscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))

        layout {
            // Multi-touch interactive canvas
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [palette.tileFillTop.opacity(0.72), palette.backgroundBottom.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(palette.tileBorderHighlight.opacity(0.55), lineWidth: 1.3)
                    )

                VStack(spacing: 7) {
                    Image(systemName: client.profile.gestureConfig.isGlobalOverlayEnabled ? "hand.draw.fill" : "hand.raised.slash.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(client.profile.gestureConfig.isGlobalOverlayEnabled ? palette.accent : palette.secondaryText)

                    Text(
                        client.profile.gestureConfig.isGlobalOverlayEnabled
                            ? L10n.tr("多指触控手势板", "Multi-Touch Gesture Pad", language: lang)
                            : L10n.tr("多指手势已在 Mac 端暂停", "Multi-Touch Paused on Mac", language: lang)
                    )
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                    VStack(spacing: 2) {
                        Text(L10n.tr("双指上/下滑：最大化与最小化  ·  双指左/右滑：贴靠半屏", "2-Finger Up/Down: Max & Min  ·  2-Finger L/R: Snap Half", language: lang))
                        Text(L10n.tr("三指捏合/张开：复制与粘贴  ·  单指可直接点按快捷按钮", "Pinch In/Out: Copy & Paste  ·  1-Finger taps quick buttons", language: lang))
                    }
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                }
                .padding(12)
                .allowsHitTesting(false)

                MultiTouchGestureCaptureView(
                    isEnabled: client.profile.gestureConfig.isGlobalOverlayEnabled,
                    onGestureTriggered: onTriggerGesture
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Tactile Quick Trigger Grid (>= 46pt height for crisp 1-finger taps)
            let quickGestures: [TouchGestureType] = [
                .twoFingerSwipeUp, .twoFingerSwipeDown,
                .twoFingerSwipeLeft, .twoFingerSwipeRight,
                .threeFingerPinchIn, .threeFingerPinchOut,
                .twoFingerDoubleTap, .threeFingerSwipeUp
            ]

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(quickGestures) { gesture in
                    let mapped = client.profile.gestureConfig.action(for: gesture)
                    Button {
                        onTriggerGesture(gesture)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mapped?.sfSymbol ?? gesture.sfSymbol)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 18)
                            Text(mapped?.compactTitle(in: lang) ?? gesture.title(in: lang))
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 46)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios-quick-gesture-\(gesture.rawValue)")
                }
            }
            .frame(maxWidth: isLandscape ? 268 : .infinity)
        }
        .padding(14)
    }
}

// MARK: - 5. iPad Chocolate Bar Deck with Pinned Control Strip

public struct IOSIPadChocolateBarDeckView: View {
    @ObservedObject var client: CompanionClientEngine
    @Binding var currentPageIndex: Int
    var isFollowingFrontmostApp: Bool
    var isDeckSwitchHighlighted: Bool
    var onFollowFrontmostApp: (() -> Void)?
    var onSelectManualPage: ((Int) -> Void)?
    var onMovePage: ((PageReorderDirection) -> Void)?
    let availableWidth: CGFloat
    var isLandscape: Bool
    var onPromptHUD: ((String) -> Void)?
    let onEditSlot: (IOSEditSlotSelection) -> Void

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        currentPageIndex: Binding<Int>,
        isFollowingFrontmostApp: Bool = true,
        isDeckSwitchHighlighted: Bool = false,
        onFollowFrontmostApp: (() -> Void)? = nil,
        onSelectManualPage: ((Int) -> Void)? = nil,
        onMovePage: ((PageReorderDirection) -> Void)? = nil,
        availableWidth: CGFloat,
        isLandscape: Bool = true,
        onPromptHUD: ((String) -> Void)? = nil,
        onEditSlot: @escaping (IOSEditSlotSelection) -> Void
    ) {
        self.client = client
        self._currentPageIndex = currentPageIndex
        self.isFollowingFrontmostApp = isFollowingFrontmostApp
        self.isDeckSwitchHighlighted = isDeckSwitchHighlighted
        self.onFollowFrontmostApp = onFollowFrontmostApp
        self.onSelectManualPage = onSelectManualPage
        self.onMovePage = onMovePage
        self.availableWidth = availableWidth
        self.isLandscape = isLandscape
        self.onPromptHUD = onPromptHUD
        self.onEditSlot = onEditSlot
    }

    public var body: some View {
        let pageCount = max(1, client.profile.pages.count)
        let activeIdx = min(max(0, currentPageIndex), pageCount - 1)

        return VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                        let nextIdx = (activeIdx - 1 + pageCount) % pageCount
                        if let onSelectManualPage {
                            onSelectManualPage(nextIdx)
                        } else {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                                currentPageIndex = nextIdx
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                            .frame(width: 34, height: 30)
                            .background(palette.tileFillBottom.opacity(0.88), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios-page-prev-button")

                    ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(0..<pageCount, id: \.self) { pageIdx in
                                    let isSelected = (pageIdx == activeIdx)
                                    let icon = client.profile.pages.indices.contains(pageIdx)
                                        ? client.profile.pages[pageIdx].iconEmoji
                                        : "🍫"
                                    let rawTitle = client.profile.pages.indices.contains(pageIdx)
                                        ? client.profile.pages[pageIdx].title
                                        : ""
                                    let displayTitle = PageSwitcherTitleFormatter.displayTitle(
                                        rawTitle: rawTitle,
                                        pageIndex: pageIdx,
                                        language: lang
                                    )

                                    Button {
                                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                        if let onSelectManualPage {
                                            onSelectManualPage(pageIdx)
                                        } else {
                                            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                                                currentPageIndex = pageIdx
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(icon)
                                                .font(.system(size: 11.5))
                                            MaxWidthPillTitleLayout(maxWidth: 108) {
                                                Text(displayTitle)
                                                    .font(.system(size: 11.5, weight: isSelected ? .bold : .semibold, design: .rounded))
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .frame(height: 30)
                                        .background(
                                            isSelected ? palette.accent : palette.barSurface.opacity(0.9),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(isSelected ? palette.accentForeground : palette.primaryText)
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(isSelected ? .clear : palette.subtleCardStroke, lineWidth: 1)
                                        )
                                        .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .id("ipad-deck-page-\(pageIdx)")
                                    .accessibilityIdentifier("ios-ipad-deck-page-name-\(pageIdx)")
                                    .accessibilityLabel(displayTitle)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                        .onChange(of: activeIdx) { _, nextIdx in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scrollProxy.scrollTo("ipad-deck-page-\(nextIdx)", anchor: .center)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)

                    Button {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                        let nextIdx = (activeIdx + 1) % pageCount
                        if let onSelectManualPage {
                            onSelectManualPage(nextIdx)
                        } else {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                                currentPageIndex = nextIdx
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                            .frame(width: 34, height: 30)
                            .background(palette.tileFillBottom.opacity(0.88), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios-page-next-button")
                }

                HStack(spacing: 8) {
                    if let onMovePage {
                        IOSPageReorderControls(
                            client: client,
                            activePageIndex: activeIdx,
                            compact: false,
                            onMove: onMovePage
                        )
                    }

                    HStack(spacing: 2) {
                        ForEach(0..<pageCount, id: \.self) { dotIdx in
                            let isSelected = (dotIdx == activeIdx)
                            Button {
                                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                if let onSelectManualPage {
                                    onSelectManualPage(dotIdx)
                                } else {
                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                                        currentPageIndex = dotIdx
                                    }
                                }
                            } label: {
                                ZStack {
                                    if isSelected {
                                        Capsule()
                                            .fill(palette.accent)
                                            .frame(width: 18, height: 7)
                                    } else {
                                        Circle()
                                            .fill(palette.secondaryText.opacity(0.35))
                                            .frame(width: 7, height: 7)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ios-page-dot-\(dotIdx)")
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(palette.barSurface.opacity(0.88), in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            IOSChocolateBarSurfaceView(
                client: client,
                currentPageIndex: $currentPageIndex,
                isFollowingFrontmostApp: isFollowingFrontmostApp,
                isDeckSwitchHighlighted: isDeckSwitchHighlighted,
                onFollowFrontmostApp: onFollowFrontmostApp,
                isLandscape: isLandscape,
                onPromptHUD: onPromptHUD,
                onEditSlot: onEditSlot
            )

            IOSCompactKeyAndRecentsBar(
                client: client,
                showInlineRecentChips: true,
                onPromptHUD: onPromptHUD
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Rectangle()
                .fill(palette.subtleCardStroke)
                .frame(height: 1)
                .padding(.horizontal, 14)

            IOSPersistentControlStripView(
                client: client,
                preferSingleRow: availableWidth >= 620,
                embeddedInSurface: true,
                onPromptHUD: onPromptHUD,
                onEditSlot: onEditSlot
            )
        }
        .background(palette.barSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }
}

// MARK: - 6. Persistent Control Strip (Volume, Brightness, Now Playing, Mic Mute, Clock)

public struct IOSPersistentControlStripView: View {
    @ObservedObject var client: CompanionClientEngine
    let preferSingleRow: Bool
    let embeddedInSurface: Bool
    var onPromptHUD: ((String) -> Void)?
    var onEditSlot: ((IOSEditSlotSelection) -> Void)?

    @State private var pressedKey: String?
    @State private var suppressedRepeatStripKey: String?
    @State private var volumeDragLevel: Double?
    @State private var brightnessDragLevel: Double?
    @State private var volumeThrottle = ControlLevelDragThrottle()
    @State private var brightnessThrottle = ControlLevelDragThrottle()

    private static let localClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var state: ControlStripState { client.controlStripState }

    private var effectiveVolume: Double {
        ControlStripLevel.clamp(volumeDragLevel ?? state.volume)
    }

    private var effectiveBrightness: Double {
        ControlStripLevel.clamp(brightnessDragLevel ?? state.brightness)
    }

    public init(
        client: CompanionClientEngine,
        preferSingleRow: Bool,
        embeddedInSurface: Bool = false,
        onPromptHUD: ((String) -> Void)? = nil,
        onEditSlot: ((IOSEditSlotSelection) -> Void)? = nil
    ) {
        self.client = client
        self.preferSingleRow = preferSingleRow
        self.embeddedInSurface = embeddedInSurface
        self.onPromptHUD = onPromptHUD
        self.onEditSlot = onEditSlot
    }

    public var body: some View {
        VStack(spacing: 8) {
            IOSPinnedStripTilesRow(
                client: client,
                onPromptHUD: onPromptHUD,
                onEditSlot: onEditSlot
            )

            if preferSingleRow {
                singleRowContent
            } else {
                twoRowContent
            }

            IOSCompanionStripStatusRow(client: client)
        }
        .padding(.horizontal, embeddedInSurface ? 14 : 12)
        .padding(.vertical, preferSingleRow ? 7 : 9)
        .background {
            if !embeddedInSurface {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(palette.barSurface.opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios-persistent-control-strip")
    }

    // MARK: - Responsive Strip Layouts

    private var singleRowContent: some View {
        HStack(spacing: 10) {
            volumeControlCluster
                .frame(minWidth: 150, idealWidth: 188, maxWidth: 230)

            stripDivider

            brightnessControlCluster
                .frame(minWidth: 120, idealWidth: 154, maxWidth: 196)

            stripDivider

            nowPlayingCluster
                .frame(maxWidth: .infinity)

            stripDivider

            IOSAudioOutputPickerButton(client: client, compact: false)

            IOSDisplayTargetPickerMenu(client: client, compact: true)

            undoWindowMoveButton

            micMuteButton(compactLabel: true)

            clockTextView
        }
    }

    private var twoRowContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                volumeControlCluster
                    .frame(maxWidth: .infinity)

                stripDivider

                brightnessControlCluster
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 8) {
                nowPlayingCluster
                    .frame(maxWidth: .infinity)

                IOSAudioOutputPickerButton(client: client, compact: true)

                IOSDisplayTargetPickerMenu(client: client, compact: true)

                undoWindowMoveButton

                micMuteButton(compactLabel: false)

                clockTextView
            }
        }
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(palette.subtleCardStroke)
            .frame(width: 1, height: 22)
    }

    // MARK: - Volume (Drag to Set, Tap Speaker to Mute, Current Level)

    private var volumeControlCluster: some View {
        let isMuted = state.isVolumeMuted && volumeDragLevel == nil
        let pct = ControlStripLevel.percentage(for: effectiveVolume)
        let isMutePressed = (pressedKey == "volumeMute")

        return HStack(spacing: 6) {
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                ChocPressFeedback.completeTap(key: "volumeMute", pressedKey: $pressedKey)
                triggerStripQuickAction(.volumeMute)
            } label: {
                Image(systemName: speakerSymbol(level: effectiveVolume, isMuted: isMuted))
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(isMuted ? palette.statusFailure : palette.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        isMutePressed
                            ? palette.accent.opacity(0.18)
                            : (isMuted ? palette.statusFailure.opacity(0.14) : palette.tileFillBottom),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isMutePressed
                                    ? palette.accent
                                    : (isMuted ? palette.statusFailure.opacity(0.45) : palette.subtleCardStroke),
                                lineWidth: isMutePressed ? 1.8 : 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .scaleEffect(isMutePressed ? 0.92 : 1.0)
            }
            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: "volumeMute"))
            .accessibilityIdentifier("ios-strip-volume-mute")
            .accessibilityLabel(
                isMuted
                    ? L10n.tr("取消静音", "Unmute Volume", language: lang)
                    : L10n.tr("静音", "Mute Volume", language: lang)
            )

            ControlStripDragSlider(
                level: effectiveVolume,
                fillColor: isMuted ? palette.secondaryText.opacity(0.45) : palette.accent,
                palette: palette,
                accessibilityLabel: L10n.tr("音量", "Volume", language: lang),
                accessibilityIdentifier: "ios-strip-volume-slider",
                onDragChanged: { newLevel in
                    volumeDragLevel = newLevel
                    let now = ProcessInfo.processInfo.systemUptime
                    if let throttled = volumeThrottle.updateDrag(to: newLevel, at: now) {
                        client.setControlLevel(kind: .volume, level: throttled)
                    }
                },
                onDragEnded: { finalLevel in
                    let now = ProcessInfo.processInfo.systemUptime
                    let committed = volumeThrottle.endDrag(at: finalLevel, at: now)
                    client.setControlLevel(kind: .volume, level: committed)
                    volumeDragLevel = nil
                },
                onAccessibilityStep: { stepped in
                    client.setControlLevel(kind: .volume, level: stepped)
                }
            )

            Text("\(pct)%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isMuted ? palette.secondaryText : palette.primaryText)
                .frame(minWidth: 32, alignment: .trailing)
                .accessibilityIdentifier("ios-strip-volume-level")
        }
    }

    private func speakerSymbol(level: Double, isMuted: Bool) -> String {
        if isMuted || level <= 0.001 {
            return "speaker.slash.fill"
        } else if level < 0.34 {
            return "speaker.wave.1.fill"
        } else if level < 0.67 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    // MARK: - Brightness (Drag to Set Main Display Brightness)

    private var brightnessControlCluster: some View {
        let available = state.isBrightnessAvailable || !client.connectionState.isConnected
        let pct = ControlStripLevel.percentage(for: effectiveBrightness)

        return HStack(spacing: 6) {
            Image(systemName: effectiveBrightness < 0.45 ? "sun.min.fill" : "sun.max.fill")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(available ? palette.accentEmphasis : palette.secondaryText)
                .frame(width: 22, height: 34)

            ControlStripDragSlider(
                level: effectiveBrightness,
                fillColor: available ? palette.accentEmphasis : palette.secondaryText.opacity(0.4),
                palette: palette,
                accessibilityLabel: L10n.tr("主显示器亮度", "Main Display Brightness", language: lang),
                accessibilityIdentifier: "ios-strip-brightness-slider",
                onDragChanged: { newLevel in
                    brightnessDragLevel = newLevel
                    let now = ProcessInfo.processInfo.systemUptime
                    if let throttled = brightnessThrottle.updateDrag(to: newLevel, at: now) {
                        client.setControlLevel(kind: .brightness, level: throttled)
                    }
                },
                onDragEnded: { finalLevel in
                    let now = ProcessInfo.processInfo.systemUptime
                    let committed = brightnessThrottle.endDrag(at: finalLevel, at: now)
                    client.setControlLevel(kind: .brightness, level: committed)
                    brightnessDragLevel = nil
                },
                onAccessibilityStep: { stepped in
                    client.setControlLevel(kind: .brightness, level: stepped)
                }
            )

            if preferSingleRow {
                Text("\(pct)%")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(palette.secondaryText)
                    .frame(minWidth: 30, alignment: .trailing)
            }
        }
        .opacity(available ? 1.0 : 0.6)
    }

    // MARK: - Now Playing (Title or App Name, Play/Pause, Next, Quiet Empty State)

    private var nowPlayingCluster: some View {
        let activeMedia = state.nowPlaying
        let rowContent = NowPlayingProgressFormatter.rowDisplayContent(for: activeMedia)
        let primaryText = rowContent?.title
        let progressText = rowContent?.progressText
        let isPlaying = activeMedia?.isPlaying ?? false

        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: primaryText != nil ? "music.note" : "waveform")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(primaryText != nil ? palette.accent : palette.secondaryText.opacity(0.65))

                if let primaryText {
                    Text(primaryText)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(L10n.tr("未在播放", "Not Playing", language: lang))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.secondaryText.opacity(0.8))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if primaryText != nil, let progressText {
                    Text(progressText)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("ios-strip-now-playing-progress")
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(palette.tileFillBottom.opacity(0.75), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios-strip-now-playing-label")

            let isPlayPressed = (pressedKey == "playPause")
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                ChocPressFeedback.completeTap(key: "playPause", pressedKey: $pressedKey)
                triggerStripQuickAction(.mediaPlayPause)
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 34, height: 34)
                    .background(
                        isPlayPressed ? palette.tileFillBottom : palette.tileFillTop,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isPlayPressed ? palette.accent : palette.subtleCardStroke,
                                lineWidth: isPlayPressed ? 1.8 : 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .scaleEffect(isPlayPressed ? 0.92 : 1.0)
            }
            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: "playPause"))
            .accessibilityIdentifier("ios-strip-play-pause")
            .accessibilityLabel(L10n.tr("播放或暂停", "Play or Pause", language: lang))

            let isNextPressed = (pressedKey == "nextTrack")
            Button {
                if suppressedRepeatStripKey == "nextTrack" {
                    suppressedRepeatStripKey = nil
                    return
                }
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                ChocPressFeedback.completeTap(key: "nextTrack", pressedKey: $pressedKey)
                triggerStripQuickAction(.mediaNext)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 34, height: 34)
                    .background(
                        isNextPressed ? palette.tileFillBottom : palette.tileFillTop,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isNextPressed ? palette.accent : palette.subtleCardStroke,
                                lineWidth: isNextPressed ? 1.8 : 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .scaleEffect(isNextPressed ? 0.92 : 1.0)
            }
            .buttonStyle(
                IOSRepeatableQuickActionButtonStyle(
                    pressedKey: $pressedKey,
                    key: "nextTrack",
                    action: .mediaNext,
                    suppressReleaseKey: $suppressedRepeatStripKey
                ) {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                    triggerStripQuickAction(.mediaNext)
                }
            )
            .accessibilityIdentifier("ios-strip-next-track")
            .accessibilityLabel(L10n.tr("下一曲", "Next Track", language: lang))
        }
    }

    // MARK: - One-Level Window Move Undo (Quiet When Nothing to Undo)

    private var undoWindowMoveButton: some View {
        let canUndo = state.canUndoWindowMove

        return Button {
            guard state.canUndoWindowMove else { return }
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            client.undoLastWindowMove()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(canUndo ? palette.accent : palette.secondaryText.opacity(0.42))
                .frame(width: 34, height: 34)
                .background(
                    (canUndo ? palette.accent.opacity(0.14) : palette.tileFillBottom.opacity(0.55)),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            canUndo ? palette.accent.opacity(0.6) : palette.subtleCardStroke,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-strip-undo-window-move")
        .accessibilityLabel(L10n.tr("撤销上次窗口移动", "Undo Last Window Move", language: lang))
        .accessibilityValue(
            canUndo
                ? L10n.tr("可撤销", "Available", language: lang)
                : L10n.tr("无窗口移动可撤销", "Nothing to Undo", language: lang)
        )
    }

    // MARK: - Mic Mute (One Tap, Visible On/Off State)

    private func micMuteButton(compactLabel: Bool) -> some View {
        let isMuted = state.isMicMuted
        let isMicPressed = (pressedKey == "micMute")

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            ChocPressFeedback.completeTap(key: "micMute", pressedKey: $pressedKey)
            if client.connectionState.isConnected {
                client.toggleMicMute()
            } else {
                client.lastFeedback = CompanionFeedbackToast(
                    success: false,
                    title: L10n.tr("麦克风静音", "Microphone Mute", language: lang),
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 12.5, weight: .bold))

                if !isMuted {
                    Circle()
                        .fill(palette.statusConnected)
                        .frame(width: 5.5, height: 5.5)
                }

                Text(
                    isMuted
                        ? L10n.tr("闭麦", "Muted", language: lang)
                        : (compactLabel ? L10n.tr("麦克", "Mic", language: lang) : L10n.tr("麦克风", "Mic On", language: lang))
                )
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isMuted ? palette.emphasisForeground : palette.primaryText)
            .padding(.horizontal, 9)
            .frame(height: 34)
            .background(
                isMuted
                    ? palette.statusFailure.opacity(isMicPressed ? 0.84 : 1.0)
                    : (isMicPressed ? palette.accent.opacity(0.16) : palette.tileFillBottom),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isMicPressed
                            ? palette.accent
                            : (isMuted ? palette.statusFailure : palette.statusConnected.opacity(0.5)),
                        lineWidth: isMicPressed ? 1.8 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(isMicPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: "micMute"))
        .accessibilityIdentifier("ios-strip-mic-mute")
        .accessibilityLabel(L10n.tr("麦克风静音开关", "Microphone Mute", language: lang))
        .accessibilityValue(isMuted ? L10n.tr("已静音", "Muted", language: lang) : L10n.tr("开启中", "On", language: lang))
    }

    private func triggerStripQuickAction(_ action: SystemQuickAction) {
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

    // MARK: - Clock (Local Time, Text Only)

    private var clockTextView: some View {
        TimelineView(.periodic(from: .now, by: 10.0)) { context in
            Text(Self.localClockFormatter.string(from: context.date))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("ios-strip-clock")
        }
    }
}

// MARK: - Tactile Throttled Drag Slider

private struct ControlStripDragSlider: View {
    let level: Double
    let fillColor: Color
    let palette: ChocPalette
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let onDragChanged: (Double) -> Void
    let onDragEnded: (Double) -> Void
    let onAccessibilityStep: (Double) -> Void

    @GestureState private var isDragging: Bool = false
    @State private var activeDraggedLevel: Double?

    private let trackHeight: CGFloat = 10
    private let thumbSize: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let clamped = ControlStripLevel.clamp(level)
            let usableSpan = max(0, width - thumbSize)
            let thumbX = usableSpan * CGFloat(clamped)
            let fillWidth = min(width, max(trackHeight, thumbX + thumbSize * 0.5))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.tileFillBottom)
                    .frame(height: trackHeight)
                    .overlay(
                        Capsule()
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )

                if clamped > 0.005 {
                    Capsule()
                        .fill(fillColor)
                        .frame(width: fillWidth, height: trackHeight)
                }

                Circle()
                    .fill(palette.barSurface)
                    .frame(width: thumbSize, height: thumbSize)
                    .overlay(
                        Circle()
                            .strokeBorder(fillColor, lineWidth: 2)
                    )
                    .shadow(color: palette.primaryText.opacity(0.12), radius: 2, x: 0, y: 1)
                    .scaleEffect(isDragging ? 1.14 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
                    .offset(x: thumbX)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        let normalized = ControlStripLevel.clamp(Double(value.location.x / width))
                        activeDraggedLevel = normalized
                        onDragChanged(normalized)
                    }
                    .onEnded { value in
                        let normalized = ControlStripLevel.clamp(Double(value.location.x / width))
                        activeDraggedLevel = nil
                        onDragEnded(normalized)
                    }
            )
            .onChange(of: isDragging) { _, dragging in
                if !dragging, let pending = activeDraggedLevel {
                    activeDraggedLevel = nil
                    onDragEnded(pending)
                }
            }
        }
        .frame(height: 34)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(ControlStripLevel.percentage(for: level))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onAccessibilityStep(ControlStripLevel.clamp(level + 0.05))
            case .decrement:
                onAccessibilityStep(ControlStripLevel.clamp(level - 0.05))
            @unknown default:
                break
            }
        }
    }
}
