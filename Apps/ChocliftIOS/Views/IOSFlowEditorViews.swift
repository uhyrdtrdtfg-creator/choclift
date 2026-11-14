import AVFAudio
import ChocliftCore
import Speech
import SwiftUI

// MARK: - Standalone Flows Manager Sheet (iPhone & iPad)

public struct IOSFlowsManagerSheet: View {
    @ObservedObject var client: CompanionClientEngine
    let defaultPageIndex: Int
    @Environment(\.dismiss) private var dismiss

    @State private var editingSession: IOSFlowEditSession?
    @State private var placingFlow: ActionFlow?
    @State private var selectedPageIndex: Int = 0
    @State private var selectedSlotIndex: Int = 0

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine, defaultPageIndex: Int = 0) {
        self.client = client
        self.defaultPageIndex = defaultPageIndex
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                IOSSentenceFlowProposalCard(client: client)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                if client.controlStripState.shouldShowDisplayPicker {
                    HStack(spacing: 8) {
                        Text(L10n.tr("贴靠与分屏目标屏幕", "Target Display for Snap & Split", language: lang))
                            .font(ChocType.caption)
                            .foregroundStyle(palette.secondaryText)
                        Spacer()
                        IOSDisplayTargetPickerMenu(client: client, compact: false)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                IOSFlowsListContent(
                    client: client,
                    targetSlot: nil,
                    onSelectForSlot: nil,
                    onRequestEdit: { session in
                        editingSession = session
                    },
                    onRequestPlaceInSlot: { flow in
                        selectedPageIndex = min(max(0, defaultPageIndex), max(0, client.profile.pages.count - 1))
                        selectedSlotIndex = firstEmptySlot(in: selectedPageIndex) ?? 0
                        placingFlow = flow
                    }
                )
            }
            .background(
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle(L10n.tr("动作流 (Flows)", "Action Flows", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("完成", "Done", language: lang)) {
                        dismiss()
                    }
                    .foregroundStyle(palette.secondaryText)
                }
                ToolbarItem(placement: .primaryAction) {
                    newFlowMenu
                }
            }
            .onAppear {
                client.requestMacCatalog()
            }
            .sheet(item: $editingSession) { session in
                IOSFlowEditorSheet(
                    client: client,
                    initialFlow: session.flow,
                    isNew: session.isNew
                ) { saved in
                    saveFlowToProfile(saved)
                }
            }
            .sheet(item: $placingFlow) { flow in
                placeInSlotSheet(for: flow)
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
    }

    private var newFlowMenu: some View {
        Menu {
            Button {
                let draft = ActionFlow(
                    name: L10n.tr("新建动作流", "New Flow", language: lang),
                    emoji: "⚡️",
                    backgroundHex: "#ECFAFE",
                    steps: []
                )
                editingSession = IOSFlowEditSession(flow: draft, isNew: true)
            } label: {
                Label(L10n.tr("空白动作流…", "Blank Flow…", language: lang), systemImage: "plus")
            }

            Button {
                let preferred = client.macCatalogApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
                    ?? client.macCatalogApps.first
                let draft = ActionFlow.makeOpenWaitMaximizeTemplate(
                    bundleIdentifier: preferred?.bundleIdentifier ?? "com.apple.Safari",
                    appName: preferred?.appName ?? "Safari",
                    appPath: preferred?.appPath,
                    language: lang
                )
                editingSession = IOSFlowEditSession(flow: draft, isNew: true)
            } label: {
                Label(
                    L10n.tr("模板：打开应用 → 等待前置 → 最大化", "Template: Open → Wait → Maximize", language: lang),
                    systemImage: "arrow.up.left.and.arrow.down.right"
                )
            }

            Button {
                let left = client.macCatalogApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
                    ?? client.macCatalogApps.first
                let right = client.macCatalogApps.first(where: {
                    $0.bundleIdentifier == "com.apple.Notes" && $0.bundleIdentifier != left?.bundleIdentifier
                }) ?? client.macCatalogApps.dropFirst().first
                let draft = ActionFlow.makeSplitScreenTemplate(
                    leftBundleIdentifier: left?.bundleIdentifier ?? "com.apple.Safari",
                    leftAppName: left?.appName ?? "Safari",
                    leftAppPath: left?.appPath,
                    rightBundleIdentifier: right?.bundleIdentifier ?? "com.apple.Notes",
                    rightAppName: right?.appName ?? "Notes",
                    rightAppPath: right?.appPath,
                    language: lang
                )
                editingSession = IOSFlowEditSession(flow: draft, isNew: true)
            } label: {
                Label(
                    L10n.tr("模板：双应用左右分屏", "Template: Left & Right Split", language: lang),
                    systemImage: "rectangle.split.2x1"
                )
            }
        } label: {
            Label(L10n.tr("新建", "New", language: lang), systemImage: "plus")
        }
    }

    private func placeInSlotSheet(for flow: ActionFlow) -> some View {
        NavigationStack {
            Form {
                Section(L10n.tr("选择要放置的巧克力栏位置", "Choose Chocolate Bar Destination", language: lang)) {
                    Picker(L10n.tr("页面", "Page", language: lang), selection: $selectedPageIndex) {
                        ForEach(Array(client.profile.pages.enumerated()), id: \.offset) { idx, page in
                            Text("\(page.iconEmoji) \(idx + 1). \(page.title)").tag(idx)
                        }
                    }

                    Picker(L10n.tr("槽位", "Slot", language: lang), selection: $selectedSlotIndex) {
                        ForEach(0..<BarPage.slotsPerPage, id: \.self) { sIdx in
                            let label = client.profile.pages.indices.contains(selectedPageIndex)
                                ? client.profile.pages[selectedPageIndex].slots[sIdx]?.displayTitle(in: lang)
                                : nil
                            let suffix = label.map { " (\($0))" } ?? L10n.tr(" (空)", " (Empty)", language: lang)
                            Text("#\(sIdx + 1)\(suffix)").tag(sIdx)
                        }
                    }
                }
                .listRowBackground(palette.barSurface)

                Section {
                    Button {
                        var updated = client.profile
                        updated.upsertFlow(flow)
                        if updated.pages.indices.contains(selectedPageIndex),
                           updated.pages[selectedPageIndex].slots.indices.contains(selectedSlotIndex) {
                            let existingID = updated.pages[selectedPageIndex].slots[selectedSlotIndex]?.id ?? UUID()
                            updated.pages[selectedPageIndex].slots[selectedSlotIndex] = updated.makeBarItem(for: flow, id: existingID)
                            client.pushUpdatedProfile(updated)
                        }
                        placingFlow = nil
                    } label: {
                        Label(
                            L10n.tr("放入此槽位", "Place Flow in Slot", language: lang),
                            systemImage: "square.grid.2x2.fill"
                        )
                        .font(ChocType.body.weight(.semibold))
                        .foregroundStyle(palette.accentEmphasis)
                    }
                }
                .listRowBackground(palette.barSurface)
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle(flow.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "Cancel", language: lang)) {
                        placingFlow = nil
                    }
                    .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
        .presentationDetents([.medium])
    }

    private func firstEmptySlot(in pageIdx: Int) -> Int? {
        guard client.profile.pages.indices.contains(pageIdx) else { return nil }
        return client.profile.pages[pageIdx].slots.firstIndex(where: { $0 == nil })
    }

    private func saveFlowToProfile(_ flow: ActionFlow) {
        var updated = client.profile
        var normalized = flow
        normalized.updatedAt = Date()
        updated.upsertFlow(normalized)
        client.pushUpdatedProfile(updated)
    }
}

// MARK: - Embedded Slot Tab View inside IOSSlotEditorSheet

public struct IOSFlowsSlotTabView: View {
    @ObservedObject var client: CompanionClientEngine
    let pageIndex: Int
    let slotIndex: Int
    let onAssignedToSlot: (ActionFlow) -> Void

    @State private var editingSession: IOSFlowEditSession?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        pageIndex: Int,
        slotIndex: Int,
        onAssignedToSlot: @escaping (ActionFlow) -> Void
    ) {
        self.client = client
        self.pageIndex = pageIndex
        self.slotIndex = slotIndex
        self.onAssignedToSlot = onAssignedToSlot
    }

    public var body: some View {
        VStack(spacing: 0) {
            IOSSentenceFlowProposalCard(client: client)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

            HStack {
                Text(L10n.tr("轻点动作流即可放入当前槽位", "Tap a flow to place it in Slot #\(slotIndex + 1)", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Menu {
                    Button {
                        let draft = ActionFlow(
                            name: L10n.tr("新建动作流", "New Flow", language: lang),
                            emoji: "⚡️",
                            backgroundHex: "#ECFAFE",
                            steps: []
                        )
                        editingSession = IOSFlowEditSession(flow: draft, isNew: true)
                    } label: {
                        Label(L10n.tr("空白动作流…", "Blank Flow…", language: lang), systemImage: "plus")
                    }

                    Button {
                        let app = client.macCatalogApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
                            ?? client.macCatalogApps.first
                        let tpl = ActionFlow.makeOpenWaitMaximizeTemplate(
                            bundleIdentifier: app?.bundleIdentifier ?? "com.apple.Safari",
                            appName: app?.appName ?? "Safari",
                            appPath: app?.appPath,
                            language: lang
                        )
                        editingSession = IOSFlowEditSession(flow: tpl, isNew: true)
                    } label: {
                        Label(L10n.tr("模板：打开 → 等待前置 → 最大化", "Template: Open → Wait → Maximize", language: lang), systemImage: "arrow.up.left.and.arrow.down.right")
                    }

                    Button {
                        let left = client.macCatalogApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
                            ?? client.macCatalogApps.first
                        let right = client.macCatalogApps.first(where: {
                            $0.bundleIdentifier == "com.apple.Notes" && $0.bundleIdentifier != left?.bundleIdentifier
                        }) ?? client.macCatalogApps.dropFirst().first
                        let tpl = ActionFlow.makeSplitScreenTemplate(
                            leftBundleIdentifier: left?.bundleIdentifier ?? "com.apple.Safari",
                            leftAppName: left?.appName ?? "Safari",
                            leftAppPath: left?.appPath,
                            rightBundleIdentifier: right?.bundleIdentifier ?? "com.apple.Notes",
                            rightAppName: right?.appName ?? "Notes",
                            rightAppPath: right?.appPath,
                            language: lang
                        )
                        editingSession = IOSFlowEditSession(flow: tpl, isNew: true)
                    } label: {
                        Label(L10n.tr("模板：双应用左右分屏", "Template: Left & Right Split", language: lang), systemImage: "rectangle.split.2x1")
                    }
                } label: {
                    Label(L10n.tr("新建动作流", "New Flow", language: lang), systemImage: "plus.circle.fill")
                        .font(ChocType.body.weight(.semibold))
                        .foregroundStyle(palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if client.controlStripState.shouldShowDisplayPicker {
                HStack(spacing: 8) {
                    Text(L10n.tr("目标屏幕", "Target Display", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    IOSDisplayTargetPickerMenu(client: client, compact: false)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            IOSFlowsListContent(
                client: client,
                targetSlot: (pageIndex, slotIndex),
                onSelectForSlot: { flow in
                    onAssignedToSlot(flow)
                },
                onRequestEdit: { session in
                    editingSession = session
                },
                onRequestPlaceInSlot: nil
            )
        }
        .sheet(item: $editingSession) { session in
            IOSFlowEditorSheet(
                client: client,
                initialFlow: session.flow,
                isNew: session.isNew
            ) { saved in
                if session.isNew {
                    onAssignedToSlot(saved)
                } else {
                    var updated = client.profile
                    var normalized = saved
                    normalized.updatedAt = Date()
                    updated.upsertFlow(normalized)
                    client.pushUpdatedProfile(updated)
                }
            }
        }
    }
}

public struct IOSFlowEditSession: Identifiable {
    public let id = UUID()
    public let flow: ActionFlow
    public let isNew: Bool

    public init(flow: ActionFlow, isNew: Bool) {
        self.flow = flow
        self.isNew = isNew
    }
}

// MARK: - Shared Flows List with Reorder, Run, Edit & Delete

private struct IOSFlowsListContent: View {
    @ObservedObject var client: CompanionClientEngine
    let targetSlot: (Int, Int)?
    let onSelectForSlot: ((ActionFlow) -> Void)?
    let onRequestEdit: (IOSFlowEditSession) -> Void
    let onRequestPlaceInSlot: ((ActionFlow) -> Void)?

    @State private var deleteGate = DestructiveActionConfirmGate()
    @State private var flowConfirmGate = DestructiveActionConfirmGate()

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    var body: some View {
        if client.profile.flows.isEmpty {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "arrow.triangle.branch")
                    .font(ChocType.title)
                    .foregroundStyle(palette.accent)
                Text(L10n.tr("尚无动作流", "No Saved Flows Yet", language: lang))
                    .font(ChocType.title)
                    .foregroundStyle(palette.primaryText)
                Text(
                    L10n.tr(
                        "创建「打开应用 → 等待前置 → 最大化」或「双应用左右分屏」等顺序动作流，一键放置在触控栏上。",
                        "Create multi-step Mac flows such as Open + Wait Frontmost + Maximize or Left/Right Split Screen.",
                        language: lang
                    )
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

                HStack(spacing: 10) {
                    Button {
                        let app = client.macCatalogApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
                            ?? client.macCatalogApps.first
                        let tpl = ActionFlow.makeOpenWaitMaximizeTemplate(
                            bundleIdentifier: app?.bundleIdentifier ?? "com.apple.Safari",
                            appName: app?.appName ?? "Safari",
                            appPath: app?.appPath,
                            language: lang
                        )
                        onRequestEdit(IOSFlowEditSession(flow: tpl, isNew: true))
                    } label: {
                        Text(L10n.tr("示例 1：前置最大化", "Example 1: Maximize", language: lang))
                            .font(ChocType.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .foregroundStyle(palette.accentForeground)

                    Button {
                        let left = client.macCatalogApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
                            ?? client.macCatalogApps.first
                        let right = client.macCatalogApps.first(where: {
                            $0.bundleIdentifier == "com.apple.Notes" && $0.bundleIdentifier != left?.bundleIdentifier
                        }) ?? client.macCatalogApps.dropFirst().first
                        let tpl = ActionFlow.makeSplitScreenTemplate(
                            leftBundleIdentifier: left?.bundleIdentifier ?? "com.apple.Safari",
                            leftAppName: left?.appName ?? "Safari",
                            leftAppPath: left?.appPath,
                            rightBundleIdentifier: right?.bundleIdentifier ?? "com.apple.Notes",
                            rightAppName: right?.appName ?? "Notes",
                            rightAppPath: right?.appPath,
                            language: lang
                        )
                        onRequestEdit(IOSFlowEditSession(flow: tpl, isNew: true))
                    } label: {
                        Text(L10n.tr("示例 2：左右分屏", "Example 2: Split", language: lang))
                            .font(ChocType.caption)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
        } else {
            List {
                ForEach(Array(client.profile.flows.enumerated()), id: \.element.id) { idx, flow in
                    let badgeFill = ChocSwatch.resolvedTileColor(hex: flow.backgroundHex, fallbackHex: "#ECFAFE")
                    HStack(spacing: 12) {
                        Button {
                            if let onSelectForSlot {
                                onSelectForSlot(flow)
                            } else {
                                onRequestEdit(IOSFlowEditSession(flow: flow, isNew: false))
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(badgeFill)
                                        .frame(width: 40, height: 40)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                                        )
                                    Text(flow.emoji.isEmpty ? "⚡️" : flow.emoji)
                                        .font(ChocType.title)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(flow.name)
                                        .font(ChocType.body.weight(.semibold))
                                        .foregroundStyle(palette.primaryText)
                                    Text(
                                        flow.steps
                                            .filter(\.isEnabled)
                                            .map { stepSummaryTitle($0) }
                                            .joined(separator: " → ")
                                    )
                                    .font(ChocType.micro)
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(2)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 4)

                        if client.connectionState.isConnected,
                           flowConfirmGate.isArmed(
                               targetID: flow.id.uuidString,
                               at: ProcessInfo.processInfo.systemUptime
                           ) {
                            Button {
                                let decision = flowConfirmGate.registerTap(
                                    targetID: flow.id.uuidString,
                                    isDestructive: flow.requiresDestructiveConfirmation,
                                    at: ProcessInfo.processInfo.systemUptime
                                )
                                if decision == .confirmedRun || decision == .runImmediately {
                                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                    client.triggerFlow(id: flow.id)
                                }
                            } label: {
                                Text(L10n.tr("再点确认", "Tap Again", language: lang))
                                    .font(ChocType.micro)
                                    .foregroundStyle(palette.emphasisForeground)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(palette.statusFailure, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        if onSelectForSlot == nil {
                            Button {
                                let decision = flowConfirmGate.registerTap(targetID: flow.id.uuidString, isDestructive: flow.requiresDestructiveConfirmation, at: ProcessInfo.processInfo.systemUptime)
                                switch decision {
                                case .requireSecondTap: break
                                case .runImmediately, .confirmedRun: client.triggerFlow(id: flow.id)
                                }
                            } label: {
                                Image(systemName: "play.fill").frame(width: 44, height: 44)
                            }
                            .buttonStyle(.borderedProminent).tint(palette.accent)
                            .disabled(!client.connectionState.isConnected)
                            .accessibilityLabel(L10n.tr("运行动作流", "Run Flow", language: lang))
                        }

                        Menu {
                            if let onSelectForSlot {
                                Button {
                                    onSelectForSlot(flow)
                                } label: {
                                    Label(L10n.tr("放入此槽位", "Assign to Slot", language: lang), systemImage: "plus.square.on.square")
                                }
                            }

                            if let onRequestPlaceInSlot {
                                Button {
                                    onRequestPlaceInSlot(flow)
                                } label: {
                                    Label(L10n.tr("放入巧克力栏槽位…", "Place in Bar Slot…", language: lang), systemImage: "square.grid.2x2")
                                }
                            }

                            if client.connectionState.isConnected {
                                Button {
                                    let decision = flowConfirmGate.registerTap(
                                        targetID: flow.id.uuidString,
                                        isDestructive: flow.requiresDestructiveConfirmation,
                                        at: ProcessInfo.processInfo.systemUptime
                                    )
                                    switch decision {
                                    case .requireSecondTap:
                                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                        let delay = CompanionInteractionPolicy.destructiveConfirmWindowSeconds + 0.05
                                        Task { @MainActor in
                                            try? await Task.sleep(for: .seconds(delay))
                                            flowConfirmGate.expireIfNeeded(at: ProcessInfo.processInfo.systemUptime)
                                        }
                                    case .runImmediately, .confirmedRun:
                                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                        client.triggerFlow(id: flow.id)
                                    }
                                } label: {
                                    Label(L10n.tr("立即在 Mac 上运行", "Run on Mac Now", language: lang), systemImage: "play.fill")
                                }
                            }

                            Button {
                                onRequestEdit(IOSFlowEditSession(flow: flow, isNew: false))
                            } label: {
                                Label(L10n.tr("编辑动作流…", "Edit Flow…", language: lang), systemImage: "pencil")
                            }

                            if idx > 0 {
                                Button {
                                    moveFlow(from: idx, to: idx - 1)
                                } label: {
                                    Label(L10n.tr("上移", "Move Up", language: lang), systemImage: "arrow.up")
                                }
                            }

                            if idx + 1 < client.profile.flows.count {
                                Button {
                                    moveFlow(from: idx, to: idx + 1)
                                } label: {
                                    Label(L10n.tr("下移", "Move Down", language: lang), systemImage: "arrow.down")
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                deleteFlow(id: flow.id)
                            } label: {
                                Label(deleteGate.isArmed(targetID: flow.id.uuidString, at: ProcessInfo.processInfo.systemUptime) ? L10n.tr("再点确认删除", "Tap again to delete", language: lang) : L10n.tr("删除动作流", "Delete Flow", language: lang), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(ChocType.title)
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 44, height: 44)
                        }
                    }
                    .frame(minHeight: 60)
                    .padding(.vertical, 3)
                    .listRowBackground(palette.barSurface)
                }
                .onMove { offsets, destination in
                    var updated = client.profile
                    updated.moveFlows(fromOffsets: offsets, toOffset: destination)
                    client.pushUpdatedProfile(updated)
                }
                .onDelete { offsets in
                    let ids = offsets.compactMap { client.profile.flows.indices.contains($0) ? client.profile.flows[$0].id : nil }
                    for id in ids { deleteFlow(id: id) }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func moveFlow(from source: Int, to destination: Int) {
        var updated = client.profile
        updated.moveFlow(from: source, to: destination)
        client.pushUpdatedProfile(updated)
    }

    private func deleteFlow(id: UUID) {
        let decision = deleteGate.registerTap(targetID: id.uuidString, isDestructive: true, at: ProcessInfo.processInfo.systemUptime)
        if case .requireSecondTap = decision { return }
        var updated = client.profile
        _ = updated.deleteFlow(id: id)
        client.pushUpdatedProfile(updated)
    }

    private func stepSummaryTitle(_ step: ActionFlowStep) -> String {
        if case .insertSnippet(let snippetID, _) = step.kind,
           let live = client.profile.snippet(withID: snippetID) {
            let liveTitle = live.displayTitle(in: lang)
            return L10n.tr("插入片段「\(liveTitle)」", "Insert Snippet \"\(liveTitle)\"", language: lang)
        }
        return step.displayTitle(in: lang)
    }
}

// MARK: - Full Flow Editor Sheet (iPhone & iPad)

public struct IOSFlowEditorSheet: View {
    @ObservedObject var client: CompanionClientEngine
    let isNew: Bool
    let onCommit: (ActionFlow) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ActionFlow
    @State private var stepSession: IOSStepEditSession?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        initialFlow: ActionFlow,
        isNew: Bool,
        onCommit: @escaping (ActionFlow) -> Void
    ) {
        self.client = client
        self.isNew = isNew
        self.onCommit = onCommit
        self._draft = State(initialValue: initialFlow)
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("动作流外观与名称", "Flow Name & Tile", language: lang)) {
                    HStack {
                        Spacer()
                        ChocBarTileCard(
                            item: client.profile.makeBarItem(for: draft),
                            iconData: nil,
                            palette: palette,
                            language: lang
                        )
                        .frame(width: 96, height: 96)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)

                    TextField(L10n.tr("动作流名称", "Flow Name", language: lang), text: $draft.name)
                        .listRowBackground(palette.barSurface)

                    HStack {
                        Text("Emoji")
                            .foregroundStyle(palette.primaryText)
                        Spacer()
                        TextField("⚡️", text: $draft.emoji)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                        ForEach(["⚡️", "🪟", "🖥", "🚀", "🎯"], id: \.self) { em in
                            Button(em) { draft.emoji = em }
                                .buttonStyle(.bordered)
                        }
                    }
                    .listRowBackground(palette.barSurface)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ChocSwatch.tileColors, id: \.self) { hex in
                                let isSel = draft.backgroundHex.uppercased() == hex.uppercased()
                                Button {
                                    draft.backgroundHex = hex
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: hex))
                                            .frame(width: 30, height: 30)
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
                    .listRowBackground(palette.barSurface)
                }

                Section {
                    if draft.steps.isEmpty {
                        Text(L10n.tr("点击下方按钮按顺序添加步骤。若某一步执行失败，Mac 会立即停止并反馈失败步骤。", "Add ordered steps below. Execution halts immediately if any step fails.", language: lang))
                            .font(ChocType.caption)
                            .foregroundStyle(palette.secondaryText)
                            .listRowBackground(palette.barSurface)
                    } else {
                        ForEach(Array(draft.steps.enumerated()), id: \.element.id) { idx, step in
                            let resolvedText = resolvedStepText(for: step)
                            HStack(spacing: 10) {
                                Text("\(idx + 1)")
                                    .font(ChocType.micro)
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Color(hex: step.accentHex).opacity(step.isEnabled ? 1 : 0.4), in: Circle())

                                Image(systemName: resolvedText.isWarning ? "exclamationmark.triangle.fill" : step.sfSymbol)
                                    .font(ChocType.caption)
                                    .foregroundStyle(
                                        resolvedText.isWarning
                                            ? palette.statusFailure
                                            : Color(hex: step.accentHex).opacity(step.isEnabled ? 1 : 0.5)
                                    )
                                    .frame(width: 20)

                                Button {
                                    stepSession = IOSStepEditSession(
                                        step: step,
                                        defaultFollowBundleID: priorBundleID(before: idx)
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(resolvedText.title)
                                            .font(ChocType.body.weight(.semibold))
                                            .foregroundStyle(step.isEnabled ? palette.primaryText : palette.secondaryText)
                                            .strikethrough(!step.isEnabled)
                                        Text(resolvedText.subtitle)
                                            .font(ChocType.micro)
                                            .foregroundStyle(resolvedText.isWarning ? palette.statusFailure : palette.secondaryText)
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    guard idx > 0 else { return }
                                    let moved = draft.steps.remove(at: idx)
                                    draft.steps.insert(moved, at: idx - 1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                        .font(ChocType.caption)
                                }
                                .buttonStyle(.borderless)
                                .disabled(idx == 0)

                                Button {
                                    guard idx + 1 < draft.steps.count else { return }
                                    let moved = draft.steps.remove(at: idx)
                                    draft.steps.insert(moved, at: idx + 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .font(ChocType.caption)
                                }
                                .buttonStyle(.borderless)
                                .disabled(idx + 1 >= draft.steps.count)
                            }
                            .listRowBackground(palette.barSurface)
                        }
                        .onMove { offsets, destination in
                            let valid = offsets.filter { draft.steps.indices.contains($0) }
                            let moving = valid.map { draft.steps[$0] }
                            for i in valid.sorted(by: >) {
                                draft.steps.remove(at: i)
                            }
                            let adjusted = destination - valid.filter { $0 < destination }.count
                            draft.steps.insert(contentsOf: moving, at: min(max(0, adjusted), draft.steps.count))
                        }
                        .onDelete { offsets in
                            draft.steps.remove(atOffsets: offsets)
                        }
                    }

                    addStepMenuRow
                        .listRowBackground(palette.barSurface)
                } header: {
                    HStack {
                        Text(L10n.tr("顺序执行步骤", "Sequential Steps", language: lang))
                        Spacer()
                        EditButton()
                            .font(ChocType.caption)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle(
                isNew
                    ? L10n.tr("新建动作流", "New Flow", language: lang)
                    : L10n.tr("编辑动作流", "Edit Flow", language: lang)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "Cancel", language: lang)) {
                        dismiss()
                    }
                    .foregroundStyle(palette.secondaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("保存", "Save", language: lang)) {
                        var clean = draft
                        let trimmed = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        clean.name = trimmed.isEmpty ? L10n.tr("动作流", "Action Flow", language: lang) : trimmed
                        clean.emoji = clean.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "⚡️" : clean.emoji
                        clean.updatedAt = Date()
                        onCommit(clean)
                        dismiss()
                    }
                    .disabled(draft.steps.isEmpty || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(item: $stepSession) { session in
                IOSFlowStepEditorSheet(
                    client: client,
                    initialStep: session.step,
                    defaultFollowBundleID: session.defaultFollowBundleID
                ) { savedStep in
                    if let idx = draft.steps.firstIndex(where: { $0.id == savedStep.id }) {
                        draft.steps[idx] = savedStep
                    } else {
                        draft.steps.append(savedStep)
                    }
                }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
        .onAppear {
            client.requestMacCatalog()
        }
    }

    private var addStepMenuRow: some View {
        let followBundle = priorBundleID(before: draft.steps.count)
        let followName = priorAppName(before: draft.steps.count)
        return Menu {
            Button {
                let firstApp = client.macCatalogApps.first
                let step = ActionFlowStep(
                    kind: .launchOrActivateApp(
                        bundleIdentifier: firstApp?.bundleIdentifier ?? "com.apple.Safari",
                        appName: firstApp?.appName ?? "Safari",
                        appPath: firstApp?.appPath
                    )
                )
                stepSession = IOSStepEditSession(step: step, defaultFollowBundleID: followBundle)
            } label: {
                Label(L10n.tr("打开或激活 Mac 应用…", "Launch or Activate Mac App…", language: lang), systemImage: "app.badge.checkmark")
            }

            Button {
                let step = ActionFlowStep(
                    kind: .waitForAppFrontmost(
                        bundleIdentifier: followBundle ?? "",
                        appName: followName,
                        timeoutSeconds: ActionFlowStep.defaultTimeoutSeconds
                    )
                )
                stepSession = IOSStepEditSession(step: step, defaultFollowBundleID: followBundle)
            } label: {
                Label(L10n.tr("等待应用前置…", "Wait Until App Is Frontmost…", language: lang), systemImage: "macwindow.on.rectangle")
            }

            Button {
                let step = ActionFlowStep(
                    kind: .systemAction(
                        action: .maximizeWindow,
                        targetBundleIdentifier: followBundle,
                        targetAppName: followName
                    )
                )
                stepSession = IOSStepEditSession(step: step, defaultFollowBundleID: followBundle)
            } label: {
                Label(L10n.tr("执行窗口 / 系统快捷动作…", "Run Window or System Action…", language: lang), systemImage: "bolt.fill")
            }

            Button {
                let step = ActionFlowStep(kind: .delay(seconds: ActionFlowStep.defaultDelaySeconds))
                stepSession = IOSStepEditSession(step: step, defaultFollowBundleID: followBundle)
            } label: {
                Label(L10n.tr("固定短延时…", "Short Bounded Delay…", language: lang), systemImage: "timer")
            }

            Divider()

            Button {
                let step = ActionFlowStep(kind: .openWebsite(url: "", title: nil, switchExistingTab: true))
                stepSession = IOSStepEditSession(step: step, defaultFollowBundleID: followBundle)
            } label: {
                Label(L10n.tr("打开网页…", "Open Website…", language: lang), systemImage: "globe")
            }

            Button {
                let initialShortcut = client.macCatalogShortcuts.first?.name ?? ""
                let step = ActionFlowStep(kind: .runShortcut(shortcutName: initialShortcut))
                stepSession = IOSStepEditSession(step: step, defaultFollowBundleID: followBundle)
            } label: {
                Label(L10n.tr("运行 Mac 快捷指令…", "Run Mac Shortcut…", language: lang), systemImage: "sparkles.rectangle.stack")
            }

            Button {
                let firstSnippet = client.profile.snippets.first
                let step = ActionFlowStep(
                    kind: .insertSnippet(
                        snippetID: firstSnippet?.id ?? UUID(),
                        titleSnapshot: firstSnippet?.displayTitle(in: lang)
                    )
                )
                stepSession = IOSStepEditSession(step: step, defaultFollowBundleID: followBundle)
            } label: {
                Label(L10n.tr("插入文本片段…", "Insert Saved Snippet…", language: lang), systemImage: "text.quote")
            }
        } label: {
            Label(L10n.tr("添加步骤…", "Add Step…", language: lang), systemImage: "plus.circle.fill")
                .font(ChocType.body.weight(.semibold))
                .foregroundStyle(palette.accent)
        }
    }

    private func resolvedStepText(for step: ActionFlowStep) -> (title: String, subtitle: String, isWarning: Bool) {
        if case .insertSnippet(let snippetID, _) = step.kind {
            if let live = client.profile.snippet(withID: snippetID) {
                let liveTitle = live.displayTitle(in: lang)
                let title = L10n.tr("插入片段「\(liveTitle)」", "Insert Snippet \"\(liveTitle)\"", language: lang)
                let preview = live.singleLinePreview
                let subtitle = preview.isEmpty
                    ? live.insertMode.badgeTitle(in: lang)
                    : "\(live.insertMode.badgeTitle(in: lang)) · \(preview)"
                return (title, subtitle, false)
            }
            return (
                step.displayTitle(in: lang),
                L10n.tr("该文本片段已被删除，执行时此步骤将报错停止", "Snippet was deleted — this step will fail when run", language: lang),
                true
            )
        }
        return (step.displayTitle(in: lang), step.subtitle(in: lang), false)
    }

    private func priorBundleID(before index: Int) -> String? {
        for step in draft.steps.prefix(index).reversed() {
            if let bid = step.referencedBundleIdentifier {
                return bid
            }
        }
        return nil
    }

    private func priorAppName(before index: Int) -> String? {
        for step in draft.steps.prefix(index).reversed() {
            switch step.kind {
            case .launchOrActivateApp(_, let name, _):
                return name
            case .waitForAppFrontmost(_, let name, _):
                if let name, !name.isEmpty { return name }
            default:
                continue
            }
        }
        return nil
    }
}

private struct IOSStepEditSession: Identifiable {
    let id = UUID()
    let step: ActionFlowStep
    let defaultFollowBundleID: String?
}

// MARK: - Step Editor Sheet (iPhone & iPad)

public struct IOSFlowStepEditorSheet: View {
    public enum StepKindChoice: String, CaseIterable, Identifiable {
        case launchApp
        case waitFrontmost
        case systemAction
        case delay
        case openWebsite
        case runShortcut
        case insertSnippet

        public var id: String { rawValue }

        func title(in lang: AppLanguage) -> String {
            switch self {
            case .launchApp:
                return L10n.tr("打开应用", "Open App", language: lang)
            case .waitFrontmost:
                return L10n.tr("等待前置", "Wait Frontmost", language: lang)
            case .systemAction:
                return L10n.tr("系统动作", "Quick Action", language: lang)
            case .delay:
                return L10n.tr("延时", "Delay", language: lang)
            case .openWebsite:
                return L10n.tr("打开网页", "Open Website", language: lang)
            case .runShortcut:
                return L10n.tr("运行快捷指令", "Run Shortcut", language: lang)
            case .insertSnippet:
                return L10n.tr("插入文本片段", "Insert Snippet", language: lang)
            }
        }

        var sfSymbol: String {
            switch self {
            case .launchApp:
                return "app.badge.checkmark"
            case .waitFrontmost:
                return "macwindow.on.rectangle"
            case .systemAction:
                return "bolt.fill"
            case .delay:
                return "timer"
            case .openWebsite:
                return "globe"
            case .runShortcut:
                return "sparkles.rectangle.stack"
            case .insertSnippet:
                return "text.quote"
            }
        }
    }

    @ObservedObject var client: CompanionClientEngine
    let stepID: UUID
    @State private var stepEnabled: Bool
    let defaultFollowBundleID: String?
    let onSave: (ActionFlowStep) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var choice: StepKindChoice = .launchApp
    @State private var searchText: String = ""
    @State private var bundleID: String = "com.apple.Safari"
    @State private var appName: String = "Safari"
    @State private var appPath: String?

    @State private var waitFollowPrevious: Bool = false
    @State private var timeoutSeconds: Double = ActionFlowStep.defaultTimeoutSeconds
    @State private var delaySeconds: Double = ActionFlowStep.defaultDelaySeconds

    @State private var selectedAction: SystemQuickAction = .maximizeWindow
    @State private var actionFollowActiveFlowApp: Bool = true

    @State private var websiteURL: String = ""
    @State private var websiteTitle: String = ""
    @State private var websiteSwitchTab: Bool = true

    @State private var shortcutSearch: String = ""
    @State private var shortcutName: String = ""

    @State private var snippetSearch: String = ""
    @State private var selectedSnippetID: UUID?
    @State private var missingSnippetTitle: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var availableApps: [(bundleID: String, appName: String, appPath: String?, icon: Data?)] {
        var seen = Set<String>()
        var rows: [(String, String, String?, Data?)] = []

        for app in client.macCatalogApps where seen.insert(app.bundleIdentifier).inserted {
            rows.append((app.bundleIdentifier, app.appName, app.appPath, app.iconPNGData ?? client.appIconsByBundleID[app.bundleIdentifier] ?? BundledAppIcons.pngData(for: app.bundleIdentifier)))
        }
        for recent in client.recentApps where seen.insert(recent.bundleIdentifier).inserted {
            rows.append((recent.bundleIdentifier, recent.appName, recent.appPath, client.appIconsByBundleID[recent.bundleIdentifier] ?? BundledAppIcons.pngData(for: recent.bundleIdentifier)))
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.1.localizedCaseInsensitiveContains(q) || $0.0.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredShortcuts: [InstalledShortcutSummary] {
        let q = shortcutSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return client.macCatalogShortcuts }
        return client.macCatalogShortcuts.filter {
            $0.name.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredSnippets: [TextSnippet] {
        let q = snippetSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return client.profile.snippets }
        return client.profile.snippets.filter {
            $0.displayTitle(in: lang).localizedCaseInsensitiveContains(q) ||
            $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    public init(
        client: CompanionClientEngine,
        initialStep: ActionFlowStep,
        defaultFollowBundleID: String?,
        onSave: @escaping (ActionFlowStep) -> Void
    ) {
        self.client = client
        self.stepID = initialStep.id
        self._stepEnabled = State(initialValue: initialStep.isEnabled)
        self.defaultFollowBundleID = defaultFollowBundleID
        self.onSave = onSave

        switch initialStep.kind {
        case .launchOrActivateApp(let bid, let name, let path):
            _choice = State(initialValue: .launchApp)
            _bundleID = State(initialValue: bid)
            _appName = State(initialValue: name)
            _appPath = State(initialValue: path)

        case .waitForAppFrontmost(let bid, let name, let timeout):
            _choice = State(initialValue: .waitFrontmost)
            let trimmed = bid.trimmingCharacters(in: .whitespacesAndNewlines)
            _waitFollowPrevious = State(initialValue: trimmed.isEmpty)
            _bundleID = State(initialValue: trimmed.isEmpty ? (defaultFollowBundleID ?? "com.apple.Safari") : trimmed)
            _appName = State(initialValue: name ?? "")
            _timeoutSeconds = State(initialValue: ActionFlowStep.clampTimeout(timeout))

        case .systemAction(let act, let targetBid, let targetName):
            _choice = State(initialValue: .systemAction)
            _selectedAction = State(initialValue: act)
            let trimmed = targetBid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            _actionFollowActiveFlowApp = State(initialValue: trimmed.isEmpty)
            _bundleID = State(initialValue: trimmed.isEmpty ? (defaultFollowBundleID ?? "com.apple.Safari") : trimmed)
            _appName = State(initialValue: targetName ?? "")

        case .delay(let secs):
            _choice = State(initialValue: .delay)
            _delaySeconds = State(initialValue: ActionFlowStep.clampDelay(secs))

        case .openWebsite(let url, let title, let switchExistingTab):
            _choice = State(initialValue: .openWebsite)
            _websiteURL = State(initialValue: url)
            _websiteTitle = State(initialValue: title ?? "")
            _websiteSwitchTab = State(initialValue: switchExistingTab)

        case .runShortcut(let name):
            _choice = State(initialValue: .runShortcut)
            _shortcutName = State(initialValue: name)

        case .insertSnippet(let snippetID, let titleSnapshot):
            _choice = State(initialValue: .insertSnippet)
            if client.profile.snippet(withID: snippetID) != nil {
                _selectedSnippetID = State(initialValue: snippetID)
            } else {
                _selectedSnippetID = State(initialValue: nil)
                _missingSnippetTitle = State(initialValue: titleSnapshot)
            }

        case .unsupported:
            _choice = State(initialValue: .systemAction)
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L10n.tr("步骤类型", "Step Type", language: lang), selection: $choice) {
                        ForEach(StepKindChoice.allCases) { kind in
                            Label(kind.title(in: lang), systemImage: kind.sfSymbol)
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle(L10n.tr("启用此步骤", "Step Enabled", language: lang), isOn: $stepEnabled)
                        .tint(palette.accent)
                }
                .listRowBackground(palette.barSurface)

                switch choice {
                case .launchApp:
                    appSelectionSections
                case .waitFrontmost:
                    waitFrontmostSections
                case .systemAction:
                    systemActionSections
                case .delay:
                    delaySections
                case .openWebsite:
                    websiteSections
                case .runShortcut:
                    shortcutSections
                case .insertSnippet:
                    snippetSections
                }
            }
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle(L10n.tr("配置步骤", "Configure Step", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "Cancel", language: lang)) { dismiss() }
                        .foregroundStyle(palette.secondaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "Done", language: lang)) {
                        if let step = buildStep() {
                            onSave(step)
                            dismiss()
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                client.requestMacCatalog()
            }
            .onChange(of: choice) { _, newChoice in
                if newChoice == .insertSnippet, selectedSnippetID == nil, missingSnippetTitle == nil {
                    selectedSnippetID = client.profile.snippets.first?.id
                } else if newChoice == .runShortcut, shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    shortcutName = client.macCatalogShortcuts.first?.name ?? ""
                }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
    }

    private var canSave: Bool {
        switch choice {
        case .launchApp:
            return !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .waitFrontmost:
            return waitFollowPrevious || !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .systemAction:
            if selectedAction.targetsApplication && !actionFollowActiveFlowApp {
                return !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        case .delay:
            return delaySeconds >= ActionFlowStep.minDelaySeconds
        case .openWebsite:
            return ActionFlowStep.isValidWebsiteURL(websiteURL)
        case .runShortcut:
            return !shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .insertSnippet:
            guard let id = selectedSnippetID else { return false }
            return client.profile.snippet(withID: id) != nil
        }
    }

    @ViewBuilder
    private var appSelectionSections: some View {
        Section(L10n.tr("目标 Mac 应用", "Target Mac App", language: lang)) {
            TextField("com.apple.Safari", text: $bundleID)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField(L10n.tr("应用名称 (例如 Safari)", "App Name (e.g. Safari)", language: lang), text: $appName)
        }
        .listRowBackground(palette.barSurface)

        if !availableApps.isEmpty {
            Section(L10n.tr("从已同步的 Mac 应用中选取", "Pick from Mac Apps", language: lang)) {
                TextField(L10n.tr("搜索应用…", "Search apps…", language: lang), text: $searchText)
                ForEach(availableApps.prefix(40), id: \.bundleID) { row in
                    Button {
                        bundleID = row.bundleID
                        appName = row.appName
                        appPath = row.appPath
                    } label: {
                        HStack(spacing: 10) {
                            DataImageView(pngData: row.icon, fallbackSymbol: "app.fill", tint: palette.secondaryText)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.appName).foregroundStyle(palette.primaryText)
                                Text(row.bundleID).font(ChocType.micro).foregroundStyle(palette.secondaryText)
                            }
                            Spacer()
                            if bundleID == row.bundleID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(palette.statusConnected)
                            }
                        }
                    }
                }
            }
            .listRowBackground(palette.barSurface)
        }
    }

    @ViewBuilder
    private var waitFrontmostSections: some View {
        Section(L10n.tr("等待条件", "Frontmost Condition", language: lang)) {
            Toggle(L10n.tr("跟随上一步打开的应用", "Follow Previous Step's App", language: lang), isOn: $waitFollowPrevious)
                .tint(palette.accent)

            if !waitFollowPrevious {
                TextField("com.apple.Safari", text: $bundleID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(L10n.tr("应用名称", "App Name", language: lang), text: $appName)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.tr("超时上限", "Timeout", language: lang))
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    Text(ActionFlowStep.formatSeconds(timeoutSeconds))
                        .font(ChocType.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(palette.primaryText)
                }
                Slider(value: $timeoutSeconds, in: 0.2...ActionFlowStep.maxTimeoutSeconds, step: 0.2)
                    .tint(palette.accent)
            }
        }
        .listRowBackground(palette.barSurface)

        if !waitFollowPrevious && !availableApps.isEmpty {
            Section(L10n.tr("快速选取应用", "Pick App", language: lang)) {
                ForEach(availableApps.prefix(25), id: \.bundleID) { row in
                    Button {
                        bundleID = row.bundleID
                        appName = row.appName
                    } label: {
                        HStack {
                            Text(row.appName).foregroundStyle(palette.primaryText)
                            Spacer()
                            if bundleID == row.bundleID {
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

    @ViewBuilder
    private var systemActionSections: some View {
        Section(L10n.tr("选择系统快捷动作", "Select Mac Action", language: lang)) {
            Picker(L10n.tr("动作", "Action", language: lang), selection: $selectedAction) {
                ForEach(SystemQuickAction.allCases) { act in
                    Label(act.title(in: lang), systemImage: act.sfSymbol).tag(act)
                }
            }
        }
        .listRowBackground(palette.barSurface)

        if selectedAction.targetsApplication {
            Section(L10n.tr("目标窗口绑定", "Intended App Targeting", language: lang)) {
                Toggle(
                    L10n.tr("作用于当前动作流的目标应用", "Target Active App in Flow", language: lang),
                    isOn: $actionFollowActiveFlowApp
                )
                .tint(palette.accent)

                if !actionFollowActiveFlowApp {
                    TextField("com.apple.Safari", text: $bundleID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(L10n.tr("应用名称", "App Name", language: lang), text: $appName)
                } else {
                    Text(
                        L10n.tr(
                            "左半屏、右半屏与最大化会严格作用于目标应用窗口，绝不会误贴靠前一步的其它应用。",
                            "Window snaps strictly target the intended app in the flow rather than any leftover window.",
                            language: lang
                        )
                    )
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                }
            }
            .listRowBackground(palette.barSurface)
        }
    }

    @ViewBuilder
    private var delaySections: some View {
        Section(L10n.tr("固定短延时（最长 10 秒）", "Bounded Delay (Max 10s)", language: lang)) {
            HStack {
                Text(L10n.tr("等待时长", "Duration", language: lang))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Text(ActionFlowStep.formatSeconds(delaySeconds))
                    .font(ChocType.title.monospacedDigit())
                    .foregroundStyle(palette.primaryText)
            }
            Slider(value: $delaySeconds, in: 0.1...ActionFlowStep.maxDelaySeconds, step: 0.1)
                .tint(palette.accent)

            HStack {
                ForEach([0.2, 0.5, 1.0, 2.0, 3.0], id: \.self) { preset in
                    Button(ActionFlowStep.formatSeconds(preset)) {
                        delaySeconds = preset
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .listRowBackground(palette.barSurface)
    }

    @ViewBuilder
    private var websiteSections: some View {
        let trimmedURL = websiteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let showInvalidHint = !trimmedURL.isEmpty && !ActionFlowStep.isValidWebsiteURL(websiteURL)

        Section(L10n.tr("目标网页", "Target Website", language: lang)) {
            TextField("https://example.com", text: $websiteURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if showInvalidHint {
                Label(
                    L10n.tr("请输入包含有效域名的网址（如 example.com）", "Enter a valid website URL with a host (e.g. example.com)", language: lang),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(ChocType.micro)
                .foregroundStyle(palette.statusFailure)
            }

            TextField(L10n.tr("显示标题（可选）", "Display Title (Optional)", language: lang), text: $websiteTitle)

            Toggle(
                L10n.tr("智能切换到已打开的浏览器标签页", "Switch to Already-Open Browser Tab", language: lang),
                isOn: $websiteSwitchTab
            )
            .tint(palette.accent)
        }
        .listRowBackground(palette.barSurface)

        Section(L10n.tr("常用网页预设", "Quick Website Presets", language: lang)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(
                        [
                            ("GitHub", "https://github.com"),
                            ("Google", "https://www.google.com"),
                            ("ChatGPT", "https://chatgpt.com"),
                            ("Linear", "https://linear.app"),
                            ("localhost:3000", "http://localhost:3000")
                        ],
                        id: \.0
                    ) { preset in
                        Button(preset.0) {
                            websiteURL = preset.1
                            if websiteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                websiteTitle = preset.0
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listRowBackground(palette.barSurface)
    }

    @ViewBuilder
    private var shortcutSections: some View {
        Section(L10n.tr("Mac 快捷指令名称", "Mac Shortcut Name", language: lang)) {
            TextField(L10n.tr("输入已有快捷指令精确名称", "Exact Mac Shortcut name", language: lang), text: $shortcutName)
                .autocorrectionDisabled()

            Button {
                client.requestMacCatalog()
            } label: {
                Label(L10n.tr("刷新 Mac 快捷指令列表", "Refresh Mac Shortcuts", language: lang), systemImage: "arrow.clockwise")
                    .font(ChocType.caption)
            }
        }
        .listRowBackground(palette.barSurface)

        if !client.macCatalogShortcuts.isEmpty {
            Section(L10n.tr("从已同步的 Mac 快捷指令中选取", "Pick from Mac Shortcuts", language: lang)) {
                TextField(L10n.tr("搜索快捷指令…", "Filter shortcuts…", language: lang), text: $shortcutSearch)
                ForEach(filteredShortcuts) { sc in
                    Button {
                        shortcutName = sc.name
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .foregroundStyle(palette.accent)
                            Text(sc.name)
                                .foregroundStyle(palette.primaryText)
                            Spacer()
                            if shortcutName.trimmingCharacters(in: .whitespacesAndNewlines) == sc.name {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(palette.statusConnected)
                            }
                        }
                    }
                }
            }
            .listRowBackground(palette.barSurface)
        } else {
            Section {
                Text(
                    L10n.tr(
                        "连接 Mac 后会自动同步本机快捷指令列表；也可在上方直接填写快捷指令名称。",
                        "Connect to your Mac to browse installed Shortcuts, or type an existing Shortcut's exact name above.",
                        language: lang
                    )
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
            }
            .listRowBackground(palette.barSurface)
        }
    }

    @ViewBuilder
    private var snippetSections: some View {
        if let missingTitle = missingSnippetTitle, selectedSnippetID == nil {
            Section {
                Label(
                    L10n.tr(
                        "原有关联片段「\(missingTitle)」已被删除，请重新选择一个现有片段。",
                        "Previously selected snippet \"\(missingTitle)\" was deleted. Select an existing snippet below.",
                        language: lang
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.statusFailure)
            }
            .listRowBackground(palette.barSurface)
        }

        if client.profile.snippets.isEmpty {
            Section(L10n.tr("已保存的文本片段", "Saved Snippets", language: lang)) {
                Text(
                    L10n.tr(
                        "当前工作区尚无已保存的文本片段。请先在「片段 (Snippets)」页面创建文本片段，随后即可在动作流中选用。",
                        "No saved snippets yet. Create a snippet in the Snippets tab first, then select it here.",
                        language: lang
                    )
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
            }
            .listRowBackground(palette.barSurface)
        } else {
            Section(L10n.tr("选择要插入的文本片段", "Select Saved Snippet", language: lang)) {
                TextField(L10n.tr("搜索文本片段…", "Search snippets…", language: lang), text: $snippetSearch)
                ForEach(filteredSnippets) { snippet in
                    Button {
                        selectedSnippetID = snippet.id
                        missingSnippetTitle = nil
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "text.quote")
                                .foregroundStyle(palette.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(snippet.displayTitle(in: lang))
                                        .font(ChocType.body.weight(.semibold))
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                    Text(snippet.insertMode.badgeTitle(in: lang))
                                        .font(ChocType.micro)
                                        .foregroundStyle(palette.secondaryText)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(palette.accent.opacity(0.12), in: Capsule())
                                }
                                Text(snippet.singleLinePreview)
                                    .font(ChocType.micro)
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if selectedSnippetID == snippet.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(palette.statusConnected)
                            }
                        }
                    }
                }
            }
            .listRowBackground(palette.barSurface)
        }
    }

    private func buildStep() -> ActionFlowStep? {
        let cleanBid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = appName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch choice {
        case .launchApp:
            guard !cleanBid.isEmpty else { return nil }
            return ActionFlowStep(
                id: stepID,
                kind: .launchOrActivateApp(
                    bundleIdentifier: cleanBid,
                    appName: cleanName.isEmpty ? cleanBid : cleanName,
                    appPath: appPath
                ),
                isEnabled: stepEnabled
            )

        case .waitFrontmost:
            if waitFollowPrevious {
                return ActionFlowStep(
                    id: stepID,
                    kind: .waitForAppFrontmost(bundleIdentifier: "", appName: nil, timeoutSeconds: timeoutSeconds),
                    isEnabled: stepEnabled
                )
            }
            guard !cleanBid.isEmpty else { return nil }
            return ActionFlowStep(
                id: stepID,
                kind: .waitForAppFrontmost(
                    bundleIdentifier: cleanBid,
                    appName: cleanName.isEmpty ? nil : cleanName,
                    timeoutSeconds: timeoutSeconds
                ),
                isEnabled: stepEnabled
            )

        case .systemAction:
            if selectedAction.targetsApplication && !actionFollowActiveFlowApp {
                guard !cleanBid.isEmpty else { return nil }
                return ActionFlowStep(
                    id: stepID,
                    kind: .systemAction(
                        action: selectedAction,
                        targetBundleIdentifier: cleanBid,
                        targetAppName: cleanName.isEmpty ? nil : cleanName
                    ),
                    isEnabled: stepEnabled
                )
            }
            return ActionFlowStep(
                id: stepID,
                kind: .systemAction(action: selectedAction, targetBundleIdentifier: nil, targetAppName: nil),
                isEnabled: stepEnabled
            )

        case .delay:
            return ActionFlowStep(
                id: stepID,
                kind: .delay(seconds: delaySeconds),
                isEnabled: stepEnabled
            )

        case .openWebsite:
            guard ActionFlowStep.isValidWebsiteURL(websiteURL) else { return nil }
            let cleanURL = ActionFlowStep.normalizedWebsiteURL(websiteURL)
            let cleanTitle = websiteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return ActionFlowStep(
                id: stepID,
                kind: .openWebsite(
                    url: cleanURL,
                    title: cleanTitle.isEmpty ? nil : cleanTitle,
                    switchExistingTab: websiteSwitchTab
                ),
                isEnabled: stepEnabled
            )

        case .runShortcut:
            let cleanShortcut = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanShortcut.isEmpty else { return nil }
            return ActionFlowStep(
                id: stepID,
                kind: .runShortcut(shortcutName: cleanShortcut),
                isEnabled: stepEnabled
            )

        case .insertSnippet:
            guard let id = selectedSnippetID,
                  let snippet = client.profile.snippet(withID: id) else {
                return nil
            }
            return ActionFlowStep(
                id: stepID,
                kind: .insertSnippet(
                    snippetID: snippet.id,
                    titleSnapshot: snippet.displayTitle(in: lang)
                ),
                isEnabled: stepEnabled
            )
        }
    }
}

// MARK: - Sentence-to-Flow Proposal Card (Phone Sends Plain Sentence Only; Mac Confirms)

struct IOSSentenceFlowProposalCard: View {
    @ObservedObject var client: CompanionClientEngine
    @StateObject private var speech = IOSSentenceSpeechTranscriber()

    @State private var sentenceText: String = ""
    @State private var statusBanner: (message: String, isError: Bool)?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var trimmedSentence: String {
        sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(ChocType.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
                Text(L10n.tr("一句话生成动作流（Mac 确认执行）", "Sentence to Flow (Confirm on Mac)", language: lang))
                    .font(ChocType.caption.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                if speech.isRecording {
                    Text(L10n.tr("正在听写…", "Listening…", language: lang))
                        .font(ChocType.micro.weight(.semibold))
                        .foregroundStyle(palette.accentEmphasis)
                }
            }

            HStack(spacing: 8) {
                TextField(
                    L10n.tr(
                        "输入或说出要让 Mac 提议的一句话…",
                        "Type or speak a sentence for your Mac…",
                        language: lang
                    ),
                    text: $sentenceText
                )
                .font(ChocType.body)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit {
                    submitSentence()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.tileFillBottom)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                )

                Button {
                    statusBanner = nil
                    speech.toggleRecording(language: lang, initialPrefix: sentenceText) { updatedText in
                        sentenceText = updatedText
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(speech.isRecording ? palette.emphasisForeground : palette.accent)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(speech.isRecording ? palette.accentEmphasis : palette.tileFillBottom)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    speech.isRecording
                        ? L10n.tr("停止语音输入", "Stop Dictation", language: lang)
                        : L10n.tr("语音输入一句话", "Speak Sentence", language: lang)
                )

                Button {
                    submitSentence()
                } label: {
                    Text(L10n.tr("提议", "Propose", language: lang))
                        .font(ChocType.caption.weight(.semibold))
                        .foregroundStyle(palette.accentForeground)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(trimmedSentence.isEmpty ? palette.secondaryText.opacity(0.35) : palette.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(trimmedSentence.isEmpty)
            }

            if let speechErr = speech.errorMessage, !speechErr.isEmpty {
                Text(speechErr)
                    .font(ChocType.micro)
                    .foregroundStyle(palette.statusFailure)
            } else if let banner = statusBanner {
                Text(banner.message)
                    .font(ChocType.micro)
                    .foregroundStyle(banner.isError ? palette.statusFailure : palette.statusConnected)
            }

            Text(
                L10n.tr(
                    "手机仅发送纯文本语句；API 密钥保留在 Mac，草稿须在 Mac 上点击「确认」后才会保存并执行。",
                    "Sends plain sentence text only — API key stays on Mac and Mac confirmation is required before anything runs.",
                    language: lang
                )
            )
            .font(ChocType.micro)
            .foregroundStyle(palette.secondaryText)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(palette.barSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .onDisappear {
            speech.stopRecording()
        }
    }

    private func submitSentence() {
        speech.stopRecording()
        let clean = trimmedSentence
        guard !clean.isEmpty else { return }

        if client.proposeFlow(sentence: clean) {
            sentenceText = ""
            statusBanner = (
                message: L10n.tr(
                    "已发送至 Mac — 请在 Mac 动作流工作台核对步骤并点击「确认」。",
                    "Sent to Mac — review the proposed steps and tap Confirm on your Mac.",
                    language: lang
                ),
                isError: false
            )
        } else {
            statusBanner = (
                message: L10n.tr(
                    "当前未连接 Mac，无法发送语句。",
                    "Connect to your Mac first before proposing a flow.",
                    language: lang
                ),
                isError: true
            )
        }
    }
}

@MainActor
private final class IOSSentenceSpeechTranscriber: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var errorMessage: String?

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionGeneration: UInt64 = 0

    func toggleRecording(
        language: AppLanguage,
        initialPrefix: String,
        onTranscript: @escaping @MainActor (String) -> Void
    ) {
        if isRecording {
            stopRecording()
            return
        }

        errorMessage = nil
        sessionGeneration &+= 1
        let generation = sessionGeneration
        let basePrefix = initialPrefix.trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor [weak self] in
            guard let self, self.sessionGeneration == generation else { return }
            await self.beginRecording(
                generation: generation,
                language: language,
                basePrefix: basePrefix,
                onTranscript: onTranscript
            )
        }
    }

    func stopRecording() {
        sessionGeneration &+= 1
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
        if isRecording {
            isRecording = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func beginRecording(
        generation: UInt64,
        language: AppLanguage,
        basePrefix: String,
        onTranscript: @escaping @MainActor (String) -> Void
    ) async {
        let speechStatus = await Self.requestSpeechAuthorization()
        guard sessionGeneration == generation else { return }
        guard speechStatus == .authorized else {
            errorMessage = L10n.tr(
                "未获得语音识别权限，请在系统设置中开启语音识别或直接使用键盘输入。",
                "Speech recognition permission was denied. Enable it in Settings or type your sentence.",
                language: language
            )
            return
        }

        let micAllowed = await AVAudioApplication.requestRecordPermission()
        guard sessionGeneration == generation else { return }
        guard micAllowed else {
            errorMessage = L10n.tr(
                "未获得麦克风权限，请在系统设置中开启麦克风权限或直接使用键盘输入。",
                "Microphone permission was denied. Enable it in Settings or type your sentence.",
                language: language
            )
            return
        }

        let preferredLocale: Locale = {
            switch language {
            case .chinese:
                return Locale(identifier: "zh-CN")
            case .english:
                return Locale(identifier: "en-US")
            case .system:
                return Locale.current
            }
        }()

        guard let recognizer = SFSpeechRecognizer(locale: preferredLocale) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            errorMessage = L10n.tr(
                "当前设备暂不支持语音识别，请直接输入文字。",
                "Speech recognition is currently unavailable on this device — please type instead.",
                language: language
            )
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            engine.prepare()
            try engine.start()

            audioEngine = engine
            recognitionRequest = request
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let spokenText = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let hadError = (error != nil)
                Task { @MainActor [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    if let spokenText, !spokenText.isEmpty {
                        let combined = basePrefix.isEmpty ? spokenText : "\(basePrefix) \(spokenText)"
                        onTranscript(String(combined.prefix(CompanionClientEngine.maxProposedFlowSentenceCharacters)))
                    }
                    if isFinal || hadError {
                        self.stopRecording()
                    }
                }
            }
        } catch {
            stopRecording()
            errorMessage = L10n.tr(
                "无法启动麦克风录音，请直接输入文字。",
                "Could not start microphone dictation — please type instead.",
                language: language
            )
        }
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
