import Foundation
import XCTest
@testable import ChocliftCore

@MainActor
private final class AppDeckTestServerDelegate: MacServerEngineDelegate {
    var profile: ChocliftWorkspaceProfile
    var recentApps: [RecentAppEntry] = [
        RecentAppEntry(bundleIdentifier: "com.apple.finder", appName: "Finder", isFrontmost: true, isPinned: true)
    ]
    var frontmostBundleID: String? = "com.apple.finder"
    var triggeredItems: [BarItem] = []

    init(profile: ChocliftWorkspaceProfile) {
        self.profile = profile
    }

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { recentApps }
    func serverFrontmostBundleID() -> String? { frontmostBundleID }
    func serverTextInputState() -> (isEditing: Bool, appName: String?) { (false, nil) }
    func serverIsAccessibilityGranted() -> Bool { true }
    func serverIcons(for bundleIDs: [String]) -> [String: Data] { [:] }
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {}

    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .triggerBarItem(let item):
            triggeredItems.append(item)
            reply(.actionFeedback(success: true, title: item.displayTitle(), detail: "Triggered"))
        case .updateProfile(let updated):
            profile = updated
        default:
            break
        }
    }
}

final class AppDeckBindingsTests: XCTestCase {
    func testBindingResolvesRightPageID() {
        var profile = ChocliftDefaults.makeDefaultProfile()
        let workspacePage = profile.pages[1]
        let quickActionsPage = profile.pages[2]

        profile.setAppDeckBinding(bundleIdentifier: "com.apple.dt.Xcode", pageID: workspacePage.id)
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.Safari", pageID: quickActionsPage.id)

        XCTAssertEqual(profile.boundPageID(forBundleIdentifier: "com.apple.dt.Xcode"), workspacePage.id)
        XCTAssertEqual(profile.boundPageID(forBundleIdentifier: "com.apple.dt.xcode"), workspacePage.id)
        XCTAssertEqual(profile.boundPageID(forBundleIdentifier: "com.apple.Safari"), quickActionsPage.id)

        let resolvedXcode = profile.resolvePageID(
            forFrontmostBundleIdentifier: "com.apple.dt.Xcode",
            currentPageID: profile.pages[0].id
        )
        XCTAssertEqual(resolvedXcode, workspacePage.id)

        var follower = AppDeckFollowerState()
        follower.handleProfileUpdated(profile, frontmostBundleIdentifier: "com.apple.finder")
        XCTAssertEqual(follower.currentPageIndex, 0)
        XCTAssertEqual(follower.currentPageID, profile.pages[0].id)

        follower.handleFrontmostAppChanged("com.apple.dt.Xcode", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 1)
        XCTAssertEqual(follower.currentPageID, workspacePage.id)

        follower.handleFrontmostAppChanged("com.apple.Safari", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 2)
        XCTAssertEqual(follower.currentPageID, quickActionsPage.id)
    }

    func testMissingBindingKeepsCurrentPage() {
        var profile = ChocliftDefaults.makeDefaultProfile()
        let workspacePage = profile.pages[1]
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.dt.Xcode", pageID: workspacePage.id)

        var follower = AppDeckFollowerState()
        follower.syncCurrentPage(with: profile)
        XCTAssertEqual(follower.currentPageIndex, 0)

        // Unbound frontmost app keeps initial page 0
        follower.handleFrontmostAppChanged("com.apple.Notes", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 0)
        XCTAssertEqual(follower.currentPageID, profile.pages[0].id)

        // Bound frontmost app switches to page 1
        follower.handleFrontmostAppChanged("com.apple.dt.Xcode", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 1)
        XCTAssertEqual(follower.currentPageID, workspacePage.id)

        // Subsequent unbound or nil frontmost app keeps page 1
        follower.handleFrontmostAppChanged("com.apple.Calculator", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 1)
        XCTAssertEqual(follower.currentPageID, workspacePage.id)

        follower.handleFrontmostAppChanged(nil, in: profile)
        XCTAssertEqual(follower.currentPageIndex, 1)
        XCTAssertEqual(follower.currentPageID, workspacePage.id)
    }

    func testDeletedPageIsIgnored() {
        var profile = ChocliftDefaults.makeDefaultProfile()
        let deletedPage = profile.pages[3]
        profile.setAppDeckBinding(bundleIdentifier: "com.figma.Desktop", pageID: deletedPage.id)
        XCTAssertEqual(profile.boundPageID(forBundleIdentifier: "com.figma.Desktop"), deletedPage.id)

        // Remove the bound page without removing the dictionary entry to simulate a stale/deleted page reference
        profile.pages.removeAll { $0.id == deletedPage.id }

        XCTAssertNil(profile.boundPage(forBundleIdentifier: "com.figma.Desktop"))
        XCTAssertNil(profile.boundPageID(forBundleIdentifier: "com.figma.Desktop"))
        XCTAssertFalse(profile.referencedAppBundleIdentifiers.contains("com.figma.Desktop"))

        let currentPage = profile.pages[0]
        XCTAssertEqual(
            profile.resolvePageID(forFrontmostBundleIdentifier: "com.figma.Desktop", currentPageID: currentPage.id),
            currentPage.id
        )

        var follower = AppDeckFollowerState()
        follower.syncCurrentPage(with: profile)
        follower.handleFrontmostAppChanged("com.figma.Desktop", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 0)
        XCTAssertEqual(follower.currentPageID, currentPage.id)
    }

    func testAtMostOnePagePerBundleIDAndMultipleAppsPerPage() {
        var profile = ChocliftDefaults.makeDefaultProfile()
        let devPage = profile.pages[1]
        let mediaPage = profile.pages[4]

        // Bind multiple apps to a single page
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.dt.Xcode", pageID: devPage.id)
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.Terminal", pageID: devPage.id)

        XCTAssertEqual(
            profile.boundBundleIdentifiers(forPageID: devPage.id),
            ["com.apple.dt.Xcode", "com.apple.Terminal"]
        )
        XCTAssertEqual(profile.boundPageID(forBundleIdentifier: "com.apple.dt.Xcode"), devPage.id)
        XCTAssertEqual(profile.boundPageID(forBundleIdentifier: "com.apple.Terminal"), devPage.id)

        // Rebinding an app (even with different case) moves it to the new page rather than duplicating
        profile.setAppDeckBinding(bundleIdentifier: "COM.APPLE.TERMINAL", pageID: mediaPage.id)

        XCTAssertEqual(profile.boundBundleIdentifiers(forPageID: devPage.id), ["com.apple.dt.Xcode"])
        XCTAssertEqual(profile.boundPageID(forBundleIdentifier: "com.apple.Terminal"), mediaPage.id)
        XCTAssertEqual(profile.appDeckBindings.count, 2)
    }

    func testManualPageNavigationPinsUntilFollowFrontmostAppTappedAgain() {
        var profile = ChocliftDefaults.makeDefaultProfile()
        let workspacePage = profile.pages[1]
        let quickActionsPage = profile.pages[2]
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.dt.Xcode", pageID: workspacePage.id)
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.Safari", pageID: quickActionsPage.id)

        var follower = AppDeckFollowerState()
        follower.handleFrontmostAppChanged("com.apple.dt.Xcode", in: profile)
        XCTAssertTrue(follower.isFollowingFrontmostApp)
        XCTAssertEqual(follower.currentPageIndex, 1)

        // Manual arrow steps forward and pins to page 2
        follower.stepManualPage(by: 1, in: profile)
        XCTAssertFalse(follower.isFollowingFrontmostApp)
        XCTAssertEqual(follower.currentPageIndex, 2)

        // Frontmost app changes while pinned do NOT override manual selection
        follower.handleFrontmostAppChanged("com.apple.dt.Xcode", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 2)
        XCTAssertFalse(follower.isFollowingFrontmostApp)

        // Direct manual page selection (e.g. pill tap or swipe) also stays pinned
        follower.selectManualPage(index: 5, in: profile)
        XCTAssertEqual(follower.currentPageIndex, 5)
        follower.handleFrontmostAppChanged("com.apple.Safari", in: profile)
        XCTAssertEqual(follower.currentPageIndex, 5)

        // Tapping "Follow Frontmost App" unpins and immediately switches to Safari's bound deck
        follower.followFrontmostApp(frontmostBundleIdentifier: "com.apple.Safari", in: profile)
        XCTAssertTrue(follower.isFollowingFrontmostApp)
        XCTAssertEqual(follower.currentPageIndex, 2)
        XCTAssertEqual(follower.currentPageID, quickActionsPage.id)
    }

    func testProfileCodableRoundTripAndLegacyDecodeDefaultEmpty() throws {
        var profile = ChocliftDefaults.makeDefaultProfile()
        profile.setAppDeckBinding(bundleIdentifier: "com.apple.Safari", pageID: profile.pages[2].id)

        let encoded = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: encoded)
        XCTAssertEqual(decoded.appDeckBindings, profile.appDeckBindings)
        XCTAssertEqual(decoded, profile)

        // Simulate a legacy protocol v2 profile JSON payload without `appDeckBindings`
        var rawObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        rawObject.removeValue(forKey: "appDeckBindings")
        let legacyData = try JSONSerialization.data(withJSONObject: rawObject)
        let legacyDecoded = try JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: legacyData)
        XCTAssertTrue(legacyDecoded.appDeckBindings.isEmpty)
    }

    @MainActor
    func testFrontmostAppBroadcastSyncsIPhoneIPadAndWatchWithoutAutoRunningTiles() async throws {
        let suiteName = "com.choclift.tests.appdecks.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }

        var initialProfile = ChocliftDefaults.makeDefaultProfile()
        let xcodeDeckID = initialProfile.pages[1].id
        let musicDeckID = initialProfile.pages[4].id
        initialProfile.setAppDeckBinding(bundleIdentifier: "com.apple.dt.Xcode", pageID: xcodeDeckID)
        initialProfile.setAppDeckBinding(bundleIdentifier: "com.apple.Music", pageID: musicDeckID)

        let delegate = AppDeckTestServerDelegate(profile: initialProfile)
        let server = MacServerEngine(macID: "mac-appdecks-host", macName: "Studio Mac")
        server.delegate = delegate
        defer { server.stop() }

        func connectCompanion(id: String, name: String, platform: DevicePlatform, prefix: String) async throws -> CompanionClientEngine {
            let client = CompanionClientEngine(
                deviceID: id,
                deviceName: name,
                platform: platform,
                userDefaults: isolatedDefaults,
                storageKeyPrefix: prefix
            )
            let (serverPipe, clientPipe) = SimulatedBLECompanionPipe.pair()
            server.acceptCompanionTransport(serverPipe, link: .bluetooth)
            client.connectInMemoryBluetooth(to: clientPipe, targetName: "Studio Mac")

            let pinDeadline = Date().addingTimeInterval(2.0)
            while Date() < pinDeadline {
                if case .awaitingPIN = client.connectionState { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            client.submitPIN(server.currentPIN)

            let authDeadline = Date().addingTimeInterval(2.0)
            while Date() < authDeadline {
                if client.connectionState.isConnected { return client }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Timed out connecting \(name)")
            return client
        }

        let iphoneClient = try await connectCompanion(id: "iphone-1", name: "iPhone", platform: .iPhone, prefix: "ip")
        defer { iphoneClient.disconnect() }
        let ipadClient = try await connectCompanion(id: "ipad-1", name: "iPad", platform: .iPad, prefix: "ipad")
        defer { ipadClient.disconnect() }
        let watchClient = try await connectCompanion(id: "watch-1", name: "Watch", platform: .appleWatch, prefix: "watch")
        defer { watchClient.disconnect() }

        var iphoneFollower = AppDeckFollowerState()
        var ipadFollower = AppDeckFollowerState()
        var watchFollower = AppDeckFollowerState()

        iphoneFollower.handleProfileUpdated(iphoneClient.profile, frontmostBundleIdentifier: iphoneClient.frontmostBundleID)
        ipadFollower.handleProfileUpdated(ipadClient.profile, frontmostBundleIdentifier: ipadClient.frontmostBundleID)
        watchFollower.handleProfileUpdated(watchClient.profile, frontmostBundleIdentifier: watchClient.frontmostBundleID)

        XCTAssertEqual(iphoneFollower.currentPageIndex, 0)
        XCTAssertEqual(ipadFollower.currentPageIndex, 0)
        XCTAssertEqual(watchFollower.currentPageIndex, 0)

        // Switch frontmost Mac app to Xcode -> iPhone, iPad, and Watch all resolve page 1 with zero auto-run tiles
        delegate.frontmostBundleID = "com.apple.dt.Xcode"
        server.broadcast(.frontmostAppChanged(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"))

        let switchDeadline = Date().addingTimeInterval(2.0)
        while Date() < switchDeadline {
            if iphoneClient.frontmostBundleID == "com.apple.dt.Xcode",
               ipadClient.frontmostBundleID == "com.apple.dt.Xcode",
               watchClient.frontmostBundleID == "com.apple.dt.Xcode" {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        iphoneFollower.handleFrontmostAppChanged(iphoneClient.frontmostBundleID, in: iphoneClient.profile)
        ipadFollower.handleFrontmostAppChanged(ipadClient.frontmostBundleID, in: ipadClient.profile)
        watchFollower.handleFrontmostAppChanged(watchClient.frontmostBundleID, in: watchClient.profile)

        XCTAssertEqual(iphoneFollower.currentPageID, xcodeDeckID)
        XCTAssertEqual(ipadFollower.currentPageID, xcodeDeckID)
        XCTAssertEqual(watchFollower.currentPageID, xcodeDeckID)
        XCTAssertEqual(iphoneFollower.currentPageIndex, 1)
        XCTAssertEqual(ipadFollower.currentPageIndex, 1)
        XCTAssertEqual(watchFollower.currentPageIndex, 1)
        XCTAssertTrue(delegate.triggeredItems.isEmpty, "Switching frontmost app must never auto-execute tiles")
    }
}
