import ChocliftCore
import SwiftUI

struct IOSCompanionHotkeysSection: View {
    @ObservedObject var client: CompanionClientEngine
    let toolsQuery: String

    @State private var showAddPicker = false

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }
    private var hotkeys: [CompanionHotkey] { client.profile.hotkeys }
    private var isAtLimit: Bool { hotkeys.count >= CompanionHotkeyLibrary.maxCount }

    private var sectionHeaderTitle: String {
        L10n.tr("快捷键", "Shortcuts", language: lang)
    }

    private var filteredHotkeys: [CompanionHotkey] {
        let trimmed = toolsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return hotkeys }
        if sectionHeaderTitle.localizedCaseInsensitiveContains(trimmed) {
            return hotkeys
        }
        return hotkeys.filter {
            $0.resolvedTitle(in: lang).localizedCaseInsensitiveContains(trimmed) ||
            $0.displayLabel.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var shouldShowAddRow: Bool {
        let trimmed = toolsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let addLabel = L10n.tr("添加快捷键", "Add Shortcut", language: lang)
        return addLabel.localizedCaseInsensitiveContains(trimmed) ||
            sectionHeaderTitle.localizedCaseInsensitiveContains(trimmed)
    }

    var body: some View {
        if !filteredHotkeys.isEmpty || shouldShowAddRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(sectionHeaderTitle)
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                    Text("\(hotkeys.count)/\(CompanionHotkeyLibrary.maxCount)")
                        .font(ChocType.micro)
                        .foregroundStyle(palette.secondaryText)
                }

                VStack(spacing: 0) {
                    ForEach(filteredHotkeys) { hotkey in
                        hotkeyRow(hotkey)
                        Divider().overlay(palette.subtleCardStroke)
                    }

                    if shouldShowAddRow {
                        Button {
                            showAddPicker = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(isAtLimit ? palette.secondaryText : palette.accent)
                                    .frame(width: 22)
                                Text(
                                    isAtLimit
                                        ? L10n.tr("已达 8 个快捷键上限", "8-Shortcut Limit Reached", language: lang)
                                        : L10n.tr("添加快捷键", "Add Shortcut", language: lang)
                                )
                                .foregroundStyle(isAtLimit ? palette.secondaryText : palette.primaryText)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(ChocType.micro)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            .font(ChocType.body)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isAtLimit)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            }
            .sheet(isPresented: $showAddPicker) {
                IOSCompanionHotkeyAddSheet(client: client)
            }
        }
    }

    private func hotkeyRow(_ hotkey: CompanionHotkey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: CompanionHotkeyLibrary.actionSymbol(for: hotkey.actionID))
                .foregroundStyle(palette.accent)
                .frame(width: 22)

            Text(hotkey.resolvedTitle(in: lang))
                .font(ChocType.body)
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(hotkey.displayLabel)
                .font(ChocType.caption)
                .foregroundStyle(palette.primaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(palette.tileFillBottom, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))

            Button {
                client.deleteCompanionHotkey(id: hotkey.id)
            } label: {
                Image(systemName: "trash")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.statusFailure)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("删除快捷键", "Delete Shortcut", language: lang))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
    }
}

private struct IOSCompanionHotkeyAddSheet: View {
    @ObservedObject var client: CompanionClientEngine
    @Environment(\.dismiss) private var dismiss

    @State private var selectedActionID: String = SystemQuickAction.maximizeWindow.rawValue
    @State private var useCommand: Bool = true
    @State private var useOption: Bool = true
    @State private var useControl: Bool = false
    @State private var useShift: Bool = false
    @State private var selectedKeyCode: UInt16 = 0x28 // K

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var carbonModifiers: UInt32 {
        CompanionHotkeyModifiers.make(
            command: useCommand,
            option: useOption,
            control: useControl,
            shift: useShift
        )
    }

    private var hasRequiredModifier: Bool {
        CompanionHotkeyLibrary.hasRequiredModifiers(carbonModifiers)
    }

    private var isDuplicateChord: Bool {
        let normalized = CompanionHotkeyLibrary.normalizedModifiers(carbonModifiers)
        return client.profile.hotkeys.contains {
            $0.keyCode == selectedKeyCode && $0.carbonModifiers == normalized
        }
    }

    private var canSave: Bool {
        hasRequiredModifier &&
            !isDuplicateChord &&
            selectedKeyCode != 0 &&
            client.profile.hotkeys.count < CompanionHotkeyLibrary.maxCount
    }

    private var previewChord: String {
        CompanionHotkeyLibrary.displayLabel(keyCode: selectedKeyCode, carbonModifiers: carbonModifiers)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    previewCard

                    actionPickerCard

                    modifiersCard

                    keyMenuCard
                }
                .padding(16)
            }
            .background(
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消", "Cancel", language: lang)) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(L10n.tr("添加快捷键", "Add Shortcut", language: lang))
                        .font(ChocType.title)
                        .foregroundStyle(palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("保存", "Save", language: lang)) {
                        saveShortcut()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .tint(palette.accent)
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.tr("组合键预览", "Shortcut Preview", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text(previewChord)
                    .font(ChocType.title)
                    .foregroundStyle(hasRequiredModifier ? palette.accent : palette.statusFailure)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(palette.tileFillBottom, in: Capsule())
            }

            if !hasRequiredModifier {
                Text(L10n.tr("请至少开启 Command、Option 或 Control 中的一个修饰键。", "Turn on at least one of Command, Option, or Control.", language: lang))
                    .font(ChocType.micro)
                    .foregroundStyle(palette.statusFailure)
            } else if isDuplicateChord {
                Text(L10n.tr("该组合键已存在，请更换修饰键或按键。", "This shortcut chord is already saved.", language: lang))
                    .font(ChocType.micro)
                    .foregroundStyle(palette.statusFailure)
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
    }

    private var actionPickerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("触发动作", "Action", language: lang))
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)

            Menu {
                Section(L10n.tr("快捷操作", "Quick Actions", language: lang)) {
                    ForEach(SystemQuickAction.allCases) { action in
                        Button {
                            selectedActionID = action.rawValue
                        } label: {
                            Label(action.title(in: lang), systemImage: action.sfSymbol)
                        }
                    }
                }
                Section(L10n.tr("更多伴侣操作", "Companion Actions", language: lang)) {
                    ForEach(CompanionActionCatalog.all) { action in
                        Button {
                            selectedActionID = action.id
                        } label: {
                            Label(action.title(in: lang), systemImage: action.sfSymbol)
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: CompanionHotkeyLibrary.actionSymbol(for: selectedActionID))
                        .foregroundStyle(palette.accent)
                        .frame(width: 22)
                    Text(CompanionHotkeyLibrary.actionTitle(for: selectedActionID, in: lang) ?? selectedActionID)
                        .font(ChocType.body)
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(ChocType.micro)
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            }
        }
    }

    private var modifiersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("修饰键", "Modifiers", language: lang))
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)

            VStack(spacing: 0) {
                modifierToggleRow(title: "Command (⌘)", isOn: $useCommand)
                Divider().overlay(palette.subtleCardStroke)
                modifierToggleRow(title: "Option (⌥)", isOn: $useOption)
                Divider().overlay(palette.subtleCardStroke)
                modifierToggleRow(title: "Control (⌃)", isOn: $useControl)
                Divider().overlay(palette.subtleCardStroke)
                modifierToggleRow(title: "Shift (⇧)", isOn: $useShift)
            }
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
        }
    }

    private func modifierToggleRow(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(ChocType.body)
                .foregroundStyle(palette.primaryText)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }

    private var keyMenuCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tr("按键", "Key", language: lang))
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)

            Menu {
                ForEach(CompanionHotkeyKeyOption.Category.allCases, id: \.self) { category in
                    Section(category.title(in: lang)) {
                        ForEach(CompanionHotkeyLibrary.pickerKeyOptions.filter { $0.category == category }) { option in
                            Button(option.label) {
                                selectedKeyCode = option.keyCode
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "keyboard")
                        .foregroundStyle(palette.accent)
                        .frame(width: 22)
                    Text(CompanionHotkeyLibrary.keyName(for: selectedKeyCode))
                        .font(ChocType.body)
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(ChocType.micro)
                        .foregroundStyle(palette.secondaryText)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            }
        }
    }

    private func saveShortcut() {
        guard canSave else { return }
        let title = CompanionHotkeyLibrary.actionTitle(for: selectedActionID, in: lang) ?? selectedActionID
        let hotkey = CompanionHotkey(
            keyCode: selectedKeyCode,
            carbonModifiers: carbonModifiers,
            actionID: selectedActionID,
            title: title
        )
        client.upsertCompanionHotkey(hotkey)
        dismiss()
    }
}
