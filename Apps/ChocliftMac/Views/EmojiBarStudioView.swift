import ChocliftCore
import SwiftUI

public struct EmojiBarStudioView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @State private var selectedEmojiSlot: Int = 0
    @State private var selectedCategoryID: String = EmojiCatalog.categories.first?.id ?? "popular"
    @State private var emojiSearch = ""
    @State private var customEmojiInput: String = ""
    @State private var snippetSearch = ""
    @State private var snippetEditorSession: MacSnippetEditorSession?

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    private var currentSlide: EmojiSlide {
        let idx = min(max(0, coordinator.selectedEmojiSlideIndex), coordinator.profile.emojiSlides.count - 1)
        return coordinator.profile.emojiSlides[idx]
    }

    private var filteredSnippets: [TextSnippet] {
        let trimmed = snippetSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return coordinator.profile.snippets }
        return coordinator.profile.snippets.filter { snippet in
            snippet.title.localizedCaseInsensitiveContains(trimmed) ||
            snippet.displayTitle(in: lang).localizedCaseInsensitiveContains(trimmed) ||
            snippet.body.localizedCaseInsensitiveContains(trimmed)
        }
    }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                autoSurfaceBanner

                slideSelectorStrip

                HStack(alignment: .top, spacing: 22) {
                    emojiSlideHardwarePreview

                    emojiCatalogPicker
                }

                snippetsStudioSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .sheet(item: $snippetEditorSession) { session in
            MacSnippetEditorSheet(coordinator: coordinator, session: session)
        }
    }

    private var autoSurfaceBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(coordinator.isEditingTextOnMac ? palette.statusConnected.opacity(0.16) : palette.tileFillBottom)
                    .frame(width: 44, height: 44)
                Image(systemName: coordinator.isEditingTextOnMac ? "character.cursor.ibeam" : "face.smiling.inverse")
                    .font(ChocType.title)
                    .foregroundStyle(coordinator.isEditingTextOnMac ? palette.statusConnected : palette.secondaryText)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("智能光标感知表情栏", "Smart Cursor-Aware Emoji Bar", language: lang))
                    .font(ChocType.body.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                if coordinator.isEditingTextOnMac, let appName = coordinator.focusedTextAppName {
                    Text(L10n.tr("检测到正在「\(appName)」中输入文字 — 已自动在伴侣设备上弹出表情栏！", "Typing detected in \(appName) — Emoji Bar automatically surfaced on companion!", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.statusConnected)
                } else {
                    Text(L10n.tr("在 Mac 任意文本框点击打字时，iPhone / iPad / Watch 会自动切换到表情栏。", "Automatically switches your companion to Emoji Bar whenever you focus a text field on Mac.", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                }
            }

            Spacer()

            Toggle(
                L10n.tr("打字时自动弹出", "Auto-Show When Typing", language: lang),
                isOn: Binding(
                    get: { coordinator.profile.settings.autoShowEmojiBarWhenTyping },
                    set: { val in
                        coordinator.mutateProfile { $0.settings.autoShowEmojiBarWhenTyping = val }
                    }
                )
            )
            .toggleStyle(.switch)
            .tint(palette.accent)
            .foregroundStyle(palette.primaryText)
        }
        .padding(14)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private var slideSelectorStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(coordinator.profile.emojiSlides) { slide in
                    let isSelected = (slide.index == coordinator.selectedEmojiSlideIndex)
                    let displayTitle = PageSwitcherTitleFormatter.displayTitle(
                        rawTitle: slide.title,
                        pageIndex: slide.index,
                        language: lang
                    )
                    Button {
                        coordinator.selectedEmojiSlideIndex = slide.index
                        selectedEmojiSlot = 0
                    } label: {
                        HStack(spacing: 5) {
                            Text(slide.iconEmoji)
                            MaxWidthPillTitleLayout(maxWidth: 108) {
                                Text(displayTitle)
                                    .font(ChocType.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .padding(.horizontal, isSelected ? 13 : 10)
                        .padding(.vertical, 6.5)
                        .foregroundStyle(isSelected ? palette.accent : palette.secondaryText)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emojiSlideHardwarePreview: some View {
        let slideIdx = currentSlide.index
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(
                    "Slide Title",
                    text: Binding(
                        get: { coordinator.profile.emojiSlides[slideIdx].title },
                        set: { newTitle in
                            coordinator.mutateProfile { $0.emojiSlides[slideIdx].title = newTitle }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 164)

                Spacer()

                Text(L10n.tr("选中格 #\(selectedEmojiSlot + 1) · 点击右侧替换", "Slot #\(selectedEmojiSlot + 1) · Pick right to replace", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<EmojiSlide.emojisPerSlide, id: \.self) { slotIdx in
                    let emoji = currentSlide.emojis[slotIdx]
                    let isSelected = (selectedEmojiSlot == slotIdx)

                    ZStack(alignment: .bottomTrailing) {
                        Button {
                            selectedEmojiSlot = slotIdx
                        } label: {
                            ZStack {
                                Text(emoji)
                                    .font(.system(size: 52))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 80)
                            .overlay(alignment: .bottom) {
                                if isSelected { Rectangle().fill(palette.accent).frame(width: 20, height: 2) }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            _ = coordinator.insertText(emoji, triggeredBy: "Mac Studio")
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .font(ChocType.micro)
                                .foregroundStyle(palette.secondaryText)
                                .frame(width: 22, height: 22)
                                .background(palette.backgroundBottom.opacity(0.65), in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                        .help(L10n.tr("发送到最近活动窗口", "Type into active Mac app", language: lang))
                    }
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [palette.barSurface, palette.barSurface],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: 420)
    }

    private var emojiCatalogPicker: some View {
        let activeCategory = EmojiCatalog.categories.first(where: { $0.id == selectedCategoryID })
            ?? EmojiCatalog.categories[0]

        let matchingEmoji = emojiSearch.isEmpty ? activeCategory.emojis : EmojiCatalog.categories.filter { $0.title(in: lang).localizedCaseInsensitiveContains(emojiSearch) || $0.emojis.contains(where: { $0.contains(emojiSearch) }) }.flatMap(\.emojis)
        return VStack(alignment: .leading, spacing: 10) {
            TextField(L10n.tr("搜索表情或分类", "Search emoji or category", language: lang), text: $emojiSearch)
                .textFieldStyle(.roundedBorder).frame(minHeight: 44)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EmojiCatalog.categories) { cat in
                        let isSel = (cat.id == selectedCategoryID)
                        Button {
                            selectedCategoryID = cat.id
                        } label: {
                            HStack(spacing: 4) {
                                Text(cat.icon)
                                Text(cat.title(in: lang))
                                    .font(ChocType.caption)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5.5)
                            .foregroundStyle(isSel ? palette.accent : palette.secondaryText)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(Array(Set(matchingEmoji)).sorted(), id: \.self) { emoji in
                        Button {
                            _ = coordinator.insertText(emoji)
                        } label: {
                            Text(emoji)
                                .font(ChocType.title)
                                .frame(width: 44, height: 44)
                                .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 0.8))
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.bordered)
                        .contextMenu {
                            Button(L10n.tr("填入槽位", "Assign to Slot", language: lang)) { assignEmojiToCurrentSlot(emoji) }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 216)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )

            HStack(spacing: 8) {
                TextField(
                    L10n.tr("或输入任意自定义 Emoji / 符号…", "Or enter any custom Emoji / symbol…", language: lang),
                    text: $customEmojiInput
                )
                .textFieldStyle(.roundedBorder)

                Button(L10n.tr("填入槽位", "Assign", language: lang)) {
                    let trimmed = customEmojiInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    assignEmojiToCurrentSlot(trimmed)
                    customEmojiInput = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.accentForeground)
                .disabled(customEmojiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func assignEmojiToCurrentSlot(_ emoji: String) {
        let slideIdx = currentSlide.index
        let slotIdx = selectedEmojiSlot
        coordinator.mutateProfile { draft in
            draft.emojiSlides[slideIdx].emojis[slotIdx] = emoji
            if slotIdx == 0 {
                draft.emojiSlides[slideIdx].iconEmoji = emoji
            }
        }
        selectedEmojiSlot = (slotIdx + 1) % EmojiSlide.emojisPerSlide
    }

    // MARK: - Snippet List (Add, Rename, Delete & Insert Mode)

    private var snippetsStudioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "text.quote")
                    .font(ChocType.title)
                    .foregroundStyle(palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(L10n.tr("文本片段", "Text Snippets", language: lang))
                            .font(ChocType.body.weight(.semibold))
                            .foregroundStyle(palette.primaryText)

                        Text("\(coordinator.profile.snippets.count)/\(TextSnippet.maxLibraryCount)")
                            .font(ChocType.micro.monospacedDigit())
                            .foregroundStyle(palette.secondaryText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(palette.tileFillBottom, in: Capsule())
                            .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                    }

                    Text(
                        L10n.tr(
                            "可放入触控栏槽位、底部常驻栏或 Mac 顶部悬浮栏，并在所有伴侣设备间自动同步。",
                            "Place snippets on bar slots, the pinned strip, or the Mac notch bar — synced across your devices.",
                            language: lang
                        )
                    )
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                }

                Spacer()

                if !coordinator.profile.snippets.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(ChocType.micro)
                            .foregroundStyle(palette.secondaryText)
                        TextField(
                            L10n.tr("搜索片段…", "Search snippets…", language: lang),
                            text: $snippetSearch
                        )
                        .textFieldStyle(.plain)
                        .frame(width: 150)

                        if !snippetSearch.isEmpty {
                            Button {
                                snippetSearch = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(palette.secondaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                }

                Button {
                    snippetEditorSession = .create
                } label: {
                    Label(L10n.tr("新建片段", "Add Snippet", language: lang), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.accentForeground)
                .controlSize(.small)
                .disabled(!coordinator.profile.canAddMoreSnippets)
                .accessibilityIdentifier("mac-emoji-studio-add-snippet")
            }

            if coordinator.profile.snippets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(ChocType.title)
                        .foregroundStyle(palette.secondaryText)
                    Text(L10n.tr("暂无保存的文本片段", "No Saved Snippets Yet", language: lang))
                        .font(ChocType.body.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                    Text(
                        L10n.tr(
                            "点击右上角「新建片段」保存常用回复、链接、签名或命令，随后可分配到任意槽位。",
                            "Click \"Add Snippet\" to save replies, links, signatures, or commands and assign them to any slot.",
                            language: lang
                        )
                    )
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            } else if filteredSnippets.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(palette.secondaryText)
                    Text(
                        L10n.tr(
                            "没有匹配「\(snippetSearch)」的文本片段",
                            "No snippets matching \"\(snippetSearch)\"",
                            language: lang
                        )
                    )
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Button(L10n.tr("清空搜索", "Clear", language: lang)) {
                        snippetSearch = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(14)
                .background(palette.tileFillTop, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(palette.subtleCardStroke, lineWidth: 1))
            } else {
                VStack(spacing: 8) {
                    ForEach(filteredSnippets) { snippet in
                        snippetRow(snippet)
                    }
                }
            }
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    private func snippetRow(_ snippet: TextSnippet) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ChocSwatch.resolvedTileColor(hex: "#F3EEFF"))
                    .frame(width: 36, height: 36)
                Image(systemName: snippet.insertMode.sfSymbol)
                    .font(ChocType.body.weight(.semibold))
                    .foregroundStyle(palette.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.displayTitle(in: lang))
                    .font(ChocType.body.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                Text(snippet.singleLinePreview)
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                ForEach(SnippetInsertMode.allCases) { mode in
                    Button {
                        _ = coordinator.setSnippetInsertMode(id: snippet.id, mode: mode)
                    } label: {
                        if snippet.insertMode == mode {
                            Label(mode.title(in: lang), systemImage: "checkmark")
                        } else {
                            Label(mode.title(in: lang), systemImage: mode.sfSymbol)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: snippet.insertMode.sfSymbol)
                        .font(ChocType.micro)
                    Text(snippet.insertMode.badgeTitle(in: lang))
                        .font(ChocType.micro)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.tileFillBottom, in: Capsule())
                .foregroundStyle(palette.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                _ = coordinator.runSnippetByID(
                    snippet.id,
                    fallbackName: snippet.displayTitle(in: lang),
                    triggeredBy: "Mac Studio"
                )
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.accent)
                    .frame(width: 28, height: 28)
                    .background(palette.tileFillBottom, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("发送到当前聚焦输入框", "Insert into focused Mac app", language: lang))

            Button {
                snippetEditorSession = .rename(snippet)
            } label: {
                Label(L10n.tr("重命名", "Rename", language: lang), systemImage: "pencil.line")
                    .font(ChocType.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("mac-snippet-rename-\(snippet.id.uuidString)")

            Button {
                snippetEditorSession = .edit(snippet)
            } label: {
                Label(L10n.tr("编辑", "Edit", language: lang), systemImage: "square.and.pencil")
                    .font(ChocType.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("mac-snippet-edit-\(snippet.id.uuidString)")

            Menu {
                ForEach(Array(coordinator.profile.pages.enumerated()), id: \.element.id) { pIdx, page in
                    Menu("\(page.iconEmoji) \(page.title)") {
                        ForEach(0..<BarPage.slotsPerPage, id: \.self) { sIdx in
                            let currentLabel = coordinator.profile.pages[pIdx].slots[sIdx].map {
                                coordinator.profile.displayTitle(for: $0, in: lang)
                            } ?? L10n.tr("空槽位", "Empty", language: lang)
                            Button("#\(sIdx + 1) · \(currentLabel)") {
                                coordinator.assignSnippetToSlot(snippet, pageIndex: pIdx, slotIndex: sIdx)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
            .help(L10n.tr("放入触控栏槽位", "Assign to Bar Slot", language: lang))

            Button(role: .destructive) {
                _ = coordinator.deleteSnippet(id: snippet.id)
            } label: {
                Image(systemName: "trash")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.statusFailure)
                    .frame(width: 28, height: 28)
                    .background(palette.tileFillBottom, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("删除片段", "Delete Snippet", language: lang))
            .accessibilityIdentifier("mac-snippet-delete-\(snippet.id.uuidString)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            LinearGradient(
                colors: [palette.tileFillTop, palette.tileFillBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .contextMenu {
            Button {
                snippetEditorSession = .rename(snippet)
            } label: {
                Label(L10n.tr("重命名…", "Rename…", language: lang), systemImage: "pencil.line")
            }

            Button {
                snippetEditorSession = .edit(snippet)
            } label: {
                Label(L10n.tr("编辑内容…", "Edit Snippet…", language: lang), systemImage: "square.and.pencil")
            }

            Divider()

            Button(role: .destructive) {
                _ = coordinator.deleteSnippet(id: snippet.id)
            } label: {
                Label(L10n.tr("删除", "Delete", language: lang), systemImage: "trash")
            }
        }
    }
}

// MARK: - Mac Snippet Editor / Rename Sheet (macOS 13 SwiftUI)

enum MacSnippetEditorSession: Identifiable {
    case create
    case rename(TextSnippet)
    case edit(TextSnippet)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .rename(let snippet):
            return "rename-\(snippet.id.uuidString)"
        case .edit(let snippet):
            return "edit-\(snippet.id.uuidString)"
        }
    }
}

struct MacSnippetEditorSheet: View {
    @ObservedObject var coordinator: MacAppCoordinator
    let session: MacSnippetEditorSession
    @Environment(\.dismiss) private var dismiss

    @State private var titleText: String = ""
    @State private var bodyText: String = ""
    @State private var selectedInsertMode: SnippetInsertMode = .focusedFieldInsert

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    private var existingSnippet: TextSnippet? {
        switch session {
        case .create:
            return nil
        case .rename(let snippet), .edit(let snippet):
            return snippet
        }
    }

    private var isRenameOnly: Bool {
        if case .rename = session { return true }
        return false
    }

    private var canSave: Bool {
        if isRenameOnly {
            return existingSnippet != nil
        }
        if existingSnippet == nil && !coordinator.profile.canAddMoreSnippets {
            return false
        }
        return !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sheetTitle: String {
        switch session {
        case .create:
            return L10n.tr("新建文本片段", "New Snippet", language: lang)
        case .rename:
            return L10n.tr("重命名文本片段", "Rename Snippet", language: lang)
        case .edit:
            return L10n.tr("编辑文本片段", "Edit Snippet", language: lang)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(sheetTitle)
                    .font(ChocType.title)
                    .foregroundStyle(palette.primaryText)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.tr("名称（可选）", "Title (optional)", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                    Text("\(titleText.count)/\(TextSnippet.maxTitleLength)")
                        .font(ChocType.micro.monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                }

                TextField(
                    L10n.tr("最多 40 个字符，留空则取首行文字", "Max 40 characters (blank uses first line)", language: lang),
                    text: Binding(
                        get: { titleText },
                        set: { titleText = TextSnippet.clampTitle($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if isRenameOnly {
                        saveAndDismiss()
                    }
                }
            }

            if !isRenameOnly {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.tr("片段内容", "Snippet Body", language: lang))
                            .font(ChocType.caption)
                            .foregroundStyle(palette.secondaryText)
                        Spacer()
                        Text("\(bodyText.count)/\(TextSnippet.maxBodyLength)")
                            .font(ChocType.micro.monospacedDigit())
                            .foregroundStyle(palette.secondaryText)
                    }

                    TextEditor(
                        text: Binding(
                            get: { bodyText },
                            set: { bodyText = TextSnippet.clampBody($0) }
                        )
                    )
                    .font(ChocType.body)
                    .foregroundStyle(palette.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 130)
                    .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                    )

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(SnippetPlaceholderToken.allCases) { placeholder in
                                let canAppend = bodyText.count + placeholder.rawValue.count <= TextSnippet.maxBodyLength
                                Button {
                                    bodyText = SnippetPlaceholderExpander.appendToken(placeholder, to: bodyText)
                                } label: {
                                    Text(placeholder.rawValue)
                                        .font(ChocType.micro.monospaced())
                                        .foregroundStyle(canAppend ? palette.primaryText : palette.secondaryText.opacity(0.5))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(palette.tileFillBottom, in: Capsule())
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                                        )
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(!canAppend)
                                .accessibilityIdentifier("mac-snippet-token-\(placeholder.name)")
                            }
                        }
                    }

                    let previewLine = SnippetPlaceholderExpander.preview(bodyText)
                    HStack(spacing: 6) {
                        Text(L10n.tr("今日预览：", "Preview:", language: lang))
                            .font(ChocType.micro)
                            .foregroundStyle(palette.secondaryText)
                        Text(previewLine.isEmpty ? "—" : previewLine)
                            .font(ChocType.micro)
                            .foregroundStyle(previewLine.isEmpty ? palette.secondaryText : palette.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mac-snippet-expansion-preview")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("输入模式", "Insert Mode", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)

                    Picker("", selection: $selectedInsertMode) {
                        ForEach(SnippetInsertMode.allCases) { mode in
                            Text(mode.badgeTitle(in: lang)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(selectedInsertMode.subtitle(in: lang))
                        .font(ChocType.micro)
                        .foregroundStyle(palette.secondaryText)
                }
            }

            HStack {
                if let existing = existingSnippet {
                    Button(role: .destructive) {
                        _ = coordinator.deleteSnippet(id: existing.id)
                        dismiss()
                    } label: {
                        Label(L10n.tr("删除", "Delete", language: lang), systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.statusFailure)
                }

                Spacer()

                Button(L10n.tr("取消", "Cancel", language: lang)) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.tr("保存", "Save", language: lang)) {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.accentForeground)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480)
        .background(
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onAppear {
            if let existing = existingSnippet {
                titleText = existing.title
                bodyText = existing.body
                selectedInsertMode = existing.insertMode
            } else {
                selectedInsertMode = .focusedFieldInsert
            }
        }
    }

    private func saveAndDismiss() {
        guard canSave else { return }
        switch session {
        case .create:
            let created = TextSnippet(
                title: TextSnippet.resolvedTitle(title: titleText, body: bodyText, language: lang),
                body: bodyText,
                insertMode: selectedInsertMode,
                updatedAt: Date()
            )
            guard coordinator.saveSnippet(created) else { return }
        case .rename(let existing):
            guard coordinator.renameSnippet(id: existing.id, title: titleText) else { return }
        case .edit(let existing):
            let updated = TextSnippet(
                id: existing.id,
                title: TextSnippet.resolvedTitle(title: titleText, body: bodyText, language: lang),
                body: bodyText,
                insertMode: selectedInsertMode,
                updatedAt: Date()
            )
            guard coordinator.saveSnippet(updated) else { return }
        }
        dismiss()
    }
}
