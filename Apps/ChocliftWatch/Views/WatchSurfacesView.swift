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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.bannerTitle(in: lang))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    if state.isFailure, let detail = state.bannerSubtitle(in: lang) {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
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

// MARK: - 1. Watch Chocolate Bar Surface (8 Synced Pages x 8 Slots)

public struct WatchChocolateBarView: View {
    @ObservedObject var client: CompanionClientEngine
    @Binding var deckFollower: AppDeckFollowerState
    let onRequestPairing: () -> Void

    @State private var showPagePickerSheet: Bool = false
    @State private var assigningSlot: WatchSlotCoordinate?
    @State private var pressedSlotKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

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

    private var activeBoundFrontmostAppName: String? {
        guard deckFollower.isFollowingFrontmostApp,
              let frontBundleID = client.frontmostBundleID,
              !client.profile.pages.isEmpty,
              client.profile.boundPageID(forBundleIdentifier: frontBundleID) == activePage.id else {
            return nil
        }
        return client.profile.resolvedAppDisplayName(
            forBundleIdentifier: frontBundleID,
            recentApps: client.recentApps,
            catalogApps: client.macCatalogApps
        )
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if !client.connectionState.isConnected {
                    WatchConnectionStateBanner(client: client, onTap: onRequestPairing)
                }

                pageSwitcherBar

                if !deckFollower.isFollowingFrontmostApp {
                    followFrontmostAppButton
                } else if let boundAppName = activeBoundFrontmostAppName {
                    followingAppBadge(appName: boundAppName)
                }

                let columns = [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ]

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<BarPage.slotsPerPage, id: \.self) { slotIdx in
                        let item = activePage.slots[slotIdx]
                        let key = "\(safePageIndex)-\(slotIdx)"
                        let iconData = item?.bundleIdentifier.flatMap {
                            client.appIconsByBundleID[$0] ?? BundledAppIcons.pngData(for: $0)
                        }
                        let isFrontmost = (item?.bundleIdentifier != nil && item?.bundleIdentifier == client.frontmostBundleID)

                        watchSlotButton(
                            pageIndex: safePageIndex,
                            slotIndex: slotIdx,
                            key: key,
                            item: item,
                            iconData: iconData,
                            isFrontmost: isFrontmost
                        )
                        .frame(height: 64)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
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
    }

    private var pageSwitcherBar: some View {
        HStack(spacing: 6) {
            Button {
                stepPage(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
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
                        .font(.system(size: 13))
                    Text(activePage.title)
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Text("\(safePageIndex + 1)/\(client.profile.pages.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
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
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 36, height: 36)
                    .background(palette.tileFillBottom, in: Circle())
                    .overlay(Circle().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var followFrontmostAppButton: some View {
        Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            withAnimation(.easeInOut(duration: 0.22)) {
                deckFollower.followFrontmostApp(
                    frontmostBundleIdentifier: client.frontmostBundleID,
                    in: client.profile
                )
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10.5, weight: .bold))
                Text(L10n.tr("跟随前台应用", "Follow Frontmost App", language: lang))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
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

    private func followingAppBadge(appName: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "macwindow")
                .font(.system(size: 9.5, weight: .bold))
            Text(L10n.tr("跟随 \(appName)", "Following \(appName)", language: lang))
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(palette.accent.opacity(0.14), in: Capsule())
        .foregroundStyle(palette.accent)
    }

    private func stepPage(by delta: Int) {
        guard !client.profile.pages.isEmpty else { return }
        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
        withAnimation(.easeInOut(duration: 0.2)) {
            deckFollower.stepManualPage(by: delta, in: client.profile)
        }
    }

    private func watchSlotButton(
        pageIndex: Int,
        slotIndex: Int,
        key: String,
        item: BarItem?,
        iconData: Data?,
        isFrontmost: Bool
    ) -> some View {
        let isPressed = (pressedSlotKey == key)

        return Button {
            if let item {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                withAnimation(.spring(response: 0.16, dampingFraction: 0.65)) {
                    pressedSlotKey = key
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if pressedSlotKey == key {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                            pressedSlotKey = nil
                        }
                    }
                }
                client.triggerBarItem(item)
            } else {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                assigningSlot = WatchSlotCoordinate(pageIndex: pageIndex, slotIndex: slotIndex)
            }
        } label: {
            ChocBarTileCard(
                item: item,
                iconData: iconData,
                isFrontmostApp: isFrontmost,
                palette: palette,
                language: lang,
                compact: true
            )
            .scaleEffect(isPressed ? 0.93 : 1.0)
        }
        .buttonStyle(.plain)
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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(palette.accent)
                    Text(L10n.tr("跟随前台应用", "Follow Frontmost App", language: lang))
                        .font(.system(size: 13, weight: deckFollower.isFollowingFrontmostApp ? .bold : .medium, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Spacer()
                    if deckFollower.isFollowingFrontmostApp {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
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
                            .font(.system(size: 15))
                        Text(page.title)
                            .font(.system(size: 13.5, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        Spacer()
                        if pageOffset == safePageIndex {
                            Image(systemName: deckFollower.isFollowingFrontmostApp ? "macwindow" : "checkmark")
                                .font(.caption.bold())
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
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                    Text(L10n.tr("\(flow.enabledStepCount) 步", "\(flow.enabledStepCount) steps", language: lang))
                                        .font(.caption2)
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
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(1)
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
                        Label(action.compactTitle(in: lang), systemImage: action.sfSymbol)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(palette.primaryText)
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

    @State private var pressedAction: SystemQuickAction?

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
        .openEmojiPicker, .lockScreen
    ]

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !client.connectionState.isConnected {
                    WatchConnectionStateBanner(client: client, onTap: onRequestPairing)
                }

                // Media & Volume Strip (Clean iconic transport buttons >= 46pt)
                sectionHeader(L10n.tr("媒体与音量", "Media & Volume", language: lang), symbol: "speaker.wave.2.fill")

                tripleMediaStrip([.mediaPrevious, .mediaPlayPause, .mediaNext])
                tripleMediaStrip([.volumeDown, .volumeMute, .volumeUp])

                // Window Snap & Sizing
                sectionHeader(L10n.tr("窗口布局", "Window Layout", language: lang), symbol: "macwindow")

                actionTwoColumnGrid(windowActions)

                // Workspace & Clipboard
                sectionHeader(L10n.tr("工作区与编辑", "Workspace & Edit", language: lang), symbol: "sparkles")

                actionTwoColumnGrid(workspaceActions)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }

    private func sectionHeader(_ text: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.secondaryText)
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
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
                    trigger(action)
                } label: {
                    Image(systemName: action.sfSymbol)
                        .font(.system(size: isPrimary ? 18 : 16, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            LinearGradient(
                                colors: [
                                    palette.tileFillTop,
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
                                    isPrimary ? palette.accent.opacity(0.65) : palette.subtleCardStroke,
                                    lineWidth: 1
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .scaleEffect(isPressed ? 0.94 : 1.0)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.compactTitle(in: lang))
            }
        }
    }

    private func actionTwoColumnGrid(_ actions: [SystemQuickAction]) -> some View {
        let cols = [
            GridItem(.flexible(), spacing: 7),
            GridItem(.flexible(), spacing: 7)
        ]

        return LazyVGrid(columns: cols, spacing: 7) {
            ForEach(actions) { action in
                let tileTone = ChocSwatch.resolvedTileColor(hex: action.accentHex, fallbackHex: ChocPalette.coreTileBottomHex)
                let isPressed = (pressedAction == action)

                Button {
                    trigger(action)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: action.sfSymbol)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                            .frame(width: 18)

                        Text(action.compactTitle(in: lang))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 48)
                    .background(
                        LinearGradient(
                            colors: [palette.tileFillTop, tileTone],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .scaleEffect(isPressed ? 0.94 : 1.0)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func trigger(_ action: SystemQuickAction) {
        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .rigid)
        withAnimation(.spring(response: 0.14, dampingFraction: 0.65)) {
            pressedAction = action
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            if pressedAction == action {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                    pressedAction = nil
                }
            }
        }
        client.performQuickAction(action)
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
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.secondaryText)

                if client.recentApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.title3)
                            .foregroundStyle(palette.secondaryText)
                        Text(
                            client.connectionState.isConnected
                                ? L10n.tr("在 Mac 上切换窗口后即会同步至此", "Switch windows on your Mac to sync here", language: lang)
                                : L10n.tr("连接 Mac 后可腕上一键切换窗口", "Connect your Mac to switch windows from your wrist", language: lang)
                        )
                        .font(.system(size: 12, design: .rounded))
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
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        Text(
                            entry.isFrontmost
                                ? L10n.tr("当前前台", "Active", language: lang)
                                : (entry.isRunning ? L10n.tr("运行中", "Running", language: lang) : L10n.tr("已固定", "Pinned", language: lang))
                        )
                        .font(.system(size: 10.5, weight: .medium))
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
                    .font(.system(size: 12, weight: .semibold))
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
                            .font(.system(size: 10.5, weight: .bold))
                        Text(L10n.tr("正在 \(client.focusedMacAppName ?? "Mac") 输入", "Typing in \(client.focusedMacAppName ?? "Mac")", language: lang))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(palette.statusConnected.opacity(0.22), in: Capsule())
                    .foregroundStyle(palette.statusConnected)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "character.cursor.ibeam")
                            .font(.system(size: 10, weight: .bold))
                        Text(L10n.tr("请先在 Mac 点击输入框", "Focus a Mac text field", language: lang))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(palette.tileFillBottom, in: Capsule())
                    .foregroundStyle(palette.secondaryText)
                }

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
                    .font(.system(size: 10.5, weight: .bold))
                Text(label)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
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
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 36, height: 36)
                    .background(palette.tileFillBottom, in: Circle())
                    .overlay(Circle().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 5) {
                Text(activeSlide.iconEmoji)
                    .font(.system(size: 13))
                Text(activeSlide.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
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
                    .font(.system(size: 12, weight: .bold))
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
                    withAnimation(.spring(response: 0.14, dampingFraction: 0.65)) {
                        pressedEmojiIndex = idx
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                        if pressedEmojiIndex == idx {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                                pressedEmojiIndex = nil
                            }
                        }
                    }
                    if client.connectionState.isConnected {
                        client.insertEmoji(emoji)
                    } else {
                        onRequestPairing()
                    }
                } label: {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
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
                                .strokeBorder(palette.tileBorderHighlight.opacity(0.48), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .scaleEffect(isPressed ? 0.93 : 1.0)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var savedSnippetsSlotsList: some View {
        if client.profile.snippets.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.title3)
                    .foregroundStyle(palette.secondaryText)
                Text(
                    L10n.tr(
                        "在 iPhone 或 iPad 上新建片段后即可在腕上一键输入",
                        "Create snippets on iPhone or iPad to trigger them here",
                        language: lang
                    )
                )
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else {
            ForEach(client.profile.snippets) { snippet in
                let isPressed = (pressedSnippetID == snippet.id)

                Button {
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                    withAnimation(.spring(response: 0.14, dampingFraction: 0.65)) {
                        pressedSnippetID = snippet.id
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                        if pressedSnippetID == snippet.id {
                            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                                pressedSnippetID = nil
                            }
                        }
                    }
                    if client.connectionState.isConnected {
                        client.insertText(snippet.body)
                    } else {
                        onRequestPairing()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snippet.displayTitle(in: lang))
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)

                        Text(snippet.singleLinePreview)
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 46)
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
                            .strokeBorder(palette.tileBorderHighlight.opacity(0.55), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .scaleEffect(isPressed ? 0.94 : 1.0)
                }
                .buttonStyle(.plain)
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
