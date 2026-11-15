import AppKit
import ChocliftCore
import SwiftUI

public struct MacCompanionHotkeysCard: View {
    @ObservedObject var coordinator: MacAppCoordinator

    @State private var selectedActionID: String = SystemQuickAction.maximizeWindow.rawValue
    @State private var recordedKeyCode: UInt16?
    @State private var recordedCarbonModifiers: UInt32 = 0
    @State private var isRecording: Bool = false
    @State private var localMonitorToken: Any?
    @State private var validationMessage: String?

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }
    private var hotkeys: [CompanionHotkey] { coordinator.profile.hotkeys }
    private var isAtLimit: Bool { hotkeys.count >= CompanionHotkeyLibrary.maxCount }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(
                    L10n.tr("快捷键", "Shortcuts", language: lang),
                    systemImage: "command"
                )
                .font(ChocType.title)
                .foregroundStyle(palette.primaryText)

                Text("\(hotkeys.count)/\(CompanionHotkeyLibrary.maxCount)")
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.tileFillBottom, in: Capsule())

                Spacer()
            }

            Text(
                L10n.tr(
                    "绑定全局 Mac 快捷键以立即执行单个伴侣动作（最多 8 个，需包含 ⌘、⌥ 或 ⌃）。",
                    "Bind up to 8 global Mac shortcuts to trigger an action immediately (requires ⌘, ⌥, or ⌃).",
                    language: lang
                )
            )
            .font(ChocType.caption)
            .foregroundStyle(palette.secondaryText)

            composerRow

            if let validationMessage, !validationMessage.isEmpty {
                Text(validationMessage)
                    .font(ChocType.micro)
                    .foregroundStyle(palette.statusFailure)
            }

            if hotkeys.isEmpty {
                Text(L10n.tr("尚未添加全局快捷键。", "No global shortcuts saved yet.", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(hotkeys) { hotkey in
                        savedHotkeyRow(hotkey)
                    }
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .onDisappear {
            stopRecording()
        }
    }

    private var composerRow: some View {
        HStack(spacing: 10) {
            Picker(L10n.tr("动作", "Action", language: lang), selection: $selectedActionID) {
                Section(L10n.tr("快捷操作", "Quick Actions", language: lang)) {
                    ForEach(SystemQuickAction.allCases) { action in
                        Text(action.title(in: lang)).tag(action.rawValue)
                    }
                }
                Section(L10n.tr("更多伴侣操作", "Companion Actions", language: lang)) {
                    ForEach(CompanionActionCatalog.all) { action in
                        Text(action.title(in: lang)).tag(action.id)
                    }
                }
                if !coordinator.profile.flows.isEmpty {
                    Section(L10n.tr("动作流", "Action Flows", language: lang)) {
                        ForEach(coordinator.profile.flows) { flow in
                            let actionID = CompanionHotkeyLibrary.flowActionID(flow.id)
                            Text(pickerItemTitle(flow.name, fallbackID: actionID)).tag(actionID)
                        }
                    }
                }
                if !coordinator.profile.quadLayouts.isEmpty {
                    Section(L10n.tr("四宫格", "Quad Layouts", language: lang)) {
                        ForEach(coordinator.profile.quadLayouts) { layout in
                            let actionID = CompanionHotkeyLibrary.quadActionID(layout.id)
                            Text(pickerItemTitle(layout.name, fallbackID: actionID)).tag(actionID)
                        }
                    }
                }
                if !isPickerSelectionPresent {
                    Text(selectedActionID).tag(selectedActionID)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
                        .foregroundStyle(isRecording ? palette.accentEmphasis : palette.accent)
                    Text(recorderButtonTitle)
                        .font(ChocType.caption)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    isRecording ? palette.accent.opacity(0.12) : palette.tileFillBottom,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isRecording ? palette.accent : palette.subtleCardStroke, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isAtLimit && !isRecording)

            Button(L10n.tr("保存", "Save", language: lang)) {
                saveRecordedHotkey()
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .foregroundStyle(palette.accentForeground)
            .disabled(!canSaveRecordedHotkey)
        }
    }

    private var recorderButtonTitle: String {
        if isRecording {
            return L10n.tr("按下组合键… (Esc 取消)", "Press shortcut… (Esc to cancel)", language: lang)
        }
        if let keyCode = recordedKeyCode, CompanionHotkeyLibrary.hasRequiredModifiers(recordedCarbonModifiers) {
            return CompanionHotkeyLibrary.displayLabel(keyCode: keyCode, carbonModifiers: recordedCarbonModifiers)
        }
        return L10n.tr("录制快捷键", "Record Shortcut", language: lang)
    }

    private var isPickerSelectionPresent: Bool {
        if CompanionHotkeyLibrary.isKnownActionID(selectedActionID) {
            return true
        }
        if coordinator.profile.flows.contains(where: { CompanionHotkeyLibrary.flowActionID($0.id) == selectedActionID }) {
            return true
        }
        if coordinator.profile.quadLayouts.contains(where: { CompanionHotkeyLibrary.quadActionID($0.id) == selectedActionID }) {
            return true
        }
        return false
    }

    private func pickerItemTitle(_ rawName: String, fallbackID: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackID : trimmed
    }

    private var canSaveRecordedHotkey: Bool {
        guard !isAtLimit,
              let keyCode = recordedKeyCode,
              CompanionHotkeyLibrary.isAllowedKeyCode(keyCode),
              CompanionHotkeyLibrary.isValidActionID(selectedActionID) else {
            return false
        }
        return CompanionHotkeyLibrary.hasRequiredModifiers(recordedCarbonModifiers)
    }

    private func savedHotkeyRow(_ hotkey: CompanionHotkey) -> some View {
        let isConflict = coordinator.hotkeyMonitor?.failedRegistrationIDs.contains(hotkey.id) == true
        return HStack(spacing: 10) {
            Image(systemName: CompanionHotkeyLibrary.actionSymbol(for: hotkey.actionID))
                .font(ChocType.body)
                .foregroundStyle(palette.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(hotkey.resolvedTitle(in: coordinator.profile, language: lang))
                    .font(ChocType.body)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                if isConflict {
                    Text(L10n.tr("系统快捷键冲突，未能注册", "Shortcut already in use by macOS", language: lang))
                        .font(ChocType.micro)
                        .foregroundStyle(palette.statusFailure)
                }
            }

            Spacer(minLength: 8)

            Text(hotkey.displayLabel)
                .font(ChocType.caption)
                .foregroundStyle(palette.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(palette.tileFillBottom, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))

            Button {
                _ = coordinator.deleteCompanionHotkey(id: hotkey.id)
            } label: {
                Image(systemName: "trash")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.statusFailure)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("删除快捷键", "Delete shortcut", language: lang))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private func startRecording() {
        stopRecording()
        validationMessage = nil
        isRecording = true
        coordinator.hotkeyMonitor?.setSuspendedForRecording(true)

        localMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let carbonMods = Self.carbonModifiers(from: flags)

            if event.keyCode == 0x35 && !CompanionHotkeyLibrary.hasRequiredModifiers(carbonMods) {
                stopRecording()
                return nil
            }

            if CompanionHotkeyLibrary.isModifierKeyCode(event.keyCode) {
                return nil
            }

            guard CompanionHotkeyLibrary.hasRequiredModifiers(carbonMods) else {
                validationMessage = L10n.tr(
                    "必须包含 ⌘、⌥ 或 ⌃ 修饰键（不能仅使用 ⇧）。",
                    "Include at least Command, Option, or Control (Shift-only is not allowed).",
                    language: lang
                )
                return nil
            }

            guard CompanionHotkeyLibrary.isAllowedKeyCode(event.keyCode) else {
                validationMessage = L10n.tr(
                    "不支持该按键，请换用其他按键。",
                    "This key cannot be used as a shortcut; choose another key.",
                    language: lang
                )
                return nil
            }

            recordedKeyCode = event.keyCode
            recordedCarbonModifiers = carbonMods
            validationMessage = nil
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let token = localMonitorToken {
            NSEvent.removeMonitor(token)
            localMonitorToken = nil
        }
        if isRecording {
            isRecording = false
        }
        coordinator.hotkeyMonitor?.setSuspendedForRecording(false)
    }

    private func saveRecordedHotkey() {
        guard let keyCode = recordedKeyCode else { return }
        let title = CompanionHotkeyLibrary.actionTitle(for: selectedActionID, in: coordinator.profile, language: lang) ?? selectedActionID
        let hotkey = CompanionHotkey(
            keyCode: keyCode,
            carbonModifiers: recordedCarbonModifiers,
            actionID: selectedActionID,
            title: title
        )
        let outcome = coordinator.upsertCompanionHotkey(hotkey)
        if outcome.success {
            recordedKeyCode = nil
            recordedCarbonModifiers = 0
            validationMessage = nil
        } else {
            validationMessage = outcome.detail
        }
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        CompanionHotkeyModifiers.make(
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            shift: flags.contains(.shift)
        )
    }
}
