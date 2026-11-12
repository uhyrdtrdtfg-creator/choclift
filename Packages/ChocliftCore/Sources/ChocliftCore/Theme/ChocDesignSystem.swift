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
            (a, r, g, b) = (255, 68, 34, 18)
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

// MARK: - Chocolate Theme Palette

public struct ChocPalette: Sendable {
    public let backgroundTop: Color
    public let backgroundBottom: Color
    public let barSurface: Color
    public let tileFillTop: Color
    public let tileFillBottom: Color
    public let tileBorderHighlight: Color
    public let primaryText: Color
    public let secondaryText: Color
    public let accentGold: Color
    public let accentRuby: Color

    public static func forTheme(_ theme: ChocTheme) -> ChocPalette {
        switch theme {
        case .darkChocolate:
            return ChocPalette(
                backgroundTop: Color(hex: "#231007"),
                backgroundBottom: Color(hex: "#140803"),
                barSurface: Color(hex: "#2E160A"),
                tileFillTop: Color(hex: "#4A2513"),
                tileFillBottom: Color(hex: "#33180B"),
                tileBorderHighlight: Color(hex: "#784226"),
                primaryText: Color(hex: "#FFF7EE"),
                secondaryText: Color(hex: "#CFA987"),
                accentGold: Color(hex: "#F0AE43"),
                accentRuby: Color(hex: "#D63230")
            )
        case .milkChocolate:
            return ChocPalette(
                backgroundTop: Color(hex: "#3B1E10"),
                backgroundBottom: Color(hex: "#241108"),
                barSurface: Color(hex: "#4C2816"),
                tileFillTop: Color(hex: "#6B3A21"),
                tileFillBottom: Color(hex: "#512A16"),
                tileBorderHighlight: Color(hex: "#9B5C3B"),
                primaryText: Color(hex: "#FFF9F2"),
                secondaryText: Color(hex: "#E5C3A6"),
                accentGold: Color(hex: "#F5BD58"),
                accentRuby: Color(hex: "#E0433E")
            )
        case .rubyBerry:
            return ChocPalette(
                backgroundTop: Color(hex: "#2D0E18"),
                backgroundBottom: Color(hex: "#18060C"),
                barSurface: Color(hex: "#3D1522"),
                tileFillTop: Color(hex: "#5B2134"),
                tileFillBottom: Color(hex: "#401523"),
                tileBorderHighlight: Color(hex: "#8F3D58"),
                primaryText: Color(hex: "#FFF4F7"),
                secondaryText: Color(hex: "#DDA4B6"),
                accentGold: Color(hex: "#F3B562"),
                accentRuby: Color(hex: "#FF4D6D")
            )
        case .matchaWhite:
            return ChocPalette(
                backgroundTop: Color(hex: "#19261B"),
                backgroundBottom: Color(hex: "#0E1710"),
                barSurface: Color(hex: "#223425"),
                tileFillTop: Color(hex: "#314B36"),
                tileFillBottom: Color(hex: "#233727"),
                tileBorderHighlight: Color(hex: "#577F5E"),
                primaryText: Color(hex: "#F6FFF7"),
                secondaryText: Color(hex: "#B4D2B9"),
                accentGold: Color(hex: "#E8C56B"),
                accentRuby: Color(hex: "#52B788")
            )
        case .midnightObsidian:
            return ChocPalette(
                backgroundTop: Color(hex: "#18181D"),
                backgroundBottom: Color(hex: "#0D0D11"),
                barSurface: Color(hex: "#22222A"),
                tileFillTop: Color(hex: "#30303C"),
                tileFillBottom: Color(hex: "#23232D"),
                tileBorderHighlight: Color(hex: "#4C4C5E"),
                primaryText: Color(hex: "#F7F7FA"),
                secondaryText: Color(hex: "#A5A5B8"),
                accentGold: Color(hex: "#F0AE43"),
                accentRuby: Color(hex: "#E05252")
            )
        }
    }
}

// MARK: - Preset Tile Swatches

public enum ChocSwatch {
    public static let tileColors: [String] = [
        "#6C3EB8", "#C93B2B", "#D97706", "#0D9488",
        "#2563EB", "#DB2777", "#4F46E5", "#16A34A",
        "#5C2D16", "#24292F", "#9333EA", "#EA580C"
    ]
}

// MARK: - Cross-Platform PNG Data Image Helper

public struct DataImageView: View {
    public let pngData: Data?
    public let fallbackSymbol: String
    public let tint: Color

    public init(pngData: Data?, fallbackSymbol: String = "app.fill", tint: Color = .white) {
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
                .padding(8)
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

// MARK: - Brand Icon ("c" Chocolate Wrapper Logo)

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
                        colors: [Color(hex: "#6B3418"), Color(hex: "#381808")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Color(hex: "#9A5633").opacity(0.65), lineWidth: max(1, size * 0.03))
                )

            // Gold & crimson wrapper ribbon accent at bottom-left
            VStack {
                Spacer()
                HStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#D62828"), Color(hex: "#F4A261")],
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
                .foregroundStyle(Color(hex: "#FFF3E2"))
                .shadow(color: .black.opacity(0.4), radius: size * 0.05, x: 0, y: size * 0.03)
                .offset(y: -size * 0.04)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Molded Chocolate Tile Card

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
            let corner = max(side < 64 ? 11 : 14, side * 0.22)

            if let item {
                filledTile(for: item, side: side, corner: corner)
            } else {
                emptyMoldedSquare(corner: corner)
            }
        }
    }

    @ViewBuilder
    private func filledTile(for item: BarItem, side: CGFloat, corner: CGFloat) -> some View {
        switch item.kind {
        case .macApp(_, let appName, _, let fallbackSymbol):
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [palette.tileFillTop, palette.tileFillBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(
                                isFrontmostApp ? palette.accentGold : palette.tileBorderHighlight.opacity(0.55),
                                lineWidth: isFrontmostApp ? 2.2 : 1.1
                            )
                    )
                    .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 4)

                VStack(spacing: compact ? 3 : 5) {
                    DataImageView(
                        pngData: iconData,
                        fallbackSymbol: fallbackSymbol,
                        tint: palette.primaryText
                    )
                    .frame(width: side * 0.50, height: side * 0.50)
                    .shadow(color: .black.opacity(0.28), radius: 3, x: 0, y: 2)

                    Text(appName)
                        .font(.system(size: max(10, side * 0.115), weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }

                if isFrontmostApp {
                    VStack {
                        Spacer()
                        Circle()
                            .fill(palette.accentGold)
                            .frame(width: 6, height: 6)
                            .shadow(color: palette.accentGold.opacity(0.9), radius: 4)
                            .padding(.bottom, 5)
                    }
                }
            }

        case .shortcut(let shortcutName, let emoji, let backgroundHex):
            let base = Color(hex: backgroundHex)
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [base.opacity(0.96), base.opacity(0.68)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(.white.opacity(0.24), lineWidth: 1.1)
                    )
                    .shadow(color: base.opacity(0.36), radius: 6, x: 0, y: 4)

                VStack(spacing: compact ? 3 : 5) {
                    HStack(spacing: 4) {
                        Text(emoji)
                            .font(.system(size: side * 0.30))
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.system(size: max(9, side * 0.11), weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Text(shortcutName.uppercased())
                        .font(.system(size: max(9.5, side * 0.105), weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 6)
                }
            }

        case .website(let url, let title, let emoji, let backgroundHex, let switchExistingTab):
            let base = Color(hex: backgroundHex)
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [base.opacity(0.95), base.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(.white.opacity(0.22), lineWidth: 1.1)
                    )
                    .shadow(color: base.opacity(0.32), radius: 6, x: 0, y: 4)

                VStack(spacing: compact ? 3 : 5) {
                    ZStack(alignment: .topTrailing) {
                        Text(emoji.isEmpty ? "🌐" : emoji)
                            .font(.system(size: side * 0.30))
                            .frame(width: side * 0.44, height: side * 0.38)
                        Image(systemName: switchExistingTab ? "arrow.triangle.2.circlepath" : "safari.fill")
                            .font(.system(size: max(8, side * 0.095), weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .offset(x: 6, y: -2)
                    }

                    Text(title.isEmpty ? cleanHost(from: url) : title)
                        .font(.system(size: max(10, side * 0.11), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
            }

        case .systemAction(let action, let customTitle, let customHex):
            let base = Color(hex: customHex ?? action.accentHex)
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [palette.tileFillTop, base.opacity(0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(base.opacity(0.7), lineWidth: 1.2)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)

                VStack(spacing: compact ? 4 : 6) {
                    Image(systemName: action.sfSymbol)
                        .font(.system(size: side * 0.27, weight: .semibold))
                        .foregroundStyle(.white)
                    let defaultActionLabel = side < 64 ? action.compactTitle(in: language) : action.title(in: language)
                    Text((customTitle?.isEmpty == false ? customTitle! : defaultActionLabel))
                        .font(.system(size: max(9, side * 0.105), weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(side < 64 ? 1 : 2)
                        .padding(.horizontal, 5)
                }
            }
        }
    }

    private func emptyMoldedSquare(corner: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.tileFillBottom.opacity(0.55), palette.backgroundBottom.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            palette.tileBorderHighlight.opacity(0.28),
                            style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                        )
                )

            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.secondaryText.opacity(0.55))
        }
    }

    private func cleanHost(from rawURL: String) -> String {
        if let url = URL(string: rawURL), let host = url.host() {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return rawURL
    }
}
