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
