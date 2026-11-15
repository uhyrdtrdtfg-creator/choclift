import ChocliftCore
import SwiftUI

public struct MacDeskTimerCard: View {
    @ObservedObject var coordinator: MacAppCoordinator

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }
    private var timer: DeskTimerState { coordinator.controlStripState.deskTimer }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(DeskTimerState.cardTitle(in: lang), systemImage: "timer")
                    .font(ChocType.title)
                    .foregroundStyle(palette.primaryText)

                Text(timer.phase.statusLabel(in: lang))
                    .font(ChocType.micro)
                    .foregroundStyle(phaseTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(phaseBackground, in: Capsule())

                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                if timer.phase == .running {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        primaryTimerButton(at: context.date)
                    }
                } else {
                    primaryTimerButton(at: Date())
                }

                Button {
                    coordinator.resetDeskTimer()
                } label: {
                    Label(L10n.tr("重置", "Reset", language: lang), systemImage: "arrow.counterclockwise")
                        .font(ChocType.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(timer.phase == .idle)
                .accessibilityIdentifier("mac-desk-timer-reset")
            }

            HStack(spacing: 8) {
                ForEach(DeskTimerState.presetMinutes, id: \.self) { minutes in
                    presetChip(minutes: minutes)
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("mac-desk-timer-card")
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

    private var phaseBackground: Color {
        switch timer.phase {
        case .running:
            return palette.accent.opacity(0.14)
        case .paused:
            return palette.accentEmphasis.opacity(0.14)
        case .idle:
            return palette.tileFillBottom
        }
    }

    private var primaryActionLabel: String {
        switch timer.phase {
        case .running:
            return L10n.tr("暂停", "Pause", language: lang)
        case .paused:
            return L10n.tr("继续", "Resume", language: lang)
        case .idle:
            return L10n.tr("开始", "Start", language: lang)
        }
    }

    private var primaryActionSymbol: String {
        timer.phase == .running ? "pause.fill" : "play.fill"
    }

    private func primaryTimerButton(at now: Date) -> some View {
        let remainingText = timer.formattedRemaining(at: now)
        let isActive = timer.phase != .idle

        return Button {
            coordinator.toggleDeskTimerRunPause()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: primaryActionSymbol)
                    .font(ChocType.caption)
                    .foregroundStyle(isActive ? palette.accentForeground : palette.accent)
                Text(remainingText)
                    .font(ChocType.title.monospacedDigit())
                    .foregroundStyle(isActive ? palette.accentForeground : palette.primaryText)
                Spacer(minLength: 6)
                Text(primaryActionLabel)
                    .font(ChocType.caption)
                    .foregroundStyle(isActive ? palette.accentForeground.opacity(0.92) : palette.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityIdentifier("mac-desk-timer-primary")
    }

    private func presetChip(minutes: Int) -> some View {
        let seconds = minutes * 60
        let isMatchingPreset = (timer.presetSeconds == seconds)
        let isActiveMatch = isMatchingPreset && timer.phase != .idle

        return Button {
            coordinator.startDeskTimer(presetSeconds: seconds)
        } label: {
            Text(DeskTimerState.presetChipTitle(minutes: minutes, in: lang))
                .font(ChocType.caption.monospacedDigit())
                .foregroundStyle(isActiveMatch ? palette.accentForeground : palette.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
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
        .accessibilityIdentifier("mac-desk-timer-preset-\(minutes)")
    }
}
