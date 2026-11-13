import ChocliftCore
import SwiftUI

// MARK: - 1. Hold-to-Repeat Button Styles (Volume Up, Volume Down, Media Next Only; >= 400 ms)

public struct IOSRepeatableQuickActionButtonStyle: ButtonStyle {
    @Binding var pressedKey: String?
    let key: String
    let action: SystemQuickAction
    let onFire: () -> Void
    @Binding var suppressReleaseKey: String?

    public init(
        pressedKey: Binding<String?>,
        key: String,
        action: SystemQuickAction,
        suppressReleaseKey: Binding<String?>,
        onFire: @escaping () -> Void
    ) {
        self._pressedKey = pressedKey
        self.key = key
        self.action = action
        self._suppressReleaseKey = suppressReleaseKey
        self.onFire = onFire
    }

    public func makeBody(configuration: Configuration) -> some View {
        IOSRepeatableQuickActionLabel(
            configuration: configuration,
            pressedKey: $pressedKey,
            key: key,
            action: action,
            suppressReleaseKey: $suppressReleaseKey,
            onFire: onFire
        )
    }
}

private struct IOSRepeatableQuickActionLabel: View {
    let configuration: ButtonStyle.Configuration
    @Binding var pressedKey: String?
    let key: String
    let action: SystemQuickAction
    @Binding var suppressReleaseKey: String?
    let onFire: () -> Void

    var body: some View {
        let canRepeat = HoldToRepeatPolicy.supportsHoldToRepeat(action)
        let isHolding = configuration.isPressed && canRepeat

        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    ChocPressFeedback.beginPress(key: key, pressedKey: $pressedKey)
                } else {
                    let keySnapshot = key
                    let binding = $pressedKey
                    DispatchQueue.main.async {
                        if !ChocPressFeedback.hasActiveHold(for: keySnapshot) {
                            ChocPressFeedback.cancelPressImmediately(key: keySnapshot, pressedKey: binding)
                        }
                    }
                }
            }
            .task(id: isHolding) {
                guard isHolding else { return }
                // Short stationary slop so quick taps still run via Button.action on release.
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled, configuration.isPressed else { return }

                var repeatController = HoldToRepeatController()
                let startedAt = ProcessInfo.processInfo.systemUptime
                guard repeatController.beginHold(for: action, at: startedAt) else { return }
                suppressReleaseKey = key
                onFire()

                while !Task.isCancelled && configuration.isPressed {
                    try? await Task.sleep(for: .milliseconds(40))
                    guard !Task.isCancelled, configuration.isPressed else {
                        repeatController.endHold()
                        return
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    if repeatController.shouldFireRepeat(at: now) {
                        onFire()
                    }
                }
                repeatController.endHold()
            }
            .onDisappear {
                ChocPressFeedback.cancelPressImmediately(key: key, pressedKey: $pressedKey)
            }
    }
}

// MARK: - 2. Tile Folders Sheet & Folder Slot Editor (1 Folder Per Page, Up to 8 Child Actions)

public struct IOSTileFolderSelection: Identifiable, Equatable {
    public let pageIndex: Int
    public let slotIndex: Int
    public var id: String { "folder-\(pageIndex)-\(slotIndex)" }

    public init(pageIndex: Int, slotIndex: Int) {
        self.pageIndex = pageIndex
        self.slotIndex = slotIndex
    }
}

public struct IOSTileFolderSheet: View {
    @ObservedObject var client: CompanionClientEngine
    let pageIndex: Int
    let slotIndex: Int
    var onPromptHUD: ((String) -> Void)?
    let onEditFolderSlot: (IOSEditSlotSelection) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var pressedChildKey: String?
    @State private var suppressedRepeatChildKey: String?
    @State private var confirmGate = DestructiveActionConfirmGate()

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        pageIndex: Int,
        slotIndex: Int,
        onPromptHUD: ((String) -> Void)? = nil,
        onEditFolderSlot: @escaping (IOSEditSlotSelection) -> Void
    ) {
        self.client = client
        self.pageIndex = pageIndex
        self.slotIndex = slotIndex
        self.onPromptHUD = onPromptHUD
        self.onEditFolderSlot = onEditFolderSlot
    }

    private var folderContext: (page: BarPage, folder: TileFolder, origin: SlotCoordinate)? {
        guard client.profile.pages.indices.contains(pageIndex) else { return nil }
        let page = client.profile.pages[pageIndex]
        guard page.slots.indices.contains(slotIndex),
              case .folder(let folder) = page.slots[slotIndex]?.kind else {
            return nil
        }
        return (page, folder, SlotCoordinate(pageID: page.id, slotIndex: slotIndex))
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if let ctx = folderContext {
                    TimelineView(.periodic(from: .now, by: 15.0)) { timeline in
                        folderBodyContent(ctx: ctx, now: timeline.date)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(palette.secondaryText)
                        Text(L10n.tr("该文件夹已移除", "Folder Removed", language: lang))
                            .font(.headline)
                            .foregroundStyle(palette.primaryText)
                    }
                }
            }
            .navigationTitle(
                folderContext.map { "\($0.folder.emoji) \($0.folder.displayTitle(in: lang))" }
                    ?? L10n.tr("文件夹", "Folder", language: lang)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("关闭", "Done", language: lang)) {
                        dismiss()
                    }
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityIdentifier("ios-folder-done-button")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let target = IOSEditSlotSelection(pageIndex: pageIndex, slotIndex: slotIndex)
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            onEditFolderSlot(target)
                        }
                    } label: {
                        Label(L10n.tr("编辑文件夹", "Edit Folder", language: lang), systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(palette.accent)
                    .accessibilityIdentifier("ios-folder-edit-button")
                }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios-folder-sheet")
    }

    @ViewBuilder
    private func folderBodyContent(
        ctx: (page: BarPage, folder: TileFolder, origin: SlotCoordinate),
        now: Date
    ) -> some View {
        let children = Array(ctx.folder.children.prefix(TileFolder.maxChildren))

        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Label(
                    L10n.tr(
                        "子动作 \(children.count)/\(TileFolder.maxChildren)",
                        "\(children.count)/\(TileFolder.maxChildren) Actions",
                        language: lang
                    ),
                    systemImage: "square.grid.2x2.fill"
                )
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(palette.accent.opacity(0.12), in: Capsule())
                .accessibilityIdentifier("ios-folder-sheet-count")

                Spacer()

                Text(
                    L10n.tr(
                        "点按子动作直接运行 · 不占用 8 页上限",
                        "Tap an action to run · Keeps 8-page limit",
                        language: lang
                    )
                )
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if children.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 12)
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text(L10n.tr("文件夹暂为空", "This Folder Is Empty", language: lang))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Text(
                        L10n.tr(
                            "最多可添加 8 个子动作（应用、系统动作、快捷指令、动作流或音效）。",
                            "Add up to 8 child actions (apps, system actions, shortcuts, flows, or sounds).",
                            language: lang
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                    Button {
                        let target = IOSEditSlotSelection(pageIndex: pageIndex, slotIndex: slotIndex)
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            onEditFolderSlot(target)
                        }
                    } label: {
                        Label(L10n.tr("添加子动作", "Add Actions", language: lang), systemImage: "plus")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(palette.accentForeground)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(palette.accent, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios-folder-empty-add-button")
                    Spacer(minLength: 12)
                }
            } else {
                ScrollView {
                    let cols = [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ]
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(Array(children.enumerated()), id: \.element.id) { childIdx, child in
                            folderChildButton(
                                child: child,
                                childIndex: childIdx,
                                folderOrigin: ctx.origin,
                                now: now
                            )
                            .frame(height: 92)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func folderChildButton(
        child: BarItem,
        childIndex: Int,
        folderOrigin: SlotCoordinate,
        now: Date
    ) -> some View {
        let key = "folder-child-\(child.id.uuidString)"
        let isPressed = (pressedChildKey == key)
        let isAwaitingConfirm = confirmGate.isArmed(
            targetID: key,
            at: ProcessInfo.processInfo.systemUptime
        )
        let iconData = child.bundleIdentifier.flatMap {
            client.appIconsByBundleID[$0] ?? BundledAppIcons.pngData(for: $0)
        }
        let isFrontmost = (child.bundleIdentifier != nil && child.bundleIdentifier == client.frontmostBundleID)
        let lastTriggered = client.lastTriggeredText(for: child, now: now)
        let resolvedTitle = client.profile.displayTitle(for: child, in: lang)

        if case .systemAction(let action, _, _) = child.kind,
           HoldToRepeatPolicy.supportsHoldToRepeat(action) {
            Button {
                if suppressedRepeatChildKey == key {
                    suppressedRepeatChildKey = nil
                    return
                }
                ChocPressFeedback.completeTap(key: key, pressedKey: $pressedChildKey)
                fireChildImmediately(child: child, folderOrigin: folderOrigin, resolvedTitle: resolvedTitle)
            } label: {
                ChocBarTileCard(
                    item: child,
                    iconData: iconData,
                    isFrontmostApp: isFrontmost,
                    isPressed: isPressed,
                    isAwaitingConfirmation: false,
                    lastRunOutcome: nil,
                    palette: palette,
                    language: lang,
                    compact: true,
                    profile: client.profile,
                    slotOrigin: folderOrigin,
                    lastTriggeredText: lastTriggered,
                    iconLookup: { bundleID in
                        client.appIconsByBundleID[bundleID] ?? BundledAppIcons.pngData(for: bundleID)
                    }
                )
                .scaleEffect(isPressed ? 0.94 : 1.0)
            }
            .buttonStyle(
                IOSRepeatableQuickActionButtonStyle(
                    pressedKey: $pressedChildKey,
                    key: key,
                    action: action,
                    suppressReleaseKey: $suppressedRepeatChildKey
                ) {
                    fireChildImmediately(child: child, folderOrigin: folderOrigin, resolvedTitle: resolvedTitle)
                }
            )
            .accessibilityIdentifier("ios-folder-child-\(childIndex)")
            .accessibilityLabel(resolvedTitle)
        } else {
            Button {
                ChocPressFeedback.completeTap(key: key, pressedKey: $pressedChildKey)
                handleFolderChildTap(
                    child: child,
                    key: key,
                    folderOrigin: folderOrigin,
                    resolvedTitle: resolvedTitle
                )
            } label: {
                ChocBarTileCard(
                    item: child,
                    iconData: iconData,
                    isFrontmostApp: isFrontmost,
                    isPressed: isPressed,
                    isAwaitingConfirmation: isAwaitingConfirm,
                    lastRunOutcome: nil,
                    palette: palette,
                    language: lang,
                    compact: true,
                    profile: client.profile,
                    slotOrigin: folderOrigin,
                    lastTriggeredText: lastTriggered,
                    iconLookup: { bundleID in
                        client.appIconsByBundleID[bundleID] ?? BundledAppIcons.pngData(for: bundleID)
                    }
                )
                .scaleEffect(isPressed ? 0.94 : 1.0)
            }
            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedChildKey, key: key))
            .accessibilityIdentifier("ios-folder-child-\(childIndex)")
            .accessibilityLabel(resolvedTitle)
        }
    }

    private func handleFolderChildTap(
        child: BarItem,
        key: String,
        folderOrigin: SlotCoordinate,
        resolvedTitle: String
    ) {
        let isDestructive = child.requiresDestructiveConfirmation(in: client.profile, from: folderOrigin)
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
            fireChildImmediately(child: child, folderOrigin: folderOrigin, resolvedTitle: resolvedTitle)
            dismiss()
        }
    }

    private func fireChildImmediately(
        child: BarItem,
        folderOrigin: SlotCoordinate,
        resolvedTitle: String
    ) {
        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
        if client.connectionState.isConnected {
            client.triggerBarItem(child, from: folderOrigin)
        } else {
            client.recordOfflineTileFailure(
                slot: folderOrigin,
                title: resolvedTitle,
                detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
            )
        }
    }
}

// MARK: - 3. iOS Folder Slot Editor Tab (Used Inside IOSSlotEditorSheet)

public struct IOSFolderSlotEditorView: View {
    @ObservedObject var client: CompanionClientEngine
    let pageIndex: Int
    let slotIndex: Int
    var onJumpToExistingFolder: ((Int) -> Void)?
    let onSaveFolder: (TileFolder) -> Void

    @State private var folderTitle: String = ""
    @State private var folderEmoji: String = TileFolder.defaultEmoji
    @State private var folderHex: String = TileFolder.defaultBackgroundHex
    @State private var children: [BarItem] = []
    @State private var showAddChildSheet: Bool = false
    @State private var didHydrate: Bool = false

    private static let presetEmojis: [String] = ["📁", "🗂️", "🎛️", "🎬", "🎧", "🛠️", "🚀", "⭐️"]

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        pageIndex: Int,
        slotIndex: Int,
        onJumpToExistingFolder: ((Int) -> Void)? = nil,
        onSaveFolder: @escaping (TileFolder) -> Void
    ) {
        self.client = client
        self.pageIndex = pageIndex
        self.slotIndex = slotIndex
        self.onJumpToExistingFolder = onJumpToExistingFolder
        self.onSaveFolder = onSaveFolder
    }

    private var existingFolderIndexOnPage: Int? {
        guard client.profile.pages.indices.contains(pageIndex) else { return nil }
        return client.profile.pages[pageIndex].folderSlotIndex
    }

    private var canPlaceFolderHere: Bool {
        guard client.profile.pages.indices.contains(pageIndex) else { return false }
        return client.profile.pages[pageIndex].canPlaceFolder(at: slotIndex)
    }

    public var body: some View {
        Group {
            if !canPlaceFolderHere, let existingIdx = existingFolderIndexOnPage {
                VStack(spacing: 12) {
                    Spacer(minLength: 16)
                    Image(systemName: "folder.badge.exclamationmark")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text(L10n.tr("每页最多 1 个文件夹", "One Folder Per Page", language: lang))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Text(
                        L10n.tr(
                            "本页槽位 #\(existingIdx + 1) 已有文件夹磁贴。文件夹最多容纳 8 个子动作，不增加新页面。",
                            "Slot #\(existingIdx + 1) on this page already holds a folder (up to 8 child actions, no extra page).",
                            language: lang
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                    if let onJumpToExistingFolder {
                        Button {
                            onJumpToExistingFolder(existingIdx)
                        } label: {
                            Label(
                                L10n.tr("编辑槽位 #\(existingIdx + 1) 的文件夹", "Edit Folder in Slot #\(existingIdx + 1)", language: lang),
                                systemImage: "folder.fill"
                            )
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(palette.accentForeground)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(palette.accent, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ios-folder-jump-existing")
                    }
                    Spacer(minLength: 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        folderAppearanceCard
                        folderChildrenCard
                        saveFolderButton
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            hydrateIfNeeded()
        }
        .sheet(isPresented: $showAddChildSheet) {
            IOSFolderChildPickerSheet(client: client) { childItem in
                guard children.count < TileFolder.maxChildren else { return }
                children.append(childItem)
            }
        }
    }

    private var folderAppearanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("文件夹外观", "Folder Appearance", language: lang))
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(palette.secondaryText)

            TextField(
                L10n.tr("文件夹标题（如：快捷工具）", "Folder Title (e.g. Quick Tools)", language: lang),
                text: $folderTitle
            )
            .textFieldStyle(.plain)
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
            .accessibilityIdentifier("ios-folder-title-field")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Self.presetEmojis, id: \.self) { emoji in
                        let selected = (folderEmoji == emoji)
                        Button {
                            folderEmoji = emoji
                        } label: {
                            Text(emoji)
                                .font(.system(size: 19))
                                .frame(width: 38, height: 38)
                                .background(
                                    selected ? palette.accent.opacity(0.16) : palette.tileFillBottom,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(selected ? palette.accent : palette.subtleCardStroke, lineWidth: selected ? 1.6 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ChocSwatch.tileColors, id: \.self) { hex in
                        let isSelected = (folderHex.caseInsensitiveCompare(hex) == .orderedSame)
                        Button {
                            folderHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            isSelected ? palette.accent : palette.subtleCardStroke,
                                            lineWidth: isSelected ? 2.2 : 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var folderChildrenCard: some View {
        let isFull = children.count >= TileFolder.maxChildren

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(
                    L10n.tr(
                        "子动作（\(children.count)/\(TileFolder.maxChildren)）",
                        "Child Actions (\(children.count)/\(TileFolder.maxChildren))",
                        language: lang
                    )
                )
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .accessibilityIdentifier("ios-folder-count-badge")

                Spacer()

                Button {
                    showAddChildSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(
                            isFull
                                ? L10n.tr("已满 8/8", "Full 8/8", language: lang)
                                : L10n.tr("添加动作", "Add Action", language: lang)
                        )
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(isFull ? palette.secondaryText : palette.accentForeground)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(isFull ? palette.tileFillBottom : palette.accent, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isFull)
                .accessibilityIdentifier("ios-folder-add-child-button")
            }

            if children.isEmpty {
                Text(
                    L10n.tr(
                        "可先保存空文件夹，或立即添加最多 8 个子动作。",
                        "Save now or add up to 8 child actions right away.",
                        language: lang
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 7) {
                    ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                        HStack(spacing: 8) {
                            Text("#\(idx + 1)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 22, alignment: .leading)

                            Text(client.profile.displayTitle(for: child, in: lang))
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)

                            Spacer()

                            Button {
                                guard idx > 0 else { return }
                                children.swapAt(idx, idx - 1)
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(idx > 0 ? palette.primaryText : palette.secondaryText.opacity(0.35))
                                    .frame(width: 28, height: 28)
                                    .background(palette.tileFillBottom, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(idx == 0)

                            Button {
                                guard idx + 1 < children.count else { return }
                                children.swapAt(idx, idx + 1)
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(idx + 1 < children.count ? palette.primaryText : palette.secondaryText.opacity(0.35))
                                    .frame(width: 28, height: 28)
                                    .background(palette.tileFillBottom, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(idx + 1 >= children.count)

                            Button {
                                children.remove(at: idx)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundStyle(palette.statusFailure)
                                    .frame(width: 30, height: 30)
                                    .background(palette.statusFailure.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ios-folder-child-remove-\(idx)")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var saveFolderButton: some View {
        Button {
            let folder = TileFolder(
                title: folderTitle,
                emoji: folderEmoji,
                backgroundHex: folderHex,
                children: children
            )
            onSaveFolder(folder)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill.badge.plus")
                    .font(.system(size: 14, weight: .bold))
                Text(L10n.tr("保存文件夹磁贴", "Save Folder Tile", language: lang))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
            }
            .foregroundStyle(palette.accentForeground)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-folder-save-button")
    }

    private func hydrateIfNeeded() {
        guard !didHydrate else { return }
        didHydrate = true
        guard client.profile.pages.indices.contains(pageIndex),
              client.profile.pages[pageIndex].slots.indices.contains(slotIndex),
              case .folder(let existing) = client.profile.pages[pageIndex].slots[slotIndex]?.kind else {
            return
        }
        folderTitle = existing.title
        folderEmoji = existing.emoji
        folderHex = existing.backgroundHex
        children = existing.children
    }
}

private struct IOSFolderChildPickerSheet: View {
    enum SourceSegment: String, CaseIterable, Identifiable {
        case actions
        case apps
        case flows
        case sounds
        case shortcuts

        var id: String { rawValue }
    }

    @ObservedObject var client: CompanionClientEngine
    let onPick: (BarItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var segment: SourceSegment = .actions
    @State private var query: String = ""

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("", selection: $segment) {
                    Text(L10n.tr("系统动作", "Actions", language: lang)).tag(SourceSegment.actions)
                    Text(L10n.tr("应用", "Apps", language: lang)).tag(SourceSegment.apps)
                    Text(L10n.tr("动作流", "Flows", language: lang)).tag(SourceSegment.flows)
                    Text(L10n.tr("音效", "Sounds", language: lang)).tag(SourceSegment.sounds)
                    Text(L10n.tr("指令", "Shortcuts", language: lang)).tag(SourceSegment.shortcuts)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.top, 8)

                ScrollView {
                    VStack(spacing: 8) {
                        switch segment {
                        case .actions:
                            ForEach(Array(SystemQuickAction.allCases.enumerated()), id: \.element.id) { idx, action in
                                childChoiceRow(
                                    title: action.title(in: lang),
                                    symbol: action.sfSymbol,
                                    identifier: "ios-folder-pick-action-\(idx)"
                                ) {
                                    onPick(BarItem(kind: .systemAction(action: action)))
                                    dismiss()
                                }
                            }
                        case .apps:
                            ForEach(client.macCatalogApps) { app in
                                childChoiceRow(
                                    title: app.appName,
                                    symbol: "app.fill",
                                    identifier: "ios-folder-pick-app-\(app.bundleIdentifier)"
                                ) {
                                    onPick(
                                        BarItem(
                                            kind: .macApp(
                                                bundleIdentifier: app.bundleIdentifier,
                                                appName: app.appName,
                                                appPath: app.appPath
                                            )
                                        )
                                    )
                                    dismiss()
                                }
                            }
                        case .flows:
                            ForEach(client.profile.flows) { flow in
                                childChoiceRow(
                                    title: "\(flow.emoji) \(flow.name)",
                                    symbol: "arrow.triangle.branch",
                                    identifier: "ios-folder-pick-flow-\(flow.id.uuidString)"
                                ) {
                                    onPick(client.profile.makeBarItem(for: flow))
                                    dismiss()
                                }
                            }
                        case .sounds:
                            ForEach(client.profile.soundboardClips) { clip in
                                childChoiceRow(
                                    title: "\(clip.emoji) \(clip.name)",
                                    symbol: "speaker.wave.2.fill",
                                    identifier: "ios-folder-pick-sound-\(clip.id.uuidString)"
                                ) {
                                    onPick(client.profile.makeBarItem(for: clip))
                                    dismiss()
                                }
                            }
                        case .shortcuts:
                            ForEach(client.macCatalogShortcuts) { sc in
                                childChoiceRow(
                                    title: sc.name,
                                    symbol: "bolt.fill",
                                    identifier: "ios-folder-pick-shortcut-\(sc.name)"
                                ) {
                                    onPick(
                                        BarItem(
                                            kind: .shortcut(
                                                shortcutName: sc.name,
                                                emoji: "⚡️",
                                                backgroundHex: "#FFF6E3"
                                            )
                                        )
                                    )
                                    dismiss()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                }
            }
            .background(
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle(L10n.tr("选择文件夹子动作", "Choose Child Action", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "Cancel", language: lang)) {
                        dismiss()
                    }
                }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
    }

    private func childChoiceRow(
        title: String,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 30, height: 30)
                    .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(palette.accent)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - 4. Phone Page Reorder Controls (Move Page Left / Right — App Bindings Follow Page ID)

public struct IOSPageReorderControls: View {
    @ObservedObject var client: CompanionClientEngine
    let activePageIndex: Int
    let compact: Bool
    let onMove: (PageReorderDirection) -> Void

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        activePageIndex: Int,
        compact: Bool = false,
        onMove: @escaping (PageReorderDirection) -> Void
    ) {
        self.client = client
        self.activePageIndex = activePageIndex
        self.compact = compact
        self.onMove = onMove
    }

    public var body: some View {
        let canLeft = client.canMovePage(at: activePageIndex, direction: .left)
        let canRight = client.canMovePage(at: activePageIndex, direction: .right)

        HStack(spacing: 4) {
            Button {
                guard canLeft else { return }
                onMove(.left)
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.left.to.line")
                        .font(.system(size: compact ? 10 : 10.5, weight: .bold))
                    if !compact {
                        Text(L10n.tr("左移", "Left", language: lang))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(canLeft ? palette.primaryText : palette.secondaryText.opacity(0.38))
                .padding(.horizontal, compact ? 7 : 8)
                .frame(height: compact ? 26 : 28)
                .background(
                    (canLeft ? palette.tileFillTop : palette.barSurface.opacity(0.6)),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 0.9))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canLeft)
            .accessibilityIdentifier("ios-page-move-left")
            .accessibilityLabel(L10n.tr("将当前页向左移动", "Move Current Page Left", language: lang))

            Button {
                guard canRight else { return }
                onMove(.right)
            } label: {
                HStack(spacing: 2) {
                    if !compact {
                        Text(L10n.tr("右移", "Right", language: lang))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    Image(systemName: "arrow.right.to.line")
                        .font(.system(size: compact ? 10 : 10.5, weight: .bold))
                }
                .foregroundStyle(canRight ? palette.primaryText : palette.secondaryText.opacity(0.38))
                .padding(.horizontal, compact ? 7 : 8)
                .frame(height: compact ? 26 : 28)
                .background(
                    (canRight ? palette.tileFillTop : palette.barSurface.opacity(0.6)),
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 0.9))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canRight)
            .accessibilityIdentifier("ios-page-move-right")
            .accessibilityLabel(L10n.tr("将当前页向右移动", "Move Current Page Right", language: lang))
        }
    }
}

// MARK: - 5. Quiet Hours for Haptics (Phone Setting — Mutes Success/Failure Haptics Between Two Local Times, Default Off)

public struct IOSHapticQuietHoursCard: View {
    @ObservedObject var client: CompanionClientEngine

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { client.hapticQuietHours.isEnabled },
            set: { newValue in
                client.setHapticQuietHoursEnabled(newValue)
            }
        )
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { HapticQuietHoursSettings.date(forMinuteOfDay: client.hapticQuietHours.startMinuteOfDay) },
            set: { newDate in
                let mins = HapticQuietHoursSettings.minuteOfDay(from: newDate)
                client.setHapticQuietHoursWindow(
                    startMinuteOfDay: mins,
                    endMinuteOfDay: client.hapticQuietHours.endMinuteOfDay
                )
            }
        )
    }

    private var endDateBinding: Binding<Date> {
        Binding(
            get: { HapticQuietHoursSettings.date(forMinuteOfDay: client.hapticQuietHours.endMinuteOfDay) },
            set: { newDate in
                let mins = HapticQuietHoursSettings.minuteOfDay(from: newDate)
                client.setHapticQuietHoursWindow(
                    startMinuteOfDay: client.hapticQuietHours.startMinuteOfDay,
                    endMinuteOfDay: mins
                )
            }
        )
    }

    public var body: some View {
        let isQuietNow = client.isHapticQuietTime()

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: client.hapticQuietHours.isEnabled ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 32, height: 32)
                    .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("震动免打扰时段", "Haptic Quiet Hours", language: lang))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)

                    Text(
                        L10n.tr(
                            "在设定时段内静音成功与失败震动，Mac 动作照常执行。",
                            "Mutes success & failure haptics between two local times. Mac actions still run.",
                            language: lang
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                }

                Spacer()

                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .tint(palette.accent)
                    .accessibilityIdentifier("ios-quiet-hours-toggle")
            }

            if client.hapticQuietHours.isEnabled {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("开始时间", "Start Time", language: lang))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                        DatePicker(
                            "",
                            selection: startDateBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .accessibilityIdentifier("ios-quiet-hours-start")
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("结束时间", "End Time", language: lang))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                        DatePicker(
                            "",
                            selection: endDateBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .accessibilityIdentifier("ios-quiet-hours-end")
                    }
                }
                .padding(.top, 2)

                HStack(spacing: 6) {
                    Circle()
                        .fill(isQuietNow ? palette.accent : palette.statusConnected)
                        .frame(width: 7, height: 7)
                    Text(
                        isQuietNow
                            ? L10n.tr(
                                "当前处于免打扰时段（\(client.hapticQuietHours.formattedTimeRange)）· 结果震动已静音",
                                "Quiet now (\(client.hapticQuietHours.formattedTimeRange)) · Outcome haptics muted",
                                language: lang
                            )
                            : L10n.tr(
                                "生效时段：\(client.hapticQuietHours.formattedTimeRange)（本地时间）",
                                "Active daily \(client.hapticQuietHours.formattedTimeRange) local time",
                                language: lang
                            )
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
                }
                .accessibilityIdentifier("ios-quiet-hours-status")
            }
        }
        .padding(14)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios-quiet-hours-card")
    }
}
