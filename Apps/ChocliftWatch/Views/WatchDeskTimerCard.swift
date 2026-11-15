import ChocliftCore
import SwiftUI

public struct WatchDeskTimerCard: View {
    @ObservedObject var client: CompanionClientEngine

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var timer: DeskTimerState { client.controlStripState.deskTimer }

    private let chipColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 5),
        GridItem(.flexible(), spacing: 5),
        GridItem(.flexible(), spacing: 5)
    ]

    public init(client: CompanionClientEngine) {
        self.client = client
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "timer")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.accent)
                Text(DeskTimerState.cardTitle(in: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(timer.phase.statusLabel(in: lang))
                    .font(ChocType.micro)
                    .foregroundStyle(phaseTint)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                if timer.phase == .running {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        primaryTimerButton(at: context.date)
                    }
                } else {
                    primaryTimerButton(at: Date())
                }

                Button {
                    CompanionFeedbackHaptics.tap(
                        enabled: client.profile.settings.hapticFeedbackEnabled,
                        intensity: .light
                    )
                    client.resetDeskTimer()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(ChocType.caption)
                        .foregroundStyle(timer.phase == .idle ? palette.secondaryText.opacity(0.45) : palette.primaryText)
                        .frame(width: 38, height: 38)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(timer.phase == .idle)
                .accessibilityLabel(L10n.tr("重置", "Reset", language: lang))
                .accessibilityIdentifier("watch-desk-timer-reset")
            }

            LazyVGrid(columns: chipColumns, spacing: 5) {
                ForEach(DeskTimerState.presetMinutes, id: \.self) { minutes in
                    presetChip(minutes: minutes)
                }
            }
        }
        .padding(9)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("watch-desk-timer-card")
    }

    private var phaseTint: Color {
        switch timer.phase {
        case .running:
            return palette.accent
        case .paused:
            return palette.accentEmphasis
        case .idle:
            return palette.secondaryText
        }
    }

    private var primaryActionSymbol: String {
        timer.phase == .running ? "pause.fill" : "play.fill"
    }

    private func primaryTimerButton(at now: Date) -> some View {
        let remainingText = timer.formattedRemaining(at: now)
        let isActive = timer.phase != .idle

        return Button {
            CompanionFeedbackHaptics.tap(
                enabled: client.profile.settings.hapticFeedbackEnabled,
                intensity: .light
            )
            client.toggleDeskTimerRunPause()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: primaryActionSymbol)
                    .font(ChocType.micro)
                    .foregroundStyle(isActive ? palette.accentForeground : palette.accent)
                Text(remainingText)
                    .font(ChocType.body.monospacedDigit())
                    .foregroundStyle(isActive ? palette.accentForeground : palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(
                isActive ? palette.accent : palette.tileFillBottom,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? palette.accent : palette.subtleCardStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch-desk-timer-primary")
    }

    private func presetChip(minutes: Int) -> some View {
        let seconds = minutes * 60
        let isMatchingPreset = (timer.presetSeconds == seconds)
        let isActiveMatch = isMatchingPreset && timer.phase != .idle

        return Button {
            CompanionFeedbackHaptics.tap(
                enabled: client.profile.settings.hapticFeedbackEnabled,
                intensity: .light
            )
            client.startDeskTimer(presetSeconds: seconds)
        } label: {
            Text(DeskTimerState.presetChipTitle(minutes: minutes, in: lang))
                .font(ChocType.micro.monospacedDigit())
                .foregroundStyle(isActiveMatch ? palette.accentForeground : palette.primaryText)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    isActiveMatch ? palette.accent : palette.tileFillBottom,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isMatchingPreset ? palette.accent.opacity(0.65) : palette.subtleCardStroke,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch-desk-timer-preset-\(minutes)")
    }
}
