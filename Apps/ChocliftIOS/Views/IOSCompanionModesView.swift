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
    let isLandscape: Bool
    let onEditSlot: (IOSEditSlotSelection) -> Void

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        currentPageIndex: Binding<Int>,
        isLandscape: Bool,
        onEditSlot: @escaping (IOSEditSlotSelection) -> Void
    ) {
        self.client = client
        self._currentPageIndex = currentPageIndex
        self.isLandscape = isLandscape
        self.onEditSlot = onEditSlot
    }

    public var body: some View {
        TabView(selection: $currentPageIndex) {
            ForEach(client.profile.pages) { page in
                pageGrid(for: page)
                    .tag(page.index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private func pageGrid(for page: BarPage) -> some View {
        let colCount = isLandscape ? 4 : 2
        let rowCount = isLandscape ? 2 : 4

        return GeometryReader { geo in
            let spacing: CGFloat = isLandscape ? 12 : 14
            let horizontalPad: CGFloat = isLandscape ? 14 : 18
            let verticalPad: CGFloat = isLandscape ? 12 : 16
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
                            let key = "\(page.index)-\(slotIdx)"
                            let iconData = item?.bundleIdentifier.flatMap { client.appIconsByBundleID[$0] }
                            let isFrontmost = (item?.bundleIdentifier != nil && item?.bundleIdentifier == client.frontmostBundleID)

                            tileButton(
                                pageIndex: page.index,
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
            .scaleEffect(isPressed ? 0.93 : 1.0)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onEditSlot(IOSEditSlotSelection(pageIndex: pageIndex, slotIndex: slotIndex))
            } label: {
                Label(L10n.tr("编辑此巧克力槽…", "Configure Slot…", language: lang), systemImage: "pencil")
            }

            if let item {
                Button {
                    client.triggerBarItem(item)
                } label: {
                    Label(L10n.tr("立即在 Mac 执行", "Run on Mac", language: lang), systemImage: "play.fill")
                }

                Button(role: .destructive) {
                    var updated = client.profile
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

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine, isLandscape: Bool, currentBarPageIndex: Int) {
        self.client = client
        self.isLandscape = isLandscape
        self.currentBarPageIndex = currentBarPageIndex
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.tr("应用时间旅行", "App Time Travel", language: lang), systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.bold())
                    .foregroundStyle(palette.primaryText)

                Spacer()

                Text(L10n.tr("轻点即切 · 长按可固定或退出（支持拖拽文件时切换目标窗口）", "Tap to switch · Long-press to Pin or Quit", language: lang))
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if client.recentApps.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(palette.secondaryText)
                    Text(
                        client.connectionState.isConnected
                            ? L10n.tr("等待同步 Mac 最近打开的应用…", "Syncing recent Mac apps…", language: lang)
                            : L10n.tr("连接 Mac 后即可实时查看和穿梭最近打开的应用", "Connect to your Mac to jump through recently opened apps", language: lang)
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                }
                .frame(maxWidth: .infinity)
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
        let icon = client.appIconsByBundleID[entry.bundleIdentifier]

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
                            .foregroundStyle(palette.accentGold)
                            .padding(4)
                            .background(.black.opacity(0.65), in: Circle())
                            .offset(x: 6, y: -4)
                    }
                }

                Text(entry.appName)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle()
                        .fill(entry.isFrontmost ? palette.accentGold : (entry.isRunning ? .green.opacity(0.75) : .gray))
                        .frame(width: 5, height: 5)
                    Text(entry.isFrontmost
                         ? L10n.tr("当前窗口", "Active", language: lang)
                         : (entry.isRunning ? L10n.tr("运行中", "Running", language: lang) : L10n.tr("已固定", "Pinned", language: lang)))
                        .font(.system(size: 9, weight: .medium))
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
                            .strokeBorder(entry.isFrontmost ? palette.accentGold : palette.tileBorderHighlight.opacity(0.45), lineWidth: entry.isFrontmost ? 2 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                client.togglePinRecentApp(entry)
            } label: {
                Label(
                    entry.isPinned ? L10n.tr("取消固定", "Unpin", language: lang) : L10n.tr("固定到时间旅行最前", "Pin Favorite", language: lang),
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
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.22), in: Capsule())
                    .foregroundStyle(.green)
                } else {
                    Text(client.profile.emojiSlides[min(max(0, currentSlideIndex), client.profile.emojiSlides.count - 1)].title)
                        .font(.caption.bold())
                        .foregroundStyle(palette.secondaryText)
                }

                Spacer()

                Button {
                    customizingSlotIndex = nil
                    showAllCatalogSheet = true
                } label: {
                    Label(L10n.tr("全部分类", "All Emojis", language: lang), systemImage: "magnifyingglass")
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(palette.tileFillTop, in: Capsule())
                        .foregroundStyle(palette.primaryText)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(EmojiCatalog.categories) { cat in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(cat.icon) \(cat.title(in: lang))")
                                .font(.headline)
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
                                            .font(.system(size: 30))
                                            .frame(height: 44)
                                            .frame(maxWidth: .infinity)
                                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(
                customizingSlotIndex != nil
                    ? L10n.tr("选择替换表情", "Pick Replacement Emoji", language: lang)
                    : L10n.tr("点击直接输入到 Mac", "Tap to Type on Mac", language: lang)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("关闭", "Close", language: lang)) {
                        showAllCatalogSheet = false
                    }
                }
            }
        }
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
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [palette.tileFillTop.opacity(0.72), palette.backgroundBottom.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(palette.tileBorderHighlight.opacity(0.6), lineWidth: 1.4)
                    )

                VStack(spacing: 8) {
                    Image(systemName: "hand.draw.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(palette.accentGold)
                    Text(L10n.tr("多指触控手势板", "Multi-Touch Gesture Pad", language: lang))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    VStack(spacing: 3) {
                        Text(L10n.tr("双指上滑：最大化窗口  ·  双指下滑：最小化窗口", "2-Finger Up: Maximize  ·  2-Finger Down: Minimize", language: lang))
                        Text(L10n.tr("双指左/右滑：左右半屏  ·  捏合/张开：复制与粘贴", "2-Finger L/R: Snap Half  ·  Pinch In/Out: Copy & Paste", language: lang))
                    }
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Tactile Quick Trigger Grid (also great for one-handed or Simulator tapping!)
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
                        VStack(spacing: 3) {
                            Image(systemName: mapped?.sfSymbol ?? gesture.sfSymbol)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(palette.accentGold)
                            Text(mapped?.title(in: lang) ?? gesture.title(in: lang))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 6)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: isLandscape ? 250 : .infinity)
        }
        .padding(14)
    }
}
