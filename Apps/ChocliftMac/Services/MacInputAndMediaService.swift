import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ChocliftCore
import Foundation

@MainActor
public final class MacInputAndMediaService {
    private let windowService: MacAccessibilityAndWindowService
    private var pendingClipboardSnapshot: [PasteboardItemSnapshot]?
    private var clipboardRestoreTask: Task<Void, Never>?
    private var compiledPlayerScripts: [String: NSAppleScript] = [:]

    /// Supplies live Now Playing / active audio client context from `MacSystemControlService`.
    public var mediaTransportContextProvider: (() -> MacMediaTransportContext)?
    /// Supplies live Now Playing bundle + duration context for playback scrubbing (`MacMediaSeekRouter`).
    public var mediaSeekContextProvider: (() -> MacMediaSeekContext)?

    public init(windowService: MacAccessibilityAndWindowService) {
        self.windowService = windowService
    }

    public var isStagingTransientPasteboard: Bool {
        pendingClipboardSnapshot != nil
    }

    // MARK: - Cursor-Aware Text & Emoji Insertion

    public static func previewLabel(for text: String, maxCharacters: Int = 24) -> String {
        let singleLine = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !singleLine.isEmpty else {
            return ""
        }
        if singleLine.count <= maxCharacters {
            return singleLine
        }
        return "\(singleLine.prefix(maxCharacters))…"
    }

    public func insertText(
        _ text: String,
        preferredPID: pid_t? = nil,
        allowActivatingPreferredPID: Bool = false,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        let clamped = TextSnippet.clampBody(text)
        guard !clamped.isEmpty else {
            return (false, L10n.tr("输入内容为空", "Text is empty", language: language))
        }

        guard windowService.isAccessibilityTrusted() else {
            return (
                false,
                L10n.tr(
                    "请在系统设置 → 辅助功能中授权 Choclift 后输入到光标处",
                    "Grant Accessibility permission in System Settings to insert at the cursor",
                    language: language
                )
            )
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let resolvedFocus: MacAccessibilityAndWindowService.FocusedTextInputTarget? = {
            if let direct = windowService.focusedTextInput(excludingPID: myPID) {
                return direct
            }
            if allowActivatingPreferredPID,
               let preferredPID,
               preferredPID != myPID,
               let app = NSRunningApplication(processIdentifier: preferredPID),
               !app.isTerminated {
                app.activate()
                RunLoop.current.run(until: Date().addingTimeInterval(0.06))
                return windowService.focusedTextInput(inApplicationPID: preferredPID)
            }
            return nil
        }()

        guard let focused = resolvedFocus else {
            return (
                false,
                L10n.tr(
                    "未检测到焦点输入框，请先在 Mac 中点击文本框",
                    "No text field focused on Mac — click a text field first",
                    language: language
                )
            )
        }

        let rawLabel = Self.previewLabel(for: clamped)
        let label = rawLabel.isEmpty ? L10n.tr("文本片段", "snippet", language: language) : rawLabel

        // 1. Insert directly via Accessibility into the focused text input without touching NSPasteboard.
        if windowService.insertTextViaAX(clamped, into: focused.element) {
            return (true, L10n.tr("已输入 \(label)", "Inserted \(label)", language: language))
        }

        // 2. Fallback for focused editable views that do not expose settable AXSelectedText (e.g. Terminal):
        //    stage transiently, paste, and restore the user's prior clipboard contents.
        pastePreservingClipboard(clamped)
        return (true, L10n.tr("已输入 \(label)", "Inserted \(label)", language: language))
    }

    public func executeSnippet(
        _ text: String,
        mode: SnippetInsertMode,
        preferredPID: pid_t? = nil,
        allowActivatingPreferredPID: Bool = false,
        language: AppLanguage = .system
    ) -> (success: Bool, didPerformAction: Bool, message: String) {
        let clamped = TextSnippet.clampBody(text)
        guard !clamped.isEmpty else {
            return (false, false, L10n.tr("输入内容为空", "Text is empty", language: language))
        }

        let rawLabel = Self.previewLabel(for: clamped)
        let label = rawLabel.isEmpty ? L10n.tr("文本片段", "snippet", language: language) : rawLabel
        let myPID = ProcessInfo.processInfo.processIdentifier

        switch mode {
        case .focusedFieldInsert:
            let res = insertText(
                clamped,
                preferredPID: preferredPID,
                allowActivatingPreferredPID: allowActivatingPreferredPID,
                language: language
            )
            return (res.success, true, res.message)

        case .clipboardPaste:
            guard ensureAccessibilityOrPrompt() else {
                return (
                    false,
                    true,
                    L10n.tr(
                        "请在系统设置 → 辅助功能中授权 Choclift 后粘贴文本片段",
                        "Grant Accessibility permission in System Settings to paste snippets",
                        language: language
                    )
                )
            }
            guard activateTargetForKeystroke(preferredPID, strict: false) else {
                let denied = missingStrictTargetResult()
                return (denied.success, true, denied.message)
            }
            // Cancel any pending transient clipboard restore so explicit clipboard paste remains on NSPasteboard.
            clipboardRestoreTask?.cancel()
            clipboardRestoreTask = nil
            pendingClipboardSnapshot = nil

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(clamped, forType: .string)
            postKeyStroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            return (
                true,
                true,
                L10n.tr("已通过剪贴板粘贴 \(label)", "Pasted \(label) via clipboard", language: language)
            )

        case .typeKeys:
            // Typing mode is only available when a field is focused. If no field is focused, do nothing.
            guard windowService.isAccessibilityTrusted() else {
                return (false, false, "")
            }
            let hasFocusedField = (windowService.focusedTextInput(excludingPID: myPID) != nil)
            let plan = SnippetInsertPolicy.evaluate(
                body: clamped,
                mode: .typeKeys,
                isFieldFocused: hasFocusedField
            )
            guard case .typeThroughKeyPath(let textToType) = plan else {
                return (false, false, "")
            }
            typeStringThroughKeyPath(textToType)
            return (
                true,
                true,
                L10n.tr("已逐字键入 \(label)", "Typed \(label)", language: language)
            )
        }
    }

    private func typeStringThroughKeyPath(_ text: String) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return
        }

        for ch in normalized {
            if ch == "\n" {
                postKeyStroke(virtualKey: CGKeyCode(kVK_Return), flags: [])
                continue
            }
            if ch == "\t" {
                postKeyStroke(virtualKey: CGKeyCode(kVK_Tab), flags: [])
                continue
            }
            var utf16Units = Array(String(ch).utf16)
            guard !utf16Units.isEmpty,
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
            keyUp.keyboardSetUnicodeString(stringLength: utf16Units.count, unicodeString: &utf16Units)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func pastePreservingClipboard(_ text: String) {
        let pb = NSPasteboard.general
        if pendingClipboardSnapshot == nil {
            pendingClipboardSnapshot = snapshotPasteboard(pb)
        }
        clipboardRestoreTask?.cancel()

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
        let stagedChangeCount = pb.changeCount

        postKeyStroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        clipboardRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.pendingClipboardSnapshot
            self.pendingClipboardSnapshot = nil
            self.clipboardRestoreTask = nil
            guard let snapshot, pb.changeCount == stagedChangeCount else { return }
            self.restorePasteboard(pb, snapshot: snapshot)
        }
    }

    // MARK: - System Quick Actions & Gesture Actions

    public func executeSystemAction(
        _ action: SystemQuickAction,
        preferredPID: pid_t?,
        strictTargetPID: Bool = false
    ) -> (success: Bool, message: String) {
        switch action {
        case .maximizeWindow:
            return windowService.performWindowOperation(.maximizeOrRestore, preferredPID: preferredPID, strictTargetPID: strictTargetPID)
        case .minimizeWindow:
            return windowService.performWindowOperation(.minimize, preferredPID: preferredPID, strictTargetPID: strictTargetPID)
        case .snapWindowLeft:
            return windowService.performWindowOperation(.snapLeft, preferredPID: preferredPID, strictTargetPID: strictTargetPID)
        case .snapWindowRight:
            return windowService.performWindowOperation(.snapRight, preferredPID: preferredPID, strictTargetPID: strictTargetPID)
        case .centerWindow:
            return windowService.performWindowOperation(.center, preferredPID: preferredPID, strictTargetPID: strictTargetPID)
        case .toggleFullscreen:
            return windowService.performWindowOperation(.toggleFullscreen, preferredPID: preferredPID, strictTargetPID: strictTargetPID)

        case .copySelection:
            guard ensureAccessibilityOrPrompt() else {
                return accessibilityDeniedResult()
            }
            guard activateTargetForKeystroke(preferredPID, strict: strictTargetPID) else {
                return missingStrictTargetResult()
            }
            postKeyStroke(virtualKey: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
            return (true, L10n.tr("已执行复制 (⌘C)", "Executed Copy (⌘C)"))

        case .pasteClipboard:
            guard ensureAccessibilityOrPrompt() else {
                return accessibilityDeniedResult()
            }
            guard activateTargetForKeystroke(preferredPID, strict: strictTargetPID) else {
                return missingStrictTargetResult()
            }
            postKeyStroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
            return (true, L10n.tr("已执行粘贴 (⌘V)", "Executed Paste (⌘V)"))

        case .cutSelection:
            guard ensureAccessibilityOrPrompt() else {
                return accessibilityDeniedResult()
            }
            guard activateTargetForKeystroke(preferredPID, strict: strictTargetPID) else {
                return missingStrictTargetResult()
            }
            postKeyStroke(virtualKey: CGKeyCode(kVK_ANSI_X), flags: .maskCommand)
            return (true, L10n.tr("已执行剪切 (⌘X)", "Executed Cut (⌘X)"))

        case .undoAction:
            guard ensureAccessibilityOrPrompt() else {
                return accessibilityDeniedResult()
            }
            guard activateTargetForKeystroke(preferredPID, strict: strictTargetPID) else {
                return missingStrictTargetResult()
            }
            postKeyStroke(virtualKey: CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)
            return (true, L10n.tr("已执行撤销 (⌘Z)", "Executed Undo (⌘Z)"))

        case .redoAction:
            guard ensureAccessibilityOrPrompt() else {
                return accessibilityDeniedResult()
            }
            guard activateTargetForKeystroke(preferredPID, strict: strictTargetPID) else {
                return missingStrictTargetResult()
            }
            postKeyStroke(virtualKey: CGKeyCode(kVK_ANSI_Z), flags: [.maskCommand, .maskShift])
            return (true, L10n.tr("已执行重做 (⇧⌘Z)", "Executed Redo (⇧⌘Z)"))

        case .missionControl:
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return (true, L10n.tr("已打开调度中心", "Opened Mission Control"))

        case .showDesktop:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Mission Control", "--args", "1"]
            try? process.run()
            return (true, L10n.tr("已切换显示桌面", "Toggled Show Desktop"))

        case .screenshotInteractive:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-c"]
            try? process.run()
            return (true, L10n.tr("已启动区域截图（存至剪贴板）", "Started interactive screenshot to clipboard"))

        case .mediaPlayPause:
            return executeMediaTransportCommand(.playPause)

        case .mediaNext:
            return executeMediaTransportCommand(.nextTrack)

        case .mediaPrevious:
            return executeMediaTransportCommand(.previousTrack)

        case .volumeUp:
            _ = postMediaKey(keyType: 0) // NX_KEYTYPE_SOUND_UP
            return (true, L10n.tr("音量 +", "Volume Up"))

        case .volumeDown:
            _ = postMediaKey(keyType: 1) // NX_KEYTYPE_SOUND_DOWN
            return (true, L10n.tr("音量 -", "Volume Down"))

        case .volumeMute:
            _ = postMediaKey(keyType: 7) // NX_KEYTYPE_MUTE
            return (true, L10n.tr("已切换静音", "Toggled Mute"))

        case .lockScreen:
            if windowService.isAccessibilityTrusted() {
                postKeyStroke(virtualKey: CGKeyCode(kVK_ANSI_Q), flags: [.maskCommand, .maskControl])
                return (true, L10n.tr("已锁定屏幕", "Screen Locked"))
            }
            return accessibilityDeniedResult()

        case .quitApp:
            let myPID = ProcessInfo.processInfo.processIdentifier
            let targetApp: NSRunningApplication? = {
                if strictTargetPID {
                    guard let preferredPID,
                          preferredPID != myPID,
                          let app = NSRunningApplication(processIdentifier: preferredPID),
                          !app.isTerminated else {
                        return nil
                    }
                    return app
                }
                if let preferredPID,
                   preferredPID != myPID,
                   let app = NSRunningApplication(processIdentifier: preferredPID),
                   !app.isTerminated {
                    return app
                }
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != myPID,
                   !front.isTerminated {
                    return front
                }
                return nil
            }()
            guard let app = targetApp else {
                if strictTargetPID {
                    return missingStrictTargetResult()
                }
                return (false, L10n.tr("当前没有可退出的前台应用", "No active application to quit"))
            }
            let name = app.localizedName ?? app.bundleIdentifier ?? "App"
            let ok = app.terminate()
            return ok
                ? (true, L10n.tr("已退出 \(name)", "Quit \(name)"))
                : (false, L10n.tr("无法退出 \(name)", "Could not quit \(name)"))

        case .openEmojiPicker:
            if windowService.isAccessibilityTrusted() {
                postKeyStroke(virtualKey: CGKeyCode(kVK_Space), flags: [.maskCommand, .maskControl])
            } else {
                NSApp.orderFrontCharacterPalette(nil)
            }
            return (true, L10n.tr("已打开表情面板", "Opened Emoji Palette"))
        }
    }

    // MARK: - Compact Key Row (Arrows, Escape, Space — Existing Input Path)

    public func sendCompactKey(
        _ key: CompanionCompactKey,
        preferredPID: pid_t? = nil,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        guard ensureAccessibilityOrPrompt() else {
            return (
                false,
                L10n.tr(
                    "需要辅助功能权限才能发送按键，请在系统设置中开启",
                    "Accessibility permission is required to send keys",
                    language: language
                )
            )
        }
        guard activateTargetForKeystroke(preferredPID, strict: false) else {
            return missingStrictTargetResult()
        }

        let virtualKey: CGKeyCode
        let flags: CGEventFlags
        switch key {
        case .escape:
            virtualKey = CGKeyCode(kVK_Escape)
            flags = []
        case .leftArrow:
            virtualKey = CGKeyCode(kVK_LeftArrow)
            flags = [.maskSecondaryFn, .maskNumericPad]
        case .upArrow:
            virtualKey = CGKeyCode(kVK_UpArrow)
            flags = [.maskSecondaryFn, .maskNumericPad]
        case .downArrow:
            virtualKey = CGKeyCode(kVK_DownArrow)
            flags = [.maskSecondaryFn, .maskNumericPad]
        case .rightArrow:
            virtualKey = CGKeyCode(kVK_RightArrow)
            flags = [.maskSecondaryFn, .maskNumericPad]
        case .space:
            virtualKey = CGKeyCode(kVK_Space)
            flags = []
        }

        postKeyStroke(virtualKey: virtualKey, flags: flags)
        let label = key.capLabel(in: language)
        return (true, L10n.tr("已发送 \(label)", "Sent \(label)", language: language))
    }

    // MARK: - Low-Level CGEvent & Pasteboard Helpers

    private func ensureAccessibilityOrPrompt() -> Bool {
        if windowService.isAccessibilityTrusted() {
            return true
        }
        _ = windowService.promptForAccessibilityPermission()
        return false
    }

    private func accessibilityDeniedResult() -> (success: Bool, message: String) {
        (
            false,
            L10n.tr(
                "需要辅助功能权限才能发送系统快捷键，请在系统设置中开启",
                "Accessibility permission is required to send shortcuts"
            )
        )
    }

    private func missingStrictTargetResult() -> (success: Bool, message: String) {
        (
            false,
            L10n.tr("目标应用未运行，已停止发送快捷键", "Target application is not running; aborted shortcut")
        )
    }

    private func activateTargetForKeystroke(_ pid: pid_t?, strict: Bool) -> Bool {
        if strict {
            guard let pid,
                  let target = NSRunningApplication(processIdentifier: pid),
                  !target.isTerminated else {
                return false
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                target.activate(options: [.activateAllWindows])
            }
            return true
        }
        activatePIDIfNeeded(pid)
        return true
    }

    private func activatePIDIfNeeded(_ pid: pid_t?) {
        guard let pid,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != pid,
              let target = NSRunningApplication(processIdentifier: pid) else {
            return
        }
        target.activate()
    }

    private func postKeyStroke(virtualKey: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    @discardableResult
    private func postMediaKey(keyType: Int32) -> Bool {
        func send(down: Bool) -> Bool {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((keyType << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            guard let cgEvent = event?.cgEvent else {
                return false
            }
            cgEvent.post(tap: .cghidEventTap)
            return true
        }
        let downSent = send(down: true)
        let upSent = send(down: false)
        return downSent && upSent
    }

    private enum PlayerScriptOutcome {
        case delivered
        case notRunning
        case failed(String)
    }

    private func executeMediaTransportCommand(
        _ command: MacMediaTransportCommand,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        let context = mediaTransportContextProvider?() ?? Self.fallbackMediaTransportContext()
        let route = MacMediaTransportRouter.chooseRoute(context: context)

        switch route {
        case .spotifyScript:
            guard Self.isAppRunning(bundleID: MacMediaTransportRouter.spotifyBundleIdentifier) else {
                if context.hasOtherActiveMediaClient, postMediaKey(keyType: Int32(command.hidMediaKeyType)) {
                    return (true, command.successMessage(in: language))
                }
                return (false, MacMediaTransportFailureReason.spotifyNotRunning.message(in: language))
            }

            switch executePlayerAppleScript(
                bundleID: MacMediaTransportRouter.spotifyBundleIdentifier,
                verb: command.spotifyScriptVerb
            ) {
            case .delivered:
                return (true, command.successMessage(in: language))
            case .notRunning:
                if context.hasOtherActiveMediaClient, postMediaKey(keyType: Int32(command.hidMediaKeyType)) {
                    return (true, command.successMessage(in: language))
                }
                return (false, MacMediaTransportFailureReason.spotifyNotRunning.message(in: language))
            case .failed(let errorMessage):
                // Do not post an ignored HID media key to Spotify and claim fake success;
                // only fall back to HID media key if another non-Spotify media client is actually active.
                if context.hasOtherActiveMediaClient, postMediaKey(keyType: Int32(command.hidMediaKeyType)) {
                    return (true, command.successMessage(in: language))
                }
                return (
                    false,
                    L10n.tr(
                        "无法向 Spotify 发送指令：\(errorMessage)",
                        "Could not deliver command to Spotify: \(errorMessage)",
                        language: language
                    )
                )
            }

        case .mediaKey:
            if context.nowPlayingBundleID?.caseInsensitiveCompare(MacMediaTransportRouter.musicBundleIdentifier) == .orderedSame,
               Self.isAppRunning(bundleID: MacMediaTransportRouter.musicBundleIdentifier) {
                if case .delivered = executePlayerAppleScript(
                    bundleID: MacMediaTransportRouter.musicBundleIdentifier,
                    verb: command.musicScriptVerb
                ) {
                    return (true, command.successMessage(in: language))
                }
            }
            if postMediaKey(keyType: Int32(command.hidMediaKeyType)) {
                return (true, command.successMessage(in: language))
            }
            return (
                false,
                L10n.tr("无法发送系统媒体按键事件", "Could not post system media key event", language: language)
            )

        case .failure(let reason):
            return (false, reason.message(in: language))
        }
    }

    /// Seeks the active Now Playing session to `requestedPositionSeconds` (`0...duration`) using the same
    /// background `NSAppleScript` / AppleEvent pattern as `playpause` for Spotify and Music.
    /// Never activates or launches any player, never posts HID media keys or track skips, and returns
    /// explicit failure for missing duration or unsupported apps on macOS 13.
    public func seekNowPlaying(
        to requestedPositionSeconds: Double,
        language: AppLanguage = .system
    ) -> (success: Bool, appliedPositionSeconds: Double?, message: String) {
        let context = mediaSeekContextProvider?() ?? Self.fallbackMediaSeekContext()
        let route = MacMediaSeekRouter.chooseRoute(
            requestedPositionSeconds: requestedPositionSeconds,
            context: context
        )

        switch route {
        case .spotifyScript(let clampedSeconds):
            let timestampText = NowPlayingProgressFormatter.formatTimestamp(Int(clampedSeconds.rounded(.down)))
            switch executePlayerSeekAppleScript(target: .spotify, positionSeconds: clampedSeconds) {
            case .delivered:
                return (
                    true,
                    clampedSeconds,
                    L10n.tr("已将 Spotify 跳转至 \(timestampText)", "Seeked Spotify to \(timestampText)", language: language)
                )
            case .notRunning:
                return (
                    false,
                    nil,
                    MacMediaSeekRejectionReason.playerNotRunning(bundleID: MacMediaSeekRouter.spotifyBundleIdentifier)
                        .message(in: language)
                )
            case .failed(let errorMessage):
                return (
                    false,
                    nil,
                    L10n.tr(
                        "无法跳转 Spotify 播放进度：\(errorMessage)",
                        "Could not seek Spotify playback: \(errorMessage)",
                        language: language
                    )
                )
            }

        case .musicScript(let clampedSeconds):
            let timestampText = NowPlayingProgressFormatter.formatTimestamp(Int(clampedSeconds.rounded(.down)))
            switch executePlayerSeekAppleScript(target: .music, positionSeconds: clampedSeconds) {
            case .delivered:
                return (
                    true,
                    clampedSeconds,
                    L10n.tr("已将 Music 跳转至 \(timestampText)", "Seeked Music to \(timestampText)", language: language)
                )
            case .notRunning:
                return (
                    false,
                    nil,
                    MacMediaSeekRejectionReason.playerNotRunning(bundleID: MacMediaSeekRouter.musicBundleIdentifier)
                        .message(in: language)
                )
            case .failed(let errorMessage):
                return (
                    false,
                    nil,
                    L10n.tr(
                        "无法跳转 Music 播放进度：\(errorMessage)",
                        "Could not seek Music playback: \(errorMessage)",
                        language: language
                    )
                )
            }

        case .rejected(let reason):
            return (false, nil, reason.message(in: language))
        }
    }

    private func executePlayerSeekAppleScript(
        target: MacMediaSeekTargetPlayer,
        positionSeconds: Double
    ) -> PlayerScriptOutcome {
        guard Self.isAppRunning(bundleID: target.bundleIdentifier) else {
            return .notRunning
        }

        let source = """
        with timeout of 3 seconds
            \(target.scriptSource(positionSeconds: positionSeconds))
        end timeout
        """
        guard let script = NSAppleScript(source: source) else {
            return .failed("AppleScript initialization failed")
        }

        var errorDict: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorDict)
        if let errorDict {
            let errNum = (errorDict[NSAppleScript.errorNumber] as? Int) ?? 0
            if errNum == -600 {
                return .notRunning
            }
            let reason = (errorDict[NSAppleScript.errorBriefMessage] as? String)
                ?? (errorDict[NSAppleScript.errorMessage] as? String)
                ?? "AppleEvent error (\(errNum))"
            return .failed(reason)
        }
        if descriptor.stringValue == "NOT_RUNNING" {
            return .notRunning
        }
        return .delivered
    }

    /// Sends a background AppleEvent/AppleScript command (`playpause` / `next track` / `previous track`)
    /// without activating the target app or stealing focus, and never launches the app if it is not running.
    private func executePlayerAppleScript(bundleID: String, verb: String) -> PlayerScriptOutcome {
        guard Self.isAppRunning(bundleID: bundleID) else {
            return .notRunning
        }

        let cacheKey = "\(bundleID)|\(verb)"
        let script: NSAppleScript
        if let cached = compiledPlayerScripts[cacheKey] {
            script = cached
        } else {
            let source = """
            with timeout of 3 seconds
                if application id "\(bundleID)" is running then
                    tell application id "\(bundleID)" to \(verb)
                    return "DELIVERED"
                else
                    return "NOT_RUNNING"
                end if
            end timeout
            """
            guard let created = NSAppleScript(source: source) else {
                return .failed("AppleScript initialization failed")
            }
            compiledPlayerScripts[cacheKey] = created
            script = created
        }

        var errorDict: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorDict)
        if let errorDict {
            let errNum = (errorDict[NSAppleScript.errorNumber] as? Int) ?? 0
            if errNum == -600 {
                return .notRunning
            }
            let reason = (errorDict[NSAppleScript.errorBriefMessage] as? String)
                ?? (errorDict[NSAppleScript.errorMessage] as? String)
                ?? "AppleEvent error (\(errNum))"
            return .failed(reason)
        }
        if descriptor.stringValue == "NOT_RUNNING" {
            return .notRunning
        }
        return .delivered
    }

    nonisolated private static func isAppRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { !$0.isTerminated })
    }

    private static func fallbackMediaTransportContext() -> MacMediaTransportContext {
        let spotifyRunning = isAppRunning(bundleID: MacMediaTransportRouter.spotifyBundleIdentifier)
        let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return MacMediaTransportContext(
            nowPlayingBundleID: nil,
            isNowPlayingPlaying: false,
            isSpotifyRunning: spotifyRunning,
            isSpotifyPlaying: false,
            frontmostBundleID: frontmostID,
            hasOtherActiveMediaClient: false
        )
    }

    private static func fallbackMediaSeekContext() -> MacMediaSeekContext {
        MacMediaSeekContext(
            nowPlayingBundleID: nil,
            durationSeconds: nil,
            isSpotifyRunning: isAppRunning(bundleID: MacMediaSeekRouter.spotifyBundleIdentifier),
            isMusicRunning: isAppRunning(bundleID: MacMediaSeekRouter.musicBundleIdentifier)
        )
    }

    private struct PasteboardItemSnapshot {
        let representations: [(NSPasteboard.PasteboardType, Data)]
    }

    private func snapshotPasteboard(_ pb: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            let pairs = item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
            return PasteboardItemSnapshot(representations: pairs)
        }
    }

    private func restorePasteboard(_ pb: NSPasteboard, snapshot: [PasteboardItemSnapshot]) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let restoredItems: [NSPasteboardItem] = snapshot.map { snap in
            let item = NSPasteboardItem()
            for (type, data) in snap.representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(restoredItems)
    }
}
