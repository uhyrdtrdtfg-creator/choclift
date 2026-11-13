import Foundation
import Network

public struct DiscoveredMacHost: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let macID: String?
    public let endpoint: NWEndpoint
    public let directHost: String?
    public let directPort: UInt16?

    public init(
        id: String,
        name: String,
        macID: String?,
        endpoint: NWEndpoint,
        directHost: String? = nil,
        directPort: UInt16? = nil
    ) {
        self.id = id
        self.name = name
        self.macID = macID
        self.endpoint = endpoint
        self.directHost = directHost
        self.directPort = directPort
    }
}

public struct SavedMacCredential: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var macID: String
    public var macName: String
    public var authToken: String
    public var lastDirectHost: String?
    public var lastDirectPort: UInt16?
    public var lastBluetoothPeripheralID: UUID?
    public var updatedAt: Date

    public var id: String { macID }

    public init(
        macID: String,
        macName: String,
        authToken: String,
        lastDirectHost: String? = nil,
        lastDirectPort: UInt16? = nil,
        lastBluetoothPeripheralID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.macID = macID
        self.macName = macName
        self.authToken = authToken
        self.lastDirectHost = lastDirectHost
        self.lastDirectPort = lastDirectPort
        self.lastBluetoothPeripheralID = lastBluetoothPeripheralID
        self.updatedAt = updatedAt
    }
}

public struct CompanionFeedbackToast: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let success: Bool
    public let title: String
    public let detail: String?
    public let timestamp = Date()

    public init(success: Bool, title: String, detail: String? = nil) {
        self.success = success
        self.title = title
        self.detail = detail
    }
}

public enum CompanionConnectionState: Equatable, Sendable {
    case disconnected
    case connecting(targetName: String)
    case awaitingPIN(macID: String, macName: String, errorMessage: String?)
    case connected(macID: String, macName: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

@MainActor
public final class CompanionClientEngine: ObservableObject {
    @Published public private(set) var connectionState: CompanionConnectionState = .disconnected
    @Published public private(set) var discoveredMacs: [DiscoveredMacHost] = []
    @Published public private(set) var discoveredBluetoothMacs: [DiscoveredBluetoothMac] = []
    @Published public private(set) var activeLink: CompanionLinkKind?
    @Published public private(set) var isBluetoothPoweredOn: Bool = false
    @Published public private(set) var bluetoothAvailability: CompanionBluetoothAvailability = .unknown
    @Published public private(set) var lastConnectionIssue: String?
    @Published public private(set) var savedMacs: [SavedMacCredential] = []

    @Published public var profile: ChocliftWorkspaceProfile = ChocliftDefaults.makeDefaultProfile()
    @Published public private(set) var recentApps: [RecentAppEntry] = []
    @Published public private(set) var frontmostBundleID: String?
    @Published public private(set) var frontmostAppName: String?
    @Published public private(set) var isEditingTextOnMac: Bool = false
    @Published public private(set) var focusedMacAppName: String?
    @Published public private(set) var isMacAccessibilityGranted: Bool = true
    @Published public private(set) var appIconsByBundleID: [String: Data] = [:]
    @Published public private(set) var macCatalogApps: [InstalledAppSummary] = []
    @Published public private(set) var macCatalogShortcuts: [InstalledShortcutSummary] = []
    @Published public private(set) var orcaStatus: OrcaTaskStatusSnapshot?
    @Published public private(set) var controlStripState: ControlStripState = ControlStripState()
    @Published public private(set) var clipboardPreview: ClipboardPreviewSnapshot = .empty
    @Published public private(set) var calendarSnapshot: NextCalendarEventSnapshot = .initial
    @Published public private(set) var latestScreenshotPreview: ScreenshotCaptureResult?
    @Published public private(set) var isCapturingScreenshot: Bool = false
    @Published public private(set) var frontmostWindows: FrontmostAppWindowSnapshot = .empty
    @Published public private(set) var activeTileFeedback: TileActionFeedbackBanner?
    @Published public private(set) var recentlyTriggeredTiles: [RecentlyTriggeredTileEntry] = []
    @Published public var lastFeedback: CompanionFeedbackToast?

    public let deviceID: String
    public var deviceName: String
    public let platform: DevicePlatform

    /// Optional test hook allowing simulated BLE transports to exercise automatic token reconnect on drop.
    public var simulatedBluetoothReconnectProvider: (() -> CompanionFrameTransport?)?
    /// Internal test hook allowing simulated BLE discovery + GATT metadata sessions without physical radio hardware.
    var simulatedBluetoothConnector: ((DiscoveredBluetoothMac) -> CompanionFrameTransport?)?
    /// Internal test hook allowing unit tests to deterministically simulate watchOS NECP `.waiting(NWError)` states.
    var simulatedTCPWaitingErrorProvider: ((NWEndpoint) -> NWError?)?
    public var reconnectDelaySeconds: TimeInterval = 2.0
    public var connectTimeoutSeconds: TimeInterval = 8.0
    public var heartbeatIntervalSeconds: TimeInterval = 5.0
    public var heartbeatTimeoutSeconds: TimeInterval = 15.0
    public var maxAutoReconnectAttempts: Int = 3
    public var pinGlitchRecoveryWindowSeconds: TimeInterval = 6.0
    public var tileFeedbackDurationSeconds: TimeInterval = TileActionFeedbackBanner.defaultDisplayDurationSeconds

    /// True if the user tapped Disconnect/Cancel during the current app launch; never persisted across launches.
    public var isAutoConnectSuppressedForCurrentLaunch: Bool {
        intentionalDisconnect
    }

    private let storageDefaults: UserDefaults
    private let savedMacsKey: String
    private let recentlyTriggeredTilesKey: String
    private let networkQueue = DispatchQueue(label: "com.choclift.client.network", qos: .userInteractive)

    private var browser: NWBrowser?
    private var bluetoothBrowser: BluetoothCompanionBrowser?
    private var isBrowsingActive = false
    private var browsingStartedAt: Date?

    private var connection: NWConnection?
    private var frameTransport: CompanionFrameTransport?
    private var isTransportReady = false
    private var accumulator = WireStreamAccumulator()
    private var currentSessionID = UUID()
    private var lastServerActivityAt = Date()

    private var activeEndpoint: NWEndpoint?
    private var activeTargetName: String = "Mac"
    private var activeDirectHost: String?
    private var activeDirectPort: UInt16?
    private var activeBluetoothPeripheralID: UUID?
    private var candidateMacID: String?
    private var isSavedMacProbeConnect = false
    private var probeTargetMacID: String?
    private var rejectedAutoProbePeripheralIDs: Set<UUID> = []
    private var retriedTokenMacIDs: Set<String> = []
    private var consecutiveReconnectFailures: Int = 0

    private var pinGlitchState: (macID: String, macName: String, errorMessage: String?, deadline: Date)?
    private var pendingPINSubmission: String?

    private var intentionalDisconnect = false
    private var didAttemptHTTPFallbackInCurrentConnect = false
    private var wifiPreferenceTask: Task<Void, Never>?
    private var connectWatchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pinGlitchExpiryTask: Task<Void, Never>?
    private var pinSubmissionWatchdogTask: Task<Void, Never>?
    private var tileFeedbackTracker = TileActionFeedbackTracker()
    private var tileFeedbackExpiryTask: Task<Void, Never>?

    public init(
        deviceID: String,
        deviceName: String,
        platform: DevicePlatform,
        userDefaults: UserDefaults = .standard,
        storageKeyPrefix: String = "com.choclift.companion"
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.storageDefaults = userDefaults
        self.savedMacsKey = "\(storageKeyPrefix).savedMacs"
        self.recentlyTriggeredTilesKey = "\(storageKeyPrefix).recentlyTriggeredTiles"
        loadSavedCredentials()
        loadRecentlyTriggeredTiles()
    }

    // MARK: - Discovery

    public func startBrowsing() {
        stopBrowsing()
        rejectedAutoProbePeripheralIDs.removeAll()
        isBrowsingActive = true
        browsingStartedAt = Date()

        let params = NWParameters()
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: ChocliftDefaults.bonjourServiceType,
            domain: nil
        )
        let newBrowser = NWBrowser(for: descriptor, using: params)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var hosts: [DiscoveredMacHost] = []
                for result in results {
                    if case let .service(name, type, domain, _) = result.endpoint {
                        var macID: String?
                        var customName = name
                        var txtHost: String?
                        var txtPort: UInt16?
                        if case let .bonjour(txtRecord) = result.metadata {
                            macID = txtRecord["macID"]
                            if let txtName = txtRecord["macName"], !txtName.isEmpty {
                                customName = txtName
                            }
                            if let ip = txtRecord["ip"], !ip.isEmpty {
                                txtHost = ip
                            }
                            if let portStr = txtRecord["port"], let parsedPort = UInt16(portStr), parsedPort > 0 {
                                txtPort = parsedPort
                            }
                        }
                        let uniqueID = "\(name).\(type).\(domain)"
                        hosts.append(
                            DiscoveredMacHost(
                                id: uniqueID,
                                name: customName,
                                macID: macID,
                                endpoint: result.endpoint,
                                directHost: txtHost,
                                directPort: txtPort
                            )
                        )
                    }
                }
                self.discoveredMacs = hosts.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                if self.connectionState == .disconnected,
                   self.reconnectTask == nil,
                   self.matchingSavedWiFiHost() != nil {
                    self.consecutiveReconnectFailures = 0
                }
                self.autoConnectIfAppropriate()
            }
        }
        self.browser = newBrowser
        newBrowser.start(queue: networkQueue)
        startBluetoothBrowsing()
    }

    public func startBluetoothBrowsing() {
        let scanner = bluetoothBrowser ?? BluetoothCompanionBrowser()
        bluetoothBrowser = scanner
        scanner.onAvailabilityChanged = { [weak self] availability in
            self?.bluetoothAvailability = availability
        }
        scanner.onPowerStateChanged = { [weak self] poweredOn in
            self?.isBluetoothPoweredOn = poweredOn
            self?.bluetoothAvailability = scanner.availability
            if poweredOn {
                self?.autoConnectIfAppropriate()
            }
        }
        scanner.onDiscoveredChanged = { [weak self] hosts in
            guard let self else { return }
            self.discoveredBluetoothMacs = self.enrichedDiscoveredBluetoothMacs(from: hosts)
            self.isBluetoothPoweredOn = scanner.isPoweredOn
            self.bluetoothAvailability = scanner.availability
            if self.connectionState == .disconnected,
               self.reconnectTask == nil,
               self.matchingSavedDiscoveredBluetoothHost() != nil {
                self.consecutiveReconnectFailures = 0
            }
            self.autoConnectIfAppropriate()
        }
        scanner.onMetadataResolved = { [weak self] host in
            guard let self else { return }
            self.discoveredBluetoothMacs = self.enrichedDiscoveredBluetoothMacs(from: scanner.discovered)
            if let macID = host.macID {
                self.handleResolvedBluetoothIdentity(
                    macID: macID,
                    macName: host.name,
                    peripheralID: host.id
                )
            }
        }
        scanner.onLinkReady = { [weak self] _, host in
            guard let self else { return }
            self.discoveredBluetoothMacs = self.enrichedDiscoveredBluetoothMacs(from: scanner.discovered)
            self.isBluetoothPoweredOn = scanner.isPoweredOn
            self.bluetoothAvailability = scanner.availability
            if self.activeLink == .bluetooth && self.activeBluetoothPeripheralID == host.id {
                self.activeTargetName = host.name
                if let macID = host.macID {
                    self.candidateMacID = macID
                }
            }
        }
        scanner.start()
        isBluetoothPoweredOn = scanner.isPoweredOn
        bluetoothAvailability = scanner.availability
        discoveredBluetoothMacs = enrichedDiscoveredBluetoothMacs(from: scanner.discovered)
    }

    func simulateDiscoveredBluetoothMacs(
        _ hosts: [DiscoveredBluetoothMac],
        autoConnect: Bool = true
    ) {
        isBrowsingActive = true
        discoveredBluetoothMacs = enrichedDiscoveredBluetoothMacs(from: hosts)
        if connectionState == .disconnected,
           reconnectTask == nil,
           matchingSavedDiscoveredBluetoothHost() != nil {
            consecutiveReconnectFailures = 0
        }
        if autoConnect {
            autoConnectIfAppropriate()
        }
    }

    private func enrichedDiscoveredBluetoothMacs(from hosts: [DiscoveredBluetoothMac]) -> [DiscoveredBluetoothMac] {
        let mapped = hosts.map { host -> DiscoveredBluetoothMac in
            guard host.macID == nil,
                  host.name == "Mac",
                  let saved = savedMacs.first(where: { $0.lastBluetoothPeripheralID == host.id }),
                  !saved.macName.isEmpty else {
                return host
            }
            return DiscoveredBluetoothMac(id: host.id, name: saved.macName, macID: nil)
        }
        return mapped.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func stopBrowsing() {
        isBrowsingActive = false
        wifiPreferenceTask?.cancel()
        wifiPreferenceTask = nil
        browser?.cancel()
        browser = nil
        bluetoothBrowser?.stop()
        discoveredBluetoothMacs = []
    }

    /// Re-arms discovery and saved-token auto-reconnect when returning to foreground (e.g. watchOS wrist raise).
    public func handleAppDidBecomeActive() {
        if connectionState == .disconnected && !intentionalDisconnect {
            rejectedAutoProbePeripheralIDs.removeAll()
        }
        if simulatedBluetoothConnector == nil {
            if !isBrowsingActive {
                startBrowsing()
            } else {
                bluetoothBrowser?.start()
            }
        }
        if connectionState == .disconnected && !intentionalDisconnect {
            consecutiveReconnectFailures = 0
            autoConnectIfAppropriate(allowBluetoothNow: discoveredMacs.isEmpty)
        }
    }

    // MARK: - Auto-Connect & Cross-Link Preference

    private func autoConnectIfAppropriate(allowBluetoothNow: Bool = false) {
        guard connectionState == .disconnected, !intentionalDisconnect, !savedMacs.isEmpty else { return }

        // 1. Always prefer live Wi-Fi TCP when both links are available.
        if let wifiHost = matchingSavedWiFiHost() {
            wifiPreferenceTask?.cancel()
            wifiPreferenceTask = nil
            connect(to: wifiHost)
            return
        }

        // 2. When not on the same Wi-Fi, connect via Bluetooth LE using the same saved auth token.
        guard let btHost = matchingSavedDiscoveredBluetoothHost() else { return }

        let elapsed = browsingStartedAt.map { Date().timeIntervalSince($0) } ?? 1.0
        if allowBluetoothNow || elapsed >= 0.65 {
            wifiPreferenceTask?.cancel()
            wifiPreferenceTask = nil
            intentionalDisconnect = false
            consecutiveReconnectFailures = 0
            lastConnectionIssue = nil
            clearPINGlitchState()
            connectBluetoothInternal(
                to: btHost,
                preservePINState: false,
                probeSavedMac: btHost.macID == nil,
                probeTargetMacID: nil
            )
        } else if wifiPreferenceTask == nil {
            let remaining = max(0.05, 0.65 - elapsed)
            wifiPreferenceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard let self, !Task.isCancelled else { return }
                self.wifiPreferenceTask = nil
                self.autoConnectIfAppropriate(allowBluetoothNow: true)
            }
        }
    }

    private func matchingSavedWiFiHost() -> DiscoveredMacHost? {
        for saved in savedMacs {
            if let byID = discoveredMacs.first(where: { $0.macID == saved.macID }) {
                return byID
            }
            if let byName = discoveredMacs.first(where: {
                $0.name.caseInsensitiveCompare(saved.macName) == .orderedSame
            }) {
                return byName
            }
        }
        return nil
    }

    private func matchingSavedDiscoveredBluetoothHost(preferMacID: String? = nil) -> DiscoveredBluetoothMac? {
        let orderedSaved: [SavedMacCredential] = {
            guard let preferMacID else { return savedMacs }
            let prioritized = savedMacs.filter { $0.macID == preferMacID }
            let others = savedMacs.filter { $0.macID != preferMacID }
            return prioritized + others
        }()

        for saved in orderedSaved {
            if let btHost = matchingDiscoveredBluetoothHost(for: saved) {
                return btHost
            }
        }
        return nil
    }

    private func matchingDiscoveredBluetoothHost(for saved: SavedMacCredential) -> DiscoveredBluetoothMac? {
        if let byID = discoveredBluetoothMacs.first(where: { $0.macID == saved.macID }) {
            return byID
        }
        if let pid = saved.lastBluetoothPeripheralID,
           let byPeripheral = discoveredBluetoothMacs.first(where: {
               $0.id == pid &&
               $0.macID == nil &&
               !rejectedAutoProbePeripheralIDs.contains($0.id)
           }) {
            return byPeripheral
        }
        if let byName = discoveredBluetoothMacs.first(where: {
            $0.macID == nil &&
            !rejectedAutoProbePeripheralIDs.contains($0.id) &&
            Self.namesLikelyMatch(savedName: saved.macName, advertisedName: $0.name)
        }) {
            return byName
        }
        if let unprobed = discoveredBluetoothMacs.first(where: { candidate in
            candidate.macID == nil &&
            !rejectedAutoProbePeripheralIDs.contains(candidate.id) &&
            !savedMacs.contains(where: { other in
                other.macID != saved.macID && other.lastBluetoothPeripheralID == candidate.id
            })
        }) {
            return unprobed
        }
        return nil
    }

    private static func namesLikelyMatch(savedName: String, advertisedName: String) -> Bool {
        let a = savedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = advertisedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.caseInsensitiveCompare(b) == .orderedSame {
            return true
        }
        if b.count >= 8, a.lowercased().hasPrefix(b.lowercased()) {
            return true
        }
        return false
    }

    // MARK: - Connecting (Wi-Fi TCP & Bluetooth LE)

    public func canReconnectSavedMac(_ saved: SavedMacCredential) -> Bool {
        if discoveredMacs.contains(where: { $0.macID == saved.macID || $0.name == saved.macName }) {
            return true
        }
        if matchingDiscoveredBluetoothHost(for: saved) != nil {
            return true
        }
        if saved.lastDirectHost != nil && saved.lastDirectPort != nil {
            return true
        }
        if saved.lastBluetoothPeripheralID != nil && isBluetoothPoweredOn {
            return true
        }
        return false
    }

    public func reconnectSavedMac(_ saved: SavedMacCredential) {
        consecutiveReconnectFailures = 0
        lastConnectionIssue = nil
        rejectedAutoProbePeripheralIDs.removeAll()
        if let wifiHost = discoveredMacs.first(where: {
            $0.macID == saved.macID || $0.name.caseInsensitiveCompare(saved.macName) == .orderedSame
        }) {
            connect(to: wifiHost)
            return
        }
        if let btHost = matchingDiscoveredBluetoothHost(for: saved) {
            intentionalDisconnect = false
            clearPINGlitchState()
            connectBluetoothInternal(
                to: btHost,
                preservePINState: false,
                probeSavedMac: btHost.macID == nil,
                probeTargetMacID: saved.macID
            )
            return
        }
        if let host = saved.lastDirectHost, let port = saved.lastDirectPort {
            candidateMacID = saved.macID
            connectToHost(host: host, port: port, targetName: saved.macName)
            return
        }
        if let peripheralID = saved.lastBluetoothPeripheralID {
            _ = connectKnownBluetoothPeripheral(
                id: peripheralID,
                targetName: saved.macName,
                macID: saved.macID
            )
        }
    }

    public func connect(to discovered: DiscoveredMacHost) {
        intentionalDisconnect = false
        isSavedMacProbeConnect = false
        probeTargetMacID = nil
        consecutiveReconnectFailures = 0
        lastConnectionIssue = nil
        clearPINGlitchState()
        wifiPreferenceTask?.cancel()
        reconnectTask?.cancel()
        candidateMacID = discovered.macID
            ?? savedMacs.first(where: { $0.macName.caseInsensitiveCompare(discovered.name) == .orderedSame })?.macID
        activeDirectHost = discovered.directHost
        activeDirectPort = discovered.directPort
        activeBluetoothPeripheralID = nil
        openConnection(to: discovered.endpoint, targetName: discovered.name, preservePINState: false)
    }

    public func connectToHost(
        host: String,
        port: UInt16 = ChocliftDefaults.defaultTCPPort,
        targetName: String? = nil
    ) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        intentionalDisconnect = false
        isSavedMacProbeConnect = false
        probeTargetMacID = nil
        consecutiveReconnectFailures = 0
        lastConnectionIssue = nil
        clearPINGlitchState()
        wifiPreferenceTask?.cancel()
        reconnectTask?.cancel()
        activeDirectHost = trimmedHost
        activeDirectPort = port
        activeBluetoothPeripheralID = nil
        candidateMacID = savedMacs.first(where: { $0.lastDirectHost == trimmedHost })?.macID
            ?? candidateMacID
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(trimmedHost), port: nwPort)
        openConnection(to: endpoint, targetName: targetName ?? "\(trimmedHost):\(port)", preservePINState: false)
    }

    public func connectBluetooth(to host: DiscoveredBluetoothMac) {
        intentionalDisconnect = false
        consecutiveReconnectFailures = 0
        lastConnectionIssue = nil
        rejectedAutoProbePeripheralIDs.remove(host.id)
        clearPINGlitchState()
        connectBluetoothInternal(
            to: host,
            preservePINState: false,
            probeSavedMac: false,
            probeTargetMacID: nil
        )
    }

    private func connectBluetoothInternal(
        to host: DiscoveredBluetoothMac,
        preservePINState: Bool,
        probeSavedMac: Bool = false,
        probeTargetMacID: String? = nil
    ) {
        let resolvedTransport: CompanionFrameTransport? = {
            if let simulatedBluetoothConnector {
                return simulatedBluetoothConnector(host)
            }
            if bluetoothBrowser == nil {
                startBluetoothBrowsing()
            }
            return bluetoothBrowser?.connect(to: host)
        }()

        guard let link = resolvedTransport else {
            let lang = profile.settings.language
            lastConnectionIssue = bluetoothAvailability.detailGuidance(in: lang)
                ?? L10n.tr("无法建立蓝牙连接，请确认蓝牙已开启。", "Unable to start Bluetooth connection. Check that Bluetooth is enabled.", language: lang)
            activeLink = nil
            isSavedMacProbeConnect = false
            self.probeTargetMacID = nil
            connectionState = .disconnected
            return
        }
        let resolvedMacID: String? = {
            if let explicit = host.macID {
                return explicit
            }
            if let byPeripheral = savedMacs.first(where: { $0.lastBluetoothPeripheralID == host.id }) {
                return byPeripheral.macID
            }
            return nil
        }()
        let displayTargetName: String = {
            if host.name == "Mac",
               let resolvedMacID,
               let savedName = savedMacs.first(where: { $0.macID == resolvedMacID })?.macName,
               !savedName.isEmpty {
                return savedName
            }
            return host.name
        }()
        attachBluetoothTransport(
            link,
            targetName: displayTargetName,
            macID: resolvedMacID,
            peripheralID: host.id,
            armWatchdog: simulatedBluetoothConnector == nil,
            preservePINState: preservePINState,
            probeSavedMac: probeSavedMac,
            probeTargetMacID: probeTargetMacID
        )
    }

    @discardableResult
    private func connectKnownBluetoothPeripheral(
        id: UUID,
        targetName: String,
        macID: String?,
        preservePINState: Bool = false
    ) -> Bool {
        if bluetoothBrowser == nil {
            startBluetoothBrowsing()
        }
        guard let link = bluetoothBrowser?.retrieveAndConnect(
            peripheralID: id,
            fallbackName: targetName,
            macID: macID
        ) else {
            let lang = profile.settings.language
            lastConnectionIssue = bluetoothAvailability.detailGuidance(in: lang)
                ?? L10n.tr("蓝牙未就绪或设备超出范围。", "Bluetooth is unavailable or Mac is out of range.", language: lang)
            activeLink = nil
            if !preservePINState {
                connectionState = .disconnected
            }
            return false
        }
        attachBluetoothTransport(
            link,
            targetName: targetName,
            macID: macID,
            peripheralID: id,
            armWatchdog: true,
            preservePINState: preservePINState,
            probeSavedMac: false,
            probeTargetMacID: nil
        )
        return true
    }

    public func connectInMemoryBluetooth(
        to transport: CompanionFrameTransport,
        targetName: String,
        macID: String? = nil,
        peripheralID: UUID? = nil
    ) {
        intentionalDisconnect = false
        consecutiveReconnectFailures = 0
        lastConnectionIssue = nil
        clearPINGlitchState()
        let resolvedMacID: String? = {
            if let macID { return macID }
            if let byPeripheral = savedMacs.first(where: { $0.lastBluetoothPeripheralID != nil && $0.lastBluetoothPeripheralID == peripheralID }) {
                return byPeripheral.macID
            }
            return nil
        }()
        attachBluetoothTransport(
            transport,
            targetName: targetName,
            macID: resolvedMacID,
            peripheralID: peripheralID,
            armWatchdog: false,
            preservePINState: false,
            probeSavedMac: false,
            probeTargetMacID: nil
        )
    }

    private func attachBluetoothTransport(
        _ transport: CompanionFrameTransport,
        targetName: String,
        macID: String?,
        peripheralID: UUID?,
        armWatchdog: Bool,
        preservePINState: Bool,
        probeSavedMac: Bool,
        probeTargetMacID: String?
    ) {
        intentionalDisconnect = false
        wifiPreferenceTask?.cancel()
        reconnectTask?.cancel()
        connectWatchdogTask?.cancel()
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let sessionID = UUID()
        currentSessionID = sessionID
        isTransportReady = false

        let oldConn = connection
        connection = nil
        oldConn?.cancel()

        let oldTransport = frameTransport
        frameTransport = nil
        oldTransport?.cancel()

        accumulator.reset()
        retriedTokenMacIDs.removeAll()
        activeLink = .bluetooth
        activeTargetName = targetName
        activeDirectHost = nil
        activeDirectPort = nil
        activeBluetoothPeripheralID = peripheralID
        candidateMacID = macID
        isSavedMacProbeConnect = probeSavedMac
        self.probeTargetMacID = probeTargetMacID
        if !preservePINState {
            connectionState = .connecting(targetName: targetName)
        }
        frameTransport = transport

        if let metadataTransport = transport as? BluetoothMetadataAwareTransport {
            metadataTransport.onBluetoothMetadata = { [weak self] metadata in
                let applyBlock: @MainActor () -> Void = {
                    guard let self, self.currentSessionID == sessionID else { return }
                    self.handleResolvedBluetoothIdentity(
                        macID: metadata.macID,
                        macName: metadata.macName,
                        peripheralID: peripheralID
                    )
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { applyBlock() }
                } else {
                    Task { @MainActor in applyBlock() }
                }
            }
        }

        if let errorTransport = transport as? BluetoothErrorReportingTransport {
            errorTransport.onTransportError = { [weak self] message in
                let applyBlock: @MainActor () -> Void = {
                    guard let self, self.currentSessionID == sessionID else { return }
                    self.handleBluetoothWriteFailure(message)
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { applyBlock() }
                } else {
                    Task { @MainActor in applyBlock() }
                }
            }
        }

        transport.onReady = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentSessionID == sessionID else { return }
                self.isTransportReady = true
                self.lastServerActivityAt = Date()
                if armWatchdog {
                    self.armHandshakeWatchdog(
                        sessionID: sessionID,
                        failedLink: .bluetooth,
                        timeoutSeconds: max(0.2, self.connectTimeoutSeconds)
                    )
                } else {
                    self.connectWatchdogTask?.cancel()
                    self.connectWatchdogTask = nil
                }
                self.sendHello()
                if let pendingPIN = self.pendingPINSubmission {
                    self.pendingPINSubmission = nil
                    self.send(.submitPIN(
                        pin: pendingPIN,
                        deviceID: self.deviceID,
                        deviceName: self.deviceName,
                        platform: self.platform
                    ))
                }
            }
        }
        transport.onPayload = { [weak self] payload in
            Task { @MainActor [weak self] in
                guard let self, self.currentSessionID == sessionID else { return }
                self.ingest(payload, sessionID: sessionID)
            }
        }
        transport.onClosed = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentSessionID == sessionID else { return }
                self.handleConnectionDropped(failedLink: .bluetooth)
            }
        }

        if armWatchdog {
            armHandshakeWatchdog(
                sessionID: sessionID,
                failedLink: .bluetooth,
                timeoutSeconds: max(0.2, connectTimeoutSeconds)
            )
        }

        transport.start()
    }

    private func handleBluetoothWriteFailure(_ reason: String) {
        currentSessionID = UUID()
        isTransportReady = false
        isSavedMacProbeConnect = false
        probeTargetMacID = nil
        clearPINGlitchState()
        wifiPreferenceTask?.cancel()
        wifiPreferenceTask = nil
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let oldConn = connection
        connection = nil
        oldConn?.cancel()

        let oldTransport = frameTransport
        frameTransport = nil
        oldTransport?.cancel()

        accumulator.reset()
        retriedTokenMacIDs.removeAll()

        if intentionalDisconnect {
            activeLink = nil
            connectionState = .disconnected
            return
        }

        let lang = profile.settings.language
        let target = activeTargetName
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let issue: String
        if trimmed.isEmpty {
            issue = L10n.tr(
                "向 \(target) 发送蓝牙数据失败，请重新选择设备连接。",
                "Bluetooth write to \(target) failed. Select your Mac to reconnect.",
                language: lang
            )
        } else {
            issue = L10n.tr(
                "向 \(target) 发送蓝牙数据失败（\(trimmed)），请重新选择设备连接。",
                "Bluetooth write to \(target) failed (\(trimmed)). Select your Mac to reconnect.",
                language: lang
            )
        }

        activeLink = nil
        lastConnectionIssue = issue
        lastFeedback = CompanionFeedbackToast(
            success: false,
            title: L10n.tr("蓝牙发送失败", "Bluetooth Write Failed", language: lang),
            detail: issue
        )
        connectionState = .disconnected
    }

    private func handleResolvedBluetoothIdentity(
        macID: String,
        macName: String,
        peripheralID: UUID?
    ) {
        if let peripheralID,
           let idx = discoveredBluetoothMacs.firstIndex(where: { $0.id == peripheralID }) {
            let updatedName = macName.isEmpty ? discoveredBluetoothMacs[idx].name : macName
            let updatedHost = DiscoveredBluetoothMac(id: peripheralID, name: updatedName, macID: macID)
            if discoveredBluetoothMacs[idx] != updatedHost {
                discoveredBluetoothMacs[idx] = updatedHost
                discoveredBluetoothMacs.sort {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
        }

        guard activeLink == .bluetooth,
              peripheralID == nil || activeBluetoothPeripheralID == peripheralID else {
            return
        }

        if isSavedMacProbeConnect {
            let matchesSavedProbe: Bool = {
                if let targetID = probeTargetMacID {
                    return macID == targetID && savedMacs.contains(where: { $0.macID == targetID })
                }
                return savedMacs.contains(where: { $0.macID == macID })
            }()

            if !matchesSavedProbe {
                if let peripheralID {
                    rejectedAutoProbePeripheralIDs.insert(peripheralID)
                }
                abortUnmatchedSavedMacProbe(unmatchedTargetMacID: probeTargetMacID)
                return
            }

            isSavedMacProbeConnect = false
            probeTargetMacID = nil
        }

        candidateMacID = macID
        if !macName.isEmpty {
            activeTargetName = macName
        }
        if case .connecting = connectionState {
            connectionState = .connecting(targetName: activeTargetName)
        }
    }

    private func abortUnmatchedSavedMacProbe(unmatchedTargetMacID: String?) {
        currentSessionID = UUID()
        isTransportReady = false
        isSavedMacProbeConnect = false
        probeTargetMacID = nil
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let oldTransport = frameTransport
        frameTransport = nil
        oldTransport?.cancel()

        accumulator.reset()
        retriedTokenMacIDs.removeAll()
        activeLink = nil
        candidateMacID = nil
        activeBluetoothPeripheralID = nil
        connectionState = .disconnected

        if let specificMacID = unmatchedTargetMacID,
           let saved = savedMacs.first(where: { $0.macID == specificMacID }) {
            if let nextHost = matchingDiscoveredBluetoothHost(for: saved) {
                connectBluetoothInternal(
                    to: nextHost,
                    preservePINState: false,
                    probeSavedMac: nextHost.macID == nil,
                    probeTargetMacID: specificMacID
                )
            } else {
                let lang = profile.settings.language
                lastConnectionIssue = L10n.tr(
                    "附近未找到已配对的 \(saved.macName)。",
                    "\(saved.macName) was not found in nearby Bluetooth range.",
                    language: lang
                )
            }
        } else {
            autoConnectIfAppropriate(allowBluetoothNow: true)
        }
    }

    private func openConnection(to endpoint: NWEndpoint, targetName: String, preservePINState: Bool) {
        wifiPreferenceTask?.cancel()
        reconnectTask?.cancel()
        connectWatchdogTask?.cancel()
        pinSubmissionWatchdogTask?.cancel()
        pinSubmissionWatchdogTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let sessionID = UUID()
        currentSessionID = sessionID
        isTransportReady = false
        didAttemptHTTPFallbackInCurrentConnect = false

        let oldConn = connection
        connection = nil
        oldConn?.cancel()

        let oldTransport = frameTransport
        frameTransport = nil
        oldTransport?.cancel()

        accumulator.reset()
        retriedTokenMacIDs.removeAll()

        activeEndpoint = endpoint
        activeTargetName = targetName
        activeLink = .wifi
        if !preservePINState {
            connectionState = .connecting(targetName: targetName)
        }

        #if os(watchOS) && !targetEnvironment(simulator)
        // Per Apple TN3135, low-level Network.framework sockets (`NWConnection`) are blocked by NECP on physical
        // watchOS hardware, whereas high-level `URLSession` HTTP is permitted over direct Watch Wi-Fi and iPhone LAN relay.
        if let (directHost, directPort) = resolvedDirectHostAndPort(from: endpoint) {
            didAttemptHTTPFallbackInCurrentConnect = true
            openHTTPWiFiConnection(
                host: directHost,
                port: directPort,
                targetName: targetName,
                preservePINState: preservePINState
            )
            return
        }
        #endif

        let hasBluetoothFallback = matchingSavedDiscoveredBluetoothHost(preferMacID: candidateMacID) != nil
        let watchdogSeconds = hasBluetoothFallback ? min(3.5, connectTimeoutSeconds) : max(0.2, connectTimeoutSeconds)

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 15
        }

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor [weak self] in
                guard let self, let conn, self.currentSessionID == sessionID, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.isTransportReady = true
                    self.lastServerActivityAt = Date()
                    self.armHandshakeWatchdog(
                        sessionID: sessionID,
                        failedLink: .wifi,
                        timeoutSeconds: watchdogSeconds
                    )
                    self.receiveLoop(for: conn, sessionID: sessionID)
                    self.sendHello()
                    if let pendingPIN = self.pendingPINSubmission {
                        self.pendingPINSubmission = nil
                        self.send(.submitPIN(
                            pin: pendingPIN,
                            deviceID: self.deviceID,
                            deviceName: self.deviceName,
                            platform: self.platform
                        ))
                    }
                case .waiting(let error):
                    self.handleTCPConnectionWaiting(error, sessionID: sessionID)
                case .failed:
                    self.handleConnectionDropped(failedLink: .wifi)
                case .cancelled:
                    if self.intentionalDisconnect {
                        self.connectionState = .disconnected
                    }
                default:
                    break
                }
            }
        }

        armHandshakeWatchdog(
            sessionID: sessionID,
            failedLink: .wifi,
            timeoutSeconds: watchdogSeconds
        )

        if let simulatedWaiting = simulatedTCPWaitingErrorProvider?(endpoint) {
            Task { @MainActor [weak self] in
                guard let self, self.currentSessionID == sessionID else { return }
                self.handleTCPConnectionWaiting(simulatedWaiting, sessionID: sessionID)
            }
        } else {
            conn.start(queue: networkQueue)
        }
    }

    func handleTCPConnectionWaiting(_ error: NWError, sessionID: UUID) {
        guard currentSessionID == sessionID, !isTransportReady else { return }

        var posixCode: POSIXErrorCode?
        if case let .posix(code) = error {
            posixCode = code
        }

        let shouldTryHTTPWiFiFallback: Bool = {
            guard !didAttemptHTTPFallbackInCurrentConnect else { return false }
            if platform == .appleWatch {
                return true
            }
            if let code = posixCode {
                return code == .ENETDOWN || code == .EACCES || code == .EPERM
            }
            return false
        }()

        if shouldTryHTTPWiFiFallback,
           let (host, port) = resolvedDirectHostAndPort(from: activeEndpoint) {
            didAttemptHTTPFallbackInCurrentConnect = true
            openHTTPWiFiConnection(
                host: host,
                port: port,
                targetName: activeTargetName,
                preservePINState: pinGlitchState != nil
            )
            return
        }

        if let code = posixCode,
           code == .ECONNREFUSED || code == .ENETDOWN || code == .ENETUNREACH || code == .EHOSTUNREACH || code == .EACCES || code == .EPERM {
            handleConnectionDropped(failedLink: .wifi)
        }
    }

    private func resolvedDirectHostAndPort(from endpoint: NWEndpoint?) -> (String, UInt16)? {
        if let host = activeDirectHost, !host.isEmpty,
           let port = activeDirectPort, port > 0 {
            return (host, port)
        }
        if let endpoint, case let .hostPort(nwHost, nwPort) = endpoint, nwPort.rawValue > 0 {
            let cleanHost: String? = {
                switch nwHost {
                case .name(let name, _):
                    return name
                case .ipv4(let v4):
                    return String(describing: v4).split(separator: "%").first.map(String.init)
                case .ipv6(let v6):
                    return String(describing: v6).split(separator: "%").first.map(String.init)
                @unknown default:
                    return nil
                }
            }()
            if let cleanHost, !cleanHost.isEmpty {
                return (cleanHost, nwPort.rawValue)
            }
        }
        if let candidateMacID,
           let saved = savedMacs.first(where: { $0.macID == candidateMacID }),
           let host = saved.lastDirectHost, !host.isEmpty,
           let port = saved.lastDirectPort, port > 0 {
            return (host, port)
        }
        return nil
    }

    private func openHTTPWiFiConnection(
        host: String,
        port: UInt16,
        targetName: String,
        preservePINState: Bool
    ) {
        wifiPreferenceTask?.cancel()
        reconnectTask?.cancel()
        connectWatchdogTask?.cancel()
        pinSubmissionWatchdogTask?.cancel()
        pinSubmissionWatchdogTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let sessionID = UUID()
        currentSessionID = sessionID
        isTransportReady = false

        let oldConn = connection
        connection = nil
        oldConn?.cancel()

        let oldTransport = frameTransport
        frameTransport = nil
        oldTransport?.cancel()

        accumulator.reset()
        retriedTokenMacIDs.removeAll()

        activeDirectHost = host
        activeDirectPort = port
        if let nwPort = NWEndpoint.Port(rawValue: port) {
            activeEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
        activeTargetName = targetName
        activeLink = .wifi
        if !preservePINState {
            connectionState = .connecting(targetName: targetName)
        }

        let hasBluetoothFallback = matchingSavedDiscoveredBluetoothHost(preferMacID: candidateMacID) != nil
        let watchdogSeconds = hasBluetoothFallback ? min(3.5, connectTimeoutSeconds) : max(0.2, connectTimeoutSeconds)
        let pollSeconds = max(0.5, min(10.0, heartbeatTimeoutSeconds * 0.6))
        let httpTransport = HTTPCompanionClientLink(
            host: host,
            port: port,
            requestTimeoutSeconds: watchdogSeconds,
            pollTimeoutSeconds: pollSeconds
        )
        frameTransport = httpTransport

        httpTransport.onReady = { [weak self] in
            let apply: @MainActor () -> Void = {
                guard let self, self.currentSessionID == sessionID else { return }
                self.isTransportReady = true
                self.lastServerActivityAt = Date()
                self.armHandshakeWatchdog(
                    sessionID: sessionID,
                    failedLink: .wifi,
                    timeoutSeconds: watchdogSeconds
                )
                self.sendHello()
                if let pendingPIN = self.pendingPINSubmission {
                    self.pendingPINSubmission = nil
                    self.send(.submitPIN(
                        pin: pendingPIN,
                        deviceID: self.deviceID,
                        deviceName: self.deviceName,
                        platform: self.platform
                    ))
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { apply() }
            } else {
                Task { @MainActor in apply() }
            }
        }

        httpTransport.onPayload = { [weak self] payload in
            Task { @MainActor [weak self] in
                guard let self, self.currentSessionID == sessionID else { return }
                self.ingest(payload, sessionID: sessionID)
            }
        }

        httpTransport.onClosed = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentSessionID == sessionID else { return }
                self.handleConnectionDropped(failedLink: .wifi)
            }
        }

        armHandshakeWatchdog(
            sessionID: sessionID,
            failedLink: .wifi,
            timeoutSeconds: watchdogSeconds
        )

        httpTransport.start()
    }

    private func armHandshakeWatchdog(
        sessionID: UUID,
        failedLink: CompanionLinkKind,
        timeoutSeconds: TimeInterval
    ) {
        connectWatchdogTask?.cancel()
        let bounded = max(0.2, timeoutSeconds)
        connectWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(bounded))
            guard let self, !Task.isCancelled, self.currentSessionID == sessionID else { return }
            let stillWaitingForHandshake: Bool = {
                if case .connecting = self.connectionState {
                    return true
                }
                if self.pinGlitchState != nil && !self.isTransportReady {
                    return true
                }
                return false
            }()
            guard stillWaitingForHandshake else { return }
            self.handleConnectionDropped(failedLink: failedLink)
        }
    }

    public func disconnect() {
        intentionalDisconnect = true
        isSavedMacProbeConnect = false
        probeTargetMacID = nil
        currentSessionID = UUID()
        isTransportReady = false
        clearPINGlitchState()
        wifiPreferenceTask?.cancel()
        wifiPreferenceTask = nil
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
        pinSubmissionWatchdogTask?.cancel()
        pinSubmissionWatchdogTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let oldConn = connection
        connection = nil
        oldConn?.cancel()

        let oldTransport = frameTransport
        frameTransport = nil
        oldTransport?.cancel()

        activeLink = nil
        orcaStatus = nil
        clipboardPreview = .empty
        calendarSnapshot = .initial
        frontmostWindows = .empty
        latestScreenshotPreview = nil
        isCapturingScreenshot = false
        var disconnectedStrip = controlStripState
        disconnectedStrip.isKeepMacAwakeEnabled = false
        controlStripState = disconnectedStrip
        tileFeedbackTracker.clearPendingWithoutFeedback()
        lastConnectionIssue = nil
        accumulator.reset()
        retriedTokenMacIDs.removeAll()
        connectionState = .disconnected
    }

    private func clearPINGlitchState() {
        pinGlitchExpiryTask?.cancel()
        pinGlitchExpiryTask = nil
        pinGlitchState = nil
        pendingPINSubmission = nil
    }

    private var shouldSendSessionHeartbeats: Bool {
        if connectionState.isConnected {
            return true
        }
        if case .awaitingPIN = connectionState, isTransportReady {
            return true
        }
        return false
    }

    private func startHeartbeat(sessionID: UUID) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = max(0.05, self?.heartbeatIntervalSeconds ?? 5.0)
                try? await Task.sleep(for: .seconds(interval))
                guard let self,
                      !Task.isCancelled,
                      self.currentSessionID == sessionID,
                      self.shouldSendSessionHeartbeats else {
                    break
                }
                if Date().timeIntervalSince(self.lastServerActivityAt) > max(0.1, self.heartbeatTimeoutSeconds) {
                    self.handleConnectionDropped(failedLink: self.activeLink ?? .bluetooth)
                    break
                }
                self.send(.ping(timestamp: Date().timeIntervalSince1970))
            }
        }
    }

    private func sendHello() {
        let matched = tokenMatchForConnectAttempt(
            macID: candidateMacID,
            peripheralID: activeBluetoothPeripheralID,
            directHost: activeDirectHost
        )
        if let matched {
            retriedTokenMacIDs.insert(matched.macID)
        }
        send(.hello(
            protocolVersion: ChocliftDefaults.protocolVersion,
            deviceID: deviceID,
            deviceName: deviceName,
            platform: platform,
            savedAuthToken: matched?.authToken
        ))
    }

    private func ingest(_ payload: Data, sessionID: UUID) {
        guard currentSessionID == sessionID else { return }
        lastServerActivityAt = Date()
        do {
            let frames = try accumulator.appendAndExtractPayloads(payload)
            for frame in frames {
                do {
                    handleServerMessage(try WireFrameCodec.decodePayload(ServerMessage.self, from: frame))
                } catch {
                    // Each frame is 4-byte length-prefixed, so stream framing stays aligned when a payload
                    // contains an unrecognized ServerMessage case; ignore unknown post-auth frames instead of
                    // dropping an established companion session.
                    guard connectionState.isConnected else {
                        throw error
                    }
                }
            }
        } catch {
            let failed = activeLink ?? .wifi
            handleConnectionDropped(failedLink: failed)
        }
    }

    private func handleConnectionDropped(failedLink: CompanionLinkKind) {
        currentSessionID = UUID()
        isTransportReady = false
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
        pinSubmissionWatchdogTask?.cancel()
        pinSubmissionWatchdogTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        let oldConn = connection
        connection = nil
        oldConn?.cancel()

        let oldTransport = frameTransport
        frameTransport = nil
        oldTransport?.cancel()

        accumulator.reset()
        retriedTokenMacIDs.removeAll()

        if intentionalDisconnect {
            clearPINGlitchState()
            activeLink = nil
            orcaStatus = nil
            clipboardPreview = .empty
            calendarSnapshot = .initial
            frontmostWindows = .empty
            latestScreenshotPreview = nil
            isCapturingScreenshot = false
            var disconnectedStrip = controlStripState
            disconnectedStrip.isKeepMacAwakeEnabled = false
            controlStripState = disconnectedStrip
            tileFeedbackTracker.clearPendingWithoutFeedback()
            connectionState = .disconnected
            return
        }

        // Preserve the PIN keypad across brief transient Wi-Fi/BLE glitches while typing a 6-digit PIN.
        let now = Date()
        if case .awaitingPIN(let pinMacID, let pinMacName, let pinError) = connectionState {
            let deadline = pinGlitchState?.deadline ?? now.addingTimeInterval(max(0.2, pinGlitchRecoveryWindowSeconds))
            if now < deadline {
                pinGlitchState = (macID: pinMacID, macName: pinMacName, errorMessage: pinError, deadline: deadline)
                if pinGlitchExpiryTask == nil {
                    let remaining = max(0.05, deadline.timeIntervalSince(now))
                    pinGlitchExpiryTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(remaining))
                        guard let self, !Task.isCancelled, self.pinGlitchState != nil else { return }
                        let lang = self.profile.settings.language
                        let target = self.activeTargetName
                        self.clearPINGlitchState()
                        self.currentSessionID = UUID()
                        self.connection?.cancel()
                        self.connection = nil
                        self.frameTransport?.cancel()
                        self.frameTransport = nil
                        self.activeLink = nil
                        self.lastConnectionIssue = L10n.tr(
                            "配对过程中与 \(target) 的连接已中断，请重新选择设备。",
                            "Connection to \(target) dropped during PIN entry. Select your Mac to retry.",
                            language: lang
                        )
                        self.connectionState = .disconnected
                    }
                }
                scheduleRecoveryAttempt(
                    failedLink: failedLink,
                    delaySeconds: min(0.2, reconnectDelaySeconds),
                    preservePINState: true
                )
                return
            }
        }

        clearPINGlitchState()

        let wasConnectedOrConnecting: Bool = {
            switch connectionState {
            case .connected, .connecting: return true
            default: return false
            }
        }()

        let lang = profile.settings.language
        let target = activeTargetName
        activeLink = nil
        orcaStatus = nil
        clipboardPreview = .empty
        calendarSnapshot = .initial
        frontmostWindows = .empty
        isCapturingScreenshot = false
        var disconnectedStrip = controlStripState
        disconnectedStrip.isKeepMacAwakeEnabled = false
        controlStripState = disconnectedStrip
        if let failedBanner = tileFeedbackTracker.failPendingOnDisconnect() {
            publishTileFeedback(failedBanner)
        }
        connectionState = .disconnected
        if wasConnectedOrConnecting {
            lastConnectionIssue = L10n.tr(
                "与 \(target) 的连接已断开。",
                "Disconnected from \(target).",
                language: lang
            )
        }

        guard wasConnectedOrConnecting else { return }

        // Immediate cross-link failover when Wi-Fi fails/drops and Bluetooth has discovered the paired Mac.
        if failedLink == .wifi,
           let btFallback = matchingSavedDiscoveredBluetoothHost(preferMacID: candidateMacID) {
            consecutiveReconnectFailures = 0
            connectBluetoothInternal(
                to: btFallback,
                preservePINState: false,
                probeSavedMac: btFallback.macID == nil,
                probeTargetMacID: nil
            )
            return
        }

        if failedLink == .bluetooth, isSavedMacProbeConnect, candidateMacID == nil {
            if let failedProbeID = activeBluetoothPeripheralID {
                rejectedAutoProbePeripheralIDs.insert(failedProbeID)
            }
            let targetID = probeTargetMacID
            isSavedMacProbeConnect = false
            probeTargetMacID = nil
            if let nextCandidate = matchingSavedDiscoveredBluetoothHost(preferMacID: targetID) {
                lastConnectionIssue = nil
                connectBluetoothInternal(
                    to: nextCandidate,
                    preservePINState: false,
                    probeSavedMac: nextCandidate.macID == nil,
                    probeTargetMacID: targetID
                )
                return
            }
        }

        consecutiveReconnectFailures += 1
        guard consecutiveReconnectFailures <= maxAutoReconnectAttempts else {
            lastConnectionIssue = L10n.tr(
                "无法连接到 \(target)，已停止重试；当 Mac 重新出现在 Wi-Fi 或蓝牙范围时会自动连接。",
                "Could not reach \(target). Stopped retrying; will reconnect automatically when your Mac reappears on Wi-Fi or Bluetooth.",
                language: lang
            )
            return
        }

        scheduleRecoveryAttempt(
            failedLink: failedLink,
            delaySeconds: reconnectDelaySeconds,
            preservePINState: false
        )
    }

    private func scheduleRecoveryAttempt(
        failedLink: CompanionLinkKind,
        delaySeconds: TimeInterval,
        preservePINState: Bool
    ) {
        let retryEndpoint = activeEndpoint
        let retryName = activeTargetName
        let retryMacID = candidateMacID
        let retryPeripheralID = activeBluetoothPeripheralID

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.02, delaySeconds)))
            guard let self, !Task.isCancelled, !self.intentionalDisconnect else { return }
            if preservePINState {
                guard self.pinGlitchState != nil else { return }
            } else {
                guard self.connectionState == .disconnected else { return }
            }

            // 1. Prefer live Bonjour Wi-Fi if discovered.
            if let wifiHost = self.matchingSavedWiFiHost()
                ?? (preservePINState ? self.discoveredMacs.first(where: { $0.macID == retryMacID || $0.name == retryName }) : nil) {
                self.candidateMacID = wifiHost.macID ?? retryMacID
                self.openConnection(to: wifiHost.endpoint, targetName: wifiHost.name, preservePINState: preservePINState)
                return
            }

            // 2. Otherwise use live discovered Bluetooth Mac if available.
            if let btHost = self.matchingSavedDiscoveredBluetoothHost(preferMacID: retryMacID)
                ?? (preservePINState ? self.discoveredBluetoothMacs.first(where: { $0.id == retryPeripheralID || $0.macID == retryMacID }) : nil) {
                self.connectBluetoothInternal(
                    to: btHost,
                    preservePINState: preservePINState,
                    probeSavedMac: !preservePINState && btHost.macID == nil,
                    probeTargetMacID: nil
                )
                return
            }

            // 3. Test hook for simulated BLE auto-reconnect.
            if failedLink == .bluetooth,
               let simTransport = self.simulatedBluetoothReconnectProvider?() {
                self.attachBluetoothTransport(
                    simTransport,
                    targetName: retryName,
                    macID: retryMacID,
                    peripheralID: retryPeripheralID,
                    armWatchdog: false,
                    preservePINState: preservePINState,
                    probeSavedMac: false,
                    probeTargetMacID: nil
                )
                return
            }

            // 4. Retry saved Bluetooth peripheral or previous TCP endpoint within retry budget.
            if failedLink == .bluetooth,
               let pid = retryPeripheralID ?? self.savedMacs.first(where: { $0.macID == retryMacID })?.lastBluetoothPeripheralID,
               self.isBluetoothPoweredOn,
               self.connectKnownBluetoothPeripheral(id: pid, targetName: retryName, macID: retryMacID, preservePINState: preservePINState) {
                return
            }

            if let endpoint = retryEndpoint {
                self.openConnection(to: endpoint, targetName: retryName, preservePINState: preservePINState)
                return
            }

            if let pid = retryPeripheralID ?? self.savedMacs.first(where: { $0.macID == retryMacID })?.lastBluetoothPeripheralID,
               self.isBluetoothPoweredOn {
                _ = self.connectKnownBluetoothPeripheral(id: pid, targetName: retryName, macID: retryMacID, preservePINState: preservePINState)
            }
        }
    }

    // MARK: - Pairing & Commands

    public func submitPIN(_ pin: String) {
        if case .awaitingPIN(let macID, let macName, let existingErr) = connectionState, existingErr != nil {
            connectionState = .awaitingPIN(macID: macID, macName: macName, errorMessage: nil)
        }
        pinSubmissionWatchdogTask?.cancel()
        let submittedSessionID = currentSessionID
        let pinTimeout = max(0.3, connectTimeoutSeconds)
        pinSubmissionWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(pinTimeout))
            guard let self, !Task.isCancelled, self.currentSessionID == submittedSessionID else { return }
            guard case .awaitingPIN(let macID, let macName, let currentErr) = self.connectionState,
                  currentErr == nil else {
                return
            }
            let lang = self.profile.settings.language
            self.connectionState = .awaitingPIN(
                macID: macID,
                macName: macName,
                errorMessage: L10n.tr(
                    "验证超时，Mac 未响应配对结果，请重试。",
                    "PIN verification timed out with no reply from your Mac. Please try again.",
                    language: lang
                )
            )
        }

        if isTransportReady {
            pendingPINSubmission = nil
            send(.submitPIN(pin: pin, deviceID: deviceID, deviceName: deviceName, platform: platform))
        } else if pinGlitchState != nil {
            pendingPINSubmission = pin
        } else {
            send(.submitPIN(pin: pin, deviceID: deviceID, deviceName: deviceName, platform: platform))
        }
    }

    public func triggerBarItem(_ item: BarItem, from slotOrigin: SlotCoordinate? = nil) {
        let resolvedSlot = slotOrigin ?? locateSlot(for: item.id)
        if let resolvedSlot {
            tileFeedbackTracker.recordTileTriggered(slot: resolvedSlot)
        } else {
            tileFeedbackTracker.clearPendingWithoutFeedback()
        }
        recordRecentlyTriggeredTile(item, from: resolvedSlot)
        send(.triggerBarItem(item))
    }

    public func recordOfflineTileFailure(slot: SlotCoordinate?, title: String, detail: String) {
        if let slot {
            publishTileFeedback(tileFeedbackTracker.recordImmediateOutcome(slot: slot, outcome: .failure))
            if let slotItem = profile.barItem(at: slot) {
                recordRecentlyTriggeredTile(slotItem, from: slot)
            }
        } else {
            tileFeedbackTracker.clearPendingWithoutFeedback()
        }
        lastFeedback = CompanionFeedbackToast(success: false, title: title, detail: detail)
    }

    public func recordRecentlyTriggeredTile(_ item: BarItem, from slotOrigin: SlotCoordinate? = nil) {
        if item.isSlotReference, profile.resolveBarItem(item, from: slotOrigin).isMissing {
            return
        }
        let resolvedTitle = profile.displayTitle(for: item, from: slotOrigin, in: profile.settings.language)
        var list = RecentlyTriggeredTileList(entries: recentlyTriggeredTiles)
        list.record(id: item.id, title: resolvedTitle)
        recentlyTriggeredTiles = list.entries
        persistRecentlyTriggeredTiles()
    }

    public func clearRecentlyTriggeredTiles() {
        recentlyTriggeredTiles = []
        persistRecentlyTriggeredTiles()
    }

    public func tileOutcome(for slot: SlotCoordinate?) -> TileActionOutcome? {
        guard let slot else { return nil }
        return tileFeedbackTracker.outcome(for: slot)
    }

    public func triggerFlow(id: UUID) {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.triggerFlow(flowID: id))
    }

    public func activateRecentApp(_ entry: RecentAppEntry) {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.activateRecentApp(bundleIdentifier: entry.bundleIdentifier, appPath: entry.appPath))
    }

    public func togglePinRecentApp(_ entry: RecentAppEntry) {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.setRecentAppPinned(bundleIdentifier: entry.bundleIdentifier, isPinned: !entry.isPinned))
    }

    public func quitOrHideApp(bundleIdentifier: String, shouldQuit: Bool) {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.quitOrHideApp(bundleIdentifier: bundleIdentifier, shouldQuit: shouldQuit))
    }

    public func insertText(_ text: String) {
        let clamped = TextSnippet.clampBody(text)
        guard !clamped.isEmpty else { return }
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.insertEmoji(clamped))
    }

    public func insertEmoji(_ emoji: String) {
        insertText(emoji)
    }

    public func performGesture(_ gesture: TouchGestureType) {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.performGesture(gesture))
    }

    public func performQuickAction(_ action: SystemQuickAction) {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.performQuickAction(action))
    }

    public func requestControlStripState() {
        send(.requestControlStripState)
    }

    public func setControlLevel(kind: ControlLevelKind, level: Double) {
        let clamped = ControlStripLevel.clamp(level)
        var next = controlStripState
        switch kind {
        case .volume:
            next.volume = clamped
            if clamped > 0.001 {
                next.isVolumeMuted = false
            }
        case .brightness:
            next.brightness = clamped
        }
        controlStripState = next
        send(.setControlLevel(kind: kind, level: clamped))
    }

    public func setMicMuted(_ isMuted: Bool) {
        var next = controlStripState
        next.isMicMuted = isMuted
        controlStripState = next
        send(.setMicMuted(isMuted))
    }

    public func toggleMicMute() {
        setMicMuted(!controlStripState.isMicMuted)
    }

    public func undoLastWindowMove() {
        guard controlStripState.canUndoWindowMove else { return }
        var next = controlStripState
        next.canUndoWindowMove = false
        controlStripState = next
        send(.undoLastWindowMove)
    }

    public func requestCompanionDashboard() {
        send(.requestCompanionDashboard)
    }

    public func pasteMacClipboard() {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.pasteMacClipboard)
    }

    public func captureMainDisplayScreenshot() {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        isCapturingScreenshot = true
        send(.captureMainDisplayScreenshot)
    }

    public func dismissScreenshotPreview() {
        latestScreenshotPreview = nil
    }

    public func setTargetDisplay(displayID: UInt32?) {
        var next = controlStripState
        next.selectedTargetDisplayID = DisplaySnapTargetResolver.resolvedTargetDisplayID(
            selectedDisplayID: displayID,
            connectedDisplays: next.connectedDisplays
        )
        controlStripState = next
        send(.setTargetDisplay(displayID: next.effectiveTargetDisplayID))
    }

    public func openCalendarOnMac() {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.openCalendarApp)
    }

    public func triggerSoundboardClip(id: UUID) {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.triggerSoundboardClip(soundID: id))
    }

    public func stopSoundboardPlayback() {
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.stopSoundboardPlayback)
    }

    public func setSoundboardVolume(_ level: Double) {
        let clamped = ControlStripLevel.clamp(level)
        var nextStrip = controlStripState
        nextStrip.soundboardVolume = clamped
        controlStripState = nextStrip
        profile.soundboardVolume = clamped
        send(.setSoundboardVolume(level: clamped))
    }

    public func setKeepMacAwake(_ isEnabled: Bool) {
        let lang = profile.settings.language
        guard connectionState.isConnected else {
            var next = controlStripState
            next.isKeepMacAwakeEnabled = false
            controlStripState = next
            lastFeedback = CompanionFeedbackToast(
                success: false,
                title: L10n.tr("保持 Mac 唤醒", "Keep Mac Awake", language: lang),
                detail: L10n.tr("需连接 Mac 后才能开启防休眠", "Connect to your Mac to prevent idle sleep", language: lang)
            )
            return
        }
        tileFeedbackTracker.clearPendingWithoutFeedback()
        var next = controlStripState
        next.isKeepMacAwakeEnabled = isEnabled
        controlStripState = next
        send(.setKeepMacAwake(isEnabled))
    }

    public func toggleKeepMacAwake() {
        setKeepMacAwake(!controlStripState.isKeepMacAwakeEnabled)
    }

    /// Requests switching the Mac's default CoreAudio output device without optimistically faking a switch locally.
    public func selectAudioOutputDevice(id: String) {
        let lang = profile.settings.language
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard connectionState.isConnected else {
            lastFeedback = CompanionFeedbackToast(
                success: false,
                title: L10n.tr("音频输出", "Audio Output", language: lang),
                detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
            )
            return
        }
        guard controlStripState.canSwitchAudioOutput else {
            lastFeedback = CompanionFeedbackToast(
                success: false,
                title: L10n.tr("音频输出只读", "Audio Output Read-Only", language: lang),
                detail: L10n.tr(
                    "当前 macOS 音频硬件不支持通过公开 API 切换默认输出设备。",
                    "macOS reported the default audio output as read-only via public CoreAudio API.",
                    language: lang
                )
            )
            return
        }
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.setAudioOutputDevice(deviceID: trimmed))
    }

    public func requestFrontmostAppWindows() {
        guard connectionState.isConnected else { return }
        send(.requestFrontmostAppWindows)
    }

    public func raiseFrontmostWindow(id: String) {
        let lang = profile.settings.language
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard connectionState.isConnected else {
            lastFeedback = CompanionFeedbackToast(
                success: false,
                title: L10n.tr("置顶窗口", "Raise Window", language: lang),
                detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
            )
            return
        }
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.raiseFrontmostWindow(windowID: trimmed))
    }

    /// Puts the Mac display to sleep without locking the Mac or changing the Keep Mac Awake toggle.
    public func sleepMacDisplay() {
        let lang = profile.settings.language
        guard connectionState.isConnected else {
            lastFeedback = CompanionFeedbackToast(
                success: false,
                title: L10n.tr("熄灭屏幕", "Sleep Display", language: lang),
                detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
            )
            return
        }
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.sleepMacDisplay)
    }

    /// Sends Escape, Space, or an Arrow key to the frontmost Mac app through the existing input path.
    public func sendCompactKey(_ key: CompanionCompactKey) {
        let lang = profile.settings.language
        guard connectionState.isConnected else {
            lastFeedback = CompanionFeedbackToast(
                success: false,
                title: key.title(in: lang),
                detail: L10n.tr("尚未连接 Mac", "Mac Not Connected", language: lang)
            )
            return
        }
        tileFeedbackTracker.clearPendingWithoutFeedback()
        send(.sendCompactKey(key))
    }

    @discardableResult
    public func pinSlotToStrip(_ coordinate: SlotCoordinate) -> Bool {
        var next = profile
        guard next.pinSlotToStrip(coordinate) else { return false }
        pushUpdatedProfile(next)
        return true
    }

    @discardableResult
    public func unpinSlotFromStrip(_ coordinate: SlotCoordinate) -> Bool {
        var next = profile
        guard next.unpinSlotFromStrip(coordinate) else { return false }
        pushUpdatedProfile(next)
        return true
    }

    @discardableResult
    public func togglePinSlotToStrip(_ coordinate: SlotCoordinate) -> Bool {
        if profile.isSlotPinnedToStrip(coordinate) {
            return unpinSlotFromStrip(coordinate)
        }
        return pinSlotToStrip(coordinate)
    }

    public func pushUpdatedProfile(_ updated: ChocliftWorkspaceProfile) {
        var next = updated
        next.prunePinnedStripSlots()
        next.bumpRevision()
        self.profile = next
        send(.updateProfile(next))
        requestMissingIconsIfNeeded()
    }

    public func requestMacCatalog() {
        send(.requestMacCatalog)
    }

    public func focusOrcaTask(dispatchID: String) {
        let trimmed = dispatchID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(.focusOrcaTask(dispatchID: trimmed))
    }

    public func forgetSavedMac(macID: String) {
        savedMacs.removeAll { $0.macID == macID }
        persistSavedCredentials()
    }

    // MARK: - Wire Send / Receive

    private func send(_ message: ClientMessage) {
        do {
            let framed = try WireFrameCodec.encode(message)
            if let frameTransport {
                frameTransport.send(framed)
            } else {
                connection?.send(content: framed, completion: .contentProcessed { _ in })
            }
        } catch {
            lastFeedback = CompanionFeedbackToast(success: false, title: "Send Error", detail: error.localizedDescription)
        }
    }

    private func receiveLoop(for conn: NWConnection, sessionID: UUID) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak conn] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, let conn, self.currentSessionID == sessionID, self.connection === conn else { return }

                if let data, !data.isEmpty {
                    self.ingest(data, sessionID: sessionID)
                }

                if isComplete || error != nil {
                    if self.currentSessionID == sessionID {
                        self.handleConnectionDropped(failedLink: .wifi)
                    }
                } else {
                    self.receiveLoop(for: conn, sessionID: sessionID)
                }
            }
        }
    }

    private func handleServerMessage(_ message: ServerMessage) {
        switch message {
        case .pairingRequired(let macID, let macName):
            if activeLink == .bluetooth {
                handleResolvedBluetoothIdentity(
                    macID: macID,
                    macName: macName,
                    peripheralID: activeBluetoothPeripheralID
                )
                guard activeLink == .bluetooth else { return }
            }
            candidateMacID = macID
            activeTargetName = macName
            if let existing = savedMacs.first(where: { $0.macID == macID }),
               !retriedTokenMacIDs.contains(macID) {
                retriedTokenMacIDs.insert(macID)
                if pinGlitchState == nil {
                    connectionState = .connecting(targetName: macName)
                }
                armHandshakeWatchdog(
                    sessionID: currentSessionID,
                    failedLink: activeLink ?? .wifi,
                    timeoutSeconds: max(0.2, connectTimeoutSeconds)
                )
                send(.hello(
                    protocolVersion: ChocliftDefaults.protocolVersion,
                    deviceID: deviceID,
                    deviceName: deviceName,
                    platform: platform,
                    savedAuthToken: existing.authToken
                ))
            } else {
                connectWatchdogTask?.cancel()
                connectWatchdogTask = nil
                let preservedErr = pinGlitchState?.errorMessage
                connectionState = .awaitingPIN(macID: macID, macName: macName, errorMessage: preservedErr)
                startHeartbeat(sessionID: currentSessionID)
            }

        case .authSucceeded(
            let macID,
            let macName,
            let authToken,
            let serverProfile,
            let serverRecents,
            let frontmost,
            let editingText,
            let focusedApp,
            let axTrusted
        ):
            connectWatchdogTask?.cancel()
            connectWatchdogTask = nil
            pinSubmissionWatchdogTask?.cancel()
            pinSubmissionWatchdogTask = nil
            clearPINGlitchState()
            isSavedMacProbeConnect = false
            probeTargetMacID = nil
            consecutiveReconnectFailures = 0
            lastConnectionIssue = nil
            candidateMacID = macID
            activeTargetName = macName
            let resolvedPeripheralID = activeBluetoothPeripheralID
                ?? discoveredBluetoothMacs.first(where: {
                    $0.macID == macID ||
                    $0.name.caseInsensitiveCompare(macName) == .orderedSame
                })?.id
            saveCredential(
                SavedMacCredential(
                    macID: macID,
                    macName: macName,
                    authToken: authToken,
                    lastDirectHost: activeDirectHost,
                    lastDirectPort: activeDirectPort,
                    lastBluetoothPeripheralID: resolvedPeripheralID,
                    updatedAt: Date()
                )
            )
            profile = serverProfile
            var initialStrip = controlStripState
            initialStrip.soundboardVolume = serverProfile.soundboardVolume
            controlStripState = initialStrip
            recentApps = serverRecents
            frontmostBundleID = frontmost
            frontmostAppName = frontmost.flatMap { bid in
                serverRecents.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(bid) == .orderedSame })?.appName
            }
            isEditingTextOnMac = editingText
            focusedMacAppName = focusedApp
            isMacAccessibilityGranted = axTrusted
            orcaStatus = nil
            clipboardPreview = .empty
            frontmostWindows = .empty
            isCapturingScreenshot = false
            connectionState = .connected(macID: macID, macName: macName)
            startHeartbeat(sessionID: currentSessionID)
            requestMissingIconsIfNeeded()
            send(.requestControlStripState)
            send(.requestCompanionDashboard)
            if platform != .appleWatch {
                send(.requestFrontmostAppWindows)
            }

        case .authFailed(let reason):
            connectWatchdogTask?.cancel()
            connectWatchdogTask = nil
            pinSubmissionWatchdogTask?.cancel()
            pinSubmissionWatchdogTask = nil
            if case .awaitingPIN(let macID, let macName, _) = connectionState {
                connectionState = .awaitingPIN(macID: macID, macName: macName, errorMessage: reason)
            } else {
                lastFeedback = CompanionFeedbackToast(success: false, title: "Pairing Error", detail: reason)
            }

        case .profileUpdated(let updatedProfile):
            profile = updatedProfile
            var nextStrip = controlStripState
            nextStrip.soundboardVolume = updatedProfile.soundboardVolume
            controlStripState = nextStrip
            requestMissingIconsIfNeeded()

        case .recentAppsUpdated(let entries):
            recentApps = entries
            requestMissingIconsIfNeeded()

        case .frontmostAppChanged(let bundleID, let appName):
            frontmostBundleID = bundleID
            frontmostAppName = appName

        case .textFieldFocusChanged(let isEditingText, let appName):
            isEditingTextOnMac = isEditingText
            focusedMacAppName = appName

        case .accessibilityStatusChanged(let isTrusted):
            isMacAccessibilityGranted = isTrusted

        case .appIconsBatch(let batch):
            for (bundleID, pngData) in batch {
                appIconsByBundleID[bundleID] = pngData
            }

        case .macCatalogSnapshot(let apps, let shortcuts):
            macCatalogApps = apps
            macCatalogShortcuts = shortcuts
            for app in apps {
                if let icon = app.iconPNGData {
                    appIconsByBundleID[app.bundleIdentifier] = icon
                }
            }

        case .actionFeedback(let success, let title, let detail):
            if let resolvedTileBanner = tileFeedbackTracker.resolvePending(success: success) {
                publishTileFeedback(resolvedTileBanner)
            }
            lastFeedback = CompanionFeedbackToast(success: success, title: title, detail: detail)

        case .orcaStatusUpdated(let snapshot):
            orcaStatus = snapshot

        case .pong:
            break

        case .controlStripStateUpdated(let state):
            controlStripState = state
            profile.soundboardVolume = state.soundboardVolume

        case .clipboardPreviewUpdated(let snapshot):
            guard platform != .appleWatch else {
                clipboardPreview = .empty
                return
            }
            clipboardPreview = snapshot

        case .screenshotCaptured(let result):
            isCapturingScreenshot = false
            let shotTitle = L10n.tr("主屏幕截图", "Main Display Screenshot", language: profile.settings.language)
            if result.success {
                if result.previewJPEGData != nil {
                    latestScreenshotPreview = result
                }
                let savedDetail = result.fileName.map {
                    L10n.tr("已保存到 Mac 桌面：\($0)", "Saved to Mac Desktop: \($0)", language: profile.settings.language)
                } ?? L10n.tr("已保存到 Mac 桌面", "Saved to Mac Desktop", language: profile.settings.language)
                lastFeedback = CompanionFeedbackToast(success: true, title: shotTitle, detail: savedDetail)
            } else {
                latestScreenshotPreview = nil
                let errDetail = result.errorMessage ?? L10n.tr(
                    "需要屏幕录制权限：请在系统设置 → 隐私与安全性 → 屏幕录制中开启 Choclift",
                    "Screen Recording permission required — enable Choclift in System Settings → Privacy & Security → Screen Recording",
                    language: profile.settings.language
                )
                lastFeedback = CompanionFeedbackToast(success: false, title: shotTitle, detail: errDetail)
            }

        case .calendarStatusUpdated(let snapshot):
            calendarSnapshot = snapshot

        case .frontmostWindowsUpdated(let snapshot):
            frontmostWindows = snapshot

        case .unknownServerMessage:
            if !connectionState.isConnected {
                handleConnectionDropped(failedLink: activeLink ?? .wifi)
            }
        }
    }

    private func locateSlot(for itemID: UUID) -> SlotCoordinate? {
        for page in profile.pages {
            for (slotIndex, candidate) in page.slots.enumerated() where candidate?.id == itemID {
                return SlotCoordinate(pageID: page.id, slotIndex: slotIndex)
            }
        }
        return nil
    }

    private func publishTileFeedback(_ banner: TileActionFeedbackBanner?) {
        activeTileFeedback = banner
        tileFeedbackExpiryTask?.cancel()
        tileFeedbackExpiryTask = nil
        guard let banner else { return }
        let token = banner.token
        let duration = max(0.05, tileFeedbackDurationSeconds)
        tileFeedbackExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            if self.tileFeedbackTracker.expireFeedback(matchingToken: token) {
                self.activeTileFeedback = nil
            }
        }
    }

    private func requestMissingIconsIfNeeded() {
        guard connectionState.isConnected else { return }
        var needed = Set<String>()
        for bundleID in profile.referencedAppBundleIdentifiers where appIconsByBundleID[bundleID] == nil {
            needed.insert(bundleID)
        }
        for recent in recentApps where appIconsByBundleID[recent.bundleIdentifier] == nil {
            needed.insert(recent.bundleIdentifier)
        }
        if !needed.isEmpty {
            send(.requestIcons(bundleIdentifiers: Array(needed)))
        }
    }

    // MARK: - Credential Persistence

    func tokenForConnectAttempt(
        macID: String?,
        peripheralID: UUID?,
        directHost: String?,
        targetName: String
    ) -> String? {
        tokenMatchForConnectAttempt(
            macID: macID,
            peripheralID: peripheralID,
            directHost: directHost
        )?.authToken
    }

    private func tokenMatchForConnectAttempt(
        macID: String?,
        peripheralID: UUID?,
        directHost: String?
    ) -> SavedMacCredential? {
        if let macID {
            return savedMacs.first(where: { $0.macID == macID })
        }
        if let peripheralID,
           let cred = savedMacs.first(where: { $0.lastBluetoothPeripheralID == peripheralID }) {
            return cred
        }
        if let directHost,
           let cred = savedMacs.first(where: { $0.lastDirectHost == directHost }) {
            return cred
        }
        return nil
    }

    private func saveCredential(_ credential: SavedMacCredential) {
        var merged = credential
        if let idx = savedMacs.firstIndex(where: { $0.macID == credential.macID }) {
            let existing = savedMacs[idx]
            if merged.lastDirectHost == nil {
                merged.lastDirectHost = existing.lastDirectHost
            }
            if merged.lastDirectPort == nil {
                merged.lastDirectPort = existing.lastDirectPort
            }
            if merged.lastBluetoothPeripheralID == nil {
                merged.lastBluetoothPeripheralID = existing.lastBluetoothPeripheralID
            }
            savedMacs[idx] = merged
        } else {
            savedMacs.insert(merged, at: 0)
        }
        persistSavedCredentials()
    }

    private func loadSavedCredentials() {
        guard let data = storageDefaults.data(forKey: savedMacsKey),
              let decoded = try? JSONDecoder().decode([SavedMacCredential].self, from: data) else {
            savedMacs = []
            return
        }
        savedMacs = decoded
    }

    private func persistSavedCredentials() {
        if let data = try? JSONEncoder().encode(savedMacs) {
            storageDefaults.set(data, forKey: savedMacsKey)
        }
    }

    private func loadRecentlyTriggeredTiles() {
        guard let data = storageDefaults.data(forKey: recentlyTriggeredTilesKey),
              let decoded = try? JSONDecoder().decode(RecentlyTriggeredTileList.self, from: data) else {
            recentlyTriggeredTiles = []
            return
        }
        recentlyTriggeredTiles = decoded.entries
    }

    private func persistRecentlyTriggeredTiles() {
        let list = RecentlyTriggeredTileList(entries: recentlyTriggeredTiles)
        if let data = try? JSONEncoder().encode(list) {
            storageDefaults.set(data, forKey: recentlyTriggeredTilesKey)
        }
    }
}
