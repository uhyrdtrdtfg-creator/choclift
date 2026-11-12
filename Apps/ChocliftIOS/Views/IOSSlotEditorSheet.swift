import ChocliftCore
import SwiftUI

public struct IOSSlotEditorSheet: View {
    public enum EditorTab: String, CaseIterable, Identifiable {
        case apps
        case flows
        case shortcuts
        case website
        case actions
        public var id: String { rawValue }
    }

    @ObservedObject var client: CompanionClientEngine
    let pageIndex: Int
    let slotIndex: Int
    @Environment(\.dismiss) private var dismiss

    @State private var tab: EditorTab = .apps
    @State private var searchQuery: String = ""
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

    public init(client: CompanionClientEngine, pageIndex: Int, slotIndex: Int) {
        self.client = client
        self.pageIndex = pageIndex
        self.slotIndex = slotIndex
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(L10n.tr("应用", "Apps", language: lang)).tag(EditorTab.apps)
                    Text(L10n.tr("动作流", "Flows", language: lang)).tag(EditorTab.flows)
                    Text(L10n.tr("指令", "Shortcuts", language: lang)).tag(EditorTab.shortcuts)
                    Text(L10n.tr("网页", "Web", language: lang)).tag(EditorTab.website)
                    Text(L10n.tr("动作", "Actions", language: lang)).tag(EditorTab.actions)
                }
                .pickerStyle(.segmented)
                .padding(12)

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
                if client.profile.pages.indices.contains(pageIndex),
                   client.profile.pages[pageIndex].slots[slotIndex] != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(L10n.tr("清空", "Clear", language: lang), role: .destructive) {
                            assignItem(nil)
                        }
                        .foregroundStyle(palette.statusFailure)
                    }
                }
            }
            .onAppear {
                hydrateExisting()
                requestCatalogWithTimeout()
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
                    Text(L10n.tr("连接 Mac 后可浏览全部本机应用；离线时仍可切换到上方「快捷指令」「网页」或「系统动作」先行配置。", "Connect to your Mac to browse installed apps, or switch to Shortcuts, Website, or Actions above while offline.", language: lang))
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
                                pngData: app.iconPNGData ?? client.appIconsByBundleID[app.bundleIdentifier],
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
                [.missionControl, .showDesktop, .screenshotInteractive, .openEmojiPicker, .lockScreen]
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
                                .fill(Color(hex: hex))
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
        }
    }
}
