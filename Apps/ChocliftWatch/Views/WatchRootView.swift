import ChocliftCore
import SwiftUI

public enum WatchSurfaceMode: Int, CaseIterable, Identifiable {
    case chocolateBar = 0
    case quickActions = 1
    case timeTravel = 2
    case emojiBar = 3

    public var id: Int { rawValue }

    public var sfSymbol: String {
        switch self {
        case .chocolateBar: return "square.grid.2x2.fill"
        case .quickActions: return "bolt.fill"
        case .timeTravel: return "clock.arrow.circlepath"
        case .emojiBar: return "face.smiling.fill"
        }
    }

    public func shortLabel(in lang: AppLanguage) -> String {
        switch self {
        case .chocolateBar: return L10n.tr("巧克力栏", "Chocolate Bar", language: lang)
        case .quickActions: return L10n.tr("快捷遥控", "Quick Actions", language: lang)
        case .timeTravel: return L10n.tr("最近应用", "Recent Apps", language: lang)
        case .emojiBar: return L10n.tr("表情直输", "Emoji Bar", language: lang)
        }
    }
}

public struct WatchRootView: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.scenePhase) private var scenePhase

    @State private var activeMode: WatchSurfaceMode = .chocolateBar
    @State private var modeBeforeAutoEmoji: WatchSurfaceMode?
    @State private var deckFollower = AppDeckFollowerState()
    @State private var currentEmojiSlideIndex: Int = 0
    @State private var showPairingSheet: Bool = false
    @State private var showModePickerSheet: Bool = false
    @State private var hudMessage: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var visualState: ChocConnectionVisualState { ChocConnectionVisualState.resolve(from: client) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                TabView(selection: $activeMode) {
                    WatchChocolateBarView(
                        client: client,
                        deckFollower: $deckFollower,
                        onRequestPairing: { showPairingSheet = true }
                    )
                    .tag(WatchSurfaceMode.chocolateBar)

                    WatchQuickActionsView(
                        client: client,
                        onRequestPairing: { showPairingSheet = true }
                    )
                    .tag(WatchSurfaceMode.quickActions)

                    WatchTimeTravelView(
                        client: client,
                        onRequestPairing: { showPairingSheet = true }
                    )
                    .tag(WatchSurfaceMode.timeTravel)

                    WatchEmojiBarView(
                        client: client,
                        currentSlideIndex: $currentEmojiSlideIndex,
                        onRequestPairing: { showPairingSheet = true }
                    )
                    .tag(WatchSurfaceMode.emojiBar)
                }
                .tabViewStyle(.page)

                if let hud = hudMessage {
                    Text(hud)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(palette.barSurface.opacity(0.95), in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                        .padding(.bottom, 3)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: hudMessage)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionToolbarButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    modeToolbarButton
                }
            }
        }
        .sheet(isPresented: $showPairingSheet) {
            WatchPairingView(client: client)
        }
        .sheet(isPresented: $showModePickerSheet) {
            modePickerSheet
        }
        .onAppear {
            deckFollower.handleProfileUpdated(client.profile, frontmostBundleIdentifier: client.frontmostBundleID)
            client.startBrowsing()
            if !client.connectionState.isConnected && client.savedMacs.isEmpty {
                showPairingSheet = true
            }
        }
        .onChange(of: client.frontmostBundleID) { _, newBundleID in
            withAnimation(.easeInOut(duration: 0.22)) {
                deckFollower.handleFrontmostAppChanged(newBundleID, in: client.profile)
            }
        }
        .onChange(of: client.profile) { _, newProfile in
            withAnimation(.easeInOut(duration: 0.22)) {
                deckFollower.handleProfileUpdated(newProfile, frontmostBundleIdentifier: client.frontmostBundleID)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                client.handleAppDidBecomeActive()
            }
        }
        .onChange(of: client.connectionState) { _, newState in
            if case .awaitingPIN = newState, !showPairingSheet {
                showPairingSheet = true
            } else if newState.isConnected && showPairingSheet {
                showPairingSheet = false
            }
        }
        .onChange(of: client.isEditingTextOnMac) { _, editing in
            guard client.profile.settings.autoShowEmojiBarWhenTyping else { return }
            if editing {
                if activeMode != .emojiBar {
                    modeBeforeAutoEmoji = activeMode
                    withAnimation(.easeInOut(duration: 0.22)) {
                        activeMode = .emojiBar
                    }
                }
            } else if client.profile.settings.autoReturnFromEmojiBarOnBlur,
                      let previous = modeBeforeAutoEmoji {
                modeBeforeAutoEmoji = nil
                withAnimation(.easeInOut(duration: 0.22)) {
                    activeMode = previous
                }
            }
        }
        .onChange(of: client.lastFeedback) { _, toast in
            guard let toast else { return }
            CompanionFeedbackHaptics.notify(
                enabled: client.profile.settings.hapticFeedbackEnabled,
                kind: toast.success ? .success : .error
            )
            flashHUD(toast.title)
        }
    }

    // MARK: - Readable, Tap-Friendly Toolbar Controls

    private var connectionToolbarButton: some View {
        let tint = visualState.tintColor(in: palette)

        return Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            showPairingSheet = true
        } label: {
            HStack(spacing: 4) {
                if visualState.showsProgressSpinner {
                    ProgressView()
                        .scaleEffect(0.62)
                        .frame(width: 12, height: 12)
                        .tint(tint)
                } else {
                    Image(systemName: visualState.sfSymbol)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(tint)
                }

                Text(visualState.watchToolbarLabel(in: lang))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 34)
            .background(palette.tileFillTop.opacity(0.92), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        visualState.isFailure ? palette.statusFailure.opacity(0.75) : tint.opacity(0.35),
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var modeToolbarButton: some View {
        Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            showModePickerSheet = true
        } label: {
            Image(systemName: activeMode.sfSymbol)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(palette.accent)
                .frame(width: 34, height: 34)
                .background(palette.tileFillBottom.opacity(0.95), in: Circle())
                .overlay(Circle().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var modePickerSheet: some View {
        List {
            ForEach(WatchSurfaceMode.allCases) { mode in
                let isSelected = (activeMode == mode)
                Button {
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                    modeBeforeAutoEmoji = nil
                    activeMode = mode
                    showModePickerSheet = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: mode.sfSymbol)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isSelected ? palette.accentForeground : palette.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(isSelected ? palette.accent : palette.tileFillTop, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Text(mode.shortLabel(in: lang))
                            .font(.system(size: 14, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)

                        Spacer()

                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .frame(minHeight: 38)
                }
                .listRowBackground(palette.barSurface)
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
    }

    private func flashHUD(_ text: String) {
        hudMessage = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if hudMessage == text {
                hudMessage = nil
            }
        }
    }
}
