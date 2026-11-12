#if os(macOS)
import Foundation
import Network

@MainActor
public protocol MacServerEngineDelegate: AnyObject {
    func serverCurrentProfile() -> ChocliftWorkspaceProfile
    func serverCurrentRecentApps() -> [RecentAppEntry]
    func serverFrontmostBundleID() -> String?
    func serverTextInputState() -> (isEditing: Bool, appName: String?)
    func serverIsAccessibilityGranted() -> Bool
    func serverIcons(for bundleIDs: [String]) -> [String: Data]
    func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord])
    func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    )
}

@MainActor
public final class MacServerEngine: ObservableObject {
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var isBluetoothAdvertising: Bool = false
    @Published public private(set) var bluetoothAvailability: CompanionBluetoothAvailability = .unknown
    @Published public private(set) var listeningPort: UInt16?
    @Published public private(set) var currentPIN: String
    @Published public private(set) var pairedDevices: [PairedDeviceRecord]
    @Published public private(set) var localIPAddresses: [String] = []
    @Published public private(set) var lastErrorMessage: String?

    public let macID: String
    public var macName: String
    public weak var delegate: MacServerEngineDelegate?

    /// Application-level idle timeout for Bluetooth sessions so a companion that disappears
    /// without sending a GATT unsubscribe is evicted cleanly on the Mac.
    public var bluetoothSessionTimeoutSeconds: TimeInterval = 16.0
    public var heartbeatSweepIntervalSeconds: TimeInterval = 2.0

    private var listener: NWListener?
    private let networkQueue = DispatchQueue(label: "com.choclift.server.network", qos: .userInteractive)
    private var sessions: [UUID: ClientSessionContext] = [:]
    private var didFallbackToRandomPort = false
    private let bluetoothAdvertiser: BluetoothCompanionAdvertiser
    private var heartbeatMonitorTask: Task<Void, Never>?

    private final class ClientSessionContext {
        let id: UUID
        let link: CompanionLinkKind
        let sendFrame: (Data) -> Void
        var cancelTransport: () -> Void = {}
        var usesStream: Bool = false
        var stream: NWConnection?
        var accumulator = WireStreamAccumulator()
        var deviceID: String?
        var deviceName: String?
        var platform: DevicePlatform = .iPhone
        var isAuthenticated = false
        var sentIconBundleIDs: Set<String> = []
        var lastActivityAt = Date()

        init(id: UUID = UUID(), link: CompanionLinkKind, sendFrame: @escaping (Data) -> Void) {
            self.id = id
            self.link = link
            self.sendFrame = sendFrame
        }
    }

    public init(
        macID: String,
        macName: String,
        initialPairedDevices: [PairedDeviceRecord] = []
    ) {
        self.macID = macID
        self.macName = macName
        self.currentPIN = Self.generateSixDigitPIN()
        self.pairedDevices = initialPairedDevices.map { record in
            var copy = record
            copy.isCurrentlyConnected = false
            copy.activeLink = nil
            return copy
        }
        self.bluetoothAdvertiser = BluetoothCompanionAdvertiser(macID: macID, macName: macName)
        refreshLocalIPAddresses()
        bluetoothAdvertiser.onAccepted = { [weak self] transport in
            self?.acceptCompanionTransport(transport, link: .bluetooth)
        }
        bluetoothAdvertiser.onStateChanged = { [weak self] advertising, availability, _ in
            self?.isBluetoothAdvertising = advertising
            self?.bluetoothAvailability = availability
        }
    }

    public func acceptInMemoryCompanion() -> CompanionFrameTransport {
        let (serverEnd, clientEnd) = InMemoryCompanionPipe.pair()
        acceptCompanionTransport(serverEnd, link: .bluetooth)
        return clientEnd
    }

    public var connectedDeviceCount: Int {
        sessions.values.filter(\.isAuthenticated).count
    }

    public func regeneratePIN() {
        currentPIN = Self.generateSixDigitPIN()
    }

    public func removePairedDevice(deviceID: String) {
        pairedDevices.removeAll { $0.deviceID == deviceID }
        for (sessionID, session) in sessions where session.deviceID == deviceID {
            session.cancelTransport()
            sessions.removeValue(forKey: sessionID)
        }
        delegate?.serverDidUpdatePairedDevices(pairedDevices)
    }

    public func start(
        preferredPort: UInt16 = ChocliftDefaults.defaultTCPPort,
        advertiseBonjour: Bool = true,
        advertiseBluetooth: Bool = true
    ) {
        stop()
        didFallbackToRandomPort = false
        refreshLocalIPAddresses()
        startListener(port: preferredPort, advertiseBonjour: advertiseBonjour)
        if advertiseBluetooth {
            bluetoothAdvertiser.macName = macName
            bluetoothAdvertiser.start()
        }
        ensureHeartbeatMonitorRunning()
    }

    private func startListener(port: UInt16, advertiseBonjour: Bool) {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
                tcpOptions.enableKeepalive = true
                tcpOptions.keepaliveIdle = 15
            }

            let nwPort: NWEndpoint.Port = (port == 0) ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
            let newListener = try NWListener(using: params, on: nwPort)

            if advertiseBonjour {
                var txtRecord = NWTXTRecord()
                txtRecord["macID"] = macID
                txtRecord["macName"] = macName
                txtRecord["ver"] = "\(ChocliftDefaults.protocolVersion)"
                newListener.service = NWListener.Service(
                    name: macName,
                    type: ChocliftDefaults.bonjourServiceType,
                    txtRecord: txtRecord
                )
            }

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.listeningPort = newListener.port?.rawValue
                        self.lastErrorMessage = nil
                    case .failed(let error):
                        self.isListening = false
                        newListener.cancel()
                        if !self.didFallbackToRandomPort && port != 0 {
                            self.didFallbackToRandomPort = true
                            self.startListener(port: 0, advertiseBonjour: advertiseBonjour)
                        } else {
                            self.lastErrorMessage = error.localizedDescription
                        }
                    case .cancelled:
                        self.isListening = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.acceptConnection(connection)
                }
            }

            self.listener = newListener
            newListener.start(queue: networkQueue)
        } catch {
            if !didFallbackToRandomPort && port != 0 {
                didFallbackToRandomPort = true
                startListener(port: 0, advertiseBonjour: advertiseBonjour)
            } else {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    public func stop() {
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil
        listener?.cancel()
        listener = nil
        bluetoothAdvertiser.stop()
        isListening = false
        listeningPort = nil
        for (_, session) in sessions {
            session.cancelTransport()
        }
        sessions.removeAll()
        syncConnectedFlags()
    }

    private func ensureHeartbeatMonitorRunning() {
        guard heartbeatMonitorTask == nil else { return }
        heartbeatMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval = max(0.02, self?.heartbeatSweepIntervalSeconds ?? 2.0)
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { break }
                self.sweepExpiredBluetoothSessions()
            }
        }
    }

    private func sweepExpiredBluetoothSessions() {
        let now = Date()
        let timeout = max(0.05, bluetoothSessionTimeoutSeconds)
        var staleIDs: [UUID] = []
        for (id, session) in sessions where session.link == .bluetooth {
            if now.timeIntervalSince(session.lastActivityAt) > timeout {
                staleIDs.append(id)
            }
        }
        for id in staleIDs {
            cleanupSession(sessionID: id)
        }
    }

    // MARK: - Broadcasting to Connected Companion Devices

    public func broadcast(_ message: ServerMessage, excludingDeviceID: String? = nil) {
        for session in sessions.values where session.isAuthenticated {
            if let excludingDeviceID, session.deviceID == excludingDeviceID {
                continue
            }
            send(message, to: session)
        }
    }

    public func pushMissingIconsToAllSessions(bundleIDs: Set<String>) {
        guard !bundleIDs.isEmpty, let delegate else { return }
        for session in sessions.values where session.isAuthenticated {
            let missing = bundleIDs.subtracting(session.sentIconBundleIDs)
            guard !missing.isEmpty else { continue }
            let fetched = delegate.serverIcons(for: Array(missing))
            if !fetched.isEmpty {
                session.sentIconBundleIDs.formUnion(fetched.keys)
                sendIconsBatch(fetched, to: session)
            }
        }
    }

    // MARK: - Connection Lifecycle

    private func acceptConnection(_ connection: NWConnection) {
        let context = ClientSessionContext(link: .wifi) { data in
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
        context.cancelTransport = { connection.cancel() }
        context.usesStream = true
        context.stream = connection
        sessions[context.id] = context
        let sessionID = context.id

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receiveNextChunk(sessionID: sessionID)
                case .failed, .cancelled:
                    self.cleanupSession(sessionID: sessionID)
                default:
                    break
                }
            }
        }

        connection.start(queue: networkQueue)
    }

    public func acceptCompanionTransport(_ transport: CompanionFrameTransport, link: CompanionLinkKind) {
        let context = ClientSessionContext(link: link) { data in
            transport.send(data)
        }
        context.cancelTransport = { transport.cancel() }
        sessions[context.id] = context
        let sessionID = context.id
        transport.onPayload = { [weak self] payload in
            Task { @MainActor in self?.ingest(payload, sessionID: sessionID) }
        }
        transport.onClosed = { [weak self] in
            Task { @MainActor in self?.cleanupSession(sessionID: sessionID) }
        }
        transport.onReady = { [weak self] in
            Task { @MainActor in
                guard self?.sessions[sessionID] != nil else { return }
            }
        }
        if link == .bluetooth {
            ensureHeartbeatMonitorRunning()
        }
        transport.start()
    }

    private func cleanupSession(sessionID: UUID) {
        guard let removed = sessions.removeValue(forKey: sessionID) else { return }
        removed.cancelTransport()
        syncConnectedFlags()
    }

    private func receiveNextChunk(sessionID: UUID) {
        guard let session = sessions[sessionID], session.usesStream, let connection = session.stream else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, let activeSession = self.sessions[sessionID] else { return }

                if let data, !data.isEmpty {
                    self.ingest(data, sessionID: sessionID)
                }

                if isComplete || error != nil {
                    self.cleanupSession(sessionID: sessionID)
                } else if activeSession.usesStream {
                    self.receiveNextChunk(sessionID: sessionID)
                }
            }
        }
    }

    private func ingest(_ data: Data, sessionID: UUID) {
        guard let activeSession = sessions[sessionID] else { return }
        activeSession.lastActivityAt = Date()
        do {
            let payloads = try activeSession.accumulator.appendAndExtractPayloads(data)
            for payload in payloads {
                let clientMsg = try WireFrameCodec.decodePayload(ClientMessage.self, from: payload)
                handleIncomingMessage(clientMsg, session: activeSession)
            }
        } catch {
            send(.authFailed(reason: error.localizedDescription), to: activeSession)
            cleanupSession(sessionID: sessionID)
        }
    }

    private func handleIncomingMessage(_ message: ClientMessage, session: ClientSessionContext) {
        switch message {
        case .hello(_, let deviceID, let deviceName, let platform, let savedAuthToken):
            session.deviceID = deviceID
            session.deviceName = deviceName
            session.platform = platform

            if let savedAuthToken,
               let index = pairedDevices.firstIndex(where: { $0.deviceID == deviceID && $0.authToken == savedAuthToken }) {
                pairedDevices[index].deviceName = deviceName
                pairedDevices[index].platform = platform
                pairedDevices[index].lastSeenAt = Date()
                completeAuthentication(for: session, record: pairedDevices[index])
            } else {
                send(.pairingRequired(macID: macID, macName: macName), to: session)
            }

        case .submitPIN(let pin, let deviceID, let deviceName, let platform):
            session.deviceID = deviceID
            session.deviceName = deviceName
            session.platform = platform

            let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == currentPIN else {
                send(.authFailed(reason: L10n.tr("配对码不正确，请核对 Mac 端显示的 6 位数字。", "Incorrect PIN code. Please check the 6-digit code shown on your Mac.")), to: session)
                return
            }

            let newToken = UUID().uuidString + "-" + UUID().uuidString
            let record = PairedDeviceRecord(
                deviceID: deviceID,
                deviceName: deviceName,
                platform: platform,
                authToken: newToken,
                pairedAt: Date(),
                lastSeenAt: Date(),
                isCurrentlyConnected: true,
                activeLink: session.link
            )

            if let existingIdx = pairedDevices.firstIndex(where: { $0.deviceID == deviceID }) {
                pairedDevices[existingIdx] = record
            } else {
                pairedDevices.append(record)
            }

            completeAuthentication(for: session, record: record)

        case .ping(let timestamp):
            send(.pong(timestamp: timestamp), to: session)

        default:
            guard session.isAuthenticated,
                  let deviceID = session.deviceID,
                  let record = pairedDevices.first(where: { $0.deviceID == deviceID }) else {
                send(.pairingRequired(macID: macID, macName: macName), to: session)
                return
            }

            if case .requestIcons(let bundleIdentifiers) = message {
                if let delegate {
                    let icons = delegate.serverIcons(for: bundleIdentifiers)
                    if !icons.isEmpty {
                        session.sentIconBundleIDs.formUnion(icons.keys)
                        sendIconsBatch(icons, to: session)
                    }
                }
                return
            }

            delegate?.serverDidReceiveAuthenticatedMessage(message, from: record) { [weak self, weak session] replyMsg in
                guard let self, let session else { return }
                self.send(replyMsg, to: session)
            }
        }
    }

    private func completeAuthentication(for session: ClientSessionContext, record: PairedDeviceRecord) {
        // Disconnect any stale duplicate socket from the exact same deviceID
        for (otherID, otherSession) in sessions where otherID != session.id && otherSession.deviceID == record.deviceID {
            otherSession.cancelTransport()
            sessions.removeValue(forKey: otherID)
        }

        session.isAuthenticated = true
        syncConnectedFlags()
        delegate?.serverDidUpdatePairedDevices(pairedDevices)

        guard let delegate else { return }
        let profile = delegate.serverCurrentProfile()
        let recentApps = delegate.serverCurrentRecentApps()
        let frontmost = delegate.serverFrontmostBundleID()
        let textState = delegate.serverTextInputState()
        let axTrusted = delegate.serverIsAccessibilityGranted()

        send(
            .authSucceeded(
                macID: macID,
                macName: macName,
                authToken: record.authToken,
                profile: profile,
                recentApps: recentApps,
                frontmostBundleID: frontmost,
                isEditingTextOnMac: textState.isEditing,
                focusedAppName: textState.appName,
                isAccessibilityGranted: axTrusted
            ),
            to: session
        )

        // Immediately stream app icons referenced by profile + recentApps
        var referencedBundles = Set<String>()
        for page in profile.pages {
            for slot in page.slots {
                if let bundleID = slot?.bundleIdentifier {
                    referencedBundles.insert(bundleID)
                }
            }
        }
        for recent in recentApps {
            referencedBundles.insert(recent.bundleIdentifier)
        }

        let icons = delegate.serverIcons(for: Array(referencedBundles))
        if !icons.isEmpty {
            session.sentIconBundleIDs.formUnion(icons.keys)
            sendIconsBatch(icons, to: session)
        }
    }

    private func sendIconsBatch(_ icons: [String: Data], to session: ClientSessionContext) {
        guard !icons.isEmpty else { return }
        if session.link == .bluetooth {
            for bundleID in icons.keys.sorted() {
                if let png = icons[bundleID] {
                    send(.appIconsBatch([bundleID: png]), to: session)
                }
            }
        } else {
            send(.appIconsBatch(icons), to: session)
        }
    }

    private func send(_ message: ServerMessage, to session: ClientSessionContext) {
        do {
            session.sendFrame(try WireFrameCodec.encode(message))
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func syncConnectedFlags() {
        var changed = false
        for idx in pairedDevices.indices {
            let targetDeviceID = pairedDevices[idx].deviceID
            let matchingSessions = sessions.values.filter {
                $0.isAuthenticated && $0.deviceID == targetDeviceID
            }
            let isConn = !matchingSessions.isEmpty
            let resolvedLink: CompanionLinkKind? = isConn
                ? (matchingSessions.first(where: { $0.link == .wifi })?.link ?? matchingSessions.first?.link)
                : nil
            if pairedDevices[idx].isCurrentlyConnected != isConn || pairedDevices[idx].activeLink != resolvedLink {
                pairedDevices[idx].isCurrentlyConnected = isConn
                pairedDevices[idx].activeLink = resolvedLink
                if isConn {
                    pairedDevices[idx].lastSeenAt = Date()
                }
                changed = true
            }
        }
        if changed {
            delegate?.serverDidUpdatePairedDevices(pairedDevices)
        }
    }

    // MARK: - Network Helpers

    public func refreshLocalIPAddresses() {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            localIPAddresses = []
            return
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let ip = String(cString: hostname)
                        if !ip.hasPrefix("127.") && !addresses.contains(ip) {
                            addresses.append(ip)
                        }
                    }
                }
            }
            ptr = interface.ifa_next
        }
        localIPAddresses = addresses
    }

    public static func generateSixDigitPIN() -> String {
        let value = Int.random(in: 100_000...999_999)
        return String(value)
    }
}
#endif
