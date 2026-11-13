import AppKit
import ApplicationServices
import ChocliftCore
import CoreGraphics
import EventKit
import Foundation
import ScreenCaptureKit

// MARK: - 1. Safe Mac Clipboard Monitor & Plain-Text Extractor

@MainActor
public final class MacClipboardMonitorService {
    public var isTransientPasteInFlight: (() -> Bool)?
    public var onPreviewChanged: ((ClipboardPreviewSnapshot) -> Void)?
    public private(set) var currentPreview: ClipboardPreviewSnapshot = .empty

    private var lastObservedChangeCount: Int?

    public init() {
        refreshImmediately()
    }

    public func refreshImmediately() {
        lastObservedChangeCount = nil
        pollIfNeeded()
    }

    public func pollIfNeeded() {
        if isTransientPasteInFlight?() == true {
            return
        }
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        if lastObservedChangeCount == currentCount {
            return
        }
        lastObservedChangeCount = currentCount

        let types = Self.collectPasteboardTypes(from: pb)
        let rawText: String?
        if ClipboardPreviewEvaluator.isSafePlainTextPasteboard(pasteboardTypes: types) {
            rawText = pb.string(forType: .string)
        } else {
            rawText = nil
        }

        let evaluated = ClipboardPreviewEvaluator.evaluate(
            pasteboardTypes: types,
            string: rawText
        )
        if evaluated != currentPreview {
            currentPreview = evaluated
            onPreviewChanged?(evaluated)
        }
    }

    /// Reads the current Mac clipboard plain text for pasting into the focused Mac text field,
    /// rejecting images, file copies, and concealed/password items.
    public func currentInsertablePlainText() -> String? {
        if isTransientPasteInFlight?() == true {
            return nil
        }
        let pb = NSPasteboard.general
        let types = Self.collectPasteboardTypes(from: pb)
        guard ClipboardPreviewEvaluator.isSafePlainTextPasteboard(pasteboardTypes: types) else {
            return nil
        }
        return ClipboardPreviewEvaluator.extractInsertablePlainText(
            pasteboardTypes: types,
            string: pb.string(forType: .string)
        )
    }

    private static func collectPasteboardTypes(from pasteboard: NSPasteboard) -> Set<String> {
        var collected = Set<String>()
        if let topTypes = pasteboard.types {
            for type in topTypes {
                collected.insert(type.rawValue)
            }
        }
        if let items = pasteboard.pasteboardItems {
            for item in items {
                for type in item.types {
                    collected.insert(type.rawValue)
                }
            }
        }
        return collected
    }
}

// MARK: - 2. User-Requested Main Display Screenshot Service (Saved to Desktop, Never Uploaded)

@MainActor
public final class MacMainDisplayScreenshotService {
    public struct CaptureOutcome {
        public let wireResult: ScreenshotCaptureResult
        public let feedbackTitle: String
        public let feedbackDetail: String
    }

    private static let maxPreviewDimension: CGFloat = 320

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()

    public init() {}

    public func captureMainDisplayToDesktop(language: AppLanguage = .system) async -> CaptureOutcome {
        let title = L10n.tr("主屏幕截图", "Main Display Screenshot", language: language)

        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            let deniedDetail = L10n.tr(
                "请在系统设置 → 隐私与安全性 → 录屏中授权 Choclift 后截屏",
                "Grant Screen Recording permission in System Settings → Privacy & Security to capture your display",
                language: language
            )
            return CaptureOutcome(
                wireResult: .failed(errorMessage: deniedDetail),
                feedbackTitle: title,
                feedbackDetail: deniedDetail
            )
        }

        guard let cgImage = await Self.captureMainDisplayCGImage(),
              cgImage.width > 1,
              cgImage.height > 1 else {
            let captureFailedDetail = L10n.tr(
                "无法截取主显示器，请检查系统录屏权限设置",
                "Could not capture the main display — check Screen Recording permission in System Settings",
                language: language
            )
            return CaptureOutcome(
                wireResult: .failed(errorMessage: captureFailedDetail),
                feedbackTitle: title,
                feedbackDetail: captureFailedDetail
            )
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            let encodeErr = L10n.tr("生成 PNG 截图文件失败", "Failed to encode screenshot PNG", language: language)
            return CaptureOutcome(
                wireResult: .failed(errorMessage: encodeErr),
                feedbackTitle: title,
                feedbackDetail: encodeErr
            )
        }

        let fm = FileManager.default
        let desktopDir = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        try? fm.createDirectory(at: desktopDir, withIntermediateDirectories: true)

        let capturedAt = Date()
        let stamp = Self.fileTimestampFormatter.string(from: capturedAt)
        let baseName = "Choclift Screenshot \(stamp)"
        let targetURL = Self.uniqueDesktopFileURL(directory: desktopDir, baseName: baseName, ext: "png")
        let fileName = targetURL.lastPathComponent

        do {
            try pngData.write(to: targetURL, options: .atomic)
        } catch {
            let saveErr = L10n.tr(
                "无法保存截图到桌面：\(error.localizedDescription)",
                "Could not save screenshot to Desktop: \(error.localizedDescription)",
                language: language
            )
            return CaptureOutcome(
                wireResult: .failed(errorMessage: saveErr, capturedAt: capturedAt),
                feedbackTitle: title,
                feedbackDetail: saveErr
            )
        }

        let previewJPEG = Self.makeSmallJPEGPreview(from: cgImage, maxDimension: Self.maxPreviewDimension)
        let savedDetail = L10n.tr(
            "已保存到 Mac 桌面：\(fileName)",
            "Saved to Mac Desktop: \(fileName)",
            language: language
        )
        return CaptureOutcome(
            wireResult: .succeeded(
                fileName: fileName,
                previewJPEGData: previewJPEG,
                capturedAt: capturedAt
            ),
            feedbackTitle: title,
            feedbackDetail: savedDetail
        )
    }

    private static func captureMainDisplayCGImage() async -> CGImage? {
        let mainID = CGMainDisplayID()
        if #available(macOS 14.0, *) {
            if let shareable = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let scDisplay = shareable.displays.first(where: { $0.displayID == mainID }) ?? shareable.displays.first {
                let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                let config = SCStreamConfiguration()
                let scaleFactor = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == scDisplay.displayID
                })?.backingScaleFactor ?? 2.0
                config.width = max(1, Int(CGFloat(scDisplay.width) * scaleFactor))
                config.height = max(1, Int(CGFloat(scDisplay.height) * scaleFactor))
                config.showsCursor = false
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    return image
                }
            }
        }
        return CGDisplayCreateImage(mainID)
    }

    private static func uniqueDesktopFileURL(directory: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        let candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        for suffix in 2...999 {
            let numbered = directory.appendingPathComponent("\(baseName) (\(suffix)).\(ext)")
            if !fm.fileExists(atPath: numbered.path) {
                return numbered
            }
        }
        return directory.appendingPathComponent("\(baseName) (\(UUID().uuidString.prefix(6))).\(ext)")
    }

    private static func makeSmallJPEGPreview(from image: CGImage, maxDimension: CGFloat) -> Data? {
        let srcW = CGFloat(image.width)
        let srcH = CGFloat(image.height)
        guard srcW > 0, srcH > 0 else { return nil }

        let scale = min(1.0, maxDimension / max(srcW, srcH))
        let dstW = max(1, Int((srcW * scale).rounded()))
        let dstH = max(1, Int((srcH * scale).rounded()))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        guard let scaledCG = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaledCG)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.58])
    }
}

// MARK: - 3. Read-Only Next Calendar Event Service (EventKit, Zero Writes)

@MainActor
public final class MacCalendarEventService {
    public var onSnapshotChanged: ((NextCalendarEventSnapshot) -> Void)?
    public private(set) var currentSnapshot: NextCalendarEventSnapshot = .initial

    private let eventStore = EKEventStore()
    private var storeChangedObserver: NSObjectProtocol?
    private var periodicRefreshTask: Task<Void, Never>?
    private var hasPromptedForAccess = false

    private static let lookaheadSeconds: TimeInterval = 7 * 24 * 3600

    public init() {}

    public func start() {
        stop()
        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot(requestAccessIfUndetermined: false)
            }
        }

        refreshSnapshot(requestAccessIfUndetermined: true)

        periodicRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { break }
                self.refreshSnapshot(requestAccessIfUndetermined: false)
            }
        }
    }

    public func stop() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        if let storeChangedObserver {
            NotificationCenter.default.removeObserver(storeChangedObserver)
            self.storeChangedObserver = nil
        }
    }

    public func refreshSnapshot(requestAccessIfUndetermined: Bool = false) {
        let status = EKEventStore.authorizationStatus(for: .event)

        if Self.isReadAuthorized(status) {
            let now = Date()
            let horizon = now.addingTimeInterval(Self.lookaheadSeconds)
            let predicate = eventStore.predicateForEvents(withStart: now, end: horizon, calendars: nil)
            let events = eventStore.events(matching: predicate)
            let candidates = events.map { ev in
                CalendarEventCandidate(
                    title: ev.title ?? "",
                    startDate: ev.startDate,
                    endDate: ev.endDate,
                    isAllDay: ev.isAllDay,
                    isCanceled: ev.status == .canceled
                )
            }
            let next = NextCalendarEventSnapshot.selectNextEvent(from: candidates, now: now)
            publish(NextCalendarEventSnapshot(permission: .authorized, nextEvent: next))
            return
        }

        if status == .notDetermined {
            publish(.initial)
            if requestAccessIfUndetermined && !hasPromptedForAccess {
                hasPromptedForAccess = true
                requestReadAccess()
            }
            return
        }

        // .denied, .restricted, or .writeOnly (cannot read calendar events)
        publish(NextCalendarEventSnapshot(permission: .denied, nextEvent: nil))
    }

    private func requestReadAccess() {
        let store = eventStore
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.eventStore.reset()
                    self?.refreshSnapshot(requestAccessIfUndetermined: false)
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.eventStore.reset()
                    self?.refreshSnapshot(requestAccessIfUndetermined: false)
                }
            }
        }
    }

    private func publish(_ updated: NextCalendarEventSnapshot) {
        guard updated != currentSnapshot else { return }
        currentSnapshot = updated
        onSnapshotChanged?(updated)
    }

    private static func isReadAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }
}
