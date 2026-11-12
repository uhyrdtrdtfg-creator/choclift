import ChocliftCore
import SwiftUI

public struct IOSSlotEditorSheet: View {
    public enum EditorTab: String, CaseIterable, Identifiable {
        case apps
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

    @State private var shortcutName: String = ""
    @State private var shortcutEmoji: String = "⚡️"
    @State private var shortcutHex: String = "#6C3EB8"

    @State private var webURL: String = "https://"
    @State private var webTitle: String = ""
    @State private var webEmoji: String = "🌐"
    @State private var webHex: String = "#C93B2B"
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
                    Text(L10n.tr("Mac应用", "Apps", language: lang)).tag(EditorTab.apps)
                    Text(L10n.tr("快捷指令", "Shortcuts", language: lang)).tag(EditorTab.shortcuts)
                    Text(L10n.tr("网页", "Website", language: lang)).tag(EditorTab.website)
                    Text(L10n.tr("系统动作", "Actions", language: lang)).tag(EditorTab.actions)
                }
                .pickerStyle(.segmented)
                .padding(12)

                Group {
                    switch tab {
                    case .apps:
                        macAppsList
                    case .shortcuts:
                        shortcutsForm
                    case .website:
                        websiteForm
                    case .actions:
                        actionsGrid
                    }
                }
            }
            .navigationTitle(L10n.tr("编辑槽位 #\(slotIndex + 1)", "Edit Slot #\(slotIndex + 1)", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "Cancel", language: lang)) { dismiss() }
                }
                if client.profile.pages.indices.contains(pageIndex),
                   client.profile.pages[pageIndex].slots[slotIndex] != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(L10n.tr("清空", "Clear", language: lang), role: .destructive) {
                            assignItem(nil)
                        }
                    }
                }
            }
            .onAppear {
                client.requestMacCatalog()
                hydrateExisting()
            }
        }
    }

    private var macAppsList: some View {
        let apps = client.macCatalogApps.filter {
            searchQuery.isEmpty ||
            $0.appName.localizedCaseInsensitiveContains(searchQuery) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(searchQuery)
        }

        return VStack {
            TextField(L10n.tr("搜索已连接的 Mac 应用…", "Search connected Mac apps…", language: lang), text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)

            if apps.isEmpty {
                Spacer()
                if client.connectionState.isConnected {
                    ProgressView(L10n.tr("正在同步 Mac 端应用目录…", "Loading Mac app catalog…", language: lang))
                } else {
                    Text(L10n.tr("连接 Mac 后即可浏览全部本机应用", "Connect to your Mac to browse installed apps", language: lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                                tint: .accentColor
                            )
                            .frame(width: 34, height: 34)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.appName)
                                    .font(.body.weight(.semibold))
                                Text(app.bundleIdentifier)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var shortcutsForm: some View {
        Form {
            Section(L10n.tr("快捷指令配置", "Apple Shortcut Details", language: lang)) {
                TextField(L10n.tr("快捷指令名称", "Shortcut Name", language: lang), text: $shortcutName)
                TextField(L10n.tr("顶部 Emoji", "Top Emoji", language: lang), text: $shortcutEmoji)
                colorSwatchSelector(selection: $shortcutHex)

                Button(L10n.tr("保存快捷指令", "Save Shortcut", language: lang)) {
                    let clean = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    assignItem(BarItem(kind: .shortcut(
                        shortcutName: clean,
                        emoji: shortcutEmoji.isEmpty ? "⚡️" : shortcutEmoji,
                        backgroundHex: shortcutHex
                    )))
                }
                .disabled(shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !client.macCatalogShortcuts.isEmpty {
                Section(L10n.tr("从 Mac 快捷指令直接选取", "Pick from Mac Shortcuts", language: lang)) {
                    ForEach(client.macCatalogShortcuts) { sc in
                        Button {
                            shortcutName = sc.name
                        } label: {
                            HStack {
                                Text(sc.name)
                                Spacer()
                                if shortcutName == sc.name {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var websiteForm: some View {
        Form {
            Section(L10n.tr("网页书签", "Website Bookmark", language: lang)) {
                TextField("https://example.com", text: $webURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(L10n.tr("标题", "Title", language: lang), text: $webTitle)
                TextField("Emoji", text: $webEmoji)
                Toggle(L10n.tr("智能切换到已打开标签页", "Switch to Already-Open Browser Tab", language: lang), isOn: $webSwitchTab)
                colorSwatchSelector(selection: $webHex)

                Button(L10n.tr("保存书签", "Save Bookmark", language: lang)) {
                    let cleanURL = webURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleanURL.isEmpty, cleanURL != "https://" else { return }
                    let finalTitle = webTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? cleanURL : webTitle
                    assignItem(BarItem(kind: .website(
                        url: cleanURL,
                        title: finalTitle,
                        emoji: webEmoji.isEmpty ? "🌐" : webEmoji,
                        backgroundHex: webHex,
                        switchExistingTab: webSwitchTab
                    )))
                }
            }
        }
    }

    private var actionsGrid: some View {
        List(SystemQuickAction.allCases) { act in
            Button {
                assignItem(BarItem(kind: .systemAction(action: act)))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: act.sfSymbol)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color(hex: act.accentHex), in: RoundedRectangle(cornerRadius: 8))
                    Text(act.title(in: lang))
                        .font(.body.weight(.medium))
                }
            }
        }
    }

    private func colorSwatchSelector(selection: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ChocSwatch.tileColors, id: \.self) { hex in
                    Button {
                        selection.wrappedValue = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(.white, lineWidth: selection.wrappedValue == hex ? 3 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
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
        }
    }
}
