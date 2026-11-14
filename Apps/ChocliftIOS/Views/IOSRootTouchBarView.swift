import ChocliftCore
import SwiftUI
import UIKit

public enum IOSActiveSurfaceMode: String, CaseIterable, Identifiable {
    case chocolateBar
    case soundboard
    case timeTravel
    case emojiBar
    case gesturePad

    public var id: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .chocolateBar: return "square.grid.2x2.fill"
        case .soundboard: return "speaker.wave.2.bubble.left.fill"
        case .timeTravel: return "clock.arrow.circlepath"
        case .emojiBar: return "face.smiling.fill"
        case .gesturePad: return "hand.draw.fill"
        }
    }

    public func shortTitle(in lang: AppLanguage) -> String {
        switch self {
        case .chocolateBar: return L10n.tr("巧栏", "Bar", language: lang)
        case .soundboard: return L10n.tr("音效", "Sounds", language: lang)
        case .timeTravel: return L10n.tr("最近", "Recents", language: lang)
        case .emojiBar: return L10n.tr("表情", "Emoji", language: lang)
        case .gesturePad: return L10n.tr("手势", "Gestures", language: lang)
        }
    }
}

public struct IOSRootTouchBarView: View {
    private struct HUDToastBanner: Equatable {
        let id = UUID()
        let primaryText: String
        let secondaryText: String?
        let isFailure: Bool
    }

    @ObservedObject var client: CompanionClientEngine
    @Environment(\.scenePhase) private var scenePhase

    @State private var activeMode: IOSActiveSurfaceMode = .chocolateBar
    @State private var modeBeforeAutoEmoji: IOSActiveSurfaceMode?
    @State private var deckFollower = AppDeckFollowerState()
    @State private var isDeckSwitchHighlighted: Bool = false
    @State private var deckSwitchHighlightTask: Task<Void, Never>?
    @State private var currentEmojiSlideIndex: Int = 0
    @State private var currentEmojiSegment: IOSEmojiBarSegment = .emoji
    @State private var showToolsSheet = false
    @State private var showPairingSheet: Bool = false
    @State private var showFlowsManagerSheet: Bool = false
    @State private var showWorkspaceSearchSheet: Bool = false
    @State private var showIPadSoundboardSheet: Bool = false
    @State private var editingSlot: IOSEditSlotSelection?
    @State private var hudToast: HUDToastBanner?
    @State private var hudDismissTask: Task<Void, Never>?
    @State private var gestureConfirmGate = DestructiveActionConfirmGate()

    private var currentPageIndex: Int { deckFollower.currentPageIndex }
    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var visualState: ChocConnectionVisualState { ChocConnectionVisualState.resolve(from: client) }

    private var manualPageSelectionBinding: Binding<Int> {
        Binding(
            get: {
                guard !client.profile.pages.isEmpty else { return 0 }
                return min(max(0, deckFollower.currentPageIndex), client.profile.pages.count - 1)
            },
            set: { newIndex in
                guard !client.profile.pages.isEmpty else {
                    deckFollower.syncCurrentPage(with: client.profile)
                    return
                }
                deckFollower.selectManualPage(index: newIndex, in: client.profile)
            }
        )
    }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let isIPadWide = UIDevice.current.userInterfaceIdiom == .pad && geo.size.width >= 680 && geo.size.height >= 480

            ZStack {
                palette.backgroundTop.ignoresSafeArea()

                if isIPadWide {
                    iPadExpandedWorkspace(size: geo.size)
                } else if isLandscape {
                    iPhoneLandscapeTouchBar(totalWidth: geo.size.width)
                } else {
                    iPhonePortraitTouchBar
                }

                // Non-interactive HUD Toast
                if let hud = hudToast {
                    let cornerRadius: CGFloat = hud.secondaryText == nil ? 20 : 14
                    VStack {
                        HStack(spacing: 7) {
                            Image(systemName: hud.isFailure ? "exclamationmark.triangle.fill" : "sparkles")
                                .font(ChocType.caption)
                                .foregroundStyle(hud.isFailure ? palette.statusFailure : palette.accent)

                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(hud.primaryText)
                                    .font(ChocType.caption)
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(hud.secondaryText == nil ? 2 : 1)

                                if let secondary = hud.secondaryText {
                                    Text(secondary)
                                        .font(ChocType.micro)
                                        .foregroundStyle(hud.isFailure ? palette.statusFailure : palette.secondaryText)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            palette.barSurface.opacity(0.97),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(
                                    hud.isFailure ? palette.statusFailure.opacity(0.75) : palette.subtleCardStroke,
                                    lineWidth: hud.isFailure ? 1.3 : 1
                                )
                        )
                        .shadow(color: palette.primaryText.opacity(0.08), radius: 8, x: 0, y: 4)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        Spacer()
                    }
                    .zIndex(10)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("ios-feedback-toast")
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                IOSScreenshotPreviewOverlayCard(client: client)
                    .padding(.top, isIPadWide ? 60 : (isLandscape ? 48 : 56))
                    .padding(.trailing, (isLandscape && !isIPadWide) ? 68 : 18)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
            .animation(.easeInOut(duration: 0.2), value: hudToast)
            .animation(.easeInOut(duration: 0.2), value: client.latestScreenshotPreview)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showToolsSheet) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        HStack {
                            Button(L10n.tr("搜索", "Search", language: lang)) {
                                showToolsSheet = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showWorkspaceSearchSheet = true }
                            }
                            Spacer()
                            Button(L10n.tr("动作流", "Flows", language: lang)) {
                                showToolsSheet = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showFlowsManagerSheet = true }
                            }
                        }
                        .frame(minHeight: 44)
                        .buttonStyle(.bordered)
                        IOSPageReorderControls(client: client, activePageIndex: currentPageIndex, compact: false) { moveActiveBarPage($0) }
                        IOSPersistentControlStripView(client: client, preferSingleRow: false, secondaryOnly: true, onPromptHUD: { flashHUD($0) })
                        IOSCompanionBarRibbon(client: client, compact: false, onPromptHUD: { flashHUD($0) })
                        IOSCompactKeyAndRecentsBar(client: client, showInlineRecentChips: true, onPromptHUD: { flashHUD($0) })
                        IOSPinnedStripTilesRow(client: client, onPromptHUD: { flashHUD($0) }, onEditSlot: { selection in
                            showToolsSheet = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editingSlot = selection }
                        })
                        IOSFrontmostAppStripBadge(client: client)
                        IOSPrivacyCaptureStripBadge(client: client)
                        if client.orcaStatus != nil { IOSOrcaTaskStatusBar(client: client, compact: false) }
                    }
                    .padding(16)
                }
                .background(palette.backgroundTop)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(L10n.tr("Mac 控制", "Mac Controls", language: lang))
                            .font(ChocType.title)
                            .foregroundStyle(palette.primaryText)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "Done", language: lang)) { showToolsSheet = false }
                } }
            }
            .tint(palette.accent)
            .groupBoxStyle(ChocSurfaceGroupBoxStyle(palette: palette))
        }
        .sheet(isPresented: $showPairingSheet) {
            IOSPairingAndConnectionSheet(client: client)
        }
        .sheet(isPresented: $showFlowsManagerSheet) {
            IOSFlowsManagerSheet(client: client, defaultPageIndex: currentPageIndex)
        }
        .sheet(isPresented: $showWorkspaceSearchSheet) {
            IOSWorkspaceSearchSheet(client: client) { message in
                flashHUD(message)
            }
        }
        .sheet(isPresented: $showIPadSoundboardSheet) {
            IOSSoundboardSheet(
                client: client,
                currentBarPageIndex: currentPageIndex
            ) { message in
                flashHUD(message)
            }
        }
        .sheet(item: $editingSlot) { selection in
            IOSSlotEditorSheet(
                client: client,
                pageIndex: selection.pageIndex,
                slotIndex: selection.slotIndex,
                onEditOriginalSlot: { origPageIdx, origSlotIdx in
                    deckFollower.selectManualPage(index: origPageIdx, in: client.profile)
                    editingSlot = IOSEditSlotSelection(pageIndex: origPageIdx, slotIndex: origSlotIdx)
                }
            )
        }
        .onAppear {
            deckFollower.handleProfileUpdated(client.profile, frontmostBundleIdentifier: client.frontmostBundleID)
            client.startBrowsing()
            updateIdleTimer()
            if !client.connectionState.isConnected && client.savedMacs.isEmpty {
                showPairingSheet = true
            }
            #if DEBUG
            if let review = ProcessInfo.processInfo.environment["CHOCLIFT_REVIEW_SURFACE"] {
                activeMode = IOSActiveSurfaceMode(rawValue: review) ?? .chocolateBar
                showPairingSheet = review == "pairing"
                showToolsSheet = review == "tools"
            }
            #endif
        }
        .onChange(of: client.frontmostBundleID) { _, newBundleID in
            let previousPageID = deckFollower.currentPageID
            let wasFollowing = deckFollower.isFollowingFrontmostApp
            withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                deckFollower.handleFrontmostAppChanged(newBundleID, in: client.profile)
            }
            if wasFollowing,
               let updatedPageID = deckFollower.currentPageID,
               previousPageID != nil,
               updatedPageID != previousPageID {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                pulseDeckSwitchHighlight()
            }
        }
        .onChange(of: client.profile) { _, newProfile in
            withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
                deckFollower.handleProfileUpdated(newProfile, frontmostBundleIdentifier: client.frontmostBundleID)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                client.handleAppDidBecomeActive()
            }
        }
        .onChange(of: client.connectionState) { _, newState in
            updateIdleTimer()
            if case .awaitingPIN = newState, !showPairingSheet {
                showPairingSheet = true
            } else if newState.isConnected && showPairingSheet {
                showPairingSheet = false
            }
        }
        .onChange(of: client.profile.settings.keepCompanionScreenAwake) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: client.isEditingTextOnMac) { _, editing in
            guard client.profile.settings.autoShowEmojiBarWhenTyping else { return }
            if editing {
                if activeMode != .emojiBar {
                    modeBeforeAutoEmoji = activeMode
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        activeMode = .emojiBar
                    }
                }
            } else if client.profile.settings.autoReturnFromEmojiBarOnBlur,
                      let previous = modeBeforeAutoEmoji {
                modeBeforeAutoEmoji = nil
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    activeMode = previous
                }
            }
        }
        .onChange(of: client.lastFeedback) { _, toast in
            guard let toast else { return }
            presentFeedbackToast(toast)
        }
    }

    private var toolsButton: some View {
        Button { showToolsSheet = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(ChocType.body.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("Mac 控制", "Mac Controls", language: lang))
    }

    // MARK: - iPhone Landscape Touch Bar (Signature Layout)

    private func iPhoneLandscapeTouchBar(totalWidth: CGFloat) -> some View {
        portraitWorkspace(isWide: true)
    }

    // MARK: - iPhone Portrait Touch Bar

    private var iPhonePortraitTouchBar: some View {
        portraitWorkspace(isWide: false)
    }

    private func portraitWorkspace(isWide: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    // The active page and navigation share one header.
                    HStack(spacing: 8) {
                        Button { showToolsSheet = true } label: {
                            ChocliftBrandIconView(size: 30).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.tr("更多控制", "More Controls", language: lang))
                        Group {
                            if activeMode == .chocolateBar || activeMode == .emojiBar {
                                portraitPageStepperBar
                            } else {
                                Text(activeMode.shortTitle(in: lang)).font(ChocType.title)
                            }
                        }
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        connectionStatusPillButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)


                    VStack(spacing: 8) {
                        activeMainContent(isLandscape: isWide)
                    }
                    .padding(.horizontal, 16)

                }
                .padding(.bottom, 12)
            }
            // A layout sibling reserves the entire bar height, including on iPad.
            // Clip the scroll viewport so badges cannot render through the dock.
            .clipped()
            modeDock
        }
    }

    private var modeDock: some View {
        // Bottom Mode Switcher Dock (>= 44pt touch targets)
        HStack(spacing: 0) {
            ForEach(IOSActiveSurfaceMode.allCases) { mode in
                let selected = (activeMode == mode)
                Button {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                    modeBeforeAutoEmoji = nil
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) {
                        activeMode = mode
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mode.sfSymbol)
                            .font(.system(size: 22, weight: .semibold))
                        Text(mode.shortTitle(in: lang))
                            .font(ChocType.micro)
                            .lineLimit(1)
                    }
                    .foregroundStyle(selected ? palette.accent : palette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ios-mode-\(mode.rawValue)")
            }
        }
        .padding(.horizontal, 16)
        .background(palette.barSurface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(palette.subtleCardStroke).frame(height: 1)
        }
    }

    // MARK: - iPad Native Resizable Multi-Panel Workspace

    private func iPadExpandedWorkspace(size: CGSize) -> some View {
        portraitWorkspace(isWide: true)
    }

    private var iPadTimeTravelDockStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.tr("时间旅行 · 最近应用", "App Time Travel", language: lang), systemImage: "clock.arrow.circlepath")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                if !client.recentApps.isEmpty {
                    Text("\(client.recentApps.count)")
                        .font(ChocType.micro.monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                }
            }

            if client.recentApps.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: client.connectionState.isConnected ? "clock" : "laptopcomputer.slash")
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                    Text(
                        client.connectionState.isConnected
                            ? L10n.tr("在 Mac 上切换应用后将实时显示在此", "Switch apps on your Mac to populate Time Travel", language: lang)
                            : L10n.tr("连接 Mac 后即可一键切换最近打开的窗口", "Connect your Mac for one-tap recent window switching", language: lang)
                    )
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    Spacer()
                }
                .frame(height: 44)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(client.recentApps) { entry in
                            let icon = client.appIconsByBundleID[entry.bundleIdentifier] ?? BundledAppIcons.pngData(for: entry.bundleIdentifier)
                            Button {
                                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                                client.activateRecentApp(entry)
                            } label: {
                                HStack(spacing: 8) {
                                    DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                                        .frame(width: 28, height: 28)
                                    Text(entry.appName)
                                        .font(ChocType.caption)
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                    if entry.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(ChocType.micro)
                                            .foregroundStyle(palette.secondaryText)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 44)
                                .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .strokeBorder(entry.isFrontmost ? palette.accent : palette.subtleCardStroke, lineWidth: entry.isFrontmost ? 1.8 : 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(palette.barSurface.opacity(0.8), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    // MARK: - Subcomponents & Connection Status Controls

    @ViewBuilder
    private func activeMainContent(isLandscape: Bool) -> some View {
        switch activeMode {
        case .chocolateBar:
            IOSChocolateBarSurfaceView(
                client: client,
                currentPageIndex: manualPageSelectionBinding,
                isFollowingFrontmostApp: deckFollower.isFollowingFrontmostApp,
                isDeckSwitchHighlighted: isDeckSwitchHighlighted,
                onFollowFrontmostApp: resumeFollowingFrontmostApp,
                isLandscape: isLandscape,
                onPromptHUD: { message in
                    flashHUD(message)
                }
            ) { slot in
                editingSlot = slot
            }
        case .soundboard:
            IOSSoundboardSurfaceView(
                client: client,
                currentBarPageIndex: currentPageIndex,
                isLandscape: isLandscape,
                onPromptHUD: { message in
                    flashHUD(message)
                },
                onRequestPairing: { showPairingSheet = true }
            )
        case .timeTravel:
            IOSTimeTravelSurfaceView(
                client: client,
                isLandscape: isLandscape,
                currentBarPageIndex: currentPageIndex,
                onRequestPairing: { showPairingSheet = true },
                onPromptHUD: { message in
                    flashHUD(message)
                }
            )
        case .emojiBar:
            IOSEmojiBarSurfaceView(
                client: client,
                currentSlideIndex: $currentEmojiSlideIndex,
                activeSegment: $currentEmojiSegment,
                isLandscape: isLandscape
            )
        case .gesturePad:
            IOSGesturePadSurfaceView(
                client: client,
                isLandscape: isLandscape
            ) { gesture in
                triggerCompanionGesture(gesture)
            }
        }
    }

    private var railWorkspaceSearchButton: some View {
        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            showWorkspaceSearchSheet = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(ChocType.caption)
                .foregroundStyle(palette.primaryText)
                .frame(width: 44, height: 32)
                .background(
                    palette.tileFillBottom.opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-workspace-search-button")
        .accessibilityLabel(L10n.tr("搜索", "Search", language: lang))
    }

    private var workspaceQuickSearchButton: some View {
        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            showWorkspaceSearchSheet = true
        } label: {
            Image(systemName: "magnifyingglass")
                .font(ChocType.caption)
                .foregroundStyle(palette.primaryText)
                .frame(width: 38, height: 38)
                .background(palette.tileFillTop.opacity(0.9), in: Circle())
                .overlay(Circle().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-workspace-search-button")
        .accessibilityLabel(L10n.tr("搜索", "Search", language: lang))
    }

    /// Compact 44x44 rail button for iPhone landscape: shows Wi-Fi / BLE quietly when connected,
    /// and unmistakable state badges when connecting, failed, or unpaired.
    private var railFlowsManagerButton: some View {
        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            showFlowsManagerSheet = true
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(ChocType.caption)
                .foregroundStyle(palette.accent)
                .frame(width: 44, height: 32)
                .background(
                    palette.tileFillBottom.opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-flows-manager-button")
        .accessibilityLabel(L10n.tr("动作流", "Action Flows", language: lang))
    }

    private var flowsQuickManagerButton: some View {
        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            showFlowsManagerSheet = true
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(ChocType.caption)
                .foregroundStyle(palette.accent)
                .frame(width: 38, height: 38)
                .background(palette.tileFillTop.opacity(0.9), in: Circle())
                .overlay(Circle().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-flows-manager-button")
        .accessibilityLabel(L10n.tr("动作流", "Action Flows", language: lang))
    }

    private var railConnectionStatusButton: some View {
        let tint = visualState.tintColor(in: palette)

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            showPairingSheet = true
        } label: {
            VStack(spacing: 2) {
                if visualState.showsProgressSpinner {
                    ProgressView()
                        .scaleEffect(0.68)
                        .frame(height: 15)
                        .tint(tint)
                } else {
                    Image(systemName: visualState.sfSymbol)
                        .font(ChocType.caption)
                        .foregroundStyle(tint)
                        .frame(height: 15)
                }

                Text(visualState.railShortBadge(in: lang))
                    .font(ChocType.micro)
                    .foregroundStyle(visualState.isFailure ? tint : palette.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: 44, height: 42)
            .background(
                palette.tileFillBottom.opacity(0.92),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        visualState.isFailure ? palette.statusFailure.opacity(0.75) : tint.opacity(0.35),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-status-button")
        .accessibilityLabel(visualState.compactPillLabel(in: lang))
    }

    private var connectionDeviceName: String {
        switch visualState {
        case .connected(let name, _), .awaitingPIN(let name, _, _), .pairedStandby(let name, _):
            return name
        default:
            return client.savedMacs.first?.macName ?? L10n.tr("连接 Mac", "Connect Mac", language: lang)
        }
    }

    private var connectionStatusPillButton: some View {
        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            showPairingSheet = true
        } label: {
            Image(systemName: visualState.sfSymbol)
                .font(ChocType.body)
                .foregroundStyle(visualState.tintColor(in: palette))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-status-button")
        .accessibilityLabel(visualState.compactPillLabel(in: lang))
    }

    /// Contextual status banner shown ONLY when not connected so Empty, Connecting, Failed, and Standby
    /// states are unmistakable (and failures are never hidden behind a spinner).
    /// When the phone has a saved Mac and is disconnected, tapping the banner reconnects directly with the saved token.
    private func nonConnectedStatusBanner(compact: Bool) -> some View {
        let tint = visualState.tintColor(in: palette)
        let canOneTapReconnect = client.canOneTapReconnectFromBanner

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            if canOneTapReconnect {
                _ = client.reconnectFromDisconnectedBanner()
            } else {
                showPairingSheet = true
            }
        } label: {
            HStack(spacing: 10) {
                if visualState.showsProgressSpinner {
                    ProgressView()
                        .scaleEffect(0.78)
                        .frame(width: 18, height: 18)
                        .tint(tint)
                } else {
                    Image(systemName: visualState.sfSymbol)
                        .font(ChocType.caption)
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(visualState.bannerTitle(in: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    if !compact, let subtitle = visualState.bannerSubtitle(in: lang) {
                        Text(subtitle)
                            .font(ChocType.micro)
                            .foregroundStyle(visualState.isFailure ? tint.opacity(0.95) : palette.secondaryText)
                            .lineLimit(2)
                    } else if compact, visualState.isFailure, let subtitle = visualState.bannerSubtitle(in: lang) {
                        Text(subtitle)
                            .font(ChocType.micro)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Text(
                    canOneTapReconnect
                        ? L10n.tr("重连", "Reconnect", language: lang)
                        : (visualState.isFailure
                            ? L10n.tr("查看", "Fix", language: lang)
                            : (visualState.showsProgressSpinner
                                ? L10n.tr("详情", "Status", language: lang)
                                : L10n.tr("连接", "Pair", language: lang)))
                )
                .font(ChocType.micro)
                .foregroundStyle(palette.emphasisForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(visualState.isFailure ? palette.statusFailure : palette.accentEmphasis, in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, compact ? 7 : 9)
            .background(palette.barSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        visualState.isFailure ? palette.statusFailure.opacity(0.7) : palette.subtleCardStroke,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-status-banner")
    }

    private var verticalPagePillButton: some View {
        let isEmoji = (activeMode == .emojiBar)
        let count = isEmoji ? client.profile.emojiSlides.count : client.profile.pages.count
        let safeCount = max(1, count)
        let activeIdx = min(max(0, isEmoji ? currentEmojiSlideIndex : currentPageIndex), safeCount - 1)
        let activeName: String = {
            if isEmoji, client.profile.emojiSlides.indices.contains(activeIdx) {
                return PageSwitcherTitleFormatter.displayTitle(
                    rawTitle: client.profile.emojiSlides[activeIdx].title,
                    pageIndex: activeIdx,
                    language: lang
                )
            } else if !isEmoji, client.profile.pages.indices.contains(activeIdx) {
                return PageSwitcherTitleFormatter.displayTitle(
                    rawTitle: client.profile.pages[activeIdx].title,
                    pageIndex: activeIdx,
                    language: lang
                )
            }
            return PageSwitcherTitleFormatter.displayTitle(rawTitle: "", pageIndex: activeIdx, language: lang)
        }()

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            if isEmoji {
                currentEmojiSlideIndex = (activeIdx + 1) % safeCount
            } else {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                    deckFollower.stepManualPage(by: 1, in: client.profile)
                }
            }
        } label: {
            VStack(spacing: 3) {
                Text(activeName)
                    .font(ChocType.micro)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 3)
                HStack(spacing: 2.5) {
                    ForEach(0..<min(4, safeCount), id: \.self) { dot in
                        Circle()
                            .fill((activeIdx % 4) == dot ? palette.accent : palette.secondaryText.opacity(0.35))
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .frame(width: 44, height: 32)
            .background(palette.tileFillBottom.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-page-cycle-button")
        .accessibilityLabel(activeName)
    }

    private var portraitPageStepperBar: some View {
        let isEmoji = activeMode == .emojiBar
        let count = max(1, isEmoji ? client.profile.emojiSlides.count : client.profile.pages.count)
        let index = min(max(0, isEmoji ? currentEmojiSlideIndex : currentPageIndex), count - 1)
        let titles = isEmoji ? client.profile.emojiSlides.map(\.title) : client.profile.pages.map(\.title)
        let title = titles.indices.contains(index) ? titles[index] : L10n.tr("页面", "Page", language: lang)
        return Menu {
            ForEach(0..<count, id: \.self) { page in
                Button {
                    selectPageDot(index: page, count: count, isEmoji: isEmoji)
                } label: {
                    if page == index {
                        Label(titles.indices.contains(page) ? titles[page] : title, systemImage: "checkmark")
                    } else {
                        Text(titles.indices.contains(page) ? titles[page] : title)
                    }
                }
                .accessibilityIdentifier(isEmoji ? "ios-emoji-name-\(page)" : "ios-page-name-\(page)")
            }
            if !isEmoji {
                Section {
                    Button {
                        deckFollower.selectManualPage(index: index, in: client.profile)
                    } label: {
                        Label(L10n.tr("固定当前页", "Pin Current Page", language: lang), systemImage: deckFollower.isFollowingFrontmostApp ? "pin" : "pin.fill")
                    }
                    Button(action: resumeFollowingFrontmostApp) {
                        Label(L10n.tr("跟随前台应用", "Follow Frontmost App", language: lang), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!client.connectionState.isConnected)
                    .accessibilityIdentifier("ios-follow-frontmost-app-button")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(ChocType.title).lineLimit(1)
                Image(systemName: "chevron.down").font(ChocType.micro)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("ios-page-name-switcher")
        .foregroundStyle(palette.primaryText)
        .buttonStyle(.plain)
    }

    private var landscapePageDotsStepperBar: some View {
        let isEmoji = (activeMode == .emojiBar)
        let count = max(1, isEmoji ? client.profile.emojiSlides.count : client.profile.pages.count)
        let activeIdx = min(max(0, isEmoji ? currentEmojiSlideIndex : currentPageIndex), count - 1)

        return HStack(spacing: 7) {
            Button {
                stepPortraitPage(by: -1, count: count, isEmoji: isEmoji, current: activeIdx)
            } label: {
                Image(systemName: "chevron.left")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 34, height: 32)
                    .background(palette.tileFillBottom.opacity(0.88), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-page-prev-button")

            reachablePageNamesRow(count: count, isEmoji: isEmoji, activeIdx: activeIdx, compact: true)
                .frame(maxWidth: .infinity)
                .frame(height: 32)

            if !isEmoji {
                IOSPageReorderControls(
                    client: client,
                    activePageIndex: activeIdx,
                    compact: true
                ) { direction in
                    moveActiveBarPage(direction)
                }
            }

            reachablePageDotsRow(count: count, isEmoji: isEmoji, activeIdx: activeIdx)
                .padding(.horizontal, 6)
                .frame(width: min(140, CGFloat(count) * 16 + 12), height: 30)
                .background(palette.barSurface.opacity(0.88), in: Capsule())
                .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))

            Button {
                stepPortraitPage(by: 1, count: count, isEmoji: isEmoji, current: activeIdx)
            } label: {
                Image(systemName: "chevron.right")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 34, height: 32)
                    .background(palette.tileFillBottom.opacity(0.88), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-page-next-button")
        }
    }

    private func reachablePageNamesRow(count: Int, isEmoji: Bool, activeIdx: Int, compact: Bool) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { pageIdx in
                        let isSelected = (pageIdx == activeIdx)
                        let icon: String = {
                            if isEmoji, client.profile.emojiSlides.indices.contains(pageIdx) {
                                return client.profile.emojiSlides[pageIdx].iconEmoji
                            } else if !isEmoji, client.profile.pages.indices.contains(pageIdx) {
                                return client.profile.pages[pageIdx].iconEmoji
                            }
                            return "🍫"
                        }()
                        let rawTitle: String = {
                            if isEmoji, client.profile.emojiSlides.indices.contains(pageIdx) {
                                return client.profile.emojiSlides[pageIdx].title
                            } else if !isEmoji, client.profile.pages.indices.contains(pageIdx) {
                                return client.profile.pages[pageIdx].title
                            }
                            return ""
                        }()
                        let displayTitle = PageSwitcherTitleFormatter.displayTitle(
                            rawTitle: rawTitle,
                            pageIndex: pageIdx,
                            language: lang
                        )
                        let hasBoundApp: Bool = {
                            guard !isEmoji, client.profile.pages.indices.contains(pageIdx) else { return false }
                            let pageID = client.profile.pages[pageIdx].id
                            return !client.profile.boundBundleIdentifiers(forPageID: pageID).isEmpty
                        }()

                        Button {
                            selectPageDot(index: pageIdx, count: count, isEmoji: isEmoji)
                        } label: {
                            HStack(spacing: 4) {
                                Text(icon)
                                    .font(ChocType.caption)

                                MaxWidthPillTitleLayout(maxWidth: compact ? 96 : 112) {
                                    Text(displayTitle)
                                        .font(ChocType.caption)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }

                                if hasBoundApp {
                                    Image(systemName: "macwindow")
                                        .font(ChocType.micro)
                                        .opacity(isSelected ? 0.92 : 0.68)
                                }
                            }
                            .padding(.horizontal, compact ? 10 : 11)
                            .frame(height: compact ? 30 : 34)
                            .background(
                                isSelected ? palette.accent : palette.barSurface.opacity(0.92),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? palette.accentForeground : palette.primaryText)
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? .clear : palette.subtleCardStroke, lineWidth: 1)
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id("switcher-pill-\(isEmoji ? "emoji" : "page")-\(pageIdx)")
                        .accessibilityIdentifier(isEmoji ? "ios-emoji-name-\(pageIdx)" : "ios-page-name-\(pageIdx)")
                        .accessibilityLabel(displayTitle)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onAppear {
                scrollProxy.scrollTo("switcher-pill-\(isEmoji ? "emoji" : "page")-\(activeIdx)", anchor: .center)
            }
            .onChange(of: activeIdx) { _, nextIdx in
                withAnimation(.easeInOut(duration: 0.2)) {
                    scrollProxy.scrollTo("switcher-pill-\(isEmoji ? "emoji" : "page")-\(nextIdx)", anchor: .center)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios-page-name-switcher")
    }

    private func reachablePageDotsRow(count: Int, isEmoji: Bool, activeIdx: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { dotIdx in
                let isSelected = (dotIdx == activeIdx)
                let dotLabel: String = {
                    if isEmoji, client.profile.emojiSlides.indices.contains(dotIdx) {
                        return client.profile.emojiSlides[dotIdx].title
                    } else if !isEmoji, client.profile.pages.indices.contains(dotIdx) {
                        return client.profile.pages[dotIdx].title
                    }
                    return "\(dotIdx + 1)"
                }()

                Button {
                    selectPageDot(index: dotIdx, count: count, isEmoji: isEmoji)
                } label: {
                    ZStack {
                        if isSelected {
                            Capsule()
                                .fill(palette.accent)
                                .frame(width: 18, height: 7)
                        } else {
                            Circle()
                                .fill(palette.secondaryText.opacity(0.35))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(isEmoji ? "ios-emoji-dot-\(dotIdx)" : "ios-page-dot-\(dotIdx)")
                .accessibilityLabel(L10n.tr("第 \(dotIdx + 1) 页：\(dotLabel)", "Page \(dotIdx + 1): \(dotLabel)", language: lang))
            }
        }
    }

    private func selectPageDot(index: Int, count: Int, isEmoji: Bool) {
        guard count > 0 else { return }
        let clamped = min(max(0, index), count - 1)
        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            if isEmoji {
                currentEmojiSlideIndex = clamped
            } else {
                deckFollower.selectManualPage(index: clamped, in: client.profile)
            }
        }
    }

    private func stepPortraitPage(by delta: Int, count: Int, isEmoji: Bool, current: Int) {
        guard count > 0 else { return }
        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            if isEmoji {
                currentEmojiSlideIndex = (current + delta + count) % count
            } else {
                deckFollower.stepManualPage(by: delta, in: client.profile)
            }
        }
    }

    private func moveActiveBarPage(_ direction: PageReorderDirection) {
        guard !client.profile.pages.isEmpty else { return }
        deckFollower.syncCurrentPage(with: client.profile)
        let safeIdx = min(max(0, currentPageIndex), client.profile.pages.count - 1)
        let movingPageID = client.profile.pages[safeIdx].id
        guard client.movePage(withID: movingPageID, direction: direction) != nil else { return }
        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            deckFollower.handleProfileUpdated(
                client.profile,
                frontmostBundleIdentifier: client.frontmostBundleID
            )
        }
    }

    private func resumeFollowingFrontmostApp() {
        let previousPageID = deckFollower.currentPageID
        withAnimation(.spring(response: 0.30, dampingFraction: 0.85)) {
            deckFollower.followFrontmostApp(
                frontmostBundleIdentifier: client.frontmostBundleID,
                in: client.profile
            )
        }
        if deckFollower.currentPageID != previousPageID {
            pulseDeckSwitchHighlight()
        }
    }

    private func pulseDeckSwitchHighlight() {
        deckSwitchHighlightTask?.cancel()
        isDeckSwitchHighlighted = true
        deckSwitchHighlightTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            isDeckSwitchHighlighted = false
        }
    }

    // MARK: - Helpers

    private func triggerCompanionGesture(_ gesture: TouchGestureType) {
        let mapped = client.profile.gestureConfig.action(for: gesture)
        let isDestructive = mapped?.requiresDestructiveConfirmation ?? false
        let decision = gestureConfirmGate.registerTap(
            targetID: "gesture-\(gesture.rawValue)",
            isDestructive: isDestructive,
            at: ProcessInfo.processInfo.systemUptime
        )
        if case .requireSecondTap = decision {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            let label = mapped?.title(in: lang) ?? gesture.title(in: lang)
            flashHUD(L10n.tr("3 秒内再点一次确认：\(label)", "Tap again within 3s: \(label)", language: lang))
            let delay = CompanionInteractionPolicy.destructiveConfirmWindowSeconds + 0.05
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                gestureConfirmGate.expireIfNeeded(at: ProcessInfo.processInfo.systemUptime)
            }
            return
        }

        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .rigid)
        guard client.connectionState.isConnected else {
            client.lastFeedback = CompanionFeedbackToast(
                success: false,
                title: gesture.title(in: lang),
                detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
            )
            return
        }
        client.performGesture(gesture)
        if let mapped {
            showHUD(
                primary: "\(gesture.title(in: lang)) → \(mapped.title(in: lang))",
                secondary: nil,
                isFailure: false,
                duration: 1.8
            )
        } else {
            showHUD(primary: gesture.title(in: lang), secondary: nil, isFailure: false, duration: 1.8)
        }
    }

    private func presentFeedbackToast(_ toast: CompanionFeedbackToast) {
        let trimmedTitle = toast.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetail = (toast.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !toast.success {
            CompanionHaptics.notify(enabled: client.shouldPlayOutcomeHaptics(), type: .error)
            if !trimmedTitle.isEmpty,
               !trimmedDetail.isEmpty,
               trimmedTitle.caseInsensitiveCompare(trimmedDetail) != .orderedSame,
               !trimmedDetail.localizedCaseInsensitiveContains(trimmedTitle) {
                showHUD(primary: trimmedTitle, secondary: trimmedDetail, isFailure: true, duration: 3.0)
            } else {
                let fallback = !trimmedDetail.isEmpty
                    ? trimmedDetail
                    : (!trimmedTitle.isEmpty ? trimmedTitle : L10n.tr("操作执行失败", "Action Failed", language: lang))
                showHUD(primary: fallback, secondary: nil, isFailure: true, duration: 3.0)
            }
            return
        }

        CompanionHaptics.tap(enabled: client.shouldPlayOutcomeHaptics(), style: .light)
        let message = !trimmedDetail.isEmpty ? trimmedDetail : trimmedTitle
        guard !message.isEmpty else { return }
        showHUD(primary: message, secondary: nil, isFailure: false, duration: 1.8)
    }

    private func flashHUD(_ message: String) {
        showHUD(primary: message, secondary: nil, isFailure: false, duration: 2.2)
    }

    private func showHUD(primary: String, secondary: String?, isFailure: Bool, duration: TimeInterval) {
        hudDismissTask?.cancel()
        let banner = HUDToastBanner(primaryText: primary, secondaryText: secondary, isFailure: isFailure)
        hudToast = banner
        hudDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            if hudToast?.id == banner.id {
                hudToast = nil
            }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled =
            client.connectionState.isConnected && client.profile.settings.keepCompanionScreenAwake
    }
}
