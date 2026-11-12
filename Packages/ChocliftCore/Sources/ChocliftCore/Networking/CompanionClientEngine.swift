import Foundation
import Network

public struct DiscoveredMacHost: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let macID: String?
    public let endpoint: NWEndpoint

    public init(id: String, name: String, macID: String?, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.macID = macID
        self.endpoint = endpoint
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
    @Published public private(set) var isEditingTextOnMac: Bool = false
    @Published public private(set) var focusedMacAppName: String?
    @Published public private(set) var isMacAccessibilityGranted: Bool = true
    @Published public private(set) var appIconsByBundleID: [String: Data] = [:]
    @Published public private(set) var macCatalogApps: [InstalledAppSummary] = []
    @Published public private(set) var macCatalogShortcuts: [InstalledShortcutSummary] = []
    @Published public var lastFeedback: CompanionFeedbackToast?

    public let deviceID: String
    public var deviceName: String
    public let platform: DevicePlatform

    /// Optional test hook allowing simulated BLE transports to exercise automatic token reconnect on drop.
    public var simulatedBluetoothReconnectProvider: (() -> CompanionFrameTransport?)?
    public var reconnectDelaySeconds: TimeInterval = 2.0
    public var connectTimeoutSeconds: TimeInterval = 8.0
    public var heartbeatIntervalSeconds: TimeInterval = 5.0
    public var heartbeatTimeoutSeconds: TimeInterval = 15.0
    public var maxAutoReconnectAttempts: Int = 3
    public var pinGlitchRecoveryWindowSeconds: TimeInterval = 6.0

    /// True if the user tapped Disconnect/Cancel during the current app launch; never persisted across launches.
    public var isAutoConnectSuppressedForCurrentLaunch: Bool {
        intentionalDisconnect
    }

    private let storageDefaults: UserDefaults
    private let savedMacsKey: String
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
    private var activeBluetoothMacIDTag: String?
    private var candidateMacID: String?
    private var retriedTokenMacIDs: Set<String> = []
    private var consecutiveReconnectFailures: Int = 0

    private var pinGlitchState: (macID: String, macName: String, errorMessage: String?, deadline: Date)?
    private var pendingPINSubmission: String?

    private var intentionalDisconnect = false
    private var wifiPreferenceTask: Task<Void, Never>?
    private var connectWatchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pinGlitchExpiryTask: Task<Void, Never>?

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
        loadSavedCredentials()
    }

    // MARK: - Discovery

    public func startBrowsing() {
        stopBrowsing()
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
                        if case let .bonjour(txtRecord) = result.metadata {
                            macID = txtRecord["macID"]
                            if let txtName = txtRecord["macName"], !txtName.isEmpty {
                                customName = txtName
                            }
                        }
                        let uniqueID = "\(name).\(type).\(domain)"
                        hosts.append(
                            DiscoveredMacHost(
                                id: uniqueID,
                                name: customName,
                                macID: macID,
                                endpoint: result.endpoint
                            )
                        )
                    }
                }
                self.discoveredMacs = hosts.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                self.consecutiveReconnectFailures = 0
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
            self.discoveredBluetoothMacs = hosts
            self.isBluetoothPoweredOn = scanner.isPoweredOn
            self.bluetoothAvailability = scanner.availability
            if !hosts.isEmpty {
                self.consecutiveReconnectFailures = 0
            }
            self.autoConnectIfAppropriate()
        }
        scanner.onMetadataResolved = { [weak self] host in
            guard let self else { return }
            self.discoveredBluetoothMacs = scanner.discovered
            if self.activeLink == .bluetooth && self.activeBluetoothPeripheralID == host.id {
                self.activeTargetName = host.name
                if let macID = host.macID {
                    self.candidateMacID = macID
                    self.activeBluetoothMacIDTag = ChocliftBluetooth.macIDTag(for: macID)
                }
                if case .connecting = self.connectionState {
                    self.connectionState = .connecting(targetName: host.name)
                }
            }
        }
        scanner.onLinkReady = { [weak self] _, host in
            guard let self else { return }
            self.discoveredBluetoothMacs = scanner.discovered
            self.isBluetoothPoweredOn = scanner.isPoweredOn
            self.bluetoothAvailability = scanner.availability
            if self.activeLink == .bluetooth && self.activeBluetoothPeripheralID == host.id {
                self.activeTargetName = host.name
                if let macID = host.macID {
                    self.candidateMacID = macID
                    self.activeBluetoothMacIDTag = ChocliftBluetooth.macIDTag(for: macID)
                } else if let tag = host.macIDTag {
                    self.activeBluetoothMacIDTag = tag
                }
            }
        }
        scanner.start()
        isBluetoothPoweredOn = scanner.isPoweredOn
        bluetoothAvailability = scanner.availability
        discoveredBluetoothMacs = scanner.discovered
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
        if !isBrowsingActive {
            startBrowsing()
        } else {
            bluetoothBrowser?.start()
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
            connectBluetooth(to: btHost)
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
        let expectedTag = ChocliftBluetooth.macIDTag(for: saved.macID)
        if let byID = discoveredBluetoothMacs.first(where: { $0.macID == saved.macID }) {
            return byID
        }
        if let byTag = discoveredBluetoothMacs.first(where: { $0.macIDTag == expectedTag }) {
            return byTag
        }
        if let pid = saved.lastBluetoothPeripheralID,
           let byPeripheral = discoveredBluetoothMacs.first(where: { $0.id == pid && $0.macID == nil && $0.macIDTag == nil }) {
            return byPeripheral
        }
        if let byName = discoveredBluetoothMacs.first(where: {
            $0.macID == nil &&
            $0.macIDTag == nil &&
            Self.namesLikelyMatch(savedName: saved.macName, advertisedName: $0.name)
        }) {
            return byName
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
        if let wifiHost = discoveredMacs.first(where: {
            $0.macID == saved.macID || $0.name.caseInsensitiveCompare(saved.macName) == .orderedSame
        }) {
            connect(to: wifiHost)
            return
        }
        if let btHost = matchingDiscoveredBluetoothHost(for: saved) {
            connectBluetooth(to: btHost)
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
        consecutiveReconnectFailures = 0
        lastConnectionIssue = nil
        clearPINGlitchState()
        wifiPreferenceTask?.cancel()
        reconnectTask?.cancel()
        candidateMacID = discovered.macID
            ?? savedMacs.first(where: { $0.macName.caseInsensitiveCompare(discovered.name) == .orderedSame })?.macID
        activeDirectHost = nil
        activeDirectPort = nil
        activeBluetoothPeripheralID = nil
        activeBluetoothMacIDTag = nil
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
        consecutiveReconnectFailures = 0
        lastConnectionIssue = nil
        clearPINGlitchState()
        wifiPreferenceTask?.cancel()
        reconnectTask?.cancel()
        activeDirectHost = trimmedHost
        activeDirectPort = port
        activeBluetoothPeripheralID = nil
        activeBluetoothMacIDTag = nil
        candidateMacID = savedMacs.first(where: { $0.lastDirectHost == trimmedHost })?.macID
            ?? candidateMacID
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(trimmedHost), port: nwPort)
        openConnection(to: endpoint, targetName: targetName ?? "\(trimmedHost):\(port)", preservePINState: false)
    }

    public func connectBluetooth(to host: DiscoveredBluetoothMac) {
        intentionalDisconnect = false
        consecutiveReconnectFailures = 0
        lastConnectionIssue = nil
        clearPINGlitchState()
        connectBluetoothInternal(to: host, preservePINState: false)
    }

    private func connectBluetoothInternal(to host: DiscoveredBluetoothMac, preservePINState: Bool) {
        if bluetoothBrowser == nil {
            startBluetoothBrowsing()
        }
        guard let link = bluetoothBrowser?.connect(to: host) else {
            let lang = profile.settings.language
            lastConnectionIssue = bluetoothAvailability.detailGuidance(in: lang)
                ?? L10n.tr("无法建立蓝牙连接，请确认蓝牙已开启。", "Unable to start Bluetooth connection. Check that Bluetooth is enabled.", language: lang)
            activeLink = nil
            connectionState = .disconnected
            return
        }
        let resolvedMacID: String? = {
            if let explicit = host.macID {
                return explicit
            }
            if let tag = host.macIDTag {
                return savedMacs.first(where: { ChocliftBluetooth.macIDTag(for: $0.macID) == tag })?.macID
            }
            if let byPeripheral = savedMacs.first(where: { $0.lastBluetoothPeripheralID == host.id }) {
                return byPeripheral.macID
            }
            return savedMacs.first(where: { Self.namesLikelyMatch(savedName: $0.macName, advertisedName: host.name) })?.macID
        }()
        attachBluetoothTransport(
            link,
            targetName: host.name,
            macID: resolvedMacID,
            macIDTag: host.macIDTag,
            peripheralID: host.id,
            armWatchdog: true,
            preservePINState: preservePINState
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
            macIDTag: macID.map { ChocliftBluetooth.macIDTag(for: $0) },
            peripheralID: id,
            armWatchdog: true,
            preservePINState: preservePINState
        )
        return true
    }

    public func connectInMemoryBluetooth(
        to transport: CompanionFrameTransport,
        targetName: String,
        macID: String? = nil,
        macIDTag: String? = nil,
        peripheralID: UUID? = nil
    ) {
        intentionalDisconnect = false
        consecutiveReconnectFailures = 0
        lastConnectionIssue = nil
        clearPINGlitchState()
        let resolvedMacID: String? = {
            if let macID { return macID }
            if let macIDTag {
                return savedMacs.first(where: { ChocliftBluetooth.macIDTag(for: $0.macID) == macIDTag })?.macID
            }
            if let byPeripheral = savedMacs.first(where: { $0.lastBluetoothPeripheralID != nil && $0.lastBluetoothPeripheralID == peripheralID }) {
                return byPeripheral.macID
            }
            return savedMacs.first(where: { Self.namesLikelyMatch(savedName: $0.macName, advertisedName: targetName) })?.macID
        }()
        attachBluetoothTransport(
            transport,
            targetName: targetName,
            macID: resolvedMacID,
            macIDTag: macIDTag ?? macID.map { ChocliftBluetooth.macIDTag(for: $0) },
            peripheralID: peripheralID,
            armWatchdog: false,
            preservePINState: false
        )
    }

    private func attachBluetoothTransport(
        _ transport: CompanionFrameTransport,
        targetName: String,
        macID: String?,
        macIDTag: String?,
        peripheralID: UUID?,
        armWatchdog: Bool,
        preservePINState: Bool
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
        activeBluetoothPeripheralID = peripheralID
        activeBluetoothMacIDTag = macIDTag ?? macID.map { ChocliftBluetooth.macIDTag(for: $0) }
        candidateMacID = macID
        if !preservePINState {
            connectionState = .connecting(targetName: targetName)
        }
        frameTransport = transport

        transport.onReady = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.currentSessionID == sessionID else { return }
                self.connectWatchdogTask?.cancel()
                self.connectWatchdogTask = nil
                self.isTransportReady = true
                self.lastServerActivityAt = Date()
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
            let timeout = max(0.2, connectTimeoutSeconds)
            connectWatchdogTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled, self.currentSessionID == sessionID, !self.isTransportReady else { return }
                self.handleConnectionDropped(failedLink: .bluetooth)
            }
        }

        transport.start()
    }

    private func openConnection(to endpoint: NWEndpoint, targetName: String, preservePINState: Bool) {
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

        activeEndpoint = endpoint
        activeTargetName = targetName
        activeLink = .wifi
        if !preservePINState {
            connectionState = .connecting(targetName: targetName)
        }

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
                    self.connectWatchdogTask?.cancel()
                    self.connectWatchdogTask = nil
                    self.isTransportReady = true
                    self.lastServerActivityAt = Date()
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

        let hasBluetoothFallback = matchingSavedDiscoveredBluetoothHost(preferMacID: candidateMacID) != nil
        let watchdogSeconds = hasBluetoothFallback ? min(3.5, connectTimeoutSeconds) : max(0.2, connectTimeoutSeconds)
        connectWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(watchdogSeconds))
            guard let self, !Task.isCancelled, self.currentSessionID == sessionID, !self.isTransportReady else { return }
            self.handleConnectionDropped(failedLink: .wifi)
        }

        conn.start(queue: networkQueue)
    }

    public func disconnect() {
        intentionalDisconnect = true
        currentSessionID = UUID()
        isTransportReady = false
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

        activeLink = nil
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

    private func startHeartbeat(sessionID: UUID) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = max(0.05, self?.heartbeatIntervalSeconds ?? 5.0)
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled, self.currentSessionID == sessionID, self.connectionState.isConnected else {
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
        send(.hello(
            protocolVersion: ChocliftDefaults.protocolVersion,
            deviceID: deviceID,
            deviceName: deviceName,
            platform: platform,
            savedAuthToken: lookupSavedToken()
        ))
    }

    private func ingest(_ payload: Data, sessionID: UUID) {
        guard currentSessionID == sessionID else { return }
        lastServerActivityAt = Date()
        do {
            let frames = try accumulator.appendAndExtractPayloads(payload)
            for frame in frames {
                handleServerMessage(try WireFrameCodec.decodePayload(ServerMessage.self, from: frame))
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
            connectBluetoothInternal(to: btFallback, preservePINState: false)
            return
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
        let retryTag = activeBluetoothMacIDTag

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
                self.connectBluetoothInternal(to: btHost, preservePINState: preservePINState)
                return
            }

            // 3. Test hook for simulated BLE auto-reconnect.
            if failedLink == .bluetooth,
               let simTransport = self.simulatedBluetoothReconnectProvider?() {
                self.attachBluetoothTransport(
                    simTransport,
                    targetName: retryName,
                    macID: retryMacID,
                    macIDTag: retryTag,
                    peripheralID: retryPeripheralID,
                    armWatchdog: false,
                    preservePINState: preservePINState
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
        if isTransportReady {
            pendingPINSubmission = nil
            send(.submitPIN(pin: pin, deviceID: deviceID, deviceName: deviceName, platform: platform))
        } else if pinGlitchState != nil {
            pendingPINSubmission = pin
        } else {
            send(.submitPIN(pin: pin, deviceID: deviceID, deviceName: deviceName, platform: platform))
        }
    }

    public func triggerBarItem(_ item: BarItem) {
        send(.triggerBarItem(item))
    }

    public func activateRecentApp(_ entry: RecentAppEntry) {
        send(.activateRecentApp(bundleIdentifier: entry.bundleIdentifier, appPath: entry.appPath))
    }

    public func togglePinRecentApp(_ entry: RecentAppEntry) {
        send(.setRecentAppPinned(bundleIdentifier: entry.bundleIdentifier, isPinned: !entry.isPinned))
    }

    public func quitOrHideApp(bundleIdentifier: String, shouldQuit: Bool) {
        send(.quitOrHideApp(bundleIdentifier: bundleIdentifier, shouldQuit: shouldQuit))
    }

    public func insertEmoji(_ emoji: String) {
        send(.insertEmoji(emoji))
    }

    public func performGesture(_ gesture: TouchGestureType) {
        send(.performGesture(gesture))
    }

    public func performQuickAction(_ action: SystemQuickAction) {
        send(.performQuickAction(action))
    }

    public func pushUpdatedProfile(_ updated: ChocliftWorkspaceProfile) {
        var next = updated
        next.bumpRevision()
        self.profile = next
        send(.updateProfile(next))
        requestMissingIconsIfNeeded()
    }

    public func requestMacCatalog() {
        send(.requestMacCatalog)
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
            candidateMacID = macID
            activeTargetName = macName
            if let existing = savedMacs.first(where: { $0.macID == macID }),
               !retriedTokenMacIDs.contains(macID) {
                retriedTokenMacIDs.insert(macID)
                if pinGlitchState == nil {
                    connectionState = .connecting(targetName: macName)
                }
                send(.hello(
                    protocolVersion: ChocliftDefaults.protocolVersion,
                    deviceID: deviceID,
                    deviceName: deviceName,
                    platform: platform,
                    savedAuthToken: existing.authToken
                ))
            } else {
                let preservedErr = pinGlitchState?.errorMessage
                connectionState = .awaitingPIN(macID: macID, macName: macName, errorMessage: preservedErr)
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
            clearPINGlitchState()
            consecutiveReconnectFailures = 0
            lastConnectionIssue = nil
            candidateMacID = macID
            activeTargetName = macName
            let resolvedPeripheralID = activeBluetoothPeripheralID
                ?? discoveredBluetoothMacs.first(where: {
                    $0.macID == macID ||
                    $0.macIDTag == ChocliftBluetooth.macIDTag(for: macID) ||
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
            recentApps = serverRecents
            frontmostBundleID = frontmost
            isEditingTextOnMac = editingText
            focusedMacAppName = focusedApp
            isMacAccessibilityGranted = axTrusted
            connectionState = .connected(macID: macID, macName: macName)
            startHeartbeat(sessionID: currentSessionID)
            requestMissingIconsIfNeeded()

        case .authFailed(let reason):
            if case .awaitingPIN(let macID, let macName, _) = connectionState {
                connectionState = .awaitingPIN(macID: macID, macName: macName, errorMessage: reason)
            } else {
                lastFeedback = CompanionFeedbackToast(success: false, title: "Pairing Error", detail: reason)
            }

        case .profileUpdated(let updatedProfile):
            profile = updatedProfile
            requestMissingIconsIfNeeded()

        case .recentAppsUpdated(let entries):
            recentApps = entries
            requestMissingIconsIfNeeded()

        case .frontmostAppChanged(let bundleID, _):
            frontmostBundleID = bundleID

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
            lastFeedback = CompanionFeedbackToast(success: success, title: title, detail: detail)

        case .pong:
            break
        }
    }

    private func requestMissingIconsIfNeeded() {
        guard connectionState.isConnected else { return }
        var needed = Set<String>()
        for page in profile.pages {
            for slot in page.slots {
                if let bundleID = slot?.bundleIdentifier, appIconsByBundleID[bundleID] == nil {
                    needed.insert(bundleID)
                }
            }
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
        macIDTag: String?,
        peripheralID: UUID?,
        directHost: String?,
        targetName: String
    ) -> String? {
        if let macID {
            return savedMacs.first(where: { $0.macID == macID })?.authToken
        }
        if let macIDTag {
            return savedMacs.first(where: { ChocliftBluetooth.macIDTag(for: $0.macID) == macIDTag })?.authToken
        }
        if let peripheralID,
           let cred = savedMacs.first(where: { $0.lastBluetoothPeripheralID == peripheralID }) {
            return cred.authToken
        }
        if let directHost,
           let cred = savedMacs.first(where: { $0.lastDirectHost == directHost }) {
            return cred.authToken
        }
        if let cred = savedMacs.first(where: {
            Self.namesLikelyMatch(savedName: $0.macName, advertisedName: targetName)
        }) {
            return cred.authToken
        }
        return savedMacs.first?.authToken
    }

    private func lookupSavedToken() -> String? {
        tokenForConnectAttempt(
            macID: candidateMacID,
            macIDTag: activeBluetoothMacIDTag,
            peripheralID: activeBluetoothPeripheralID,
            directHost: activeDirectHost,
            targetName: activeTargetName
        )
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
}
