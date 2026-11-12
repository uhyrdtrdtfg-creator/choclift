import AppKit
import ChocliftCore
import SwiftUI
import UniformTypeIdentifiers

private struct EditingSlotTarget: Identifiable {
    let pageIndex: Int
    let slotIndex: Int
    var id: String { "\(pageIndex)-\(slotIndex)" }
}

public struct ChocolateBarStudioView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @State private var editingSlot: EditingSlotTarget?
    @State private var hoveredSlotIndex: Int?
    @State private var draggedSlotIndex: Int?
    @State private var showPageRenamePopover: Bool = false

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    private var currentPage: BarPage {
        let idx = min(max(0, coordinator.selectedPageIndex), coordinator.profile.pages.count - 1)
        return coordinator.profile.pages[idx]
    }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 22) {
            pageSelectorStrip

            chocolateHardwarePreview

            bottomHintBar
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .sheet(item: $editingSlot) { target in
            let existing = coordinator.profile.pages[target.pageIndex].slots[target.slotIndex]
            MacSlotItemPickerSheet(
                coordinator: coordinator,
                pageIndex: target.pageIndex,
                slotIndex: target.slotIndex,
                existingItem: existing
            )
        }
    }

    // MARK: - 8-Page Top Strip (Matches Screenshot Top Row)

    private var pageSelectorStrip: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(coordinator.profile.pages) { page in
                    let isSelected = (page.index == coordinator.selectedPageIndex)
                    Button {
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                            coordinator.selectedPageIndex = page.index
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(page.iconEmoji)
                                .font(.system(size: 15))
                            if isSelected {
                                Text(page.title)
                                    .font(.system(.callout, design: .rounded, weight: .bold))
                                    .lineLimit(1)
                            } else {
                                Text("\(page.index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, isSelected ? 14 : 10)
                        .padding(.vertical, 7)
                        .background(
                            isSelected
                                ? palette.tileFillTop.opacity(0.92)
                                : Color.primary.opacity(0.05),
                            in: Capsule()
                        )
                        .foregroundStyle(isSelected ? palette.primaryText : .primary)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isSelected ? palette.accentGold.opacity(0.75) : Color.primary.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: 20)

                Button {
                    showPageRenamePopover.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.callout)
                        .padding(7)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("编辑当前页面名称与图标", "Rename Page & Icon", language: lang))
                .popover(isPresented: $showPageRenamePopover) {
                    pageMetadataEditor
                }
            }
        }
    }

    private var pageMetadataEditor: some View {
        let idx = coordinator.selectedPageIndex
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("页面 #\(idx + 1) 设置", "Page #\(idx + 1) Settings", language: lang))
                .font(.headline)

            LabeledContent(L10n.tr("名称", "Title", language: lang)) {
                TextField(
                    "Page Title",
                    text: Binding(
                        get: { coordinator.profile.pages[idx].title },
                        set: { newVal in
                            coordinator.mutateProfile { $0.pages[idx].title = newVal }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            }

            LabeledContent(L10n.tr("图标", "Icon", language: lang)) {
                HStack(spacing: 5) {
                    ForEach(["🍫", "🚀", "⚡️", "🌐", "🔮", "🎨", "🎧", "🌙", "💼", "⭐️"], id: \.self) { em in
                        Button(em) {
                            coordinator.mutateProfile { $0.pages[idx].iconEmoji = em }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                coordinator.mutateProfile { draft in
                    draft.pages[idx].slots = Array(repeating: nil, count: BarPage.slotsPerPage)
                }
                showPageRenamePopover = false
            } label: {
                Label(L10n.tr("清空本页全部 8 个槽位", "Clear All 8 Slots on This Page", language: lang), systemImage: "trash")
            }
        }
        .padding(16)
    }

    // MARK: - Realistic 2x4 Chocolate Touch Bar Frame

    private var chocolateHardwarePreview: some View {
        let pageIdx = currentPage.index
        let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 4)

        return HStack(spacing: 16) {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(0..<BarPage.slotsPerPage, id: \.self) { slotIdx in
                    let slotItem = currentPage.slots[slotIdx]
                    let iconData = slotItem?.bundleIdentifier.flatMap { coordinator.catalogService.iconData(forBundleID: $0) }
                    let isFrontmost = (slotItem?.bundleIdentifier != nil && slotItem?.bundleIdentifier == coordinator.timeTravel.frontmostBundleID)

                    slotCell(
                        pageIndex: pageIdx,
                        slotIndex: slotIdx,
                        item: slotItem,
                        iconData: iconData,
                        isFrontmost: isFrontmost
                    )
                    .aspectRatio(1.0, contentMode: .fit)
                }
            }
            .frame(maxWidth: 590)

            // Companion Side Rail Preview (mirrors the iPhone landscape rail!)
            VStack(spacing: 14) {
                Circle()
                    .fill(coordinator.server.connectedDeviceCount > 0 ? Color.green : palette.accentGold)
                    .frame(width: 8, height: 8)
                    .shadow(color: (coordinator.server.connectedDeviceCount > 0 ? Color.green : palette.accentGold).opacity(0.8), radius: 4)

                VStack(spacing: 5) {
                    ForEach(0..<BarPage.maxPages, id: \.self) { dotIdx in
                        Circle()
                            .fill(dotIdx == pageIdx ? palette.primaryText : palette.secondaryText.opacity(0.35))
                            .frame(width: dotIdx == pageIdx ? 6 : 4.5, height: dotIdx == pageIdx ? 6 : 4.5)
                            .onTapGesture {
                                coordinator.selectedPageIndex = dotIdx
                            }
                    }
                }

                Spacer(minLength: 4)

                Button {
                    coordinator.selectedSection = .timeTravel
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("切换到应用时间旅行", "Open App Time Travel", language: lang))

                Button {
                    coordinator.selectedSection = .emojiBar
                } label: {
                    Image(systemName: "face.smiling.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("切换到表情栏编辑", "Open Emoji Bar Editor", language: lang))
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 10)
            .background(palette.backgroundBottom.opacity(0.65), in: Capsule())
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.backgroundTop, palette.backgroundBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .strokeBorder(palette.tileBorderHighlight.opacity(0.55), lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 10)
        )
    }

    private func slotCell(
        pageIndex: Int,
        slotIndex: Int,
        item: BarItem?,
        iconData: Data?,
        isFrontmost: Bool
    ) -> some View {
        let isHovered = (hoveredSlotIndex == slotIndex)

        return ZStack(alignment: .topTrailing) {
            Button {
                editingSlot = EditingSlotTarget(pageIndex: pageIndex, slotIndex: slotIndex)
            } label: {
                ChocBarTileCard(
                    item: item,
                    iconData: iconData,
                    isFrontmostApp: isFrontmost,
                    palette: palette,
                    language: lang
                )
                .scaleEffect(isHovered ? 1.025 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isHovered)
            }
            .buttonStyle(.plain)

            if let item, isHovered {
                HStack(spacing: 4) {
                    Button {
                        coordinator.executeBarItem(item, triggeredBy: "Mac Studio")
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.black.opacity(0.65), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("立即在 Mac 上测试运行", "Test Trigger on Mac", language: lang))

                    Button {
                        coordinator.setSlotItem(nil, pageIndex: pageIndex, slotIndex: slotIndex)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.red.opacity(0.8), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("移除", "Clear Slot", language: lang))
                }
                .padding(6)
            }
        }
        .onHover { hovering in
            hoveredSlotIndex = hovering ? slotIndex : (hoveredSlotIndex == slotIndex ? nil : hoveredSlotIndex)
        }
        .onDrag {
            draggedSlotIndex = slotIndex
            return NSItemProvider(object: "choclift-slot:\(slotIndex)" as NSString)
        }
        .onDrop(of: [.plainText, .fileURL, .url], isTargeted: nil) { providers in
            handleDrop(providers: providers, pageIndex: pageIndex, targetSlot: slotIndex)
        }
        .contextMenu {
            Button {
                editingSlot = EditingSlotTarget(pageIndex: pageIndex, slotIndex: slotIndex)
            } label: {
                Label(L10n.tr("配置槽位…", "Configure Slot…", language: lang), systemImage: "pencil")
            }

            if let item {
                Button {
                    coordinator.executeBarItem(item, triggeredBy: "Mac Studio")
                } label: {
                    Label(L10n.tr("立即执行测试", "Trigger Action Now", language: lang), systemImage: "play.fill")
                }

                Divider()

                Button(role: .destructive) {
                    coordinator.setSlotItem(nil, pageIndex: pageIndex, slotIndex: slotIndex)
                } label: {
                    Label(L10n.tr("清空槽位", "Clear Slot", language: lang), systemImage: "trash")
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider], pageIndex: Int, targetSlot: Int) -> Bool {
        // 1. Internal slot-to-slot swap
        if let fromSlot = draggedSlotIndex {
            draggedSlotIndex = nil
            coordinator.swapSlots(pageIndex: pageIndex, fromSlot: fromSlot, toSlot: targetSlot)
            return true
        }

        // 2. External .app file or browser URL drop
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let rawData = data as? Data,
                          let fileURL = URL(dataRepresentation: rawData, relativeTo: nil) else { return }
                    Task { @MainActor in
                        _ = coordinator.handleDroppedFileOrURL(fileURL, pageIndex: pageIndex, slotIndex: targetSlot)
                    }
                }
                return true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    let resolvedURL: URL? = {
                        if let u = item as? URL { return u }
                        if let d = item as? Data { return URL(dataRepresentation: d, relativeTo: nil) }
                        return nil
                    }()
                    guard let webURL = resolvedURL else { return }
                    Task { @MainActor in
                        _ = coordinator.handleDroppedFileOrURL(webURL, pageIndex: pageIndex, slotIndex: targetSlot)
                    }
                }
                return true
            }
        }
        return false
    }

    private var bottomHintBar: some View {
        HStack(spacing: 18) {
            Label(
                L10n.tr("点击任意方块配置应用 / 快捷指令 / 网址", "Click any square to assign an App, Shortcut, or Website", language: lang),
                systemImage: "hand.point.up.left.fill"
            )
            Text("·")
            Label(
                L10n.tr("支持从访达直接拖入 .app 或从浏览器拖入网址，拖拽方块可互换位置", "Drag .app bundles or URLs directly onto squares, or drag squares to reorder", language: lang),
                systemImage: "arrow.up.and.down.and.arrow.left.and.right"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
