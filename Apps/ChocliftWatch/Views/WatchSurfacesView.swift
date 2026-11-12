import ChocliftCore
import SwiftUI

public struct WatchSlotCoordinate: Identifiable {
    public let pageIndex: Int
    public let slotIndex: Int
    public var id: String { "\(pageIndex)-\(slotIndex)" }
}

// MARK: - 1. Watch Chocolate Bar Surface (8 Synced Pages x 8 Slots)

public struct WatchChocolateBarView: View {
    @ObservedObject var client: CompanionClientEngine
    @Binding var currentPageIndex: Int
    let onRequestPairing: () -> Void

    @State private var showPagePickerSheet: Bool = false
    @State private var assigningSlot: WatchSlotCoordinate?
    @State private var pressedSlotKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var safePageIndex: Int {
        guard !client.profile.pages.isEmpty else { return 0 }
        return min(max(0, currentPageIndex), client.profile.pages.count - 1)
    }

    private var activePage: BarPage {
        guard !client.profile.pages.isEmpty else {
            return BarPage(index: 0, title: "Daily", iconEmoji: "🍫")
        }
        return client.profile.pages[safePageIndex]
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if !client.connectionState.isConnected {
                    watchConnectionBanner
                }

                pageSwitcherBar

                let columns = [
                    GridItem(.flexible(), spacing: 7),
                    GridItem(.flexible(), spacing: 7)
                ]

                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(0..<BarPage.slotsPerPage, id: \.self) { slotIdx in
                        let item = activePage.slots[slotIdx]
                        let key = "\(safePageIndex)-\(slotIdx)"
                        let iconData = item?.bundleIdentifier.flatMap { client.appIconsByBundleID[$0] }
                        let isFrontmost = (item?.bundleIdentifier != nil && item?.bundleIdentifier == client.frontmostBundleID)

                        watchSlotButton(
                            pageIndex: safePageIndex,
                            slotIndex: slotIdx,
                            key: key,
                            item: item,
                            iconData: iconData,
                            isFrontmost: isFrontmost
                        )
                        .frame(height: 56)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
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

    private var watchConnectionBanner: some View {
        Button {
            onRequestPairing()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: connectionBannerIcon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.accentGold)
                Text(connectionBannerTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(palette.accentGold.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var connectionBannerIcon: String {
        switch client.connectionState {
        case .awaitingPIN: return "key.fill"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .disconnected, .connected: return "laptopcomputer.and.applewatch"
        }
    }

    private var connectionBannerTitle: String {
        switch client.connectionState {
        case .awaitingPIN(_, let macName, _):
            return L10n.tr("输入 \(macName) 配对码", "Enter PIN for \(macName)", language: lang)
        case .connecting(let targetName):
            return L10n.tr("正在连接 \(targetName)…", "Connecting \(targetName)…", language: lang)
        case .disconnected:
            return L10n.tr("未连接 · 点此配对 Mac", "Offline · Tap to Pair Mac", language: lang)
        case .connected(_, let macName):
            return macName
        }
    }

    private var pageSwitcherBar: some View {
        HStack(spacing: 6) {
            Button {
                stepPage(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 26, height: 26)
                    .background(palette.tileFillBottom, in: Circle())
            }
            .buttonStyle(.plain)

            Button {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                showPagePickerSheet = true
            } label: {
                HStack(spacing: 4) {
                    Text(activePage.iconEmoji)
                        .font(.system(size: 12))
                    Text(activePage.title)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Text("\(safePageIndex + 1)/\(client.profile.pages.count)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(palette.barSurface, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                stepPage(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 26, height: 26)
                    .background(palette.tileFillBottom, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func stepPage(by delta: Int) {
        let count = client.profile.pages.count
        guard count > 0 else { return }
        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
        currentPageIndex = (safePageIndex + delta + count) % count
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
            ForEach(client.profile.pages) { page in
                Button {
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                    currentPageIndex = page.index
                    showPagePickerSheet = false
                } label: {
                    HStack(spacing: 8) {
                        Text(page.iconEmoji)
                        Text(page.title)
                            .font(.system(.callout, design: .rounded, weight: page.index == safePageIndex ? .bold : .medium))
                        Spacer()
                        if page.index == safePageIndex {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(palette.accentGold)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Quick Slot Assignment Sheet on Watch

private struct WatchSlotQuickAssignSheet: View {
    @ObservedObject var client: CompanionClientEngine
    let pageIndex: Int
    let slotIndex: Int
    @Environment(\.dismiss) private var dismiss

    private var lang: AppLanguage { client.profile.settings.language }

    var body: some View {
        List {
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
                                    pngData: client.appIconsByBundleID[entry.bundleIdentifier],
                                    fallbackSymbol: "app.fill"
                                )
                                .frame(width: 20, height: 20)
                                Text(entry.appName)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            Section(L10n.tr("系统快捷动作", "Quick Actions", language: lang)) {
                ForEach(SystemQuickAction.allCases) { action in
                    Button {
                        assign(BarItem(kind: .systemAction(action: action)))
                    } label: {
                        Label(action.compactTitle(in: lang), systemImage: action.sfSymbol)
                    }
                }
            }
        }
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
                    Button {
                        onRequestPairing()
                    } label: {
                        Label(
                            L10n.tr("未连接 Mac · 点此配对", "Not Linked · Pair Mac", language: lang),
                            systemImage: "exclamationmark.circle.fill"
                        )
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.accentGold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }

                // Media & Volume Strip
                sectionHeader(L10n.tr("媒体与音量", "Media & Volume", language: lang), symbol: "speaker.wave.2.fill")

                tripleActionStrip([.mediaPrevious, .mediaPlayPause, .mediaNext])
                tripleActionStrip([.volumeDown, .volumeMute, .volumeUp])

                // Window Snap & Sizing
                sectionHeader(L10n.tr("窗口控制", "Window Layout", language: lang), symbol: "macwindow")

                actionTwoColumnGrid(windowActions)

                // Workspace & Clipboard
                sectionHeader(L10n.tr("工作区与剪贴板", "Workspace & Edit", language: lang), symbol: "sparkles")

                actionTwoColumnGrid(workspaceActions)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
        }
    }

    private func sectionHeader(_ text: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.accentGold)
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.top, 2)
    }

    private func tripleActionStrip(_ actions: [SystemQuickAction]) -> some View {
        HStack(spacing: 6) {
            ForEach(actions) { action in
                Button {
                    trigger(action)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: action.sfSymbol)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Text(action.compactTitle(in: lang))
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        LinearGradient(
                            colors: [palette.tileFillTop, Color(hex: action.accentHex).opacity(0.42)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func actionTwoColumnGrid(_ actions: [SystemQuickAction]) -> some View {
        let cols = [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]

        return LazyVGrid(columns: cols, spacing: 6) {
            ForEach(actions) { action in
                let accent = Color(hex: action.accentHex)
                Button {
                    trigger(action)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: action.sfSymbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 18)
                        Text(action.compactTitle(in: lang))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .background(
                        LinearGradient(
                            colors: [palette.tileFillTop, accent.opacity(0.38)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(accent.opacity(0.55), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func trigger(_ action: SystemQuickAction) {
        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .rigid)
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
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(L10n.tr("应用时间旅行", "Time Travel", language: lang), systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                }

                if client.recentApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.title3)
                            .foregroundStyle(palette.secondaryText)
                        Text(
                            client.connectionState.isConnected
                                ? L10n.tr("等待同步最近应用…", "Syncing recent Mac apps…", language: lang)
                                : L10n.tr("配对 Mac 后可一键切换最近打开的应用", "Pair your Mac to switch recent apps from your wrist", language: lang)
                        )
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)

                        if !client.connectionState.isConnected {
                            Button(L10n.tr("立即配对", "Pair Mac", language: lang)) {
                                onRequestPairing()
                            }
                            .font(.caption.bold())
                        }
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
            .padding(.bottom, 10)
        }
    }

    private func recentAppRow(_ entry: RecentAppEntry) -> some View {
        let icon = client.appIconsByBundleID[entry.bundleIdentifier]

        return HStack(spacing: 6) {
            Button {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                client.activateRecentApp(entry)
            } label: {
                HStack(spacing: 8) {
                    DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.appName)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                        Text(
                            entry.isFrontmost
                                ? L10n.tr("当前前台", "Active", language: lang)
                                : (entry.isRunning ? L10n.tr("运行中", "Running", language: lang) : L10n.tr("已固定", "Pinned", language: lang))
                        )
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(entry.isFrontmost ? palette.accentGold : palette.secondaryText)
                    }

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)

            Button {
                CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                client.togglePinRecentApp(entry)
            } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.isPinned ? palette.accentGold : palette.secondaryText.opacity(0.7))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(entry.isFrontmost ? palette.accentGold : palette.tileBorderHighlight.opacity(0.35), lineWidth: entry.isFrontmost ? 1.6 : 1)
        )
    }
}

// MARK: - 4. Watch Emoji Bar Surface (8 Synced Slides)

public struct WatchEmojiBarView: View {
    @ObservedObject var client: CompanionClientEngine
    @Binding var currentSlideIndex: Int
    let onRequestPairing: () -> Void

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
                if client.isEditingTextOnMac {
                    HStack(spacing: 4) {
                        Image(systemName: "character.cursor.ibeam")
                            .font(.system(size: 10, weight: .bold))
                        Text(L10n.tr("正在 \(client.focusedMacAppName ?? "Mac") 输入", "Typing in \(client.focusedMacAppName ?? "Mac")", language: lang))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.22), in: Capsule())
                    .foregroundStyle(.green)
                }

                HStack(spacing: 6) {
                    Button {
                        stepSlide(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                            .frame(width: 26, height: 26)
                            .background(palette.tileFillBottom, in: Circle())
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 4) {
                        Text(activeSlide.iconEmoji)
                            .font(.system(size: 12))
                        Text(activeSlide.title)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(palette.barSurface, in: Capsule())

                    Button {
                        stepSlide(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                            .frame(width: 26, height: 26)
                            .background(palette.tileFillBottom, in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                let cols = [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6)
                ]

                LazyVGrid(columns: cols, spacing: 6) {
                    ForEach(Array(activeSlide.emojis.enumerated()), id: \.offset) { _, emoji in
                        Button {
                            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                            if client.connectionState.isConnected {
                                client.insertEmoji(emoji)
                            } else {
                                onRequestPairing()
                            }
                        } label: {
                            Text(emoji)
                                .font(.system(size: 24))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(
                                    LinearGradient(
                                        colors: [palette.tileFillTop, palette.tileFillBottom],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(palette.tileBorderHighlight.opacity(0.45), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
        }
    }

    private func stepSlide(by delta: Int) {
        let count = client.profile.emojiSlides.count
        guard count > 0 else { return }
        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
        currentSlideIndex = (safeSlideIndex + delta + count) % count
    }
}
