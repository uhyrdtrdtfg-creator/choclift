import ChocliftCore
import SwiftUI

public struct EmojiBarStudioView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @State private var selectedEmojiSlot: Int = 0
    @State private var selectedCategoryID: String = EmojiCatalog.categories.first?.id ?? "popular"
    @State private var emojiSearch = ""
    @State private var customEmojiInput: String = ""

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    private var currentSlide: EmojiSlide {
        let idx = min(max(0, coordinator.selectedEmojiSlideIndex), coordinator.profile.emojiSlides.count - 1)
        return coordinator.profile.emojiSlides[idx]
    }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 16) {
            autoSurfaceBanner

            slideSelectorStrip

            HStack(alignment: .top, spacing: 22) {
                emojiSlideHardwarePreview

                emojiCatalogPicker
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
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
}
