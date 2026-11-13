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

// MARK: - 1. Chocolate Bar Surface (8 Pages x 8 Slots)

public struct IOSChocolateBarSurfaceView: View {
    @ObservedObject var client: CompanionClientEngine
    @Binding var currentPageIndex: Int
    var isFollowingFrontmostApp: Bool
    var onFollowFrontmostApp: (() -> Void)?
    let isLandscape: Bool
    let onEditSlot: (IOSEditSlotSelection) -> Void

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        currentPageIndex: Binding<Int>,
        isFollowingFrontmostApp: Bool = true,
        onFollowFrontmostApp: (() -> Void)? = nil,
        isLandscape: Bool,
        onEditSlot: @escaping (IOSEditSlotSelection) -> Void
    ) {
        self.client = client
        self._currentPageIndex = currentPageIndex
        self.isFollowingFrontmostApp = isFollowingFrontmostApp
        self.onFollowFrontmostApp = onFollowFrontmostApp
        self.isLandscape = isLandscape
        self.onEditSlot = onEditSlot
    }

    private var activeBoundFrontmostAppName: String? {
        guard isFollowingFrontmostApp,
              let frontBundleID = client.frontmostBundleID,
              !client.profile.pages.isEmpty else {
            return nil
        }
        let safeIdx = min(max(0, currentPageIndex), client.profile.pages.count - 1)
        let activePage = client.profile.pages[safeIdx]
        guard client.profile.boundPageID(forBundleIdentifier: frontBundleID) == activePage.id else {
            return nil
        }
        return client.profile.resolvedAppDisplayName(
            forBundleIdentifier: frontBundleID,
            recentApps: client.recentApps,
            catalogApps: client.macCatalogApps
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !isFollowingFrontmostApp, let onFollowFrontmostApp {
                manualPinnedHeader(onFollow: onFollowFrontmostApp)
            } else if let boundAppName = activeBoundFrontmostAppName {
                followingAppHeader(appName: boundAppName)
            }

            TabView(selection: $currentPageIndex) {
                ForEach(Array(client.profile.pages.enumerated()), id: \.element.id) { pageOffset, page in
                    pageGrid(for: page, pageOffset: pageOffset)
                        .tag(pageOffset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
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

    private func followingAppHeader(appName: String) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "macwindow")
                    .font(.caption2.bold())
                Text(L10n.tr("正跟随 \(appName)", "Following \(appName)", language: lang))
                    .font(.caption2.bold())
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(palette.accent.opacity(0.14), in: Capsule())
            .foregroundStyle(palette.accent)

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

            VStack(spacing: spacing) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<colCount, id: \.self) { col in
                            let slotIdx = row * colCount + col
                            let item = page.slots[slotIdx]
                            let key = "\(pageOffset)-\(slotIdx)"
                            let iconData = item?.bundleIdentifier.flatMap {
                                client.appIconsByBundleID[$0] ?? BundledAppIcons.pngData(for: $0)
                            }
                            let isFrontmost = (item?.bundleIdentifier != nil && item?.bundleIdentifier == client.frontmostBundleID)

                            tileButton(
                                pageIndex: pageOffset,
                                slotIndex: slotIdx,
                                key: key,
                                item: item,
                                iconData: iconData,
                                isFrontmost: isFrontmost
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

    private func tileButton(
        pageIndex: Int,
        slotIndex: Int,
        key: String,
        item: BarItem?,
        iconData: Data?,
        isFrontmost: Bool
    ) -> some View {
        let isPressed = (pressedKey == key)

        return Button {
            if let item {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                withAnimation(.spring(response: 0.16, dampingFraction: 0.6)) {
                    pressedKey = key
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    if pressedKey == key {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                            pressedKey = nil
                        }
                    }
                }
                client.triggerBarItem(item)
            } else {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                onEditSlot(IOSEditSlotSelection(pageIndex: pageIndex, slotIndex: slotIndex))
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
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-slot-\(pageIndex)-\(slotIndex)")
        .accessibilityLabel(
            item?.displayTitle(in: lang)
                ?? L10n.tr("空槽位 \(slotIndex + 1)", "Empty Slot \(slotIndex + 1)", language: lang)
        )
        .contextMenu {
            Button {
                onEditSlot(IOSEditSlotSelection(pageIndex: pageIndex, slotIndex: slotIndex))
            } label: {
                Label(L10n.tr("配置此巧克力槽…", "Configure Slot…", language: lang), systemImage: "pencil")
            }

            if let item {
                Button {
                    client.triggerBarItem(item)
                } label: {
                    Label(L10n.tr("立即在 Mac 执行", "Run on Mac", language: lang), systemImage: "play.fill")
                }

                Button(role: .destructive) {
                    var updated = client.profile
                    guard updated.pages.indices.contains(pageIndex),
                          updated.pages[pageIndex].slots.indices.contains(slotIndex) else { return }
                    updated.pages[pageIndex].slots[slotIndex] = nil
                    client.pushUpdatedProfile(updated)
                } label: {
                    Label(L10n.tr("清空槽位", "Clear Slot", language: lang), systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - 2. App Time Travel Surface

public struct IOSTimeTravelSurfaceView: View {
    @ObservedObject var client: CompanionClientEngine
    let isLandscape: Bool
    let currentBarPageIndex: Int
    var onRequestPairing: (() -> Void)?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        isLandscape: Bool,
        currentBarPageIndex: Int,
        onRequestPairing: (() -> Void)? = nil
    ) {
        self.client = client
        self.isLandscape = isLandscape
        self.currentBarPageIndex = currentBarPageIndex
        self.onRequestPairing = onRequestPairing
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
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(client.recentApps) { entry in
                            recentAppCard(entry)
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

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
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
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [palette.tileFillTop, palette.tileFillBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(entry.isFrontmost ? palette.accent : palette.tileBorderHighlight.opacity(0.45), lineWidth: entry.isFrontmost ? 2 : 1)
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
                    client.quitOrHideApp(bundleIdentifier: entry.bundleIdentifier, shouldQuit: true)
                } label: {
                    Label(L10n.tr("退出应用", "Quit App on Mac", language: lang), systemImage: "xmark.octagon")
                }
            }
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

// MARK: - 3. Emoji Bar Surface (8 Slides + Quick Catalog)

public struct IOSEmojiBarSurfaceView: View {
    @ObservedObject var client: CompanionClientEngine
    @Binding var currentSlideIndex: Int
    let isLandscape: Bool

    @State private var showAllCatalogSheet = false
    @State private var customizingSlotIndex: Int?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        currentSlideIndex: Binding<Int>,
        isLandscape: Bool
    ) {
        self.client = client
        self._currentSlideIndex = currentSlideIndex
        self.isLandscape = isLandscape
    }

    public var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
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
                } else if !client.profile.emojiSlides.isEmpty {
                    let safeIdx = min(max(0, currentSlideIndex), client.profile.emojiSlides.count - 1)
                    HStack(spacing: 5) {
                        Text(client.profile.emojiSlides[safeIdx].iconEmoji)
                        Text(client.profile.emojiSlides[safeIdx].title)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Spacer()

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
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            TabView(selection: $currentSlideIndex) {
                ForEach(client.profile.emojiSlides) { slide in
                    emojiSlideGrid(slide)
                        .tag(slide.index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .sheet(isPresented: $showAllCatalogSheet) {
            emojiBrowserSheet
        }
    }

    private func emojiSlideGrid(_ slide: EmojiSlide) -> some View {
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

                            Button {
                                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                client.insertEmoji(emoji)
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .fill(LinearGradient(colors: [palette.tileFillTop, palette.tileFillBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                                .strokeBorder(palette.tileBorderHighlight.opacity(0.5), lineWidth: 1.1)
                                        )

                                    Text(emoji)
                                        .font(.system(size: min(tileW, tileH) * 0.48))
                                }
                                .frame(width: tileW, height: tileH)
                                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            }
                            .buttonStyle(.plain)
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
            }
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
