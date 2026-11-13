import AppKit
import ChocliftCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main Studio Section: Composable Action Flows

public struct ActionFlowsStudioView: View {
    @ObservedObject var coordinator: MacAppCoordinator

    @State private var selectedFlowID: UUID?
    @State private var editorSheetDraft: FlowSheetSession?
    @State private var assignPageIndex: Int = 0
    @State private var assignSlotIndex: Int = 0

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }
    private var flows: [ActionFlow] { coordinator.profile.flows }

    private var selectedFlow: ActionFlow? {
        if let selectedFlowID, let found = coordinator.profile.flow(withID: selectedFlowID) {
            return found
        }
        return flows.first
    }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        HStack(spacing: 0) {
            flowsSidebar
                .frame(width: 300)

            Divider()

            Group {
                if let flow = selectedFlow {
                    MacFlowDetailWorkspaceView(
                        coordinator: coordinator,
                        flow: flow,
                        assignPageIndex: $assignPageIndex,
                        assignSlotIndex: $assignSlotIndex,
                        onOpenFullEditor: { target in
                            editorSheetDraft = FlowSheetSession(flow: target, isNew: false)
                        },
                        onDeleted: {
                            selectedFlowID = coordinator.profile.flows.first?.id
                        }
                    )
                    .id(flow.id)
                } else {
                    emptyStudioPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            assignPageIndex = coordinator.selectedPageIndex
            if selectedFlowID == nil {
                selectedFlowID = flows.first?.id
            }
        }
        .onChange(of: coordinator.profile.flows) { updatedFlows in
            if let current = selectedFlowID, updatedFlows.contains(where: { $0.id == current }) {
                return
            }
            selectedFlowID = updatedFlows.first?.id
        }
        .sheet(item: $editorSheetDraft) { session in
            MacFlowEditorSheet(
                coordinator: coordinator,
                initialFlow: session.flow,
                isNew: session.isNew
            ) { saved in
                coordinator.saveFlow(saved)
                selectedFlowID = saved.id
            }
        }
    }

    // MARK: - Left Sidebar (Flow List + Reorder + Templates)

    private var flowsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(
                    L10n.tr("动作流列表", "Action Flows", language: lang),
                    systemImage: "arrow.triangle.branch"
                )
                .font(.headline)
                .foregroundStyle(palette.primaryText)

                Spacer()

                Menu {
                    Button {
                        openNewBlankFlow()
                    } label: {
                        Label(L10n.tr("空白动作流…", "Blank Flow…", language: lang), systemImage: "plus")
                    }

                    Divider()

                    Button {
                        openNewFocusMaximizeTemplate()
                    } label: {
                        Label(
                            L10n.tr("模板：打开应用 → 等待前置 → 最大化", "Template: Open App → Wait Frontmost → Maximize", language: lang),
                            systemImage: "arrow.up.left.and.arrow.down.right"
                        )
                    }

                    Button {
                        openNewSplitScreenTemplate()
                    } label: {
                        Label(
                            L10n.tr("模板：双应用左右分屏", "Template: Split Left & Right Apps", language: lang),
                            systemImage: "rectangle.split.2x1"
                        )
                    }
                } label: {
                    Label(L10n.tr("新建", "New", language: lang), systemImage: "plus")
                        .font(.caption.bold())
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            }
            .padding(14)

            Divider()

            if flows.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 30))
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("尚无动作流", "No Flows Yet", language: lang))
                        .font(.subheadline.bold())
                        .foregroundStyle(palette.primaryText)
                    Text(
                        L10n.tr(
                            "将多个打开应用、等待前置与窗口贴靠动作组合成一键触发器，自动同步到 iPhone、iPad 与 Watch。",
                            "Chain app launches, frontmost waits, and window snaps into one synced tile.",
                            language: lang
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(flows.enumerated()), id: \.element.id) { index, flow in
                            flowSidebarRow(flow: flow, index: index)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(palette.barSurface.opacity(0.6))
    }

    private func flowSidebarRow(flow: ActionFlow, index: Int) -> some View {
        let isSelected = (selectedFlow?.id == flow.id)
        let isRunning = (coordinator.runningFlowID == flow.id)
        let badgeFill = ChocSwatch.resolvedTileColor(hex: flow.backgroundHex, fallbackHex: "#ECFAFE")

        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(badgeFill)
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )
                Text(flow.emoji.isEmpty ? "⚡️" : flow.emoji)
                    .font(.system(size: 18))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(flow.name)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text(
                    L10n.tr(
                        "\(flow.enabledStepCount) 个启用步骤",
                        "\(flow.enabledStepCount) active step\(flow.enabledStepCount == 1 ? "" : "s")",
                        language: lang
                    )
                )
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
            }

            Spacer(minLength: 4)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.accent)
            } else {
                VStack(spacing: 2) {
                    Button {
                        coordinator.moveFlow(from: index, to: index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.25 : 0.85)

                    Button {
                        coordinator.moveFlow(from: index, to: index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(index + 1 >= flows.count)
                    .opacity(index + 1 >= flows.count ? 0.25 : 0.85)
                }
            }
        }
        .padding(9)
        .background(
            isSelected ? palette.accent.opacity(0.14) : palette.barSurface,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isSelected ? palette.accent.opacity(0.7) : palette.subtleCardStroke, lineWidth: 1.2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedFlowID = flow.id
        }
        .contextMenu {
            Button {
                coordinator.executeFlow(flow)
            } label: {
                Label(L10n.tr("立即运行测试", "Run Flow Now", language: lang), systemImage: "play.fill")
            }

            Button {
                editorSheetDraft = FlowSheetSession(flow: flow, isNew: false)
            } label: {
                Label(L10n.tr("编辑动作流…", "Edit Flow…", language: lang), systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                coordinator.deleteFlow(id: flow.id)
            } label: {
                Label(L10n.tr("删除动作流", "Delete Flow", language: lang), systemImage: "trash")
            }
        }
    }

    // MARK: - Empty State with Preset Examples

    private var emptyStudioPlaceholder: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(palette.accent)

            Text(L10n.tr("创建可组合的 Mac 动作流", "Build Composable Mac Action Flows", language: lang))
                .font(.title2.bold())
                .foregroundStyle(palette.primaryText)

            Text(
                L10n.tr(
                    "按顺序串行执行多个步骤；若某一步失败会自动停止并提示失败步骤，绝不会把窗口贴靠误作用到错误的应用上。",
                    "Run ordered Mac steps sequentially. If any step fails, execution halts immediately with step-specific feedback instead of snapping the wrong app.",
                    language: lang
                )
            )
            .font(.callout)
            .foregroundStyle(palette.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button {
                    openNewBlankFlow()
                } label: {
                    Label(L10n.tr("新建空白动作流", "New Blank Flow", language: lang), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.accentForeground)

                Button {
                    openNewFocusMaximizeTemplate()
                } label: {
                    Label(
                        L10n.tr("示例 1：打开等待前置并最大化", "Example 1: Open, Wait & Maximize", language: lang),
                        systemImage: "arrow.up.left.and.arrow.down.right"
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    openNewSplitScreenTemplate()
                } label: {
                    Label(
                        L10n.tr("示例 2：双应用左右分屏", "Example 2: Left & Right Split", language: lang),
                        systemImage: "rectangle.split.2x1"
                    )
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding(30)
    }

    private func openNewBlankFlow() {
        let draft = ActionFlow(
            name: L10n.tr("新建动作流", "New Flow", language: lang),
            emoji: "⚡️",
            backgroundHex: "#ECFAFE",
            steps: []
        )
        editorSheetDraft = FlowSheetSession(flow: draft, isNew: true)
    }

    private func openNewFocusMaximizeTemplate() {
        let preferred = coordinator.installedApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
            ?? coordinator.installedApps.first
        let draft = ActionFlow.makeOpenWaitMaximizeTemplate(
            bundleIdentifier: preferred?.bundleIdentifier ?? "com.apple.Safari",
            appName: preferred?.appName ?? "Safari",
            appPath: preferred?.appPath,
            language: lang
        )
        editorSheetDraft = FlowSheetSession(flow: draft, isNew: true)
    }

    private func openNewSplitScreenTemplate() {
        let leftApp = coordinator.installedApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
            ?? coordinator.installedApps.first
        let rightApp = coordinator.installedApps.first(where: {
            $0.bundleIdentifier == "com.apple.Notes" && $0.bundleIdentifier != leftApp?.bundleIdentifier
        }) ?? coordinator.installedApps.dropFirst().first
        let draft = ActionFlow.makeSplitScreenTemplate(
            leftBundleIdentifier: leftApp?.bundleIdentifier ?? "com.apple.Safari",
            leftAppName: leftApp?.appName ?? "Safari",
            leftAppPath: leftApp?.appPath,
            rightBundleIdentifier: rightApp?.bundleIdentifier ?? "com.apple.Notes",
            rightAppName: rightApp?.appName ?? "Notes",
            rightAppPath: rightApp?.appPath,
            language: lang
        )
        editorSheetDraft = FlowSheetSession(flow: draft, isNew: true)
    }
}

private struct FlowSheetSession: Identifiable {
    let id = UUID()
    let flow: ActionFlow
    let isNew: Bool
}

// MARK: - Right Detail Workspace for a Selected Flow

private struct MacFlowDetailWorkspaceView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    let flow: ActionFlow
    @Binding var assignPageIndex: Int
    @Binding var assignSlotIndex: Int
    let onOpenFullEditor: (ActionFlow) -> Void
    let onDeleted: () -> Void

    @State private var stepEditorTarget: StepSheetTarget?

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    private var placedLocations: [(pageTitle: String, pageIndex: Int, slotIndex: Int)] {
        var found: [(String, Int, Int)] = []
        for (pIdx, page) in coordinator.profile.pages.enumerated() {
            for (sIdx, slot) in page.slots.enumerated() where slot?.flowID == flow.id {
                found.append((page.title, pIdx, sIdx))
            }
        }
        return found
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSummaryCard
                slotPlacementCard
                stepsPipelineCard
            }
            .padding(22)
        }
        .sheet(item: $stepEditorTarget) { target in
            MacFlowStepEditorSheet(
                coordinator: coordinator,
                initialStep: target.step,
                defaultFollowBundleID: target.defaultFollowBundleID,
                onSave: { updatedStep in
                    var updated = flow
                    if let idx = updated.steps.firstIndex(where: { $0.id == updatedStep.id }) {
                        updated.steps[idx] = updatedStep
                    } else {
                        updated.steps.append(updatedStep)
                    }
                    coordinator.saveFlow(updated)
                }
            )
        }
    }

    private var headerSummaryCard: some View {
        HStack(spacing: 18) {
            ChocBarTileCard(
                item: coordinator.profile.makeBarItem(for: flow),
                iconData: nil,
                palette: palette,
                language: lang
            )
            .frame(width: 98, height: 98)

            VStack(alignment: .leading, spacing: 6) {
                Text(flow.name)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)

                Text(
                    L10n.tr(
                        "共 \(flow.steps.count) 步（\(flow.enabledStepCount) 步启用）· 同步至所有已配对设备",
                        "\(flow.steps.count) total steps (\(flow.enabledStepCount) active) · Synced to paired devices",
                        language: lang
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

                HStack(spacing: 10) {
                    Button {
                        coordinator.executeFlow(flow)
                    } label: {
                        Label(
                            coordinator.runningFlowID == flow.id
                                ? L10n.tr("正在执行…", "Running…", language: lang)
                                : L10n.tr("在 Mac 上运行测试", "Test Run on Mac", language: lang),
                            systemImage: "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .foregroundStyle(palette.accentForeground)
                    .disabled(flow.enabledStepCount == 0 || coordinator.runningFlowID == flow.id)

                    Button {
                        onOpenFullEditor(flow)
                    } label: {
                        Label(L10n.tr("编辑名称与外观…", "Edit Name & Tile…", language: lang), systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        coordinator.deleteFlow(id: flow.id)
                        onDeleted()
                    } label: {
                        Label(L10n.tr("删除", "Delete", language: lang), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.statusFailure)
                }
                .padding(.top, 2)
            }

            Spacer()
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var slotPlacementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                L10n.tr("放置到巧克力栏槽位（iPhone / iPad / Watch 可直接点按触发）", "Place on Chocolate Bar Slot (Trigger from iPhone, iPad & Watch)", language: lang),
                systemImage: "square.grid.2x2.fill"
            )
            .font(.subheadline.bold())
            .foregroundStyle(palette.primaryText)

            HStack(spacing: 12) {
                Picker(L10n.tr("页面", "Page", language: lang), selection: $assignPageIndex) {
                    ForEach(Array(coordinator.profile.pages.enumerated()), id: \.offset) { idx, page in
                        Text("\(page.iconEmoji) \(idx + 1). \(page.title)").tag(idx)
                    }
                }
                .frame(width: 210)

                Picker(L10n.tr("槽位", "Slot", language: lang), selection: $assignSlotIndex) {
                    ForEach(0..<BarPage.slotsPerPage, id: \.self) { sIdx in
                        let currentTitle = coordinator.profile.pages.indices.contains(assignPageIndex)
                            ? coordinator.profile.pages[assignPageIndex].slots[sIdx]?.displayTitle(in: lang)
                            : nil
                        let suffix = currentTitle.map { " (\($0))" } ?? L10n.tr(" (空)", " (Empty)", language: lang)
                        Text("#\(sIdx + 1)\(suffix)").tag(sIdx)
                    }
                }
                .frame(width: 220)

                Button {
                    coordinator.assignFlowToSlot(flow, pageIndex: assignPageIndex, slotIndex: assignSlotIndex)
                    coordinator.flashBanner(
                        L10n.tr(
                            "已将「\(flow.name)」放入第 \(assignPageIndex + 1) 页槽位 #\(assignSlotIndex + 1)",
                            "Placed \"\(flow.name)\" into Page \(assignPageIndex + 1) Slot #\(assignSlotIndex + 1)",
                            language: lang
                        )
                    )
                } label: {
                    Label(L10n.tr("放入该槽位", "Place in Slot", language: lang), systemImage: "plus.square.on.square")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accentEmphasis)
                .foregroundStyle(palette.emphasisForeground)

                Spacer()
            }

            if !placedLocations.isEmpty {
                HStack(spacing: 6) {
                    Text(L10n.tr("当前已放置于：", "Currently placed at:", language: lang))
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                    ForEach(Array(placedLocations.enumerated()), id: \.offset) { _, loc in
                        Text("\(loc.pageTitle) #\(loc.slotIndex + 1)")
                            .font(.caption2.bold())
                            .foregroundStyle(palette.primaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(palette.accent.opacity(0.14), in: Capsule())
                    }
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var stepsPipelineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    L10n.tr("顺序执行步骤 (Sequential Steps)", "Sequential Execution Steps", language: lang),
                    systemImage: "list.number"
                )
                .font(.headline)
                .foregroundStyle(palette.primaryText)

                Spacer()

                addStepMenuButton
            }

            if flow.steps.isEmpty {
                VStack(spacing: 8) {
                    Text(L10n.tr("暂无步骤，点击右上角「添加步骤」开始编排。", "No steps yet. Click \"Add Step\" above to add your first Mac action.", language: lang))
                        .font(.callout)
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(flow.steps.enumerated()), id: \.element.id) { idx, step in
                        stepPipelineRow(step: step, index: idx)
                    }
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var addStepMenuButton: some View {
        let lastApp = lastReferencedApp(in: flow.steps)
        return Menu {
            Button {
                let initialApp = coordinator.installedApps.first
                let step = ActionFlowStep(
                    kind: .launchOrActivateApp(
                        bundleIdentifier: initialApp?.bundleIdentifier ?? "com.apple.Safari",
                        appName: initialApp?.appName ?? "Safari",
                        appPath: initialApp?.appPath
                    )
                )
                stepEditorTarget = StepSheetTarget(step: step, defaultFollowBundleID: lastApp?.bundleID)
            } label: {
                Label(L10n.tr("打开或激活 Mac 应用…", "Launch or Activate Mac App…", language: lang), systemImage: "app.badge.checkmark")
            }

            Button {
                let step = ActionFlowStep(
                    kind: .waitForAppFrontmost(
                        bundleIdentifier: lastApp?.bundleID ?? "",
                        appName: lastApp?.appName,
                        timeoutSeconds: ActionFlowStep.defaultTimeoutSeconds
                    )
                )
                stepEditorTarget = StepSheetTarget(step: step, defaultFollowBundleID: lastApp?.bundleID)
            } label: {
                Label(L10n.tr("等待目标应用前置…", "Wait Until App Is Frontmost…", language: lang), systemImage: "macwindow.on.rectangle")
            }

            Button {
                let step = ActionFlowStep(
                    kind: .systemAction(
                        action: .maximizeWindow,
                        targetBundleIdentifier: lastApp?.bundleID,
                        targetAppName: lastApp?.appName
                    )
                )
                stepEditorTarget = StepSheetTarget(step: step, defaultFollowBundleID: lastApp?.bundleID)
            } label: {
                Label(L10n.tr("执行窗口 / 系统快捷动作…", "Run Window or System Action…", language: lang), systemImage: "bolt.fill")
            }

            Button {
                let step = ActionFlowStep(kind: .delay(seconds: ActionFlowStep.defaultDelaySeconds))
                stepEditorTarget = StepSheetTarget(step: step, defaultFollowBundleID: lastApp?.bundleID)
            } label: {
                Label(L10n.tr("短时间等待延时…", "Short Bounded Delay…", language: lang), systemImage: "timer")
            }
        } label: {
            Label(L10n.tr("添加步骤", "Add Step", language: lang), systemImage: "plus")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private func stepPipelineRow(step: ActionFlowStep, index: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color(hex: step.accentHex).opacity(step.isEnabled ? 1.0 : 0.4), in: Circle())

            Image(systemName: step.sfSymbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(hex: step.accentHex))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.displayTitle(in: lang))
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .strikethrough(!step.isEnabled)
                    .foregroundStyle(step.isEnabled ? palette.primaryText : palette.secondaryText)
                Text(step.subtitle(in: lang))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { step.isEnabled },
                    set: { newValue in
                        var updated = flow
                        if let i = updated.steps.firstIndex(where: { $0.id == step.id }) {
                            updated.steps[i].isEnabled = newValue
                            coordinator.saveFlow(updated)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(palette.accent)
            .controlSize(.small)

            HStack(spacing: 4) {
                Button {
                    moveStep(from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(index == 0)

                Button {
                    moveStep(from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(index + 1 >= flow.steps.count)

                Button {
                    let priorApp = lastReferencedApp(in: Array(flow.steps.prefix(index)))
                    stepEditorTarget = StepSheetTarget(step: step, defaultFollowBundleID: priorApp?.bundleID)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    var updated = flow
                    updated.steps.removeAll { $0.id == step.id }
                    coordinator.saveFlow(updated)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(palette.statusFailure)
                .controlSize(.small)
            }
        }
        .padding(11)
        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private func moveStep(from source: Int, to destination: Int) {
        guard flow.steps.indices.contains(source),
              flow.steps.indices.contains(destination) else { return }
        var updated = flow
        let item = updated.steps.remove(at: source)
        updated.steps.insert(item, at: destination)
        coordinator.saveFlow(updated)
    }

    private func lastReferencedApp(in steps: [ActionFlowStep]) -> (bundleID: String, appName: String)? {
        for step in steps.reversed() {
            switch step.kind {
            case .launchOrActivateApp(let bid, let name, _):
                if !bid.isEmpty { return (bid, name) }
            case .waitForAppFrontmost(let bid, let name, _):
                if !bid.isEmpty { return (bid, name ?? bid) }
            default:
                continue
            }
        }
        return nil
    }
}

private struct StepSheetTarget: Identifiable {
    let id = UUID()
    let step: ActionFlowStep
    let defaultFollowBundleID: String?
}

// MARK: - Full Flow Editor Sheet (Reusable from Studio & Slot Picker)

public struct MacFlowEditorSheet: View {
    @ObservedObject var coordinator: MacAppCoordinator
    let isNew: Bool
    let onCommit: (ActionFlow) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ActionFlow
    @State private var stepSheetTarget: StepSheetTarget?

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    public init(
        coordinator: MacAppCoordinator,
        initialFlow: ActionFlow,
        isNew: Bool,
        onCommit: @escaping (ActionFlow) -> Void
    ) {
        self.coordinator = coordinator
        self.isNew = isNew
        self.onCommit = onCommit
        self._draft = State(initialValue: initialFlow)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    isNew
                        ? L10n.tr("新建动作流", "New Action Flow", language: lang)
                        : L10n.tr("编辑动作流", "Edit Action Flow", language: lang)
                )
                .font(.headline)
                .foregroundStyle(palette.primaryText)

                Spacer()

                Menu {
                    Button {
                        let preferred = coordinator.installedApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
                            ?? coordinator.installedApps.first
                        let tpl = ActionFlow.makeOpenWaitMaximizeTemplate(
                            bundleIdentifier: preferred?.bundleIdentifier ?? "com.apple.Safari",
                            appName: preferred?.appName ?? "Safari",
                            appPath: preferred?.appPath,
                            language: lang
                        )
                        draft.name = tpl.name
                        draft.emoji = tpl.emoji
                        draft.backgroundHex = tpl.backgroundHex
                        draft.steps = tpl.steps
                    } label: {
                        Label(
                            L10n.tr("填入模板：打开应用 → 等待前置 → 最大化", "Load Template: Open → Wait Frontmost → Maximize", language: lang),
                            systemImage: "arrow.up.left.and.arrow.down.right"
                        )
                    }

                    Button {
                        let leftApp = coordinator.installedApps.first(where: { $0.bundleIdentifier == "com.apple.Safari" })
                            ?? coordinator.installedApps.first
                        let rightApp = coordinator.installedApps.first(where: {
                            $0.bundleIdentifier == "com.apple.Notes" && $0.bundleIdentifier != leftApp?.bundleIdentifier
                        }) ?? coordinator.installedApps.dropFirst().first
                        let tpl = ActionFlow.makeSplitScreenTemplate(
                            leftBundleIdentifier: leftApp?.bundleIdentifier ?? "com.apple.Safari",
                            leftAppName: leftApp?.appName ?? "Safari",
                            leftAppPath: leftApp?.appPath,
                            rightBundleIdentifier: rightApp?.bundleIdentifier ?? "com.apple.Notes",
                            rightAppName: rightApp?.appName ?? "Notes",
                            rightAppPath: rightApp?.appPath,
                            language: lang
                        )
                        draft.name = tpl.name
                        draft.emoji = tpl.emoji
                        draft.backgroundHex = tpl.backgroundHex
                        draft.steps = tpl.steps
                    } label: {
                        Label(
                            L10n.tr("填入模板：双应用左右分屏", "Load Template: Split Left & Right Apps", language: lang),
                            systemImage: "rectangle.split.2x1"
                        )
                    }
                } label: {
                    Label(L10n.tr("快速模板", "Templates", language: lang), systemImage: "sparkles")
                        .font(.caption)
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            }
            .padding(16)

            Divider()

            HStack(alignment: .top, spacing: 18) {
                // Left: Tile Appearance & Name
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        ChocBarTileCard(
                            item: coordinator.profile.makeBarItem(for: draft),
                            iconData: nil,
                            palette: palette,
                            language: lang
                        )
                        .frame(width: 112, height: 112)
                        Spacer()
                    }

                    LabeledContent(L10n.tr("名称", "Name", language: lang)) {
                        TextField(L10n.tr("例如：分屏工作区", "e.g. Split Workspace", language: lang), text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    LabeledContent("Emoji") {
                        HStack(spacing: 5) {
                            TextField("⚡️", text: $draft.emoji)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 48)
                            ForEach(["⚡️", "🪟", "🖥", "🚀", "🎯", "🍫"], id: \.self) { em in
                                Button(em) { draft.emoji = em }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.tr("卡片颜色", "Tile Color", language: lang))
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
                            ForEach(ChocSwatch.tileColors, id: \.self) { hex in
                                let isSel = draft.backgroundHex.uppercased() == hex.uppercased()
                                Button {
                                    draft.backgroundHex = hex
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: hex))
                                            .frame(width: 24, height: 24)
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(isSel ? palette.accent : palette.subtleCardStroke, lineWidth: isSel ? 2.5 : 1.0)
                                            )
                                        if isSel {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9.5, weight: .black))
                                                .foregroundStyle(palette.primaryText)
                                        }
                                    }
                                    .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Spacer()
                }
                .frame(width: 240)

                Divider()

                // Right: Ordered Steps
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L10n.tr("执行步骤顺序", "Ordered Steps", language: lang))
                            .font(.subheadline.bold())
                            .foregroundStyle(palette.primaryText)
                        Spacer()
                        addDraftStepMenu
                    }

                    if draft.steps.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "list.bullet.rectangle")
                                .font(.title)
                                .foregroundStyle(palette.secondaryText)
                            Text(L10n.tr("点击右上角「添加步骤」或「快速模板」编排动作流", "Add steps or choose a template above", language: lang))
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                                .multilineTextAlignment(.center)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(Array(draft.steps.enumerated()), id: \.element.id) { idx, step in
                                    HStack(spacing: 8) {
                                        Text("\(idx + 1)")
                                            .font(.caption2.monospaced().bold())
                                            .foregroundStyle(.white)
                                            .frame(width: 20, height: 20)
                                            .background(Color(hex: step.accentHex), in: Circle())

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(step.displayTitle(in: lang))
                                                .font(.callout.weight(.semibold))
                                                .foregroundStyle(palette.primaryText)
                                                .lineLimit(1)
                                            Text(step.subtitle(in: lang))
                                                .font(.caption2)
                                                .foregroundStyle(palette.secondaryText)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Button {
                                            guard idx > 0 else { return }
                                            let item = draft.steps.remove(at: idx)
                                            draft.steps.insert(item, at: idx - 1)
                                        } label: {
                                            Image(systemName: "chevron.up")
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(idx == 0)

                                        Button {
                                            guard idx + 1 < draft.steps.count else { return }
                                            let item = draft.steps.remove(at: idx)
                                            draft.steps.insert(item, at: idx + 1)
                                        } label: {
                                            Image(systemName: "chevron.down")
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(idx + 1 >= draft.steps.count)

                                        Button {
                                            stepSheetTarget = StepSheetTarget(
                                                step: step,
                                                defaultFollowBundleID: priorBundleID(before: idx)
                                            )
                                        } label: {
                                            Image(systemName: "pencil")
                                        }
                                        .buttonStyle(.borderless)

                                        Button(role: .destructive) {
                                            draft.steps.removeAll { $0.id == step.id }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(8)
                                    .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(16)

            Divider()

            HStack {
                Button(L10n.tr("取消", "Cancel", language: lang)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("保存动作流", "Save Flow", language: lang)) {
                    var clean = draft
                    let trimmed = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    clean.name = trimmed.isEmpty ? L10n.tr("动作流", "Action Flow", language: lang) : trimmed
                    clean.emoji = clean.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "⚡️" : clean.emoji
                    clean.updatedAt = Date()
                    onCommit(clean)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.accentForeground)
                .disabled(draft.steps.isEmpty || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 680, height: 500)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .tint(palette.accent)
        .preferredColorScheme(.light)
        .sheet(item: $stepSheetTarget) { target in
            MacFlowStepEditorSheet(
                coordinator: coordinator,
                initialStep: target.step,
                defaultFollowBundleID: target.defaultFollowBundleID,
                onSave: { savedStep in
                    if let idx = draft.steps.firstIndex(where: { $0.id == savedStep.id }) {
                        draft.steps[idx] = savedStep
                    } else {
                        draft.steps.append(savedStep)
                    }
                }
            )
        }
    }

    private var addDraftStepMenu: some View {
        let followBundle = priorBundleID(before: draft.steps.count)
        let followName = priorAppName(before: draft.steps.count)
        return Menu {
            Button {
                let firstApp = coordinator.installedApps.first
                let step = ActionFlowStep(
                    kind: .launchOrActivateApp(
                        bundleIdentifier: firstApp?.bundleIdentifier ?? "com.apple.Safari",
                        appName: firstApp?.appName ?? "Safari",
                        appPath: firstApp?.appPath
                    )
                )
                stepSheetTarget = StepSheetTarget(step: step, defaultFollowBundleID: followBundle)
            } label: {
                Label(L10n.tr("打开或激活应用…", "Launch / Activate App…", language: lang), systemImage: "app.badge.checkmark")
            }

            Button {
                let step = ActionFlowStep(
                    kind: .waitForAppFrontmost(
                        bundleIdentifier: followBundle ?? "",
                        appName: followName,
                        timeoutSeconds: ActionFlowStep.defaultTimeoutSeconds
                    )
                )
                stepEditorTargetSheet(step, followBundle: followBundle)
            } label: {
                Label(L10n.tr("等待应用前置…", "Wait for App Frontmost…", language: lang), systemImage: "macwindow.on.rectangle")
            }

            Button {
                let step = ActionFlowStep(
                    kind: .systemAction(
                        action: .maximizeWindow,
                        targetBundleIdentifier: followBundle,
                        targetAppName: followName
                    )
                )
                stepEditorTargetSheet(step, followBundle: followBundle)
            } label: {
                Label(L10n.tr("执行窗口 / 系统动作…", "Run System Action…", language: lang), systemImage: "bolt.fill")
            }

            Button {
                let step = ActionFlowStep(kind: .delay(seconds: ActionFlowStep.defaultDelaySeconds))
                stepEditorTargetSheet(step, followBundle: followBundle)
            } label: {
                Label(L10n.tr("固定短延时…", "Short Delay…", language: lang), systemImage: "timer")
            }
        } label: {
            Label(L10n.tr("添加步骤", "Add Step", language: lang), systemImage: "plus")
                .font(.caption.bold())
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private func stepEditorTargetSheet(_ step: ActionFlowStep, followBundle: String?) {
        stepSheetTarget = StepSheetTarget(step: step, defaultFollowBundleID: followBundle)
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

// MARK: - Step Editor Sheet (Mac)

public struct MacFlowStepEditorSheet: View {
    public enum EditableStepKindTag: String, CaseIterable, Identifiable {
        case launchApp
        case waitFrontmost
        case systemAction
        case delay

        public var id: String { rawValue }
    }

    @ObservedObject var coordinator: MacAppCoordinator
    let stepID: UUID
    let isEnabled: Bool
    let defaultFollowBundleID: String?
    let onSave: (ActionFlowStep) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTag: EditableStepKindTag = .launchApp
    @State private var appSearch: String = ""
    @State private var bundleID: String = "com.apple.Safari"
    @State private var appName: String = "Safari"
    @State private var appPath: String?

    @State private var waitFollowPreviousApp: Bool = false
    @State private var timeoutSeconds: Double = ActionFlowStep.defaultTimeoutSeconds
    @State private var delaySeconds: Double = ActionFlowStep.defaultDelaySeconds

    @State private var chosenAction: SystemQuickAction = .maximizeWindow
    @State private var actionFollowActiveFlowApp: Bool = true

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    private var filteredApps: [InstalledAppSummary] {
        let q = appSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return coordinator.installedApps }
        return coordinator.installedApps.filter {
            $0.appName.localizedCaseInsensitiveContains(q) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(q)
        }
    }

    public init(
        coordinator: MacAppCoordinator,
        initialStep: ActionFlowStep,
        defaultFollowBundleID: String?,
        onSave: @escaping (ActionFlowStep) -> Void
    ) {
        self.coordinator = coordinator
        self.stepID = initialStep.id
        self.isEnabled = initialStep.isEnabled
        self.defaultFollowBundleID = defaultFollowBundleID
        self.onSave = onSave

        switch initialStep.kind {
        case .launchOrActivateApp(let bid, let name, let path):
            _selectedTag = State(initialValue: .launchApp)
            _bundleID = State(initialValue: bid)
            _appName = State(initialValue: name)
            _appPath = State(initialValue: path)

        case .waitForAppFrontmost(let bid, let name, let timeout):
            _selectedTag = State(initialValue: .waitFrontmost)
            let trimmed = bid.trimmingCharacters(in: .whitespacesAndNewlines)
            _waitFollowPreviousApp = State(initialValue: trimmed.isEmpty)
            _bundleID = State(initialValue: trimmed.isEmpty ? (defaultFollowBundleID ?? "com.apple.Safari") : trimmed)
            _appName = State(initialValue: name ?? "")
            _timeoutSeconds = State(initialValue: ActionFlowStep.clampTimeout(timeout))

        case .systemAction(let action, let targetBid, let targetName):
            _selectedTag = State(initialValue: .systemAction)
            _chosenAction = State(initialValue: action)
            let trimmed = targetBid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            _actionFollowActiveFlowApp = State(initialValue: trimmed.isEmpty)
            _bundleID = State(initialValue: trimmed.isEmpty ? (defaultFollowBundleID ?? "com.apple.Safari") : trimmed)
            _appName = State(initialValue: targetName ?? "")

        case .delay(let secs):
            _selectedTag = State(initialValue: .delay)
            _delaySeconds = State(initialValue: ActionFlowStep.clampDelay(secs))

        case .unsupported:
            _selectedTag = State(initialValue: .systemAction)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tr("配置步骤", "Configure Flow Step", language: lang))
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Picker("", selection: $selectedTag) {
                    Text(L10n.tr("打开应用", "Open App", language: lang)).tag(EditableStepKindTag.launchApp)
                    Text(L10n.tr("等待前置", "Wait Frontmost", language: lang)).tag(EditableStepKindTag.waitFrontmost)
                    Text(L10n.tr("系统动作", "Quick Action", language: lang)).tag(EditableStepKindTag.systemAction)
                    Text(L10n.tr("延时", "Delay", language: lang)).tag(EditableStepKindTag.delay)
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
            .padding(16)

            Divider()

            Group {
                switch selectedTag {
                case .launchApp:
                    launchAppConfigBody
                case .waitFrontmost:
                    waitFrontmostConfigBody
                case .systemAction:
                    systemActionConfigBody
                case .delay:
                    delayConfigBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)

            Divider()

            HStack {
                Button(L10n.tr("取消", "Cancel", language: lang)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.tr("保存步骤", "Save Step", language: lang)) {
                    if let built = buildStep() {
                        onSave(built)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.accentForeground)
                .disabled(!canSaveStep)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 450)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .tint(palette.accent)
        .preferredColorScheme(.light)
    }

    private var canSaveStep: Bool {
        switch selectedTag {
        case .launchApp:
            return !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .waitFrontmost:
            if waitFollowPreviousApp { return true }
            return !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .systemAction:
            if chosenAction.targetsApplication && !actionFollowActiveFlowApp {
                return !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        case .delay:
            return delaySeconds >= ActionFlowStep.minDelaySeconds
        }
    }

    private var launchAppConfigBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(L10n.tr("搜索本机应用…", "Search installed Mac apps…", language: lang), text: $appSearch)
                    .textFieldStyle(.roundedBorder)
                Button {
                    pickAppBundleInFinder()
                } label: {
                    Label(L10n.tr("访达选择…", "Finder…", language: lang), systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            List(filteredApps) { app in
                Button {
                    bundleID = app.bundleIdentifier
                    appName = app.appName
                    appPath = app.appPath
                } label: {
                    HStack(spacing: 10) {
                        DataImageView(pngData: app.iconPNGData, fallbackSymbol: "app.fill", tint: palette.secondaryText)
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.appName)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(palette.primaryText)
                            Text(app.bundleIdentifier)
                                .font(.caption2)
                                .foregroundStyle(palette.secondaryText)
                        }
                        Spacer()
                        if bundleID == app.bundleIdentifier {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(palette.statusConnected)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(palette.barSurface)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))

            HStack(spacing: 10) {
                LabeledContent("Bundle ID") {
                    TextField("com.apple.Safari", text: $bundleID)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent(L10n.tr("名称", "Name", language: lang)) {
                    TextField("Safari", text: $appName)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var waitFrontmostConfigBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(
                L10n.tr("自动跟随上一步打开的目标应用", "Follow the app opened in the previous step", language: lang),
                isOn: $waitFollowPreviousApp
            )
            .tint(palette.accent)

            if !waitFollowPreviousApp {
                HStack(spacing: 8) {
                    TextField(L10n.tr("搜索应用以填入 Bundle ID…", "Filter apps…", language: lang), text: $appSearch)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.tr("访达选择…", "Finder…", language: lang)) {
                        pickAppBundleInFinder()
                    }
                    .buttonStyle(.bordered)
                }

                List(filteredApps.prefix(40)) { app in
                    Button {
                        bundleID = app.bundleIdentifier
                        appName = app.appName
                    } label: {
                        HStack {
                            Text(app.appName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(palette.primaryText)
                            Text(app.bundleIdentifier)
                                .font(.caption2)
                                .foregroundStyle(palette.secondaryText)
                            Spacer()
                            if bundleID == app.bundleIdentifier {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(palette.statusConnected)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(palette.barSurface)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                .frame(height: 150)

                HStack(spacing: 10) {
                    LabeledContent("Bundle ID") {
                        TextField("com.apple.Safari", text: $bundleID)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent(L10n.tr("显示名", "App Name", language: lang)) {
                        TextField("Safari", text: $appName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.tr("最长等待超时", "Maximum Wait Timeout", language: lang))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    Text(ActionFlowStep.formatSeconds(timeoutSeconds))
                        .font(.callout.monospacedDigit().bold())
                        .foregroundStyle(palette.primaryText)
                }
                Slider(value: $timeoutSeconds, in: 0.2...ActionFlowStep.maxTimeoutSeconds, step: 0.2)
                    .tint(palette.accent)
                Text(L10n.tr("若超时后该应用仍未处于前台，动作流将立即停止并提示该步骤失败。", "If the app does not become frontmost before timeout, the flow stops and reports this step.", language: lang))
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
            }

            Spacer()
        }
    }

    private var systemActionConfigBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent(L10n.tr("选择动作", "System Action", language: lang)) {
                Picker("", selection: $chosenAction) {
                    ForEach(SystemQuickAction.allCases) { act in
                        Text(act.title(in: lang)).tag(act)
                    }
                }
                .frame(width: 290)
            }

            if chosenAction.targetsApplication {
                Divider()

                Toggle(
                    L10n.tr("作用于当前动作流中刚打开/激活的应用（推荐）", "Apply to the current app in this flow (Recommended)", language: lang),
                    isOn: $actionFollowActiveFlowApp
                )
                .tint(palette.accent)

                if !actionFollowActiveFlowApp {
                    HStack(spacing: 10) {
                        LabeledContent("Bundle ID") {
                            TextField("com.apple.Safari", text: $bundleID)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent(L10n.tr("应用名", "App Name", language: lang)) {
                            TextField("Safari", text: $appName)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    List(filteredApps.prefix(30)) { app in
                        Button {
                            bundleID = app.bundleIdentifier
                            appName = app.appName
                        } label: {
                            HStack {
                                Text(app.appName)
                                    .font(.callout)
                                    .foregroundStyle(palette.primaryText)
                                Text(app.bundleIdentifier)
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                                Spacer()
                                if bundleID == app.bundleIdentifier {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(palette.statusConnected)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(palette.barSurface)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    .frame(height: 150)
                } else {
                    Text(
                        L10n.tr(
                            "窗口左半屏、右半屏与最大化会严格绑定到目标应用的进程，不会误操作前一步遗留的其它窗口。",
                            "Left/Right window snaps and maximize strictly target the intended app process rather than any leftover window.",
                            language: lang
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                }
            }

            Spacer()
        }
    }

    private var delayConfigBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.tr("等待时长（上限 10 秒）", "Bounded Delay (Max 10s)", language: lang))
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Text(ActionFlowStep.formatSeconds(delaySeconds))
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(palette.primaryText)
            }

            Slider(value: $delaySeconds, in: 0.1...ActionFlowStep.maxDelaySeconds, step: 0.1)
                .tint(palette.accent)

            HStack(spacing: 8) {
                ForEach([0.2, 0.5, 1.0, 2.0, 3.0], id: \.self) { preset in
                    Button(ActionFlowStep.formatSeconds(preset)) {
                        delaySeconds = preset
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text(
                L10n.tr(
                    "用于在两个系统动作之间留出固定缓冲时间；若需等待应用启动完成，优先使用「等待前置」步骤。",
                    "Pauses between steps for a bounded duration. Prefer \"Wait Frontmost\" when waiting for an app launch.",
                    language: lang
                )
            )
            .font(.caption)
            .foregroundStyle(palette.secondaryText)

            Spacer()
        }
    }

    private func pickAppBundleInFinder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK,
           let url = panel.url,
           let bundle = Bundle(url: url),
           let bid = bundle.bundleIdentifier {
            let rawName = FileManager.default.displayName(atPath: url.path)
            let cleaned = rawName.lowercased().hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
            bundleID = bid
            appName = cleaned
            appPath = url.path
            _ = coordinator.catalogService.iconData(forBundleID: bid, fallbackPath: url.path)
        }
    }

    private func buildStep() -> ActionFlowStep? {
        let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch selectedTag {
        case .launchApp:
            guard !trimmedBundle.isEmpty else { return nil }
            let resolvedName = trimmedName.isEmpty ? trimmedBundle : trimmedName
            return ActionFlowStep(
                id: stepID,
                kind: .launchOrActivateApp(bundleIdentifier: trimmedBundle, appName: resolvedName, appPath: appPath),
                isEnabled: isEnabled
            )

        case .waitFrontmost:
            if waitFollowPreviousApp {
                return ActionFlowStep(
                    id: stepID,
                    kind: .waitForAppFrontmost(bundleIdentifier: "", appName: nil, timeoutSeconds: timeoutSeconds),
                    isEnabled: isEnabled
                )
            }
            guard !trimmedBundle.isEmpty else { return nil }
            return ActionFlowStep(
                id: stepID,
                kind: .waitForAppFrontmost(
                    bundleIdentifier: trimmedBundle,
                    appName: trimmedName.isEmpty ? nil : trimmedName,
                    timeoutSeconds: timeoutSeconds
                ),
                isEnabled: isEnabled
            )

        case .systemAction:
            if chosenAction.targetsApplication && !actionFollowActiveFlowApp {
                guard !trimmedBundle.isEmpty else { return nil }
                return ActionFlowStep(
                    id: stepID,
                    kind: .systemAction(
                        action: chosenAction,
                        targetBundleIdentifier: trimmedBundle,
                        targetAppName: trimmedName.isEmpty ? nil : trimmedName
                    ),
                    isEnabled: isEnabled
                )
            }
            return ActionFlowStep(
                id: stepID,
                kind: .systemAction(action: chosenAction, targetBundleIdentifier: nil, targetAppName: nil),
                isEnabled: isEnabled
            )

        case .delay:
            return ActionFlowStep(
                id: stepID,
                kind: .delay(seconds: delaySeconds),
                isEnabled: isEnabled
            )
        }
    }
}
