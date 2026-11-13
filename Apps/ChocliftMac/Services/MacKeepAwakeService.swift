import AppKit
import ChocliftCore
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Manages an `IOPMAssertion` (`PreventUserIdleSystemSleep`) driven by `MacAwakeAssertionStateMachine`.
///
/// Behavior:
/// - Prevents idle *system* sleep while enabled and at least one companion is connected.
/// - Display may still sleep normally (`PreventUserIdleDisplaySleep` is NOT asserted).
/// - Turning the toggle off or disconnecting the last companion immediately releases the assertion.
/// - Never mutates persistent Energy Saver / `pmset` defaults.
@MainActor
public final class MacKeepAwakeService {
    public var onAssertionStateChanged: ((Bool) -> Void)?

    public private(set) var stateMachine = MacAwakeAssertionStateMachine()
    private var activeAssertionID: IOPMAssertionID?
    private var terminationObserver: NSObjectProtocol?

    public init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let assertionID = activeAssertionID {
            IOPMAssertionRelease(assertionID)
        }
    }

    public var isHoldingAssertion: Bool {
        activeAssertionID != nil && stateMachine.shouldHoldAssertion
    }

    @discardableResult
    public func setToggleEnabled(_ enabled: Bool) -> Bool {
        let previous = isHoldingAssertion
        _ = stateMachine.setToggleEnabled(enabled)
        let ok = reconcileSystemAssertion()
        let current = isHoldingAssertion
        if current != previous {
            onAssertionStateChanged?(current)
        }
        return enabled ? (ok && current) : !current
    }

    public func updateConnectedCompanionDeviceIDs(_ connectedIDs: Set<String>) {
        let previous = isHoldingAssertion
        _ = stateMachine.updateConnectedDevices(connectedIDs)
        _ = reconcileSystemAssertion()
        let current = isHoldingAssertion
        if current != previous {
            onAssertionStateChanged?(current)
        }
    }

    public func stop() {
        let previous = isHoldingAssertion
        stateMachine.reset()
        releaseAssertionIfHeld()
        if previous {
            onAssertionStateChanged?(false)
        }
    }

    @discardableResult
    private func reconcileSystemAssertion() -> Bool {
        if stateMachine.shouldHoldAssertion {
            guard activeAssertionID == nil else { return true }
            var createdID: IOPMAssertionID = 0
            let reason = "Choclift Companion Keep Mac Awake" as CFString
            let assertionType = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
            let result = IOPMAssertionCreateWithName(
                assertionType,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason,
                &createdID
            )
            if result == kIOReturnSuccess {
                activeAssertionID = createdID
                return true
            } else {
                _ = stateMachine.setToggleEnabled(false)
                activeAssertionID = nil
                return false
            }
        } else {
            releaseAssertionIfHeld()
            return true
        }
    }

    private func releaseAssertionIfHeld() {
        guard let assertionID = activeAssertionID else { return }
        IOPMAssertionRelease(assertionID)
        activeAssertionID = nil
    }
}
