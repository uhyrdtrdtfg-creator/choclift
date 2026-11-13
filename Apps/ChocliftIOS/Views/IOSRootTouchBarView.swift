import ChocliftCore
import SwiftUI
import UIKit

public enum IOSActiveSurfaceMode: String, CaseIterable, Identifiable {
    case chocolateBar
    case timeTravel
    case emojiBar
    case gesturePad

    public var id: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .chocolateBar: return "square.grid.2x2.fill"
        case .timeTravel: return "clock.arrow.circlepath"
        case .emojiBar: return "face.smiling.fill"
        case .gesturePad: return "hand.draw.fill"
        }
    }

    public func shortTitle(in lang: AppLanguage) -> String {
        switch self {
        case .chocolateBar: return L10n.tr("巧栏", "Bar", language: lang)
        case .timeTravel: return L10n.tr("最近", "Recents", language: lang)
        case .emojiBar: return L10n.tr("表情", "Emoji", language: lang)
        case .gesturePad: return L10n.tr("手势", "Gestures", language: lang)
        }
    }
}

public struct IOSRootTouchBarView: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.scenePhase) private var scenePhase

    @State private var activeMode: IOSActiveSurfaceMode = .chocolateBar
    @State private var modeBeforeAutoEmoji: IOSActiveSurfaceMode?
    @State private var deckFollower = AppDeckFollowerState()
    @State private var currentEmojiSlideIndex: Int = 0
    @State private var showPairingSheet: Bool = false
    @State private var showFlowsManagerSheet: Bool = false
    @State private var editingSlot: IOSEditSlotSelection?
    @State private var gestureHUDText: String?

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
                guard client.profile.pages.indices.contains(deckFollower.currentPageIndex) else {
                    deckFollower.syncCurrentPage(with: client.profile)
                    return
                }
                guard newIndex != deckFollower.currentPageIndex else { return }
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
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if isIPadWide {
                    iPadExpandedWorkspace(size: geo.size)
                } else if isLandscape {
                    iPhoneLandscapeTouchBar
                } else {
                    iPhonePortraitTouchBar
                }

                // Pass-through 2-finger & 3-finger Multi-Touch Recognizer:
                // yields nil in hitTest for 0/1-finger touches so buttons underneath receive taps directly.
                MultiTouchGestureCaptureView(
                    isEnabled: client.profile.gestureConfig.isGlobalOverlayEnabled
                ) { gesture in
                    triggerCompanionGesture(gesture)
                }
                .ignoresSafeArea()

                // Non-interactive HUD Toast
                if let hud = gestureHUDText {
                    VStack {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption2.bold())
                                .foregroundStyle(palette.accent)
                            Text(hud)
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(palette.barSurface.opacity(0.96), in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                        .shadow(color: palette.primaryText.opacity(0.08), radius: 8, x: 0, y: 4)
                        .padding(.top, 10)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: gestureHUDText)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showPairingSheet) {
            IOSPairingAndConnectionSheet(client: client)
        }
        .sheet(isPresented: $showFlowsManagerSheet) {
            IOSFlowsManagerSheet(client: client, defaultPageIndex: currentPageIndex)
        }
        .sheet(item: $editingSlot) { selection in
            IOSSlotEditorSheet(
                client: client,
                pageIndex: selection.pageIndex,
                slotIndex: selection.slotIndex
            )
        }
        .onAppear {
            deckFollower.handleProfileUpdated(client.profile, frontmostBundleIdentifier: client.frontmostBundleID)
            client.startBrowsing()
            updateIdleTimer()
            if !client.connectionState.isConnected && client.savedMacs.isEmpty {
                showPairingSheet = true
            }
        }
        .onChange(of: client.frontmostBundleID) { _, newBundleID in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                deckFollower.handleFrontmostAppChanged(newBundleID, in: client.profile)
            }
        }
        .onChange(of: client.profile) { _, newProfile in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
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
            flashHUD(toast.detail ?? toast.title)
        }
    }

    // MARK: - iPhone Landscape Touch Bar (Signature Layout)

    private var iPhoneLandscapeTouchBar: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if !client.connectionState.isConnected {
                    nonConnectedStatusBanner(compact: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                }

                activeMainContent(isLandscape: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Right-hand Vertical Control Rail — quiet link badge + generous 44pt mode targets
            VStack(spacing: 6) {
                railConnectionStatusButton

                railFlowsManagerButton

                if activeMode == .chocolateBar || activeMode == .emojiBar {
                    verticalPagePillButton
                }

                Spacer(minLength: 2)

                VStack(spacing: 7) {
                    ForEach(IOSActiveSurfaceMode.allCases) { mode in
                        let selected = (activeMode == mode)
                        Button {
                            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                            modeBeforeAutoEmoji = nil
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.8)) {
                                activeMode = mode
                            }
                        } label: {
                            Image(systemName: mode.sfSymbol)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(selected ? palette.accentForeground : palette.secondaryText)
                                .frame(width: 44, height: 40)
                                .background(
                                    selected ? palette.accent : palette.tileFillBottom.opacity(0.88),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(selected ? .clear : palette.subtleCardStroke, lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("ios-mode-\(mode.rawValue)")
                        .accessibilityLabel(mode.shortTitle(in: lang))
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(palette.barSurface.opacity(0.92))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(palette.subtleCardStroke)
                    .frame(width: 1)
            }
        }
    }

    // MARK: - iPhone Portrait Touch Bar

    private var iPhonePortraitTouchBar: some View {
        VStack(spacing: 8) {
            // Top Brand & Connection Status Header
            HStack(spacing: 10) {
                ChocliftBrandIconView(size: 30)
                Text("choclift")
                    .font(.system(.headline, design: .rounded, weight: .black))
                    .foregroundStyle(palette.primaryText)

                Spacer(minLength: 6)

                flowsQuickManagerButton

                connectionStatusPillButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            if !client.connectionState.isConnected {
                nonConnectedStatusBanner(compact: false)
                    .padding(.horizontal, 16)
            }

            if activeMode == .chocolateBar || activeMode == .emojiBar {
                portraitPageStepperBar
                    .padding(.horizontal, 16)
            }

            activeMainContent(isLandscape: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom Mode Switcher Dock (>= 44pt touch targets)
            HStack(spacing: 8) {
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
                                .font(.system(size: 15, weight: .bold))
                            Text(mode.shortTitle(in: lang))
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selected ? palette.accentForeground : palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            selected ? palette.accent : palette.tileFillBottom.opacity(0.85),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios-mode-\(mode.rawValue)")
                }
            }
            .padding(6)
            .background(palette.barSurface.opacity(0.94), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    // MARK: - iPad Native Resizable Multi-Panel Workspace

    private func iPadExpandedWorkspace(size: CGSize) -> some View {
        VStack(spacing: 12) {
            // Top Header with 8 Page Pills & Quiet Connection Status Pill
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    ChocliftBrandIconView(size: 32)
                    Text("choclift")
                        .font(.system(.title3, design: .rounded, weight: .black))
                        .foregroundStyle(palette.primaryText)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(client.profile.pages.enumerated()), id: \.element.id) { pageOffset, page in
                            let isSel = (currentPageIndex == pageOffset)
                            let hasBoundApp = !client.profile.boundBundleIdentifiers(forPageID: page.id).isEmpty
                            Button {
                                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                                    deckFollower.selectManualPage(index: pageOffset, in: client.profile)
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(page.iconEmoji)
                                    Text(page.title)
                                        .font(.system(.caption, design: .rounded, weight: .bold))
                                    if hasBoundApp {
                                        Image(systemName: "macwindow")
                                            .font(.system(size: 9, weight: .bold))
                                            .opacity(isSel ? 0.9 : 0.65)
                                    }
                                }
                                .padding(.horizontal, 13)
                                .frame(height: 38)
                                .background(isSel ? palette.accent : palette.tileFillBottom, in: Capsule())
                                .foregroundStyle(isSel ? palette.accentForeground : palette.primaryText)
                                .overlay(
                                    Capsule()
                                        .strokeBorder(isSel ? .clear : palette.subtleCardStroke, lineWidth: 1)
                                )
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 8)

                Button {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                    showFlowsManagerSheet = true
                } label: {
                    Label(L10n.tr("动作流", "Flows", language: lang), systemImage: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 38)
                        .background(palette.tileFillTop.opacity(0.9), in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                connectionStatusPillButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            if !client.connectionState.isConnected {
                nonConnectedStatusBanner(compact: true)
                    .padding(.horizontal, 18)
            }

            // Main Split: Left = Chocolate Bar + Time Travel Strip | Right = Emoji Bar + Gestures
            HStack(spacing: 14) {
                VStack(spacing: 12) {
                    IOSChocolateBarSurfaceView(
                        client: client,
                        currentPageIndex: manualPageSelectionBinding,
                        isFollowingFrontmostApp: deckFollower.isFollowingFrontmostApp,
                        onFollowFrontmostApp: resumeFollowingFrontmostApp,
                        isLandscape: true
                    ) { slot in
                        editingSlot = slot
                    }
                    .background(palette.barSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )

                    iPadTimeTravelDockStrip
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    IOSEmojiBarSurfaceView(
                        client: client,
                        currentSlideIndex: $currentEmojiSlideIndex,
                        isLandscape: true
                    )
                    .background(palette.barSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )

                    IOSGesturePadSurfaceView(
                        client: client,
                        isLandscape: false
                    ) { gesture in
                        triggerCompanionGesture(gesture)
                    }
                    .background(palette.barSurface.opacity(0.65), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )
                }
                .frame(width: min(368, size.width * 0.36))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
    }

    private var iPadTimeTravelDockStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.tr("时间旅行 · 最近应用", "App Time Travel", language: lang), systemImage: "clock.arrow.circlepath")
                    .font(.caption.bold())
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                if !client.recentApps.isEmpty {
                    Text("\(client.recentApps.count)")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(palette.secondaryText)
                }
            }

            if client.recentApps.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: client.connectionState.isConnected ? "clock" : "laptopcomputer.slash")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                    Text(
                        client.connectionState.isConnected
                            ? L10n.tr("在 Mac 上切换应用后将实时显示在此", "Switch apps on your Mac to populate Time Travel", language: lang)
                            : L10n.tr("连接 Mac 后即可一键切换最近打开的窗口", "Connect your Mac for one-tap recent window switching", language: lang)
                    )
                    .font(.caption)
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
                                        .font(.system(.caption, design: .rounded, weight: .bold))
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)
                                    if entry.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 9))
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
                onFollowFrontmostApp: resumeFollowingFrontmostApp,
                isLandscape: isLandscape
            ) { slot in
                editingSlot = slot
            }
        case .timeTravel:
            IOSTimeTravelSurfaceView(
                client: client,
                isLandscape: isLandscape,
                currentBarPageIndex: currentPageIndex,
                onRequestPairing: { showPairingSheet = true }
            )
        case .emojiBar:
            IOSEmojiBarSurfaceView(
                client: client,
                currentSlideIndex: $currentEmojiSlideIndex,
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

    /// Compact 44x44 rail button for iPhone landscape: shows Wi-Fi / BLE quietly when connected,
    /// and unmistakable state badges when connecting, failed, or unpaired.
    private var railFlowsManagerButton: some View {
        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            showFlowsManagerSheet = true
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(palette.accent)
                .frame(width: 44, height: 34)
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
                .font(.system(size: 13.5, weight: .bold))
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
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(height: 15)
                }

                Text(visualState.railShortBadge(in: lang))
                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(visualState.isFailure ? tint : palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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

    /// Quiet capsule status button for iPhone portrait & iPad headers.
    private var connectionStatusPillButton: some View {
        let tint = visualState.tintColor(in: palette)

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            showPairingSheet = true
        } label: {
            HStack(spacing: 6) {
                if visualState.showsProgressSpinner {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                        .tint(tint)
                } else if case .connected(_, let link) = visualState {
                    Circle()
                        .fill(palette.statusConnected)
                        .frame(width: 7, height: 7)
                    Image(systemName: link.sfSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                } else {
                    Image(systemName: visualState.sfSymbol)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(tint)
                }

                Text(visualState.compactPillLabel(in: lang))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(palette.tileFillTop.opacity(0.9), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        visualState.isFailure ? palette.statusFailure.opacity(0.75) : palette.subtleCardStroke,
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-status-button")
    }

    /// Contextual status banner shown ONLY when not connected so Empty, Connecting, Failed, and Standby
    /// states are unmistakable (and failures are never hidden behind a spinner).
    private func nonConnectedStatusBanner(compact: Bool) -> some View {
        let tint = visualState.tintColor(in: palette)

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            showPairingSheet = true
        } label: {
            HStack(spacing: 10) {
                if visualState.showsProgressSpinner {
                    ProgressView()
                        .scaleEffect(0.78)
                        .frame(width: 18, height: 18)
                        .tint(tint)
                } else {
                    Image(systemName: visualState.sfSymbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(visualState.bannerTitle(in: lang))
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    if !compact, let subtitle = visualState.bannerSubtitle(in: lang) {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(visualState.isFailure ? tint.opacity(0.95) : palette.secondaryText)
                            .lineLimit(2)
                    } else if compact, visualState.isFailure, let subtitle = visualState.bannerSubtitle(in: lang) {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Text(
                    visualState.isFailure
                        ? L10n.tr("查看", "Fix", language: lang)
                        : (visualState.showsProgressSpinner
                            ? L10n.tr("详情", "Status", language: lang)
                            : L10n.tr("连接", "Pair", language: lang))
                )
                .font(.system(size: 11, weight: .bold, design: .rounded))
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
        let count = (activeMode == .emojiBar) ? client.profile.emojiSlides.count : client.profile.pages.count
        let safeCount = max(1, count)
        let activeIdx = min(max(0, (activeMode == .emojiBar) ? currentEmojiSlideIndex : currentPageIndex), safeCount - 1)

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            if activeMode == .emojiBar {
                currentEmojiSlideIndex = (activeIdx + 1) % safeCount
            } else {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                    deckFollower.stepManualPage(by: 1, in: client.profile)
                }
            }
        } label: {
            VStack(spacing: 3) {
                Text("\(activeIdx + 1)/\(safeCount)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.primaryText)
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
    }

    private var portraitPageStepperBar: some View {
        let isEmoji = (activeMode == .emojiBar)
        let count = max(1, isEmoji ? client.profile.emojiSlides.count : client.profile.pages.count)
        let activeIdx = min(max(0, isEmoji ? currentEmojiSlideIndex : currentPageIndex), count - 1)
        let icon: String = {
            if isEmoji, client.profile.emojiSlides.indices.contains(activeIdx) {
                return client.profile.emojiSlides[activeIdx].iconEmoji
            } else if !isEmoji, client.profile.pages.indices.contains(activeIdx) {
                return client.profile.pages[activeIdx].iconEmoji
            }
            return "🍫"
        }()
        let title: String = {
            if isEmoji, client.profile.emojiSlides.indices.contains(activeIdx) {
                return client.profile.emojiSlides[activeIdx].title
            } else if !isEmoji, client.profile.pages.indices.contains(activeIdx) {
                return client.profile.pages[activeIdx].title
            }
            return "Daily"
        }()

        return HStack(spacing: 8) {
            Button {
                stepPortraitPage(by: -1, count: count, isEmoji: isEmoji, current: activeIdx)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 40, height: 36)
                    .background(palette.tileFillBottom.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-page-prev-button")

            HStack(spacing: 6) {
                Text(icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Text("\(activeIdx + 1)/\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.secondaryText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(palette.barSurface.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )

            Button {
                stepPortraitPage(by: 1, count: count, isEmoji: isEmoji, current: activeIdx)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 40, height: 36)
                    .background(palette.tileFillBottom.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-page-next-button")
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

    private func resumeFollowingFrontmostApp() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            deckFollower.followFrontmostApp(
                frontmostBundleIdentifier: client.frontmostBundleID,
                in: client.profile
            )
        }
    }

    // MARK: - Helpers

    private func triggerCompanionGesture(_ gesture: TouchGestureType) {
        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .rigid)
        client.performGesture(gesture)
        if let mapped = client.profile.gestureConfig.action(for: gesture) {
            flashHUD("\(gesture.title(in: lang)) → \(mapped.title(in: lang))")
        } else {
            flashHUD(gesture.title(in: lang))
        }
    }

    private func flashHUD(_ message: String) {
        gestureHUDText = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if gestureHUDText == message {
                gestureHUDText = nil
            }
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled =
            client.connectionState.isConnected && client.profile.settings.keepCompanionScreenAwake
    }
}
