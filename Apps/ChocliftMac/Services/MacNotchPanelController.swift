import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ChocliftCore
import Foundation
import SwiftUI

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class ChocNotchFloatingPanel: NSPanel {
    var onEscapePressed: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onEscapePressed?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
public final class MacNotchPanelController {
    private weak var coordinator: MacAppCoordinator?
    private let presentation = NotchPanelPresentationState()
    private var panel: ChocNotchFloatingPanel?
    private var hostingView: FirstMouseHostingView<MacNotchPanelView>?

    private var stateMachine = NotchPanelHoverStateMachine()
    private var settledPanelFrame: CGRect?
    private var visibilityGeneration: UInt64 = 0

    private var globalMouseMoveMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private var globalMouseDownMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []

    private var dwellWakeupTask: Task<Void, Never>?
    private var visibleWatchdogTask: Task<Void, Never>?

    private var escapeEventHandlerRef: EventHandlerRef?
    private var escapeHotKeyRef: EventHotKeyRef?

    public private(set) var isPanelVisible: Bool = false

    public init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    public func start() {
        stop()
        installCarbonEscapeHandler()
        installEventMonitors()
        installWorkspaceAndScreenObservers()
    }

    public func stop() {
        dwellWakeupTask?.cancel()
        dwellWakeupTask = nil
        visibleWatchdogTask?.cancel()
        visibleWatchdogTask = nil

        unregisterTemporaryEscapeHotKey()
        if let handler = escapeEventHandlerRef {
            RemoveEventHandler(handler)
            escapeEventHandlerRef = nil
        }

        if let m = globalMouseMoveMonitor { NSEvent.removeMonitor(m); globalMouseMoveMonitor = nil }
        if let m = localMouseMoveMonitor { NSEvent.removeMonitor(m); localMouseMoveMonitor = nil }
        if let m = globalMouseDownMonitor { NSEvent.removeMonitor(m); globalMouseDownMonitor = nil }
        if let m = localMouseDownMonitor { NSEvent.removeMonitor(m); localMouseDownMonitor = nil }
        if let m = globalKeyDownMonitor { NSEvent.removeMonitor(m); globalKeyDownMonitor = nil }
        if let m = localKeyDownMonitor { NSEvent.removeMonitor(m); localKeyDownMonitor = nil }

        let wsNC = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers {
            wsNC.removeObserver(obs)
        }
        workspaceObservers.removeAll()

        let appNC = NotificationCenter.default
        for obs in appObservers {
            appNC.removeObserver(obs)
        }
        appObservers.removeAll()

        orderOutImmediately()
    }

    public func syncSettingsChanged() {
        guard let coordinator else { return }
        if !coordinator.notchPanelEnabled {
            _ = stateMachine.dismissImmediately(suppressUntilTriggerExit: false)
            hidePanel(animated: true)
            return
        }
        if isPanelVisible,
           stateMachine.visibleSession?.anchor == .leftEdge,
           !coordinator.leftEdgePanelEnabled {
            _ = stateMachine.dismissImmediately(suppressUntilTriggerExit: false)
            hidePanel(animated: true)
            return
        }
        evaluateCurrentPointer()
    }

    public func dismissPanelImmediately() {
        let transition = stateMachine.dismissImmediately(suppressUntilTriggerExit: true)
        if transition == .hide || isPanelVisible {
            hidePanel(animated: true)
        }
    }

    // MARK: - Event Monitors & Notifications

    private func installEventMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: moveMask) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateCurrentPointer()
            }
        }
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: moveMask) { [weak self] event in
            self?.evaluateCurrentPointer()
            return event
        }

        let clickMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: clickMask) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPanelVisible else { return }
                let mouse = NSEvent.mouseLocation
                if let frame = self.settledPanelFrame,
                   !NotchPanelLayout.rectContainsInclusive(frame, point: mouse, edgeSlop: 2) {
                    self.dismissPanelImmediately()
                }
            }
        }
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: clickMask) { [weak self] event in
            guard let self, self.isPanelVisible else { return event }
            if let panel = self.panel, event.window !== panel {
                self.dismissPanelImmediately()
            }
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isPanelVisible else { return }
                self.dismissPanelImmediately()
            }
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isPanelVisible, event.keyCode == UInt16(kVK_Escape) else {
                return event
            }
            self.dismissPanelImmediately()
            return nil
        }
    }

    private func installWorkspaceAndScreenObservers() {
        let wsNC = NSWorkspace.shared.notificationCenter
        let spaceToken = wsNC.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissPanelImmediately()
            }
        }
        workspaceObservers = [spaceToken]

        let appNC = NotificationCenter.default
        let screenToken = appNC.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissPanelImmediately()
            }
        }
        appObservers = [screenToken]
    }

    // MARK: - Temporary Escape HotKey (Works Without Stealing Focus)

    private func installCarbonEscapeHandler() {
        guard escapeEventHandlerRef == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
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
            guard err == noErr, hotKeyID.signature == 0x4348_4F43, hotKeyID.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let controller = Unmanaged<MacNotchPanelController>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                controller.dismissPanelImmediately()
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
            escapeEventHandlerRef = handlerRef
        }
    }

    private func registerTemporaryEscapeHotKey() {
        guard escapeHotKeyRef == nil else { return }
        let hotKeyID = EventHotKeyID(signature: 0x4348_4F43, id: 1) // 'CHOC'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            escapeHotKeyRef = ref
        }
    }

    private func unregisterTemporaryEscapeHotKey() {
        if let ref = escapeHotKeyRef {
            UnregisterEventHotKey(ref)
            escapeHotKeyRef = nil
        }
    }

    // MARK: - State Machine Evaluation

    private func evaluateCurrentPointer() {
        guard let coordinator else { return }

        let nsScreens = NSScreen.screens
        let metrics = nsScreens.map(Self.makeMetrics(for:))
        let pointer = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        let mouseButtonsPressed = (NSEvent.pressedMouseButtons != 0)

        let targetScreen: NSScreen? = {
            if let activeIdx = stateMachine.visibleSession?.screenIndex,
               nsScreens.indices.contains(activeIdx) {
                return nsScreens[activeIdx]
            }
            return nsScreens.first(where: { NotchPanelLayout.rectContainsInclusive($0.frame, point: pointer) })
                ?? NSScreen.main
        }()

        let fullScreenSuppressed = targetScreen.map { isFullScreenVideoOrSpaceActive(on: $0) } ?? false

        let transition = stateMachine.step(
            pointerLocation: pointer,
            screens: metrics,
            isPanelEnabled: coordinator.notchPanelEnabled,
            isLeftEdgeEnabled: coordinator.leftEdgePanelEnabled,
            isFullScreenSuppressed: fullScreenSuppressed,
            isMouseButtonPressed: mouseButtonsPressed,
            currentPanelFrame: settledPanelFrame,
            now: now
        )

        switch transition {
        case .none:
            break
        case .show(let anchor, let screenIndex):
            if nsScreens.indices.contains(screenIndex) {
                showPanel(anchor: anchor, on: nsScreens[screenIndex], metrics: metrics[screenIndex])
            }
        case .hide:
            hidePanel(animated: true)
        }

        updateHoveredSlotHighlight(globalPointer: pointer)
        scheduleDwellWakeupIfNeeded(now: now)
    }

    private func scheduleDwellWakeupIfNeeded(now: TimeInterval) {
        dwellWakeupTask?.cancel()
        dwellWakeupTask = nil

        guard stateMachine.pendingHover != nil,
              let delay = stateMachine.nextWakeupDelay(now: now) else {
            return
        }

        let nanoseconds = UInt64((delay + 0.015) * 1_000_000_000)
        dwellWakeupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.evaluateCurrentPointer()
        }
    }

    private func startVisibleWatchdog() {
        visibleWatchdogTask?.cancel()
        visibleWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 75_000_000) // 75 ms
                guard !Task.isCancelled, let self, self.isPanelVisible else { return }
                if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape)) {
                    self.dismissPanelImmediately()
                    return
                }
                self.evaluateCurrentPointer()
            }
        }
    }

    private func updateHoveredSlotHighlight(globalPointer: CGPoint) {
        guard isPanelVisible, let frame = settledPanelFrame else {
            if presentation.hoveredSlotIndex != nil {
                presentation.hoveredSlotIndex = nil
            }
            return
        }
        let localPoint = CGPoint(x: globalPointer.x - frame.origin.x, y: globalPointer.y - frame.origin.y)
        let hitSlot = MacNotchPanelView.hitTestSlotIndex(at: localPoint)
        if presentation.hoveredSlotIndex != hitSlot {
            presentation.hoveredSlotIndex = hitSlot
        }
    }

    // MARK: - Show & Hide Panel

    private func ensurePanelCreated() -> ChocNotchFloatingPanel? {
        if let existing = panel {
            return existing
        }
        guard let coordinator else { return nil }

        let size = MacNotchPanelView.windowSize
        let created = ChocNotchFloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        created.onEscapePressed = { [weak self] in
            self?.dismissPanelImmediately()
        }

        let rootView = MacNotchPanelView(
            coordinator: coordinator,
            presentation: presentation,
            onTriggerItem: { [weak self] item in
                self?.handleTileTriggered(item)
            },
            onOpenStudio: { [weak self] in
                self?.openStudioWindow()
            },
            onDismiss: { [weak self] in
                self?.dismissPanelImmediately()
            }
        )

        let host = FirstMouseHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        created.contentView = host

        self.hostingView = host
        self.panel = created
        return created
    }

    private func showPanel(anchor: NotchPanelAnchor, on screen: NSScreen, metrics: NotchScreenMetrics) {
        guard let panel = ensurePanelCreated() else { return }

        visibilityGeneration &+= 1
        let capturedGen = visibilityGeneration
        presentation.anchor = anchor
        presentation.inlineFeedback = nil

        let targetSize = MacNotchPanelView.windowSize
        let targetFrame = NotchPanelLayout.panelFrame(
            for: anchor,
            panelSize: targetSize,
            screen: metrics
        )
        settledPanelFrame = targetFrame

        isPanelVisible = true
        registerTemporaryEscapeHotKey()
        startVisibleWatchdog()

        panel.alphaValue = 0
        panel.setFrame(targetFrame, display: true)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, self.visibilityGeneration == capturedGen else { return }
                panel?.alphaValue = 1
            }
        })
    }

    private func hidePanel(animated: Bool) {
        dwellWakeupTask?.cancel()
        dwellWakeupTask = nil
        visibleWatchdogTask?.cancel()
        visibleWatchdogTask = nil
        unregisterTemporaryEscapeHotKey()

        presentation.hoveredSlotIndex = nil
        settledPanelFrame = nil
        isPanelVisible = false
        visibilityGeneration &+= 1
        let capturedGen = visibilityGeneration

        guard let panel, panel.isVisible else { return }

        if !animated {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.11
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, self.visibilityGeneration == capturedGen else { return }
                panel?.alphaValue = 0
                panel?.orderOut(nil)
            }
        })

        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let self, self.visibilityGeneration == capturedGen else { return }
            panel?.alphaValue = 0
            panel?.orderOut(nil)
        }
    }

    private func orderOutImmediately() {
        isPanelVisible = false
        settledPanelFrame = nil
        presentation.hoveredSlotIndex = nil
        visibilityGeneration &+= 1
        panel?.alphaValue = 0
        panel?.orderOut(nil)
    }

    // MARK: - Actions

    private func handleTileTriggered(_ item: BarItem) {
        guard let coordinator else { return }
        let sourceName = L10n.tr("Mac 悬浮栏", "Mac Notch Bar", language: coordinator.lang)

        let shouldDismissBeforeAction: Bool = {
            if case .systemAction(let action, _, _) = item.kind {
                switch action {
                case .screenshotInteractive, .missionControl, .showDesktop, .lockScreen, .toggleFullscreen:
                    return true
                default:
                    return false
                }
            }
            return false
        }()

        if shouldDismissBeforeAction {
            _ = stateMachine.dismissImmediately(suppressUntilTriggerExit: true)
            orderOutImmediately()
            unregisterTemporaryEscapeHotKey()
            visibleWatchdogTask?.cancel()
            visibleWatchdogTask = nil
        }

        Task { @MainActor [weak self, weak coordinator] in
            guard let coordinator else { return }
            let feedback = await coordinator.triggerBarItem(item, triggeredBy: sourceName)
            if !shouldDismissBeforeAction {
                let label = feedback.success ? "✓ \(item.displayTitle(in: coordinator.lang))" : feedback.detail
                self?.presentation.flashFeedback(label)
            }
        }
    }

    private func openStudioWindow() {
        guard let coordinator else { return }
        dismissPanelImmediately()
        coordinator.selectedSection = .chocolateBar
        NSApp.activate(ignoringOtherApps: true)

        if let studioWin = NSApp.windows.first(where: { win in
            !(win is NSPanel) && (win.identifier?.rawValue.contains("studio-main") == true || win.title == "choclift")
        }) {
            studioWin.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    // MARK: - Screen Metrics & Full-Screen Video / Space Detection

    private static func makeMetrics(for screen: NSScreen) -> NotchScreenMetrics {
        let topInset: CGFloat
        let auxLeft: CGRect?
        let auxRight: CGRect?
        topInset = screen.safeAreaInsets.top
        auxLeft = screen.auxiliaryTopLeftArea
        auxRight = screen.auxiliaryTopRightArea

        return NotchScreenMetrics(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: topInset,
            auxiliaryTopLeftRect: auxLeft,
            auxiliaryTopRightRect: auxRight
        )
    }

    private func isFullScreenVideoOrSpaceActive(on screen: NSScreen) -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              !frontApp.isTerminated,
              frontApp.processIdentifier != myPID else {
            return false
        }

        let metrics = Self.makeMetrics(for: screen)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height

        // When Accessibility is granted, inspect AXFullScreen directly on the focused window.
        if AXIsProcessTrusted() {
            let appElem = AXUIElementCreateApplication(frontApp.processIdentifier)
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
               let winVal = winRef,
               CFGetTypeID(winVal) == AXUIElementGetTypeID() {
                let winElem = winVal as! AXUIElement
                var fsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(winElem, "AXFullScreen" as CFString, &fsRef) == .success,
                   let isFS = fsRef as? Bool,
                   isFS {
                    if let quartzFrame = Self.readAXWindowQuartzRect(winElem) {
                        let appKitFrame = NotchPanelLayout.appKitScreenRect(
                            fromQuartzRect: quartzFrame,
                            primaryScreenHeight: primaryHeight
                        )
                        if appKitFrame.intersects(screen.frame) {
                            return true
                        }
                    } else {
                        return true
                    }
                }
            }
        }

        // Fallback without Accessibility: check if the menu bar is hidden on this screen AND
        // a frontmost layer-0 window covers 100% of the physical screen frame (e.g., full-screen video).
        guard metrics.menuBarHeight <= 1.0,
              let infoList = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }

        let frontPID = frontApp.processIdentifier
        for entry in infoList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontPID,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = entry[kCGWindowAlpha as String] as? Double,
                  alpha > 0.01,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let quartzRect = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            let appKitRect = NotchPanelLayout.appKitScreenRect(
                fromQuartzRect: quartzRect,
                primaryScreenHeight: primaryHeight
            )
            if NotchPanelLayout.windowCoversFullScreen(
                windowFrameInScreenCoords: appKitRect,
                screen: metrics
            ) {
                return true
            }
        }

        return false
    }

    private static func readAXWindowQuartzRect(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef,
              let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}
