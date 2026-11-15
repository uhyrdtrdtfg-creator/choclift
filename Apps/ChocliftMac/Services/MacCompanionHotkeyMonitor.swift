import AppKit
import Carbon.HIToolbox
import ChocliftCore
import Foundation

private final class CarbonHotKeyHandleStore {
    var eventHandlerRef: EventHandlerRef?
    var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]

    func unregisterHotKeys() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    func stopAll() {
        unregisterHotKeys()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}

@MainActor
public final class MacCompanionHotkeyMonitor {
    public static let signature: OSType = 0x4348_4B59 // 'CHKY'
    public static let validCarbonIDRange: ClosedRange<UInt32> = 2...9

    private weak var coordinator: MacAppCoordinator?
    private let handleStore = CarbonHotKeyHandleStore()
    private var hotkeysByCarbonID: [UInt32: CompanionHotkey] = [:]
    private var lastLoadedHotkeys: [CompanionHotkey] = []
    private var isSuspendedForRecording = false
    public private(set) var failedRegistrationIDs: Set<UUID> = []

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    deinit {
        handleStore.stopAll()
    }

    public func start(initialHotkeys: [CompanionHotkey]) {
        stop()
        installCarbonHandlerIfNeeded()
        reload(hotkeys: initialHotkeys)
    }

    public func stop() {
        hotkeysByCarbonID.removeAll()
        failedRegistrationIDs.removeAll()
        handleStore.stopAll()
    }

    public func setSuspendedForRecording(_ suspended: Bool) {
        guard isSuspendedForRecording != suspended else { return }
        isSuspendedForRecording = suspended
        if suspended {
            handleStore.unregisterHotKeys()
        } else {
            reload(hotkeys: lastLoadedHotkeys)
        }
    }

    public func reload(hotkeys: [CompanionHotkey]) {
        let sanitized = CompanionHotkeyLibrary.sanitize(hotkeys)
        lastLoadedHotkeys = sanitized

        handleStore.unregisterHotKeys()
        hotkeysByCarbonID.removeAll()
        failedRegistrationIDs.removeAll()

        guard !sanitized.isEmpty else { return }
        installCarbonHandlerIfNeeded()
        guard !isSuspendedForRecording else { return }

        for (index, hotkey) in sanitized.prefix(CompanionHotkeyLibrary.maxCount).enumerated() {
            let carbonID = UInt32(index + 2)
            guard Self.validCarbonIDRange.contains(carbonID) else { break }

            let eventHotKeyID = EventHotKeyID(signature: Self.signature, id: carbonID)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(hotkey.keyCode),
                hotkey.carbonModifiers,
                eventHotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                handleStore.hotKeyRefs[carbonID] = ref
                hotkeysByCarbonID[carbonID] = hotkey
            } else {
                failedRegistrationIDs.insert(hotkey.id)
            }
        }
    }

    private func installCarbonHandlerIfNeeded() {
        guard handleStore.eventHandlerRef == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else {
                return OSStatus(eventNotHandledErr)
            }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard err == noErr,
                  hotKeyID.signature == MacCompanionHotkeyMonitor.signature,
                  MacCompanionHotkeyMonitor.validCarbonIDRange.contains(hotKeyID.id) else {
                return OSStatus(eventNotHandledErr)
            }
            let monitor = Unmanaged<MacCompanionHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            let pressedID = hotKeyID.id
            Task { @MainActor [weak monitor] in
                monitor?.handleHotKeyPressed(carbonID: pressedID)
            }
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            userData,
            &handlerRef
        )
        if status == noErr {
            handleStore.eventHandlerRef = handlerRef
        }
    }

    private func handleHotKeyPressed(carbonID: UInt32) {
        guard !isSuspendedForRecording,
              let hotkey = hotkeysByCarbonID[carbonID],
              let coordinator else {
            return
        }

        if let flowID = CompanionHotkeyLibrary.parsedFlowID(from: hotkey.actionID) {
            Task { @MainActor [weak coordinator] in
                guard let coordinator else { return }
                let trimmedTitle = hotkey.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let result = await coordinator.runFlowByID(
                    flowID,
                    fallbackName: trimmedTitle.isEmpty ? hotkey.actionID : trimmedTitle,
                    triggeredBy: "Mac Shortcut"
                )
                if !result.success {
                    coordinator.flashBanner(result.detail)
                }
            }
            return
        }

        if let quadID = CompanionHotkeyLibrary.parsedQuadLayoutID(from: hotkey.actionID) {
            Task { @MainActor [weak coordinator] in
                guard let coordinator else { return }
                let result = await coordinator.runQuadLayout(
                    id: quadID,
                    triggeredBy: "Mac Shortcut"
                )
                if !result.success {
                    coordinator.flashBanner(result.message)
                }
            }
            return
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        let isChocliftFrontmost: Bool = {
            guard let frontApp else { return false }
            if frontApp.processIdentifier == selfPID {
                return true
            }
            guard let bundleID = frontApp.bundleIdentifier else { return false }
            return ActionFlowStep.isChocliftBundleIdentifier(bundleID)
        }()

        if CompanionHotkeyLibrary.isQuitStyleAction(hotkey.actionID) && isChocliftFrontmost {
            let message = L10n.tr(
                "当前前台为 Choclift，已跳过退出操作",
                "Choclift is frontmost; skipped quit action",
                language: coordinator.lang
            )
            coordinator.didExecuteCompanionHotkey(
                hotkey: hotkey,
                systemAction: SystemQuickAction(rawValue: hotkey.actionID),
                success: false,
                message: message
            )
            return
        }

        let preferredPID: pid_t? = {
            guard let candidatePID = coordinator.timeTravel.lastExternalAppPID,
                  candidatePID != selfPID else {
                return nil
            }
            if let running = NSRunningApplication(processIdentifier: candidatePID),
               let bundleID = running.bundleIdentifier,
               ActionFlowStep.isChocliftBundleIdentifier(bundleID) {
                return nil
            }
            return candidatePID
        }()

        if let action = SystemQuickAction(rawValue: hotkey.actionID) {
            let result = coordinator.inputService.executeSystemAction(
                action,
                preferredPID: preferredPID,
                strictTargetPID: false
            )
            coordinator.didExecuteCompanionHotkey(
                hotkey: hotkey,
                systemAction: action,
                success: result.success,
                message: result.message
            )
        } else {
            let result = MacCompanionActionRunner.run(
                id: hotkey.actionID,
                preferredPID: preferredPID
            )
            coordinator.didExecuteCompanionHotkey(
                hotkey: hotkey,
                systemAction: nil,
                success: result.success,
                message: result.message
            )
        }
    }
}
