import ChocliftCore
import SwiftUI

struct IOSDeskTimerSection: View {
    @ObservedObject var client: CompanionClientEngine
    let toolsQuery: String

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var timer: DeskTimerState { client.controlStripState.deskTimer }

    private var shouldDisplay: Bool {
        let trimmed = toolsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let searchableTokens = [
            DeskTimerState.cardTitle(in: lang),
            "计时器", "倒计时", "番茄", "暂停", "继续", "重置",
            "Timer", "Countdown", "Pause", "Resume", "Reset",
            "5", "10", "15", "25", "45"
        ]
        return searchableTokens.contains { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        if shouldDisplay {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "timer")
                        .font(ChocType.body)
                        .foregroundStyle(palette.accent)
                    Text(DeskTimerState.cardTitle(in: lang))
                        .font(ChocType.title)
                        .foregroundStyle(palette.primaryText)
                    Text(timer.phase.statusLabel(in: lang))
                        .font(ChocType.micro)
                        .foregroundStyle(phaseTint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(phaseBackground, in: Capsule())
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
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
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(ChocType.caption)
                            Text(L10n.tr("重置", "Reset", language: lang))
                                .font(ChocType.caption)
                        }
                        .foregroundStyle(timer.phase == .idle ? palette.secondaryText.opacity(0.55) : palette.primaryText)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 42)
                        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(timer.phase == .idle)
                    .accessibilityIdentifier("ios-desk-timer-reset")
                }

                HStack(spacing: 6) {
                    ForEach(DeskTimerState.presetMinutes, id: \.self) { minutes in
                        presetChip(minutes: minutes)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
            .accessibilityIdentifier("ios-desk-timer-card")
        }
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
            CompanionFeedbackHaptics.tap(
                enabled: client.profile.settings.hapticFeedbackEnabled,
                intensity: .light
            )
            client.toggleDeskTimerRunPause()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: primaryActionSymbol)
                    .font(ChocType.caption)
                    .foregroundStyle(isActive ? palette.accentForeground : palette.accent)
                Text(remainingText)
                    .font(ChocType.title.monospacedDigit())
                    .foregroundStyle(isActive ? palette.accentForeground : palette.primaryText)
                Spacer(minLength: 4)
                Text(primaryActionLabel)
                    .font(ChocType.caption)
                    .foregroundStyle(isActive ? palette.accentForeground.opacity(0.92) : palette.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
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
        .accessibilityIdentifier("ios-desk-timer-primary")
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
                .font(ChocType.caption.monospacedDigit())
                .foregroundStyle(isActiveMatch ? palette.accentForeground : palette.primaryText)
                .frame(maxWidth: .infinity, minHeight: 36)
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
        .accessibilityIdentifier("ios-desk-timer-preset-\(minutes)")
    }
}
