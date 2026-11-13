import AppKit
import ChocliftCore
import SwiftUI

@MainActor
public final class NotchPanelPresentationState: ObservableObject {
    @Published public var anchor: NotchPanelAnchor = .topNotch
    @Published public var hoveredSlotIndex: Int?
    @Published public var pressedSlotIndex: Int?
    @Published public var openFolderSlotIndex: Int?
    @Published public var inlineFeedback: String?

    private var feedbackTask: Task<Void, Never>?

    public init() {}

    public func flashFeedback(_ message: String) {
        feedbackTask?.cancel()
        inlineFeedback = message
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            if self?.inlineFeedback == message {
                self?.inlineFeedback = nil
            }
        }
    }
}

public struct MacNotchPanelView: View {
    public static let tileSide: CGFloat = 76
    public static let gridSpacing: CGFloat = 10
    public static let cardWidth: CGFloat = (tileSide * 4) + (gridSpacing * 3) + 28 // 362
    public static let cardHeight: CGFloat = 232
    public static let shadowHorizontalPadding: CGFloat = 16
    public static let shadowBottomPadding: CGFloat = 18
    public static let shadowTopPadding: CGFloat = 2

    public static var windowSize: CGSize {
        CGSize(
            width: cardWidth + shadowHorizontalPadding * 2,
            height: cardHeight + shadowTopPadding + shadowBottomPadding
        )
    }

    @ObservedObject var coordinator: MacAppCoordinator
    @ObservedObject var presentation: NotchPanelPresentationState
    let onTriggerSlot: (Int, BarItem?) -> Void
    let onSlotPressChanged: (Int, Bool) -> Void
    let onOpenStudio: () -> Void
    let onDismiss: () -> Void

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    private var safePageCount: Int {
        max(1, coordinator.profile.pages.count)
    }

    private var safePageIndex: Int {
        min(max(0, coordinator.selectedPageIndex), safePageCount - 1)
    }

    private var currentPage: BarPage {
        guard !coordinator.profile.pages.isEmpty else {
            return BarPage(index: 0, title: "Daily", iconEmoji: "🍫")
        }
        return coordinator.profile.pages[safePageIndex]
    }

    private var activeFolder: TileFolder? {
        guard let idx = presentation.openFolderSlotIndex,
              currentPage.slots.indices.contains(idx),
              case .folder(let folder) = currentPage.slots[idx]?.kind else {
            return nil
        }
        return folder
    }

    public init(
        coordinator: MacAppCoordinator,
        presentation: NotchPanelPresentationState,
        onTriggerSlot: @escaping (Int, BarItem?) -> Void,
        onSlotPressChanged: @escaping (Int, Bool) -> Void = { _, _ in },
        onOpenStudio: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.presentation = presentation
        self.onTriggerSlot = onTriggerSlot
        self.onSlotPressChanged = onSlotPressChanged
        self.onOpenStudio = onOpenStudio
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 10) {
            headerBar

            tileGrid
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 13)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.backgroundTop, palette.backgroundBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(palette.tileBorderHighlight, lineWidth: 1.5)
                )
                .shadow(color: palette.primaryText.opacity(0.14), radius: 14, x: 0, y: 6)
        )
        .padding(.horizontal, Self.shadowHorizontalPadding)
        .padding(.top, Self.shadowTopPadding)
        .padding(.bottom, Self.shadowBottomPadding)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .preferredColorScheme(.light)
    }

    private var headerBar: some View {
        HStack(spacing: 7) {
            if let activeFolder {
                Button {
                    presentation.openFolderSlotIndex = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                        Text(activeFolder.emoji)
                            .font(.system(size: 13))
                        Text(activeFolder.displayTitle(in: lang))
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(palette.primaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(palette.barSurface.opacity(0.92), in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 5) {
                    Text(currentPage.iconEmoji)
                        .font(.system(size: 13.5))
                    Text(currentPage.title)
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Text("\(safePageIndex + 1)/\(safePageCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.secondaryText)
                }
            }

            if let feedback = presentation.inlineFeedback {
                Text(feedback)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.accent.opacity(0.12), in: Capsule())
                    .transition(.opacity)
            }

            Spacer(minLength: 4)

            pageSwitcherControl

            if DisplaySnapTargetResolver.shouldShowPicker(for: coordinator.connectedDisplays) {
                displayPickerControl
            }

            undoWindowMoveControl

            Button {
                onOpenStudio()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 24, height: 22)
                    .background(palette.barSurface.opacity(0.88), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 0.8)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(L10n.tr("打开 Choclift 工作台", "Open Choclift Studio", language: lang))

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(palette.barSurface.opacity(0.88), in: Circle())
                    .overlay(Circle().strokeBorder(palette.subtleCardStroke, lineWidth: 0.8))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("收起悬浮栏 (Esc)", "Hide Panel (Esc)", language: lang))
        }
        .frame(height: 24)
        .animation(.easeInOut(duration: 0.15), value: presentation.inlineFeedback)
    }

    private var pageSwitcherControl: some View {
        HStack(spacing: 4) {
            Button {
                stepPage(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 3.5) {
                ForEach(0..<safePageCount, id: \.self) { dotIdx in
                    let isSelected = (dotIdx == safePageIndex)
                    Button {
                        coordinator.selectedPageIndex = dotIdx
                    } label: {
                        Circle()
                            .fill(isSelected ? palette.accent : palette.secondaryText.opacity(0.32))
                            .frame(width: isSelected ? 6 : 4.5, height: isSelected ? 6 : 4.5)
                            .frame(width: 9, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                stepPage(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        .background(palette.barSurface.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 0.8))
    }

    private var undoWindowMoveControl: some View {
        let canUndo = coordinator.canUndoWindowMove

        return Button {
            guard coordinator.canUndoWindowMove else { return }
            let sourceName = L10n.tr("Mac 悬浮栏", "Mac Notch Bar", language: lang)
            if case .restored = coordinator.undoLastWindowMove(triggeredBy: sourceName) {
                presentation.flashFeedback("✓ \(L10n.tr("已撤销窗口移动", "Undid Window Move", language: lang))")
            }
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(canUndo ? palette.accent : palette.secondaryText.opacity(0.42))
                .frame(width: 24, height: 22)
                .background(
                    (canUndo ? palette.accent.opacity(0.14) : palette.barSurface.opacity(0.68)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            canUndo ? palette.accent.opacity(0.55) : palette.subtleCardStroke,
                            lineWidth: 0.8
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mac-notch-undo-window-move")
        .help(L10n.tr("撤销上次窗口移动", "Undo Last Window Move", language: lang))
    }

    private var displayPickerControl: some View {
        let selectedID = DisplaySnapTargetResolver.resolvedTargetDisplayID(
            selectedDisplayID: coordinator.selectedTargetDisplayID,
            connectedDisplays: coordinator.connectedDisplays
        )
        let isCustomDisplay = (selectedID != nil)

        return Menu {
            Button {
                coordinator.setTargetDisplay(displayID: nil)
            } label: {
                HStack {
                    Text(L10n.tr("当前窗口所在屏幕（默认）", "Frontmost Window Display (Default)", language: lang))
                    if selectedID == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(coordinator.connectedDisplays) { display in
                Button {
                    coordinator.setTargetDisplay(displayID: display.displayID)
                } label: {
                    HStack {
                        Text(display.name)
                        if selectedID == display.displayID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "display.2")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isCustomDisplay ? palette.accent : palette.secondaryText)
                .frame(width: 24, height: 22)
                .background(
                    (isCustomDisplay ? palette.accent.opacity(0.14) : palette.barSurface.opacity(0.88)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isCustomDisplay ? palette.accent.opacity(0.55) : palette.subtleCardStroke,
                            lineWidth: 0.8
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("mac-notch-display-picker")
        .help(L10n.tr("选择窗口贴靠目标显示器", "Choose target display for window snap", language: lang))
    }

    private var tileGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(Self.tileSide), spacing: Self.gridSpacing), count: 4)
        let frontmostBundleID = coordinator.timeTravel.frontmostBundleID

        return LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
            ForEach(0..<BarPage.slotsPerPage, id: \.self) { slotIdx in
                let slotItem: BarItem? = {
                    if let activeFolder {
                        return activeFolder.children.indices.contains(slotIdx) ? activeFolder.children[slotIdx] : nil
                    }
                    return currentPage.slots.indices.contains(slotIdx) ? currentPage.slots[slotIdx] : nil
                }()
                let iconData = slotItem?.bundleIdentifier.flatMap { coordinator.catalogService.iconData(forBundleID: $0) }
                let isFrontmost = (slotItem?.bundleIdentifier != nil && slotItem?.bundleIdentifier == frontmostBundleID)
                let isHovered = (presentation.hoveredSlotIndex == slotIdx)
                let isPressed = (presentation.pressedSlotIndex == slotIdx)

                tileCell(
                    slotIndex: slotIdx,
                    item: slotItem,
                    iconData: iconData,
                    isFrontmost: isFrontmost,
                    isHovered: isHovered,
                    isPressed: isPressed
                )
                .frame(width: Self.tileSide, height: Self.tileSide)
            }
        }
    }

    @ViewBuilder
    private func tileCell(
        slotIndex: Int,
        item: BarItem?,
        iconData: Data?,
        isFrontmost: Bool,
        isHovered: Bool,
        isPressed: Bool
    ) -> some View {
        if let item {
            let origin = SlotCoordinate(pageID: currentPage.id, slotIndex: slotIndex)
            let isBrokenRef = item.isSlotReference && coordinator.profile.resolveBarItem(item, from: origin).isMissing

            Button {
                guard !isBrokenRef else { return }
                if activeFolder == nil, item.isFolder {
                    presentation.openFolderSlotIndex = slotIndex
                } else {
                    onTriggerSlot(slotIndex, item)
                }
            } label: {
                ChocBarTileCard(
                    item: item,
                    iconData: iconData,
                    isFrontmostApp: isFrontmost,
                    isPressed: isPressed && !isBrokenRef,
                    isAwaitingConfirmation: false,
                    palette: palette,
                    language: lang,
                    compact: true,
                    profile: coordinator.profile,
                    slotOrigin: origin,
                    iconLookup: { coordinator.catalogService.iconData(forBundleID: $0) }
                )
            }
            .buttonStyle(
                NotchTileButtonStyle(
                    slotIndex: slotIndex,
                    isHovered: isHovered,
                    isExternallyPressed: isPressed && !isBrokenRef,
                    accent: palette.accent,
                    onPressChanged: onSlotPressChanged
                )
            )
            .accessibilityLabel(coordinator.profile.displayTitle(for: item, from: origin, in: lang))
        } else {
            Button {
                if let folderSlotIdx = presentation.openFolderSlotIndex {
                    onTriggerSlot(folderSlotIdx, nil)
                } else {
                    onTriggerSlot(slotIndex, nil)
                }
            } label: {
                ChocBarTileCard(
                    item: nil,
                    iconData: nil,
                    isFrontmostApp: false,
                    isPressed: isPressed,
                    isAwaitingConfirmation: false,
                    palette: palette,
                    language: lang,
                    compact: true
                )
                .opacity(isPressed ? 1.0 : (isHovered ? 0.92 : 0.68))
            }
            .buttonStyle(
                NotchTileButtonStyle(
                    slotIndex: slotIndex,
                    isHovered: isHovered,
                    isExternallyPressed: isPressed,
                    accent: palette.accent,
                    onPressChanged: onSlotPressChanged
                )
            )
            .help(L10n.tr("点击在工作台中分配此槽位", "Assign this slot in Choclift Studio", language: lang))
        }
    }

    private func stepPage(by delta: Int) {
        let count = safePageCount
        guard count > 0 else { return }
        presentation.openFolderSlotIndex = nil
        coordinator.selectedPageIndex = (safePageIndex + delta + count) % count
    }

    /// Computes which of the 8 tile slots (if any) contains `pointInWindow` (AppKit bottom-left view coordinates).
    public static func hitTestSlotIndex(at pointInWindow: CGPoint) -> Int? {
        let gridOriginX = shadowHorizontalPadding + 14
        let gridWidth = (tileSide * 4) + (gridSpacing * 3)
        let gridHeight = (tileSide * 2) + gridSpacing
        let contentVStackHeight: CGFloat = 11 + 24 + 10 + gridHeight + 13
        let verticalSlack = max(0, (cardHeight - contentVStackHeight) / 2)
        let gridBottomY = shadowBottomPadding + 13 + verticalSlack

        let relX = pointInWindow.x - gridOriginX
        let relYFromBottom = pointInWindow.y - gridBottomY
        guard relX >= 0, relX <= gridWidth, relYFromBottom >= 0, relYFromBottom <= gridHeight else {
            return nil
        }

        let stride = tileSide + gridSpacing
        let col = Int(relX / stride)
        let colOffset = relX - CGFloat(col) * stride
        guard col >= 0, col < 4, colOffset <= tileSide else { return nil }

        // Row 0 is top row (higher Y in AppKit bottom-left coordinates); Row 1 is bottom row.
        let relYFromTop = gridHeight - relYFromBottom
        let row = Int(relYFromTop / stride)
        let rowOffset = relYFromTop - CGFloat(row) * stride
        guard row >= 0, row < 2, rowOffset <= tileSide else { return nil }

        return row * 4 + col
    }
}

private struct NotchTileButtonStyle: ButtonStyle {
    let slotIndex: Int
    let isHovered: Bool
    let isExternallyPressed: Bool
    let accent: Color
    let onPressChanged: (Int, Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        let activePressed = configuration.isPressed || isExternallyPressed
        configuration.label
            .scaleEffect(activePressed ? 0.94 : (isHovered ? 1.028 : 1.0))
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(
                        activePressed ? accent : (isHovered ? accent.opacity(0.55) : Color.clear),
                        lineWidth: activePressed ? 2.0 : 1.5
                    )
            )
            .animation(.easeOut(duration: 0.09), value: activePressed)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .onChange(of: configuration.isPressed) { pressing in
                onPressChanged(slotIndex, pressing)
            }
    }
}
