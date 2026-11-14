import ChocliftCore
import SwiftUI

// MARK: - 1. Empty Trash Pill Button (3-Second Second-Tap Confirm — Never Runs on First Tap)

public struct IOSEmptyTrashPillButton: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool
    var onPromptHUD: ((String) -> Void)?

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        compact: Bool = false,
        onPromptHUD: ((String) -> Void)? = nil
    ) {
        self.client = client
        self.compact = compact
        self.onPromptHUD = onPromptHUD
    }

    public var body: some View {
        let key = "round08-empty-trash-pill"
        let isPressed = (pressedKey == key)
        let now = ProcessInfo.processInfo.systemUptime
        let isArmed = client.isMaintenanceActionArmed(.emptyTrash, at: now)
        let baseTitle = Round08MaintenanceAction.emptyTrash.title(compact: compact, in: lang)
        let displayTitle = isArmed
            ? L10n.tr("再点确认", "Tap Again", language: lang)
            : baseTitle

        Button {
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            let outcome = client.tapEmptyTrash(at: ProcessInfo.processInfo.systemUptime)
            switch outcome {
            case .requireSecondTap:
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                onPromptHUD?(Round08MaintenanceAction.emptyTrash.secondTapPrompt(in: lang))
            case .confirmedExecute:
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            case .quietNothingToEject:
                break
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isArmed ? "exclamationmark.triangle.fill" : "trash")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(isArmed ? palette.emphasisForeground : palette.statusFailure)

                Text(displayTitle)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(isArmed ? palette.emphasisForeground : palette.primaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, compact ? 9 : 10)
            .frame(minHeight: 44)
            .background(
                isArmed
                    ? palette.statusFailure
                    : (isPressed ? palette.tileFillBottom : palette.tileFillTop.opacity(0.94)),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isArmed
                            ? palette.statusFailure
                            : (isPressed ? palette.accent : palette.subtleCardStroke),
                        lineWidth: (isArmed || isPressed) ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
        .accessibilityIdentifier("ios-empty-trash-button")
        .accessibilityLabel(Round08MaintenanceAction.emptyTrash.title(compact: false, in: lang))
        .accessibilityValue(isArmed ? L10n.tr("等待第二次点按确认", "Awaiting second tap confirmation", language: lang) : "")
    }
}

// MARK: - 2. Eject External Disks Pill Button (Quiet When Nothing to Eject; 3-Second Confirm Otherwise)

public struct IOSEjectExternalDisksPillButton: View {
    @ObservedObject var client: CompanionClientEngine
    let compact: Bool
    var onPromptHUD: ((String) -> Void)?

    @State private var pressedKey: String?

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        compact: Bool = false,
        onPromptHUD: ((String) -> Void)? = nil
    ) {
        self.client = client
        self.compact = compact
        self.onPromptHUD = onPromptHUD
    }

    public var body: some View {
        let key = "round08-eject-disks-pill"
        let ejectableCount = client.connectionState.isConnected
            ? client.controlStripState.ejectableExternalVolumeCount
            : 0
        let hasDisks = ejectableCount > 0
        let isPressed = hasDisks && (pressedKey == key)
        let now = ProcessInfo.processInfo.systemUptime
        let isArmed = hasDisks && client.isMaintenanceActionArmed(.ejectExternalDisks, at: now)
        let baseTitle = Round08MaintenanceAction.ejectExternalDisks.title(
            ejectableCount: ejectableCount,
            compact: compact,
            in: lang
        )
        let displayTitle = isArmed
            ? L10n.tr("再点确认", "Tap Again", language: lang)
            : baseTitle

        Button {
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedKey)
            let outcome = client.tapEjectExternalDisks(at: ProcessInfo.processInfo.systemUptime)
            switch outcome {
            case .quietNothingToEject:
                // Quiet by specification when nothing is mounted to eject.
                break
            case .requireSecondTap:
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                onPromptHUD?(Round08MaintenanceAction.ejectExternalDisks.secondTapPrompt(in: lang))
            case .confirmedExecute:
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isArmed ? "exclamationmark.triangle.fill" : "eject.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(
                        isArmed
                            ? palette.emphasisForeground
                            : (hasDisks ? palette.accent : palette.secondaryText.opacity(0.55))
                    )

                Text(displayTitle)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        isArmed
                            ? palette.emphasisForeground
                            : (hasDisks ? palette.primaryText : palette.secondaryText.opacity(0.68))
                    )
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, compact ? 9 : 10)
            .frame(minHeight: 44)
            .background(
                isArmed
                    ? palette.statusFailure
                    : (hasDisks
                        ? (isPressed ? palette.tileFillBottom : palette.tileFillTop.opacity(0.94))
                        : palette.tileFillBottom.opacity(0.48)),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isArmed
                            ? palette.statusFailure
                            : (hasDisks
                                ? (isPressed ? palette.accent : palette.subtleCardStroke)
                                : palette.subtleCardStroke.opacity(0.5)),
                        lineWidth: (isArmed || isPressed) ? 1.6 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(isPressed ? 0.94 : 1.0)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: key))
        .accessibilityIdentifier("ios-eject-disks-button")
        .accessibilityLabel(
            Round08MaintenanceAction.ejectExternalDisks.title(
                ejectableCount: ejectableCount,
                compact: false,
                in: lang
            )
        )
        .accessibilityValue(
            !hasDisks
                ? L10n.tr("无可推出的外置磁盘", "Nothing to eject", language: lang)
                : (isArmed ? L10n.tr("等待第二次点按确认", "Awaiting second tap confirmation", language: lang) : "\(ejectableCount)")
        )
    }
}

// MARK: - 3. Read-Only Camera & Microphone In-Use Strip Badge (No Preview, No Stream, No Shutter, Not a Mute Button)

public struct IOSPrivacyCaptureStripBadge: View {
    @ObservedObject var client: CompanionClientEngine

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        let isConnected = client.connectionState.isConnected
        let privacy = isConnected ? client.controlStripState.privacyCapture : .inactive
        let text: String = isConnected
            ? privacy.stripSummaryText(in: lang)
            : L10n.tr("摄像头/麦克风 —", "Cam & Mic —", language: lang)

        let backgroundFill: Color = {
            if !isConnected || !privacy.isAnyCaptureActive {
                return palette.tileFillBottom.opacity(0.72)
            }
            if privacy.isCameraInUse {
                return palette.statusConnected.opacity(0.14)
            }
            return palette.accentEmphasis.opacity(0.14)
        }()

        let strokeColor: Color = {
            if !isConnected || !privacy.isAnyCaptureActive {
                return palette.subtleCardStroke
            }
            if privacy.isCameraInUse {
                return palette.statusConnected.opacity(0.5)
            }
            return palette.accentEmphasis.opacity(0.5)
        }()

        HStack(spacing: 5) {
            if isConnected && privacy.isAnyCaptureActive {
                if privacy.isCameraInUse {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(palette.statusConnected)
                }
                if privacy.isMicrophoneInUse {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(palette.accentEmphasis)
                }
            } else {
                Image(systemName: "video.slash")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(palette.secondaryText.opacity(0.75))
            }

            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(
                    isConnected
                        ? (privacy.isAnyCaptureActive ? palette.primaryText : palette.secondaryText)
                        : palette.secondaryText.opacity(0.8)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(backgroundFill, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(strokeColor, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ios-strip-privacy-capture")
        .accessibilityLabel(L10n.tr("Mac 摄像头与麦克风状态", "Mac Camera and Microphone Status", language: lang))
        .accessibilityValue(text)
    }
}

// MARK: - 4. Read-Only Wi-Fi Current SSID Strip Badge (Current SSID Only, Fallback "Wi-Fi")

public struct IOSWiFiSSIDStripBadge: View {
    @ObservedObject var client: CompanionClientEngine

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        let isConnected = client.connectionState.isConnected
        let rawSSID = isConnected ? client.controlStripState.wifiSSID : nil
        let hasSSID = MacWiFiStatusFormatter.sanitizedSSID(rawSSID) != nil
        let labelText = MacWiFiStatusFormatter.displayText(ssid: rawSSID)

        HStack(spacing: 5) {
            Image(systemName: "wifi")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(hasSSID ? palette.accent : palette.secondaryText.opacity(0.75))

            Text(labelText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(hasSSID ? palette.primaryText : palette.secondaryText.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(palette.tileFillBottom.opacity(0.72), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ios-strip-wifi-ssid")
        .accessibilityLabel(L10n.tr("Mac Wi-Fi 名称", "Mac Wi-Fi Name", language: lang))
        .accessibilityValue(labelText)
    }
}
