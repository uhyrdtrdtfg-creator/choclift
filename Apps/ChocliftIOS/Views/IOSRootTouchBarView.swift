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
}

public struct IOSRootTouchBarView: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.scenePhase) private var scenePhase

    @State private var activeMode: IOSActiveSurfaceMode = .chocolateBar
    @State private var modeBeforeAutoEmoji: IOSActiveSurfaceMode?
    @State private var currentPageIndex: Int = 0
    @State private var currentEmojiSlideIndex: Int = 0
    @State private var showPairingSheet: Bool = false
    @State private var editingSlot: IOSEditSlotSelection?
    @State private var gestureHUDText: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

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

                // Global 2-finger & 3-finger Multi-Touch Recognizer
                MultiTouchGestureCaptureView(
                    isEnabled: client.profile.gestureConfig.isGlobalOverlayEnabled
                ) { gesture in
                    triggerCompanionGesture(gesture)
                }
                .ignoresSafeArea()

                // Floating Gesture / Action HUD Toast
                if let hud = gestureHUDText {
                    VStack {
                        Text(hud)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.78), in: Capsule())
                            .overlay(Capsule().strokeBorder(palette.accentGold.opacity(0.6), lineWidth: 1))
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
        .sheet(item: $editingSlot) { selection in
            IOSSlotEditorSheet(
                client: client,
                pageIndex: selection.pageIndex,
                slotIndex: selection.slotIndex
            )
        }
        .onAppear {
            client.startBrowsing()
            updateIdleTimer()
            if !client.connectionState.isConnected && client.savedMacs.isEmpty {
                showPairingSheet = true
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

    // MARK: - iPhone Landscape Touch Bar (Signature Choclift Layout)

    private var iPhoneLandscapeTouchBar: some View {
        HStack(spacing: 0) {
            activeMainContent(isLandscape: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right-hand Vertical Control Rail (Matches Screenshot!)
            VStack(spacing: 12) {
                connectionStatusButton

                verticalDotsIndicator

                Spacer(minLength: 4)

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
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(selected ? .black : palette.secondaryText)
                            .frame(width: 34, height: 34)
                            .background(
                                selected ? palette.accentGold : palette.tileFillBottom.opacity(0.75),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(palette.barSurface.opacity(0.88))
        }
    }

    // MARK: - iPhone Portrait Touch Bar

    private var iPhonePortraitTouchBar: some View {
        VStack(spacing: 0) {
            HStack {
                ChocliftBrandIconView(size: 28)
                Text("choclift")
                    .font(.system(.headline, design: .rounded, weight: .black))
                    .foregroundStyle(palette.primaryText)

                Spacer()

                horizontalDotsIndicator

                Spacer()

                connectionStatusButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)

            activeMainContent(isLandscape: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 16) {
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
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(selected ? .black : palette.secondaryText)
                            .frame(width: 48, height: 38)
                            .background(selected ? palette.accentGold : palette.tileFillBottom, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(palette.barSurface.opacity(0.92), in: Capsule())
            .padding(.bottom, 12)
        }
    }

    // MARK: - iPad Native Resizable Multi-Panel Workspace (v2.3.2+)

    private func iPadExpandedWorkspace(size: CGSize) -> some View {
        VStack(spacing: 12) {
            // Top Header with 8 Page Pills & Connection Pill
            HStack(spacing: 10) {
                ChocliftBrandIconView(size: 32)
                Text("choclift")
                    .font(.system(.title3, design: .rounded, weight: .black))
                    .foregroundStyle(palette.primaryText)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(client.profile.pages) { page in
                            let isSel = (currentPageIndex == page.index)
                            Button {
                                currentPageIndex = page.index
                            } label: {
                                HStack(spacing: 5) {
                                    Text(page.iconEmoji)
                                    Text(page.title)
                                        .font(.caption.bold())
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(isSel ? palette.accentGold : palette.tileFillBottom, in: Capsule())
                                .foregroundStyle(isSel ? .black : palette.primaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()

                connectionStatusPillButton
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            // Main Split: Left = Chocolate Bar + Time Travel Strip | Right = Emoji Bar + Gestures
            HStack(spacing: 14) {
                VStack(spacing: 12) {
                    IOSChocolateBarSurfaceView(
                        client: client,
                        currentPageIndex: $currentPageIndex,
                        isLandscape: true
                    ) { slot in
                        editingSlot = slot
                    }
                    .background(palette.barSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 26))

                    // Persistent Live Time Travel Dock Strip on iPad!
                    iPadTimeTravelDockStrip
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    IOSEmojiBarSurfaceView(
                        client: client,
                        currentSlideIndex: $currentEmojiSlideIndex,
                        isLandscape: true
                    )
                    .background(palette.barSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))

                    IOSGesturePadSurfaceView(
                        client: client,
                        isLandscape: false
                    ) { gesture in
                        triggerCompanionGesture(gesture)
                    }
                    .background(palette.barSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 24))
                }
                .frame(width: min(360, size.width * 0.36))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    private var iPadTimeTravelDockStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L10n.tr("时间旅行 (最近应用)", "App Time Travel", language: lang), systemImage: "clock.arrow.circlepath")
                    .font(.caption.bold())
                    .foregroundStyle(palette.secondaryText)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(client.recentApps) { entry in
                        let icon = client.appIconsByBundleID[entry.bundleIdentifier]
                        Button {
                            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                            client.activateRecentApp(entry)
                        } label: {
                            HStack(spacing: 8) {
                                DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                                    .frame(width: 30, height: 30)
                                Text(entry.appName)
                                    .font(.caption.bold())
                                    .foregroundStyle(palette.primaryText)
                                if entry.isPinned {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(palette.accentGold)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(entry.isFrontmost ? palette.accentGold : .clear, lineWidth: 1.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .background(palette.barSurface.opacity(0.75), in: RoundedRectangle(cornerRadius: 22))
    }

    // MARK: - Subcomponents

    @ViewBuilder
    private func activeMainContent(isLandscape: Bool) -> some View {
        switch activeMode {
        case .chocolateBar:
            IOSChocolateBarSurfaceView(
                client: client,
                currentPageIndex: $currentPageIndex,
                isLandscape: isLandscape
            ) { slot in
                editingSlot = slot
            }
        case .timeTravel:
            IOSTimeTravelSurfaceView(
                client: client,
                isLandscape: isLandscape,
                currentBarPageIndex: currentPageIndex
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

    private var connectionStatusButton: some View {
        Button {
            showPairingSheet = true
        } label: {
            ZStack {
                Circle()
                    .fill(palette.tileFillBottom)
                    .frame(width: 32, height: 32)
                if client.connectionState.isConnected, let link = client.activeLink {
                    Image(systemName: link.sfSymbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.green)
                        .shadow(color: Color.green.opacity(0.6), radius: 3)
                } else if case .connecting = client.connectionState {
                    ProgressView()
                        .scaleEffect(0.65)
                        .tint(palette.accentGold)
                } else if client.bluetoothAvailability.isProblemState || client.lastConnectionIssue != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.orange)
                } else {
                    Circle()
                        .fill(client.connectionState.isConnected ? Color.green : palette.accentRuby)
                        .frame(width: 10, height: 10)
                        .shadow(color: (client.connectionState.isConnected ? Color.green : palette.accentRuby).opacity(0.9), radius: 4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var connectionStatusPillButton: some View {
        Button {
            showPairingSheet = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(
                        client.connectionState.isConnected
                            ? Color.green
                            : (client.bluetoothAvailability.isProblemState || client.lastConnectionIssue != nil ? Color.orange : palette.accentRuby)
                    )
                    .frame(width: 8, height: 8)
                if client.connectionState.isConnected, let link = client.activeLink {
                    Image(systemName: link.sfSymbol)
                        .font(.caption2.bold())
                        .foregroundStyle(Color.green)
                }
                Text(
                    {
                        switch client.connectionState {
                        case .connected(_, let macName):
                            if let link = client.activeLink {
                                return "\(macName) · \(link.shortLabel(in: lang))"
                            }
                            return macName
                        case .connecting(let target):
                            return L10n.tr("正在连接 \(target)…", "Connecting \(target)…", language: lang)
                        case .awaitingPIN(_, let macName, _):
                            return L10n.tr("输入 \(macName) 配对码", "Enter PIN for \(macName)", language: lang)
                        case .disconnected:
                            if client.bluetoothAvailability.isProblemState {
                                return "\(L10n.tr("未连接", "Offline", language: lang)) · \(client.bluetoothAvailability.shortStatus(in: lang))"
                            } else if client.lastConnectionIssue != nil {
                                return L10n.tr("连接已断开 · 点击查看", "Disconnected · View Status", language: lang)
                            }
                            return L10n.tr("点击配对 Mac", "Pair Mac", language: lang)
                        }
                    }()
                )
                .font(.caption.bold())
                .foregroundStyle(palette.primaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(palette.tileFillTop, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var verticalDotsIndicator: some View {
        let count = 8
        let activeIdx = (activeMode == .emojiBar) ? currentEmojiSlideIndex : currentPageIndex

        return VStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { idx in
                Circle()
                    .fill(idx == activeIdx ? palette.accentGold : palette.secondaryText.opacity(0.32))
                    .frame(width: idx == activeIdx ? 6.5 : 4.5, height: idx == activeIdx ? 6.5 : 4.5)
                    .onTapGesture {
                        if activeMode == .emojiBar {
                            currentEmojiSlideIndex = idx
                        } else {
                            currentPageIndex = idx
                        }
                    }
            }
        }
    }

    private var horizontalDotsIndicator: some View {
        let count = 8
        let activeIdx = (activeMode == .emojiBar) ? currentEmojiSlideIndex : currentPageIndex

        return HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { idx in
                Circle()
                    .fill(idx == activeIdx ? palette.accentGold : palette.secondaryText.opacity(0.32))
                    .frame(width: idx == activeIdx ? 6.5 : 4.5, height: idx == activeIdx ? 6.5 : 4.5)
                    .onTapGesture {
                        if activeMode == .emojiBar {
                            currentEmojiSlideIndex = idx
                        } else {
                            currentPageIndex = idx
                        }
                    }
            }
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
