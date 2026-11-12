import AppKit
import ChocliftCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pairing PIN Popover

public struct MacPairingPopoverView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @ObservedObject var server: MacServerEngine

    private var lang: AppLanguage { coordinator.lang }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
        self.server = coordinator.server
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ChocliftBrandIconView(size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("配对 iPhone、iPad 或 Watch", "Pair iPhone, iPad, or Watch", language: lang))
                        .font(.headline)
                    Text(server.macName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(server.isListening ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
            }

            VStack(spacing: 6) {
                Text(L10n.tr("一次性安全配对码 (6位)", "One-Time 6-Digit Pairing PIN", language: lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Text(formattedPIN(server.currentPIN))
                        .font(.system(size: 30, weight: .black, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(.primary)

                    Button {
                        server.regeneratePIN()
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("刷新配对码", "Generate New PIN", language: lang))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "wifi")
                            .font(.caption2.bold())
                        Text(
                            server.isListening
                                ? L10n.tr("Wi-Fi 就绪", "Wi-Fi Ready", language: lang)
                                : L10n.tr("Wi-Fi 未启动", "Wi-Fi Off", language: lang)
                        )
                        .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(server.isListening ? Color.green : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((server.isListening ? Color.green : Color.secondary).opacity(0.12), in: Capsule())

                    HStack(spacing: 5) {
                        Image(systemName: server.bluetoothAvailability.isProblemState ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
                            .font(.caption2.bold())
                        Text(
                            server.isBluetoothAdvertising
                                ? L10n.tr("蓝牙广播中", "Bluetooth Ready", language: lang)
                                : server.bluetoothAvailability.shortStatus(in: lang)
                        )
                        .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(
                        server.isBluetoothAdvertising
                            ? Color.cyan
                            : (server.bluetoothAvailability.isProblemState ? Color.orange : Color.secondary)
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (server.isBluetoothAdvertising
                            ? Color.cyan
                            : (server.bluetoothAvailability.isProblemState ? Color.orange : Color.secondary)
                        ).opacity(0.12),
                        in: Capsule()
                    )
                }

                if let btGuidance = server.bluetoothAvailability.detailGuidance(in: lang) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.top, 1)
                        Text(btGuidance)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                Text(
                    L10n.tr(
                        "同一 Wi-Fi 优先局域网直连；离开同一网络时自动切换蓝牙 LE，共用同一 6 位配对码与信任令牌。",
                        "Prefers Wi-Fi on the same network; falls back to Bluetooth LE off Wi-Fi using the same 6-digit PIN and saved token.",
                        language: lang
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let port = server.listeningPort {
                    let ipText = server.localIPAddresses.isEmpty
                        ? "127.0.0.1:\(port)"
                        : server.localIPAddresses.map { "\($0):\(port)" }.joined(separator: "  /  ")
                    Label(
                        L10n.tr("直连地址：\(ipText)", "Direct Address: \(ipText)", language: lang),
                        systemImage: "network"
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
            }

            if !server.pairedDevices.isEmpty {
                Divider()
                Text(L10n.tr("已配对设备（下次打开自动重连，支持多设备同时在线）", "Paired Devices (Auto-reconnect & Multi-Device enabled)", language: lang))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(server.pairedDevices) { device in
                    HStack(spacing: 6) {
                        Image(systemName: device.platform.sfSymbol)
                            .foregroundStyle(device.isCurrentlyConnected ? .green : .secondary)
                        Text(device.deviceName)
                            .font(.callout.weight(.medium))
                        Spacer()
                        if device.isCurrentlyConnected, let link = device.activeLink {
                            HStack(spacing: 3) {
                                Image(systemName: link.sfSymbol)
                                    .font(.system(size: 9, weight: .bold))
                                Text("\(L10n.tr("在线", "Online", language: lang)) · \(link.shortLabel(in: lang))")
                                    .font(.caption2.bold())
                            }
                            .foregroundStyle(.green)
                        } else {
                            Text(device.isCurrentlyConnected
                                 ? L10n.tr("在线", "Online", language: lang)
                                 : L10n.tr("离线", "Saved", language: lang))
                                .font(.caption2.bold())
                                .foregroundStyle(device.isCurrentlyConnected ? .green : .secondary)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private func formattedPIN(_ raw: String) -> String {
        guard raw.count == 6 else { return raw }
        let idx = raw.index(raw.startIndex, offsetBy: 3)
        return "\(raw[..<idx]) \(raw[idx...])"
    }
}

// MARK: - Devices & Preferences Section

public struct DevicesAndSettingsView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @ObservedObject var server: MacServerEngine

    private var lang: AppLanguage { coordinator.lang }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
        self.server = coordinator.server
    }

    public var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 22) {
                // Left Column: Devices + Permissions + Preferences
                VStack(alignment: .leading, spacing: 18) {
                    accessibilityPermissionCard

                    pairedDevicesCard

                    appearanceAndPreferencesCard
                }
                .frame(maxWidth: .infinity)

                // Right Column: Live Activity Stream & Backup
                VStack(alignment: .leading, spacing: 18) {
                    backupAndResetCard

                    liveActivityCard
                }
                .frame(width: 340)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 18)
        }
    }

    private var accessibilityPermissionCard: some View {
        HStack(spacing: 14) {
            Image(systemName: coordinator.isAccessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.largeTitle)
                .foregroundStyle(coordinator.isAccessibilityGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("辅助功能权限 (Accessibility)", "macOS Accessibility Permission", language: lang))
                    .font(.headline)
                Text(
                    coordinator.isAccessibilityGranted
                        ? L10n.tr("已授权！手势缩放窗口、复制粘贴快捷键、以及光标处直接输入 Emoji 均已就绪。", "Granted! Window gestures, clipboard shortcuts, and cursor Emoji typing are active.", language: lang)
                        : L10n.tr("用于支持双指最小化/最大化窗口、复制粘贴手势与表情直输。请点击右侧前往「系统设置 → 隐私与安全性 → 辅助功能」开启。", "Required for window management gestures, copy/paste macros, and cursor emoji typing.", language: lang)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !coordinator.isAccessibilityGranted {
                Button(L10n.tr("立即授权…", "Grant Access…", language: lang)) {
                    coordinator.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var pairedDevicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.tr("多设备连接管理 (Multi-Device)", "Multi-Device Companion Manager", language: lang), systemImage: "iphone.and.arrow.forward")
                    .font(.headline)
                Spacer()
                if server.bluetoothAvailability.isProblemState {
                    Label(server.bluetoothAvailability.shortStatus(in: lang), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }
                Text(L10n.tr("配对码：\(server.currentPIN)", "PIN: \(server.currentPIN)", language: lang))
                    .font(.system(.callout, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }

            if let btGuidance = server.bluetoothAvailability.detailGuidance(in: lang) {
                Label(btGuidance, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if server.pairedDevices.isEmpty {
                Text(L10n.tr("暂未配对任何设备。打开 iPhone、iPad 或 Apple Watch 上的 Choclift 并输入上方 6 位配对码即可秒连。", "No paired companions yet. Open Choclift on iPhone, iPad, or Apple Watch and enter the 6-digit PIN above.", language: lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(server.pairedDevices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: device.platform.sfSymbol)
                            .font(.title3)
                            .foregroundStyle(device.isCurrentlyConnected ? .green : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(device.deviceName)
                                    .font(.body.weight(.semibold))
                                if device.isCurrentlyConnected, let link = device.activeLink {
                                    Label(link.shortLabel(in: lang), systemImage: link.sfSymbol)
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(
                                device.isCurrentlyConnected
                                    ? "\(device.platform.rawValue) · \(L10n.tr("实时连接中", "Connected Live", language: lang))\(device.activeLink.map { " (\($0.displayName(in: lang)))" } ?? "")"
                                    : "\(device.platform.rawValue) · \(L10n.tr("已记住信任令牌（支持 Wi-Fi / 蓝牙自动重连）", "Saved token (Wi-Fi & Bluetooth auto-reconnect ready)", language: lang))"
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            server.removePairedDevice(deviceID: device.deviceID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var appearanceAndPreferencesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.tr("外观主题与偏好", "Theme & Companion Preferences", language: lang), systemImage: "paintpalette.fill")
                .font(.headline)

            LabeledContent(L10n.tr("巧克力主题", "Chocolate Theme", language: lang)) {
                Picker(
                    "",
                    selection: Binding(
                        get: { coordinator.profile.settings.theme },
                        set: { newTheme in
                            coordinator.mutateProfile { $0.settings.theme = newTheme }
                        }
                    )
                ) {
                    ForEach(ChocTheme.allCases) { th in
                        Text(th.title(in: lang)).tag(th)
                    }
                }
                .frame(width: 200)
            }

            LabeledContent(L10n.tr("界面语言", "Language", language: lang)) {
                Picker(
                    "",
                    selection: Binding(
                        get: { coordinator.profile.settings.language },
                        set: { newLang in
                            coordinator.mutateProfile { $0.settings.language = newLang }
                        }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { l in
                        Text(l.displayName).tag(l)
                    }
                }
                .frame(width: 200)
            }

            Toggle(
                L10n.tr("iOS 端触感反馈 (Haptic Tap)", "Companion Haptic Feedback on Tap & Gesture", language: lang),
                isOn: Binding(
                    get: { coordinator.profile.settings.hapticFeedbackEnabled },
                    set: { v in coordinator.mutateProfile { $0.settings.hapticFeedbackEnabled = v } }
                )
            )

            Toggle(
                L10n.tr("连接时保持 iPhone / iPad 屏幕常亮", "Keep iPhone / iPad Screen Awake While Connected", language: lang),
                isOn: Binding(
                    get: { coordinator.profile.settings.keepCompanionScreenAwake },
                    set: { v in coordinator.mutateProfile { $0.settings.keepCompanionScreenAwake = v } }
                )
            )

            Toggle(
                L10n.tr("登录 Mac 时自动启动 Choclift", "Launch Choclift at Login", language: lang),
                isOn: Binding(
                    get: { coordinator.launchAtLoginEnabled },
                    set: { coordinator.setLaunchAtLogin($0) }
                )
            )
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var backupAndResetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("配置备份与还原", "Layout Backup & Reset", language: lang), systemImage: "externaldrive.fill.badge.checkmark")
                .font(.headline)

            HStack(spacing: 10) {
                Button {
                    exportProfileJSON()
                } label: {
                    Label(L10n.tr("导出配置…", "Export…", language: lang), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button {
                    importProfileJSON()
                } label: {
                    Label(L10n.tr("导入配置…", "Import…", language: lang), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(role: .destructive) {
                    coordinator.resetToFactoryDefaults()
                } label: {
                    Text(L10n.tr("恢复默认", "Reset", language: lang))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.tr("实时指令日志", "Live Companion Activity", language: lang), systemImage: "waveform.path.ecg")
                .font(.headline)

            if coordinator.activityLog.isEmpty {
                Text(L10n.tr("来自 iPhone / iPad / Watch 的点按、手势和表情输入记录将实时显示在此。", "Taps, gestures, and emoji insertions from iPhone, iPad, and Watch will appear here in real time.", language: lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.activityLog) { ev in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(ev.isSuccess ? Color.green : Color.orange)
                                    .frame(width: 7, height: 7)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(ev.summary)
                                        .font(.caption.weight(.medium))
                                    Text("\(ev.deviceName) · \(ev.timestamp.formatted(date: .omitted, time: .standard))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private func exportProfileJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "choclift-layout.json"
        if panel.runModal() == .OK, let url = panel.url {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(coordinator.profile) {
                try? data.write(to: url, options: .atomic)
                coordinator.flashBanner(L10n.tr("已导出配置文件", "Exported layout JSON", language: lang))
            }
        }
    }

    private func importProfileJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url),
           let imported = try? JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: data) {
            coordinator.mutateProfile { draft in
                draft = imported
            }
            coordinator.flashBanner(L10n.tr("成功导入配置文件", "Imported layout JSON", language: lang))
        }
    }
}

// MARK: - Main Studio Window

public struct MacMainWindowView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @ObservedObject var server: MacServerEngine

    private var lang: AppLanguage { coordinator.lang }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
        self.server = coordinator.server
    }

    public var body: some View {
        VStack(spacing: 0) {
            topNavigationHeader

            Divider()

            ZStack(alignment: .bottom) {
                Group {
                    switch coordinator.selectedSection {
                    case .chocolateBar:
                        ChocolateBarStudioView(coordinator: coordinator)
                    case .emojiBar:
                        EmojiBarStudioView(coordinator: coordinator)
                    case .timeTravel:
                        TimeTravelStudioView(coordinator: coordinator)
                    case .gestures:
                        GestureStudioView(coordinator: coordinator)
                    case .devicesAndSettings:
                        DevicesAndSettingsView(coordinator: coordinator)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let banner = coordinator.statusBannerMessage {
                    Text(banner)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.82), in: Capsule())
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: coordinator.statusBannerMessage)
        }
        .frame(minWidth: 880, minHeight: 590)
    }

    private var topNavigationHeader: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                ChocliftBrandIconView(size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("choclift")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                    Text(L10n.tr("iPhone & iPad 触控栏工作台", "Touch Bar Workflow Sweetener", language: lang))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Section Tabs
            HStack(spacing: 4) {
                ForEach(MacStudioSection.allCases) { sec in
                    let isSel = (coordinator.selectedSection == sec)
                    Button {
                        coordinator.selectedSection = sec
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: sec.sfSymbol)
                                .font(.system(size: 12, weight: .semibold))
                            Text(sec.title(in: lang))
                                .font(.system(size: 12.5, weight: isSel ? .bold : .medium))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(isSel ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(isSel ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))

            Spacer()

            if !coordinator.isAccessibilityGranted {
                Button {
                    coordinator.requestAccessibilityPermission()
                } label: {
                    Label(L10n.tr("需开启辅助功能", "Grant Accessibility", language: lang), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                coordinator.showPairingPopover.toggle()
            } label: {
                let activeLinks = Set(server.pairedDevices.filter(\.isCurrentlyConnected).compactMap(\.activeLink))
                let linkSuffix: String = {
                    if activeLinks.count == 1, let only = activeLinks.first {
                        return " · \(only.shortLabel(in: lang))"
                    } else if activeLinks.count > 1 {
                        return " · Wi-Fi+BLE"
                    }
                    return ""
                }()
                HStack(spacing: 6) {
                    Circle()
                        .fill(server.connectedDeviceCount > 0 ? Color.green : (server.isListening ? Color.orange : Color.red))
                        .frame(width: 8, height: 8)
                    Text(
                        server.connectedDeviceCount > 0
                            ? L10n.tr("已连 \(server.connectedDeviceCount) 台\(linkSuffix)", "\(server.connectedDeviceCount) Connected\(linkSuffix)", language: lang)
                            : L10n.tr("配对 PIN: \(server.currentPIN)", "Pair PIN: \(server.currentPIN)", language: lang)
                    )
                    .font(.caption.weight(.bold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $coordinator.showPairingPopover) {
                MacPairingPopoverView(coordinator: coordinator)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }
}

// MARK: - Menu Bar Extra Popover

public struct MacMenuBarPopoverView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @ObservedObject var server: MacServerEngine
    @Environment(\.openWindow) private var openWindow

    private var lang: AppLanguage { coordinator.lang }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
        self.server = coordinator.server
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ChocliftBrandIconView(size: 26)
                Text("choclift")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(server.connectedDeviceCount > 0 ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(
                    server.connectedDeviceCount > 0
                        ? L10n.tr("\(server.connectedDeviceCount) 台设备已连接", "\(server.connectedDeviceCount) Connected", language: lang)
                        : L10n.tr("等待连接", "Ready to Pair", language: lang)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Text(L10n.tr("配对码 PIN:", "Pairing PIN:", language: lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(server.currentPIN)
                    .font(.system(.body, design: .monospaced, weight: .black))
            }
            .padding(8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "studio-main")
            } label: {
                Label(L10n.tr("打开 Choclift 工作台窗口", "Open Choclift Studio", language: lang), systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)

            if !coordinator.isAccessibilityGranted {
                Button {
                    coordinator.requestAccessibilityPermission()
                } label: {
                    Label(L10n.tr("授权辅助功能权限…", "Authorize Accessibility…", language: lang), systemImage: "hand.raised.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }

            Divider()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label(L10n.tr("退出 Choclift", "Quit Choclift", language: lang), systemImage: "power")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 270)
    }
}
