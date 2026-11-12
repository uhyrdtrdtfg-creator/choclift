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
        case .chocolateBar: return L10n.tr("巧栏", "Bar", language: lang)
        case .quickActions: return L10n.tr("快捷", "Actions", language: lang)
        case .timeTravel: return L10n.tr("最近", "Recents", language: lang)
        case .emojiBar: return L10n.tr("表情", "Emoji", language: lang)
        }
    }
}

public struct WatchRootView: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.scenePhase) private var scenePhase

    @State private var activeMode: WatchSurfaceMode = .chocolateBar
    @State private var modeBeforeAutoEmoji: WatchSurfaceMode?
    @State private var currentPageIndex: Int = 0
    @State private var currentEmojiSlideIndex: Int = 0
    @State private var showPairingSheet: Bool = false
    @State private var showModePickerSheet: Bool = false
    @State private var hudMessage: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

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
                        currentPageIndex: $currentPageIndex,
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
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.84), in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.accentGold.opacity(0.65), lineWidth: 1))
                        .padding(.bottom, 2)
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
            client.startBrowsing()
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

    // MARK: - Toolbar Controls

    private var connectionToolbarButton: some View {
        Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            showPairingSheet = true
        } label: {
            HStack(spacing: 4) {
                if client.connectionState.isConnected, let link = client.activeLink {
                    Image(systemName: link.sfSymbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.green)
                } else {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 7, height: 7)
                }
                Text(statusShortText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(palette.tileFillTop.opacity(0.9), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var modeToolbarButton: some View {
        Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
            showModePickerSheet = true
        } label: {
            Image(systemName: activeMode.sfSymbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(palette.accentGold)
                .frame(width: 26, height: 26)
                .background(palette.tileFillBottom.opacity(0.9), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var modePickerSheet: some View {
        List {
            ForEach(WatchSurfaceMode.allCases) { mode in
                Button {
                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .light)
                    modeBeforeAutoEmoji = nil
                    activeMode = mode
                    showModePickerSheet = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: mode.sfSymbol)
                            .foregroundStyle(activeMode == mode ? palette.accentGold : palette.secondaryText)
                        Text(mode.shortLabel(in: lang))
                            .font(.system(.body, design: .rounded, weight: activeMode == mode ? .bold : .medium))
                        Spacer()
                        if activeMode == mode {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(palette.accentGold)
                        }
                    }
                }
            }
        }
    }

    private var statusIndicatorColor: Color {
        switch client.connectionState {
        case .connected:
            return .green
        case .connecting:
            return palette.accentGold
        case .awaitingPIN:
            return .orange
        case .disconnected:
            if client.bluetoothAvailability.isProblemState || client.lastConnectionIssue != nil {
                return .orange
            }
            return palette.accentRuby
        }
    }

    private var statusShortText: String {
        switch client.connectionState {
        case .connected(_, let macName):
            let link = (client.activeLink ?? .wifi).shortLabel(in: lang)
            return "\(macName) · \(link)"
        case .connecting:
            return L10n.tr("连接中…", "Linking…", language: lang)
        case .awaitingPIN:
            return L10n.tr("输配对码", "Enter PIN", language: lang)
        case .disconnected:
            if client.bluetoothAvailability.isProblemState {
                return client.bluetoothAvailability.shortStatus(in: lang)
            } else if client.lastConnectionIssue != nil {
                return L10n.tr("已断开", "Offline", language: lang)
            }
            return L10n.tr("配对 Mac", "Pair Mac", language: lang)
        }
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
