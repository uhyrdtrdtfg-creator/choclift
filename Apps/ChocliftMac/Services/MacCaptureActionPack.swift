import AppKit
import ApplicationServices
import ChocliftCore
import CoreGraphics
import Darwin
import Foundation

enum MacCaptureActionPack {
    @MainActor
    private static let windowService = MacAccessibilityAndWindowService()

    static func run(
        id: String,
        preferredPID: pid_t?,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        CaptureCommandPlan.execute(
            id: id,
            language: language,
            frontWindowID: {
                resolveFrontWindowIDOnMainActor(preferredPID: preferredPID)
            },
            desktopDirectoryURL: {
                resolveVerifiedDesktopDirectoryURL()
            },
            runProcess: { spec in
                runScreencaptureProcess(
                    spec,
                    timeoutSeconds: CaptureCommandPlan.defaultTimeoutSeconds
                )
            }
        )
    }

    private static func resolveFrontWindowIDOnMainActor(preferredPID: pid_t?) -> UInt32? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                windowService.frontmostCaptureWindowID(preferredPID: preferredPID)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                windowService.frontmostCaptureWindowID(preferredPID: preferredPID)
            }
        }
    }

    private static func resolveVerifiedDesktopDirectoryURL(
        fileManager: FileManager = .default
    ) -> Result<URL, CaptureActionFailure> {
        let desktopURL = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: desktopURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.desktopDirectoryUnavailable)
        }
        return .success(desktopURL.standardizedFileURL)
    }

    private static func runScreencaptureProcess(
        _ spec: CaptureCommandSpec,
        timeoutSeconds: TimeInterval
    ) -> Result<CaptureProcessResult, CaptureActionFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executablePath)
        process.arguments = spec.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        let lock = NSLock()
        var didTimeOut = false
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + timeoutSeconds)
        timer.setEventHandler {
            lock.lock()
            didTimeOut = true
            lock.unlock()
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                    if process.isRunning, pid > 0 {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
        timer.resume()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()

        lock.lock()
        let timedOut = didTimeOut
        lock.unlock()

        let capped = stderrData.count > 8192 ? stderrData.prefix(8192) : stderrData[...]
        let stderrText = String(decoding: capped, as: UTF8.self)
        return .success(
            CaptureProcessResult(
                exitCode: process.terminationStatus,
                stderr: stderrText,
                timedOut: timedOut
            )
        )
    }
}

extension MacAccessibilityAndWindowService {
    /// Resolves the front window's `CGWindowID` without triggering any Accessibility or Screen Recording TCC prompt.
    public func frontmostCaptureWindowID(preferredPID: pid_t?) -> CGWindowID? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let hostBundleID = Bundle.main.bundleIdentifier

        if let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           frontBundle == "com.apple.loginwindow" {
            return nil
        }

        func isEligibleExternalApp(_ app: NSRunningApplication) -> Bool {
            guard !app.isTerminated,
                  app.processIdentifier > 0,
                  app.processIdentifier != selfPID else {
                return false
            }
            if let bundleID = app.bundleIdentifier {
                if bundleID == "com.apple.loginwindow" {
                    return false
                }
                if SessionCompanionActionRouting.isChocliftBundle(
                    bundleID,
                    hostBundleIdentifier: hostBundleID
                ) {
                    return false
                }
            }
            return true
        }

        let primaryApp: NSRunningApplication? = {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  isEligibleExternalApp(front) else {
                return nil
            }
            return front
        }()

        let fallbackApp: NSRunningApplication? = {
            guard let preferredPID,
                  preferredPID > 0,
                  let app = NSRunningApplication(processIdentifier: preferredPID),
                  isEligibleExternalApp(app) else {
                return nil
            }
            return app
        }()

        var eligibleOwnerPIDs = Set<Int32>()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && isEligibleExternalApp(app) {
            eligibleOwnerPIDs.insert(Int32(app.processIdentifier))
        }
        if let primaryApp {
            eligibleOwnerPIDs.insert(Int32(primaryApp.processIdentifier))
        }
        if let fallbackApp {
            eligibleOwnerPIDs.insert(Int32(fallbackApp.processIdentifier))
        }

        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let candidates: [CaptureWindowCandidate] = infoList.compactMap { entry in
            guard let windowNumber = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  windowNumber > 0,
                  let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID > 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else {
                return nil
            }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            return CaptureWindowCandidate(
                windowID: windowNumber,
                ownerPID: ownerPID,
                layer: layer,
                alpha: alpha,
                bounds: WindowQuartzRect(rect),
                isOnScreen: isOnScreen
            )
        }

        let axTrusted = isAccessibilityTrusted()
        let primaryAXFrame = (axTrusted && primaryApp != nil)
            ? Self.focusedOpenAXWindowQuartzRect(forPID: primaryApp!.processIdentifier)
            : nil
        let fallbackAXFrame = (axTrusted && fallbackApp != nil && fallbackApp?.processIdentifier != primaryApp?.processIdentifier)
            ? Self.focusedOpenAXWindowQuartzRect(forPID: fallbackApp!.processIdentifier)
            : nil

        return CaptureFrontWindowResolver.resolveWindowID(
            candidates: candidates,
            primaryPID: primaryApp.map { Int32($0.processIdentifier) },
            primaryFocusedFrame: primaryAXFrame,
            fallbackPID: fallbackApp.map { Int32($0.processIdentifier) },
            fallbackFocusedFrame: fallbackAXFrame,
            eligibleOwnerPIDs: eligibleOwnerPIDs,
            selfPID: Int32(selfPID)
        )
    }

    private static func focusedOpenAXWindowQuartzRect(forPID pid: pid_t) -> WindowQuartzRect? {
        let appElement = AXUIElementCreateApplication(pid)

        func openQuartzRect(from attribute: CFString) -> WindowQuartzRect? {
            var winRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, attribute, &winRef) == .success,
                  let winRef,
                  CFGetTypeID(winRef) == AXUIElementGetTypeID() else {
                return nil
            }
            let window = winRef as! AXUIElement

            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
               let isMinimized = minRef as? Bool,
               isMinimized {
                return nil
            }

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
            guard AXValueGetValue(posVal as! AXValue, .cgPoint, &point),
                  AXValueGetValue(sizeVal as! AXValue, .cgSize, &size),
                  size.width > 0,
                  size.height > 0 else {
                return nil
            }
            return WindowQuartzRect(CGRect(origin: point, size: size))
        }

        return openQuartzRect(from: kAXFocusedWindowAttribute as CFString)
            ?? openQuartzRect(from: kAXMainWindowAttribute as CFString)
    }
}
