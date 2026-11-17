import ChocliftCore
import SwiftUI

public struct IOSSetappBarView: View {
    @ObservedObject var client: CompanionClientEngine
    private var externalBarBook: Binding<SetappBarBook>?
    private var externalTimeTravelBook: Binding<AppTimeTravelBook>?
    public var onTileRecentApps: () -> Void

    @State private var selectedPageIndex: Int = 0
    @State private var localBarBookOverride: SetappBarBook?
    @State private var localLayoutByPage: [Int: SetappBarTileLayout] = [:]
    @State private var localPinnedBundleIDsOverride: [String]?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        barBook: Binding<SetappBarBook>? = nil,
        timeTravelBook: Binding<AppTimeTravelBook>? = nil,
        onTileRecentApps: @escaping () -> Void = {}
    ) {
        self.client = client
        self.externalBarBook = barBook
        self.externalTimeTravelBook = timeTravelBook
        self.onTileRecentApps = onTileRecentApps
    }

    private var activeBarBook: SetappBarBook {
        if let externalBarBook {
            return externalBarBook.wrappedValue
        }
        if let localBarBookOverride {
            return localBarBookOverride
        }
        return Self.makeBarBook(
            from: client.profile,
            layoutOverrides: localLayoutByPage
        )
    }

    private var clampedPageIndex: Int {
        min(max(0, selectedPageIndex), SetappBarBook.pageCount - 1)
    }

    private var currentPage: SetappBarPage {
        activeBarBook.page(at: clampedPageIndex)
            ?? SetappBarPage(index: clampedPageIndex, layout: .one)
    }

    private var currentLayoutBinding: Binding<SetappBarTileLayout> {
        Binding(
            get: { currentPage.layout },
            set: { newLayout in
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                setPageLayout(newLayout, forPage: clampedPageIndex)
            }
        )
    }

    private var activeTimeTravelBook: AppTimeTravelBook {
        if let externalTimeTravelBook {
            return externalTimeTravelBook.wrappedValue
        }
        return Self.makeTimeTravelBook(
            profile: client.profile,
            recentApps: client.recentApps,
            catalogApps: client.macCatalogApps,
            pinnedOverride: localPinnedBundleIDsOverride
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            barCard
            tileRecentAppsButton
            timeTravelCard
            gestureCaptionsCard
        }
        .accessibilityIdentifier("ios-setapp-bar-view")
    }

    // MARK: - 8-Page Bar + Layout Picker + Tile Grid

    private var barCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(currentPage.title(in: lang))
                    .font(ChocType.title)
                    .foregroundStyle(palette.primaryText)

                Spacer(minLength: 8)

                pageDotsRow
            }

            Picker(
                L10n.tr("页面布局", "Tile Layout", language: lang),
                selection: currentLayoutBinding
            ) {
                ForEach(SetappBarTileLayout.allCases) { layout in
                    Text(layout.title(in: lang))
                        .tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("ios-setapp-layout-picker")

            TabView(selection: $selectedPageIndex) {
                ForEach(0..<SetappBarBook.pageCount, id: \.self) { pageIdx in
                    let page = activeBarBook.page(at: pageIdx)
                        ?? SetappBarPage(index: pageIdx, layout: .one)
                    pageTileGrid(page: page, pageIndex: pageIdx)
                        .padding(.horizontal, 2)
                        .tag(pageIdx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: tileGridHeight(for: currentPage.layout))
            .animation(.easeInOut(duration: 0.2), value: currentPage.layout)
            .accessibilityIdentifier("ios-setapp-page-pager")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var pageDotsRow: some View {
        HStack(spacing: 6) {
            ForEach(0..<SetappBarBook.pageCount, id: \.self) { idx in
                let isSelected = (idx == clampedPageIndex)
                Button {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                        selectedPageIndex = idx
                    }
                } label: {
                    Group {
                        if isSelected {
                            Capsule()
                                .fill(palette.accent)
                                .frame(width: 16, height: 7)
                        } else {
                            Circle()
                                .fill(palette.secondaryText.opacity(0.35))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .frame(minWidth: 18, minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("第 \(idx + 1) 页", "Page \(idx + 1)", language: lang))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("ios-setapp-page-dot-\(idx)")
            }
        }
        .padding(.horizontal, 8)
        .background(palette.tileFillBottom, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
    }

    private func tileGridHeight(for layout: SetappBarTileLayout) -> CGFloat {
        switch layout {
        case .one, .two, .three:
            return 90
        case .four:
            return 188
        }
    }

    private func gridColumnCount(for layout: SetappBarTileLayout) -> Int {
        switch layout {
        case .one: return 1
        case .two: return 2
        case .three: return 3
        case .four: return 2
        }
    }

    private func pageTileGrid(page: SetappBarPage, pageIndex: Int) -> some View {
        let columnCount = gridColumnCount(for: page.layout)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: columnCount)
        let visibleSlots = Array(page.slots.prefix(page.layout.slotCount))

        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(visibleSlots.enumerated()), id: \.offset) { slotIdx, slot in
                tileCell(slot: slot, pageIndex: pageIndex, slotIndex: slotIdx)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func tileCell(slot: SetappBarSlot, pageIndex: Int, slotIndex: Int) -> some View {
        if slot.isEmpty {
            // Empty tile shows a plus; long-press on empty is strictly a no-op.
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                client.lastFeedback = CompanionFeedbackToast(
                    success: true,
                    title: L10n.tr("添加组件", "Add Pieces", language: lang),
                    detail: L10n.tr(
                        "轻点空白区域，通过 Mac App 添加新的 App、Apple 快捷指令、网站或表情符号。",
                        "Tap an empty spot to add a new app, Shortcut, website or emoji using the Mac app.",
                        language: lang
                    )
                )
            } label: {
                ZStack {
                    Image(systemName: "plus")
                        .font(ChocType.title)
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 84)
                .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("添加", "Add", language: lang))
            .accessibilityIdentifier("ios-setapp-empty-tile-\(pageIndex)-\(slotIndex)")
        } else {
            // Filled tile: tap triggers on Mac, long-press shows Remove.
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                activateFilledSlot(slot)
            } label: {
                filledTileContent(for: slot)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 84)
                    .background(
                        LinearGradient(
                            colors: [palette.tileFillTop, palette.tileFillBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) {
                    removeTile(pageIndex: pageIndex, slotIndex: slotIndex)
                } label: {
                    Label(L10n.tr("移除", "Remove", language: lang), systemImage: "trash")
                }
            }
            .accessibilityLabel(tileLabel(for: slot))
            .accessibilityIdentifier("ios-setapp-filled-tile-\(pageIndex)-\(slotIndex)")
        }
    }

    @ViewBuilder
    private func filledTileContent(for slot: SetappBarSlot) -> some View {
        switch slot.kind {
        case .app:
            let iconData = slot.bundleID.flatMap {
                client.cachedAppIconData(forBundleIdentifier: $0) ?? BundledAppIcons.pngData(for: $0)
            }
            VStack(spacing: 5) {
                DataImageView(pngData: iconData, fallbackSymbol: "app.fill", tint: palette.accent)
                    .frame(width: 34, height: 34)
                Text(tileLabel(for: slot))
                    .font(ChocType.micro)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }

        case .shortcut:
            VStack(spacing: 5) {
                if let emoji = slot.emoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.system(size: 28))
                        .frame(height: 34)
                } else {
                    Image(systemName: "bolt.fill")
                        .font(ChocType.title)
                        .foregroundStyle(palette.accent)
                        .frame(width: 34, height: 34)
                }
                Text(tileLabel(for: slot))
                    .font(ChocType.micro)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }

        case .website:
            VStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(ChocType.title)
                    .foregroundStyle(palette.accent)
                    .frame(width: 34, height: 34)
                Text(tileLabel(for: slot))
                    .font(ChocType.micro)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }

        case .emoji:
            Text(slot.emoji ?? "🍫")
                .font(.system(size: 34))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty:
            Image(systemName: "plus")
                .font(ChocType.title)
                .foregroundStyle(palette.secondaryText)
        }
    }

    private func tileLabel(for slot: SetappBarSlot) -> String {
        switch slot.kind {
        case .app:
            if let displayName = slot.displayName, !displayName.isEmpty {
                return displayName
            }
            if let bundleID = slot.bundleID {
                return client.profile.resolvedAppDisplayName(
                    forBundleIdentifier: bundleID,
                    recentApps: client.recentApps,
                    catalogApps: client.macCatalogApps
                )
            }
            return L10n.tr("App", "App", language: lang)

        case .shortcut:
            return slot.shortcutName ?? slot.displayName ?? L10n.tr("快捷指令", "Shortcuts", language: lang)

        case .website:
            if let host = slot.url?.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            return slot.resolvedDisplayName ?? L10n.tr("网站链接", "Links", language: lang)

        case .emoji:
            return slot.emoji ?? ""

        case .empty:
            return L10n.tr("添加", "Add", language: lang)
        }
    }

    // MARK: - Tile Recent Apps (iPhone Duo Fold Stand-In)

    private var tileRecentAppsButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                onTileRecentApps()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.split.2x2.fill")
                        .font(ChocType.body)
                    Text("Tile recent apps")
                        .font(ChocType.body.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "macwindow.on.rectangle")
                        .font(ChocType.caption)
                }
                .foregroundStyle(palette.accentForeground)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .background(palette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-setapp-tile-recent-apps")

            Text(
                L10n.tr(
                    "折叠 iPhone Duo，即可平铺 Mac 上最近使用的应用。",
                    "Tile recent apps on your Mac by folding iPhone Duo.",
                    language: lang
                )
            )
            .font(ChocType.micro)
            .foregroundStyle(palette.secondaryText)
        }
    }

    // MARK: - App Time Travel (Up to 20 Names, Max 5 Pins)

    private var timeTravelCard: some View {
        let book = activeTimeTravelBook
        let visibleEntries = Array(book.entries.prefix(AppTimeTravelBook.maxRecentApps))
        let isPinLimitReached = !book.canPinMore

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(ChocType.body)
                    .foregroundStyle(palette.accent)
                Text("App Time Travel")
                    .font(ChocType.title)
                    .foregroundStyle(palette.primaryText)
                Text("\(book.pinnedCount)/\(AppTimeTravelBook.maxPins)")
                    .font(ChocType.micro.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.tileFillBottom, in: Capsule())
                Spacer(minLength: 0)
            }

            if isPinLimitReached {
                HStack(spacing: 6) {
                    Image(systemName: "pin.slash.fill")
                        .font(ChocType.micro)
                        .foregroundStyle(palette.accentEmphasis)
                    Text("最多只能固定 5 个 App")
                        .font(ChocType.caption)
                        .foregroundStyle(palette.primaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                )
                .accessibilityIdentifier("ios-setapp-pin-limit-message")
            }

            if visibleEntries.isEmpty {
                Text(
                    L10n.tr(
                        "切换到其他 App 以建立此列表。重新启动 choclift 后，保存的固定项和记录会显示在这里。",
                        "Switch to other apps to build this list. Saved pins and history appear here after you restart choclift.",
                        language: lang
                    )
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { idx, entry in
                        let isLatestUsed = book.latestUsedBundleID?.caseInsensitiveCompare(entry.bundleID) == .orderedSame
                        timeTravelRow(
                            entry: entry,
                            isLatestUsed: isLatestUsed,
                            isPinLimitReached: isPinLimitReached
                        )
                        if idx < visibleEntries.count - 1 {
                            Divider().overlay(palette.subtleCardStroke)
                        }
                    }
                }
                .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("ios-setapp-time-travel-section")
    }

    private func timeTravelRow(
        entry: AppTimeTravelEntry,
        isLatestUsed: Bool,
        isPinLimitReached: Bool
    ) -> some View {
        let iconData = client.cachedAppIconData(forBundleIdentifier: entry.bundleID)
            ?? BundledAppIcons.pngData(for: entry.bundleID)
        let shouldDisablePinButton = !entry.isPinned && isPinLimitReached

        return HStack(spacing: 10) {
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                _ = client.activateMacApp(bundleIdentifier: entry.bundleID)
            } label: {
                HStack(spacing: 10) {
                    DataImageView(pngData: iconData, fallbackSymbol: "app.fill", tint: palette.primaryText)
                        .frame(width: 24, height: 24)
                    Text(entry.appName)
                        .font(ChocType.body)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    if isLatestUsed {
                        Text(AppTimeTravelBook.latestUsedBadgeTitle(in: lang))
                            .font(ChocType.micro)
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(palette.accent.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if entry.isPinned {
                    Button {
                        togglePin(for: entry)
                    } label: {
                        Label(
                            AppTimeTravelBook.unpinReturnToRecentOrderTitle(in: lang),
                            systemImage: "pin.slash"
                        )
                    }
                } else {
                    Button {
                        togglePin(for: entry)
                    } label: {
                        Label(
                            L10n.tr(
                                "在下一个可用槽位固定此 App",
                                "Pin this app in the next available slot",
                                language: lang
                            ),
                            systemImage: "pin"
                        )
                    }
                    .disabled(shouldDisablePinButton)
                }
            }

            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                togglePin(for: entry)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .font(ChocType.caption)
                    Text(
                        entry.isPinned
                            ? L10n.tr("取消固定", "Unpin", language: lang)
                            : L10n.tr("固定", "Pin", language: lang)
                    )
                    .font(ChocType.micro)
                }
                .foregroundStyle(
                    shouldDisablePinButton
                        ? palette.secondaryText.opacity(0.45)
                        : (entry.isPinned ? palette.accentForeground : palette.accent)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    entry.isPinned ? palette.accent : palette.tileFillBottom,
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            entry.isPinned ? palette.accent : palette.subtleCardStroke,
                            lineWidth: 1
                        )
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(shouldDisablePinButton)
            .accessibilityLabel(
                entry.isPinned
                    ? L10n.tr("取消固定 App", "Unpin app", language: lang)
                    : (shouldDisablePinButton ? "最多只能固定 5 个 App" : L10n.tr("固定 App", "Pin app", language: lang))
            )
            .accessibilityIdentifier("ios-setapp-pin-\(entry.bundleID)")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
    }

    // MARK: - Read-Only Gesture Help Captions (No New Detector / Recognizer)

    private var gestureCaptionsCard: some View {
        let windowEntries = SetappGestureMap.allCombinations.filter {
            $0.effect == .minimizeApp || $0.effect == .maximizeApp
        }
        let clipboardEntries = SetappGestureMap.allCombinations.filter {
            $0.effect == .copySelection || $0.effect == .pasteClipboard
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.draw.fill")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.accent)
                Text(L10n.tr(SetappGestureMap.headerTitleZh, SetappGestureMap.headerTitleEn, language: lang))
                    .font(ChocType.title)
                    .foregroundStyle(palette.primaryText)
            }

            Text(L10n.tr(SetappGestureMap.windowSectionTitleZh, SetappGestureMap.windowSectionTitleEn, language: lang))
                .font(ChocType.caption)
                .foregroundStyle(palette.primaryText)
                .padding(.top, 2)

            ForEach(windowEntries) { item in
                gestureCaptionRow(item)
            }

            Text(L10n.tr(SetappGestureMap.clipboardSectionTitleZh, SetappGestureMap.clipboardSectionTitleEn, language: lang))
                .font(ChocType.caption)
                .foregroundStyle(palette.primaryText)
                .padding(.top, 4)

            ForEach(clipboardEntries) { item in
                gestureCaptionRow(item)
            }

            Text(L10n.tr(SetappGestureMap.comingSoonTitleZh, SetappGestureMap.comingSoonTitleEn, language: lang))
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)
                .padding(.top, 2)

            Text(L10n.tr(SetappGestureMap.accessibilityNoticeZh, SetappGestureMap.accessibilityNoticeEn, language: lang))
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("ios-setapp-gesture-captions")
    }

    private func gestureCaptionRow(_ item: SetappGestureEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.direction == .down ? "arrow.down.circle" : "arrow.up.circle")
                .font(ChocType.caption)
                .foregroundStyle(palette.accent)
                .frame(width: 18)
            Text(item.title(in: lang))
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions & Sync

    private func setPageLayout(_ layout: SetappBarTileLayout, forPage pageIndex: Int) {
        if let externalBarBook {
            var next = externalBarBook.wrappedValue
            _ = next.setLayout(layout, forPage: pageIndex)
            externalBarBook.wrappedValue = next
            return
        }
        localLayoutByPage[pageIndex] = layout
        if var overrideBook = localBarBookOverride {
            _ = overrideBook.setLayout(layout, forPage: pageIndex)
            localBarBookOverride = overrideBook
        }
    }

    private func removeTile(pageIndex: Int, slotIndex: Int) {
        CompanionHaptics.notify(enabled: client.profile.settings.hapticFeedbackEnabled, type: .warning)
        if let externalBarBook {
            var next = externalBarBook.wrappedValue
            _ = next.clearSlot(page: pageIndex, slot: slotIndex)
            externalBarBook.wrappedValue = next
            return
        }
        var nextBook = activeBarBook
        _ = nextBook.clearSlot(page: pageIndex, slot: slotIndex)
        localBarBookOverride = nextBook

        if client.profile.pages.indices.contains(pageIndex),
           client.profile.pages[pageIndex].slots.indices.contains(slotIndex) {
            var updatedProfile = client.profile
            if updatedProfile.setSlotItem(nil, pageIndex: pageIndex, slotIndex: slotIndex) {
                client.pushUpdatedProfile(updatedProfile)
            }
        }
    }

    private func activateFilledSlot(_ slot: SetappBarSlot) {
        switch slot.kind {
        case .app:
            if let bundleID = slot.bundleID {
                _ = client.activateMacApp(bundleIdentifier: bundleID)
            }
        case .shortcut:
            guard let name = slot.shortcutName else { return }
            let item = BarItem(
                kind: .shortcut(
                    shortcutName: name,
                    emoji: slot.emoji ?? "⚡️",
                    backgroundHex: "#F3EEFF"
                )
            )
            triggerOrReportOffline(item: item, title: name)
        case .website:
            guard let url = slot.url else { return }
            let host = tileLabel(for: slot)
            let item = BarItem(
                kind: .website(
                    url: url.absoluteString,
                    title: host,
                    emoji: "🌐",
                    backgroundHex: "#FFF1EC",
                    switchExistingTab: true
                )
            )
            triggerOrReportOffline(item: item, title: host)
        case .emoji:
            guard let emoji = slot.emoji else { return }
            if client.connectionState.isConnected {
                client.insertEmoji(emoji)
            } else {
                client.lastFeedback = CompanionFeedbackToast(
                    success: false,
                    title: emoji,
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
            }
        case .empty:
            break
        }
    }

    private func triggerOrReportOffline(item: BarItem, title: String) {
        if client.connectionState.isConnected {
            client.triggerBarItem(item)
        } else {
            client.lastFeedback = CompanionFeedbackToast(
                success: false,
                title: title,
                detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
            )
        }
    }

    private func togglePin(for entry: AppTimeTravelEntry) {
        if let externalTimeTravelBook {
            var next = externalTimeTravelBook.wrappedValue
            if entry.isPinned {
                _ = next.unpin(entry.bundleID)
            } else {
                _ = next.pin(entry.bundleID, appName: entry.appName)
            }
            externalTimeTravelBook.wrappedValue = next
            return
        }

        var current = activeTimeTravelBook
        if entry.isPinned {
            _ = current.unpin(entry.bundleID)
        } else {
            guard case .success = current.pin(entry.bundleID, appName: entry.appName) else {
                return
            }
        }
        let updatedPins = current.pinnedEntries.map(\.bundleID)
        localPinnedBundleIDsOverride = updatedPins

        if client.connectionState.isConnected {
            let matchingRecent = client.recentApps.first {
                $0.bundleIdentifier.caseInsensitiveCompare(entry.bundleID) == .orderedSame
            } ?? RecentAppEntry(
                bundleIdentifier: entry.bundleID,
                appName: entry.appName,
                isPinned: entry.isPinned
            )
            client.togglePinRecentApp(matchingRecent)
        } else {
            var updatedProfile = client.profile
            updatedProfile.pinnedTimeTravelBundleIDs = updatedPins
            client.profile = updatedProfile
        }
    }

    // MARK: - Profile Builders

    private static func makeBarBook(
        from profile: ChocliftWorkspaceProfile,
        layoutOverrides: [Int: SetappBarTileLayout]
    ) -> SetappBarBook {
        var builtPages: [SetappBarPage] = []
        builtPages.reserveCapacity(SetappBarBook.pageCount)

        for pageIdx in 0..<SetappBarBook.pageCount {
            let sourceSlots: [BarItem?] = profile.pages.indices.contains(pageIdx)
                ? Array(profile.pages[pageIdx].slots.prefix(SetappBarTileLayout.four.slotCount))
                : []
            let mappedSlots = sourceSlots.map { mapBarItemToSetappSlot($0) }
            let nonEmptyCount = mappedSlots.filter { !$0.isEmpty }.count
            let defaultLayout: SetappBarTileLayout = {
                switch nonEmptyCount {
                case 4...: return .four
                case 3: return .three
                case 2: return .two
                default: return .one
                }
            }()
            let resolvedLayout = layoutOverrides[pageIdx] ?? defaultLayout
            builtPages.append(
                SetappBarPage(
                    index: pageIdx,
                    layout: resolvedLayout,
                    slots: mappedSlots
                )
            )
        }
        return SetappBarBook(pages: builtPages)
    }

    private static func mapBarItemToSetappSlot(_ item: BarItem?) -> SetappBarSlot {
        guard let item else { return .empty }
        switch item.kind {
        case .macApp(let bundleID, let appName, _, _):
            return SetappBarSlot.app(bundleID: bundleID, displayName: appName) ?? .empty
        case .shortcut(let shortcutName, let emoji, _):
            return SetappBarSlot.shortcut(
                shortcutName: shortcutName,
                emoji: emoji,
                displayName: shortcutName
            ) ?? .empty
        case .website(let url, let title, _, _, _):
            return SetappBarSlot.website(urlString: url, displayName: title) ?? .empty
        case .snippet(_, _, let emoji, _):
            return SetappBarSlot.emoji(emoji) ?? .empty
        default:
            return .empty
        }
    }

    private static func makeTimeTravelBook(
        profile: ChocliftWorkspaceProfile,
        recentApps: [RecentAppEntry],
        catalogApps: [InstalledAppSummary],
        pinnedOverride: [String]?
    ) -> AppTimeTravelBook {
        let rawPinned = pinnedOverride ?? profile.pinnedTimeTravelBundleIDs
        var entries: [AppTimeTravelEntry] = []
        var pinSlot = 0

        for bundleID in rawPinned {
            guard pinSlot < AppTimeTravelBook.maxPins,
                  !AppTimeTravelBook.isChocliftBundleIdentifier(bundleID) else {
                continue
            }
            let matchingRecent = recentApps.first {
                $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
            }
            let name = profile.resolvedAppDisplayName(
                forBundleIdentifier: bundleID,
                preferredAppName: matchingRecent?.appName,
                recentApps: recentApps,
                catalogApps: catalogApps
            )
            entries.append(
                AppTimeTravelEntry(
                    bundleID: bundleID,
                    appName: name,
                    lastUsedAt: matchingRecent?.lastActivatedAt ?? Date(timeIntervalSince1970: 0),
                    pinnedIndex: pinSlot
                )
            )
            pinSlot += 1
        }

        for recent in recentApps {
            guard !AppTimeTravelBook.isChocliftBundleIdentifier(recent.bundleIdentifier) else {
                continue
            }
            let alreadyPinned = entries.contains {
                $0.bundleID.caseInsensitiveCompare(recent.bundleIdentifier) == .orderedSame
            }
            if !alreadyPinned {
                entries.append(
                    AppTimeTravelEntry(
                        bundleID: recent.bundleIdentifier,
                        appName: recent.appName,
                        lastUsedAt: recent.lastActivatedAt,
                        pinnedIndex: nil
                    )
                )
            }
        }

        return AppTimeTravelBook(entries: entries)
    }
}
