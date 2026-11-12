import Foundation

public enum CompanionLinkKind: String, Codable, Equatable, Hashable, Sendable {
    case wifi
    case bluetooth

    public var sfSymbol: String {
        switch self {
        case .wifi: return "wifi"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        }
    }

    public func displayName(in lang: AppLanguage = .system) -> String {
        switch self {
        case .wifi:
            return L10n.tr("Wi-Fi 局域网 (TCP)", "Wi-Fi (TCP)", language: lang)
        case .bluetooth:
            return L10n.tr("蓝牙低功耗 (BLE)", "Bluetooth LE", language: lang)
        }
    }

    public func shortLabel(in lang: AppLanguage = .system) -> String {
        switch self {
        case .wifi:
            return "Wi-Fi"
        case .bluetooth:
            return L10n.tr("蓝牙", "BLE", language: lang)
        }
    }
}

public enum CompanionBluetoothAvailability: String, Codable, Equatable, Hashable, Sendable {
    case unknown
    case resetting
    case ready
    case poweredOff
    case unauthorized
    case unsupported

    public var isReady: Bool {
        self == .ready
    }

    public var isProblemState: Bool {
        switch self {
        case .poweredOff, .unauthorized:
            return true
        default:
            return false
        }
    }

    public func shortStatus(in lang: AppLanguage = .system) -> String {
        switch self {
        case .ready:
            return L10n.tr("蓝牙就绪", "Bluetooth Ready", language: lang)
        case .poweredOff:
            return L10n.tr("蓝牙已关闭", "Bluetooth Off", language: lang)
        case .unauthorized:
            return L10n.tr("蓝牙未授权", "Bluetooth Denied", language: lang)
        case .unsupported:
            return L10n.tr("无蓝牙硬件", "Bluetooth Unavailable", language: lang)
        case .resetting, .unknown:
            return L10n.tr("蓝牙初始化中", "Bluetooth Starting", language: lang)
        }
    }

    public func detailGuidance(in lang: AppLanguage = .system) -> String? {
        switch self {
        case .poweredOff:
            return L10n.tr(
                "蓝牙已关闭。请在系统设置或控制中心开启蓝牙，以便在离开同一 Wi-Fi 时连接 Mac。",
                "Bluetooth is turned off. Enable Bluetooth in Settings or Control Center to connect off Wi-Fi.",
                language: lang
            )
        case .unauthorized:
            return L10n.tr(
                "蓝牙权限被拒绝。请在「系统设置 → 隐私与安全性 → 蓝牙」中允许 choclift 访问蓝牙。",
                "Bluetooth permission was denied. Allow Bluetooth for choclift in Settings → Privacy & Security → Bluetooth.",
                language: lang
            )
        case .unsupported, .ready, .resetting, .unknown:
            return nil
        }
    }
}

public protocol CompanionFrameTransport: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onPayload: ((Data) -> Void)? { get set }
    var onClosed: (() -> Void)? { get set }
    func start()
    func send(_ data: Data)
    func cancel()
}

public final class InMemoryCompanionPipe: CompanionFrameTransport {
    public var onReady: (() -> Void)?
    public var onPayload: ((Data) -> Void)?
    public var onClosed: (() -> Void)?
    private weak var peer: InMemoryCompanionPipe?
    private var started = false

    public init() {}

    public static func pair() -> (InMemoryCompanionPipe, InMemoryCompanionPipe) {
        let left = InMemoryCompanionPipe()
        let right = InMemoryCompanionPipe()
        left.peer = right
        right.peer = left
        return (left, right)
    }

    public func start() {
        guard !started else { return }
        started = true
        onReady?()
    }

    public func send(_ data: Data) {
        peer?.onPayload?(data)
    }

    public func cancel() {
        guard started else { return }
        started = false
        let other = peer
        peer = nil
        other?.peer = nil
        onClosed?()
        other?.onClosed?()
    }
}

/// High-level HTTP/1.1 framing transport (`URLSession`) multiplexed on the Mac server's standard port.
/// Used on watchOS (and whenever `NWConnection` is blocked by watchOS NECP `.waiting(.posix(.ENETDOWN))` per TN3135)
/// so same-LAN Wi-Fi pairing, icon sync, commands, and live broadcasts work without raw low-level sockets.
public final class HTTPCompanionClientLink: CompanionFrameTransport {
    public var onReady: (() -> Void)?
    public var onPayload: ((Data) -> Void)?
    public var onClosed: (() -> Void)?

    public let host: String
    public let port: UInt16
    public let sessionToken: String
    private let requestTimeoutSeconds: TimeInterval
    private let pollTimeoutSeconds: TimeInterval
    private let urlSession: URLSession

    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var sendInFlight = false
    private var pollActive = false
    private var consecutivePollTimeouts = 0
    private var outboundPending = Data()
    private var activeSendTask: URLSessionDataTask?
    private var activePollTask: URLSessionDataTask?

    public init(
        host: String,
        port: UInt16,
        requestTimeoutSeconds: TimeInterval = 8.0,
        pollTimeoutSeconds: TimeInterval = 12.0,
        sessionToken: String = UUID().uuidString
    ) {
        self.host = host
        self.port = port
        self.sessionToken = sessionToken
        self.requestTimeoutSeconds = max(0.2, requestTimeoutSeconds)
        self.pollTimeoutSeconds = max(0.5, pollTimeoutSeconds)

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = max(2.0, self.pollTimeoutSeconds + 5.0)
        config.timeoutIntervalForResource = max(4.0, self.pollTimeoutSeconds + 10.0)
        self.urlSession = URLSession(configuration: config)
    }

    public func start() {
        lock.lock()
        guard !started, !closed else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        onReady?()

        lock.lock()
        flushNextSendLocked()
        lock.unlock()
    }

    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        outboundPending.append(data)
        if started {
            flushNextSendLocked()
        }
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        started = false
        outboundPending.removeAll(keepingCapacity: false)
        let sendTask = activeSendTask
        let pollTask = activePollTask
        activeSendTask = nil
        activePollTask = nil
        sendInFlight = false
        pollActive = false
        lock.unlock()

        sendTask?.cancel()
        pollTask?.cancel()

        if let closeURL = makeEndpointURL(path: "/choclift/v1/close") {
            var req = URLRequest(url: closeURL)
            req.httpMethod = "POST"
            req.timeoutInterval = 1.0
            req.setValue(sessionToken, forHTTPHeaderField: "X-Choclift-Session")
            req.setValue("0", forHTTPHeaderField: "Content-Length")
            let closeTask = urlSession.dataTask(with: req) { _, _, _ in }
            closeTask.resume()
        }
        urlSession.finishTasksAndInvalidate()
        onClosed?()
    }

    private func makeEndpointURL(path: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formattedHost: String
        if trimmed.contains(":") && !trimmed.hasPrefix("[") {
            formattedHost = "[\(trimmed)]"
        } else {
            formattedHost = trimmed
        }
        return URL(string: "http://\(formattedHost):\(port)\(path)")
    }

    private func flushNextSendLocked() {
        guard started, !closed, !sendInFlight, !outboundPending.isEmpty else { return }
        guard let url = makeEndpointURL(path: "/choclift/v1/session") else {
            lock.unlock()
            failAndClose()
            lock.lock()
            return
        }

        let payload = outboundPending
        outboundPending.removeAll(keepingCapacity: false)
        sendInFlight = true

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeoutSeconds
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionToken, forHTTPHeaderField: "X-Choclift-Session")
        request.httpBody = payload

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            self?.handleSendCompleted(data: data, response: response, error: error)
        }
        activeSendTask = task
        task.resume()
    }

    private func handleSendCompleted(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        activeSendTask = nil
        sendInFlight = false

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard error == nil, (200..<300).contains(statusCode) else {
            lock.unlock()
            failAndClose()
            return
        }

        let shouldStartPoll = !pollActive
        if shouldStartPoll {
            pollActive = true
        }
        lock.unlock()

        if let data, !data.isEmpty {
            onPayload?(data)
        }

        lock.lock()
        if !closed {
            if shouldStartPoll {
                startNextPollLocked()
            }
            flushNextSendLocked()
        }
        lock.unlock()
    }

    private func startNextPollLocked() {
        guard started, !closed, pollActive else { return }
        guard let url = makeEndpointURL(path: "/choclift/v1/poll") else {
            pollActive = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(requestTimeoutSeconds, pollTimeoutSeconds + 4.0)
        request.setValue(sessionToken, forHTTPHeaderField: "X-Choclift-Session")
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let task = urlSession.dataTask(with: request) { [weak self] data, response, error in
            self?.handlePollCompleted(data: data, response: response, error: error)
        }
        activePollTask = task
        task.resume()
    }

    private func handlePollCompleted(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        activePollTask = nil

        if let urlError = error as? URLError, urlError.code == .cancelled {
            lock.unlock()
            return
        }

        if let urlError = error as? URLError, urlError.code == .timedOut {
            consecutivePollTimeouts += 1
            if consecutivePollTimeouts <= 1 {
                startNextPollLocked()
                lock.unlock()
                return
            }
            lock.unlock()
            failAndClose()
            return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard error == nil, statusCode == 200 || statusCode == 204 else {
            lock.unlock()
            failAndClose()
            return
        }

        consecutivePollTimeouts = 0
        lock.unlock()

        if let data, !data.isEmpty {
            onPayload?(data)
        }

        lock.lock()
        if !closed && pollActive {
            startNextPollLocked()
        }
        lock.unlock()
    }

    private func failAndClose() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        started = false
        outboundPending.removeAll(keepingCapacity: false)
        let sendTask = activeSendTask
        let pollTask = activePollTask
        activeSendTask = nil
        activePollTask = nil
        sendInFlight = false
        pollActive = false
        lock.unlock()

        sendTask?.cancel()
        pollTask?.cancel()
        urlSession.invalidateAndCancel()
        onClosed?()
    }
}
