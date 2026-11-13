import ChocliftCore
import SwiftUI

// MARK: - 1. Show Desktop One-Tap Pill Button (Existing SystemQuickAction.showDesktop Path)

public struct IOSShowDesktopPillButton: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine, compact: Bool = false) {
        self.client = client
        self.compact = compact
    }

    public var body: some View {
        let key = "show-desktop-pill"
        let isPressed = (pressedKey == key)
        let action = SystemQuickAction.showDesktop
        let labelText = compact ? action.compactTitle(in: lang) : action.title(in: lang)

        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            if client.connectionState.isConnected {
                client.performQuickAction(.showDesktop)
            } else {
                client.lastFeedback = CompanionFeedbackToast(
                    success: false,
                    title: action.title(in: lang),
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: action.sfSymbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.accent)

                Text(labelText)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
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
        .accessibilityIdentifier("ios-show-desktop-button")
        .accessibilityLabel(action.title(in: lang))
    }
}

// MARK: - 2. Show / Hide Finder Desktop Icons Button (Explicitly States Finder Will Restart)

public struct IOSFinderDesktopIconsPillButton: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine, compact: Bool = false) {
        self.client = client
        self.compact = compact
    }

    public var body: some View {
        let key = "finder-desktop-icons-pill"
        let isPressed = (pressedKey == key)
        let areIconsVisible = client.controlStripState.areFinderDesktopIconsVisible
        let primaryTitle = FinderDesktopIconsToggleCopy.actionTitle(
            areIconsVisible: areIconsVisible,
            compact: compact,
            language: lang
        )
        let restartSubtitle = FinderDesktopIconsToggleCopy.restartNotice(in: lang)
        let symbolName = areIconsVisible ? "eye.slash" : "eye"

        Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            client.toggleFinderDesktopIcons()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(areIconsVisible ? palette.accent : palette.accentEmphasis)

                VStack(alignment: .leading, spacing: 0.5) {
                    Text(primaryTitle)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)

                    Text(restartSubtitle)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .frame(minHeight: 34)
            .background(
                isPressed
                    ? palette.tileFillBottom
                    : (areIconsVisible ? palette.tileFillTop.opacity(0.94) : palette.accentEmphasis.opacity(0.14)),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isPressed
                            ? palette.accent
                            : (areIconsVisible ? palette.subtleCardStroke : palette.accentEmphasis.opacity(0.55)),
                        lineWidth: isPressed ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
        .accessibilityIdentifier("ios-finder-desktop-icons-button")
        .accessibilityLabel(
            FinderDesktopIconsToggleCopy.buttonCombinedLabel(
                areIconsVisible: areIconsVisible,
                compact: false,
                language: lang
            )
        )
    }
}

// MARK: - 3. Phone Strip Read-Only Mac Battery + Keep-Awake Reason Row

public struct IOSCompanionStripStatusRow: View {
    @ObservedObject var client: CompanionClientEngine

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var state: ControlStripState { client.controlStripState }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    private var activeAwakeReason: String? {
        guard client.connectionState.isConnected else { return nil }
        return state.awakeReasonLine(in: lang)
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                IOSMacBatteryStripBadge(client: client)

                Spacer(minLength: 4)

                if let reason = activeAwakeReason {
                    IOSAwakeReasonStripLabel(reason: reason, palette: palette)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                IOSMacBatteryStripBadge(client: client)

                if let reason = activeAwakeReason {
                    IOSAwakeReasonStripLabel(reason: reason, palette: palette)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Read-only Mac battery percentage + charging indicator (or `"Power adapter"` on desktop Macs with no battery).
/// Strictly read-only — no button action and no charge-limit slider.
public struct IOSMacBatteryStripBadge: View {
    @ObservedObject var client: CompanionClientEngine

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        let isConnected = client.connectionState.isConnected
        let battery = isConnected ? client.controlStripState.macBattery : nil
        let symbolName = battery?.sfSymbol ?? "laptopcomputer"
        let text: String = {
            if let battery {
                return battery.displayText(in: lang)
            }
            return L10n.tr("Mac 电量 —", "Mac Battery —", language: lang)
        }()
        let iconTint: Color = {
            guard let battery else {
                return palette.secondaryText.opacity(0.75)
            }
            if !battery.hasBattery {
                return palette.accent
            }
            if battery.isCharging {
                return palette.statusConnected
            }
            if let pct = battery.chargePercent, pct <= 20 {
                return palette.statusFailure
            }
            return palette.primaryText
        }()

        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(iconTint)

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(battery != nil ? palette.primaryText : palette.secondaryText.opacity(0.8))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(palette.tileFillBottom.opacity(0.72), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ios-strip-mac-battery")
        .accessibilityLabel(L10n.tr("Mac 电源状态", "Mac Power Status", language: lang))
        .accessibilityValue(text)
    }
}

/// Shown ONLY while Choclift's keep-awake assertion is active on the connected Mac.
public struct IOSAwakeReasonStripLabel: View {
    public let reason: String
    public let palette: ChocPalette

    public init(reason: String, palette: ChocPalette) {
        self.reason = reason
        self.palette = palette
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(palette.accentEmphasis)

            Text(reason)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(palette.accentEmphasis.opacity(0.14), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(palette.accentEmphasis.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ios-strip-awake-reason")
        .accessibilityLabel(reason)
    }
}
