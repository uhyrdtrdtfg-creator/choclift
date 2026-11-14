import ChocliftCore
import SwiftUI

public struct IOSSlotEditorSheet: View {
    public enum EditorTab: String, CaseIterable, Identifiable {
        case apps
        case folder
        case actions
        case flows
        case sounds
        case reference
        case shortcuts
        case website

        public var id: String { rawValue }

        public var sfSymbol: String {
            switch self {
            case .apps: return "app.badge"
            case .flows: return "arrow.triangle.branch"
            case .sounds: return "speaker.wave.2.bubble.left.fill"
            case .reference: return "arrow.turn.up.right"
            case .shortcuts: return "bolt.fill"
            case .website: return "globe"
            case .actions: return "command.square.fill"
            case .folder: return "folder.fill"
            }
        }

        public func title(in lang: AppLanguage) -> String {
            switch self {
            case .apps: return L10n.tr("应用", "Apps", language: lang)
            case .flows: return L10n.tr("动作流", "Flows", language: lang)
            case .sounds: return L10n.tr("音效", "Sounds", language: lang)
            case .reference: return L10n.tr("引用", "Reference", language: lang)
            case .shortcuts: return L10n.tr("指令", "Shortcuts", language: lang)
            case .website: return L10n.tr("网页", "Web", language: lang)
            case .actions: return L10n.tr("动作", "Actions", language: lang)
            case .folder: return L10n.tr("文件夹", "Folder", language: lang)
            }
        }
    }

    @ObservedObject var client: CompanionClientEngine
    let pageIndex: Int
    let slotIndex: Int
    var onEditOriginalSlot: ((Int, Int) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var pendingItem: BarItem?
    @State private var pendingFlow: ActionFlow?
    @State private var reviewName = ""
    @State private var reviewIcon = ""
    @State private var removeArmedUntil: Date?
    @State private var tab: EditorTab = .apps
    @State private var searchQuery: String = ""
    @State private var soundSearchQuery: String = ""
    @State private var isWaitingForCatalog: Bool = false

    @State private var shortcutName: String = ""
    @State private var shortcutEmoji: String = "⚡️"
    @State private var shortcutHex: String = "#F3EEFF"

    @State private var webURL: String = "https://"
    @State private var webTitle: String = ""
    @State private var webEmoji: String = "🌐"
    @State private var webHex: String = "#FFF1EC"
    @State private var webSwitchTab: Bool = true

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var currentSlotOrigin: SlotCoordinate? {
        guard client.profile.pages.indices.contains(pageIndex) else { return nil }
        return SlotCoordinate(pageID: client.profile.pages[pageIndex].id, slotIndex: slotIndex)
    }

    private var existingItem: BarItem? {
        guard client.profile.pages.indices.contains(pageIndex),
              client.profile.pages[pageIndex].slots.indices.contains(slotIndex) else {
            return nil
        }
        return client.profile.pages[pageIndex].slots[slotIndex]
    }

    public init(
        client: CompanionClientEngine,
        pageIndex: Int,
        slotIndex: Int,
        onEditOriginalSlot: ((Int, Int) -> Void)? = nil
    ) {
        self.client = client
        self.pageIndex = pageIndex
        self.slotIndex = slotIndex
        self.onEditOriginalSlot = onEditOriginalSlot
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let coord = currentSlotOrigin, let existing = existingItem {
                    pinToStripCallout(coordinate: coord, item: existing)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }

                if let existing = existingItem, existing.isSlotReference {
                    referenceOriginCallout(for: existing)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                }

                editorTabStrip
                    .padding(.vertical, 10)

                Group {
                    switch tab {
                    case .apps:
                        macAppsList
                    case .flows:
                        IOSFlowsSlotTabView(
                            client: client,
                            pageIndex: pageIndex,
                            slotIndex: slotIndex
                        ) { flow in
                            assignFlow(flow)
                        }
                    case .sounds:
                        soundboardClipsPicker
                    case .reference:
                        referenceTargetPicker
                    case .shortcuts:
                        shortcutsForm
                    case .website:
                        websiteForm
                    case .actions:
                        actionsGrid
                    case .folder:
                        IOSFolderSlotEditorView(
                            client: client,
                            pageIndex: pageIndex,
                            slotIndex: slotIndex,
                            onJumpToExistingFolder: { existingFolderIdx in
                                onEditOriginalSlot?(pageIndex, existingFolderIdx)
                            },
                            onSaveFolder: { folder in
                                let item = BarItem(
                                    id: existingItem?.id ?? UUID(),
                                    kind: .folder(folder)
                                )
                                assignItem(item)
                            }
                        )
                    }
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
            .navigationTitle(L10n.tr("编辑槽位 #\(slotIndex + 1)", "Edit Slot #\(slotIndex + 1)", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .sheet(item: $pendingItem) { item in
                NavigationStack {
                    Form {
                        Section(L10n.tr("确认动作", "Review Action", language: lang)) {
                            Text(item.displayTitle(in: lang)).font(ChocType.title)
                            TextField(L10n.tr("名称", "Name", language: lang), text: $reviewName)
                                .disabled({ if case .shortcut = item.kind { return true }; if case .slotReference = item.kind { return true }; return false }())
                            TextField(L10n.tr("图标", "Icon", language: lang), text: $reviewIcon)
                                .disabled({ if case .systemAction = item.kind { return true }; if case .slotReference = item.kind { return true }; return false }())
                        }
                        Button(L10n.tr("确认添加", "Confirm", language: lang)) { commitReviewedItem(item) }
                            .frame(minHeight: 44)
                    }
                    .scrollContentBackground(.hidden).background(palette.backgroundTop)
                    .navigationTitle(L10n.tr("名称与图标", "Name & Icon", language: lang))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.tr("返回", "Back", language: lang)) { pendingItem = nil; pendingFlow = nil }
                        }
                    }
                    .tint(palette.accent)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "Cancel", language: lang)) { dismiss() }
                        .foregroundStyle(palette.secondaryText)
                        .accessibilityIdentifier("ios-slot-editor-cancel")
                }
                if existingItem != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(removeArmedUntil != nil ? L10n.tr("再点确认", "Tap to confirm", language: lang) : L10n.tr("清空", "Clear", language: lang), role: .destructive) {
                            if let until = removeArmedUntil, until > Date() {
                                assignItem(nil)
                            } else {
                                removeArmedUntil = Date().addingTimeInterval(3)
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(3))
                                    removeArmedUntil = nil
                                }
                            }
                        }
                        .foregroundStyle(palette.statusFailure)
                        .accessibilityIdentifier("ios-slot-editor-clear")
                    }
                }
            }
            .onAppear {
                hydrateExisting()
                requestCatalogWithTimeout()
            }
            .onChange(of: pageIndex) { _, _ in
                hydrateExisting()
            }
            .onChange(of: slotIndex) { _, _ in
                hydrateExisting()
            }
            .onChange(of: client.macCatalogApps) { _, updated in
                if !updated.isEmpty {
                    isWaitingForCatalog = false
                }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
    }

    private var editorTabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(EditorTab.allCases) { candidate in
                    let isSelected = (tab == candidate)
                    Button {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                        tab = candidate
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: candidate.sfSymbol)
                                .font(ChocType.micro)
                            Text(candidate.title(in: lang))
                                .font(ChocType.caption)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(isSelected ? palette.accent : palette.tileFillBottom, in: Capsule())
                        .foregroundStyle(isSelected ? palette.accentForeground : palette.primaryText)
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? .clear : palette.subtleCardStroke, lineWidth: 1)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios-slot-editor-tab-\(candidate.rawValue)")
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private func referenceOriginCallout(for referenceItem: BarItem) -> some View {
        let resolution = client.profile.resolveBarItem(referenceItem, from: currentSlotOrigin)
        switch resolution {
        case .resolved(_, let origPageIdx, let origPageTitle, let origPageEmoji, let origSlotIdx, let targetItem):
            HStack(spacing: 10) {
                Image(systemName: "arrow.turn.up.right")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.accent)
                    .frame(width: 32, height: 32)
                    .background(palette.accent.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        L10n.tr(
                            "引用槽位：\(origPageEmoji) \(origPageTitle) · #\(origSlotIdx + 1)",
                            "Points to \(origPageEmoji) \(origPageTitle) · #\(origSlotIdx + 1)",
                            language: lang
                        )
                    )
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)

                    Text(
                        L10n.tr(
                            "原动作：\(client.profile.displayTitle(for: targetItem, in: lang))（不复制载荷）",
                            "Original: \(client.profile.displayTitle(for: targetItem, in: lang)) (no copied payload)",
                            language: lang
                        )
                    )
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let onEditOriginalSlot {
                    Button {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                        onEditOriginalSlot(origPageIdx, origSlotIdx)
                    } label: {
                        Text(L10n.tr("编辑原槽位", "Edit Original", language: lang))
                            .font(ChocType.micro)
                            .foregroundStyle(palette.accentForeground)
                            .padding(.horizontal, 11)
                            .frame(height: 32)
                            .background(palette.accent, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios-slot-edit-original-button")
                }
            }
            .padding(10)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.accent.opacity(0.45), lineWidth: 1)
            )

        case .missing:
            HStack(spacing: 10) {
                Image(systemName: "link.badge.plus")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(palette.tileFillBottom, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("原槽位已被移除", "Original Slot Was Deleted", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.primaryText)

                    Text(
                        L10n.tr(
                            "点按此引用不会执行任何操作。可在下方重新选择引用目标，或清空此槽位。",
                            "Tapping this reference does nothing. Pick a new target below or clear this slot.",
                            language: lang
                        )
                    )
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .background(palette.barSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .accessibilityIdentifier("ios-slot-missing-reference-banner")
        }
    }

    private func requestCatalogWithTimeout() {
        guard client.connectionState.isConnected else {
            isWaitingForCatalog = false
            return
        }
        if client.macCatalogApps.isEmpty {
            isWaitingForCatalog = true
        }
        client.requestMacCatalog()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.0))
            isWaitingForCatalog = false
        }
    }

    // MARK: - Sounds Tab (Local Mac Soundboard Clips)

    private var soundboardClipsPicker: some View {
        let allClips = client.profile.soundboardClips
        let filtered = SoundboardSearch.filter(allClips, query: soundSearchQuery)
        let currentSoundID = existingItem?.soundID

        return VStack(spacing: 10) {
            if !allClips.isEmpty {
                TextField(
                    L10n.tr("搜索音效名称…", "Search sound names…", language: lang),
                    text: $soundSearchQuery
                )
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14)
                .accessibilityIdentifier("ios-slot-sound-search")
            }

            if allClips.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2.bubble.left")
                        .font(ChocType.title)
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("暂无本机音效", "No Soundboard Clips Yet", language: lang))
                        .font(ChocType.title)
                        .foregroundStyle(palette.primaryText)
                    Text(
                        L10n.tr(
                            "请先在 Mac 端 Choclift「音效板」添加本机短音频（≤ 8 秒，最多 24 个），同步后即可放入任意槽位。",
                            "Add local Mac audio clips (≤ 8s, max 24) in Choclift on your Mac first, then assign them to any slot here.",
                            language: lang
                        )
                    )
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                }
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(ChocType.title)
                        .foregroundStyle(palette.secondaryText)
                    Text(
                        L10n.tr(
                            "没有匹配「\(soundSearchQuery)」的音效",
                            "No sounds matching \"\(soundSearchQuery)\"",
                            language: lang
                        )
                    )
                    .font(ChocType.body.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    Button(L10n.tr("清空搜索", "Clear Search", language: lang)) {
                        soundSearchQuery = ""
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.accent)
                }
                Spacer()
            } else {
                List(filtered) { clip in
                    Button {
                        let existingID = existingItem?.id ?? UUID()
                        assignItem(client.profile.makeBarItem(for: clip, id: existingID))
                    } label: {
                        HStack(spacing: 12) {
                            Text(clip.emoji)
                                .font(ChocType.title)
                                .frame(width: 36, height: 36)
                                .background(
                                    ChocSwatch.resolvedTileColor(hex: clip.backgroundHex, fallbackHex: "#ECFAEE"),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(clip.name)
                                    .font(ChocType.body.weight(.semibold))
                                    .foregroundStyle(palette.primaryText)
                                Text(L10n.tr("Mac 扬声器播放 · \(clip.formattedDuration)", "Mac speakers · \(clip.formattedDuration)", language: lang))
                                    .font(ChocType.micro)
                                    .foregroundStyle(palette.secondaryText)
                            }

                            Spacer()

                            if currentSoundID == clip.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(palette.barSurface)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Reference Slot Tab (Zero Duplicated Action Payload)

    private var referenceTargetPicker: some View {
        let candidates = client.profile.availableReferenceTargets(excluding: currentSlotOrigin)
        let currentRef = existingItem?.slotReferenceCoordinate

        return Group {
            if candidates.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "arrow.turn.up.right")
                        .font(ChocType.title)
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("暂无可引用的其他槽位", "No Other Occupied Slots Yet", language: lang))
                        .font(ChocType.title)
                        .foregroundStyle(palette.primaryText)
                    Text(
                        L10n.tr(
                            "先在其他槽位放置应用、快捷指令、动作流或系统动作，即可在此直接指向它而不复制载荷。",
                            "Configure another slot first, then point this slot at it without duplicating its action payload.",
                            language: lang
                        )
                    )
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    Spacer()
                }
            } else {
                List {
                    Section {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                            let targetCoord = SlotCoordinate(pageID: candidate.page.id, slotIndex: candidate.slotIndex)
                            let isSelected = (currentRef == targetCoord)
                            let targetTitle = client.profile.displayTitle(for: candidate.item, in: lang)

                            Button {
                                let existingID = existingItem?.id ?? UUID()
                                assignItem(
                                    BarItem(
                                        id: existingID,
                                        kind: .slotReference(
                                            targetPageID: candidate.page.id,
                                            targetSlotIndex: candidate.slotIndex
                                        )
                                    )
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "arrow.turn.up.right")
                                        .font(ChocType.caption)
                                        .foregroundStyle(palette.accent)
                                        .frame(width: 32, height: 32)
                                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(targetTitle)
                                            .font(ChocType.body.weight(.semibold))
                                            .foregroundStyle(palette.primaryText)
                                        Text("\(candidate.page.iconEmoji) \(candidate.page.title) · #\(candidate.slotIndex + 1)")
                                            .font(ChocType.micro)
                                            .foregroundStyle(palette.secondaryText)
                                    }

                                    Spacer()

                                    if case .systemAction(let act, _, _) = candidate.item.kind,
                                       let shortcut = act.sentKeyboardShortcut {
                                        Text(shortcut)
                                            .font(ChocType.micro)
                                            .foregroundStyle(palette.secondaryText)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(palette.tileFillBottom, in: Capsule())
                                    }

                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(palette.accent)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .listRowBackground(palette.barSurface)
                            .accessibilityIdentifier("ios-ref-candidate-\(candidate.pageIndex)-\(candidate.slotIndex)")
                        }
                    } header: {
                        Text(
                            L10n.tr(
                                "指向已有槽位（触发时运行原槽位，原槽位删除后保持静默）",
                                "Point at an existing slot (runs original; stays quiet if original is deleted)",
                                language: lang
                            )
                        )
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Mac Apps Tab

    private var macAppsList: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let apps = client.macCatalogApps.filter {
            query.isEmpty ||
            $0.appName.localizedCaseInsensitiveContains(query) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }

        return VStack(spacing: 10) {
            if client.connectionState.isConnected && !client.macCatalogApps.isEmpty {
                TextField(L10n.tr("搜索已连接的 Mac 应用…", "Search connected Mac apps…", language: lang), text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 14)
            }

            if !client.connectionState.isConnected {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.slash")
                        .font(ChocType.title)
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang))
                        .font(ChocType.title)
                        .foregroundStyle(palette.primaryText)
                    Text(L10n.tr("连接 Mac 后可浏览全部本机应用；离线时仍可切换到上方「音效」「引用」「快捷指令」「网页」或「动作」先行配置。", "Connect to your Mac to browse installed apps, or switch to Sounds, Reference, Shortcuts, Web, or Actions above while offline.", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                Spacer()
            } else if client.macCatalogApps.isEmpty && isWaitingForCatalog {
                Spacer()
                ProgressView(L10n.tr("正在同步 Mac 应用目录…", "Loading Mac app catalog…", language: lang))
                    .tint(palette.accent)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
            } else if client.macCatalogApps.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "app.dashed")
                        .font(ChocType.title)
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("暂未收到应用目录", "Catalog Not Loaded Yet", language: lang))
                        .font(ChocType.title)
                        .foregroundStyle(palette.primaryText)
                    Button(L10n.tr("重新请求目录", "Reload Catalog", language: lang)) {
                        requestCatalogWithTimeout()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .foregroundStyle(palette.accentForeground)
                }
                Spacer()
            } else if apps.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(ChocType.title)
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("没有匹配「\(query)」的应用", "No Apps Matching \"\(query)\"", language: lang))
                        .font(ChocType.body.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                    Button(L10n.tr("清空搜索", "Clear Search", language: lang)) {
                        searchQuery = ""
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.accent)
                }
                Spacer()
            } else {
                List(apps) { app in
                    Button {
                        assignItem(BarItem(kind: .macApp(
                            bundleIdentifier: app.bundleIdentifier,
                            appName: app.appName,
                            appPath: app.appPath
                        )))
                    } label: {
                        HStack(spacing: 12) {
                            DataImageView(
                                pngData: app.iconPNGData ?? client.appIconsByBundleID[app.bundleIdentifier] ?? BundledAppIcons.pngData(for: app.bundleIdentifier),
                                fallbackSymbol: "app.fill",
                                tint: palette.secondaryText
                            )
                            .frame(width: 36, height: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.appName)
                                    .font(ChocType.body.weight(.semibold))
                                    .foregroundStyle(palette.primaryText)
                                Text(app.bundleIdentifier)
                                    .font(ChocType.micro)
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(palette.barSurface)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var shortcutsForm: some View {
        Form {
            Section(L10n.tr("快捷指令配置", "Apple Shortcut Details", language: lang)) {
                TextField(L10n.tr("快捷指令名称", "Shortcut Name", language: lang), text: $shortcutName)
                TextField(L10n.tr("顶部 Emoji", "Top Emoji", language: lang), text: $shortcutEmoji)
                colorSwatchSelector(selection: $shortcutHex)

                Button(L10n.tr("保存到槽位", "Save Shortcut", language: lang)) {
                    let clean = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    assignItem(BarItem(kind: .shortcut(
                        shortcutName: clean,
                        emoji: shortcutEmoji.isEmpty ? "⚡️" : shortcutEmoji,
                        backgroundHex: shortcutHex
                    )))
                }
                .font(ChocType.body.weight(.semibold))
                .foregroundStyle(palette.accentEmphasis)
                .disabled(shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .listRowBackground(palette.barSurface)

            if !client.macCatalogShortcuts.isEmpty {
                Section(L10n.tr("从 Mac 快捷指令直接选取", "Pick from Mac Shortcuts", language: lang)) {
                    ForEach(client.macCatalogShortcuts) { sc in
                        Button {
                            shortcutName = sc.name
                        } label: {
                            HStack {
                                Text(sc.name)
                                    .foregroundStyle(palette.primaryText)
                                Spacer()
                                if shortcutName == sc.name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(palette.accent)
                                }
                            }
                        }
                    }
                }
                .listRowBackground(palette.barSurface)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var websiteForm: some View {
        Form {
            Section(L10n.tr("网页书签", "Website Bookmark", language: lang)) {
                TextField("https://example.com", text: $webURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(L10n.tr("显示标题（可选）", "Display Title (Optional)", language: lang), text: $webTitle)
                TextField("Emoji", text: $webEmoji)
                Toggle(L10n.tr("智能切换到已打开标签页", "Switch to Already-Open Browser Tab", language: lang), isOn: $webSwitchTab)
                    .tint(palette.accent)
                colorSwatchSelector(selection: $webHex)

                Button(L10n.tr("保存书签到槽位", "Save Bookmark", language: lang)) {
                    let raw = webURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty, raw != "https://" else { return }
                    let cleanURL = raw.contains("://") ? raw : "https://\(raw)"
                    let trimmedTitle = webTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalTitle = trimmedTitle.isEmpty
                        ? (URL(string: cleanURL)?.host()?.replacingOccurrences(of: "www.", with: "") ?? cleanURL)
                        : trimmedTitle
                    assignItem(BarItem(kind: .website(
                        url: cleanURL,
                        title: finalTitle,
                        emoji: webEmoji.isEmpty ? "🌐" : webEmoji,
                        backgroundHex: webHex,
                        switchExistingTab: webSwitchTab
                    )))
                }
                .font(ChocType.body.weight(.semibold))
                .foregroundStyle(palette.accentEmphasis)
                .disabled(webURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || webURL == "https://")
            }
            .listRowBackground(palette.barSurface)
        }
        .scrollContentBackground(.hidden)
    }

    private var actionsGrid: some View {
        let sections: [(String, [SystemQuickAction])] = [
            (
                L10n.tr("窗口分屏与布局", "Window Layout", language: lang),
                [.maximizeWindow, .minimizeWindow, .snapWindowLeft, .snapWindowRight, .centerWindow, .toggleFullscreen]
            ),
            (
                L10n.tr("编辑与剪贴板", "Clipboard & Edit", language: lang),
                [.copySelection, .pasteClipboard, .cutSelection, .undoAction, .redoAction]
            ),
            (
                L10n.tr("媒体与音量", "Media & Volume", language: lang),
                [.mediaPlayPause, .mediaPrevious, .mediaNext, .volumeUp, .volumeDown, .volumeMute]
            ),
            (
                L10n.tr("桌面与系统控制", "Workspace & System", language: lang),
                [.missionControl, .showDesktop, .screenshotInteractive, .openEmojiPicker, .lockScreen, .quitApp]
            )
        ]

        return List {
            ForEach(sections, id: \.0) { header, actions in
                Section(header) {
                    ForEach(actions) { act in
                        Button {
                            assignItem(BarItem(kind: .systemAction(action: act)))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: act.sfSymbol)
                                    .foregroundStyle(palette.primaryText)
                                    .frame(width: 32, height: 32)
                                    .background(ChocSwatch.resolvedTileColor(hex: act.accentHex), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                                Text(act.title(in: lang))
                                    .font(ChocType.body)
                                    .foregroundStyle(palette.primaryText)

                                Spacer()

                                if let shortcut = act.sentKeyboardShortcut {
                                    Text(shortcut)
                                        .font(ChocType.micro)
                                        .foregroundStyle(palette.secondaryText)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(palette.tileFillBottom, in: Capsule())
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                                        )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowBackground(palette.barSurface)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func colorSwatchSelector(selection: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ChocSwatch.tileColors, id: \.self) { hex in
                    let isSel = (selection.wrappedValue.uppercased() == hex.uppercased())
                    Button {
                        selection.wrappedValue = hex
                    } label: {
                        ZStack {
                            Circle()
                                .fill(ChocSwatch.resolvedTileColor(hex: hex))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Circle()
                                        .strokeBorder(isSel ? palette.accent : palette.subtleCardStroke, lineWidth: isSel ? 2.6 : 1.0)
                                )
                            if isSel {
                                Image(systemName: "checkmark")
                                    .font(ChocType.micro)
                                    .foregroundStyle(palette.primaryText)
                            }
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func assignFlow(_ flow: ActionFlow) {
        pendingFlow = flow
        stageItem(client.profile.makeBarItem(for: flow, id: existingItem?.id ?? UUID()))
    }

    private func assignItem(_ item: BarItem?) {
        guard let item else {
            var updated = client.profile
            guard updated.setSlotItem(nil, pageIndex: pageIndex, slotIndex: slotIndex) else { return }
            client.pushUpdatedProfile(updated)
            dismiss()
            return
        }
        pendingFlow = nil
        stageItem(item)
    }

    private func stageItem(_ item: BarItem) {
        reviewName = item.displayTitle(in: lang)
        switch item.kind {
        case .shortcut(_, let emoji, _), .website(_, _, let emoji, _, _), .flow(_, _, let emoji, _, _), .soundboard(_, _, let emoji, _): reviewIcon = emoji
        case .folder(let folder): reviewIcon = folder.emoji
        case .macApp(_, _, _, let symbol): reviewIcon = symbol
        case .systemAction(let action, _, _): reviewIcon = action.sfSymbol
        default: reviewIcon = "arrow.turn.up.right"
        }
        pendingItem = item
    }

    private func commitReviewedItem(_ item: BarItem) {
        var item = item
        let title = reviewName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? item.displayTitle(in: lang) : title
        switch item.kind {
        case .macApp(let bundle, _, let path, let symbol): item.kind = .macApp(bundleIdentifier: bundle, appName: name, appPath: path, fallbackSymbol: reviewIcon.isEmpty ? symbol : reviewIcon)
        case .website(let url, _, let emoji, let hex, let switchTab): item.kind = .website(url: url, title: name, emoji: reviewIcon.isEmpty ? emoji : reviewIcon, backgroundHex: hex, switchExistingTab: switchTab)
        case .shortcut(let target, let emoji, let hex): item.kind = .shortcut(shortcutName: target, emoji: reviewIcon.isEmpty ? emoji : reviewIcon, backgroundHex: hex)
        case .systemAction(let action, _, let hex): item.kind = .systemAction(action: action, customTitle: name, backgroundHex: hex)
        case .flow(let id, _, let emoji, let hex, let count): item.kind = .flow(flowID: id, titleSnapshot: name, emoji: reviewIcon.isEmpty ? emoji : reviewIcon, backgroundHex: hex, stepCountSnapshot: count)
        case .soundboard(let id, _, let emoji, let hex): item.kind = .soundboard(soundID: id, titleSnapshot: name, emoji: reviewIcon.isEmpty ? emoji : reviewIcon, backgroundHex: hex)
        case .folder(var folder): folder.title = name; if !reviewIcon.isEmpty { folder.emoji = reviewIcon }; item.kind = .folder(folder)
        case .slotReference: break
        }
        var updated = client.profile
        if var flow = pendingFlow {
            flow.name = name
            if !reviewIcon.isEmpty { flow.emoji = reviewIcon }
            updated.upsertFlow(flow)
        }
        guard updated.setSlotItem(item, pageIndex: pageIndex, slotIndex: slotIndex) else { return }
        client.pushUpdatedProfile(updated)
        pendingItem = nil
        dismiss()
    }

    @ViewBuilder
    private func pinToStripCallout(coordinate: SlotCoordinate, item: BarItem) -> some View {
        let isPinned = client.profile.isSlotPinnedToStrip(coordinate)
        let pinCount = client.profile.activePinnedStripCount
        let canPin = isPinned || client.profile.canPinMoreSlotsToStrip
        let title = client.profile.displayTitle(for: item, from: coordinate, in: lang)

        HStack(spacing: 10) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(ChocType.caption)
                .foregroundStyle(isPinned ? palette.accent : palette.secondaryText)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    isPinned
                        ? L10n.tr("已固定到底部常驻栏 · \(title)", "Pinned to Persistent Strip · \(title)", language: lang)
                        : L10n.tr(
                            "底部常驻栏（\(pinCount)/\(PinnedStripSlots.maxPinnedCount)）",
                            "Persistent Strip (\(pinCount)/\(PinnedStripSlots.maxPinnedCount))",
                            language: lang
                        )
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)

                Text(
                    isPinned
                        ? L10n.tr("翻页时保持可见，点按直接运行，长按可再次编辑。", "Stays visible across page changes. Tap to run, hold to edit.", language: lang)
                        : (canPin
                            ? L10n.tr("固定后翻页仍保持可见（最多 4 个）。", "Keep this tile visible while changing pages (up to 4).", language: lang)
                            : L10n.tr("常驻栏已满 4 个固定方块，请先取消固定其他方块。", "4 tiles already pinned. Unpin another slot first.", language: lang))
                )
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
            }

            Spacer(minLength: 6)

            if isPinned {
                Button {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                    _ = client.unpinSlotFromStrip(coordinate)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.slash.fill")
                            .font(ChocType.micro)
                        Text(L10n.tr("取消固定", "Unpin", language: lang))
                            .font(ChocType.micro)
                    }
                    .foregroundStyle(palette.emphasisForeground)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 34)
                    .background(palette.accentEmphasis, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ios-slot-editor-unpin-button")
            } else {
                Button {
                    guard canPin else { return }
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                    _ = client.pinSlotToStrip(coordinate)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pin.fill")
                            .font(ChocType.micro)
                        Text(
                            canPin
                                ? L10n.tr("固定", "Pin", language: lang)
                                : L10n.tr("已满 4/4", "Full 4/4", language: lang)
                        )
                        .font(ChocType.micro)
                    }
                    .foregroundStyle(canPin ? palette.accentForeground : palette.secondaryText)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 34)
                    .background(canPin ? palette.accent : palette.tileFillBottom, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(canPin ? .clear : palette.subtleCardStroke, lineWidth: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canPin)
                .accessibilityIdentifier("ios-slot-editor-pin-button")
            }
        }
        .padding(12)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isPinned ? palette.accent.opacity(0.6) : palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private func hydrateExisting() {
        guard client.profile.pages.indices.contains(pageIndex),
              let existing = client.profile.pages[pageIndex].slots[slotIndex] else { return }
        switch existing.kind {
        case .macApp:
            tab = .apps
        case .shortcut(let name, let emoji, let hex):
            tab = .shortcuts
            shortcutName = name
            shortcutEmoji = emoji
            shortcutHex = hex
        case .website(let url, let title, let emoji, let hex, let switchTab):
            tab = .website
            webURL = url
            webTitle = title
            webEmoji = emoji
            webHex = hex
            webSwitchTab = switchTab
        case .systemAction:
            tab = .actions
        case .flow:
            tab = .flows
        case .soundboard:
            tab = .sounds
        case .folder:
            tab = .folder
        case .slotReference:
            tab = .reference
        }
    }
}
