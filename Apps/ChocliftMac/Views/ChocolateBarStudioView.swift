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

    private var filledSlotCount: Int {
        currentPage.slots.compactMap { $0 }.count
    }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 16) {
            pageSelectorStrip

            if filledSlotCount == 0 {
                emptyPageCallout
            }

            chocolateHardwarePreview
                .frame(maxHeight: .infinity)

            bottomHintBar
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
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

    // MARK: - 8-Page Top Strip

    private var pageSelectorStrip: some View {
        HStack(spacing: 7) {
            ForEach(coordinator.profile.pages) { page in
                let isSelected = (page.index == coordinator.selectedPageIndex)
                let count = page.slots.compactMap { $0 }.count

                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        coordinator.selectedPageIndex = page.index
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(page.iconEmoji)
                            .font(.system(size: 14))
                        if isSelected {
                            Text(page.title)
                                .font(.system(.callout, design: .rounded, weight: .bold))
                                .lineLimit(1)
                            Text("\(count)/\(BarPage.slotsPerPage)")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(palette.secondaryText)
                        } else {
                            Text("\(page.index + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.secondaryText)
                            if count > 0 {
                                Circle()
                                    .fill(palette.secondaryText.opacity(0.65))
                                    .frame(width: 4.5, height: 4.5)
                            }
                        }
                    }
                    .padding(.horizontal, isSelected ? 13 : 10)
                    .padding(.vertical, 7)
                    .background(
                        isSelected
                            ? palette.tileFillTop.opacity(0.95)
                            : palette.barSurface.opacity(0.75),
                        in: Capsule()
                    )
                    .foregroundStyle(isSelected ? palette.primaryText : palette.secondaryText)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isSelected ? palette.accent.opacity(0.85) : palette.subtleCardStroke,
                                lineWidth: 1
                            )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            Button {
                showPageRenamePopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                    Text(L10n.tr("页面设置", "Page Setup", language: lang))
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(palette.primaryText)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(palette.barSurface, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("编辑当前页面名称、图标或清空整页", "Rename page, pick icon, or clear slots", language: lang))
            .popover(isPresented: $showPageRenamePopover) {
                pageMetadataEditor
            }
        }
    }

    private var emptyPageCallout: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.callout.weight(.bold))
                .foregroundStyle(palette.secondaryText)
            Text(
                L10n.tr(
                    "「\(currentPage.title)」当前为空页 — 点击下方任意巧克力格添加应用、快捷指令、网页或系统动作，也可直接从访达拖入 .app。",
                    "\"\(currentPage.title)\" is empty — click any molded square below to assign an App, Shortcut, Website, or Action, or drag in an .app.",
                    language: lang
                )
            )
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                editingSlot = EditingSlotTarget(pageIndex: currentPage.index, slotIndex: 0)
            } label: {
                Text(L10n.tr("配置第 1 格…", "Assign Slot #1…", language: lang))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(palette.accent, in: Capsule())
                    .foregroundStyle(palette.accentForeground)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var pageMetadataEditor: some View {
        let idx = coordinator.selectedPageIndex
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("第 \(idx + 1) 页设置", "Page #\(idx + 1) Settings", language: lang))
                .font(.headline)
                .foregroundStyle(palette.primaryText)

            LabeledContent(L10n.tr("页面名称", "Title", language: lang)) {
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
                .frame(width: 164)
            }
            .foregroundStyle(palette.secondaryText)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("页面图标", "Page Icon", language: lang))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                    ForEach(["🍫", "🚀", "⚡️", "🌐", "🔮", "🎨", "🎧", "🌙", "💼", "⭐️"], id: \.self) { em in
                        let isCur = coordinator.profile.pages[idx].iconEmoji == em
                        Button {
                            coordinator.mutateProfile { $0.pages[idx].iconEmoji = em }
                        } label: {
                            Text(em)
                                .font(.system(size: 16))
                                .frame(width: 32, height: 30)
                                .background(
                                    isCur ? palette.accent.opacity(0.20) : palette.tileFillBottom,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(isCur ? palette.accent : palette.subtleCardStroke, lineWidth: isCur ? 1.5 : 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
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
                Label(L10n.tr("清空本页全部 8 个槽位", "Clear All 8 Slots on Page", language: lang), systemImage: "trash")
                    .foregroundStyle(palette.statusFailure)
            }
            .disabled(filledSlotCount == 0)
        }
        .padding(16)
        .frame(width: 260)
        .background(palette.barSurface)
        .tint(palette.accent)
        .preferredColorScheme(.light)
    }

    // MARK: - Realistic 2x4 Chocolate Touch Bar Frame

    private var chocolateHardwarePreview: some View {
        let pageIdx = currentPage.index
        let columns = Array(repeating: GridItem(.flexible(), spacing: 15), count: 4)
        let activeLink = coordinator.server.pairedDevices.first(where: \.isCurrentlyConnected)?.activeLink

        return HStack(spacing: 16) {
            LazyVGrid(columns: columns, spacing: 15) {
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
            .frame(maxWidth: 600)

            // Companion Side Rail Preview (mirrors the iPhone landscape rail)
            VStack(spacing: 12) {
                Button {
                    coordinator.showPairingPopover = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(palette.tileFillTop)
                            .frame(width: 30, height: 30)
                        if let activeLink {
                            Image(systemName: activeLink.sfSymbol)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(activeLink == .bluetooth ? palette.statusBluetooth : palette.statusConnected)
                        } else {
                            Circle()
                                .fill(coordinator.server.connectedDeviceCount > 0 ? palette.statusConnected : palette.secondaryText)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("查看伴侣连接与配对码", "Companion Link & Pairing PIN", language: lang))

                VStack(spacing: 3) {
                    ForEach(0..<BarPage.maxPages, id: \.self) { dotIdx in
                        Button {
                            coordinator.selectedPageIndex = dotIdx
                        } label: {
                            Circle()
                                .fill(dotIdx == pageIdx ? palette.accent : palette.secondaryText.opacity(0.35))
                                .frame(width: dotIdx == pageIdx ? 6.5 : 4.5, height: dotIdx == pageIdx ? 6.5 : 4.5)
                                .frame(width: 22, height: 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    coordinator.selectedSection = .timeTravel
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 30, height: 30)
                        .background(palette.tileFillBottom.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L10n.tr("切换到应用时间旅行", "Open App Time Travel", language: lang))

                Button {
                    coordinator.selectedSection = .emojiBar
                } label: {
                    Image(systemName: "face.smiling.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 30, height: 30)
                        .background(palette.tileFillBottom.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L10n.tr("切换到表情栏编辑", "Open Emoji Bar Editor", language: lang))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(palette.backgroundBottom.opacity(0.7), in: Capsule())
            .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.backgroundTop, palette.backgroundBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(palette.tileBorderHighlight, lineWidth: 1.8)
                )
                .shadow(color: palette.primaryText.opacity(0.08), radius: 16, x: 0, y: 8)
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
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
            }
            .buttonStyle(.plain)

            if let item, isHovered {
                HStack(spacing: 4) {
                    Button {
                        coordinator.executeBarItem(item, triggeredBy: "Mac Studio")
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                            .frame(width: 22, height: 22)
                            .background(palette.backgroundBottom.opacity(0.86), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("立即在 Mac 上测试运行", "Test Trigger on Mac", language: lang))

                    Button {
                        coordinator.setSlotItem(nil, pageIndex: pageIndex, slotIndex: slotIndex)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.accentForeground)
                            .frame(width: 22, height: 22)
                            .background(palette.statusFailure.opacity(0.92), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("清空此槽位", "Clear Slot", language: lang))
                }
                .padding(7)
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
        if let fromSlot = draggedSlotIndex {
            draggedSlotIndex = nil
            coordinator.swapSlots(pageIndex: pageIndex, fromSlot: fromSlot, toSlot: targetSlot)
            return true
        }

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
        HStack(spacing: 14) {
            Label(
                L10n.tr("点击方块分配动作", "Click a square to assign", language: lang),
                systemImage: "hand.point.up.left.fill"
            )
            Text("·")
                .foregroundStyle(palette.secondaryText.opacity(0.6))
            Label(
                L10n.tr("拖入 .app 或网址即可添加，拖动方块可互换位置", "Drop .app bundles or URLs directly, or drag tiles to swap", language: lang),
                systemImage: "arrow.up.and.down.and.arrow.left.and.right"
            )
        }
        .font(.caption)
        .foregroundStyle(palette.secondaryText)
    }
}
