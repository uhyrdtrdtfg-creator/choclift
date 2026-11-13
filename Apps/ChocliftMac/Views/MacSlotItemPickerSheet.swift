import AppKit
import ChocliftCore
import SwiftUI
import UniformTypeIdentifiers

public struct MacSlotItemPickerSheet: View {
    public enum PickerTab: String, CaseIterable, Identifiable {
        case apps
        case flows
        case shortcuts
        case website
        case actions

        public var id: String { rawValue }

        public var sfSymbol: String {
            switch self {
            case .apps: return "app.badge"
            case .flows: return "arrow.triangle.branch"
            case .shortcuts: return "bolt.fill"
            case .website: return "safari.fill"
            case .actions: return "macwindow.badge.plus"
            }
        }

        public func title(in lang: AppLanguage) -> String {
            switch self {
            case .apps: return L10n.tr("应用", "Apps", language: lang)
            case .flows: return L10n.tr("动作流", "Flows", language: lang)
            case .shortcuts: return L10n.tr("快捷指令", "Shortcuts", language: lang)
            case .website: return L10n.tr("网页", "Website", language: lang)
            case .actions: return L10n.tr("系统动作", "Actions", language: lang)
            }
        }
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
    @State private var shortcutColorHex: String = "#F3EEFF"

    // Website draft
    @State private var websiteURL: String = "https://"
    @State private var websiteTitle: String = ""
    @State private var websiteEmoji: String = "🌐"
    @State private var websiteColorHex: String = "#FFF1EC"
    @State private var websiteSwitchExistingTab: Bool = true

    // Action flow editor sheet
    @State private var flowEditorSession: SlotFlowEditorSession?

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    private var pageTitle: String {
        guard coordinator.profile.pages.indices.contains(pageIndex) else { return "Page \(pageIndex + 1)" }
        return coordinator.profile.pages[pageIndex].title
    }

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

    private var isValidWebsiteDraft: Bool {
        let clean = websiteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "https://", clean != "http://" else { return false }
        let normalized = clean.contains("://") ? clean : "https://\(clean)"
        guard let url = URL(string: normalized), let host = url.host(), !host.isEmpty else {
            return false
        }
        return true
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
                case .flows:
                    flowsPickerBody
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
        .frame(width: 680, height: 560)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .tint(palette.accent)
        .preferredColorScheme(.light)
        .onAppear(perform: hydrateFromExisting)
        .sheet(item: $flowEditorSession) { session in
            MacFlowEditorSheet(
                coordinator: coordinator,
                initialFlow: session.flow,
                isNew: session.isNew
            ) { saved in
                coordinator.assignFlowToSlot(saved, pageIndex: pageIndex, slotIndex: slotIndex)
                dismiss()
            }
        }
    }

    private var headerBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("配置槽位 #\(slotIndex + 1)", "Configure Slot #\(slotIndex + 1)", language: lang))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Text(L10n.tr("第 \(pageIndex + 1) 页「\(pageTitle)」", "Page \(pageIndex + 1) · \"\(pageTitle)\"", language: lang))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }

                Spacer()

                if let existingItem {
                    HStack(spacing: 6) {
                        Text(L10n.tr("当前：", "Current:", language: lang))
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                        Text(existingItem.displayTitle(in: lang))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.barSurface, in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                } else {
                    Text(L10n.tr("空槽位", "Empty Slot", language: lang))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(palette.barSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                }
            }

            HStack(spacing: 6) {
                ForEach(PickerTab.allCases) { tab in
                    let isSel = (activeTab == tab)
                    Button {
                        activeTab = tab
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.sfSymbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isSel ? palette.accent : palette.secondaryText)
                            Text(tab.title(in: lang))
                                .font(.system(size: 12.5, weight: isSel ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isSel ? palette.primaryText : palette.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            isSel ? palette.tileFillTop : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isSel ? palette.accent.opacity(0.75) : .clear, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Tab 1: Mac Apps

    private var appsPickerBody: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(
                    L10n.tr("搜索本机应用（支持 ↑ ↓ 方向键与回车选择）…", "Search Mac apps (↑ ↓ arrows & Return to pick)…", language: lang),
                    text: $appSearchText
                )
                .textFieldStyle(.plain)
                .onChange(of: appSearchText) { _ in
                    highlightedAppIndex = 0
                }
                .onSubmit {
                    if filteredApps.indices.contains(highlightedAppIndex) {
                        selectApp(filteredApps[highlightedAppIndex])
                    }
                }

                if !appSearchText.isEmpty {
                    Button {
                        appSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    chooseAppViaFinderPanel()
                } label: {
                    Label(L10n.tr("从访达选择…", "Browse Finder…", language: lang), systemImage: "folder")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            .padding(.horizontal, 18)
            .padding(.top, 12)

            if coordinator.isScanningCatalog && coordinator.installedApps.isEmpty {
                Spacer()
                ProgressView(L10n.tr("正在扫描本机已安装应用…", "Scanning installed Mac apps…", language: lang))
                    .tint(palette.accent)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
            } else if filteredApps.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 32))
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("未找到匹配的应用", "No Matching Apps", language: lang))
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Text(L10n.tr("尝试缩短关键词，或从访达中手动选择任意 .app 应用包。", "Try another search term, or pick any .app bundle from Finder.", language: lang))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                    HStack(spacing: 8) {
                        if !appSearchText.isEmpty {
                            Button(L10n.tr("清空搜索词", "Clear Search", language: lang)) {
                                appSearchText = ""
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(L10n.tr("从访达选择…", "Browse Finder…", language: lang)) {
                            chooseAppViaFinderPanel()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                        .foregroundStyle(palette.accentForeground)
                    }
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List(Array(filteredApps.enumerated()), id: \.element.bundleIdentifier) { idx, app in
                        let isCurrent = (existingItem?.bundleIdentifier == app.bundleIdentifier)
                        Button {
                            selectApp(app)
                        } label: {
                            HStack(spacing: 12) {
                                DataImageView(pngData: app.iconPNGData, fallbackSymbol: "app.fill", tint: palette.secondaryText)
                                    .frame(width: 34, height: 34)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(app.appName)
                                            .font(.system(.body, design: .rounded, weight: .semibold))
                                            .foregroundStyle(palette.primaryText)
                                        if isCurrent {
                                            Text(L10n.tr("当前已选", "Current", language: lang))
                                                .font(.caption2.bold())
                                                .foregroundStyle(palette.statusConnected)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(palette.statusConnected.opacity(0.16), in: Capsule())
                                        }
                                    }
                                    Text(app.bundleIdentifier)
                                        .font(.caption2)
                                        .foregroundStyle(palette.secondaryText)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if idx == highlightedAppIndex {
                                    Text("⏎")
                                        .font(.caption.bold())
                                        .foregroundStyle(palette.primaryText)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(palette.tileFillTop, in: Capsule())
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                idx == highlightedAppIndex
                                    ? palette.accent.opacity(0.18)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(idx == highlightedAppIndex ? palette.accent.opacity(0.75) : .clear, lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(palette.barSurface.opacity(0.6))
                        .id(idx)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(
                        AppPickerKeyMonitor(
                            onUp: {
                                if highlightedAppIndex > 0 {
                                    highlightedAppIndex -= 1
                                    proxy.scrollTo(highlightedAppIndex, anchor: .center)
                                }
                            },
                            onDown: {
                                if highlightedAppIndex + 1 < filteredApps.count {
                                    highlightedAppIndex += 1
                                    proxy.scrollTo(highlightedAppIndex, anchor: .center)
                                }
                            },
                            onReturn: {
                                guard filteredApps.indices.contains(highlightedAppIndex) else {
                                    return false
                                }
                                selectApp(filteredApps[highlightedAppIndex])
                                return true
                            }
                        )
                    )
                }
            }
        }
    }

    // MARK: - Tab 1B: Composable Action Flows

    private var flowsPickerBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(L10n.tr("选择已保存的动作流，或新建一个多步动作流放入此槽位", "Pick a saved flow or create a multi-step flow for this slot", language: lang))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)

                Spacer()

                Menu {
                    Button {
                        let blank = ActionFlow(
                            name: L10n.tr("新建动作流", "New Flow", language: lang),
                            emoji: "⚡️",
                            backgroundHex: "#ECFAFE",
                            steps: []
                        )
                        flowEditorSession = SlotFlowEditorSession(flow: blank, isNew: true)
                    } label: {
                        Label(L10n.tr("空白动作流…", "Blank Flow…", language: lang), systemImage: "plus")
                    }

                    Button {
                        let app = coordinator.installedApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
                            ?? coordinator.installedApps.first
                        let tpl = ActionFlow.makeOpenWaitMaximizeTemplate(
                            bundleIdentifier: app?.bundleIdentifier ?? "com.apple.Safari",
                            appName: app?.appName ?? "Safari",
                            appPath: app?.appPath,
                            language: lang
                        )
                        flowEditorSession = SlotFlowEditorSession(flow: tpl, isNew: true)
                    } label: {
                        Label(L10n.tr("模板：打开应用 → 等待前置 → 最大化", "Template: Open → Wait → Maximize", language: lang), systemImage: "arrow.up.left.and.arrow.down.right")
                    }

                    Button {
                        let left = coordinator.installedApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
                            ?? coordinator.installedApps.first
                        let right = coordinator.installedApps.first(where: {
                            $0.bundleIdentifier == "com.apple.Notes" && $0.bundleIdentifier != left?.bundleIdentifier
                        }) ?? coordinator.installedApps.dropFirst().first
                        let tpl = ActionFlow.makeSplitScreenTemplate(
                            leftBundleIdentifier: left?.bundleIdentifier ?? "com.apple.Safari",
                            leftAppName: left?.appName ?? "Safari",
                            leftAppPath: left?.appPath,
                            rightBundleIdentifier: right?.bundleIdentifier ?? "com.apple.Notes",
                            rightAppName: right?.appName ?? "Notes",
                            rightAppPath: right?.appPath,
                            language: lang
                        )
                        flowEditorSession = SlotFlowEditorSession(flow: tpl, isNew: true)
                    } label: {
                        Label(L10n.tr("模板：双应用左右分屏", "Template: Left & Right Split", language: lang), systemImage: "rectangle.split.2x1")
                    }
                } label: {
                    Label(L10n.tr("新建动作流…", "New Flow…", language: lang), systemImage: "plus")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            if coordinator.profile.flows.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 32))
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("暂无已保存的动作流", "No Saved Flows Yet", language: lang))
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Text(L10n.tr("点击右上角「新建动作流…」可创建单应用全屏或双应用分屏等顺序动作流。", "Click \"New Flow…\" above to create sequential multi-step Mac actions.", language: lang))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(Array(coordinator.profile.flows.enumerated()), id: \.element.id) { idx, flow in
                    let isCurrent = (existingItem?.flowID == flow.id)
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ChocSwatch.resolvedTileColor(hex: flow.backgroundHex, fallbackHex: "#ECFAFE"))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                                )
                            Text(flow.emoji.isEmpty ? "⚡️" : flow.emoji)
                                .font(.system(size: 18))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(flow.name)
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                    .foregroundStyle(palette.primaryText)
                                if isCurrent {
                                    Text(L10n.tr("当前已选", "Current", language: lang))
                                        .font(.caption2.bold())
                                        .foregroundStyle(palette.statusConnected)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(palette.statusConnected.opacity(0.16), in: Capsule())
                                }
                            }
                            Text(
                                L10n.tr(
                                    "\(flow.enabledStepCount) 步 · \(flow.steps.map { $0.displayTitle(in: lang) }.joined(separator: " → "))",
                                    "\(flow.enabledStepCount) steps · \(flow.steps.map { $0.displayTitle(in: lang) }.joined(separator: " → "))",
                                    language: lang
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            coordinator.moveFlow(from: idx, to: idx - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(idx == 0)

                        Button {
                            coordinator.moveFlow(from: idx, to: idx + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(idx + 1 >= coordinator.profile.flows.count)

                        Button {
                            flowEditorSession = SlotFlowEditorSession(flow: flow, isNew: false)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)

                        Button(role: .destructive) {
                            coordinator.deleteFlow(id: flow.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)

                        Button(L10n.tr("放入槽位", "Assign", language: lang)) {
                            coordinator.assignFlowToSlot(flow, pageIndex: pageIndex, slotIndex: slotIndex)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.accent)
                        .foregroundStyle(palette.accentForeground)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(palette.barSurface.opacity(0.6))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Tab 2: Apple Shortcuts

    private var shortcutsPickerBody: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.tr("本机快捷指令", "Installed Mac Shortcuts", language: lang))
                        .font(.subheadline.bold())
                    Spacer()
                    Button {
                        coordinator.refreshCatalog()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.tr("刷新快捷指令列表", "Refresh Shortcuts", language: lang))
                }

                TextField(L10n.tr("筛选快捷指令…", "Filter Shortcuts…", language: lang), text: $shortcutSearchText)
                    .textFieldStyle(.roundedBorder)

                if coordinator.isScanningCatalog && coordinator.installedShortcuts.isEmpty {
                    VStack {
                        Spacer()
                        ProgressView(L10n.tr("读取快捷指令列表…", "Loading Shortcuts…", language: lang))
                            .controlSize(.small)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if filteredShortcuts.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text(
                            coordinator.installedShortcuts.isEmpty
                                ? L10n.tr("暂未读取到快捷指令", "No Mac Shortcuts Found", language: lang)
                                : L10n.tr("无匹配的快捷指令", "No Matching Shortcuts", language: lang)
                        )
                        .font(.caption.weight(.bold))
                        Text(L10n.tr("可在右侧直接输入快捷指令名称，或打开系统「快捷指令」创建。", "Enter any Shortcut name on the right, or create one in macOS Shortcuts.", language: lang))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(L10n.tr("打开「快捷指令」应用", "Open Shortcuts App", language: lang)) {
                            let url = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    List(filteredShortcuts) { item in
                        Button {
                            shortcutName = item.name
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(palette.secondaryText)
                                Text(item.name)
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(1)
                                Spacer()
                                if shortcutName == item.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(palette.accent)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(palette.barSurface)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                }
            }
            .frame(width: 270)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.tr("快捷指令方块预览", "Shortcut Tile Preview", language: lang))
                    .font(.subheadline.bold())
                    .foregroundStyle(palette.primaryText)

                HStack {
                    Spacer()
                    ChocBarTileCard(
                        item: BarItem(kind: .shortcut(
                            shortcutName: shortcutName.isEmpty ? "Morning Workflow" : shortcutName,
                            emoji: shortcutEmoji,
                            backgroundHex: shortcutColorHex
                        )),
                        iconData: nil,
                        palette: palette,
                        language: lang
                    )
                    .frame(width: 112, height: 112)
                    Spacer()
                }

                LabeledContent(L10n.tr("指令名称", "Shortcut Name", language: lang)) {
                    TextField("Morning Workflow", text: $shortcutName)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.tr("顶部图标", "Emoji", language: lang)) {
                    HStack(spacing: 5) {
                        TextField("⚡️", text: $shortcutEmoji)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        ForEach(["⚡️", "🔮", "📝", "☕️", "🎵", "🚀", "🧠", "🍫"], id: \.self) { em in
                            Button {
                                shortcutEmoji = em
                            } label: {
                                Text(em)
                                    .frame(width: 26, height: 26)
                                    .background(
                                        shortcutEmoji == em ? palette.accent.opacity(0.20) : palette.barSurface,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(shortcutEmoji == em ? palette.accent : palette.subtleCardStroke, lineWidth: 1)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("方块配色", "Tile Color", language: lang))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
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
                    .tint(palette.accentEmphasis)
                    .foregroundStyle(palette.emphasisForeground)
                    .disabled(shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(18)
    }

    // MARK: - Tab 3: Website Bookmark

    private var websitePickerBody: some View {
        HStack(spacing: 20) {
            VStack(spacing: 12) {
                Text(L10n.tr("实时预览", "Live Tile Preview", language: lang))
                    .font(.caption.weight(.semibold))
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
                    palette: palette,
                    language: lang
                )
                .frame(width: 122, height: 122)

                Text(L10n.tr("常用网站快填", "Quick Presets", language: lang))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                VStack(spacing: 6) {
                    presetWebsiteButton(title: "YouTube", url: "https://www.youtube.com", emoji: "▶️", hex: "#FFF1EC")
                    presetWebsiteButton(title: "GitHub", url: "https://github.com", emoji: "🐙", hex: "#EDF6FF")
                    presetWebsiteButton(title: "Figma", url: "https://www.figma.com", emoji: "🎨", hex: "#FFF6E3")
                    presetWebsiteButton(title: "Notion", url: "https://www.notion.so", emoji: "📓", hex: "#F3EEFF")
                }
            }
            .frame(width: 180)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                LabeledContent(L10n.tr("网址 URL", "Website URL", language: lang)) {
                    TextField("https://example.com", text: $websiteURL)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.tr("显示名称", "Display Title", language: lang)) {
                    TextField(L10n.tr("留空则自动提取域名", "Optional (auto-uses domain)", language: lang), text: $websiteTitle)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent(L10n.tr("图标 Emoji", "Icon Emoji", language: lang)) {
                    HStack(spacing: 5) {
                        TextField("🌐", text: $websiteEmoji)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        ForEach(["🌐", "▶️", "🐙", "🎨", "📓", "📰", "💬", "🛒"], id: \.self) { em in
                            Button {
                                websiteEmoji = em
                            } label: {
                                Text(em)
                                    .frame(width: 26, height: 26)
                                    .background(
                                        websiteEmoji == em ? palette.accent.opacity(0.20) : palette.barSurface,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(websiteEmoji == em ? palette.accent : palette.subtleCardStroke, lineWidth: 1)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Toggle(
                    L10n.tr("若已在 Safari / Chrome / Arc 打开则直接切换到该标签页", "Switch to existing tab if already open in Safari / Chrome / Arc", language: lang),
                    isOn: $websiteSwitchExistingTab
                )
                .font(.callout)
                .tint(palette.accent)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("方块配色", "Tile Color", language: lang))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                    swatchRow(selection: $websiteColorHex)
                }

                Spacer()

                HStack {
                    if !isValidWebsiteDraft && websiteURL != "https://" {
                        Text(L10n.tr("请输入有效的网址域名", "Enter a valid website address", language: lang))
                            .font(.caption)
                            .foregroundStyle(palette.statusFailure)
                    }
                    Spacer()
                    Button(L10n.tr("保存网页书签到槽位", "Save Website to Slot", language: lang)) {
                        let raw = websiteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let cleanURL = raw.contains("://") ? raw : "https://\(raw)"
                        let derivedTitle: String = {
                            let t = websiteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !t.isEmpty { return t }
                            return URL(string: cleanURL)?.host()?.replacingOccurrences(of: "www.", with: "") ?? cleanURL
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
                    .tint(palette.accentEmphasis)
                    .foregroundStyle(palette.emphasisForeground)
                    .disabled(!isValidWebsiteDraft)
                }
            }
        }
        .padding(18)
    }

    // MARK: - Tab 4: Categorized System Quick Actions

    private var actionsPickerBody: some View {
        let groups: [(String, [SystemQuickAction])] = [
            (
                L10n.tr("窗口分屏与布局", "Window Layout & Sizing", language: lang),
                [.maximizeWindow, .minimizeWindow, .snapWindowLeft, .snapWindowRight, .centerWindow, .toggleFullscreen]
            ),
            (
                L10n.tr("编辑与剪贴板", "Clipboard & Editing", language: lang),
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

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.0) { groupTitle, actions in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(groupTitle)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 9) {
                            ForEach(actions) { action in
                                let isCurrent: Bool = {
                                    if case .systemAction(let cur, _, _) = existingItem?.kind {
                                        return cur == action
                                    }
                                    return false
                                }()

                                Button {
                                    let item = BarItem(kind: .systemAction(action: action))
                                    coordinator.setSlotItem(item, pageIndex: pageIndex, slotIndex: slotIndex)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: action.sfSymbol)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(palette.primaryText)
                                            .frame(width: 32, height: 32)
                                            .background(ChocSwatch.resolvedTileColor(hex: action.accentHex), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        Text(action.title(in: lang))
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(palette.primaryText)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                        if isCurrent {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(palette.accent)
                                        }
                                    }
                                    .padding(9)
                                    .background(
                                        isCurrent ? palette.tileFillTop : palette.barSurface,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(isCurrent ? palette.accent : palette.subtleCardStroke, lineWidth: isCurrent ? 1.5 : 1)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(18)
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
                        .foregroundStyle(palette.statusFailure)
                }
            }

            Spacer()

            Button(L10n.tr("取消", "Cancel", language: lang)) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
            HStack(spacing: 7) {
                Text(emoji)
                Text(title)
                    .font(.caption.bold())
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func swatchRow(selection: Binding<String>) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
            ForEach(ChocSwatch.tileColors, id: \.self) { hex in
                let isSel = (selection.wrappedValue.uppercased() == hex.uppercased())
                Button {
                    selection.wrappedValue = hex
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle()
                                    .strokeBorder(isSel ? palette.accent : palette.subtleCardStroke, lineWidth: isSel ? 2.5 : 1.0)
                            )
                        if isSel {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(palette.primaryText)
                        }
                    }
                    .contentShape(Circle())
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
        case .flow:
            activeTab = .flows
        }
    }
}

private struct SlotFlowEditorSession: Identifiable {
    let id = UUID()
    let flow: ActionFlow
    let isNew: Bool
}

private struct AppPickerKeyMonitor: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
    let onReturn: () -> Bool

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView()
        view.onUp = onUp
        view.onDown = onDown
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ view: KeyMonitorView, context: Context) {
        view.onUp = onUp
        view.onDown = onDown
        view.onReturn = onReturn
    }
}

private final class KeyMonitorView: NSView {
    var onUp: () -> Void = {}
    var onDown: () -> Void = {}
    var onReturn: () -> Bool = { false }
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  window.isKeyWindow,
                  event.window === window else {
                return event
            }
            let disallowed: NSEvent.ModifierFlags = [.command, .option, .control]
            guard event.modifierFlags.intersection(disallowed).isEmpty else {
                return event
            }
            if let textInput = window.firstResponder as? NSTextInputClient,
               textInput.hasMarkedText() {
                return event
            }
            switch event.keyCode {
            case 126: // Up arrow
                self.onUp()
                return nil
            case 125: // Down arrow
                self.onDown()
                return nil
            case 36, 76: // Return / Keypad Enter
                return self.onReturn() ? nil : event
            default:
                return event
            }
        }
    }

    override func removeFromSuperview() {
        removeMonitor()
        super.removeFromSuperview()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
