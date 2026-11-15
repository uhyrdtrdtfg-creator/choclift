import AppKit
import ChocliftCore
import Foundation

@MainActor
public final class MacAppAndShortcutCatalogService {
    private var iconPNGCache: [String: Data] = [:]
    private var appPathByBundleID: [String: String] = [:]

    public init() {}

    // MARK: - App Catalog Scanning (v2.3.5 Reliable Discovery)

    public func scanInstalledApps() async -> [InstalledAppSummary] {
        let discoveredPaths = await Task.detached(priority: .userInitiated) { () -> [(bundleID: String, name: String, path: String)] in
            let fm = FileManager.default
            var roots: [URL] = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications"),
                URL(fileURLWithPath: "/System/Applications/Utilities"),
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            ]

            let setappURL = URL(fileURLWithPath: "/Applications/Setapp")
            if fm.fileExists(atPath: setappURL.path) {
                roots.append(setappURL)
            }

            var candidateAppURLs: [URL] = [
                URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
            ]

            func collectApps(in dir: URL, depth: Int) {
                guard depth <= 2,
                      let children = try? fm.contentsOfDirectory(
                          at: dir,
                          includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                          options: [.skipsHiddenFiles]
                      ) else {
                    return
                }
                for child in children {
                    if child.pathExtension.lowercased() == "app" {
                        candidateAppURLs.append(child)
                    } else if depth < 2 {
                        let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        let isPkg = (try? child.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
                        if isDir && !isPkg {
                            collectApps(in: child, depth: depth + 1)
                        }
                    }
                }
            }

            for root in roots {
                collectApps(in: root, depth: 0)
            }

            var seenBundles = Set<String>()
            var entries: [(bundleID: String, name: String, path: String)] = []

            for appURL in candidateAppURLs {
                guard let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.isEmpty,
                      seenBundles.insert(bundleID).inserted else {
                    continue
                }
                let rawDisplay = fm.displayName(atPath: appURL.path)
                let cleanedName: String
                if rawDisplay.lowercased().hasSuffix(".app") {
                    cleanedName = String(rawDisplay.dropLast(4))
                } else {
                    cleanedName = rawDisplay
                }
                entries.append((bundleID, cleanedName, appURL.path))
            }

            entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return entries
        }.value

        var summaries: [InstalledAppSummary] = []
        summaries.reserveCapacity(discoveredPaths.count)
        for item in discoveredPaths {
            appPathByBundleID[item.bundleID] = item.path
            let png = iconData(forBundleID: item.bundleID, fallbackPath: item.path)
            summaries.append(
                InstalledAppSummary(
                    bundleIdentifier: item.bundleID,
                    appName: item.name,
                    appPath: item.path,
                    iconPNGData: png
                )
            )
        }
        return summaries
    }

    public func iconData(forBundleID bundleID: String, fallbackPath: String? = nil) -> Data? {
        if let cached = iconPNGCache[bundleID] {
            return cached
        }

        let resolvedURL: URL? = {
            if let fallbackPath, FileManager.default.fileExists(atPath: fallbackPath) {
                return URL(fileURLWithPath: fallbackPath)
            }
            if let knownPath = appPathByBundleID[bundleID], FileManager.default.fileExists(atPath: knownPath) {
                return URL(fileURLWithPath: knownPath)
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }()

        guard let appURL = resolvedURL else { return nil }
        appPathByBundleID[bundleID] = appURL.path
        let nsIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        guard let png = Self.encodeNSImageToPNG(nsIcon, targetDimension: 96) else { return nil }
        iconPNGCache[bundleID] = png
        return png
    }

    public func iconsBatch(for bundleIDs: [String]) -> [String: Data] {
        var result: [String: Data] = [:]
        for id in bundleIDs {
            if let data = iconData(forBundleID: id) {
                result[id] = data
            }
        }
        return result
    }

    public static func encodeNSImageToPNG(_ image: NSImage, targetDimension: Int = 96) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetDimension,
            pixelsHigh: targetDimension,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = NSSize(width: targetDimension, height: targetDimension)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetDimension, height: targetDimension),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - App Launch & Switch (with Drag & Drop 2.0 Support)

    public func launchOrActivateApp(
        bundleIdentifier: String,
        appPath: String?,
        windowService: MacAccessibilityAndWindowService
    ) async -> (success: Bool, message: String) {
        let outcome = await launchOrActivateAppWithHandle(
            bundleIdentifier: bundleIdentifier,
            appPath: appPath,
            windowService: windowService
        )
        return (outcome.success, outcome.message)
    }

    public func launchOrActivateAppWithHandle(
        bundleIdentifier: String,
        appPath: String?,
        windowService: MacAccessibilityAndWindowService
    ) async -> (success: Bool, message: String, app: FlowAppHandle?) {
        let directRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
        let runningMatches: [NSRunningApplication] = !directRunning.isEmpty
            ? directRunning
            : NSWorkspace.shared.runningApplications.filter {
                !$0.isTerminated &&
                $0.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            }

        if let running = runningMatches.first {
            running.unhide()
            windowService.unminimizeFirstWindowIfAllMinimized(pid: running.processIdentifier)
            running.activate(options: [.activateAllWindows])
        }

        let canonicalBundleID = runningMatches.first?.bundleIdentifier ?? bundleIdentifier

        let resolvedURL: URL? = {
            if let appPath, FileManager.default.fileExists(atPath: appPath) {
                return URL(fileURLWithPath: appPath)
            }
            if let cached = appPathByBundleID[canonicalBundleID] ?? appPathByBundleID[bundleIdentifier],
               FileManager.default.fileExists(atPath: cached) {
                return URL(fileURLWithPath: cached)
            }
            if let direct = NSWorkspace.shared.urlForApplication(withBundleIdentifier: canonicalBundleID) {
                return direct
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }()

        guard let appURL = resolvedURL else {
            if let running = runningMatches.first {
                let handle = FlowAppHandle(
                    bundleIdentifier: running.bundleIdentifier ?? canonicalBundleID,
                    appName: running.localizedName ?? canonicalBundleID,
                    processIdentifier: running.processIdentifier
                )
                return (true, L10n.tr("已切换到应用", "Switched to app"), handle)
            }
            return (
                false,
                L10n.tr("未在 Mac 上找到该应用 (\(bundleIdentifier))", "App not found on Mac (\(bundleIdentifier))"),
                nil
            )
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        do {
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            windowService.unminimizeFirstWindowIfAllMinimized(pid: app.processIdentifier)
            app.activate(options: [.activateAllWindows])
            let handle = FlowAppHandle(
                bundleIdentifier: app.bundleIdentifier ?? canonicalBundleID,
                appName: app.localizedName ?? canonicalBundleID,
                processIdentifier: app.processIdentifier
            )
            return (
                true,
                L10n.tr("已打开 \(app.localizedName ?? bundleIdentifier)", "Activated \(app.localizedName ?? bundleIdentifier)"),
                handle
            )
        } catch {
            return (false, error.localizedDescription, nil)
        }
    }

    // MARK: - Apple Shortcuts Integration

    public func fetchInstalledShortcuts() async -> [InstalledShortcutSummary] {
        await Task.detached(priority: .utility) {
            let shortcutsBinary = URL(fileURLWithPath: "/usr/bin/shortcuts")
            guard FileManager.default.isExecutableFile(atPath: shortcutsBinary.path) else {
                return []
            }

            let proc = Process()
            proc.executableURL = shortcutsBinary
            proc.arguments = ["list"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()

            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    return []
                }
                return text
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { InstalledShortcutSummary(name: $0) }
            } catch {
                return []
            }
        }.value
    }

    public func runShortcut(
        named shortcutName: String,
        allowSchemeFallback: Bool = true
    ) async -> (success: Bool, message: String) {
        let trimmed = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, L10n.tr("快捷指令名称为空", "Shortcut name is empty"))
        }

        let cliResult = await Task.detached(priority: .userInitiated) { () -> (ran: Bool, status: Int32, stderr: String) in
            let shortcutsBinary = URL(fileURLWithPath: "/usr/bin/shortcuts")
            guard FileManager.default.isExecutableFile(atPath: shortcutsBinary.path) else {
                return (false, -1, "shortcuts CLI unavailable")
            }

            let proc = Process()
            proc.executableURL = shortcutsBinary
            proc.arguments = ["run", trimmed]
            let errPipe = Pipe()
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = errPipe

            do {
                try proc.run()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (true, proc.terminationStatus, errStr)
            } catch {
                return (false, -1, error.localizedDescription)
            }
        }.value

        if cliResult.ran && cliResult.status == 0 {
            return (true, L10n.tr("已运行快捷指令「\(trimmed)」", "Ran Shortcut \"\(trimmed)\""))
        }

        // Fallback to shortcuts:// URL scheme only when the CLI binary could not be launched
        // and the caller permits fire-and-forget URL scheme invocation.
        if allowSchemeFallback && !cliResult.ran,
           let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let schemeURL = URL(string: "shortcuts://run-shortcut?name=\(encoded)") {
            let opened = NSWorkspace.shared.open(schemeURL)
            if opened {
                return (true, L10n.tr("已唤起快捷指令「\(trimmed)」", "Triggered Shortcut \"\(trimmed)\""))
            }
        }

        let detail = cliResult.stderr.isEmpty
            ? L10n.tr("未找到名为「\(trimmed)」的快捷指令", "Shortcut \"\(trimmed)\" not found")
            : cliResult.stderr
        return (false, detail)
    }

    // MARK: - Website Bookmarks + Smart Existing Tab Switcher

    public func openWebsite(
        rawURL: String,
        switchExistingTab: Bool,
        browserBundleIdentifier: String? = nil
    ) async -> (success: Bool, message: String) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "https://", trimmed != "http://" else {
            return (false, L10n.tr("无效的网址：\(rawURL)", "Invalid URL: \(rawURL)"))
        }

        let normalizedString = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard let targetURL = URL(string: normalizedString),
              let host = targetURL.host(),
              !host.isEmpty else {
            return (false, L10n.tr("无效的网址：\(rawURL)", "Invalid URL: \(rawURL)"))
        }

        let preferredBrowser = browserBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let browserBundle = (preferredBrowser?.isEmpty == false) ? preferredBrowser : nil

        if switchExistingTab {
            let loweredHost = host.lowercased()
            let cleanedHost = loweredHost.hasPrefix("www.") ? String(loweredHost.dropFirst(4)) : loweredHost
            let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let switched = await Task.detached(priority: .userInitiated) {
                Self.trySwitchExistingBrowserTab(
                    matchingHost: cleanedHost,
                    runningBundleIDs: runningBundleIDs,
                    preferredBundleIdentifier: browserBundle
                )
            }.value

            if switched {
                return (true, L10n.tr("已切换到已打开的网页标签页 (\(cleanedHost))", "Switched to open browser tab (\(cleanedHost))"))
            }
        }

        if let browserBundle,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundle) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                _ = try await NSWorkspace.shared.open([targetURL], withApplicationAt: appURL, configuration: config)
                let name = FileManager.default.displayName(atPath: appURL.path)
                return (true, L10n.tr("已用 \(name) 打开 \(host)", "Opened \(host) in \(name)"))
            } catch {
                return (false, error.localizedDescription)
            }
        }

        let ok = NSWorkspace.shared.open(targetURL)
        return ok
            ? (true, L10n.tr("已打开网页 \(host)", "Opened \(host)"))
            : (false, L10n.tr("无法打开网址：\(normalizedString)", "Failed to open URL: \(normalizedString)"))
    }

    public func quitRunningApp(
        bundleIdentifier: String,
        appPath: String?
    ) -> (success: Bool, message: String) {
        let bundleID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else {
            return (false, L10n.tr("未选择要退出的应用", "No app selected to quit"))
        }
        guard !ActionFlowStep.isChocliftBundleIdentifier(bundleID) else {
            return (false, L10n.tr("不能通过动作流退出 Choclift", "Action flows cannot quit Choclift"))
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && $0.processIdentifier != myPID }
        let fallback = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated &&
            $0.processIdentifier != myPID &&
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame
        }
        let targets = matches.isEmpty ? fallback : matches
        guard !targets.isEmpty else {
            let label = targets.first?.localizedName ?? bundleID
            _ = appPath
            return (false, L10n.tr("\(label) 当前没有在运行", "\(label) is not running"))
        }
        var quitCount = 0
        var name = bundleID
        for app in targets {
            name = app.localizedName ?? name
            if app.terminate() {
                quitCount += 1
            }
        }
        guard quitCount > 0 else {
            return (false, L10n.tr("无法退出 \(name)", "Could not quit \(name)"))
        }
        return (true, L10n.tr("已退出 \(name)", "Quit \(name)"))
    }

    public func openFolderInApp(
        folderPath: String,
        bundleIdentifier: String,
        appPath: String?
    ) async -> (success: Bool, message: String) {
        let folder = ActionFlowStep.normalizedWorkingDirectoryPath(folderPath)
        guard ActionFlowStep.isValidWorkingDirectoryPath(folder) else {
            return (false, L10n.tr("工作目录无效", "Working directory is invalid"))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (false, L10n.tr("找不到工作目录：\(folder)", "Working directory not found: \(folder)"))
        }
        let bundleID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else {
            return (false, L10n.tr("未选择用来打开目录的应用", "No app selected to open the folder"))
        }
        let appURL: URL? = {
            if let appPath, FileManager.default.fileExists(atPath: appPath) {
                return URL(fileURLWithPath: appPath)
            }
            if let cached = appPathByBundleID[bundleID], FileManager.default.fileExists(atPath: cached) {
                return URL(fileURLWithPath: cached)
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }()
        guard let appURL else {
            return (false, L10n.tr("未在 Mac 上找到该应用 (\(bundleID))", "App not found on Mac (\(bundleID))"))
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
        do {
            _ = try await NSWorkspace.shared.open([folderURL], withApplicationAt: appURL, configuration: config)
            let appLabel = FileManager.default.displayName(atPath: appURL.path)
            let folderLabel = folderURL.lastPathComponent
            return (true, L10n.tr("已用 \(appLabel) 打开 \(folderLabel)", "Opened \(folderLabel) in \(appLabel)"))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    nonisolated private static func trySwitchExistingBrowserTab(
        matchingHost: String,
        runningBundleIDs: Set<String>,
        preferredBundleIdentifier: String? = nil
    ) -> Bool {
        let escapedHost = matchingHost.replacingOccurrences(of: "\"", with: "")
        guard !escapedHost.isEmpty else { return false }

        // Chromium family browsers (Chrome, Arc, Brave, Edge)
        let chromiumCandidates: [(bundleID: String, appName: String)] = [
            ("com.google.Chrome", "Google Chrome"),
            ("company.thebrowser.Browser", "Arc"),
            ("com.brave.Browser", "Brave Browser"),
            ("com.microsoft.edgemac", "Microsoft Edge")
        ]

        let preferred = preferredBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let orderedChromium: [(bundleID: String, appName: String)] = {
            guard let preferred, !preferred.isEmpty else { return chromiumCandidates }
            return chromiumCandidates.filter { $0.bundleID.caseInsensitiveCompare(preferred) == .orderedSame }
        }()

        for browser in orderedChromium where runningBundleIDs.contains(browser.bundleID) {
            let scriptSource = """
            tell application "\(browser.appName)"
                set winIdx to 1
                repeat with w in windows
                    set tabIdx to 1
                    repeat with t in tabs of w
                        if (URL of t) contains "\(escapedHost)" then
                            set active tab index of w to tabIdx
                            set index of w to 1
                            activate
                            return "FOUND"
                        end if
                        set tabIdx to tabIdx + 1
                    end repeat
                    set winIdx to winIdx + 1
                end repeat
            end tell
            return "NONE"
            """
            if runAppleScriptCheckingFound(scriptSource) {
                return true
            }
        }

        let preferSafari = preferredBundleIdentifier?.caseInsensitiveCompare("com.apple.Safari") == .orderedSame
        let allowSafari = preferredBundleIdentifier == nil || preferSafari
        if allowSafari, runningBundleIDs.contains("com.apple.Safari") {
            let safariScript = """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) contains "\(escapedHost)" then
                            set current tab of w to t
                            set index of w to 1
                            activate
                            return "FOUND"
                        end if
                    end repeat
                end repeat
            end tell
            return "NONE"
            """
            if runAppleScriptCheckingFound(safariScript) {
                return true
            }
        }

        return false
    }

    nonisolated private static func runAppleScriptCheckingFound(_ source: String) -> Bool {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let descriptor = script.executeAndReturnError(&errorDict)
        guard errorDict == nil else { return false }
        return descriptor.stringValue == "FOUND"
    }
}
