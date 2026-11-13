import AVFoundation
import AppKit
import ChocliftCore
import Foundation
import UniformTypeIdentifiers

@MainActor
public final class MacSoundboardService: NSObject, ObservableObject {
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var activeSoundID: UUID?

    private struct ActivePlayerEntry {
        let token: UUID
        let soundID: UUID
        let player: AVAudioPlayer
    }

    private final class PlayerDelegateBridge: NSObject, AVAudioPlayerDelegate {
        let token: UUID
        let onFinish: @MainActor (UUID) -> Void

        init(token: UUID, onFinish: @escaping @MainActor (UUID) -> Void) {
            self.token = token
            self.onFinish = onFinish
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            let token = self.token
            let onFinish = self.onFinish
            Task { @MainActor in
                onFinish(token)
            }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            let token = self.token
            let onFinish = self.onFinish
            Task { @MainActor in
                onFinish(token)
            }
        }
    }

    private static let maxSimultaneousPlayers = 6
    private static let defaultEmojis = ["🔊", "🔔", "🥁", "🎺", "✨", "🎉", "👏", "🚀", "💥", "🎵", "🐸", "🫧"]

    private var activePlayers: [ActivePlayerEntry] = []
    private var delegateBridges: [UUID: PlayerDelegateBridge] = [:]

    public override init() {
        super.init()
    }

    // MARK: - Local File Duration Inspection & Candidate Creation

    public func inspectAudioDuration(at url: URL) -> Result<Double, SoundboardValidationError> {
        let path = url.standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              !isDir.boolValue else {
            return .failure(.missingFile)
        }
        guard SoundboardCatalogValidator.isSupportedAudioPath(path) else {
            return .failure(.unsupportedFormat)
        }

        var measuredSeconds: Double?
        if let player = try? AVAudioPlayer(contentsOf: url),
           player.duration.isFinite,
           player.duration > 0 {
            measuredSeconds = player.duration
        } else if let audioFile = try? AVAudioFile(forReading: url) {
            let sampleRate = audioFile.processingFormat.sampleRate
            if sampleRate > 0 {
                let dur = Double(audioFile.length) / sampleRate
                if dur.isFinite && dur > 0 {
                    measuredSeconds = dur
                }
            }
        }

        guard let duration = measuredSeconds, duration.isFinite, duration > 0 else {
            return .failure(.invalidDuration)
        }
        guard duration <= SoundboardClip.maxDurationSeconds else {
            return .failure(.durationTooLong(
                seconds: duration,
                maxSeconds: SoundboardClip.maxDurationSeconds
            ))
        }
        return .success(duration)
    }

    public func prepareCandidateClip(
        from url: URL,
        existingClips: [SoundboardClip],
        customName: String? = nil,
        emoji: String? = nil,
        backgroundHex: String? = nil
    ) -> Result<SoundboardClip, SoundboardValidationError> {
        guard existingClips.count < SoundboardClip.maxBoardCount else {
            return .failure(.boardFull(limit: SoundboardClip.maxBoardCount))
        }

        let cleanPath = url.standardizedFileURL.path
        switch inspectAudioDuration(at: url) {
        case .failure(let err):
            return .failure(err)
        case .success(let duration):
            let check = SoundboardCatalogValidator.validateAddition(
                filePath: cleanPath,
                durationSeconds: duration,
                existingClips: existingClips
            )
            if case .failure(let validationErr) = check {
                return .failure(validationErr)
            }

            let rawStem = url.deletingPathExtension().lastPathComponent
            let name = SoundboardClip.sanitizeName(customName ?? rawStem, fallback: rawStem)
            let chosenEmoji = emoji ?? Self.defaultEmojis[existingClips.count % Self.defaultEmojis.count]
            let paletteSwatches = ChocSwatch.tileColors
            let chosenHex = backgroundHex ?? paletteSwatches[existingClips.count % max(1, paletteSwatches.count)]

            let clip = SoundboardClip(
                name: name,
                filePath: cleanPath,
                durationSeconds: duration,
                emoji: chosenEmoji,
                backgroundHex: chosenHex
            )
            return .success(clip)
        }
    }

    // MARK: - Playback on Mac Speakers (Separate Soundboard-Only Volume)

    @discardableResult
    public func play(
        clip: SoundboardClip,
        soundboardVolume: Double,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        let url = URL(fileURLWithPath: clip.filePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            return (
                false,
                L10n.tr(
                    "找不到本地音频文件：\(clip.name)",
                    "Local audio file not found on Mac: \(clip.name)",
                    language: language
                )
            )
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.duration.isFinite,
                  player.duration > 0,
                  player.duration <= SoundboardClip.maxDurationSeconds else {
                return (
                    false,
                    L10n.tr(
                        "音效超过 8 秒上限或已损坏：\(clip.name)",
                        "Sound exceeds 8s limit or could not be decoded: \(clip.name)",
                        language: language
                    )
                )
            }

            if activePlayers.count >= Self.maxSimultaneousPlayers,
               let oldest = activePlayers.first {
                oldest.player.stop()
                cleanupPlayer(token: oldest.token)
            }

            let token = UUID()
            let bridge = PlayerDelegateBridge(token: token) { [weak self] finishedToken in
                self?.cleanupPlayer(token: finishedToken)
            }
            player.delegate = bridge
            player.volume = Float(ControlStripLevel.clamp(soundboardVolume))
            player.prepareToPlay()

            guard player.play() else {
                return (
                    false,
                    L10n.tr(
                        "Mac 扬声器无法播放：\(clip.name)",
                        "Mac speakers could not start playback: \(clip.name)",
                        language: language
                    )
                )
            }

            delegateBridges[token] = bridge
            activePlayers.append(ActivePlayerEntry(token: token, soundID: clip.id, player: player))
            activeSoundID = clip.id
            isPlaying = true

            return (
                true,
                L10n.tr("正在播放 \(clip.name)", "Playing \(clip.name)", language: language)
            )
        } catch {
            return (
                false,
                L10n.tr(
                    "播放失败：\(error.localizedDescription)",
                    "Playback failed: \(error.localizedDescription)",
                    language: language
                )
            )
        }
    }

    public func updateActivePlaybackVolume(_ level: Double) {
        let clamped = Float(ControlStripLevel.clamp(level))
        for entry in activePlayers {
            entry.player.volume = clamped
        }
    }

    public func stopAll() {
        let current = activePlayers
        activePlayers.removeAll()
        delegateBridges.removeAll()
        for entry in current {
            entry.player.stop()
        }
        isPlaying = false
        activeSoundID = nil
    }

    private func cleanupPlayer(token: UUID) {
        activePlayers.removeAll { $0.token == token }
        delegateBridges.removeValue(forKey: token)
        isPlaying = !activePlayers.isEmpty
        activeSoundID = activePlayers.last?.soundID
    }

    // MARK: - Local Mac Audio File Picker & Built-In System Sounds

    public func presentOpenPanelForLocalSounds() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.audio]
        panel.message = L10n.tr(
            "选择本机上的短音效文件（每个不超过 8 秒，最多 24 个）",
            "Choose short audio files stored on this Mac (≤ 8s each, up to 24 sounds)"
        )
        return panel.runModal() == .OK ? panel.urls : []
    }

    public func discoverBuiltInSystemSoundURLs() -> [URL] {
        let systemSoundsDir = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: systemSoundsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return items
            .filter { SoundboardCatalogValidator.isSupportedAudioPath($0.path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
