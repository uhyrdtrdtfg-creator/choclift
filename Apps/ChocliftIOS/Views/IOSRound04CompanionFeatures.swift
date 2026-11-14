import ChocliftCore
import SwiftUI
import UIKit

// MARK: - 1. Keep Mac Awake Toggle Pill (Round 4 — Prevents Idle System Sleep While Connected)

public struct IOSKeepMacAwakeTogglePill: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var isAwakeActive: Bool {
        client.connectionState.isConnected && client.controlStripState.isKeepMacAwakeEnabled
    }

    public init(client: CompanionClientEngine, compact: Bool = false) {
        self.client = client
        self.compact = compact
    }

    public var body: some View {
        let key = "keep-mac-awake"
        let isPressed = (pressedKey == key)

        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            client.toggleKeepMacAwake()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isAwakeActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isAwakeActive ? palette.accentForeground : palette.accentEmphasis)

                if isAwakeActive {
                    Circle()
                        .fill(palette.accentForeground)
                        .frame(width: 5, height: 5)
                }

                Text(
                    isAwakeActive
                        ? L10n.tr("常亮中", "Awake", language: lang)
                        : L10n.tr("防休眠", "Awake", language: lang)
                )
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(isAwakeActive ? palette.accentForeground : palette.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, compact ? 9 : 10)
            .frame(minHeight: 44)
            .background(
                isAwakeActive
                    ? palette.statusConnected.opacity(isPressed ? 0.85 : 1.0)
                    : (isPressed ? palette.tileFillBottom : palette.tileFillTop.opacity(0.94)),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isAwakeActive
                            ? palette.statusConnected
                            : (isPressed ? palette.accent : palette.subtleCardStroke),
                        lineWidth: isPressed ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
        .accessibilityIdentifier("ios-keep-mac-awake-toggle")
        .accessibilityLabel(L10n.tr("保持 Mac 唤醒（防空闲休眠）", "Keep Mac Awake", language: lang))
        .accessibilityValue(
            isAwakeActive
                ? L10n.tr("已开启", "On", language: lang)
                : L10n.tr("已关闭", "Off", language: lang)
        )
    }
}

// MARK: - 2. Mac Audio Output Picker Button & Sheet (Round 4 — Public CoreAudio Output Switcher)

public struct IOSAudioOutputPickerButton: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool

    @State private var showPickerSheet: Bool = false
    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var state: ControlStripState { client.controlStripState }

    public init(client: CompanionClientEngine, compact: Bool = true) {
        self.client = client
        self.compact = compact
    }

    public var body: some View {
        let key = "audio-output-picker"
        let isPressed = (pressedKey == key)
        let currentDevice = state.currentAudioOutputDevice
        let iconName = currentDevice?.transportKind.sfSymbol ?? "hifispeaker.2.fill"

        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            if client.connectionState.isConnected {
                client.requestControlStripState()
            }
            showPickerSheet = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(currentDevice != nil ? palette.accent : palette.secondaryText)

                if !compact, let currentDevice {
                    Text(currentDevice.name)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .frame(maxWidth: 108)
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .background(
                isPressed ? palette.accent.opacity(0.16) : palette.tileFillBottom,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isPressed ? palette.accent : palette.subtleCardStroke,
                        lineWidth: isPressed ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
        .accessibilityIdentifier("ios-audio-output-picker-button")
        .accessibilityLabel(L10n.tr("Mac 音频输出设备", "Mac Audio Output Device", language: lang))
        .accessibilityValue(state.currentAudioOutputLabel(in: lang))
        .sheet(isPresented: $showPickerSheet) {
            IOSAudioOutputPickerSheet(client: client)
        }
    }
}

public struct IOSAudioOutputPickerSheet: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.dismiss) private var dismiss

    @State private var awaitingSwitchFeedback: Bool = false
    @State private var sheetFeedback: CompanionFeedbackToast?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var state: ControlStripState { client.controlStripState }
    private var isConnected: Bool { client.connectionState.isConnected }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        currentOutputSummaryCard

                        if let feedback = sheetFeedback {
                            switchFeedbackBanner(feedback)
                        }

                        if isConnected && !state.canSwitchAudioOutput {
                            readOnlyBanner
                        }

                        if !isConnected {
                            offlineStateCard
                        } else if state.audioOutputDevices.isEmpty {
                            emptyDevicesCard
                        } else {
                            devicesListCard
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(L10n.tr("Mac 音频输出", "Mac Audio Output", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("完成", "Done", language: lang)) {
                        dismiss()
                    }
                    .accessibilityIdentifier("ios-audio-output-sheet-done")
                }
                if isConnected {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                            client.requestControlStripState()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("ios-audio-output-refresh")
                        .accessibilityLabel(L10n.tr("刷新输出设备", "Refresh Output Devices", language: lang))
                    }
                }
            }
            .onReceive(client.$lastFeedback) { newFeedback in
                guard awaitingSwitchFeedback, let newFeedback else { return }
                awaitingSwitchFeedback = false
                sheetFeedback = newFeedback
                CompanionHaptics.notify(
                    enabled: client.profile.settings.hapticFeedbackEnabled,
                    type: newFeedback.success ? .success : .error
                )
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func switchFeedbackBanner(_ feedback: CompanionFeedbackToast) -> some View {
        let tint = feedback.success ? palette.statusConnected : palette.statusFailure
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: feedback.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                if let detail = feedback.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(feedback.success ? palette.secondaryText : palette.statusFailure)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.55), lineWidth: 1)
        )
        .accessibilityIdentifier("ios-audio-output-feedback-banner")
    }

    private var currentOutputSummaryCard: some View {
        let current = isConnected ? state.currentAudioOutputDevice : nil
        return HStack(spacing: 12) {
            Image(systemName: current?.transportKind.sfSymbol ?? "hifispeaker.2.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(isConnected ? palette.accent : palette.secondaryText)
                .frame(width: 42, height: 42)
                .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("当前默认输出", "Current Default Output", language: lang))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)

                Text(
                    isConnected
                        ? (current?.name ?? L10n.tr("系统默认输出", "System Default Output", language: lang))
                        : L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
            }

            Spacer(minLength: 0)

            if isConnected && !state.canSwitchAudioOutput {
                Text(L10n.tr("只读", "Read-Only", language: lang))
                    .font(.caption2.bold())
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(palette.tileFillBottom, in: Capsule())
            }
        }
        .padding(14)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("ios-audio-output-current-card")
    }

    private var readOnlyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.subheadline.bold())
                .foregroundStyle(palette.accentEmphasis)

            Text(
                L10n.tr(
                    "当前音频输出为只读：macOS 报告默认音频输出属性不支持写入，因此仅展示当前设备，不会伪造切换结果。",
                    "Read-only: macOS reported that the default output property is not settable via public CoreAudio API, so the current device is shown without faking a switch.",
                    language: lang
                )
            )
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("ios-audio-output-readonly-banner")
    }

    private var offlineStateCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "laptopcomputer.slash")
                .font(.system(size: 26))
                .foregroundStyle(palette.secondaryText)
            Text(L10n.tr("连接 Mac 后即可查看并切换扬声器、耳机或显示器音频输出", "Connect to your Mac to view and switch speakers, headphones, or display audio outputs.", language: lang))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("ios-audio-output-offline-state")
    }

    private var emptyDevicesCard: some View {
        Text(L10n.tr("Mac 当前未报告可用的音频输出设备。", "No audio output devices reported by your Mac.", language: lang))
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
    }

    private var devicesListCard: some View {
        let selectedID = state.currentAudioOutputDevice?.id
        return VStack(spacing: 8) {
            ForEach(state.audioOutputDevices) { device in
                let isSelected = (device.id == selectedID)
                let isRowEnabled = state.canSwitchAudioOutput && device.isSelectable
                Button {
                    guard isRowEnabled else { return }
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                    sheetFeedback = nil
                    awaitingSwitchFeedback = true
                    client.selectAudioOutputDevice(id: device.id)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: device.sfSymbol)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(isSelected ? palette.statusConnected : (isRowEnabled ? palette.accent : palette.secondaryText))
                            .frame(width: 34, height: 34)
                            .background(
                                (isSelected ? palette.statusConnected.opacity(0.14) : palette.tileFillBottom),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(isRowEnabled || isSelected ? palette.primaryText : palette.secondaryText)
                                .lineLimit(1)

                            if let unavailableDetail = device.selectionUnavailableReason(in: lang) {
                                Text("\(device.transportSubtitle(in: lang)) · \(unavailableDetail)")
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            } else {
                                Text(device.transportSubtitle(in: lang))
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                            }
                        }

                        Spacer(minLength: 8)

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(palette.statusConnected)
                        } else if !isRowEnabled {
                            Image(systemName: device.isAirPlay ? "airplayaudio" : "lock")
                                .font(.caption.bold())
                                .foregroundStyle(palette.secondaryText.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 48)
                    .opacity(isRowEnabled || isSelected ? 1.0 : 0.72)
                    .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isSelected ? palette.statusConnected : palette.subtleCardStroke,
                                lineWidth: isSelected ? 1.6 : 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!isRowEnabled)
                .accessibilityIdentifier("ios-audio-output-device-\(device.id)")
            }
        }
    }
}

// MARK: - 3. Frontmost App Window List Ribbon Button, Sheet & Inline Card (Capped at 12, No Streaming)

public struct IOSFrontmostWindowsRibbonButton: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool

    @State private var showWindowsSheet: Bool = false
    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine, compact: Bool = false) {
        self.client = client
        self.compact = compact
    }

    public var body: some View {
        let key = "frontmost-windows"
        let isPressed = (pressedKey == key)
        let isConnected = client.connectionState.isConnected
        let snapshot = client.frontmostWindows
        let count = min(snapshot.windows.count, FrontmostAppWindowSnapshot.maxWindows)

        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            if isConnected {
                client.requestFrontmostAppWindows()
            }
            showWindowsSheet = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.accent)

                Text(compact ? L10n.tr("窗口", "Wins", language: lang) : L10n.tr("窗口", "Windows", language: lang))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if isConnected && count > 0 {
                    Text(snapshot.isCapped ? "\(FrontmostAppWindowSnapshot.maxWindows)+" : "\(count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(palette.accent.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, compact ? 9 : 10)
            .frame(minHeight: 44)
            .background(
                isPressed ? palette.tileFillBottom : palette.tileFillTop.opacity(0.94),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isPressed ? palette.accent : palette.subtleCardStroke,
                        lineWidth: isPressed ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
        .accessibilityIdentifier("ios-frontmost-windows-button")
        .accessibilityLabel(L10n.tr("当前应用窗口列表", "Frontmost App Windows", language: lang))
        .sheet(isPresented: $showWindowsSheet) {
            IOSFrontmostAppWindowsSheet(client: client)
        }
    }
}

public struct IOSFrontmostAppWindowsSheet: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.dismiss) private var dismiss

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var isConnected: Bool { client.connectionState.isConnected }
    private var snapshot: FrontmostAppWindowSnapshot { client.frontmostWindows }

    private var displayedWindows: [MacFrontmostWindowItem] {
        FrontmostAppWindowSnapshot.capWindows(snapshot.windows)
    }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        headerCard

                        if !isConnected {
                            offlineState
                        } else if !snapshot.isAccessibilityTrusted {
                            accessibilityPermissionCard
                        } else if displayedWindows.isEmpty {
                            emptyWindowsCard
                        } else {
                            VStack(spacing: 8) {
                                ForEach(displayedWindows) { win in
                                    windowRowButton(win)
                                }
                            }

                            if snapshot.isCapped {
                                Text(
                                    L10n.tr(
                                        "仅展示前 \(FrontmostAppWindowSnapshot.maxWindows) 个窗口（共 \(snapshot.totalWindowCount) 个），不传输窗口画面。",
                                        "Showing up to \(FrontmostAppWindowSnapshot.maxWindows) of \(snapshot.totalWindowCount) windows (titles only, no screen streaming).",
                                        language: lang
                                    )
                                )
                                .font(.caption2)
                                .foregroundStyle(palette.secondaryText)
                                .padding(.horizontal, 4)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(L10n.tr("当前应用窗口", "Frontmost Windows", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("完成", "Done", language: lang)) {
                        dismiss()
                    }
                    .accessibilityIdentifier("ios-frontmost-windows-sheet-done")
                }
                if isConnected {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                            client.requestFrontmostAppWindows()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("ios-frontmost-windows-refresh")
                        .accessibilityLabel(L10n.tr("刷新窗口列表", "Refresh Windows", language: lang))
                    }
                }
            }
            .onAppear {
                if isConnected {
                    client.requestFrontmostAppWindows()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var headerCard: some View {
        let appName = snapshot.appName ?? client.frontmostAppName ?? L10n.tr("当前前台应用", "Frontmost App", language: lang)
        let bundleID = snapshot.bundleIdentifier ?? client.frontmostBundleID
        let iconData = bundleID.flatMap { client.appIconsByBundleID[$0] ?? BundledAppIcons.pngData(for: $0) }

        return HStack(spacing: 12) {
            DataImageView(pngData: iconData, fallbackSymbol: "macwindow", tint: palette.accent)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(isConnected ? appName : L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                Text(
                    isConnected
                        ? L10n.tr("点按任意窗口将其在 Mac 上置顶（最多显示 12 个）", "Tap a window to raise it on your Mac (capped at 12)", language: lang)
                        : L10n.tr("连接 Mac 后即可查看当前前台应用的窗口列表", "Connect to your Mac to list windows of the frontmost app", language: lang)
                )
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("ios-frontmost-windows-header")
    }

    private var offlineState: some View {
        VStack(spacing: 8) {
            Image(systemName: "macwindow.badge.plus")
                .font(.system(size: 26))
                .foregroundStyle(palette.secondaryText)
            Text(L10n.tr("配对并连接 Mac 后，这里会显示前台应用的窗口标题（上限 12 个），点按即可置顶。", "Pair and connect your Mac to see up to 12 window titles for the active app and tap to raise.", language: lang))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("ios-frontmost-windows-offline")
    }

    private var accessibilityPermissionCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(palette.accentEmphasis)
            Text(
                L10n.tr(
                    "需要在 Mac「系统设置 → 隐私与安全性 → 辅助功能」中允许 Choclift，才能读取并置顶应用窗口。",
                    "Enable Choclift under Mac System Settings → Privacy & Security → Accessibility to list and raise windows.",
                    language: lang
                )
            )
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var emptyWindowsCard: some View {
        Text(L10n.tr("当前前台应用没有打开的窗口。", "The frontmost app currently has no open windows.", language: lang))
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
    }

    private func windowRowButton(_ win: MacFrontmostWindowItem) -> some View {
        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            client.raiseFrontmostWindow(id: win.id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: win.isMinimized ? "minus.rectangle" : (win.isMainOrFocused ? "macwindow.badge.plus" : "macwindow"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(win.isMainOrFocused ? palette.accent : palette.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(win.title)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if win.isMainOrFocused {
                            Text(L10n.tr("当前焦点", "Focused", language: lang))
                                .font(.caption2.bold())
                                .foregroundStyle(palette.accent)
                        }
                        if win.isMinimized {
                            Text(L10n.tr("已最小化 · 点按恢复置顶", "Minimized · Tap to Raise", language: lang))
                                .font(.caption2)
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 46)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        win.isMainOrFocused ? palette.accent.opacity(0.65) : palette.subtleCardStroke,
                        lineWidth: win.isMainOrFocused ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-frontmost-window-row-\(win.index)")
    }
}

public struct IOSFrontmostWindowsInlineCard: View {
    @ObservedObject var client: CompanionClientEngine

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var snapshot: FrontmostAppWindowSnapshot { client.frontmostWindows }
    private var displayedWindows: [MacFrontmostWindowItem] {
        FrontmostAppWindowSnapshot.capWindows(snapshot.windows)
    }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        if client.connectionState.isConnected {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        L10n.tr(
                            "\(snapshot.appName ?? client.frontmostAppName ?? "前台应用") 窗口",
                            "\(snapshot.appName ?? client.frontmostAppName ?? "Frontmost") Windows",
                            language: lang
                        ),
                        systemImage: "macwindow.on.rectangle"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                    Spacer()

                    Button {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                        client.requestFrontmostAppWindows()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(palette.accent)
                            .frame(width: 28, height: 28)
                            .background(palette.tileFillBottom, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("刷新窗口", "Refresh Windows", language: lang))
                }

                if displayedWindows.isEmpty {
                    Text(
                        snapshot.isAccessibilityTrusted
                            ? L10n.tr("当前前台应用暂无可列出的窗口", "No open windows in the frontmost app", language: lang)
                            : L10n.tr("授权辅助功能后可列出并置顶窗口", "Grant Accessibility on Mac to list and raise windows", language: lang)
                    )
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                } else {
                    VStack(spacing: 6) {
                        ForEach(displayedWindows) { win in
                            Button {
                                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                                client.raiseFrontmostWindow(id: win.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: win.isMinimized ? "minus.rectangle" : "macwindow")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(win.isMainOrFocused ? palette.accent : palette.secondaryText)

                                    Text(win.title)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(1)

                                    Spacer(minLength: 4)

                                    Text(L10n.tr("置顶", "Raise", language: lang))
                                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                        .foregroundStyle(palette.accent)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(palette.accent.opacity(0.12), in: Capsule())
                                }
                                .padding(.horizontal, 10)
                                .frame(minHeight: 44)
                                .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            win.isMainOrFocused ? palette.accent.opacity(0.6) : palette.subtleCardStroke,
                                            lineWidth: 1
                                        )
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .background(palette.barSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
            .accessibilityIdentifier("ios-frontmost-windows-inline-card")
        }
    }
}
