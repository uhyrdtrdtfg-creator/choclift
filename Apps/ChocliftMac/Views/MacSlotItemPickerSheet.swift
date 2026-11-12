import AppKit
import ChocliftCore
import SwiftUI
import UniformTypeIdentifiers

public struct MacSlotItemPickerSheet: View {
    public enum PickerTab: String, CaseIterable, Identifiable {
        case apps
        case shortcuts
        case website
        case actions

        public var id: String { rawValue }
    }

    @ObservedObject var coordinator: MacAppCoordinator
    let pageIndex: Int
    let slotIndex: Int
    let existingItem: BarItem?
    @Environment(\.dismiss) private var dismiss

    @State private var activeTab: PickerTab = .apps
    @State private var appSearchText: String = ""
    @State private var highlightedAppIndex: Int = 0

    // Shortcut draft
    @State private var shortcutSearchText: String = ""
    @State private var shortcutName: String = ""
    @State private var shortcutEmoji: String = "⚡️"
    @State private var shortcutColorHex: String = "#6C3EB8"

    // Website draft
    @State private var websiteURL: String = "https://"
    @State private var websiteTitle: String = ""
    @State private var websiteEmoji: String = "🌐"
    @State private var websiteColorHex: String = "#C93B2B"
    @State private var websiteSwitchExistingTab: Bool = true

    private var lang: AppLanguage { coordinator.lang }

    private var filteredApps: [InstalledAppSummary] {
        let query = appSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return coordinator.installedApps }
        return coordinator.installedApps.filter {
            $0.appName.localizedCaseInsensitiveContains(query) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredShortcuts: [InstalledShortcutSummary] {
        let query = shortcutSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return coordinator.installedShortcuts }
        return coordinator.installedShortcuts.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    public init(
        coordinator: MacAppCoordinator,
        pageIndex: Int,
        slotIndex: Int,
        existingItem: BarItem?
    ) {
        self.coordinator = coordinator
        self.pageIndex = pageIndex
        self.slotIndex = slotIndex
        self.existingItem = existingItem
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            Group {
                switch activeTab {
                case .apps:
                    appsPickerBody
                case .shortcuts:
                    shortcutsPickerBody
                case .website:
                    websitePickerBody
                case .actions:
                    actionsPickerBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footerBar
        }
        .frame(width: 640, height: 540)
        .onAppear(perform: hydrateFromExisting)
    }

    private var headerBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("配置巧克力槽位 #\(slotIndex + 1)", "Configure Chocolate Slot #\(slotIndex + 1)", language: lang))
                    .font(.headline)
                Text(L10n.tr("第 \(pageIndex + 1) 页 · 支持应用、快捷指令、网页书签与窗口动作", "Page \(pageIndex + 1) · Apps, Apple Shortcuts, Websites & Actions", language: lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $activeTab) {
                Text(L10n.tr("应用", "Apps", language: lang)).tag(PickerTab.apps)
                Text(L10n.tr("快捷指令", "Shortcuts", language: lang)).tag(PickerTab.shortcuts)
                Text(L10n.tr("网页", "Website", language: lang)).tag(PickerTab.website)
                Text(L10n.tr("系统动作", "Actions", language: lang)).tag(PickerTab.actions)
            }
            .pickerStyle(.segmented)
            .frame(width: 340)
        }
        .padding(16)
    }

    // MARK: - Tab 1: Mac Apps (v2.3.5 Keyboard Navigable App Picker)

    private var appsPickerBody: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    L10n.tr("搜索 Mac 应用（可用 ↑ ↓ 方向键选择，回车确认）…", "Search Mac apps (Use ↑ ↓ arrows & Return to pick)…", language: lang),
                    text: $appSearchText
                )
                .textFieldStyle(.plain)
                .onChange(of: appSearchText) { _, _ in
                    highlightedAppIndex = 0
                }
                .onSubmit {
                    if filteredApps.indices.contains(highlightedAppIndex) {
                        selectApp(filteredApps[highlightedAppIndex])
                    }
                }

                Button {
                    chooseAppViaFinderPanel()
                } label: {
                    Label(L10n.tr("从访达选择…", "Browse Finder…", language: lang), systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if coordinator.isScanningCatalog && filteredApps.isEmpty {
                Spacer()
                ProgressView(L10n.tr("正在扫描本机应用…", "Scanning installed Mac apps…", language: lang))
                Spacer()
            } else if filteredApps.isEmpty {
                Spacer()
                ContentUnavailableView(
                    L10n.tr("未找到匹配应用", "No Matching Apps", language: lang),
                    systemImage: "app.dashed",
                    description: Text(L10n.tr("可点击右上角「从访达选择…」手动添加任意 .app", "Use Browse Finder to pick any .app bundle manually", language: lang))
                )
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List(Array(filteredApps.enumerated()), id: \.element.bundleIdentifier) { idx, app in
                        Button {
                            selectApp(app)
                        } label: {
                            HStack(spacing: 12) {
                                DataImageView(pngData: app.iconPNGData, fallbackSymbol: "app.fill", tint: .accentColor)
                                    .frame(width: 34, height: 34)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.appName)
                                        .font(.system(.body, design: .rounded, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(app.bundleIdentifier)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if idx == highlightedAppIndex {
                                    Text("⏎")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.primary.opacity(0.08), in: Capsule())
                                }
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(
                                idx == highlightedAppIndex
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(idx)
                    }
                    .listStyle(.inset)
                    .onKeyPress(.downArrow) {
                        if highlightedAppIndex + 1 < filteredApps.count {
                            highlightedAppIndex += 1
                            proxy.scrollTo(highlightedAppIndex, anchor: .center)
                        }
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        if highlightedAppIndex > 0 {
                            highlightedAppIndex -= 1
                            proxy.scrollTo(highlightedAppIndex, anchor: .center)
                        }
                        return .handled
                    }
                    .onKeyPress(.return) {
                        if filteredApps.indices.contains(highlightedAppIndex) {
                            selectApp(filteredApps[highlightedAppIndex])
                            return .handled
                        }
                        return .ignored
                    }
                }
            }
        }
    }

    // MARK: - Tab 2: Apple Shortcuts

    private var shortcutsPickerBody: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.tr("本机快捷指令列表", "Installed Mac Shortcuts", language: lang))
                        .font(.subheadline.bold())
                    Spacer()
                    Button {
                        coordinator.refreshCatalog()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.tr("刷新快捷指令列表", "Refresh Shortcuts", language: lang))
                }

                TextField(L10n.tr("搜索快捷指令…", "Filter Shortcuts…", language: lang), text: $shortcutSearchText)
                    .textFieldStyle(.roundedBorder)

                if filteredShortcuts.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(L10n.tr("右侧可直接输入任意快捷指令名称", "Enter any Shortcut name on the right", language: lang))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(L10n.tr("打开系统「快捷指令」应用", "Open macOS Shortcuts App", language: lang)) {
                            let url = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(filteredShortcuts) { item in
                        Button {
                            shortcutName = item.name
                        } label: {
                            HStack {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(.purple)
                                Text(item.name)
                                Spacer()
                                if shortcutName == item.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                }
            }
            .frame(width: 265)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.tr("快捷指令卡片样式", "Shortcut Tile Customization", language: lang))
                    .font(.subheadline.bold())

                HStack {
                    Spacer()
                    ChocBarTileCard(
                        item: BarItem(kind: .shortcut(
                            shortcutName: shortcutName.isEmpty ? "Morning Workflow" : shortcutName,
                            emoji: shortcutEmoji,
                            backgroundHex: shortcutColorHex
                        )),
                        iconData: nil,
                        palette: coordinator.palette,
                        language: lang
                    )
                    .frame(width: 108, height: 108)
                    Spacer()
                }

                LabeledContent(L10n.tr("指令名称", "Shortcut Name", language: lang)) {
                    TextField("Morning Workflow", text: $shortcutName)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.tr("顶部 Emoji", "Top Emoji", language: lang)) {
                    HStack(spacing: 6) {
                        TextField("⚡️", text: $shortcutEmoji)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        ForEach(["⚡️", "🔮", "📝", "☕️", "🎵", "🚀", "🧠", "🍫"], id: \.self) { em in
                            Button(em) { shortcutEmoji = em }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("卡片配色", "Tile Color", language: lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    swatchRow(selection: $shortcutColorHex)
                }

                Spacer()

                HStack {
                    Spacer()
                    Button(L10n.tr("保存快捷指令到槽位", "Save Shortcut to Slot", language: lang)) {
                        let finalName = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !finalName.isEmpty else { return }
                        let item = BarItem(
                            kind: .shortcut(
                                shortcutName: finalName,
                                emoji: shortcutEmoji.isEmpty ? "⚡️" : shortcutEmoji,
                                backgroundHex: shortcutColorHex
                            )
                        )
                        coordinator.setSlotItem(item, pageIndex: pageIndex, slotIndex: slotIndex)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
    }

    // MARK: - Tab 3: Website Bookmark

    private var websitePickerBody: some View {
        HStack(spacing: 20) {
            VStack(spacing: 14) {
                Text(L10n.tr("实时预览", "Live Tile Preview", language: lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ChocBarTileCard(
                    item: BarItem(kind: .website(
                        url: websiteURL,
                        title: websiteTitle.isEmpty ? "Website" : websiteTitle,
                        emoji: websiteEmoji,
                        backgroundHex: websiteColorHex,
                        switchExistingTab: websiteSwitchExistingTab
                    )),
                    iconData: nil,
                    palette: coordinator.palette,
                    language: lang
                )
                .frame(width: 124, height: 124)

                Text(L10n.tr("快速预设", "Popular Presets", language: lang))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    presetWebsiteButton(title: "YouTube", url: "https://www.youtube.com", emoji: "▶️", hex: "#C93B2B")
                    presetWebsiteButton(title: "GitHub", url: "https://github.com", emoji: "🐙", hex: "#24292F")
                    presetWebsiteButton(title: "Figma", url: "https://www.figma.com", emoji: "🎨", hex: "#9333EA")
                    presetWebsiteButton(title: "Notion", url: "https://www.notion.so", emoji: "📓", hex: "#37352F")
                }
            }
            .frame(width: 175)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                LabeledContent(L10n.tr("网址 URL", "Website URL", language: lang)) {
                    TextField("https://example.com", text: $websiteURL)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.tr("显示名称", "Display Title", language: lang)) {
                    TextField("YouTube / Notion / Docs", text: $websiteTitle)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.tr("图标 Emoji", "Icon Emoji", language: lang)) {
                    HStack(spacing: 6) {
                        TextField("🌐", text: $websiteEmoji)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        ForEach(["🌐", "▶️", "🐙", "🎨", "📓", "📰", "💬", "🛒"], id: \.self) { em in
                            Button(em) { websiteEmoji = em }
                                .buttonStyle(.bordered)
                        }
                    }
                }

                Toggle(
                    L10n.tr("若浏览器已打开该网站，自动切换到对应标签页（支持 Safari / Chrome / Arc）", "Switch to already-open tab if open in Safari / Chrome / Arc", language: lang),
                    isOn: $websiteSwitchExistingTab
                )
                .font(.callout)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("卡片配色", "Tile Color", language: lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    swatchRow(selection: $websiteColorHex)
                }

                Spacer()

                HStack {
                    Spacer()
                    Button(L10n.tr("保存网页书签到槽位", "Save Website to Slot", language: lang)) {
                        let cleanURL = websiteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanURL.isEmpty, cleanURL != "https://" else { return }
                        let derivedTitle: String = {
                            let t = websiteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { return t }
                            let normalized = cleanURL.contains("://") ? cleanURL : "https://\(cleanURL)"
                            return URL(string: normalized)?.host()?.replacingOccurrences(of: "www.", with: "") ?? cleanURL
                        }()
                        let item = BarItem(
                            kind: .website(
                                url: cleanURL,
                                title: derivedTitle,
                                emoji: websiteEmoji.isEmpty ? "🌐" : websiteEmoji,
                                backgroundHex: websiteColorHex,
                                switchExistingTab: websiteSwitchExistingTab
                            )
                        )
                        coordinator.setSlotItem(item, pageIndex: pageIndex, slotIndex: slotIndex)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(18)
    }

    // MARK: - Tab 4: System Quick Actions

    private var actionsPickerBody: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(SystemQuickAction.allCases) { action in
                    Button {
                        let item = BarItem(kind: .systemAction(action: action))
                        coordinator.setSlotItem(item, pageIndex: pageIndex, slotIndex: slotIndex)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: action.sfSymbol)
                                .font(.title3)
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Color(hex: action.accentHex), in: RoundedRectangle(cornerRadius: 8))
                            Text(action.title(in: lang))
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private var footerBar: some View {
        HStack {
            if existingItem != nil {
                Button(role: .destructive) {
                    coordinator.setSlotItem(nil, pageIndex: pageIndex, slotIndex: slotIndex)
                    dismiss()
                } label: {
                    Label(L10n.tr("清空此槽位", "Clear Slot", language: lang), systemImage: "trash")
                }
            }

            Spacer()

            Button(L10n.tr("取消", "Cancel", language: lang)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    // MARK: - Helpers

    private func selectApp(_ app: InstalledAppSummary) {
        let item = BarItem(
            kind: .macApp(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.appName,
                appPath: app.appPath
            )
        )
        coordinator.setSlotItem(item, pageIndex: pageIndex, slotIndex: slotIndex)
        dismiss()
    }

    private func chooseAppViaFinderPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            _ = coordinator.handleDroppedFileOrURL(url, pageIndex: pageIndex, slotIndex: slotIndex)
            dismiss()
        }
    }

    private func presetWebsiteButton(title: String, url: String, emoji: String, hex: String) -> some View {
        Button {
            websiteTitle = title
            websiteURL = url
            websiteEmoji = emoji
            websiteColorHex = hex
        } label: {
            HStack {
                Text(emoji)
                Text(title)
                    .font(.caption.bold())
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func swatchRow(selection: Binding<String>) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
            ForEach(ChocSwatch.tileColors, id: \.self) { hex in
                Button {
                    selection.wrappedValue = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .strokeBorder(.white, lineWidth: selection.wrappedValue == hex ? 2.5 : 0)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func hydrateFromExisting() {
        guard let existingItem else { return }
        switch existingItem.kind {
        case .macApp(_, let appName, _, _):
            activeTab = .apps
            appSearchText = appName
        case .shortcut(let name, let emoji, let hex):
            activeTab = .shortcuts
            shortcutName = name
            shortcutEmoji = emoji
            shortcutColorHex = hex
        case .website(let url, let title, let emoji, let hex, let switchTab):
            activeTab = .website
            websiteURL = url
            websiteTitle = title
            websiteEmoji = emoji
            websiteColorHex = hex
            websiteSwitchExistingTab = switchTab
        case .systemAction:
            activeTab = .actions
        }
    }
}
