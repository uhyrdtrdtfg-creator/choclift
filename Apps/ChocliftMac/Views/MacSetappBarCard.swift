import AppKit
import ChocliftCore
import SwiftUI

public struct MacSetappBarCard: View {
    @ObservedObject var coordinator: MacAppCoordinator
    private var pairingCodeOverride: String?
    private var externalBarBook: Binding<SetappBarBook>?
    private var initialEmojiBook: EmojiBarBook?
    private var showInDockBinding: Binding<Bool>?
    public var onSaveEmojiBar: (EmojiBarBook) -> Void

    @State private var localBarBookOverride: SetappBarBook?
    @State private var draftEmojiBook: EmojiBarBook?

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    public init(
        coordinator: MacAppCoordinator,
        pairingCode: String? = nil,
        barBook: Binding<SetappBarBook>? = nil,
        emojiBook: EmojiBarBook? = nil,
        showInDockBinding: Binding<Bool>? = nil,
        onSaveEmojiBar: ((EmojiBarBook) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.pairingCodeOverride = pairingCode
        self.externalBarBook = barBook
        self.initialEmojiBook = emojiBook
        self.showInDockBinding = showInDockBinding
        self.onSaveEmojiBar = onSaveEmojiBar ?? { savedBook in
            Self.applySavedEmojiBook(savedBook, to: coordinator)
        }
    }

    private var resolvedFourDigitPairingCode: String? {
        if let override = pairingCodeOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           override.count == 4,
           override.allSatisfy(\.isNumber) {
            return override
        }
        let serverPIN = coordinator.server.currentPIN.trimmingCharacters(in: .whitespacesAndNewlines)
        if serverPIN.count == 4, serverPIN.allSatisfy(\.isNumber) {
            return serverPIN
        }
        return nil
    }

    private var activeBarBook: SetappBarBook {
        if let externalBarBook {
            return externalBarBook.wrappedValue
        }
        if let localBarBookOverride {
            return localBarBookOverride
        }
        return Self.makeBarBook(from: coordinator.profile)
    }

    private var activeEmojiBook: EmojiBarBook {
        if let draftEmojiBook {
            return draftEmojiBook
        }
        if let initialEmojiBook {
            return initialEmojiBook
        }
        return Self.makeEmojiBook(from: coordinator.profile.emojiSlides)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow
            pairingCodeSection
            Divider()
            pageListSection
            Divider()
            emojiBarSection
            Divider()
            settingsTogglesSection
        }
        .padding(16)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("mac-setapp-bar-card")
    }

    // MARK: - Header & 4-Digit Pairing Code

    private var headerRow: some View {
        HStack(spacing: 10) {
            Label(
                L10n.tr("choclift 栏", "choclift bar", language: lang),
                systemImage: "square.grid.2x2.fill"
            )
            .font(ChocType.title)
            .foregroundStyle(palette.primaryText)

            Spacer(minLength: 8)
        }
    }

    private var pairingCodeSection: some View {
        let codeText = resolvedFourDigitPairingCode ?? "PIN"

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    L10n.tr(
                        "在你的配套 App 中输入此代码",
                        "Enter this code on your companion app",
                        language: lang
                    )
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.primaryText)

                Text(
                    L10n.tr(
                        "请确保你的 Mac 和 iPhone 连接到同一 Wi-Fi 网络。",
                        "Make sure your Mac and iPhone are connected to the same Wi-Fi network.",
                        language: lang
                    )
                )
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)
            }

            Spacer(minLength: 8)

            Text(codeText)
                .font(ChocType.title.monospacedDigit())
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
                )
                .accessibilityIdentifier("mac-setapp-pairing-code")
        }
    }

    // MARK: - Page List (Clear Page, Move Page Up / Down)

    private var pageListSection: some View {
        let pageCount = SetappBarBook.pageCount

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(
                    L10n.tr(
                        "在 Mac App 中自定义 choclift Bar，最多 8 页",
                        "Use the Mac app to customize your choclift bar with up to eight pages",
                        language: lang
                    )
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)

                Spacer()
            }

            VStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { pageIdx in
                    pageRow(pageIndex: pageIdx, totalCount: pageCount)
                }
            }
        }
        .accessibilityIdentifier("mac-setapp-page-list")
    }

    private func pageRow(pageIndex: Int, totalCount: Int) -> some View {
        let setappPage = activeBarBook.page(at: pageIndex)
            ?? SetappBarPage(index: pageIndex, layout: .one)
        let profilePage = coordinator.profile.pages.indices.contains(pageIndex)
            ? coordinator.profile.pages[pageIndex]
            : nil
        let filledCount: Int = {
            if externalBarBook != nil || localBarBookOverride != nil {
                return setappPage.slots.filter { !$0.isEmpty }.count
            }
            if let profilePage {
                return profilePage.slots.compactMap { $0 }.count
            }
            return setappPage.slots.filter { !$0.isEmpty }.count
        }()
        let pageLabel = L10n.tr("第 \(pageIndex + 1) 页", "Page \(pageIndex + 1)", language: lang)
        let customTitle = profilePage?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return HStack(spacing: 10) {
            Text("\(pageIndex + 1)")
                .font(ChocType.micro.monospacedDigit())
                .foregroundStyle(palette.secondaryText)
                .frame(width: 20, height: 20)
                .background(palette.barSurface, in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(pageLabel)
                        .font(ChocType.body.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                    if !customTitle.isEmpty && externalBarBook == nil {
                        Text("· \(customTitle)")
                            .font(ChocType.caption)
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                }
                Text(
                    filledCount == 0
                        ? L10n.tr("空白", "Empty", language: lang)
                        : L10n.tr("已放置 \(filledCount) 项", "\(filledCount) filled", language: lang)
                )
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)
            }

            Spacer(minLength: 8)

            Button {
                movePage(at: pageIndex, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(pageIndex <= 0)
            .help(L10n.tr("移动页面（上移）", "Move Page Up", language: lang))
            .accessibilityLabel(L10n.tr("上移第 \(pageIndex + 1) 页", "Move Page \(pageIndex + 1) Up", language: lang))
            .accessibilityIdentifier("mac-setapp-page-up-\(pageIndex)")

            Button {
                movePage(at: pageIndex, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(pageIndex >= totalCount - 1)
            .help(L10n.tr("移动页面（下移）", "Move Page Down", language: lang))
            .accessibilityLabel(L10n.tr("下移第 \(pageIndex + 1) 页", "Move Page \(pageIndex + 1) Down", language: lang))
            .accessibilityIdentifier("mac-setapp-page-down-\(pageIndex)")

            Button(role: .destructive) {
                clearPage(at: pageIndex)
            } label: {
                Text(L10n.tr("清空页面", "Clear Page", language: lang))
                    .font(ChocType.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(palette.statusFailure)
            .disabled(filledCount == 0)
            .accessibilityIdentifier("mac-setapp-page-clear-\(pageIndex)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    // MARK: - Emoji Bar (8 Slides x 8 Single-Emoji TextFields + Save Button)

    private var emojiBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(
                    L10n.tr("自定义 Emoji Bar", "Customize Emoji Bar", language: lang),
                    systemImage: "face.smiling.inverse"
                )
                .font(ChocType.title)
                .foregroundStyle(palette.primaryText)

                Spacer(minLength: 8)

                Button {
                    let sanitized = activeEmojiBook.sanitized()
                    draftEmojiBook = sanitized
                    onSaveEmojiBar(sanitized)
                } label: {
                    Text(L10n.tr("保存", "Save", language: lang))
                        .font(ChocType.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .foregroundStyle(palette.accentForeground)
                .controlSize(.small)
                .accessibilityIdentifier("mac-setapp-emoji-save")
            }

            Text(
                L10n.tr(
                    "Emoji Bar 提供 8 个可自定义行，最多可放置 64 个表情。",
                    "8 customizable slides in your Emoji Bar to pick from up to 64 emojis.",
                    language: lang
                )
            )
            .font(ChocType.caption)
            .foregroundStyle(palette.secondaryText)

            VStack(spacing: 6) {
                ForEach(0..<EmojiBarBook.slideCount, id: \.self) { slideIdx in
                    let isEmptySlide = activeEmojiBook.isSlideEmpty(slideIdx)
                    HStack(spacing: 6) {
                        Text(L10n.tr("幻灯片 \(slideIdx + 1)", "Slide \(slideIdx + 1)", language: lang))
                            .font(ChocType.micro.monospacedDigit())
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 68, alignment: .leading)

                        ForEach(0..<EmojiBarBook.emojisPerSlide, id: \.self) { slotIdx in
                            TextField(
                                "·",
                                text: emojiSlotBinding(slide: slideIdx, index: slotIdx)
                            )
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .font(ChocType.body)
                            .frame(width: 36)
                            .accessibilityIdentifier("mac-setapp-emoji-\(slideIdx)-\(slotIdx)")
                        }

                        Button {
                            var updated = activeEmojiBook
                            updated.clear(slide: slideIdx)
                            draftEmojiBook = updated
                        } label: {
                            Text(L10n.tr("清除", "Clear", language: lang))
                                .font(ChocType.micro)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(isEmptySlide)
                        .accessibilityIdentifier("mac-setapp-emoji-clear-slide-\(slideIdx)")

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
            .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )
        }
        .accessibilityIdentifier("mac-setapp-emoji-section")
    }

    private func emojiSlotBinding(slide: Int, index: Int) -> Binding<String> {
        Binding(
            get: {
                activeEmojiBook.emoji(slide: slide, index: index) ?? ""
            },
            set: { rawInput in
                var updated = activeEmojiBook
                let previous = updated.emoji(slide: slide, index: index) ?? ""
                let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    updated.clearSlot(slide: slide, index: index)
                    draftEmojiBook = updated
                    return
                }
                let candidate: String
                if trimmed.count > 1, !previous.isEmpty, trimmed.hasPrefix(previous) {
                    candidate = String(trimmed.dropFirst(previous.count).prefix(1))
                } else {
                    candidate = String(trimmed.prefix(1))
                }
                if let valid = EmojiBarBook.validateEmoji(candidate) {
                    _ = updated.set(slide: slide, index: index, emoji: valid)
                    draftEmojiBook = updated
                }
            }
        )
    }

    // MARK: - Settings Toggles (Open at Login, Show in Dock)

    private var settingsTogglesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                L10n.tr("登录时打开", "Open at Login", language: lang),
                isOn: Binding(
                    get: { coordinator.launchAtLoginEnabled },
                    set: { coordinator.setLaunchAtLogin($0) }
                )
            )
            .tint(palette.accent)
            .accessibilityIdentifier("mac-setapp-open-at-login-toggle")

            if let showInDockBinding {
                Toggle(
                    L10n.tr("在程序坞中显示", "Show in Dock", language: lang),
                    isOn: showInDockBinding
                )
                .tint(palette.accent)
                .accessibilityIdentifier("mac-setapp-show-in-dock-toggle")
            } else {
                Toggle(
                    L10n.tr("在程序坞中显示", "Show in Dock", language: lang),
                    isOn: .constant(true)
                )
                .tint(palette.accent)
                .disabled(true)
                .foregroundStyle(palette.secondaryText)
                .accessibilityIdentifier("mac-setapp-show-in-dock-toggle")
            }
        }
    }

    // MARK: - Page & Emoji Actions

    private func movePage(at pageIndex: Int, offset: Int) {
        let targetIndex = pageIndex + offset
        guard (0..<SetappBarBook.pageCount).contains(pageIndex),
              (0..<SetappBarBook.pageCount).contains(targetIndex) else {
            return
        }
        if let externalBarBook {
            var next = externalBarBook.wrappedValue
            _ = next.movePage(from: pageIndex, to: targetIndex)
            externalBarBook.wrappedValue = next
            return
        }
        if var overrideBook = localBarBookOverride {
            _ = overrideBook.movePage(from: pageIndex, to: targetIndex)
            localBarBookOverride = overrideBook
        }
        let direction: PageReorderDirection = offset < 0 ? .left : .right
        _ = coordinator.movePage(at: pageIndex, direction: direction)
    }

    private func clearPage(at pageIndex: Int) {
        guard (0..<SetappBarBook.pageCount).contains(pageIndex) else { return }
        if let externalBarBook {
            var next = externalBarBook.wrappedValue
            _ = next.clearPage(index: pageIndex)
            externalBarBook.wrappedValue = next
            return
        }
        if var overrideBook = localBarBookOverride {
            _ = overrideBook.clearPage(index: pageIndex)
            localBarBookOverride = overrideBook
        }
        if coordinator.profile.pages.indices.contains(pageIndex) {
            coordinator.mutateProfile { draft in
                guard draft.pages.indices.contains(pageIndex) else { return }
                for slotIdx in draft.pages[pageIndex].slots.indices {
                    _ = draft.setSlotItem(nil, pageIndex: pageIndex, slotIndex: slotIdx)
                }
            }
            coordinator.flashBanner(
                L10n.tr(
                    "已清空第 \(pageIndex + 1) 页",
                    "Cleared Page \(pageIndex + 1)",
                    language: lang
                )
            )
        }
    }

    private static func makeBarBook(from profile: ChocliftWorkspaceProfile) -> SetappBarBook {
        var pages: [SetappBarPage] = []
        pages.reserveCapacity(SetappBarBook.pageCount)
        for pageIdx in 0..<SetappBarBook.pageCount {
            let sourceSlots: [BarItem?] = profile.pages.indices.contains(pageIdx)
                ? Array(profile.pages[pageIdx].slots.prefix(SetappBarTileLayout.four.slotCount))
                : []
            let mapped = sourceSlots.map { item -> SetappBarSlot in
                guard let item else { return .empty }
                switch item.kind {
                case .macApp(let bundleID, let appName, _, _):
                    return SetappBarSlot.app(bundleID: bundleID, displayName: appName) ?? .empty
                case .shortcut(let shortcutName, let emoji, _):
                    return SetappBarSlot.shortcut(shortcutName: shortcutName, emoji: emoji, displayName: shortcutName) ?? .empty
                case .website(let url, let title, _, _, _):
                    return SetappBarSlot.website(urlString: url, displayName: title) ?? .empty
                case .snippet(_, _, let emoji, _):
                    return SetappBarSlot.emoji(emoji) ?? .empty
                default:
                    return .empty
                }
            }
            let filled = mapped.filter { !$0.isEmpty }.count
            let layout: SetappBarTileLayout = {
                switch filled {
                case 4...: return .four
                case 3: return .three
                case 2: return .two
                default: return .one
                }
            }()
            pages.append(SetappBarPage(index: pageIdx, layout: layout, slots: mapped))
        }
        return SetappBarBook(pages: pages)
    }

    private static func makeEmojiBook(from slides: [EmojiSlide]) -> EmojiBarBook {
        let rawSlides: [[String]] = (0..<EmojiBarBook.slideCount).map { slideIdx in
            guard slides.indices.contains(slideIdx) else {
                return Array(repeating: "", count: EmojiBarBook.emojisPerSlide)
            }
            return Array(slides[slideIdx].emojis.prefix(EmojiBarBook.emojisPerSlide))
        }
        return EmojiBarBook(slides: rawSlides)
    }

    private static func applySavedEmojiBook(_ savedBook: EmojiBarBook, to coordinator: MacAppCoordinator) {
        let sanitized = savedBook.sanitized()
        let fallbackDefaults = ChocliftDefaults.makeDefaultEmojiSlides()
        coordinator.mutateProfile { draft in
            var updatedSlides = draft.emojiSlides
            while updatedSlides.count < EmojiBarBook.slideCount {
                let idx = updatedSlides.count
                let fallback = fallbackDefaults.indices.contains(idx)
                    ? fallbackDefaults[idx]
                    : EmojiSlide(index: idx, title: "Slide \(idx + 1)", iconEmoji: "⭐️", emojis: [])
                updatedSlides.append(fallback)
            }
            for slideIdx in 0..<EmojiBarBook.slideCount {
                var mergedEmojis = updatedSlides[slideIdx].emojis
                while mergedEmojis.count < EmojiBarBook.emojisPerSlide {
                    mergedEmojis.append("🍫")
                }
                for slotIdx in 0..<EmojiBarBook.emojisPerSlide {
                    if let valid = sanitized.emoji(slide: slideIdx, index: slotIdx) {
                        mergedEmojis[slotIdx] = valid
                    }
                }
                updatedSlides[slideIdx].emojis = Array(mergedEmojis.prefix(EmojiBarBook.emojisPerSlide))
            }
            draft.emojiSlides = updatedSlides
        }
        coordinator.flashBanner(
            L10n.tr("已保存 Emoji Bar", "Saved Emoji Bar", language: coordinator.lang)
        )
    }
}
