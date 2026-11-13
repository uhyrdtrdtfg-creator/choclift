import Foundation

// MARK: - Client -> Server Messages (iOS/iPadOS -> Mac)

public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(
        protocolVersion: Int,
        deviceID: String,
        deviceName: String,
        platform: DevicePlatform,
        savedAuthToken: String?
    )
    case submitPIN(
        pin: String,
        deviceID: String,
        deviceName: String,
        platform: DevicePlatform
    )
    case triggerBarItem(BarItem)
    case triggerFlow(flowID: UUID)
    case activateRecentApp(bundleIdentifier: String, appPath: String?)
    case setRecentAppPinned(bundleIdentifier: String, isPinned: Bool)
    case quitOrHideApp(bundleIdentifier: String, shouldQuit: Bool)
    case insertEmoji(String)
    case performGesture(TouchGestureType)
    case performQuickAction(SystemQuickAction)
    case updateProfile(ChocliftWorkspaceProfile)
    case requestMacCatalog
    case requestIcons(bundleIdentifiers: [String])
    case focusOrcaTask(dispatchID: String)
    case ping(timestamp: TimeInterval)
    case setControlLevel(kind: ControlLevelKind, level: Double)
    case setMicMuted(Bool)
    case requestControlStripState
    case undoLastWindowMove
    case unknownClientMessage
}

// MARK: - Server -> Client Messages (Mac -> iOS/iPadOS)

public enum ServerMessage: Codable, Equatable, Sendable {
    case pairingRequired(
        macID: String,
        macName: String
    )
    case authSucceeded(
        macID: String,
        macName: String,
        authToken: String,
        profile: ChocliftWorkspaceProfile,
        recentApps: [RecentAppEntry],
        frontmostBundleID: String?,
        isEditingTextOnMac: Bool,
        focusedAppName: String?,
        isAccessibilityGranted: Bool
    )
    case authFailed(reason: String)
    case profileUpdated(ChocliftWorkspaceProfile)
    case recentAppsUpdated([RecentAppEntry])
    case frontmostAppChanged(bundleIdentifier: String?, appName: String?)
    case textFieldFocusChanged(isEditingText: Bool, appName: String?)
    case accessibilityStatusChanged(isTrusted: Bool)
    case appIconsBatch([String: Data])
    case macCatalogSnapshot(
        apps: [InstalledAppSummary],
        shortcuts: [InstalledShortcutSummary]
    )
    case actionFeedback(
        success: Bool,
        title: String,
        detail: String?
    )
    case orcaStatusUpdated(OrcaTaskStatusSnapshot)
    case pong(timestamp: TimeInterval)
    case controlStripStateUpdated(ControlStripState)
    case unknownServerMessage
}

// MARK: - Length-Prefixed TCP Frame Codec

public enum WireFrameError: Error, LocalizedError, Equatable {
    case frameTooLarge(Int)
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let bytes):
            return "Wire frame exceeded maximum allowed size (\(bytes) bytes)."
        case .invalidPayload:
            return "Invalid wire frame JSON payload."
        }
    }
}

public enum WireFrameCodec {
    public static let maxFrameBytes = 32 * 1024 * 1024 // 32 MB ceiling for app icon catalog snapshots

    private static func makeEncoder() -> JSONEncoder {
        JSONEncoder()
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func encode<T: Encodable>(_ message: T) throws -> Data {
        let payload = try makeEncoder().encode(message)
        guard payload.count <= maxFrameBytes else {
            throw WireFrameError.frameTooLarge(payload.count)
        }
        var lengthBigEndian = UInt32(payload.count).bigEndian
        var framed = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: &lengthBigEndian) { rawPtr in
            framed.append(contentsOf: rawPtr)
        }
        framed.append(payload)
        return framed
    }

    public static func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            if let key = singleObjectKey(in: data) {
                if type == ClientMessage.self,
                   key != "hello",
                   key != "submitPIN",
                   let fallback = ClientMessage.unknownClientMessage as? T {
                    return fallback
                }
                if type == ServerMessage.self,
                   key != "pairingRequired",
                   key != "authSucceeded",
                   key != "authFailed",
                   let fallback = ServerMessage.unknownServerMessage as? T {
                    return fallback
                }
            }
            throw WireFrameError.invalidPayload
        }
    }

    private static func singleObjectKey(in data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj.count == 1,
              let key = obj.keys.first,
              !key.isEmpty else {
            return nil
        }
        return key
    }
}

/// Stateful streaming frame reassembler for TCP connections.
public struct WireStreamAccumulator: Sendable {
    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int {
        buffer.count
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    /// Appends incoming chunk and extracts all complete payload frames in FIFO order.
    public mutating func appendAndExtractPayloads(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let b0 = UInt32(buffer[start])
            let b1 = UInt32(buffer[start + 1])
            let b2 = UInt32(buffer[start + 2])
            let b3 = UInt32(buffer[start + 3])
            let payloadLength = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)

            if payloadLength > WireFrameCodec.maxFrameBytes {
                buffer.removeAll()
                throw WireFrameError.frameTooLarge(payloadLength)
            }

            let totalFrameLength = 4 + payloadLength
            guard buffer.count >= totalFrameLength else {
                break
            }

            let payloadStart = start + 4
            let payloadEnd = payloadStart + payloadLength
            let payload = Data(buffer[payloadStart..<payloadEnd])
            frames.append(payload)

            buffer.removeSubrange(start..<payloadEnd)
        }

        // Reset slice indices cleanly when all buffered bytes are consumed
        if buffer.isEmpty {
            buffer = Data()
        }

        return frames
    }
}
