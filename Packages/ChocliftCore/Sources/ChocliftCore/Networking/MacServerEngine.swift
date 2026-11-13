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

    /// Application-level idle timeout for authenticated Bluetooth sessions so a companion that disappears
    /// without sending a GATT unsubscribe is evicted cleanly on the Mac.
    public var bluetoothSessionTimeoutSeconds: TimeInterval = 16.0
    /// Extended idle window while a Bluetooth companion is on `.awaitingPIN` so reading the 6-digit code
    /// on the Mac and tapping it on Apple Watch does not prematurely evict the unauthenticated session.
    public var bluetoothPairingTimeoutSeconds: TimeInterval = 180.0
    /// Application-level idle timeout for HTTP-framed Wi-Fi sessions (used on watchOS per TN3135).
    public var httpSessionTimeoutSeconds: TimeInterval = 35.0
    public var httpPollHoldSeconds: TimeInterval = 10.0
    public var heartbeatSweepIntervalSeconds: TimeInterval = 2.0

    private var listener: NWListener?
    private let networkQueue = DispatchQueue(label: "com.choclift.server.network", qos: .userInteractive)
    private var sessions: [UUID: ClientSessionContext] = [:]
    private var httpSessionsByToken: [String: UUID] = [:]
    private var activeHTTPConnections: [UUID: NWConnection] = [:]
    private var didFallbackToRandomPort = false
    private let bluetoothAdvertiser: BluetoothCompanionAdvertiser
    private var heartbeatMonitorTask: Task<Void, Never>?

    private final class ClientSessionContext {
        let id: UUID
        let link: CompanionLinkKind
        var sendFrame: (Data) -> Void
        var cancelTransport: () -> Void = {}
        var usesStream: Bool = false
        var hasClassifiedStreamProtocol: Bool = false
        var stream: NWConnection?
        var isHTTPSession: Bool = false
        var httpSessionToken: String?
        var isCapturingDirectHTTPReply: Bool = false
        var directHTTPReplyBuffer = Data()
        var asyncHTTPOutboundBuffer = Data()
        var pendingHTTPPollResponder: ((Int, Data) -> Void)?
        var pendingHTTPPollTimeoutTask: Task<Void, Never>?
        var accumulator = WireStreamAccumulator()
        var deviceID: String?
        var deviceName: String?
        var platform: DevicePlatform = .iPhone
        var isAuthenticated = false
        var supportsControlStrip = false
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
                newListener.service = makeBonjourService(port: port == 0 ? nil : port)
            }

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                        self.listeningPort = newListener.port?.rawValue
                        self.lastErrorMessage = nil
                        if advertiseBonjour, let boundPort = newListener.port?.rawValue {
                            newListener.service = self.makeBonjourService(port: boundPort)
                        }
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

    private func makeBonjourService(port: UInt16?) -> NWListener.Service {
        var txtRecord = NWTXTRecord()
        txtRecord["macID"] = macID
        txtRecord["macName"] = macName
        txtRecord["ver"] = "\(ChocliftDefaults.protocolVersion)"
        if let primaryIP = localIPAddresses.first, !primaryIP.isEmpty {
            txtRecord["ip"] = primaryIP
        }
        if let port, port > 0 {
            txtRecord["port"] = "\(port)"
        }
        return NWListener.Service(
            name: macName,
            type: ChocliftDefaults.bonjourServiceType,
            txtRecord: txtRecord
        )
    }

    public func stop() {
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil
        listener?.cancel()
        listener = nil
        bluetoothAdvertiser.stop()
        isListening = false
        listeningPort = nil
        for (_, httpConn) in activeHTTPConnections {
            httpConn.cancel()
        }
        activeHTTPConnections.removeAll()
        httpSessionsByToken.removeAll()
        for (_, session) in sessions {
            session.pendingHTTPPollTimeoutTask?.cancel()
            session.pendingHTTPPollTimeoutTask = nil
            session.pendingHTTPPollResponder = nil
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
        let authBLETimeout = max(0.05, bluetoothSessionTimeoutSeconds)
        let pairingBLETimeout = max(0.05, bluetoothPairingTimeoutSeconds)
        let httpTimeout = max(0.2, httpSessionTimeoutSeconds)
        var staleIDs: [UUID] = []
        for (id, session) in sessions {
            if session.link == .bluetooth {
                let allowedIdle = session.isAuthenticated ? authBLETimeout : pairingBLETimeout
                if now.timeIntervalSince(session.lastActivityAt) > allowedIdle {
                    staleIDs.append(id)
                }
            } else if session.isHTTPSession {
                let allowedIdle = session.isAuthenticated ? httpTimeout : max(httpTimeout, pairingBLETimeout)
                if now.timeIntervalSince(session.lastActivityAt) > allowedIdle {
                    staleIDs.append(id)
                }
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

    public func broadcastControlStripState(_ state: ControlStripState, excludingDeviceID: String? = nil) {
        for session in sessions.values where session.isAuthenticated && session.supportsControlStrip {
            if let excludingDeviceID, session.deviceID == excludingDeviceID {
                continue
            }
            send(.controlStripStateUpdated(state), to: session)
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
        if link == .bluetooth,
           let blePipe = transport as? SimulatedBLECompanionPipe,
           blePipe.advertisedMetadataData == nil {
            blePipe.advertisedMetadataData = try? BluetoothServiceMetadata(
                macID: macID,
                macName: macName,
                protocolVersion: ChocliftDefaults.protocolVersion
            ).encodedCharacteristicValue()
        }
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
        if let token = removed.httpSessionToken, httpSessionsByToken[token] == sessionID {
            httpSessionsByToken.removeValue(forKey: token)
        }
        removed.pendingHTTPPollTimeoutTask?.cancel()
        removed.pendingHTTPPollTimeoutTask = nil
        if let pollResponder = removed.pendingHTTPPollResponder {
            removed.pendingHTTPPollResponder = nil
            pollResponder(410, Data())
        }
        removed.cancelTransport()
        syncConnectedFlags()
    }

    private func receiveNextChunk(sessionID: UUID) {
        guard let session = sessions[sessionID], session.usesStream, let connection = session.stream else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, let activeSession = self.sessions[sessionID] else { return }

                if let data, !data.isEmpty {
                    if !activeSession.hasClassifiedStreamProtocol {
                        let firstByte = data.first ?? 0
                        // Raw Choclift wire frames always begin with a 4-byte BE length <= 16 MB (first byte 0x00..0x01).
                        // HTTP requests begin with ASCII 'P' (POST), 'G' (GET), or 'O' (OPTIONS).
                        if firstByte == 0x50 || firstByte == 0x47 || firstByte == 0x4F {
                            activeSession.usesStream = false
                            activeSession.stream = nil
                            activeSession.cancelTransport = {}
                            self.sessions.removeValue(forKey: sessionID)
                            self.startHTTPConnectionLoop(connection, initialBuffer: data)
                            return
                        }
                        activeSession.hasClassifiedStreamProtocol = true
                    }
                    self.ingest(data, sessionID: sessionID)
                }

                if isComplete || error != nil {
                    self.cleanupSession(sessionID: sessionID)
                } else if activeSession.usesStream, self.sessions[sessionID] != nil {
                    self.receiveNextChunk(sessionID: sessionID)
                }
            }
        }
    }

    // MARK: - HTTP/1.1 Session Multiplexing on Same Listener Port (watchOS TN3135 Wi-Fi Path)

    private struct ParsedHTTPRequest {
        let method: String
        let path: String
        let sessionToken: String?
        let keepAlive: Bool
        let body: Data
        let consumedBytes: Int
    }

    private static func tryParseHTTPRequest(from buffer: Data) -> Result<ParsedHTTPRequest?, WireFrameError> {
        let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let headerEndRange = buffer.range(of: delimiter) else {
            if buffer.count > 65_536 {
                return .failure(.frameTooLarge(buffer.count))
            }
            return .success(nil)
        }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerEndRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .failure(.frameTooLarge(headerData.count))
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(.frameTooLarge(0))
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .failure(.frameTooLarge(0))
        }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawTarget

        var contentLength = 0
        var sessionToken: String?
        var keepAlive = true

        for headerLine in lines.dropFirst() {
            guard let colon = headerLine.firstIndex(of: ":") else { continue }
            let name = headerLine[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = headerLine[headerLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-length":
                contentLength = Int(value) ?? 0
            case "x-choclift-session":
                sessionToken = value
            case "connection":
                if value.lowercased().contains("close") {
                    keepAlive = false
                }
            default:
                break
            }
        }

        if contentLength < 0 || contentLength > WireFrameCodec.maxFrameBytes + 4096 {
            return .failure(.frameTooLarge(contentLength))
        }

        let bodyStart = headerEndRange.upperBound
        let totalNeeded = (bodyStart - buffer.startIndex) + contentLength
        guard buffer.count >= totalNeeded else {
            return .success(nil)
        }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        return .success(
            ParsedHTTPRequest(
                method: method,
                path: path,
                sessionToken: sessionToken,
                keepAlive: keepAlive,
                body: body,
                consumedBytes: totalNeeded
            )
        )
    }

    private func startHTTPConnectionLoop(_ connection: NWConnection, initialBuffer: Data) {
        let connID = UUID()
        activeHTTPConnections[connID] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    self.activeHTTPConnections.removeValue(forKey: connID)
                default:
                    break
                }
            }
        }
        processHTTPBuffer(initialBuffer, on: connection, connID: connID)
    }

    private func readMoreHTTPBytes(into existing: Data, on connection: NWConnection, connID: UUID) {
        guard activeHTTPConnections[connID] != nil else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.activeHTTPConnections[connID] != nil else { return }
                var combined = existing
                if let chunk, !chunk.isEmpty {
                    combined.append(chunk)
                }
                if !combined.isEmpty {
                    self.processHTTPBuffer(combined, on: connection, connID: connID)
                    return
                }
                if isComplete || error != nil {
                    self.activeHTTPConnections.removeValue(forKey: connID)
                    connection.cancel()
                }
            }
        }
    }

    private func processHTTPBuffer(_ buffer: Data, on connection: NWConnection, connID: UUID) {
        switch Self.tryParseHTTPRequest(from: buffer) {
        case .failure:
            sendHTTPResponse(status: 400, body: Data(), keepAlive: false, on: connection, connID: connID) { _ in }
        case .success(nil):
            readMoreHTTPBytes(into: buffer, on: connection, connID: connID)
        case .success(.some(let req)):
            let remaining = Data(buffer.dropFirst(req.consumedBytes))
            handleHTTPRequest(req, on: connection, connID: connID) { [weak self] shouldContinue in
                guard let self, shouldContinue, self.activeHTTPConnections[connID] != nil else { return }
                if !remaining.isEmpty {
                    self.processHTTPBuffer(remaining, on: connection, connID: connID)
                } else {
                    self.readMoreHTTPBytes(into: Data(), on: connection, connID: connID)
                }
            }
        }
    }

    private func handleHTTPRequest(
        _ req: ParsedHTTPRequest,
        on connection: NWConnection,
        connID: UUID,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard req.method == "POST" || req.method == "GET" else {
            sendHTTPResponse(status: 405, body: Data(), keepAlive: false, on: connection, connID: connID, completion: completion)
            return
        }
        guard let token = req.sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            sendHTTPResponse(status: 400, body: Data(), keepAlive: false, on: connection, connID: connID, completion: completion)
            return
        }

        switch req.path {
        case "/choclift/v1/close":
            if let sessionID = httpSessionsByToken[token] {
                cleanupSession(sessionID: sessionID)
            }
            sendHTTPResponse(status: 200, body: Data(), keepAlive: req.keepAlive, on: connection, connID: connID, completion: completion)

        case "/choclift/v1/session":
            let session = resolveOrCreateHTTPSession(token: token)
            session.lastActivityAt = Date()
            session.isCapturingDirectHTTPReply = true
            session.directHTTPReplyBuffer.removeAll(keepingCapacity: false)

            if !req.body.isEmpty {
                ingest(req.body, sessionID: session.id)
            }

            var replyPayload = session.directHTTPReplyBuffer
            session.directHTTPReplyBuffer.removeAll(keepingCapacity: false)
            session.isCapturingDirectHTTPReply = false

            if sessions[session.id] != nil, session.pendingHTTPPollResponder == nil, !session.asyncHTTPOutboundBuffer.isEmpty {
                replyPayload.append(session.asyncHTTPOutboundBuffer)
                session.asyncHTTPOutboundBuffer.removeAll(keepingCapacity: false)
            }

            sendHTTPResponse(status: 200, body: replyPayload, keepAlive: req.keepAlive, on: connection, connID: connID, completion: completion)

        case "/choclift/v1/poll":
            guard let sessionID = httpSessionsByToken[token], let session = sessions[sessionID] else {
                sendHTTPResponse(status: 410, body: Data(), keepAlive: false, on: connection, connID: connID, completion: completion)
                return
            }
            session.lastActivityAt = Date()

            session.pendingHTTPPollTimeoutTask?.cancel()
            session.pendingHTTPPollTimeoutTask = nil
            if let superseded = session.pendingHTTPPollResponder {
                session.pendingHTTPPollResponder = nil
                superseded(204, Data())
            }

            if !session.asyncHTTPOutboundBuffer.isEmpty {
                let queued = session.asyncHTTPOutboundBuffer
                session.asyncHTTPOutboundBuffer.removeAll(keepingCapacity: false)
                sendHTTPResponse(status: 200, body: queued, keepAlive: req.keepAlive, on: connection, connID: connID, completion: completion)
                return
            }

            let holdSeconds = max(0.1, httpPollHoldSeconds)
            session.pendingHTTPPollResponder = { [weak self] status, payload in
                guard let self else { return }
                self.sendHTTPResponse(status: status, body: payload, keepAlive: req.keepAlive, on: connection, connID: connID, completion: completion)
            }
            session.pendingHTTPPollTimeoutTask = Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(for: .seconds(holdSeconds))
                guard let self, !Task.isCancelled, let session, self.sessions[session.id] != nil else { return }
                guard let responder = session.pendingHTTPPollResponder else { return }
                session.pendingHTTPPollResponder = nil
                session.pendingHTTPPollTimeoutTask = nil
                responder(204, Data())
            }

        default:
            sendHTTPResponse(status: 404, body: Data(), keepAlive: false, on: connection, connID: connID, completion: completion)
        }
    }

    private func resolveOrCreateHTTPSession(token: String) -> ClientSessionContext {
        if let existingID = httpSessionsByToken[token], let existing = sessions[existingID] {
            return existing
        }
        let context = ClientSessionContext(link: .wifi) { _ in }
        context.isHTTPSession = true
        context.httpSessionToken = token
        context.sendFrame = { [weak context] frameData in
            guard let context, !frameData.isEmpty else { return }
            if context.isCapturingDirectHTTPReply {
                context.directHTTPReplyBuffer.append(frameData)
            } else if let pollResponder = context.pendingHTTPPollResponder {
                context.pendingHTTPPollResponder = nil
                context.pendingHTTPPollTimeoutTask?.cancel()
                context.pendingHTTPPollTimeoutTask = nil
                context.asyncHTTPOutboundBuffer.append(frameData)
                let drained = context.asyncHTTPOutboundBuffer
                context.asyncHTTPOutboundBuffer.removeAll(keepingCapacity: false)
                pollResponder(200, drained)
            } else {
                context.asyncHTTPOutboundBuffer.append(frameData)
            }
        }
        sessions[context.id] = context
        httpSessionsByToken[token] = context.id
        ensureHeartbeatMonitorRunning()
        return context
    }

    private func sendHTTPResponse(
        status: Int,
        body: Data,
        keepAlive: Bool,
        on connection: NWConnection,
        connID: UUID,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let reason: String = {
            switch status {
            case 200: return "OK"
            case 204: return "No Content"
            case 400: return "Bad Request"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 410: return "Gone"
            default: return "Error"
            }
        }()
        let connHeader = keepAlive ? "keep-alive" : "close"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: \(connHeader)\r\n\r\n"
        var wire = Data(header.utf8)
        if status != 204 && !body.isEmpty {
            wire.append(body)
        }
        connection.send(content: wire, completion: .contentProcessed { [weak self] sendError in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if sendError != nil || !keepAlive {
                    self.activeHTTPConnections.removeValue(forKey: connID)
                    connection.cancel()
                    completion(false)
                } else {
                    completion(true)
                }
            }
        })
    }

    private func ingest(_ data: Data, sessionID: UUID) {
        guard let activeSession = sessions[sessionID] else { return }
        activeSession.lastActivityAt = Date()
        do {
            let payloads = try activeSession.accumulator.appendAndExtractPayloads(data)
            for payload in payloads {
                do {
                    let clientMsg = try WireFrameCodec.decodePayload(ClientMessage.self, from: payload)
                    handleIncomingMessage(clientMsg, session: activeSession)
                } catch {
                    if activeSession.isAuthenticated {
                        send(
                            .actionFeedback(
                                success: false,
                                title: L10n.tr("不支持的指令", "Unsupported Command"),
                                detail: L10n.tr("当前 Mac 端版本无法识别该指令。", "This Mac version does not recognize that command.")
                            ),
                            to: activeSession
                        )
                    } else {
                        send(.authFailed(reason: error.localizedDescription), to: activeSession)
                        cleanupSession(sessionID: sessionID)
                        return
                    }
                }
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

        case .unknownClientMessage:
            break

        default:
            guard session.isAuthenticated,
                  let deviceID = session.deviceID,
                  let record = pairedDevices.first(where: { $0.deviceID == deviceID }) else {
                send(.pairingRequired(macID: macID, macName: macName), to: session)
                return
            }

            switch message {
            case .requestControlStripState, .setControlLevel, .setMicMuted:
                session.supportsControlStrip = true
            default:
                break
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
        var referencedBundles = profile.referencedAppBundleIdentifiers
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
