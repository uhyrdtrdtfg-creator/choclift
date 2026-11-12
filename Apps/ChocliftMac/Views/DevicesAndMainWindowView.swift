import AppKit
import ChocliftCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared PIN Formatting Helper

private func formattedSixDigitPIN(_ raw: String) -> String {
    guard raw.count == 6 else { return raw }
    let idx = raw.index(raw.startIndex, offsetBy: 3)
    return "\(raw[..<idx]) \(raw[idx...])"
}

// MARK: - Pairing PIN Popover

public struct MacPairingPopoverView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @ObservedObject var server: MacServerEngine
    @State private var didCopyPIN: Bool = false

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
        self.server = coordinator.server
    }

    private var sortedDevices: [PairedDeviceRecord] {
        server.pairedDevices.sorted { lhs, rhs in
            if lhs.isCurrentlyConnected != rhs.isCurrentlyConnected {
                return lhs.isCurrentlyConnected && !rhs.isCurrentlyConnected
            }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                ChocliftBrandIconView(size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("配对伴侣设备", "Pair a Companion Device", language: lang))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Text(server.macName)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                listenerStateBadge
            }

            if let errorMessage = server.lastErrorMessage, !errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.statusFailure)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("本地监听启动失败", "Listener Failed to Start", language: lang))
                            .font(.caption.bold())
                            .foregroundStyle(palette.statusFailure)
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(palette.statusFailure.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.statusFailure.opacity(0.45), lineWidth: 1)
                )
            }

            // 6-Digit Molded Chocolate PIN Display
            VStack(spacing: 10) {
                HStack {
                    Text(L10n.tr("一次性 6 位安全配对码", "One-Time 6-Digit Pairing PIN", language: lang))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    HStack(spacing: 6) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(server.currentPIN, forType: .string)
                            didCopyPIN = true
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.5))
                                didCopyPIN = false
                            }
                        } label: {
                            Label(
                                didCopyPIN
                                    ? L10n.tr("已复制", "Copied", language: lang)
                                    : L10n.tr("复制", "Copy", language: lang),
                                systemImage: didCopyPIN ? "checkmark" : "doc.on.doc"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.primaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(palette.tileFillTop, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            server.regeneratePIN()
                        } label: {
                            Label(L10n.tr("刷新", "New PIN", language: lang), systemImage: "arrow.clockwise")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(palette.tileFillTop, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("生成新的 6 位配对码", "Generate a new 6-digit PIN", language: lang))
                    }
                }

                let digits = Array(server.currentPIN)
                HStack(spacing: 6) {
                    ForEach(0..<min(digits.count, 6), id: \.self) { idx in
                        Text(String(digits[idx]))
                            .font(.system(size: 24, weight: .black, design: .monospaced))
                            .foregroundStyle(palette.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                LinearGradient(
                                    colors: [palette.tileFillTop, palette.tileFillBottom],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(palette.tileBorderHighlight.opacity(0.65), lineWidth: 1)
                            )
                        if idx == 2 {
                            Spacer().frame(width: 4)
                        }
                    }
                }
            }
            .padding(13)
            .background(
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )

            // Transport Readiness Pills
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    transportStatusPill(
                        symbol: "wifi",
                        title: server.isListening
                            ? L10n.tr("Wi-Fi 局域网就绪", "Wi-Fi Ready", language: lang)
                            : L10n.tr("Wi-Fi 未监听", "Wi-Fi Offline", language: lang),
                        tint: server.isListening ? palette.statusConnected : palette.secondaryText
                    )

                    transportStatusPill(
                        symbol: server.bluetoothAvailability.isProblemState
                            ? "exclamationmark.triangle.fill"
                            : "antenna.radiowaves.left.and.right",
                        title: server.isBluetoothAdvertising
                            ? L10n.tr("蓝牙 LE 广播中", "Bluetooth LE Ready", language: lang)
                            : server.bluetoothAvailability.shortStatus(in: lang),
                        tint: server.isBluetoothAdvertising
                            ? palette.statusBluetooth
                            : (server.bluetoothAvailability.isProblemState ? palette.statusFailure : palette.secondaryText)
                    )
                }

                if let btGuidance = server.bluetoothAvailability.detailGuidance(in: lang) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(palette.statusFailure)
                            .padding(.top, 1)
                        Text(btGuidance)
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.statusFailure.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                if let port = server.listeningPort {
                    let ipText = server.localIPAddresses.isEmpty
                        ? "127.0.0.1:\(port)"
                        : server.localIPAddresses.map { "\($0):\(port)" }.joined(separator: "  ·  ")
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                        Text(ipText)
                            .font(.caption2.monospaced())
                            .foregroundStyle(palette.secondaryText)
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                }
            }

            Divider()

            // Paired Devices or Empty Onboarding Steps
            if sortedDevices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        L10n.tr("首次配对只需两步", "Pair in Two Quick Steps", language: lang),
                        systemImage: "sparkles"
                    )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.primaryText)

                    Text(
                        L10n.tr(
                            "1. 在 iPhone、iPad 或 Apple Watch 打开 Choclift\n2. 选择「\(server.macName)」并输入上方 6 位配对码（Wi-Fi 与蓝牙共用同一信任令牌）",
                            "1. Open Choclift on iPhone, iPad, or Apple Watch\n2. Tap \"\(server.macName)\" and enter the 6-digit PIN above (shared across Wi-Fi & BLE)",
                            language: lang
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
                    .lineSpacing(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(L10n.tr("已配对伴侣 (\(sortedDevices.count))", "Paired Companions (\(sortedDevices.count))", language: lang))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                        Spacer()
                        Button {
                            coordinator.showPairingPopover = false
                            coordinator.selectedSection = .devicesAndSettings
                        } label: {
                            Text(L10n.tr("管理设备", "Manage", language: lang))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(sortedDevices.prefix(4)) { device in
                        HStack(spacing: 8) {
                            Image(systemName: device.platform.sfSymbol)
                                .font(.callout)
                                .foregroundStyle(device.isCurrentlyConnected ? palette.statusConnected : palette.secondaryText)
                                .frame(width: 20)

                            Text(device.deviceName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            if device.isCurrentlyConnected, let link = device.activeLink {
                                ChocLinkBadge(link: link, language: lang, palette: palette)
                            } else if device.isCurrentlyConnected {
                                Text(L10n.tr("在线", "Online", language: lang))
                                    .font(.caption2.bold())
                                    .foregroundStyle(palette.statusConnected)
                            } else {
                                Text(L10n.tr("待机", "Standby", language: lang))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(palette.secondaryText)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(palette.barSurface, in: Capsule())
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 384)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .tint(palette.accent)
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var listenerStateBadge: some View {
        if server.lastErrorMessage != nil {
            Label(L10n.tr("异常", "Error", language: lang), systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.bold())
                .foregroundStyle(palette.statusFailure)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.statusFailure.opacity(0.16), in: Capsule())
        } else if server.isListening {
            HStack(spacing: 5) {
                Circle()
                    .fill(palette.statusConnected)
                    .frame(width: 7, height: 7)
                Text(L10n.tr("可被发现", "Discoverable", language: lang))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.statusConnected)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(palette.statusConnected.opacity(0.14), in: Capsule())
        } else {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(palette.accent)
                Text(L10n.tr("启动中", "Starting", language: lang))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    private func transportStatusPill(symbol: String, title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.bold())
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Devices & Preferences Section

public struct DevicesAndSettingsView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @ObservedObject var server: MacServerEngine

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
        self.server = coordinator.server
    }

    private var sortedDevices: [PairedDeviceRecord] {
        server.pairedDevices.sorted { lhs, rhs in
            if lhs.isCurrentlyConnected != rhs.isCurrentlyConnected {
                return lhs.isCurrentlyConnected && !rhs.isCurrentlyConnected
            }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
    }

    public var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                // Left Column: Permissions + Devices + Preferences
                VStack(alignment: .leading, spacing: 16) {
                    accessibilityPermissionCard

                    pairedDevicesCard

                    appearanceAndPreferencesCard
                }
                .frame(maxWidth: .infinity)

                // Right Column: Backup & Live Activity Stream
                VStack(alignment: .leading, spacing: 16) {
                    backupAndResetCard

                    liveActivityCard
                }
                .frame(width: 348)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
        }
    }

    private var accessibilityPermissionCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(coordinator.isAccessibilityGranted ? palette.statusConnected.opacity(0.15) : palette.tileFillBottom)
                    .frame(width: 42, height: 42)
                Image(systemName: coordinator.isAccessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(coordinator.isAccessibilityGranted ? palette.statusConnected : palette.secondaryText)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(L10n.tr("辅助功能权限", "Accessibility Permission", language: lang))
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Text(
                        coordinator.isAccessibilityGranted
                            ? L10n.tr("已就绪", "Active", language: lang)
                            : L10n.tr("待开启", "Action Needed", language: lang)
                    )
                    .font(.caption2.bold())
                    .foregroundStyle(coordinator.isAccessibilityGranted ? palette.statusConnected : palette.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        coordinator.isAccessibilityGranted ? palette.statusConnected.opacity(0.16) : palette.tileFillBottom,
                        in: Capsule()
                    )
                }
                Text(
                    coordinator.isAccessibilityGranted
                        ? L10n.tr("窗口贴靠/最大化手势、剪贴板快捷键与光标表情直输均已启用。", "Window gestures, clipboard shortcuts, and cursor emoji typing are ready.", language: lang)
                        : L10n.tr("开启后方可使用远程窗口管理、复制粘贴手势与光标处直接输入表情。", "Grant access in System Settings → Privacy & Security → Accessibility for window & emoji actions.", language: lang)
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
            }

            Spacer(minLength: 8)

            if !coordinator.isAccessibilityGranted {
                Button(L10n.tr("前往授权…", "Grant Access…", language: lang)) {
                    coordinator.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accentEmphasis)
                .foregroundStyle(palette.emphasisForeground)
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var pairedDevicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(
                    L10n.tr("伴侣设备列表", "Companion Devices", language: lang),
                    systemImage: "iphone.and.arrow.forward"
                )
                .font(.headline)
                .foregroundStyle(palette.primaryText)

                if !server.pairedDevices.isEmpty {
                    Text(
                        L10n.tr(
                            "\(server.connectedDeviceCount) 在线 / \(server.pairedDevices.count) 已配对",
                            "\(server.connectedDeviceCount) Online / \(server.pairedDevices.count) Paired",
                            language: lang
                        )
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.tileFillBottom, in: Capsule())
                }

                Spacer()

                if server.bluetoothAvailability.isProblemState {
                    Label(server.bluetoothAvailability.shortStatus(in: lang), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(palette.statusFailure)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(palette.statusFailure.opacity(0.16), in: Capsule())
                }

                Button {
                    coordinator.showPairingPopover = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "key.fill")
                            .font(.caption2)
                            .foregroundStyle(palette.accent)
                        Text("PIN \(formattedSixDigitPIN(server.currentPIN))")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.tileFillTop.opacity(0.92), in: Capsule())
                    .foregroundStyle(palette.primaryText)
                    .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if let errorMessage = server.lastErrorMessage, !errorMessage.isEmpty {
                Label(
                    L10n.tr("网络监听异常：\(errorMessage)", "Network listener issue: \(errorMessage)", language: lang),
                    systemImage: "exclamationmark.octagon.fill"
                )
                .font(.caption)
                .foregroundStyle(palette.statusFailure)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.statusFailure.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if let btGuidance = server.bluetoothAvailability.detailGuidance(in: lang) {
                Label(btGuidance, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(palette.statusFailure)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.statusFailure.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if sortedDevices.isEmpty {
                emptyPairedDevicesState
            } else {
                VStack(spacing: 8) {
                    ForEach(sortedDevices) { device in
                        deviceRow(device)
                    }
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var emptyPairedDevicesState: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ForEach([DevicePlatform.iPhone, .iPad, .appleWatch], id: \.rawValue) { platform in
                    Image(systemName: platform.sfSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 38, height: 38)
                        .background(palette.tileFillTop.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            VStack(spacing: 4) {
                Text(L10n.tr("尚未配对任何伴侣设备", "No Paired Companions Yet", language: lang))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(palette.primaryText)
                Text(
                    L10n.tr(
                        "在 iPhone、iPad 或 Apple Watch 上打开 Choclift，选择「\(server.macName)」并输入 6 位配对码 \(formattedSixDigitPIN(server.currentPIN))。配对后支持 Wi-Fi 与蓝牙 LE 自动漫游重连。",
                        "Open Choclift on iPhone, iPad, or Apple Watch, choose \"\(server.macName)\", and enter PIN \(formattedSixDigitPIN(server.currentPIN)). Paired devices roam seamlessly between Wi-Fi and Bluetooth LE.",
                        language: lang
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            }

            Button {
                coordinator.showPairingPopover = true
            } label: {
                Label(
                    L10n.tr("查看配对码与直连地址", "View Pairing PIN & Direct IP", language: lang),
                    systemImage: "qrcode.viewfinder"
                )
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accentEmphasis)
            .foregroundStyle(palette.emphasisForeground)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(palette.backgroundBottom.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    private func deviceRow(_ device: PairedDeviceRecord) -> some View {
        let isOnline = device.isCurrentlyConnected
        return HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOnline ? palette.statusConnected.opacity(0.15) : palette.tileFillTop)
                    .frame(width: 40, height: 40)
                Image(systemName: device.platform.sfSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isOnline ? palette.statusConnected : palette.secondaryText)
                    .frame(width: 40, height: 40)
                Circle()
                    .fill(isOnline ? palette.statusConnected : palette.secondaryText.opacity(0.55))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(palette.barSurface, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(device.deviceName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    if isOnline, let link = device.activeLink {
                        ChocLinkBadge(link: link, language: lang, palette: palette)
                    } else if isOnline {
                        Text(L10n.tr("在线", "Online", language: lang))
                            .font(.caption2.bold())
                            .foregroundStyle(palette.statusConnected)
                    } else {
                        Text(L10n.tr("已保存令牌", "Paired", language: lang))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(palette.barSurface, in: Capsule())
                    }
                }

                Text(
                    isOnline
                        ? "\(device.platform.rawValue) · \(L10n.tr("实时连接", "Connected Live", language: lang))\(device.activeLink.map { " · \($0.displayName(in: lang))" } ?? "")"
                        : "\(device.platform.rawValue) · \(L10n.tr("最近在线", "Last seen", language: lang)) \(device.lastSeenAt.formatted(.relative(presentation: .named)))"
                )
                .font(.caption2)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(role: .destructive) {
                server.removePairedDevice(deviceID: device.deviceID)
            } label: {
                Label(L10n.tr("移除", "Forget", language: lang), systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(palette.statusFailure)
            .controlSize(.small)
        }
        .padding(11)
        .background(
            isOnline ? palette.statusConnected.opacity(0.06) : palette.tileFillBottom,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isOnline ? palette.statusConnected.opacity(0.32) : palette.subtleCardStroke,
                    lineWidth: 1
                )
        )
    }

    private var appearanceAndPreferencesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(L10n.tr("外观主题与伴侣偏好", "Theme & Companion Preferences", language: lang), systemImage: "paintpalette.fill")
                .font(.headline)
                .foregroundStyle(palette.primaryText)

            LabeledContent(L10n.tr("界面主题", "Palette Theme", language: lang)) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(palette.tileFillTop)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(palette.accent, lineWidth: 1.5))

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
                    .labelsHidden()
                    .frame(width: 196)
                }
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
                .labelsHidden()
                .frame(width: 196)
            }

            Divider()

            Toggle(
                L10n.tr("伴侣设备点按与手势触感反馈", "Companion Haptic Feedback on Tap & Gesture", language: lang),
                isOn: Binding(
                    get: { coordinator.profile.settings.hapticFeedbackEnabled },
                    set: { v in coordinator.mutateProfile { $0.settings.hapticFeedbackEnabled = v } }
                )
            )
            .tint(palette.accent)

            Toggle(
                L10n.tr("连接时保持 iPhone / iPad 屏幕常亮", "Keep iPhone / iPad Screen Awake While Connected", language: lang),
                isOn: Binding(
                    get: { coordinator.profile.settings.keepCompanionScreenAwake },
                    set: { v in coordinator.mutateProfile { $0.settings.keepCompanionScreenAwake = v } }
                )
            )
            .tint(palette.accent)

            Toggle(
                L10n.tr("登录 Mac 时自动启动 Choclift", "Launch Choclift at Login", language: lang),
                isOn: Binding(
                    get: { coordinator.launchAtLoginEnabled },
                    set: { coordinator.setLaunchAtLogin($0) }
                )
            )
            .tint(palette.accent)
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var backupAndResetCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(L10n.tr("配置备份与还原", "Layout Backup & Reset", language: lang), systemImage: "externaldrive.fill.badge.checkmark")
                .font(.headline)
                .foregroundStyle(palette.primaryText)

            Text(L10n.tr("将全部 8 页巧克力槽位、表情滑页与手势映射导出为 JSON，随时迁移或恢复。", "Export or restore all 8 Chocolate Bar pages, Emoji slides, and gesture bindings as JSON.", language: lang))
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

            HStack(spacing: 8) {
                Button {
                    exportProfileJSON()
                } label: {
                    Label(L10n.tr("导出…", "Export…", language: lang), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button {
                    importProfileJSON()
                } label: {
                    Label(L10n.tr("导入…", "Import…", language: lang), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(role: .destructive) {
                    coordinator.resetToFactoryDefaults()
                } label: {
                    Text(L10n.tr("恢复默认", "Reset", language: lang))
                }
                .buttonStyle(.bordered)
                .tint(palette.statusFailure)
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.tr("实时指令日志", "Live Companion Activity", language: lang), systemImage: "waveform.path.ecg")
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                Spacer()
                if !coordinator.activityLog.isEmpty {
                    Text("\(coordinator.activityLog.count)")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(palette.tileFillBottom, in: Capsule())
                }
            }

            if coordinator.activityLog.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "hand.tap")
                        .font(.title2)
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("暂无远程指令记录", "No Activity Yet", language: lang))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(palette.primaryText)
                    Text(L10n.tr("来自 iPhone、iPad 或 Watch 的点按、手势和表情输入将实时显示在此。", "Taps, gestures, and emoji insertions from iPhone, iPad, and Watch appear here live.", language: lang))
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 12)
                .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(coordinator.activityLog) { ev in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: ev.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(ev.isSuccess ? palette.statusConnected : palette.statusFailure)
                                    .padding(.top, 1)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ev.summary)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(palette.primaryText)
                                        .lineLimit(2)
                                    HStack(spacing: 4) {
                                        Text(ev.deviceName)
                                            .font(.caption2.weight(.semibold))
                                        Text("·")
                                        Text(ev.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.caption2.monospacedDigit())
                                    }
                                    .foregroundStyle(palette.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
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
    private var palette: ChocPalette { coordinator.palette }

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
                    case .flows:
                        ActionFlowsStudioView(coordinator: coordinator)
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
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.caption.bold())
                            .foregroundStyle(palette.secondaryText)
                        Text(banner)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(palette.primaryText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(palette.barSurface.opacity(0.96), in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    .shadow(color: palette.primaryText.opacity(0.08), radius: 10, x: 0, y: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: coordinator.statusBannerMessage)
        }
        .frame(minWidth: 960, minHeight: 610)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .tint(palette.accent)
    }

    private var topNavigationHeader: some View {
        HStack(spacing: 14) {
            // Brand Lockup
            HStack(spacing: 10) {
                ChocliftBrandIconView(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("choclift")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                    Text(L10n.tr("iPhone · iPad · Watch 触控栏工作台", "Companion Touch Bar Studio", language: lang))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // Section Tabs
            HStack(spacing: 4) {
                ForEach(MacStudioSection.allCases) { sec in
                    let isSel = (coordinator.selectedSection == sec)
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            coordinator.selectedSection = sec
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: sec.sfSymbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isSel ? palette.accent : palette.secondaryText)
                            Text(sec.title(in: lang))
                                .font(.system(size: 12.5, weight: isSel ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isSel ? palette.primaryText : palette.secondaryText)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            isSel ? palette.accent.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isSel ? palette.accent.opacity(0.65) : .clear, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))

            Spacer(minLength: 8)

            if !coordinator.isAccessibilityGranted {
                Button {
                    coordinator.requestAccessibilityPermission()
                } label: {
                    Label(L10n.tr("开启辅助功能", "Accessibility", language: lang), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(palette.barSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("点击授权辅助功能权限以启用窗口手势和表情输入", "Grant Accessibility permission for window & emoji control", language: lang))
            }

            headerConnectionButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(palette.backgroundBottom.opacity(0.45))
    }

    private var headerConnectionButton: some View {
        let activeLinks = Array(Set(server.pairedDevices.filter(\.isCurrentlyConnected).compactMap(\.activeLink)))
            .sorted { $0.rawValue < $1.rawValue }

        return Button {
            coordinator.showPairingPopover.toggle()
        } label: {
            HStack(spacing: 7) {
                if server.lastErrorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(palette.statusFailure)
                    Text(L10n.tr("监听异常", "Listener Issue", language: lang))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(palette.statusFailure)
                } else if !server.isListening {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(palette.accent)
                    Text(L10n.tr("正在启动…", "Starting…", language: lang))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                } else if server.connectedDeviceCount > 0 {
                    Circle()
                        .fill(palette.statusConnected)
                        .frame(width: 7.5, height: 7.5)
                    Text(
                        L10n.tr(
                            "已连 \(server.connectedDeviceCount) 台",
                            "\(server.connectedDeviceCount) Connected",
                            language: lang
                        )
                    )
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.primaryText)

                    ForEach(activeLinks, id: \.rawValue) { link in
                        HStack(spacing: 3) {
                            Image(systemName: link.sfSymbol)
                                .font(.system(size: 9.5, weight: .bold))
                            Text(link.shortLabel(in: lang))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(link == .bluetooth ? palette.statusBluetooth : palette.statusConnected)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((link == .bluetooth ? palette.statusBluetooth : palette.statusConnected).opacity(0.16), in: Capsule())
                    }
                } else if !server.pairedDevices.isEmpty {
                    Circle()
                        .fill(palette.secondaryText)
                        .frame(width: 7, height: 7)
                    Text(
                        L10n.tr(
                            "待连 · PIN \(formattedSixDigitPIN(server.currentPIN))",
                            "Standby · PIN \(formattedSixDigitPIN(server.currentPIN))",
                            language: lang
                        )
                    )
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                } else {
                    Image(systemName: "link.badge.plus")
                        .font(.caption.bold())
                        .foregroundStyle(palette.accentEmphasis)
                    Text(
                        L10n.tr(
                            "配对 · \(formattedSixDigitPIN(server.currentPIN))",
                            "Pair · \(formattedSixDigitPIN(server.currentPIN))",
                            language: lang
                        )
                    )
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(palette.barSurface, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        server.lastErrorMessage != nil
                            ? palette.statusFailure.opacity(0.55)
                            : palette.subtleCardStroke,
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $coordinator.showPairingPopover) {
            MacPairingPopoverView(coordinator: coordinator)
        }
    }
}

// MARK: - Menu Bar Extra Popover

public struct MacMenuBarPopoverView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @ObservedObject var server: MacServerEngine
    @Environment(\.openWindow) private var openWindow

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
        self.server = coordinator.server
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                ChocliftBrandIconView(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("choclift")
                        .font(.system(.headline, design: .rounded, weight: .black))
                        .foregroundStyle(palette.primaryText)
                    Text(
                        server.connectedDeviceCount > 0
                            ? L10n.tr("\(server.connectedDeviceCount) 台伴侣在线", "\(server.connectedDeviceCount) Companion(s) Live", language: lang)
                            : (server.lastErrorMessage != nil
                                ? L10n.tr("本地监听异常", "Listener Issue", language: lang)
                                : L10n.tr("等待伴侣连接", "Ready to Pair", language: lang))
                    )
                    .font(.caption2)
                    .foregroundStyle(server.lastErrorMessage != nil ? palette.statusFailure : palette.secondaryText)
                }
                Spacer()
                Circle()
                    .fill(
                        server.lastErrorMessage != nil
                            ? palette.statusFailure
                            : (server.connectedDeviceCount > 0 ? palette.statusConnected : palette.secondaryText)
                    )
                    .frame(width: 8, height: 8)
            }

            if !server.pairedDevices.filter(\.isCurrentlyConnected).isEmpty {
                VStack(spacing: 5) {
                    ForEach(server.pairedDevices.filter(\.isCurrentlyConnected)) { dev in
                        HStack(spacing: 6) {
                            Image(systemName: dev.platform.sfSymbol)
                                .font(.caption)
                                .foregroundStyle(palette.statusConnected)
                            Text(dev.deviceName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                            Spacer()
                            if let link = dev.activeLink {
                                ChocLinkBadge(link: link, language: lang, palette: palette)
                            }
                        }
                    }
                }
                .padding(8)
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            }

            HStack {
                Text(L10n.tr("配对码 PIN", "Pairing PIN", language: lang))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text(formattedSixDigitPIN(server.currentPIN))
                    .font(.system(.callout, design: .monospaced, weight: .black))
                    .foregroundStyle(palette.primaryText)
                Button {
                    server.regeneratePIN()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
                .help(L10n.tr("刷新配对码", "Refresh PIN", language: lang))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "studio-main")
            } label: {
                Label(L10n.tr("打开 Choclift 工作台", "Open Choclift Studio", language: lang), systemImage: "macwindow")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .foregroundStyle(palette.accentForeground)

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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
        }
        .padding(14)
        .frame(width: 292)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .tint(palette.accent)
    }
}
