import ChocliftCore
import SwiftUI

public struct EmojiBarStudioView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @State private var selectedEmojiSlot: Int = 0
    @State private var selectedCategoryID: String = EmojiCatalog.categories.first?.id ?? "popular"
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
        VStack(spacing: 18) {
            autoSurfaceBanner

            slideSelectorStrip

            HStack(alignment: .top, spacing: 22) {
                emojiSlideHardwarePreview

                emojiCatalogPicker
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
    }

    private var autoSurfaceBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: coordinator.isEditingTextOnMac ? "character.cursor.ibeam" : "face.smiling.inverse")
                .font(.title2)
                .foregroundStyle(coordinator.isEditingTextOnMac ? .green : palette.accentGold)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("智能光标感知表情栏 (Pick emojis right where you type)", "Smart Cursor-Aware Emoji Bar", language: lang))
                    .font(.subheadline.bold())
                if coordinator.isEditingTextOnMac, let appName = coordinator.focusedTextAppName {
                    Text(L10n.tr("检测到正在「\(appName)」中输入文字 — 已自动在 iPhone 上弹出表情栏！", "Typing detected in \(appName) — Emoji Bar automatically surfaced on companion!", language: lang))
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(L10n.tr("当你在 Mac 任意输入框点击打字时，iPhone / iPad 会自动切换到表情栏，轻点即可输入。", "Automatically switches your iPhone/iPad to Emoji Bar whenever you click into a text field on Mac.", language: lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var slideSelectorStrip: some View {
        HStack(spacing: 8) {
            ForEach(coordinator.profile.emojiSlides) { slide in
                let isSelected = (slide.index == coordinator.selectedEmojiSlideIndex)
                Button {
                    coordinator.selectedEmojiSlideIndex = slide.index
                    selectedEmojiSlot = 0
                } label: {
                    HStack(spacing: 5) {
                        Text(slide.iconEmoji)
                        if isSelected {
                            Text(slide.title)
                                .font(.caption.bold())
                        } else {
                            Text("\(slide.index + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, isSelected ? 12 : 9)
                    .padding(.vertical, 6)
                    .background(isSelected ? palette.tileFillTop : Color.primary.opacity(0.05), in: Capsule())
                    .foregroundStyle(isSelected ? palette.primaryText : .primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
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
                .frame(width: 160)

                Spacer()

                Text(L10n.tr("选中格 #\(selectedEmojiSlot + 1)，点击右侧替换", "Selected #\(selectedEmojiSlot + 1) — pick on right", language: lang))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<EmojiSlide.emojisPerSlide, id: \.self) { slotIdx in
                    let emoji = currentSlide.emojis[slotIdx]
                    let isSelected = (selectedEmojiSlot == slotIdx)

                    Button {
                        selectedEmojiSlot = slotIdx
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [palette.tileFillTop, palette.tileFillBottom],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? palette.accentGold : palette.tileBorderHighlight.opacity(0.45),
                                            lineWidth: isSelected ? 2.5 : 1
                                        )
                                )

                            Text(emoji)
                                .font(.system(size: 36))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            Button {
                                _ = coordinator.executeEmojiInsertion(emoji, triggeredBy: "Mac Studio")
                            } label: {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(palette.secondaryText)
                                    .padding(5)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.tr("发送到最近活动窗口", "Type into active Mac app", language: lang))
                        }
                        .aspectRatio(1.0, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [palette.backgroundTop, palette.backgroundBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
        }
        .frame(maxWidth: 420)
    }

    private var emojiCatalogPicker: some View {
        let activeCategory = EmojiCatalog.categories.first(where: { $0.id == selectedCategoryID })
            ?? EmojiCatalog.categories[0]

        return VStack(alignment: .leading, spacing: 10) {
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
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSel ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(activeCategory.emojis, id: \.self) { emoji in
                        Button {
                            assignEmojiToCurrentSlot(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 24))
                                .frame(width: 36, height: 36)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 210)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                TextField(
                    L10n.tr("或输入任意自定义 Emoji / 颜文字…", "Or enter any custom Emoji / symbol…", language: lang),
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
