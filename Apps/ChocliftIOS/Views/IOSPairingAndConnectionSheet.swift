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
                    VStack(spacing: 20) {
                        switch client.connectionState {
                        case .awaitingPIN(_, let macName, let errorMsg):
                            pinEntryView(macName: macName, errorMessage: errorMsg)
                        case .connected(let macID, let macName):
                            connectedSummaryCard(macID: macID, macName: macName)
                            discoveredHostsCard
                            bluetoothHostsCard
                        case .connecting(let targetName):
                            connectingCard(targetName: targetName)
                        case .disconnected:
                            disconnectedStatusCard
                            discoveredHostsCard
                            bluetoothHostsCard
                            directConnectionCard
                            savedMacsCard
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(L10n.tr("连接你的 Mac", "Connect to Mac", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "Done", language: lang)) {
                        dismiss()
                    }
                    .foregroundStyle(palette.accentGold)
                }
            }
        }
        .onChange(of: client.connectionState) { _, newState in
            if newState.isConnected {
                CompanionHaptics.notify(enabled: client.profile.settings.hapticFeedbackEnabled, type: .success)
                enteredPIN = ""
            }
        }
    }

    // MARK: - 6-Digit Chocolate PIN Pad

    private func pinEntryView(macName: String, errorMessage: String?) -> some View {
        VStack(spacing: 16) {
            ChocliftBrandIconView(size: 52)

            Text(L10n.tr("输入「\(macName)」上的 6 位配对码", "Enter 6-Digit PIN Shown on \"\(macName)\"", language: lang))
                .font(.headline)
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)

            if let link = client.activeLink {
                Label(
                    L10n.tr("当前配对通道：\(link.displayName(in: lang))", "Pairing over \(link.displayName(in: lang))", language: lang),
                    systemImage: link.sfSymbol
                )
                .font(.caption.bold())
                .foregroundStyle(palette.accentGold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(palette.tileFillBottom, in: Capsule())
            }

            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { idx in
                    let charStr: String = {
                        guard idx < enteredPIN.count else { return "" }
                        let strIdx = enteredPIN.index(enteredPIN.startIndex, offsetBy: idx)
                        return String(enteredPIN[strIdx])
                    }()

                    Text(charStr)
                        .font(.system(size: 24, weight: .black, design: .monospaced))
                        .foregroundStyle(palette.primaryText)
                        .frame(width: 42, height: 50)
                        .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(idx == enteredPIN.count ? palette.accentGold : palette.tileBorderHighlight.opacity(0.4), lineWidth: 1.5)
                        )
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // Numeric Keypad
            let digits = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "CLR", "0", "⌫"]
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 10), count: 3), spacing: 10) {
                ForEach(digits, id: \.self) { key in
                    Button {
                        handlePINKey(key)
                    } label: {
                        Text(key)
                            .font(.system(size: key == "CLR" ? 13 : 20, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .frame(width: 72, height: 46)
                            .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(L10n.tr("返回设备列表", "Cancel & Choose Another Mac", language: lang)) {
                enteredPIN = ""
                client.disconnect()
            }
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
        }
        .padding(18)
        .background(palette.barSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 22))
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

    // MARK: - Connected & Discovery Cards

    private func connectedSummaryCard(macID: String, macName: String) -> some View {
        let activeLink = client.activeLink ?? .wifi
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: activeLink.sfSymbol)
                    .font(.title2)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(macName)
                            .font(.headline)
                            .foregroundStyle(palette.primaryText)
                        Text(activeLink.shortLabel(in: lang))
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.22), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    Text(
                        L10n.tr(
                            "当前活动连接：\(activeLink.displayName(in: lang))",
                            "Active Link: \(activeLink.displayName(in: lang))",
                            language: lang
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                }
                Spacer()
                Button(L10n.tr("断开", "Disconnect", language: lang)) {
                    client.disconnect()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            if !client.isMacAccessibilityGranted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L10n.tr("提示：请在 Mac 端开启「辅助功能」权限以启用窗口缩放手势和光标表情输入。", "Tip: Grant Accessibility permission on your Mac to enable window gestures & cursor emoji typing.", language: lang))
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func connectingCard(targetName: String) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(palette.accentGold)
            Text(L10n.tr("正在连接 \(targetName)…", "Connecting to \(targetName)…", language: lang))
                .font(.subheadline.bold())
                .foregroundStyle(palette.primaryText)
            if let link = client.activeLink {
                Label(link.displayName(in: lang), systemImage: link.sfSymbol)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            Button(L10n.tr("取消", "Cancel", language: lang)) {
                client.disconnect()
            }
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var disconnectedStatusCard: some View {
        if let issue = client.lastConnectionIssue {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("当前未连接", "Disconnected", language: lang))
                        .font(.subheadline.bold())
                        .foregroundStyle(palette.primaryText)
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            )
        } else if client.isAutoConnectSuppressedForCurrentLaunch {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill")
                    .font(.title3)
                    .foregroundStyle(palette.secondaryText)
                Text(
                    L10n.tr(
                        "本次运行已手动断开；点击下方设备可立即重连，下次打开应用将恢复自动连接。",
                        "Disconnected for this launch. Tap a Mac below to reconnect now; next launch will auto-connect again.",
                        language: lang
                    )
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var discoveredHostsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.tr("局域网发现的 Mac", "Macs on Local Wi-Fi", language: lang), systemImage: "wifi")
                    .font(.subheadline.bold())
                    .foregroundStyle(palette.primaryText)
                Spacer()
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(palette.secondaryText)
            }

            if client.discoveredMacs.isEmpty {
                Text(L10n.tr("正在同一 Wi-Fi 下搜索运行中的 Choclift Mac 端…（如在模拟器运行，可直接使用下方本机一键直连）", "Searching local Wi-Fi for Choclift Mac… (Or use Direct IP / Simulator Localhost below)", language: lang))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.vertical, 6)
            } else {
                ForEach(client.discoveredMacs) { host in
                    Button {
                        client.connect(to: host)
                    } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(palette.accentGold)
                            Text(host.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(palette.primaryText)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(12)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var bluetoothHostsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.tr("蓝牙发现的 Mac (BLE)", "Macs over Bluetooth LE", language: lang), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.bold())
                    .foregroundStyle(palette.primaryText)
                Spacer()
                if client.isBluetoothPoweredOn {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(palette.secondaryText)
                } else if client.bluetoothAvailability.isProblemState {
                    Label(client.bluetoothAvailability.shortStatus(in: lang), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                } else {
                    Text(client.bluetoothAvailability.shortStatus(in: lang))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.secondaryText)
                }
            }

            if let guidance = client.bluetoothAvailability.detailGuidance(in: lang) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(guidance)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            } else if client.discoveredBluetoothMacs.isEmpty {
                Text(
                    client.isBluetoothPoweredOn
                        ? L10n.tr("正在通过蓝牙搜索附近的 Choclift Mac… 离开同一 Wi-Fi 时可直连，使用相同 6 位配对码与已保存令牌。", "Scanning Bluetooth LE for nearby Choclift Macs… Works off Wi-Fi with the same 6-digit PIN and saved token.", language: lang)
                        : L10n.tr("蓝牙在真机上可用（模拟器无蓝牙硬件时请使用上方 Wi-Fi 或 127.0.0.1 直连）。开启蓝牙后可在无同一 Wi-Fi 时自动连接。", "Enable Bluetooth on a physical device to connect off Wi-Fi with the same PIN (use Wi-Fi or 127.0.0.1 in Simulator).", language: lang)
                )
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
            } else {
                ForEach(client.discoveredBluetoothMacs) { host in
                    Button {
                        client.connectBluetooth(to: host)
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(palette.accentGold)
                            Text(host.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(palette.primaryText)
                            Spacer()
                            Text("BLE")
                                .font(.caption2.bold())
                                .foregroundStyle(palette.secondaryText)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(12)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var directConnectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.tr("IP 直连 / 模拟器快连", "Direct IP / Simulator Connect", language: lang), systemImage: "bolt.horizontal.circle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Button {
                    client.connectToHost(host: "127.0.0.1", port: ChocliftDefaults.defaultTCPPort, targetName: "Local Mac")
                } label: {
                    Text(L10n.tr("一键连本机 Mac", "Connect 127.0.0.1", language: lang))
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(palette.accentGold, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
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
                    .tint(palette.accentGold)
                }
                .padding(.top, 8)
            }
            .font(.caption)
            .foregroundStyle(palette.secondaryText)
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var savedMacsCard: some View {
        if !client.savedMacs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("已保存的信任 Mac", "Previously Paired Macs", language: lang))
                    .font(.subheadline.bold())
                    .foregroundStyle(palette.primaryText)

                ForEach(client.savedMacs) { saved in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(saved.macName)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(palette.primaryText)
                            HStack(spacing: 6) {
                                if let host = saved.lastDirectHost, let port = saved.lastDirectPort {
                                    Text("\(host):\(port)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(palette.secondaryText)
                                }
                                if saved.lastBluetoothPeripheralID != nil {
                                    Label("BLE", systemImage: "antenna.radiowaves.left.and.right")
                                        .font(.caption2)
                                        .foregroundStyle(palette.secondaryText)
                                }
                            }
                        }
                        Spacer()
                        if client.canReconnectSavedMac(saved) {
                            Button(L10n.tr("重连", "Reconnect", language: lang)) {
                                client.reconnectSavedMac(saved)
                            }
                            .buttonStyle(.bordered)
                            .tint(palette.accentGold)
                        }
                        Button(role: .destructive) {
                            client.forgetSavedMac(macID: saved.macID)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(16)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}
