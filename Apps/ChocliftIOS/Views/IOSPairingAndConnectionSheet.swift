import ChocliftCore
import SwiftUI

public struct IOSPairingAndConnectionSheet: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.dismiss) private var dismiss

    @State private var enteredPIN: String = ""
    @State private var manualHost: String = "127.0.0.1"
    @State private var manualPort: String = "\(ChocliftDefaults.defaultTCPPort)"
    @State private var showManualEntry: Bool = false

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    private var hasActiveFailure: Bool {
        if let issue = client.lastConnectionIssue, !issue.isEmpty {
            return true
        }
        return false
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
                    VStack(spacing: 16) {
                        switch client.connectionState {
                        case .awaitingPIN(_, let macName, let errorMsg):
                            pinEntryView(macName: macName, errorMessage: errorMsg)
                        case .connected(let macID, let macName):
                            connectedSummaryCard(macID: macID, macName: macName)
                            DisclosureGroup(L10n.tr("触觉反馈", "Haptic Feedback", language: lang)) {
                                IOSHapticQuietHoursCard(client: client)
                            }
                            discoveredHostsCard
                            bluetoothHostsCard
                            savedMacsCard
                        case .connecting(let targetName):
                            connectingCard(targetName: targetName)
                        case .disconnected:
                            disconnectedHeroOrIssueCard
                            Text(L10n.tr("蓝牙与 Wi-Fi 自动发现", "Bluetooth & Wi-Fi discovery", language: lang))
                                .font(.caption).foregroundStyle(palette.secondaryText)
                            discoveredHostsCard
                            bluetoothHostsCard
                            DisclosureGroup(L10n.tr("其他连接方式", "Other connections", language: lang)) {
                                directConnectionCard
                                savedMacsCard
                                IOSHapticQuietHoursCard(client: client)
                            }
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle(L10n.tr("连接你的 Mac", "Connect to Mac", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "Done", language: lang)) {
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .accessibilityIdentifier("ios-pairing-done")
                }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
        .onChange(of: client.connectionState) { _, newState in
            if newState.isConnected {
                CompanionHaptics.notify(enabled: client.shouldPlayOutcomeHaptics(), type: .success)
                enteredPIN = ""
            } else if case .awaitingPIN(_, _, let err) = newState {
                if err != nil {
                    CompanionHaptics.notify(enabled: client.shouldPlayOutcomeHaptics(), type: .error)
                    enteredPIN = ""
                }
            } else {
                enteredPIN = ""
            }
        }
    }

    // MARK: - 6-Digit Chocolate PIN Pad

    private func pinEntryView(macName: String, errorMessage: String?) -> some View {
        VStack(spacing: 16) {
            ChocliftBrandIconView(size: 48)
            Text(L10n.tr("输入 Mac 配对码", "Enter your Mac PIN", language: lang))
                .font(.headline).foregroundStyle(palette.primaryText)
            Text(macName).font(.caption).foregroundStyle(palette.secondaryText)
            TextField("000000", text: $enteredPIN)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .frame(minHeight: 48)
                .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: enteredPIN) { _, value in
                    enteredPIN = String(value.filter(\.isNumber).prefix(6))
                }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(palette.statusFailure)
            }
            Button(L10n.tr("连接", "Connect", language: lang)) { client.submitPIN(enteredPIN) }
                .frame(maxWidth: .infinity, minHeight: 48)
                .buttonStyle(.borderedProminent)
                .disabled(enteredPIN.count != 6)
            if let link = client.activeLink { ChocLinkBadge(link: link, language: lang, palette: palette) }
            Button(L10n.tr("选择其他 Mac", "Choose another Mac", language: lang)) {
                enteredPIN = ""
                client.disconnect()
            }
            .frame(minHeight: 44)
        }
        .padding(20)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func handlePINKey(_ key: String) {
        CompanionHaptics.tap(enabled: true, style: .light)
        switch key {
        case "CLR":
            enteredPIN = ""
        case "⌫":
            if !enteredPIN.isEmpty {
                enteredPIN.removeLast()
            }
        default:
            guard enteredPIN.count < 6 else { return }
            enteredPIN.append(key)
            if enteredPIN.count == 6 {
                client.submitPIN(enteredPIN)
            }
        }
    }

    // MARK: - Connected & Connecting Cards

    private func connectedSummaryCard(macID: String, macName: String) -> some View {
        let activeLink = client.activeLink ?? .wifi
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(palette.statusConnected.opacity(0.16))
                        .frame(width: 46, height: 46)
                    Image(systemName: activeLink.sfSymbol)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(activeLink == .bluetooth ? palette.statusBluetooth : palette.statusConnected)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(macName)
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)

                        ChocLinkBadge(link: activeLink, language: lang, palette: palette)
                    }

                    Text(
                        L10n.tr(
                            "已建立实时连接 · \(activeLink.displayName(in: lang))",
                            "Connected Live · \(activeLink.displayName(in: lang))",
                            language: lang
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                }

                Spacer(minLength: 8)

                Button(L10n.tr("断开", "Disconnect", language: lang)) {
                    client.disconnect()
                }
                .buttonStyle(.bordered)
                .tint(palette.statusFailure)
                .accessibilityIdentifier("ios-disconnect-button")
            }

            if !client.isMacAccessibilityGranted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("请在 Mac 端开启「辅助功能」权限，以启用窗口缩放手势和光标处表情输入。", "Grant Accessibility permission on your Mac to enable window gestures and cursor emoji typing.", language: lang))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.tileFillBottom.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(palette.statusConnected.opacity(0.35), lineWidth: 1)
        )
    }

    private func connectingCard(targetName: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
                .tint(palette.accent)

            VStack(spacing: 4) {
                Text(L10n.tr("正在连接「\(targetName)」…", "Connecting to \"\(targetName)\"…", language: lang))
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                if let link = client.activeLink {
                    ChocLinkBadge(link: link, language: lang, palette: palette, prominent: true)
                }
            }

            Button {
                client.disconnect()
            } label: {
                Text(L10n.tr("取消连接", "Cancel", language: lang))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.primaryText)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(palette.tileFillBottom, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-cancel-connecting-button")
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(palette.accent.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Failed / Standby / Empty Hero Card (Never hides failure behind a spinner)

    @ViewBuilder
    private var disconnectedHeroOrIssueCard: some View {
        if let issue = client.lastConnectionIssue, !issue.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(palette.statusFailure)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("未能连接到 Mac", "Connection Failed", language: lang))
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(palette.primaryText)
                        Text(issue)
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if let saved = client.savedMacs.first, client.canReconnectSavedMac(saved) {
                    Button {
                        client.reconnectSavedMac(saved)
                    } label: {
                        Label(
                            L10n.tr("重新连接 \(saved.macName)", "Retry \(saved.macName)", language: lang),
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption.weight(.bold))
                        .foregroundStyle(palette.accentForeground)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(palette.accent, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.statusFailure.opacity(0.72), lineWidth: 1.3)
            )
            .accessibilityIdentifier("ios-connection-failed-card")
        } else if client.isAutoConnectSuppressedForCurrentLaunch {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill")
                    .font(.title3)
                    .foregroundStyle(palette.secondaryText)
                Text(
                    L10n.tr(
                        "本次会话已手动断开；点按下方任意 Mac 可立即重连，下次启动将自动恢复连接。",
                        "Disconnected for this session. Tap a Mac below to reconnect now; auto-connect resumes next launch.",
                        language: lang
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
        } else if client.savedMacs.isEmpty {
            HStack(spacing: 12) {
                ChocliftBrandIconView(size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("首次配对你的 Mac", "Pair Your Mac", language: lang))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(palette.primaryText)
                    Text(
                        L10n.tr(
                            "在 Mac 上打开 Choclift，选择下方发现的设备并输入 6 位配对码。同一信任令牌支持 Wi-Fi 与蓝牙自动漫游。",
                            "Open Choclift on your Mac, pick your Mac below, and enter the 6-digit PIN. One pairing works across Wi-Fi & Bluetooth LE.",
                            language: lang
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(15)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
        }
    }

    // MARK: - Wi-Fi & Bluetooth Discovery Cards

    private var discoveredHostsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.tr("局域网发现 (Wi-Fi)", "Macs on Local Wi-Fi", language: lang), systemImage: "wifi")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                if !client.discoveredMacs.isEmpty {
                    Text("\(client.discoveredMacs.count)")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(palette.statusConnected)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.statusConnected.opacity(0.16), in: Capsule())
                } else if !hasActiveFailure && !client.connectionState.isConnected {
                    Text(L10n.tr("自动发现", "Auto-Scan", language: lang))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.tileFillBottom, in: Capsule())
                }
            }

            if client.discoveredMacs.isEmpty {
                Text(
                    L10n.tr(
                        "同一局域网下未发现广播中的 Mac。请确认 Mac 端 Choclift 已运行，或使用下方 IP / 模拟器直连。",
                        "No Macs found on local Wi-Fi yet. Make sure Choclift is running on your Mac, or use Direct IP below.",
                        language: lang
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .padding(.vertical, 4)
            } else {
                ForEach(client.discoveredMacs) { host in
                    let isSaved = (host.macID != nil && client.savedMacs.contains(where: { $0.macID == host.macID }))
                    Button {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                        client.connect(to: host)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(1)
                                if isSaved {
                                    Text(L10n.tr("已保存配对令牌", "Paired", language: lang))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(palette.statusConnected)
                                }
                            }

                            Spacer()

                            ChocLinkBadge(link: .wifi, language: lang, palette: palette)

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 50)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var bluetoothHostsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(L10n.tr("蓝牙发现 (BLE)", "Bluetooth LE", language: lang), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if client.bluetoothAvailability.isProblemState {
                    Label(client.bluetoothAvailability.shortStatus(in: lang), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(palette.statusFailure)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.statusFailure.opacity(0.18), in: Capsule())
                } else {
                    Text(client.bluetoothAvailability.shortStatus(in: lang))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(client.isBluetoothPoweredOn ? palette.statusBluetooth : palette.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.tileFillBottom, in: Capsule())
                }
            }

            if let guidance = client.bluetoothAvailability.detailGuidance(in: lang) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(palette.statusFailure)
                    Text(guidance)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.statusFailure.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if client.discoveredBluetoothMacs.isEmpty {
                Text(
                    client.isBluetoothPoweredOn
                        ? L10n.tr("离开同一 Wi-Fi 时可通过蓝牙 LE 直连附近的 Mac，共用同一 6 位配对码。", "Connects off Wi-Fi to nearby Macs over Bluetooth LE using the same 6-digit PIN.", language: lang)
                        : L10n.tr("在真机上开启蓝牙可在无同一 Wi-Fi 时连接；模拟器环境请使用 Wi-Fi 或下方 127.0.0.1 直连。", "Available on physical iPhone/iPad hardware off Wi-Fi (in Simulator, use 127.0.0.1 below).", language: lang)
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .padding(.vertical, 4)
            } else {
                ForEach(client.discoveredBluetoothMacs) { host in
                    Button {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                        client.connectBluetooth(to: host)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(palette.statusBluetooth)
                                .frame(width: 28)
                            Text(host.name)
                                .font(.system(.body, design: .rounded, weight: .semibold))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                            Spacer()
                            ChocLinkBadge(link: .bluetooth, language: lang, palette: palette)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 50)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var directConnectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(L10n.tr("IP 直连 / 模拟器快连", "Direct IP / Simulator", language: lang), systemImage: "bolt.horizontal.circle.fill")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                Spacer()

                Button {
                    CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                    client.connectToHost(host: "127.0.0.1", port: ChocliftDefaults.defaultTCPPort, targetName: "Local Mac")
                } label: {
                    Text(L10n.tr("连接本机 127.0.0.1", "Connect 127.0.0.1", language: lang))
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(palette.accentEmphasis, in: Capsule())
                        .foregroundStyle(palette.emphasisForeground)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ios-connect-localhost")
            }

            DisclosureGroup(
                L10n.tr("手动输入局域网 IP 与端口", "Enter Custom Mac IP & Port", language: lang),
                isExpanded: $showManualEntry
            ) {
                HStack(spacing: 8) {
                    TextField("192.168.1.x", text: $manualHost)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    TextField("54821", text: $manualPort)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(width: 82)

                    Button(L10n.tr("连接", "Connect", language: lang)) {
                        let portVal = UInt16(manualPort) ?? ChocliftDefaults.defaultTCPPort
                        client.connectToHost(host: manualHost, port: portVal)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .foregroundStyle(palette.accentForeground)
                }
                .padding(.top, 8)
            }
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var savedMacsCard: some View {
        if !client.savedMacs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("已保存的信任 Mac", "Paired Macs", language: lang))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(palette.primaryText)

                ForEach(client.savedMacs) { saved in
                    HStack(spacing: 10) {
                        Image(systemName: "laptopcomputer")
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(saved.macName)
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                if let host = saved.lastDirectHost, let port = saved.lastDirectPort {
                                    Text("\(host):\(port)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(palette.secondaryText)
                                }
                                if saved.lastBluetoothPeripheralID != nil {
                                    ChocLinkBadge(link: .bluetooth, language: lang, palette: palette)
                                }
                            }
                        }

                        Spacer()

                        if !client.connectionState.isConnected, client.canReconnectSavedMac(saved) {
                            Button(L10n.tr("重连", "Reconnect", language: lang)) {
                                client.reconnectSavedMac(saved)
                            }
                            .buttonStyle(.bordered)
                            .tint(palette.accent)
                        }

                        Button(role: .destructive) {
                            client.forgetSavedMac(macID: saved.macID)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.statusFailure)
                    }
                    .padding(12)
                    .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
            .padding(16)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
        }
    }
}
