import AppKit
import ChocliftCore
import SwiftUI
import UniformTypeIdentifiers

public struct SoundboardStudioView: View {
    @ObservedObject var coordinator: MacAppCoordinator
    @ObservedObject var soundboardService: MacSoundboardService

    @State private var volumePreview: Double?
    @State private var searchQuery: String = ""
    @State private var editingClip: SoundboardClip?
    @State private var isDropTargeted: Bool = false

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
        self.soundboardService = coordinator.soundboardService
    }

    private var filteredClips: [SoundboardClip] {
        SoundboardSearch.filter(coordinator.profile.soundboardClips, query: searchQuery)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerToolbar

            soundboardVolumeAndSearchRow

            if coordinator.profile.soundboardClips.isEmpty {
                emptyBoardDropCard
            } else if filteredClips.isEmpty {
                noSearchMatchesState
            } else {
                soundPadsGrid
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedAudioProviders(providers)
        }
        .sheet(item: $editingClip) { clip in
            MacSoundClipEditSheet(coordinator: coordinator, clip: clip)
        }
    }

    private var headerToolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(L10n.tr("本地音效板", "Local Soundboard", language: lang))
                        .font(ChocType.title)
                        .foregroundStyle(palette.primaryText)

                    Text("\(coordinator.profile.soundboardClips.count)/\(SoundboardClip.maxBoardCount)")
                        .font(ChocType.caption.monospacedDigit())
                        .foregroundStyle(palette.primaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.tileFillBottom, in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))

                    Text(L10n.tr("最长 8 秒 · Mac 扬声器播放", "≤ 8s each · Mac Speakers", language: lang))
                        .font(ChocType.micro)
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.barSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 1))
                }

                Text(
                    L10n.tr(
                        "iPhone 与 iPad 可搜索并触发本机上的短音效；放入巧克力栏槽位后，Apple Watch 也可一键触发。无需从手机上传音频。",
                        "Trigger local Mac sounds from iPhone & iPad, or place a sound on a Chocolate Bar slot for Apple Watch. No audio is uploaded from the phone.",
                        language: lang
                    )
                )
                .font(ChocType.caption)
                .foregroundStyle(palette.secondaryText)
            }

            Spacer(minLength: 10)

            Button {
                coordinator.importBuiltInMacSounds()
            } label: {
                Label(L10n.tr("导入系统音效", "Import macOS Sounds", language: lang), systemImage: "waveform.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(!coordinator.profile.canAddMoreSoundboardClips)

            Button {
                coordinator.chooseAndAddLocalSoundFiles()
            } label: {
                Label(L10n.tr("添加本机音频…", "Add Local Audio…", language: lang), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
            .disabled(!coordinator.profile.canAddMoreSoundboardClips)
        }
    }

    private var soundboardVolumeAndSearchRow: some View {
        HStack(spacing: 14) {
            // Search by Sound Name
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)

                TextField(
                    L10n.tr("搜索音效名称…", "Search sound names…", language: lang),
                    text: $searchQuery
                )
                .textFieldStyle(.plain)
                .font(ChocType.body)
                .foregroundStyle(palette.primaryText)

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(ChocType.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .frame(width: 260, height: 34)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )

            // Separate Soundboard Volume Slider
            HStack(spacing: 10) {
                Image(systemName: coordinator.profile.soundboardVolume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.bubble.left.fill")
                    .font(ChocType.caption)
                    .foregroundStyle(palette.accent)

                Text(L10n.tr("音效板音量", "Soundboard Volume", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.primaryText)

                Slider(
                    value: Binding(
                        get: { volumePreview ?? coordinator.profile.soundboardVolume },
                        set: { volumePreview = $0 }
                    ),
                    in: 0.0...1.0,
                    onEditingChanged: { editing in
                        if !editing {
                            coordinator.setSoundboardVolume(volumePreview ?? coordinator.profile.soundboardVolume)
                            volumePreview = nil
                        }
                    }
                )
                .frame(width: 170)

                Text("\(ControlStripLevel.percentage(for: volumePreview ?? coordinator.profile.soundboardVolume))%")
                    .font(ChocType.caption.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 38, alignment: .trailing)

                Text(L10n.tr("独立于系统音量", "Separate from System Vol", language: lang))
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(palette.barSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.subtleCardStroke, lineWidth: 1)
            )

            if soundboardService.isPlaying {
                Button {
                    coordinator.stopSoundboardPlayback()
                } label: {
                    Label(L10n.tr("停止", "Stop", language: lang), systemImage: "stop.fill")
                        .font(ChocType.caption)
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
    }

    private var emptyBoardDropCard: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "speaker.wave.2.bubble.left.fill")
                .font(ChocType.title)
                .foregroundStyle(palette.accent)

            Text(L10n.tr("将 Mac 上的短音频文件拖入此处", "Drop Short Mac Audio Files Here", language: lang))
                .font(ChocType.title)
                .foregroundStyle(palette.primaryText)

            Text(
                L10n.tr(
                    "支持 WAV、MP3、M4A、AIFF、CAF、AAC、FLAC，单文件不超过 8 秒，上限 24 个。",
                    "Supports WAV, MP3, M4A, AIFF, CAF, AAC, and FLAC — up to 8 seconds per clip and 24 sounds total.",
                    language: lang
                )
            )
            .font(ChocType.body)
            .foregroundStyle(palette.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)

            HStack(spacing: 10) {
                Button {
                    coordinator.chooseAndAddLocalSoundFiles()
                } label: {
                    Label(L10n.tr("选择本地音频文件…", "Choose Audio Files…", language: lang), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)

                Button {
                    coordinator.importBuiltInMacSounds()
                } label: {
                    Label(L10n.tr("一键导入 macOS 系统音效", "Import macOS System Sounds", language: lang), systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.barSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? palette.accent : palette.subtleCardStroke,
                            style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: [6, 4])
                        )
                )
        )
    }

    private var noSearchMatchesState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(ChocType.title)
                .foregroundStyle(palette.secondaryText)
            Text(L10n.tr("没有匹配的音效名称", "No Matching Sound Names", language: lang))
                .font(ChocType.body.weight(.semibold))
                .foregroundStyle(palette.primaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var soundPadsGrid: some View {
        let columns = [
            GridItem(.adaptive(minimum: 155, maximum: 195), spacing: 12)
        ]

        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(filteredClips) { clip in
                    soundPadCard(clip)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func soundPadCard(_ clip: SoundboardClip) -> some View {
        let isActive = soundboardService.isPlaying && soundboardService.activeSoundID == clip.id
        let baseTone = ChocSwatch.resolvedTileColor(hex: clip.backgroundHex, fallbackHex: "#ECFAEE")

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(clip.emoji)
                    .font(ChocType.title)

                Spacer()

                Text(clip.formattedDuration)
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(palette.barSurface.opacity(0.9), in: Capsule())
                    .overlay(Capsule().strokeBorder(palette.subtleCardStroke, lineWidth: 0.8))
            }

            Text(clip.name)
                .font(ChocType.caption)
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)

            HStack(spacing: 6) {
                Button {
                    _ = coordinator.playSoundClip(id: clip.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isActive ? "speaker.wave.3.fill" : "play.fill")
                            .font(ChocType.micro)
                        Text(L10n.tr("试听", "Play", language: lang))
                            .font(ChocType.micro)
                    }
                    .foregroundStyle(palette.accentForeground)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 44)
                    .background(palette.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                Menu {
                    Menu(L10n.tr("放入当前页槽位", "Assign to Current Page Slot", language: lang)) {
                        let pageIdx = min(max(0, coordinator.selectedPageIndex), max(0, coordinator.profile.pages.count - 1))
                        if coordinator.profile.pages.indices.contains(pageIdx) {
                            ForEach(0..<BarPage.slotsPerPage, id: \.self) { sIdx in
                                let existing = coordinator.profile.pages[pageIdx].slots[sIdx]
                                Button {
                                    coordinator.assignSoundClipToSlot(clip, pageIndex: pageIdx, slotIndex: sIdx)
                                } label: {
                                    if let existing {
                                        Text("#\(sIdx + 1) · \(coordinator.profile.displayTitle(for: existing, in: lang))")
                                    } else {
                                        Text(L10n.tr("#\(sIdx + 1) · 空槽位", "#\(sIdx + 1) · Empty Slot", language: lang))
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        editingClip = clip
                    } label: {
                        Label(L10n.tr("编辑名称与图标…", "Rename & Style…", language: lang), systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        coordinator.deleteSoundClip(id: clip.id)
                    } label: {
                        Label(L10n.tr("移除音效", "Remove Sound", language: lang), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.tileFillTop, baseTone],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(
                            isActive ? palette.accent : palette.tileBorderHighlight,
                            lineWidth: isActive ? 2.0 : 1.1
                        )
                )
        )
        .contextMenu {
            Button {
                _ = coordinator.playSoundClip(id: clip.id)
            } label: {
                Label(L10n.tr("在 Mac 扬声器播放", "Play on Mac Speakers", language: lang), systemImage: "play.fill")
            }
            Button {
                editingClip = clip
            } label: {
                Label(L10n.tr("编辑名称与图标…", "Rename & Style…", language: lang), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                coordinator.deleteSoundClip(id: clip.id)
            } label: {
                Label(L10n.tr("移除音效", "Remove Sound", language: lang), systemImage: "trash")
            }
        }
    }

    private func handleDroppedAudioProviders(_ providers: [NSItemProvider]) -> Bool {
        var didAcceptAny = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            didAcceptAny = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let resolvedURL: URL? = {
                    if let data = item as? Data {
                        return URL(dataRepresentation: data, relativeTo: nil)
                    }
                    return item as? URL
                }()
                guard let url = resolvedURL else { return }
                Task { @MainActor in
                    _ = coordinator.addSoundFilesFromURLs([url])
                }
            }
        }
        return didAcceptAny
    }
}

private struct MacSoundClipEditSheet: View {
    @ObservedObject var coordinator: MacAppCoordinator
    let clip: SoundboardClip
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var emoji: String = "🔊"
    @State private var backgroundHex: String = "#ECFAEE"

    private var lang: AppLanguage { coordinator.lang }
    private var palette: ChocPalette { coordinator.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("编辑音效", "Edit Sound", language: lang))
                .font(ChocType.title)
                .foregroundStyle(palette.primaryText)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("名称", "Name", language: lang))
                    .font(ChocType.caption)
                    .foregroundStyle(palette.secondaryText)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("图标表情", "Emoji", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                    TextField("🔊", text: $emoji)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("卡片色调", "Tile Tint", language: lang))
                        .font(ChocType.caption)
                        .foregroundStyle(palette.secondaryText)
                    HStack(spacing: 6) {
                        ForEach(ChocSwatch.tileColors, id: \.self) { hex in
                            Button {
                                backgroundHex = hex
                            } label: {
                                Circle()
                                    .fill(ChocSwatch.resolvedTileColor(hex: hex))
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                backgroundHex.caseInsensitiveCompare(hex) == .orderedSame
                                                    ? palette.accent
                                                    : palette.subtleCardStroke,
                                                lineWidth: backgroundHex.caseInsensitiveCompare(hex) == .orderedSame ? 2 : 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Text(clip.filePath)
                    .font(ChocType.micro)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(clip.formattedDuration)
                    .font(ChocType.micro.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
            }

            HStack {
                Button(L10n.tr("取消", "Cancel", language: lang)) {
                    dismiss()
                }
                Spacer()
                Button(L10n.tr("保存", "Save", language: lang)) {
                    coordinator.updateSoundClip(
                        id: clip.id,
                        name: name,
                        emoji: emoji,
                        backgroundHex: backgroundHex
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(palette.barSurface)
        .onAppear {
            name = clip.name
            emoji = clip.emoji
            backgroundHex = clip.backgroundHex
        }
    }
}
