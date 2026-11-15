import XCTest
@testable import ChocliftCore

final class MeetingJoinLinkTests: XCTestCase {

    // MARK: - 1. Known Provider Detection

    func testKnownProvidersDetectedAcrossPlainAndFormattedInviteText() throws {
        let cases: [(input: [String], expectedProvider: String, expectedURL: String)] = [
            (
                ["https://us02web.zoom.us/j/81234567890?pwd=abc"],
                "Zoom",
                "https://us02web.zoom.us/j/81234567890?pwd=abc"
            ),
            (
                ["Join Zoom: https://acme.zoom.com/j/99887766."],
                "Zoom",
                "https://acme.zoom.com/j/99887766"
            ),
            (
                ["Room 4B", "Video link: <https://meet.google.com/abc-defg-hij>"],
                "Meet",
                "https://meet.google.com/abc-defg-hij"
            ),
            (
                ["[Join Microsoft Teams](https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=%7b%22Tid%22%3a%221%22%7d)"],
                "Teams",
                "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=%7b%22Tid%22%3a%221%22%7d"
            ),
            (
                ["https://teams.live.com/meet/9387654321"],
                "Teams",
                "https://teams.live.com/meet/9387654321"
            ),
            (
                ["Dial in or join https://company.webex.com/company/j.php?MTID=m012345,"],
                "Webex",
                "https://company.webex.com/company/j.php?MTID=m012345"
            ),
            (
                ["(https://facetime.apple.com/join#v=1&p=xyz123)"],
                "FaceTime",
                "https://facetime.apple.com/join#v=1&p=xyz123"
            ),
            (
                ["Pair programming session: https://tuple.app/c/pair-room-42!"],
                "Tuple",
                "https://tuple.app/c/pair-room-42"
            )
        ]

        for testCase in cases {
            let detected = try XCTUnwrap(
                MeetingJoinLink.detect(in: testCase.input),
                "Expected match for \(testCase.input)"
            )
            XCTAssertEqual(detected.provider, testCase.expectedProvider)
            XCTAssertEqual(detected.url.absoluteString, testCase.expectedURL)
        }

        // Lookalike domains must not masquerade as Zoom
        XCTAssertNil(MeetingJoinLink.detect(in: ["https://evilzoom.us/overview"]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["https://zoom.us.example.org/docs"]))
    }

    // MARK: - 2. Rejection of Non-HTTPS, Dangerous Schemes & Empty Strings

    func testRejectsNonHTTPSAndEmptyInputsAndIrrelevantURLs() {
        XCTAssertNil(MeetingJoinLink.detect(in: []))
        XCTAssertNil(MeetingJoinLink.detect(in: ["", "   \n\t  "]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["http://zoom.us/j/123456789"]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["http://meet.google.com/abc-defg-hij"]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["http://example.com/join/standup"]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["file:///Users/alice/Desktop/join-meeting.html"]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["file:///Applications/Calendar.app"]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["javascript:alert(1)"]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["javascript:window.open('https://zoom.us/j/123456')"]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["onclick=\"javascript:open('https://meet.google.com/abc-defg-hij')\""]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["https://github.com/uhyrdtrdtfg-creator/choclift/pull/35"]))
        XCTAssertNil(MeetingJoinLink.detect(in: ["https://docs.google.com/document/d/12345/edit"]))
    }

    // MARK: - 3. Generic Fallback & Known-Provider Priority + 500-Char Length Cap

    func testGenericFallbackKnownProviderPreferenceAndLengthCap() throws {
        let meetGeneric = try XCTUnwrap(MeetingJoinLink.detect(in: ["https://whereby.com/daily-meet-room"]))
        XCTAssertEqual(meetGeneric.provider, "Link")
        XCTAssertEqual(meetGeneric.url.absoluteString, "https://whereby.com/daily-meet-room")

        let joinGeneric = try XCTUnwrap(MeetingJoinLink.detect(in: ["https://chime.aws/join/998877"]))
        XCTAssertEqual(joinGeneric.provider, "Link")

        let callGeneric = try XCTUnwrap(MeetingJoinLink.detect(in: ["https://around.co/r/design-call"]))
        XCTAssertEqual(callGeneric.provider, "Link")

        // Prefer first known provider even when a generic join/meet/call link comes earlier
        let preferredAcrossFields = try XCTUnwrap(
            MeetingJoinLink.detect(in: [
                "Agenda & join doc: https://intranet.example.com/join-checklist",
                "Room 301",
                " backup: https://whereby.com/team-call\nPrimary video: https://meet.google.com/xyz-uvwx-rst\nSecondary: https://zoom.us/j/111222333"
            ])
        )
        XCTAssertEqual(preferredAcrossFields.provider, "Meet")
        XCTAssertEqual(preferredAcrossFields.url.absoluteString, "https://meet.google.com/xyz-uvwx-rst")

        // Cap extracted URL length at 500 characters
        let longURL = "https://us06web.zoom.us/j/1234567890?pwd=" + String(repeating: "x", count: 600)
        let capped = try XCTUnwrap(MeetingJoinLink.detect(in: [longURL]))
        XCTAssertEqual(capped.provider, "Zoom")
        XCTAssertEqual(capped.url.absoluteString.count, 500)
        XCTAssertLessThanOrEqual(capped.url.absoluteString.count, MeetingJoinLink.maxURLLength)

        // Cap cleanly when 500-char boundary splits a percent-encoded byte
        let prefix499 = "https://teams.microsoft.com/l/meetup-join/" + String(repeating: "a", count: 457)
        XCTAssertEqual(prefix499.count, 499)
        let boundaryPercentURL = prefix499 + "%20overflow"
        let boundaryCapped = try XCTUnwrap(MeetingJoinLink.detect(in: [boundaryPercentURL]))
        XCTAssertEqual(boundaryCapped.provider, "Teams")
        XCTAssertLessThanOrEqual(boundaryCapped.url.absoluteString.count, 500)
    }

    // MARK: - 4. Legacy Snapshot Decoding, Countdown Formatting & Wire Privacy

    func testLegacySnapshotDecodingSelectionCountdownAndCacheInvalidation() throws {
        // Old NextCalendarEventSnapshot JSON without joinProvider or hasJoinLink keys must still decode
        let legacyJSON = Data("""
        {
          "permission": "authorized",
          "nextEvent": {
            "title": "Design Critique",
            "startDate": 1763000900,
            "isAllDay": false
          }
        }
        """.utf8)

        let decodedLegacy = try JSONDecoder().decode(NextCalendarEventSnapshot.self, from: legacyJSON)
        XCTAssertEqual(decodedLegacy.permission, .authorized)
        XCTAssertEqual(decodedLegacy.nextEvent?.title, "Design Critique")
        XCTAssertEqual(decodedLegacy.nextEvent?.isAllDay, false)
        XCTAssertNil(decodedLegacy.nextEvent?.joinProvider)
        XCTAssertEqual(decodedLegacy.nextEvent?.hasJoinLink, false)
        XCTAssertNil(decodedLegacy.joinProvider)
        XCTAssertFalse(decodedLegacy.hasJoinLink)

        // Selection carries provider metadata without putting URL or notes on the wire
        let now = Date(timeIntervalSince1970: 1_763_000_000)
        let candidate = CalendarEventCandidate(
            title: "Sprint Sync",
            startDate: now.addingTimeInterval(180),
            endDate: now.addingTimeInterval(1980),
            joinProvider: "Zoom",
            hasJoinLink: true
        )
        let selected = try XCTUnwrap(NextCalendarEventSnapshot.selectNextEvent(from: [candidate], now: now))
        XCTAssertEqual(selected.joinProvider, "Zoom")
        XCTAssertTrue(selected.hasJoinLink)
        XCTAssertEqual(
            NextCalendarEventSnapshot.formattedCountdown(for: selected, referenceDate: now, language: .english),
            "in 3m"
        )
        XCTAssertEqual(
            NextCalendarEventSnapshot.formattedCountdown(
                for: selected,
                referenceDate: now.addingTimeInterval(180),
                language: .english
            ),
            "Now"
        )

        let snapshot = NextCalendarEventSnapshot(permission: .authorized, nextEvent: selected)
        let encodedData = try JSONEncoder().encode(snapshot)
        let encodedJSONString = try XCTUnwrap(String(data: encodedData, encoding: .utf8))
        XCTAssertFalse(encodedJSONString.contains("zoom.us"))
        XCTAssertFalse(encodedJSONString.contains("https://"))

        let roundTripped = try JSONDecoder().decode(NextCalendarEventSnapshot.self, from: encodedData)
        XCTAssertEqual(roundTripped, snapshot)
        XCTAssertEqual(roundTripped.joinProvider, "Zoom")
        XCTAssertTrue(roundTripped.hasJoinLink)

        // Mac-side cache keyed by startDate + title rejects empty cache and changed events
        var cache = MeetingJoinLinkCache()
        XCTAssertNil(cache.resolveJoinURL(expectedEvent: selected, currentEvent: selected))

        let secretZoomURL = try XCTUnwrap(URL(string: "https://us02web.zoom.us/j/555666777?pwd=secret"))
        cache.store(secretZoomURL, startDate: candidate.startDate, title: "  Sprint Sync  ")
        XCTAssertEqual(cache.resolveJoinURL(expectedEvent: selected, currentEvent: selected), secretZoomURL)

        let changedTitleEvent = NextCalendarEventSummary(
            title: "Different Meeting",
            startDate: candidate.startDate,
            joinProvider: "Zoom",
            hasJoinLink: true
        )
        XCTAssertNil(cache.resolveJoinURL(expectedEvent: selected, currentEvent: changedTitleEvent))

        let changedTimeEvent = NextCalendarEventSummary(
            title: "Sprint Sync",
            startDate: candidate.startDate.addingTimeInterval(300),
            joinProvider: "Zoom",
            hasJoinLink: true
        )
        XCTAssertNil(cache.resolveJoinURL(expectedEvent: selected, currentEvent: changedTimeEvent))
    }

    // MARK: - 5. Authenticated Wire Routing for joinNextCalendarMeeting

    #if os(macOS)
    @MainActor
    func testJoinNextCalendarMeetingWireRoutingAndPreAuthProtection() async throws {
        let suiteName = "com.choclift.joinmeeting.wire.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_763_010_000)
        let start = now.addingTimeInterval(180)
        let joinURL = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))

        let delegate = JoinMeetingWireTestDelegate(
            event: NextCalendarEventSummary(
                title: "Engineering Standup",
                startDate: start,
                joinProvider: "Meet",
                hasJoinLink: true
            ),
            cachedURL: joinURL
        )
        let server = MacServerEngine(macID: "mac-join-host", macName: "Studio Mac")
        server.delegate = delegate
        defer { server.stop() }

        // 1. Pre-auth joinNextCalendarMeeting must NOT be swallowed silently; server requires pairing
        let unauthPipe = server.acceptInMemoryCompanion()
        var unauthReplies: [ServerMessage] = []
        var unauthAcc = WireStreamAccumulator()
        unauthPipe.onPayload = { chunk in
            if let frames = try? unauthAcc.appendAndExtractPayloads(chunk) {
                for frame in frames {
                    if let msg = try? WireFrameCodec.decodePayload(ServerMessage.self, from: frame) {
                        unauthReplies.append(msg)
                    }
                }
            }
        }
        unauthPipe.start()
        unauthPipe.send(try WireFrameCodec.encode(ClientMessage.joinNextCalendarMeeting))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(unauthReplies.contains {
            if case .pairingRequired = $0 { return true }
            return false
        })
        XCTAssertTrue(delegate.openedURLs.isEmpty)

        // 2. Authenticated companion joins meeting and handles empty-cache failure toast
        let phoneServerEnd = server.acceptInMemoryCompanion()
        let (phoneProxy, phoneClientEnd) = InMemoryCompanionPipe.pair()
        phoneProxy.onPayload = { phoneServerEnd.send($0) }
        phoneServerEnd.onPayload = { phoneProxy.send($0) }
        phoneProxy.start()
        phoneServerEnd.start()

        let phoneClient = CompanionClientEngine(
            deviceID: "iphone-join-test",
            deviceName: "iPhone",
            platform: .iPhone,
            userDefaults: defaults,
            storageKeyPrefix: "phone"
        )
        defer { phoneClient.disconnect() }

        phoneClient.connectInMemoryBluetooth(to: phoneClientEnd, targetName: "Studio Mac")
        for _ in 0..<50 {
            if case .awaitingPIN = phoneClient.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        phoneClient.submitPIN(server.currentPIN)
        for _ in 0..<50 where !phoneClient.connectionState.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<50 where phoneClient.calendarSnapshot.nextEvent == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(phoneClient.calendarSnapshot.nextEvent?.joinProvider, "Meet")
        XCTAssertEqual(phoneClient.calendarSnapshot.nextEvent?.hasJoinLink, true)

        phoneClient.joinNextCalendarMeeting()
        for _ in 0..<50 where delegate.openedURLs.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(delegate.openedURLs, [joinURL])

        // Empty cache / changed event produces a failure toast without leaking URL or notes
        delegate.cache.removeAll()
        phoneClient.lastFeedback = nil
        phoneClient.joinNextCalendarMeeting()
        for _ in 0..<50 where phoneClient.lastFeedback == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(phoneClient.lastFeedback?.success, false)
        XCTAssertFalse(phoneClient.lastFeedback?.detail?.contains("meet.google.com") ?? false)
    }
    #endif
}

#if os(macOS)
@MainActor
private final class JoinMeetingWireTestDelegate: MacServerEngineDelegate {
    var profile = ChocliftDefaults.makeDefaultProfile()
    var currentEvent: NextCalendarEventSummary?
    var cache = MeetingJoinLinkCache()
    var openedURLs: [URL] = []

    init(event: NextCalendarEventSummary, cachedURL: URL) {
        self.currentEvent = event
        self.cache.store(cachedURL, startDate: event.startDate, title: event.title)
    }

    func serverCurrentProfile() -> ChocliftWorkspaceProfile { profile }
    func serverCurrentRecentApps() -> [RecentAppEntry] { [] }
    func serverFrontmostBundleID() -> String? { nil }
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
        case .requestCompanionDashboard:
            reply(.calendarStatusUpdated(NextCalendarEventSnapshot(permission: .authorized, nextEvent: currentEvent)))
        case .joinNextCalendarMeeting:
            if let url = cache.resolveJoinURL(expectedEvent: currentEvent, currentEvent: currentEvent) {
                openedURLs.append(url)
                reply(.actionFeedback(success: true, title: "Join Meeting", detail: "Joined Meet meeting on Mac"))
            } else {
                reply(.actionFeedback(success: false, title: "Join Meeting", detail: "Meeting join link is no longer available"))
            }
        default:
            break
        }
    }
}
#endif
