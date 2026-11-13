import ChocliftCore
import SwiftUI

public struct IOSSlotEditorSheet: View {
    public enum EditorTab: String, CaseIterable, Identifiable {
        case apps
        case flows
        case sounds
        case reference
        case shortcuts
        case website
        case actions

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
            }
        }
    }

    @ObservedObject var client: CompanionClientEngine
    let pageIndex: Int
    let slotIndex: Int
    var onEditOriginalSlot: ((Int, Int) -> Void)?
    @Environment(\.dismiss) private var dismiss

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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "Cancel", language: lang)) { dismiss() }
                        .foregroundStyle(palette.secondaryText)
                        .accessibilityIdentifier("ios-slot-editor-cancel")
                }
                if existingItem != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(L10n.tr("清空", "Clear", language: lang), role: .destructive) {
                            assignItem(nil)
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
                                .font(.system(size: 11.5, weight: .bold))
                            Text(candidate.title(in: lang))
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
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
                    .font(.system(size: 14, weight: .bold))
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
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                    Text(
                        L10n.tr(
                            "原动作：\(client.profile.displayTitle(for: targetItem, in: lang))（不复制载荷）",
                            "Original: \(client.profile.displayTitle(for: targetItem, in: lang)) (no copied payload)",
                            language: lang
                        )
                    )
                    .font(.caption2)
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
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(palette.tileFillBottom, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("原槽位已被移除", "Original Slot Was Deleted", language: lang))
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)

                    Text(
                        L10n.tr(
                            "点按此引用不会执行任何操作。可在下方重新选择引用目标，或清空此槽位。",
                            "Tapping this reference does nothing. Pick a new target below or clear this slot.",
                            language: lang
                        )
                    )
                    .font(.caption2)
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
                        .font(.system(size: 32))
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("暂无本机音效", "No Soundboard Clips Yet", language: lang))
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Text(
                        L10n.tr(
                            "请先在 Mac 端 Choclift「音效板」添加本机短音频（≤ 8 秒，最多 24 个），同步后即可放入任意槽位。",
                            "Add local Mac audio clips (≤ 8s, max 24) in Choclift on your Mac first, then assign them to any slot here.",
                            language: lang
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                }
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(palette.secondaryText)
                    Text(
                        L10n.tr(
                            "没有匹配「\(soundSearchQuery)」的音效",
                            "No sounds matching \"\(soundSearchQuery)\"",
                            language: lang
                        )
                    )
                    .font(.subheadline.bold())
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
                                .font(.system(size: 20))
                                .frame(width: 36, height: 36)
                                .background(
                                    ChocSwatch.resolvedTileColor(hex: clip.backgroundHex, fallbackHex: "#ECFAEE"),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(clip.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(palette.primaryText)
                                Text(L10n.tr("Mac 扬声器播放 · \(clip.formattedDuration)", "Mac speakers · \(clip.formattedDuration)", language: lang))
                                    .font(.caption2)
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
                        .font(.system(size: 32))
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("暂无可引用的其他槽位", "No Other Occupied Slots Yet", language: lang))
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Text(
                        L10n.tr(
                            "先在其他槽位放置应用、快捷指令、动作流或系统动作，即可在此直接指向它而不复制载荷。",
                            "Configure another slot first, then point this slot at it without duplicating its action payload.",
                            language: lang
                        )
                    )
                    .font(.caption)
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
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(palette.accent)
                                        .frame(width: 32, height: 32)
                                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(targetTitle)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(palette.primaryText)
                                        Text("\(candidate.page.iconEmoji) \(candidate.page.title) · #\(candidate.slotIndex + 1)")
                                            .font(.caption2)
                                            .foregroundStyle(palette.secondaryText)
                                    }

                                    Spacer()

                                    if case .systemAction(let act, _, _) = candidate.item.kind,
                                       let shortcut = act.sentKeyboardShortcut {
                                        Text(shortcut)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
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
                        .font(.system(size: 32))
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang))
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Text(L10n.tr("连接 Mac 后可浏览全部本机应用；离线时仍可切换到上方「音效」「引用」「快捷指令」「网页」或「动作」先行配置。", "Connect to your Mac to browse installed apps, or switch to Sounds, Reference, Shortcuts, Web, or Actions above while offline.", language: lang))
                        .font(.caption)
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
                        .font(.system(size: 32))
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("暂未收到应用目录", "Catalog Not Loaded Yet", language: lang))
                        .font(.headline)
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
                        .font(.title2)
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("没有匹配「\(query)」的应用", "No Apps Matching \"\(query)\"", language: lang))
                        .font(.subheadline.bold())
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
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(palette.primaryText)
                                Text(app.bundleIdentifier)
                                    .font(.caption2)
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
                .font(.body.weight(.semibold))
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
                .font(.body.weight(.semibold))
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
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(palette.primaryText)

                                Spacer()

                                if let shortcut = act.sentKeyboardShortcut {
                                    Text(shortcut)
                                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
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
                                    .font(.system(size: 11, weight: .black))
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
        var updated = client.profile
        guard updated.pages.indices.contains(pageIndex),
              updated.pages[pageIndex].slots.indices.contains(slotIndex) else { return }
        var normalized = flow
        normalized.updatedAt = Date()
        updated.upsertFlow(normalized)
        let existingID = updated.pages[pageIndex].slots[slotIndex]?.id ?? UUID()
        updated.pages[pageIndex].slots[slotIndex] = updated.makeBarItem(for: normalized, id: existingID)
        client.pushUpdatedProfile(updated)
        dismiss()
    }

    private func assignItem(_ item: BarItem?) {
        var updated = client.profile
        guard updated.pages.indices.contains(pageIndex),
              updated.pages[pageIndex].slots.indices.contains(slotIndex) else { return }
        updated.pages[pageIndex].slots[slotIndex] = item
        client.pushUpdatedProfile(updated)
        dismiss()
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
        case .slotReference:
            tab = .reference
        }
    }
}
