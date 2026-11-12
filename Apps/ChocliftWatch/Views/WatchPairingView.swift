import ChocliftCore
import SwiftUI

public struct WatchPairingView: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.dismiss) private var dismiss

    @State private var enteredPIN: String = ""
    #if targetEnvironment(simulator)
    @State private var manualHost: String = "127.0.0.1"
    #else
    @State private var manualHost: String = ""
    #endif
    @State private var manualPort: String = "\(ChocliftDefaults.defaultTCPPort)"
    @State private var showManualIPFields: Bool = false

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
                        disconnectedStateCard
                        #if targetEnvironment(simulator)
                        quickLocalhostButton
                        #endif
                        bluetoothMacsSection
                        discoveredMacsSection
                        savedMacsSection
                        manualConnectSection
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
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
                if err != nil {
                    CompanionFeedbackHaptics.notify(enabled: client.profile.settings.hapticFeedbackEnabled, kind: .error)
                    enteredPIN = ""
                }
            } else {
                enteredPIN = ""
            }
        }
    }

    // MARK: - 6-Digit Watch PIN Keypad (Readable & Tap-Friendly)

    private func watchPINEntryCard(macName: String, errorMessage: String?) -> some View {
        let isVerifying = (enteredPIN.count == 6 && errorMessage == nil)

        return VStack(spacing: 8) {
            VStack(spacing: 4) {
                Text(L10n.tr("输入 \(macName) 配对码", "PIN on \(macName)", language: lang))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let link = client.activeLink {
                    ChocLinkBadge(link: link, language: lang, palette: palette)
                }
            }

            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { idx in
                    let digit: String = {
                        guard idx < enteredPIN.count else { return "•" }
                        let strIdx = enteredPIN.index(enteredPIN.startIndex, offsetBy: idx)
                        return String(enteredPIN[strIdx])
                    }()
                    let isFilled = idx < enteredPIN.count
                    let isCurrent = (idx == enteredPIN.count && errorMessage == nil)

                    Text(digit)
                        .font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundStyle(isFilled ? palette.primaryText : palette.secondaryText.opacity(0.45))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(
                                    errorMessage != nil
                                        ? palette.accentRuby
                                        : (isCurrent ? palette.accentGold : palette.subtleCardStroke),
                                    lineWidth: (isCurrent || errorMessage != nil) ? 1.5 : 0.8
                                )
                        )
                }
            }

            if let errorMessage {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(palette.accentRuby)
                    Text(errorMessage)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.accentRuby.opacity(0.20), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.accentRuby.opacity(0.65), lineWidth: 1)
                )
            } else if isVerifying {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                        .tint(palette.accentGold)
                    Text(L10n.tr("正在验证…", "Verifying PIN…", language: lang))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }

            let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "CLR", "0", "⌫"]
            let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        handlePINKey(key)
                    } label: {
                        Group {
                            if key == "⌫" {
                                Image(systemName: "delete.left.fill")
                                    .font(.system(size: 14, weight: .bold))
                            } else {
                                Text(key)
                                    .font(.system(size: key == "CLR" ? 11.5 : 16, weight: .bold, design: .rounded))
                            }
                        }
                        .foregroundStyle(key == "CLR" ? palette.secondaryText : palette.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(palette.subtleCardStroke, lineWidth: 0.8)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isVerifying)
                    .opacity(isVerifying ? 0.55 : 1.0)
                }
            }

            Button {
                enteredPIN = ""
                client.disconnect()
            } label: {
                Text(L10n.tr("取消配对", "Cancel", language: lang))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(palette.tileFillTop.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(9)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
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
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(palette.statusConnected)
                    .frame(width: 8, height: 8)
                Text(macName)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            ChocLinkBadge(link: link, language: lang, palette: palette, prominent: true)

            if !client.isMacAccessibilityGranted {
                Text(L10n.tr("请在 Mac 开启辅助功能权限以支持窗口与表情控制。", "Grant Accessibility on Mac for window & emoji actions.", language: lang))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.accentGold)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(role: .destructive) {
                client.disconnect()
            } label: {
                Text(L10n.tr("断开连接", "Disconnect", language: lang))
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.bordered)
            .tint(palette.accentRuby)
        }
        .padding(11)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(palette.statusConnected.opacity(0.4), lineWidth: 1)
        )
    }

    private func connectingCard(targetName: String) -> some View {
        VStack(spacing: 9) {
            ProgressView()
                .tint(palette.accentGold)

            Text(L10n.tr("正在连接 \(targetName)…", "Connecting \(targetName)…", language: lang))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .multilineTextAlignment(.center)

            if let link = client.activeLink {
                ChocLinkBadge(link: link, language: lang, palette: palette)
            }

            Button {
                client.disconnect()
            } label: {
                Text(L10n.tr("取消", "Cancel", language: lang))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(palette.accentGold.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: - Failed / Unpaired State Banner (No spinner on failure)

    @ViewBuilder
    private var disconnectedStateCard: some View {
        if let issue = client.lastConnectionIssue, !issue.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.accentRuby)
                    Text(L10n.tr("连接未成功", "Connection Failed", language: lang))
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                }

                Text(issue)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let saved = client.savedMacs.first, client.canReconnectSavedMac(saved) {
                    Button {
                        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                        client.reconnectSavedMac(saved)
                    } label: {
                        Label(L10n.tr("重试连接", "Retry", language: lang), systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .background(palette.accentGold, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.accentRuby.opacity(0.75), lineWidth: 1.2)
            )
        } else if client.savedMacs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("首次配对 Mac", "Pair Your Mac", language: lang))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                Text(L10n.tr("选择下方蓝牙或 Wi-Fi Mac，输入 Mac 上的 6 位配对码。", "Tap a Bluetooth or Wi-Fi Mac below and enter its 6-digit PIN.", language: lang))
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
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
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                Text(L10n.tr("直连本机 127.0.0.1", "Connect 127.0.0.1", language: lang))
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(palette.accentGold, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bluetooth & Wi-Fi Discovery Sections

    private var bluetoothMacsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Label(L10n.tr("蓝牙连接 (BLE)", "Bluetooth LE", language: lang), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                Spacer(minLength: 2)
                if client.bluetoothAvailability.isProblemState {
                    Text(client.bluetoothAvailability.shortStatus(in: lang))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }

            if let guidance = client.bluetoothAvailability.detailGuidance(in: lang) {
                Text(guidance)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if client.discoveredBluetoothMacs.isEmpty {
                Text(
                    client.isBluetoothPoweredOn
                        ? L10n.tr("正在搜索附近蓝牙广播中的 Mac…", "Scanning nearby Bluetooth LE Macs…", language: lang)
                        : L10n.tr("真机开启蓝牙可直接配对（模拟器请用 127.0.0.1）。", "Enable Bluetooth on Watch hardware (use 127.0.0.1 in Simulator).", language: lang)
                )
                .font(.system(size: 11.5))
                .foregroundStyle(palette.secondaryText)
            } else {
                ForEach(client.discoveredBluetoothMacs) { host in
                    Button {
                        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                        client.connectBluetooth(to: host)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(palette.statusBluetooth)
                            Text(host.name)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 42)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var discoveredMacsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L10n.tr("局域网 (Wi-Fi)", "Wi-Fi Macs", language: lang), systemImage: "wifi")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(palette.primaryText)

            if client.discoveredMacs.isEmpty {
                Text(L10n.tr("暂未在同一 Wi-Fi 发现 Mac；也可展开下方输入局域网 IP。", "No Wi-Fi Macs detected yet; you can also enter your Mac's LAN IP below.", language: lang))
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.secondaryText)
            } else {
                ForEach(client.discoveredMacs) { host in
                    Button {
                        CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                        client.connect(to: host)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(palette.accentGold)
                            Text(host.name)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(palette.secondaryText)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 42)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    // MARK: - Saved Macs (Safe Tap Targets)

    @ViewBuilder
    private var savedMacsSection: some View {
        if !client.savedMacs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("已配对的 Mac", "Paired Macs", language: lang))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)

                ForEach(client.savedMacs) { saved in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Image(systemName: "laptopcomputer")
                                .font(.caption.bold())
                                .foregroundStyle(palette.accentGold)
                            Text(saved.macName)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 6) {
                            if client.canReconnectSavedMac(saved) {
                                Button {
                                    CompanionFeedbackHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, intensity: .medium)
                                    client.reconnectSavedMac(saved)
                                } label: {
                                    Label(L10n.tr("重连", "Reconnect", language: lang), systemImage: "arrow.clockwise")
                                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                        .foregroundStyle(.black)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                        .background(palette.accentGold, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }

                            Button(role: .destructive) {
                                client.forgetSavedMac(macID: saved.macID)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.accentRuby)
                                    .frame(width: 38, height: 36)
                                    .background(palette.accentRuby.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(9)
                    .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
            .padding(10)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
        }
    }

    // MARK: - Collapsible Manual IP Connect

    private var manualConnectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showManualIPFields.toggle()
                }
            } label: {
                HStack {
                    Label(L10n.tr("手动 IP 连接", "Manual IP & Port", language: lang), systemImage: "network")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    Image(systemName: showManualIPFields ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(minHeight: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showManualIPFields {
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
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 38)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accentGold)
                .disabled(manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }
}
