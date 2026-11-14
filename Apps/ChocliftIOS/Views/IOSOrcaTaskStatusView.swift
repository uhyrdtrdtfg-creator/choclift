import ChocliftCore
import SwiftUI

public struct IOSOrcaTaskStatusBar: View {
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
        if client.connectionState.isConnected, let status = client.orcaStatus {
            if !status.isOrcaRunning {
                notRunningRow
            } else {
                let rows = status.displayRows
                if rows.count <= 1, let single = rows.first {
                    singleTaskRow(single)
                } else {
                    multiTaskStrip(rows)
                }
            }
        }
    }

    // MARK: - Quiet Not-Running Line (No Install Prompt)

    private var notRunningRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "terminal")
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)

            Text(L10n.tr("Orca 未运行", "Orca is not running", language: lang))
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: compact ? 30 : 34)
        .background(palette.barSurface.opacity(0.76), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(palette.subtleCardStroke.opacity(0.75), lineWidth: 1)
        )
        .accessibilityIdentifier("ios-orca-not-running-row")
    }

    // MARK: - Single Task Row

    @ViewBuilder
    private func singleTaskRow(_ item: OrcaTaskStatusItem) -> some View {
        if item.canTapToFocus {
            let isPressed = (pressedKey == item.id)
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                ChocPressFeedback.completeTap(key: item.id, pressedKey: $pressedKey)
                client.focusOrcaTask(dispatchID: item.dispatchID)
            } label: {
                taskRowContent(item, expandWidth: true)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(
                        isPressed ? palette.tileFillBottom : rowBackground(for: item.state),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(
                                isPressed ? palette.accent : rowBorderColor(for: item.state),
                                lineWidth: isPressed ? 1.8 : 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .scaleEffect(isPressed ? 0.97 : 1.0)
            }
            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: item.id))
            .accessibilityIdentifier("ios-orca-task-row-\(item.id)")
        } else {
            taskRowContent(item, expandWidth: true)
                .padding(.horizontal, 12)
                .frame(minHeight: compact ? 36 : 40)
                .background(palette.barSurface.opacity(0.86), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                )
                .accessibilityIdentifier("ios-orca-task-row-\(item.id)")
        }
    }

    // MARK: - Multi-Task Strip

    private func multiTaskStrip(_ rows: [OrcaTaskStatusItem]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "terminal.fill")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.accent)
                Text("Orca")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.primaryText)
                Text("\(rows.count)")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(rows) { item in
                        if item.canTapToFocus {
                            let isPressed = (pressedKey == item.id)
                            Button {
                                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
                                ChocPressFeedback.completeTap(key: item.id, pressedKey: $pressedKey)
                                client.focusOrcaTask(dispatchID: item.dispatchID)
                            } label: {
                                taskPillContent(item)
                                    .padding(.horizontal, 11)
                                    .frame(minHeight: 44)
                                    .background(
                                        isPressed ? palette.tileFillBottom : rowBackground(for: item.state),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(
                                                isPressed ? palette.accent : rowBorderColor(for: item.state),
                                                lineWidth: isPressed ? 1.8 : 1
                                            )
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .scaleEffect(isPressed ? 0.96 : 1.0)
                            }
                            .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedKey, key: item.id))
                            .accessibilityIdentifier("ios-orca-task-row-\(item.id)")
                        } else {
                            taskPillContent(item)
                                .padding(.horizontal, 11)
                                .frame(minHeight: 40)
                                .background(palette.tileFillTop.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                                )
                                .accessibilityIdentifier("ios-orca-task-row-\(item.id)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Shared Row Visuals

    private func taskRowContent(_ item: OrcaTaskStatusItem, expandWidth: Bool) -> some View {
        let tint = stateColor(for: item.state)
        return HStack(spacing: 8) {
            Text("Orca")
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)

            stateBadge(for: item.state, tint: tint)

            if let title = item.title, !title.isEmpty {
                Text(title)
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if expandWidth {
                Spacer(minLength: 4)
            }

            if item.canTapToFocus {
                HStack(spacing: 3) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(ChocType.micro)
                    if !compact {
                        Text(L10n.tr("前置", "Focus", language: lang))
                            .font(ChocType.micro)
                    }
                }
                .foregroundStyle(palette.accent)
                .padding(.horizontal, compact ? 6 : 8)
                .padding(.vertical, 4)
                .background(palette.accent.opacity(0.11), in: Capsule())
            }
        }
    }

    private func taskPillContent(_ item: OrcaTaskStatusItem) -> some View {
        let tint = stateColor(for: item.state)
        return HStack(spacing: 6) {
            stateBadge(for: item.state, tint: tint)

            if let title = item.title, !title.isEmpty {
                Text(title)
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: compact ? 180 : 240, alignment: .leading)
            }

            if item.canTapToFocus {
                Image(systemName: "macwindow.on.rectangle")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.accent)
            }
        }
    }

    private func stateBadge(for state: OrcaTaskState, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: state.sfSymbol)
                .font(ChocType.micro)
            Text(state.label(in: lang))
                .font(ChocType.micro)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
    }

    private func stateColor(for state: OrcaTaskState) -> Color {
        switch state {
        case .working:
            return palette.statusConnected
        case .waiting:
            return palette.accentEmphasis
        case .failed:
            return palette.statusFailure
        case .idle:
            return palette.secondaryText
        }
    }

    private func rowBackground(for state: OrcaTaskState) -> Color {
        switch state {
        case .failed:
            return palette.barSurface.opacity(0.96)
        default:
            return palette.barSurface.opacity(0.94)
        }
    }

    private func rowBorderColor(for state: OrcaTaskState) -> Color {
        switch state {
        case .failed:
            return palette.statusFailure.opacity(0.55)
        case .waiting:
            return palette.accentEmphasis.opacity(0.45)
        case .working:
            return palette.statusConnected.opacity(0.38)
        case .idle:
            return palette.subtleCardStroke
        }
    }
}
