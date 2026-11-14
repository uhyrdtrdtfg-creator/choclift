import ChocliftCore
import SwiftUI

// MARK: - 1. iPhone & iPad Local Soundboard Surface (Round 3)

public struct IOSSoundboardSurfaceView: View {
    @ObservedObject var client: CompanionClientEngine
    let currentBarPageIndex: Int
    let isLandscape: Bool
    var onPromptHUD: ((String) -> Void)?
    var onRequestPairing: (() -> Void)?

    @State private var searchQuery: String = ""
    @State private var pressedPadID: String?
    @State private var soundboardDragLevel: Double?
    @State private var volumeThrottle = ControlLevelDragThrottle()
    @State private var lastNonZeroSoundboardVolume: Double = SoundboardClip.defaultVolume
    @FocusState private var isSoundSearchFocused: Bool

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    private var allClips: [SoundboardClip] { client.profile.soundboardClips }

    private var filteredClips: [SoundboardClip] {
        SoundboardSearch.filter(allClips, query: searchQuery)
    }

    private var effectiveSoundboardVolume: Double {
        ControlStripLevel.clamp(soundboardDragLevel ?? client.controlStripState.soundboardVolume)
    }

    public init(
        client: CompanionClientEngine,
        currentBarPageIndex: Int,
        isLandscape: Bool,
        onPromptHUD: ((String) -> Void)? = nil,
        onRequestPairing: (() -> Void)? = nil
    ) {
        self.client = client
        self.currentBarPageIndex = currentBarPageIndex
        self.isLandscape = isLandscape
        self.onPromptHUD = onPromptHUD
        self.onRequestPairing = onRequestPairing
    }

    public var body: some View {
        Group {
            if allClips.isEmpty {
                emptyBoardState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        headerBar
                        soundboardVolumeCard
                        soundSearchField
                        if filteredClips.isEmpty { noMatchingSoundsState } else { soundPadGrid }
                    }
                }
            }
        }
        .onAppear {
            let initial = ControlStripLevel.clamp(client.controlStripState.soundboardVolume)
            if initial > 0.02 {
                lastNonZeroSoundboardVolume = initial
            }
        }
        .onChange(of: client.controlStripState.soundboardVolume) { _, updated in
            if updated > 0.02 {
                lastNonZeroSoundboardVolume = updated
            }
        }
    }

    // MARK: - Header & Cap Badges

    private var headerBar: some View {
        HStack(spacing: 8) {
            Label(
                L10n.tr("本机音效板", "Mac Soundboard", language: lang),
                systemImage: "speaker.wave.2.bubble.left.fill"
            )
            .font(ChocType.body.weight(.semibold))
            .foregroundStyle(palette.primaryText)

            Text("\(allClips.count)/\(SoundboardClip.maxBoardCount)")
                .font(ChocType.micro)
                .foregroundStyle(
                    allClips.count >= SoundboardClip.maxBoardCount
                        ? palette.emphasisForeground
                        : palette.secondaryText
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    allClips.count >= SoundboardClip.maxBoardCount
                        ? palette.accentEmphasis
                        : palette.tileFillBottom,
                    in: Capsule()
                )
                .accessibilityIdentifier("ios-soundboard-cap-pill")

            Text("≤ 8s")
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(palette.tileFillBottom, in: Capsule())

            Spacer(minLength: 4)

            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                if client.connectionState.isConnected {
                    client.stopSoundboardPlayback()
                    onPromptHUD?(L10n.tr("已停止音效播放", "Stopped Soundboard", language: lang))
                } else {
                    client.lastFeedback = CompanionFeedbackToast(
                        success: false,
                        title: L10n.tr("音效板", "Soundboard", language: lang),
                        detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                    )
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(ChocType.micro)
                    Text(L10n.tr("停止", "Stop", language: lang))
                        .font(ChocType.micro)
                }
                .foregroundStyle(palette.primaryText)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(palette.tileFillTop, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-soundboard-stop-button")
        }
    }

    // MARK: - Separate Soundboard Volume Slider (Independent of System Volume)

    private var soundboardVolumeCard: some View {
        let pct = ControlStripLevel.percentage(for: effectiveSoundboardVolume)
        let isSilent = effectiveSoundboardVolume <= 0.005

        return HStack(spacing: 8) {
            Button {
                CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                if isSilent {
                    let restored = max(0.2, lastNonZeroSoundboardVolume)
                    client.setSoundboardVolume(restored)
                } else {
                    lastNonZeroSoundboardVolume = effectiveSoundboardVolume
                    client.setSoundboardVolume(0.0)
                }
            } label: {
                Image(systemName: isSilent ? "speaker.slash.fill" : "waveform.circle.fill")
                    .font(ChocType.body.weight(.semibold))
                    .foregroundStyle(isSilent ? palette.statusFailure : palette.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        isSilent ? palette.statusFailure.opacity(0.14) : palette.tileFillBottom,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isSilent ? palette.statusFailure.opacity(0.45) : palette.subtleCardStroke,
                                lineWidth: 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ios-soundboard-volume-mute")
            .accessibilityLabel(L10n.tr("音效板静音开关", "Toggle Soundboard Mute", language: lang))

            Text(L10n.tr("音效音量", "Pad Vol", language: lang))
                .font(ChocType.micro)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Slider(
                value: Binding(
                    get: { effectiveSoundboardVolume },
                    set: { newVal in
                        let clamped = ControlStripLevel.clamp(newVal)
                        soundboardDragLevel = clamped
                        let now = ProcessInfo.processInfo.systemUptime
                        if let throttled = volumeThrottle.updateDrag(to: clamped, at: now) {
                            client.setSoundboardVolume(throttled)
                        }
                    }
                ),
                in: 0.0...1.0,
                onEditingChanged: { isEditing in
                    if !isEditing, let finalVal = soundboardDragLevel {
                        let now = ProcessInfo.processInfo.systemUptime
                        let committed = volumeThrottle.endDrag(at: finalVal, at: now)
                        client.setSoundboardVolume(committed)
                        soundboardDragLevel = nil
                    }
                }
            )
            .tint(palette.accent)
            .accessibilityIdentifier("ios-soundboard-volume-slider")
            .accessibilityLabel(L10n.tr("音效板独立音量", "Soundboard Volume", language: lang))

            Text("\(pct)%")
                .font(ChocType.micro)
                .monospacedDigit()
                .foregroundStyle(isSilent ? palette.secondaryText : palette.primaryText)
                .frame(minWidth: 34, alignment: .trailing)
                .accessibilityIdentifier("ios-soundboard-volume-level")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(palette.barSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios-soundboard-volume-bar")
    }

    // MARK: - Sound Name Search Field (Pure Filter — Never Auto-Plays)

    private var soundSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)

            TextField(
                L10n.tr("搜索音效名称…", "Search sound names…", language: lang),
                text: $searchQuery
            )
            .font(ChocType.body)
            .foregroundStyle(palette.primaryText)
            .focused($isSoundSearchFocused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.done)
            .onSubmit {
                // Only dismisses keyboard focus; sound search never auto-plays.
                isSoundSearchFocused = false
            }
            .accessibilityIdentifier("ios-soundboard-search-field")

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(ChocType.body)
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ios-soundboard-search-clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(palette.barSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
        )
    }

    // MARK: - Pad Grid & Empty States

    private var soundPadGrid: some View {
        let colCount = isLandscape ? 6 : 4
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: colCount)

        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(filteredClips) { clip in
                soundPadButton(clip)
            }
        }
        .padding(.bottom, 12)
    }

    private func soundPadButton(_ clip: SoundboardClip) -> some View {
        let key = clip.id.uuidString
        let isPressed = (pressedPadID == key)

        return Button {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
            ChocPressFeedback.completeTap(key: key, pressedKey: $pressedPadID)
            if client.connectionState.isConnected {
                client.triggerSoundboardClip(id: clip.id)
            } else {
                client.lastFeedback = CompanionFeedbackToast(
                    success: false,
                    title: clip.name,
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
            }
        } label: {
            VStack(spacing: 2) {
                Text(clip.emoji)
                    .font(.system(size: 52))
                    .frame(height: 64)
                Text(clip.name)
                    .font(ChocType.micro)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .scaleEffect(isPressed ? 0.95 : 1)
        }
        .buttonStyle(ChocPressedKeyButtonStyle(pressedKey: $pressedPadID, key: key))
        .accessibilityIdentifier("ios-soundboard-pad-\(clip.id.uuidString)")
        .accessibilityLabel("\(clip.name), \(clip.formattedDuration)")
        .contextMenu {
            Button {
                assignSoundToFirstEmptySlot(clip)
            } label: {
                Label(
                    L10n.tr("放入当前巧栏空槽位", "Add to Current Bar Page", language: lang),
                    systemImage: "plus.square.on.square"
                )
            }

            if client.profile.pages.indices.contains(currentBarPageIndex) {
                let page = client.profile.pages[currentBarPageIndex]
                Menu {
                    ForEach(0..<page.slots.count, id: \.self) { slotIdx in
                        let existing = page.slots[slotIdx]?.displayTitle(in: lang)
                            ?? L10n.tr("空槽位", "Empty", language: lang)
                        Button {
                            assignSound(clip, pageIndex: currentBarPageIndex, slotIndex: slotIdx)
                        } label: {
                            Text("#\(slotIdx + 1) · \(existing)")
                        }
                    }
                } label: {
                    Label(
                        L10n.tr("指定槽位覆盖…", "Assign to Specific Slot…", language: lang),
                        systemImage: "square.grid.2x2"
                    )
                }
            }
        }
    }

    private var emptyBoardState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 6)
            Text(client.connectionState.isConnected
                 ? L10n.tr("Mac 音效板暂为空。", "Your Mac soundboard is empty.", language: lang)
                 : L10n.tr("连接 Mac 即可使用音效。", "Connect your Mac to use sounds.", language: lang))
                .font(ChocType.body)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)

            Button(L10n.tr("连接 Mac", "Connect Mac", language: lang)) {
                onRequestPairing?()
            }
            .font(ChocType.body)
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)

            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("ios-soundboard-empty-state")
    }

    private var noMatchingSoundsState: some View {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 8) {
            Spacer(minLength: 6)
            Image(systemName: "magnifyingglass")
                .font(ChocType.title)
                .foregroundStyle(palette.secondaryText)

            Text(
                L10n.tr(
                    "没有匹配「\(trimmed)」的音效",
                    "No sounds matching \"\(trimmed)\"",
                    language: lang
                )
            )
            .font(ChocType.body.weight(.semibold))
            .foregroundStyle(palette.primaryText)

            Button {
                searchQuery = ""
            } label: {
                Text(L10n.tr("清空搜索", "Clear Search", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.accentForeground)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(palette.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func assignSoundToFirstEmptySlot(_ clip: SoundboardClip) {
        guard client.profile.pages.indices.contains(currentBarPageIndex) else { return }
        let slots = client.profile.pages[currentBarPageIndex].slots
        guard let emptyIdx = slots.firstIndex(where: { $0 == nil }) else {
            onPromptHUD?(L10n.tr("当前页已满，请长按音效指定替换槽位", "Current page is full; choose a slot to replace", language: lang))
            return
        }
        assignSound(clip, pageIndex: currentBarPageIndex, slotIndex: emptyIdx)
    }

    private func assignSound(_ clip: SoundboardClip, pageIndex: Int, slotIndex: Int) {
        var updated = client.profile
        guard updated.pages.indices.contains(pageIndex),
              updated.pages[pageIndex].slots.indices.contains(slotIndex) else { return }
        updated.pages[pageIndex].slots[slotIndex] = updated.makeBarItem(for: clip)
        client.pushUpdatedProfile(updated)
        onPromptHUD?(
            L10n.tr(
                "已放入槽位 #\(slotIndex + 1)：\(clip.name)",
                "Added \(clip.name) to Slot #\(slotIndex + 1)",
                language: lang
            )
        )
    }
}

// MARK: - 2. iPad Sheet Wrapper for Soundboard

public struct IOSSoundboardSheet: View {
    @ObservedObject var client: CompanionClientEngine
    let currentBarPageIndex: Int
    var onPromptHUD: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    public init(
        client: CompanionClientEngine,
        currentBarPageIndex: Int,
        onPromptHUD: ((String) -> Void)? = nil
    ) {
        self.client = client
        self.currentBarPageIndex = currentBarPageIndex
        self.onPromptHUD = onPromptHUD
    }

    public var body: some View {
        NavigationStack {
            IOSSoundboardSurfaceView(
                client: client,
                currentBarPageIndex: currentBarPageIndex,
                isLandscape: true,
                onPromptHUD: onPromptHUD
            )
            .background(
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle(L10n.tr("本机音效板", "Mac Soundboard", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("完成", "Done", language: lang)) {
                        dismiss()
                    }
                    .foregroundStyle(palette.accent)
                    .accessibilityIdentifier("ios-soundboard-sheet-done")
                }
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
    }
}

// MARK: - 3. Companion Search Sheet Across Page Tiles, Snippets, and Flows (Round 3)

public struct IOSWorkspaceSearchSheet: View {
    @ObservedObject var client: CompanionClientEngine
    var onPromptHUD: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var scope: CompanionSearchScope = .all
    @State private var confirmGate = DestructiveActionConfirmGate()
    @FocusState private var isSearchFieldFocused: Bool

    private var lang: AppLanguage { client.profile.settings.language }
    private var palette: ChocPalette { ChocPalette.forTheme(client.profile.settings.theme) }

    /// Pure search computation: typing or changing scope NEVER triggers any action.
    private var searchResults: [CompanionSearchResult] {
        CompanionWorkspaceSearch.search(
            in: client.profile,
            query: query,
            scope: scope,
            language: lang
        )
    }

    public init(
        client: CompanionClientEngine,
        onPromptHUD: ((String) -> Void)? = nil
    ) {
        self.client = client
        self.onPromptHUD = onPromptHUD
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                searchInputBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                Menu {
                    Picker(L10n.tr("范围", "Scope", language: lang), selection: $scope) {
                        ForEach(CompanionSearchScope.allCases) { option in
                            Text(option.title(in: lang)).tag(option)
                        }
                    }
                } label: {
                    Label(L10n.tr("搜索范围", "Search Scope", language: lang), systemImage: "line.3.horizontal.decrease.circle")
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 16)

                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    idlePromptState
                } else if searchResults.isEmpty {
                    noResultsState(trimmed: trimmed)
                } else {
                    resultsList
                }
            }
            .background(
                LinearGradient(
                    colors: [palette.backgroundTop, palette.backgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle(L10n.tr("搜索按键、片段与动作流", "Search Tiles, Snippets & Flows", language: lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("关闭", "Close", language: lang)) {
                        dismiss()
                    }
                    .foregroundStyle(palette.secondaryText)
                    .accessibilityIdentifier("ios-workspace-search-close")
                }
            }
            .onAppear {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    isSearchFieldFocused = true
                }
            }
            .onChange(of: query) { _, _ in
                confirmGate.disarm()
            }
            .onChange(of: scope) { _, _ in
                confirmGate.disarm()
            }
        }
        .tint(palette.accent)
        .preferredColorScheme(.light)
    }

    private var searchInputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(ChocType.caption)
                .foregroundStyle(palette.accent)

            TextField(
                L10n.tr("输入关键词查找，点按结果才执行…", "Type to search; tap a result to run…", language: lang),
                text: $query
            )
            .font(ChocType.body)
            .foregroundStyle(palette.primaryText)
            .focused($isSearchFieldFocused)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            .onSubmit {
                // Deliberately only dismisses keyboard focus; search NEVER auto-runs on typing or Return.
                isSearchFieldFocused = false
            }
            .accessibilityIdentifier("ios-workspace-search-field")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(ChocType.body)
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ios-workspace-search-clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isSearchFieldFocused ? palette.accent : palette.subtleCardStroke, lineWidth: isSearchFieldFocused ? 1.5 : 1)
        )
    }

    private var scopePickerRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CompanionSearchScope.allCases) { itemScope in
                    let isSelected = (scope == itemScope)
                    Button {
                        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
                        scope = itemScope
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: itemScope.sfSymbol)
                                .font(ChocType.micro)
                            Text(itemScope.title(in: lang))
                                .font(ChocType.caption)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(isSelected ? palette.accent : palette.tileFillBottom, in: Capsule())
                        .foregroundStyle(isSelected ? palette.accentForeground : palette.primaryText)
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? .clear : palette.subtleCardStroke, lineWidth: 1)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios-search-scope-\(itemScope.rawValue)")
                }
            }
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(searchResults) { result in
                    resultRowButton(result)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func resultRowButton(_ result: CompanionSearchResult) -> some View {
        let isAwaitingConfirm = confirmGate.isArmed(
            targetID: result.id,
            at: ProcessInfo.processInfo.systemUptime
        )

        return Button {
            handleTapResult(result)
        } label: {
            HStack(spacing: 12) {
                resultLeadingIcon(for: result.payload)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.title)
                            .font(ChocType.body.weight(.semibold))
                            .foregroundStyle(palette.primaryText)
                            .lineLimit(1)

                        if let badge = result.badgeText, !badge.isEmpty {
                            Text(badge)
                                .font(ChocType.micro)
                                .foregroundStyle(palette.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(palette.tileFillBottom, in: Capsule())
                        }
                    }

                    Text(result.subtitle)
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isAwaitingConfirm {
                    Text(L10n.tr("再点确认", "Tap Again", language: lang))
                        .font(ChocType.micro)
                        .foregroundStyle(palette.emphasisForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(palette.statusFailure, in: Capsule())
                } else {
                    Text(actionVerbLabel(for: result.payload))
                        .font(ChocType.micro)
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(palette.accent.opacity(0.14), in: Capsule())
                }
            }
            .padding(12)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(
                        isAwaitingConfirm ? palette.statusFailure : palette.subtleCardStroke,
                        lineWidth: isAwaitingConfirm ? 1.8 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ios-search-result-\(result.id)")
    }

    @ViewBuilder
    private func resultLeadingIcon(for payload: CompanionSearchResultPayload) -> some View {
        switch payload {
        case .tile(_, _, _, _, _, _, let effectiveItem, _):
            switch effectiveItem.kind {
            case .macApp(let bundleID, _, _, _):
                let icon = client.appIconsByBundleID[bundleID] ?? BundledAppIcons.pngData(for: bundleID)
                DataImageView(pngData: icon, fallbackSymbol: "app.fill", tint: palette.primaryText)
                    .frame(width: 34, height: 34)
            case .systemAction(let action, _, _):
                Image(systemName: action.sfSymbol)
                    .font(ChocType.body.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 34, height: 34)
                    .background(
                        ChocSwatch.resolvedTileColor(hex: action.accentHex),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            case .shortcut(_, let emoji, let hex):
                Text(emoji)
                    .font(ChocType.title)
                    .frame(width: 34, height: 34)
                    .background(
                        ChocSwatch.resolvedTileColor(hex: hex),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            case .website(_, _, let emoji, let hex, _):
                Text(emoji)
                    .font(ChocType.title)
                    .frame(width: 34, height: 34)
                    .background(
                        ChocSwatch.resolvedTileColor(hex: hex),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            case .flow(_, _, let emoji, let hex, _):
                Text(emoji)
                    .font(ChocType.title)
                    .frame(width: 34, height: 34)
                    .background(
                        ChocSwatch.resolvedTileColor(hex: hex),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            case .soundboard(_, _, let emoji, let hex):
                Text(emoji)
                    .font(ChocType.title)
                    .frame(width: 34, height: 34)
                    .background(
                        ChocSwatch.resolvedTileColor(hex: hex),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            case .folder(let folder):
                Text(folder.emoji)
                    .font(ChocType.title)
                    .frame(width: 34, height: 34)
                    .background(
                        ChocSwatch.resolvedTileColor(hex: folder.backgroundHex),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            case .slotReference:
                Image(systemName: "arrow.turn.up.right")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        case .snippet:
            Image(systemName: "text.quote")
                .font(ChocType.body.weight(.semibold))
                .foregroundStyle(palette.accent)
                .frame(width: 34, height: 34)
                .background(palette.tileFillBottom, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        case .flow(let flow):
            Text(flow.emoji.isEmpty ? "⚡️" : flow.emoji)
                .font(ChocType.title)
                .frame(width: 34, height: 34)
                .background(
                    ChocSwatch.resolvedTileColor(hex: flow.backgroundHex),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
    }

    private func actionVerbLabel(for payload: CompanionSearchResultPayload) -> String {
        switch payload {
        case .tile:
            return L10n.tr("触发", "Trigger", language: lang)
        case .snippet:
            return L10n.tr("插入", "Insert", language: lang)
        case .flow:
            return L10n.tr("运行", "Run", language: lang)
        }
    }

    private func handleTapResult(_ result: CompanionSearchResult) {
        let isDestructive: Bool = {
            switch result.payload {
            case .tile(let pageID, _, _, _, let slotIndex, let item, _, _):
                return item.requiresDestructiveConfirmation(
                    in: client.profile,
                    from: SlotCoordinate(pageID: pageID, slotIndex: slotIndex)
                )
            case .snippet:
                return false
            case .flow(let flow):
                return flow.requiresDestructiveConfirmation
            }
        }()

        let decision = confirmGate.registerTap(
            targetID: result.id,
            isDestructive: isDestructive,
            at: ProcessInfo.processInfo.systemUptime
        )

        if case .requireSecondTap = decision {
            CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .light)
            let delay = CompanionInteractionPolicy.destructiveConfirmWindowSeconds + 0.05
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                confirmGate.expireIfNeeded(at: ProcessInfo.processInfo.systemUptime)
            }
            return
        }

        CompanionHaptics.tap(enabled: client.profile.settings.hapticFeedbackEnabled, style: .medium)
        guard client.connectionState.isConnected else {
            if case .tile(let pageID, _, _, _, let slotIndex, _, _, _) = result.payload {
                client.recordOfflineTileFailure(
                    slot: SlotCoordinate(pageID: pageID, slotIndex: slotIndex),
                    title: result.title,
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
            } else {
                client.lastFeedback = CompanionFeedbackToast(
                    success: false,
                    title: result.title,
                    detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
                )
            }
            dismiss()
            return
        }

        switch result.payload {
        case .tile(let pageID, _, _, _, let slotIndex, let item, _, _):
            client.triggerBarItem(item, from: SlotCoordinate(pageID: pageID, slotIndex: slotIndex))
        case .snippet(let snippet):
            if client.triggerSnippet(snippet) {
                onPromptHUD?(L10n.tr("已发送：\(result.title)", "Sent: \(result.title)", language: lang))
            } else {
                // Typing mode with no focused text field on Mac does nothing.
                return
            }
        case .flow(let flow):
            client.triggerFlow(id: flow.id)
            onPromptHUD?(L10n.tr("已运行：\(flow.name)", "Running: \(flow.name)", language: lang))
        }
        dismiss()
    }

    private var idlePromptState: some View {
        let tileCount = client.profile.pages.reduce(0) { acc, page in
            acc + page.slots.compactMap { $0 }.count
        }
        let snippetCount = client.profile.snippets.count
        let flowCount = client.profile.flows.count

        return VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass.circle.fill")
                .font(ChocType.title)
                .foregroundStyle(palette.accent.opacity(0.85))

            Text(L10n.tr("搜索巧栏按键、文本片段与动作流", "Search Tiles, Snippets & Flows", language: lang))
                .font(ChocType.body.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            Text(
                L10n.tr(
                    "当前共 \(tileCount) 个按键格、\(snippetCount) 条片段、\(flowCount) 个动作流。输入时仅实时筛选，点按结果后才会执行。",
                    "\(tileCount) tiles, \(snippetCount) snippets, and \(flowCount) flows indexed. Typing only filters — tap a result to trigger it.",
                    language: lang
                )
            )
            .font(ChocType.caption)
            .foregroundStyle(palette.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
            .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("ios-workspace-search-idle")
    }

    private func noResultsState(trimmed: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(ChocType.title)
                .foregroundStyle(palette.secondaryText)

            Text(
                L10n.tr(
                    "未找到匹配「\(trimmed)」的项目",
                    "No matches for \"\(trimmed)\"",
                    language: lang
                )
            )
            .font(ChocType.body.weight(.semibold))
            .foregroundStyle(palette.primaryText)

            Text(L10n.tr("可尝试切换上方分类或输入更短的关键词。", "Try switching scopes above or using a shorter keyword.", language: lang))
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("ios-workspace-search-empty")
    }
}
