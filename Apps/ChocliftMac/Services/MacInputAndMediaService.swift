import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ChocliftCore
import Foundation

@MainActor
public final class MacInputAndMediaService {
    private let windowService: MacAccessibilityAndWindowService

    public init(windowService: MacAccessibilityAndWindowService) {
        self.windowService = windowService
    }

    // MARK: - Instant Emoji Injection ("Pick emojis right where you type")

    public func insertEmojiAtCursor(_ emoji: String) -> (success: Bool, message: String) {
        let pb = NSPasteboard.general
        let savedSnapshot = snapshotPasteboard(pb)

        pb.clearContents()
        pb.setString(emoji, forType: .string)

        guard windowService.isAccessibilityTrusted() else {
            return (
                true,
                L10n.tr(
                    "已复制 \(emoji) 到剪贴板（开启辅助功能后可自动输入到光标处）",
                    "Copied \(emoji) to clipboard (enable Accessibility for direct cursor typing)"
                )
            )
        }

        postKeyStroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        // Restore previous clipboard contents after target app processes Cmd+V
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            restorePasteboard(pb, snapshot: savedSnapshot)
        }

        return (true, L10n.tr("已输入 \(emoji)", "Inserted \(emoji)"))
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
            postMediaKey(keyType: 16) // NX_KEYTYPE_PLAY
            return (true, L10n.tr("播放 / 暂停", "Media Play / Pause"))

        case .mediaNext:
            postMediaKey(keyType: 17) // NX_KEYTYPE_NEXT
            return (true, L10n.tr("已切至下一曲", "Skipped to Next Track"))

        case .mediaPrevious:
            postMediaKey(keyType: 18) // NX_KEYTYPE_PREVIOUS
            return (true, L10n.tr("已切至上一曲", "Returned to Previous Track"))

        case .volumeUp:
            postMediaKey(keyType: 0) // NX_KEYTYPE_SOUND_UP
            return (true, L10n.tr("音量 +", "Volume Up"))

        case .volumeDown:
            postMediaKey(keyType: 1) // NX_KEYTYPE_SOUND_DOWN
            return (true, L10n.tr("音量 -", "Volume Down"))

        case .volumeMute:
            postMediaKey(keyType: 7) // NX_KEYTYPE_MUTE
            return (true, L10n.tr("已切换静音", "Toggled Mute"))

        case .lockScreen:
            if windowService.isAccessibilityTrusted() {
                postKeyStroke(virtualKey: CGKeyCode(kVK_ANSI_Q), flags: [.maskCommand, .maskControl])
                return (true, L10n.tr("已锁定屏幕", "Screen Locked"))
            }
            return accessibilityDeniedResult()

        case .openEmojiPicker:
            if windowService.isAccessibilityTrusted() {
                postKeyStroke(virtualKey: CGKeyCode(kVK_Space), flags: [.maskCommand, .maskControl])
            } else {
                NSApp.orderFrontCharacterPalette(nil)
            }
            return (true, L10n.tr("已打开表情面板", "Opened Emoji Palette"))
        }
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

    private func postMediaKey(keyType: Int32) {
        func send(down: Bool) {
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
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        send(down: true)
        send(down: false)
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
