import ChocliftCore
import SwiftUI

public struct WatchPairingView: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.dismiss) private var dismiss

    @State private var enteredPIN: String = ""
    @State private var manualHost: String = "127.0.0.1"
    @State private var manualPort: String = "\(ChocliftDefaults.defaultTCPPort)"

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    switch client.connectionState {
                    case .awaitingPIN(_, let macName, let errorMessage):
                        watchPINEntryCard(macName: macName, errorMessage: errorMessage)
                    case .connected(let macID, let macName):
                        connectedCard(macID: macID, macName: macName)
                        bluetoothMacsSection
                        discoveredMacsSection
                    case .connecting(let targetName):
                        connectingCard(targetName: targetName)
                    case .disconnected:
                        disconnectedIssueBanner
                        quickLocalhostButton
                        bluetoothMacsSection
                        discoveredMacsSection
                        savedMacsSection
                        manualConnectSection
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .navigationTitle(L10n.tr("连接 Mac", "Link Mac", language: lang))
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: client.connectionState) { _, newState in
            if newState.isConnected {
                CompanionFeedbackHaptics.notify(enabled: client.profile.settings.hapticFeedbackEnabled, kind: .success)
                enteredPIN = ""
                dismiss()
            } else if case .awaitingPIN(_, _, let err) = newState {
                if err != nil && enteredPIN.count == 6 {
                    CompanionFeedbackHaptics.notify(enabled: client.profile.settings.hapticFeedbackEnabled, kind: .error)
                    enteredPIN = ""
                }
            } else {
                enteredPIN = ""
            }
        }
    }

    // MARK: - 6-Digit Watch PIN Keypad

    private func watchPINEntryCard(macName: String, errorMessage: String?) -> some View {
        VStack(spacing: 7) {
            Text(L10n.tr("输入 \(macName) 配对码", "PIN on \(macName)", language: lang))
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)

            if let link = client.activeLink {
                Label(link.displayName(in: lang), systemImage: link.sfSymbol)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(palette.accentGold)
            }

            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { idx in
                    let digit: String = {
                        guard idx < enteredPIN.count else { return "•" }
                        let strIdx = enteredPIN.index(enteredPIN.startIndex, offsetBy: idx)
                        return String(enteredPIN[strIdx])
                    }()
                    let isFilled = idx < enteredPIN.count

                    Text(digit)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundStyle(isFilled ? palette.primaryText : palette.secondaryText.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(idx == enteredPIN.count ? palette.accentGold : .clear, lineWidth: 1.2)
                        )
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            } else if enteredPIN.count == 6 {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 12, height: 12)
                        .tint(palette.accentGold)
                    Text(L10n.tr("正在验证配对码…", "Verifying PIN…", language: lang))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }

            let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "CLR", "0", "⌫"]
            let cols = Array(repeating: GridItem(.flexible(), spacing: 5), count: 3)

            LazyVGrid(columns: cols, spacing: 5) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        handlePINKey(key)
                    } label: {
                        Text(key)
                            .font(.system(size: key == "CLR" ? 10 : 14, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button(L10n.tr("取消", "Cancel", language: lang)) {
                enteredPIN = ""
                client.disconnect()
            }
            .font(.caption2)
            .foregroundStyle(palette.secondaryText)
        }
        .padding(8)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func handlePINKey(_ key: String) {
        CompanionFeedbackHaptics.tap(enabled: true, intensity: .light)
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

    private func connectedCard(macID: String, macName: String) -> some View {
        let link = client.activeLink ?? .wifi
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: link.sfSymbol)
                    .font(.title3)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(macName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Text(
                        L10n.tr(
                            "已连：\(link.displayName(in: lang))",
                            "Active: \(link.displayName(in: lang))",
                            language: lang
                        )
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.green)
                    .lineLimit(1)
                }
            }

            if !client.isMacAccessibilityGranted {
                Text(L10n.tr("提示：请在 Mac 开启辅助功能权限以支持窗口与表情控制。", "Enable Accessibility on Mac for window & emoji actions.", language: lang))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
            }

            Button(role: .destructive) {
                client.disconnect()
            } label: {
                Text(L10n.tr("断开连接", "Disconnect", language: lang))
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func connectingCard(targetName: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(palette.accentGold)
            Text(L10n.tr("正在连接 \(targetName)…", "Connecting \(targetName)…", language: lang))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)
            if let link = client.activeLink {
                Label(link.displayName(in: lang), systemImage: link.sfSymbol)
                    .font(.system(size: 9.5))
                    .foregroundStyle(palette.secondaryText)
            }
            Button(L10n.tr("取消", "Cancel", language: lang)) {
                client.disconnect()
            }
            .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Discovery & Direct Connect

    @ViewBuilder
    private var disconnectedIssueBanner: some View {
        if let issue = client.lastConnectionIssue {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(issue)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
            )
        }
    }

    private var quickLocalhostButton: some View {
        Button {
            CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
            client.connectToHost(host: "127.0.0.1", port: ChocliftDefaults.defaultTCPPort, targetName: "Local Mac")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundStyle(.black)
                Text(L10n.tr("直连本机 127.0.0.1", "Connect 127.0.0.1", language: lang))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(palette.accentGold, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var discoveredMacsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L10n.tr("局域网发现", "Wi-Fi Macs", language: lang), systemImage: "wifi")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
            }

            if client.discoveredMacs.isEmpty {
                Text(
                    L10n.tr(
                        "注意：Bonjour 局域网广播不会穿过 iPhone 网络代理，Apple Watch 真机通常通过上方蓝牙 LE 连接（手表直连 Wi-Fi 或使用手动 IP / 127.0.0.1 时可用 TCP）。",
                        "Note: Bonjour does not cross the iPhone network proxy, so Bluetooth LE above is the normal Watch path (Wi-Fi works on direct Watch Wi-Fi or Manual IP / 127.0.0.1).",
                        language: lang
                    )
                )
                    .font(.system(size: 9.5))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.vertical, 4)
            } else {
                ForEach(client.discoveredMacs) { host in
                    Button {
                        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                        client.connect(to: host)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "desktopcomputer")
                                .font(.caption)
                                .foregroundStyle(palette.accentGold)
                            Text(host.name)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(8)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(9)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var bluetoothMacsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Label(L10n.tr("蓝牙 Mac (BLE)", "Bluetooth LE Macs", language: lang), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 2)
                if client.bluetoothAvailability.isProblemState {
                    Text(client.bluetoothAvailability.shortStatus(in: lang))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            if let guidance = client.bluetoothAvailability.detailGuidance(in: lang) {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                    Text(guidance)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 2)
            } else if client.discoveredBluetoothMacs.isEmpty {
                Text(
                    client.isBluetoothPoweredOn
                        ? L10n.tr("前台搜索附近蓝牙 Mac（Apple Watch 真机首选通道）… 共用同一 6 位配对码与信任令牌。", "Scanning nearby BLE Macs in foreground (normal Watch hardware path)… Uses the same 6-digit PIN & token.", language: lang)
                        : L10n.tr("真机开启蓝牙即可直连 Mac（模拟器无蓝牙硬件，请用上方 127.0.0.1）。", "Enable Bluetooth on Apple Watch hardware to connect directly (use 127.0.0.1 in Simulator).", language: lang)
                )
                .font(.system(size: 10))
                .foregroundStyle(palette.secondaryText)
                .padding(.vertical, 2)
            } else {
                ForEach(client.discoveredBluetoothMacs) { host in
                    Button {
                        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                        client.connectBluetooth(to: host)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.caption)
                                .foregroundStyle(palette.accentGold)
                            Text(host.name)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(8)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(9)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var savedMacsSection: some View {
        if !client.savedMacs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("已配对的 Mac", "Saved Macs", language: lang))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.secondaryText)

                ForEach(client.savedMacs) { saved in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(saved.macName)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                            if let host = saved.lastDirectHost, let port = saved.lastDirectPort {
                                Text("\(host):\(port)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                            } else if saved.lastBluetoothPeripheralID != nil {
                                Text("Bluetooth LE")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 2)
                        if client.canReconnectSavedMac(saved) {
                            Button {
                                client.reconnectSavedMac(saved)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption.bold())
                                    .foregroundStyle(palette.accentGold)
                            }
                            .buttonStyle(.plain)
                        }
                        Button(role: .destructive) {
                            client.forgetSavedMac(macID: saved.macID)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(7)
                    .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(9)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var manualConnectSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("手动 IP 连接", "Manual IP & Port", language: lang))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(palette.secondaryText)

            TextField("192.168.1.x", text: $manualHost)
                .autocorrectionDisabled()

            TextField("54821", text: $manualPort)
                .autocorrectionDisabled()

            Button {
                let port = UInt16(manualPort.trimmingCharacters(in: .whitespacesAndNewlines))
                    ?? ChocliftDefaults.defaultTCPPort
                client.connectToHost(host: manualHost, port: port)
            } label: {
                Text(L10n.tr("连接此地址", "Connect IP", language: lang))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accentGold)
        }
        .padding(9)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14))
    }
}
