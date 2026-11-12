import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS) || os(watchOS)
import UIKit
#endif

// MARK: - Hex Color Extension

public extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 255, 255, 255)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}

// MARK: - Bright & Lively Theme Palette

public struct ChocPalette: Sendable {
    public static let coreBackgroundTopHex = "#F7F4FF"
    public static let coreBackgroundBottomHex = "#FFF8F2"
    public static let coreSurfaceHex = "#FFFFFF"
    public static let coreTileTopHex = "#FFFFFF"
    public static let coreTileBottomHex = "#F5F1FF"
    public static let coreTileBorderHex = "#E0D7FA"
    public static let corePrimaryTextHex = "#241C33"
    public static let coreSecondaryTextHex = "#6E6480"
    public static let coreAccentHex = "#7C5CFF"
    public static let coreAccentEmphasisHex = "#FF7A59"
    public static let coreStatusConnectedHex = "#12B981"
    public static let coreStatusBluetoothHex = "#2F80ED"
    public static let coreStatusFailureHex = "#E5484D"

    public let backgroundTop: Color
    public let backgroundBottom: Color
    public let barSurface: Color
    public let tileFillTop: Color
    public let tileFillBottom: Color
    public let tileBorderHighlight: Color
    public let primaryText: Color
    public let secondaryText: Color
    public let accent: Color
    public let accentEmphasis: Color
    public let accentForeground: Color
    public let emphasisForeground: Color

    // Semantic design tokens shared across the bright light system
    public var statusConnected: Color { Color(hex: Self.coreStatusConnectedHex) }
    public var statusBluetooth: Color { Color(hex: Self.coreStatusBluetoothHex) }
    public var statusFailure: Color { Color(hex: Self.coreStatusFailureHex) }
    public var subtleCardStroke: Color { tileBorderHighlight.opacity(0.92) }

    public static func forTheme(_ theme: ChocTheme) -> ChocPalette {
        switch theme {
        case .darkChocolate:
            // Bright Violet (Default)
            return ChocPalette(
                backgroundTop: Color(hex: "#F7F4FF"),
                backgroundBottom: Color(hex: "#FFF8F2"),
                barSurface: Color(hex: "#FFFFFF"),
                tileFillTop: Color(hex: "#FFFFFF"),
                tileFillBottom: Color(hex: "#F5F1FF"),
                tileBorderHighlight: Color(hex: "#E0D7FA"),
                primaryText: Color(hex: "#241C33"),
                secondaryText: Color(hex: "#6E6480"),
                accent: Color(hex: "#7C5CFF"),
                accentEmphasis: Color(hex: "#FF7A59"),
                accentForeground: Color(hex: "#FFFFFF"),
                emphasisForeground: Color(hex: "#FFFFFF")
            )
        case .milkChocolate:
            // Sunny Coral
            return ChocPalette(
                backgroundTop: Color(hex: "#FFF5F2"),
                backgroundBottom: Color(hex: "#FFF9F4"),
                barSurface: Color(hex: "#FFFFFF"),
                tileFillTop: Color(hex: "#FFFFFF"),
                tileFillBottom: Color(hex: "#FFF1EC"),
                tileBorderHighlight: Color(hex: "#FAD6CA"),
                primaryText: Color(hex: "#241C33"),
                secondaryText: Color(hex: "#6E6480"),
                accent: Color(hex: "#FF7A59"),
                accentEmphasis: Color(hex: "#7C5CFF"),
                accentForeground: Color(hex: "#FFFFFF"),
                emphasisForeground: Color(hex: "#FFFFFF")
            )
        case .rubyBerry:
            // Clear Sky
            return ChocPalette(
                backgroundTop: Color(hex: "#F2F8FF"),
                backgroundBottom: Color(hex: "#FFF9F3"),
                barSurface: Color(hex: "#FFFFFF"),
                tileFillTop: Color(hex: "#FFFFFF"),
                tileFillBottom: Color(hex: "#EDF6FF"),
                tileBorderHighlight: Color(hex: "#CCE2FA"),
                primaryText: Color(hex: "#241C33"),
                secondaryText: Color(hex: "#6E6480"),
                accent: Color(hex: "#2F80ED"),
                accentEmphasis: Color(hex: "#FF7A59"),
                accentForeground: Color(hex: "#FFFFFF"),
                emphasisForeground: Color(hex: "#FFFFFF")
            )
        case .matchaWhite:
            // Fresh Lime
            return ChocPalette(
                backgroundTop: Color(hex: "#F4FCF3"),
                backgroundBottom: Color(hex: "#FCFFF5"),
                barSurface: Color(hex: "#FFFFFF"),
                tileFillTop: Color(hex: "#FFFFFF"),
                tileFillBottom: Color(hex: "#ECFAEE"),
                tileBorderHighlight: Color(hex: "#C6ECCB"),
                primaryText: Color(hex: "#241C33"),
                secondaryText: Color(hex: "#6E6480"),
                accent: Color(hex: "#22C55E"),
                accentEmphasis: Color(hex: "#7C5CFF"),
                accentForeground: Color(hex: "#FFFFFF"),
                emphasisForeground: Color(hex: "#FFFFFF")
            )
        case .midnightObsidian:
            // Warm Amber
            return ChocPalette(
                backgroundTop: Color(hex: "#FFFBF0"),
                backgroundBottom: Color(hex: "#FFF6F0"),
                barSurface: Color(hex: "#FFFFFF"),
                tileFillTop: Color(hex: "#FFFFFF"),
                tileFillBottom: Color(hex: "#FFF5DC"),
                tileBorderHighlight: Color(hex: "#F8DFA1"),
                primaryText: Color(hex: "#241C33"),
                secondaryText: Color(hex: "#6E6480"),
                accent: Color(hex: "#F97316"),
                accentEmphasis: Color(hex: "#7C5CFF"),
                accentForeground: Color(hex: "#FFFFFF"),
                emphasisForeground: Color(hex: "#FFFFFF")
            )
        }
    }
}

// MARK: - Preset Tile Swatches

public enum ChocSwatch {
    public static let tileColors: [String] = [
        "#F3EEFF", "#FFF1EC", "#EDF6FF", "#ECFAEE",
        "#FFF6E3", "#EEF2FF", "#ECFAFE", "#F7F0FF",
        "#FFF3E8", "#EFFAF5", "#F2F5FF", "#FFFFFF"
    ]

    public static func resolvedTileColor(hex: String, fallbackHex: String = "#F3EEFF") -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            return Color(hex: fallbackHex)
        }
        let r = Double((value >> 16) & 0xFF)
        let g = Double((value >> 8) & 0xFF)
        let b = Double(value & 0xFF)
        let perceivedBrightness = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        if perceivedBrightness < 0.80 {
            return Color(hex: fallbackHex)
        }
        return Color(hex: hex)
    }
}

// MARK: - Companion Connection Visual Semantics

public enum ChocConnectionVisualState: Equatable, Sendable {
    case connected(macName: String, link: CompanionLinkKind)
    case connecting(targetName: String, link: CompanionLinkKind?)
    case awaitingPIN(macName: String, link: CompanionLinkKind?, errorMessage: String?)
    case failed(reason: String, savedMacName: String?)
    case pairedStandby(macName: String, isPausedForLaunch: Bool)
    case unpaired

    @MainActor
    public static func resolve(from client: CompanionClientEngine) -> ChocConnectionVisualState {
        let lang = client.profile.settings.language
        switch client.connectionState {
        case .connected(_, let macName):
            return .connected(macName: macName, link: client.activeLink ?? .wifi)
        case .connecting(let targetName):
            return .connecting(targetName: targetName, link: client.activeLink)
        case .awaitingPIN(_, let macName, let errorMessage):
            return .awaitingPIN(macName: macName, link: client.activeLink, errorMessage: errorMessage)
        case .disconnected:
            if let issue = client.lastConnectionIssue, !issue.isEmpty {
                return .failed(reason: issue, savedMacName: client.savedMacs.first?.macName)
            }
            if client.bluetoothAvailability.isProblemState && client.discoveredMacs.isEmpty {
                let reason = client.bluetoothAvailability.detailGuidance(in: lang)
                    ?? client.bluetoothAvailability.shortStatus(in: lang)
                return .failed(reason: reason, savedMacName: client.savedMacs.first?.macName)
            }
            if let primarySaved = client.savedMacs.first {
                return .pairedStandby(
                    macName: primarySaved.macName,
                    isPausedForLaunch: client.isAutoConnectSuppressedForCurrentLaunch
                )
            }
            return .unpaired
        }
    }

    /// True ONLY during an active connection handshake — failures and empty states never spin.
    public var showsProgressSpinner: Bool {
        if case .connecting = self { return true }
        return false
    }

    public var isFailure: Bool {
        switch self {
        case .failed:
            return true
        case .awaitingPIN(_, _, let err):
            return err != nil
        default:
            return false
        }
    }

    public var sfSymbol: String {
        switch self {
        case .connected(_, let link):
            return link.sfSymbol
        case .connecting(_, let link):
            return link?.sfSymbol ?? "dot.radiowaves.left.and.right"
        case .awaitingPIN(_, _, let err):
            return err != nil ? "exclamationmark.triangle.fill" : "key.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .pairedStandby(_, let paused):
            return paused ? "pause.circle.fill" : "arrow.triangle.2.circlepath.circle.fill"
        case .unpaired:
            return "link.badge.plus"
        }
    }

    public func tintColor(in palette: ChocPalette) -> Color {
        switch self {
        case .connected(_, let link):
            return link == .bluetooth ? palette.statusBluetooth : palette.statusConnected
        case .connecting(_, let link):
            return link == .bluetooth ? palette.statusBluetooth : palette.accent
        case .awaitingPIN(_, _, let err):
            return err != nil ? palette.statusFailure : palette.accent
        case .failed:
            return palette.statusFailure
        case .pairedStandby:
            return palette.secondaryText
        case .unpaired:
            return palette.secondaryText
        }
    }

    public func railShortBadge(in lang: AppLanguage) -> String {
        switch self {
        case .connected(_, let link):
            return link.shortLabel(in: lang)
        case .connecting:
            return L10n.tr("连接", "LINK", language: lang)
        case .awaitingPIN(_, _, let err):
            return err != nil ? L10n.tr("重试", "ERR", language: lang) : "PIN"
        case .failed:
            return L10n.tr("失败", "FAIL", language: lang)
        case .pairedStandby:
            return L10n.tr("待机", "IDLE", language: lang)
        case .unpaired:
            return L10n.tr("配对", "PAIR", language: lang)
        }
    }

    public func compactPillLabel(in lang: AppLanguage) -> String {
        switch self {
        case .connected(let macName, let link):
            return "\(macName) · \(link.shortLabel(in: lang))"
        case .connecting(let target, let link):
            if let link {
                return L10n.tr("连接 \(target) · \(link.shortLabel(in: lang))", "Linking \(target) · \(link.shortLabel(in: lang))", language: lang)
            }
            return L10n.tr("正在连接 \(target)…", "Connecting \(target)…", language: lang)
        case .awaitingPIN(let macName, _, let err):
            if err != nil {
                return L10n.tr("配对码有误 · 点击重输", "PIN Failed · Retry", language: lang)
            }
            return L10n.tr("输入 \(macName) 配对码", "Enter PIN for \(macName)", language: lang)
        case .failed:
            return L10n.tr("连接失败 · 点击重试", "Connection Failed · Retry", language: lang)
        case .pairedStandby(let macName, let paused):
            return paused
                ? L10n.tr("\(macName) · 已暂停", "\(macName) · Paused", language: lang)
                : L10n.tr("\(macName) · 待重连", "\(macName) · Paired", language: lang)
        case .unpaired:
            return L10n.tr("配对 Mac", "Pair Mac", language: lang)
        }
    }

    public func watchToolbarLabel(in lang: AppLanguage) -> String {
        switch self {
        case .connected(_, let link):
            return link.shortLabel(in: lang)
        case .connecting:
            return L10n.tr("连接中", "Linking", language: lang)
        case .awaitingPIN(_, _, let err):
            return err != nil ? L10n.tr("重输码", "Retry PIN", language: lang) : "PIN"
        case .failed:
            return L10n.tr("失败", "Failed", language: lang)
        case .pairedStandby:
            return L10n.tr("已配对", "Paired", language: lang)
        case .unpaired:
            return L10n.tr("配对", "Pair", language: lang)
        }
    }

    public func bannerTitle(in lang: AppLanguage) -> String {
        switch self {
        case .connected(let macName, let link):
            return "\(macName) · \(link.displayName(in: lang))"
        case .connecting(let target, let link):
            let suffix = link.map { " (\($0.shortLabel(in: lang)))" } ?? ""
            return L10n.tr("正在连接 \(target)\(suffix)…", "Connecting to \(target)\(suffix)…", language: lang)
        case .awaitingPIN(let macName, _, let err):
            if err != nil {
                return L10n.tr("配对验证未通过", "PIN Verification Failed", language: lang)
            }
            return L10n.tr("需要输入 \(macName) 上的 6 位配对码", "Enter 6-Digit PIN Shown on \(macName)", language: lang)
        case .failed:
            return L10n.tr("未能连接到 Mac", "Connection Failed", language: lang)
        case .pairedStandby(let macName, let paused):
            return paused
                ? L10n.tr("已手动断开 \(macName)", "Disconnected from \(macName)", language: lang)
                : L10n.tr("已配对 \(macName) · 等待上线", "Paired with \(macName) · Waiting", language: lang)
        case .unpaired:
            return L10n.tr("尚未配对 Mac", "No Mac Paired Yet", language: lang)
        }
    }

    public func bannerSubtitle(in lang: AppLanguage) -> String? {
        switch self {
        case .connected:
            return nil
        case .connecting(_, let link):
            if let link {
                return L10n.tr("正在通过 \(link.displayName(in: lang)) 握手…", "Handshaking over \(link.displayName(in: lang))…", language: lang)
            }
            return nil
        case .awaitingPIN(_, _, let err):
            return err ?? L10n.tr("点此打开数字键盘完成配对", "Tap to open keypad and finish pairing", language: lang)
        case .failed(let reason, _):
            return reason
        case .pairedStandby(_, let paused):
            return paused
                ? L10n.tr("点此立即重连，或下次打开自动恢复", "Tap to reconnect now", language: lang)
                : L10n.tr("开启 Mac 端 Choclift 后将通过 Wi-Fi 或蓝牙自动重连", "Auto-reconnects via Wi-Fi or Bluetooth when Mac is nearby", language: lang)
        case .unpaired:
            return L10n.tr("打开 Mac 端 Choclift，点此通过 Wi-Fi 或蓝牙配对", "Open Choclift on Mac and tap here to pair via Wi-Fi or BLE", language: lang)
        }
    }
}

// MARK: - Quiet Transport Link Badge

public struct ChocLinkBadge: View {
    public let link: CompanionLinkKind
    public let language: AppLanguage
    public let palette: ChocPalette
    public var prominent: Bool

    public init(
        link: CompanionLinkKind,
        language: AppLanguage = .system,
        palette: ChocPalette,
        prominent: Bool = false
    ) {
        self.link = link
        self.language = language
        self.palette = palette
        self.prominent = prominent
    }

    private var tint: Color {
        link == .bluetooth ? palette.statusBluetooth : palette.statusConnected
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: link.sfSymbol)
                .font(.system(size: prominent ? 11 : 9.5, weight: .bold))
            Text(prominent ? link.displayName(in: language) : link.shortLabel(in: language))
                .font(.system(size: prominent ? 11.5 : 10.5, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, prominent ? 9 : 7)
        .padding(.vertical, prominent ? 4 : 2.5)
        .background(tint.opacity(0.15), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(tint.opacity(0.32), lineWidth: 0.8)
        )
    }
}

// MARK: - Cross-Platform PNG Data Image Helper

public struct DataImageView: View {
    public let pngData: Data?
    public let fallbackSymbol: String
    public let tint: Color

    public init(pngData: Data?, fallbackSymbol: String = "app.fill", tint: Color = Color(hex: "#241C33")) {
        self.pngData = pngData
        self.fallbackSymbol = fallbackSymbol
        self.tint = tint
    }

    public var body: some View {
        if let pngData, let image = makeSwiftUIImage(from: pngData) {
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: fallbackSymbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
                .padding(7)
        }
    }

    private func makeSwiftUIImage(from data: Data) -> Image? {
        #if os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #elseif os(iOS) || os(watchOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #else
        return nil
        #endif
    }
}

// MARK: - Brand Icon ("c" Vivid Violet & Coral Mark)

public struct ChocliftBrandIconView: View {
    public var size: CGFloat

    public init(size: CGFloat = 44) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#7C5CFF"), Color(hex: "#6747F0")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Color(hex: "#FFFFFF").opacity(0.34), lineWidth: max(1, size * 0.03))
                )

            // Vivid coral accent ribbon at bottom-left
            VStack {
                Spacer()
                HStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#FF7A59"), Color(hex: "#FF9D7E")],
                                startPoint: .bottomLeading,
                                endPoint: .topTrailing
                            )
                        )
                        .frame(width: size * 0.72, height: size * 0.22)
                        .rotationEffect(.degrees(16))
                        .offset(x: -size * 0.08, y: size * 0.06)
                    Spacer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))

            Text("c")
                .font(.system(size: size * 0.62, weight: .black, design: .serif))
                .italic()
                .foregroundStyle(Color(hex: "#FFFFFF"))
                .shadow(color: Color(hex: "#241C33").opacity(0.18), radius: size * 0.04, x: 0, y: size * 0.02)
                .offset(y: -size * 0.04)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: "#7C5CFF").opacity(0.22), radius: size * 0.14, x: 0, y: size * 0.06)
    }
}

// MARK: - Bright Surface Tile Card

public struct ChocBarTileCard: View {
    public let item: BarItem?
    public let iconData: Data?
    public let isFrontmostApp: Bool
    public let palette: ChocPalette
    public let language: AppLanguage
    public let compact: Bool

    public init(
        item: BarItem?,
        iconData: Data?,
        isFrontmostApp: Bool = false,
        palette: ChocPalette,
        language: AppLanguage = .system,
        compact: Bool = false
    ) {
        self.item = item
        self.iconData = iconData
        self.isFrontmostApp = isFrontmostApp
        self.palette = palette
        self.language = language
        self.compact = compact
    }

    public var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let corner = max(side < 68 ? 13 : 16, side * 0.22)

            Group {
                if let item {
                    filledTile(for: item, side: side, corner: corner)
                } else {
                    emptyMoldedSquare(side: side, corner: corner)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
    }

    @ViewBuilder
    private func filledTile(for item: BarItem, side: CGFloat, corner: CGFloat) -> some View {
        let isMicro = side < 68

        switch item.kind {
        case .macApp(_, let appName, _, let fallbackSymbol):
            ZStack {
                moldedBaseShape(
                    corner: corner,
                    top: palette.tileFillTop,
                    bottom: palette.tileFillBottom,
                    borderColor: isFrontmostApp ? palette.accent : palette.tileBorderHighlight,
                    borderWidth: isFrontmostApp ? 2.0 : 1.15,
                    shadowColor: palette.primaryText.opacity(0.06)
                )

                VStack(spacing: isMicro ? 3 : (compact ? 4 : 6)) {
                    DataImageView(
                        pngData: iconData,
                        fallbackSymbol: fallbackSymbol,
                        tint: palette.accent
                    )
                    .frame(width: side * (isMicro ? 0.44 : 0.48), height: side * (isMicro ? 0.44 : 0.48))

                    Text(appName)
                        .font(.system(size: max(11, side * 0.12), weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, isMicro ? 5 : 8)
                }

                if isFrontmostApp {
                    VStack {
                        HStack {
                            Spacer()
                            Circle()
                                .fill(palette.accent)
                                .frame(width: isMicro ? 5.5 : 7, height: isMicro ? 5.5 : 7)
                                .shadow(color: palette.accent.opacity(0.45), radius: 3)
                                .padding(isMicro ? 6 : 8)
                        }
                        Spacer()
                    }
                }
            }

        case .shortcut(let shortcutName, let emoji, let backgroundHex):
            let base = ChocSwatch.resolvedTileColor(hex: backgroundHex, fallbackHex: "#F3EEFF")
            ZStack {
                moldedBaseShape(
                    corner: corner,
                    top: palette.tileFillTop,
                    bottom: base,
                    borderColor: palette.tileBorderHighlight,
                    borderWidth: 1.15,
                    shadowColor: palette.primaryText.opacity(0.06)
                )

                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "bolt.fill")
                            .font(.system(size: max(8.5, side * 0.095), weight: .bold))
                            .foregroundStyle(palette.accentEmphasis)
                            .padding(isMicro ? 5 : 7)
                    }
                    Spacer()
                }

                VStack(spacing: isMicro ? 2 : (compact ? 3 : 5)) {
                    Text(emoji.isEmpty ? "⚡️" : emoji)
                        .font(.system(size: side * (isMicro ? 0.30 : 0.32)))

                    Text(shortcutName)
                        .font(.system(size: max(10.5, side * 0.112), weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(isMicro ? 1 : 2)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, isMicro ? 5 : 7)
                }
            }

        case .website(let url, let title, let emoji, let backgroundHex, let switchExistingTab):
            let base = ChocSwatch.resolvedTileColor(hex: backgroundHex, fallbackHex: "#FFF1EC")
            ZStack {
                moldedBaseShape(
                    corner: corner,
                    top: palette.tileFillTop,
                    bottom: base,
                    borderColor: palette.tileBorderHighlight,
                    borderWidth: 1.15,
                    shadowColor: palette.primaryText.opacity(0.06)
                )

                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: switchExistingTab ? "arrow.triangle.2.circlepath" : "safari.fill")
                            .font(.system(size: max(8.5, side * 0.095), weight: .bold))
                            .foregroundStyle(palette.accent)
                            .padding(isMicro ? 5 : 7)
                    }
                    Spacer()
                }

                VStack(spacing: isMicro ? 2 : (compact ? 3 : 5)) {
                    Text(emoji.isEmpty ? "🌐" : emoji)
                        .font(.system(size: side * (isMicro ? 0.30 : 0.32)))

                    Text(title.isEmpty ? cleanHost(from: url) : title)
                        .font(.system(size: max(10.5, side * 0.115), weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, isMicro ? 5 : 7)
                }
            }

        case .systemAction(let action, let customTitle, let customHex):
            let base = ChocSwatch.resolvedTileColor(hex: customHex ?? action.accentHex, fallbackHex: "#EDF6FF")
            ZStack {
                moldedBaseShape(
                    corner: corner,
                    top: palette.tileFillTop,
                    bottom: base,
                    borderColor: palette.tileBorderHighlight,
                    borderWidth: 1.15,
                    shadowColor: palette.primaryText.opacity(0.06)
                )

                VStack(spacing: isMicro ? 3 : (compact ? 4 : 6)) {
                    Image(systemName: action.sfSymbol)
                        .font(.system(size: side * (isMicro ? 0.25 : 0.27), weight: .semibold))
                        .foregroundStyle(palette.accent)

                    let defaultActionLabel = isMicro ? action.compactTitle(in: language) : action.title(in: language)
                    Text((customTitle?.isEmpty == false ? customTitle! : defaultActionLabel))
                        .font(.system(size: max(10.5, side * 0.11), weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(isMicro ? 1 : 2)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, isMicro ? 4 : 6)
                }
            }
        }
    }

    private func moldedBaseShape(
        corner: CGFloat,
        top: Color,
        bottom: Color,
        borderColor: Color,
        borderWidth: CGFloat,
        shadowColor: Color
    ) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [top, bottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
            .shadow(color: shadowColor, radius: 6, x: 0, y: 2)
    }

    private func emptyMoldedSquare(side: CGFloat, corner: CGFloat) -> some View {
        let isMicro = side < 68
        return ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.barSurface.opacity(0.82), palette.tileFillBottom.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            palette.tileBorderHighlight,
                            style: StrokeStyle(lineWidth: 1.25, dash: [5, 4])
                        )
                )

            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: isMicro ? 15 : 17, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.accent)
                    .frame(width: isMicro ? 26 : 32, height: isMicro ? 26 : 32)
                    .background(palette.accent.opacity(0.11), in: Circle())

                if side >= 78 {
                    Text(L10n.tr("添加动作", "Assign", language: language))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private func cleanHost(from rawURL: String) -> String {
        if let url = URL(string: rawURL), let host = url.host() {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return rawURL
    }
}
