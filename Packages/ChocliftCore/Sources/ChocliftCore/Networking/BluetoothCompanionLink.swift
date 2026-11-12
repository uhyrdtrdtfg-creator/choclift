#if os(macOS) || os(iOS) || os(watchOS)
import CoreBluetooth
import Foundation

public struct DiscoveredBluetoothMac: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var macID: String?

    public init(id: UUID, name: String, macID: String?) {
        self.id = id
        self.name = name
        self.macID = macID
    }
}

public enum ChocliftBluetooth {
    public static let serviceUUID = CBUUID(string: "C40C11F7-0001-4A11-9B2E-43484F434C49")
    public static let frameUUID = CBUUID(string: "C40C11F7-0002-4A11-9B2E-43484F434C49")
    public static let metadataUUID = CBUUID(string: "C40C11F7-0003-4A11-9B2E-43484F434C49")
    /// Minimum BLE 4.0 ATT payload size (`ATT_MTU 23 - 3 = 20` bytes).
    public static let minATTChunkSize = 20
    /// Conservative upper cap per GATT notification/write PDU across macOS, iOS, and watchOS.
    public static let defaultChunkSize = 180
    /// Legacy BLE 4.x connectable undirected advertising (`ADV_IND`) payload limit in bytes.
    public static let maxLegacyConnectableAdvertisingBytes = 31
    public static let macIDKey = "macID"
    public static let macNameKey = "macName"

    /// Builds the primary connectable CoreBluetooth advertising payload for `CBPeripheralManager.startAdvertising(_:)`.
    ///
    /// `CBPeripheralManager.startAdvertising(_:)` accepts a single dictionary and offers no separate scan-response
    /// parameter: placing a second UUID or `CBAdvertisementDataLocalNameKey` in this dictionary overflows the
    /// 31-byte legacy connectable `ADV_IND` budget on macOS and can silently downgrade the advertisement to
    /// non-connectable, which watchOS ignores during foreground BLE scanning.
    ///
    /// Only the single 128-bit `serviceUUID` is advertised here (`3B Flags + 18B 128-bit UUID list = 21 bytes`).
    /// macOS supplies the system GAP device name in active scan responses (`CBPeripheral.name`), and full `macID` +
    /// `macName` identity is resolved post-connection via the readable `metadataUUID` GATT characteristic.
    public static func makeConnectableAdvertisementData() -> [String: Any] {
        [
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ]
    }

    /// Calculates the over-the-air BLE legacy `ADV_IND` payload size in bytes for a `startAdvertising` dictionary:
    /// - `3` bytes for mandatory BLE Flags AD structure (`[0x02, 0x01, flags]`)
    /// - Service UUID list AD structures (`1-byte length + 1-byte AD type + N * uuidBytes`), where non-16-bit
    ///   UUIDs occupy 16 bytes each on the air in CoreBluetooth BLE advertisements
    /// - Optional Local Name (`2 + utf8.count`), Tx Power (`3`), Manufacturer Data (`2 + count`), and Service Data
    public static func connectableAdvertisementByteCount(_ advertisementData: [String: Any]) -> Int {
        var totalBytes = 3 // Mandatory BLE Flags AD structure: [Length=2, Type=0x01, Flags]

        func uuidListByteCount(_ uuids: [CBUUID]) -> Int {
            guard !uuids.isEmpty else { return 0 }
            let sixteenBitCount = uuids.filter { $0.data.count == 2 }.count
            let oneTwentyEightBitCount = uuids.count - sixteenBitCount
            var bytes = 0
            if sixteenBitCount > 0 {
                bytes += 2 + (sixteenBitCount * 2)
            }
            if oneTwentyEightBitCount > 0 {
                bytes += 2 + (oneTwentyEightBitCount * 16)
            }
            return bytes
        }

        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            totalBytes += uuidListByteCount(serviceUUIDs)
        }

        if let solicitedUUIDs = advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] {
            totalBytes += uuidListByteCount(solicitedUUIDs)
        }

        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
           !localName.isEmpty {
            totalBytes += 2 + localName.utf8.count
        }

        if advertisementData[CBAdvertisementDataTxPowerLevelKey] != nil {
            totalBytes += 3
        }

        if let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           !manufacturerData.isEmpty {
            totalBytes += 2 + manufacturerData.count
        }

        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, data) in serviceData {
                let uuidWidth = (uuid.data.count == 2) ? 2 : 16
                totalBytes += 2 + uuidWidth + data.count
            }
        }

        return totalBytes
    }

    public static func isAdvertisementConnectable(_ advertisementData: [String: Any]) -> Bool {
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
            return connectable.boolValue
        }
        return true
    }

    /// Ensures packaged `.app` / `.appex` bundles carry `NSBluetoothAlwaysUsageDescription` before touching CoreBluetooth,
    /// avoiding a TCC privacy `SIGABRT` if a bundle was ever misconfigured while allowing CLI `xctest` runners to proceed.
    public static func canInitializeCoreBluetoothSafely(in bundle: Bundle = .main) -> Bool {
        let path = bundle.bundlePath
        guard path.hasSuffix(".app") || path.hasSuffix(".appex") else {
            return true
        }
        if let desc = bundle.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String,
           !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    public static func mapAvailability(state: CBManagerState, authorization: CBManagerAuthorization) -> CompanionBluetoothAvailability {
        switch authorization {
        case .denied, .restricted:
            return .unauthorized
        default:
            break
        }
        switch state {
        case .poweredOn:
            return .ready
        case .poweredOff:
            return .poweredOff
        case .unauthorized:
            return .unauthorized
        case .unsupported:
            return .unsupported
        case .resetting:
            return .resetting
        case .unknown:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}

public struct BluetoothServiceMetadata: Codable, Equatable, Sendable {
    public static let maxGATTAttributeBytes = 512

    public var macID: String
    public var macName: String
    public var protocolVersion: Int

    public init(
        macID: String,
        macName: String,
        protocolVersion: Int = ChocliftDefaults.protocolVersion
    ) {
        self.macID = macID
        self.macName = macName
        self.protocolVersion = protocolVersion
    }

    public func encodedCharacteristicValue(maxBytes: Int = Self.maxGATTAttributeBytes) throws -> Data {
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(self)
        guard encoded.count > maxBytes, !macName.isEmpty else {
            return encoded
        }
        var trimmed = self
        var scalars = Array(macName.unicodeScalars)
        while !scalars.isEmpty {
            scalars.removeLast()
            trimmed.macName = String(String.UnicodeScalarView(scalars))
            let candidate = try encoder.encode(trimmed)
            if candidate.count <= maxBytes {
                return candidate
            }
        }
        trimmed.macName = ""
        return try encoder.encode(trimmed)
    }

    public static func decodeCharacteristicValue(_ data: Data) throws -> BluetoothServiceMetadata {
        try JSONDecoder().decode(BluetoothServiceMetadata.self, from: data)
    }
}

public protocol BluetoothMetadataAwareTransport: CompanionFrameTransport {
    var onBluetoothMetadata: ((BluetoothServiceMetadata) -> Void)? { get set }
}

/// Segments and reassembles standard Choclift length-prefixed wire frames (`[4-byte BE length][JSON]`)
/// across arbitrary BLE ATT MTU chunks and partial header writes without adding a second header.
public final class BluetoothFrameCodec {
    private var buffer = Data()

    public init() {}

    public var bufferedByteCount: Int {
        buffer.count
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    /// Appends an incoming BLE chunk and returns any complete length-prefixed wire frames (`[4-byte BE][JSON]`).
    public func append(_ chunk: Data) throws -> [Data] {
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

            if payloadLength < 0 || payloadLength > WireFrameCodec.maxFrameBytes {
                buffer.removeAll(keepingCapacity: false)
                throw WireFrameError.frameTooLarge(payloadLength)
            }

            let totalFrameBytes = 4 + payloadLength
            guard buffer.count >= totalFrameBytes else {
                break
            }

            let end = start + totalFrameBytes
            frames.append(Data(buffer[start..<end]))
            buffer.removeSubrange(start..<end)
        }

        if buffer.isEmpty {
            buffer = Data()
        }

        return frames
    }

    /// Slices an already wire-framed `Data` (`[4-byte BE length][JSON]`) into ATT-sized chunks.
    public static func chunks(
        for wireFrame: Data,
        maxChunkBytes: Int = ChocliftBluetooth.defaultChunkSize
    ) -> [Data] {
        guard !wireFrame.isEmpty else { return [] }
        let stride = max(1, maxChunkBytes)
        var chunks: [Data] = []
        var cursor = wireFrame.startIndex
        while cursor < wireFrame.endIndex {
            let end = wireFrame.index(cursor, offsetBy: stride, limitedBy: wireFrame.endIndex) ?? wireFrame.endIndex
            chunks.append(Data(wireFrame[cursor..<end]))
            cursor = end
        }
        return chunks
    }
}

/// Byte-level FIFO transmit buffer that slices outbound wire frames dynamically at send time
/// to match negotiated BLE ATT MTU limits and pauses cleanly when `updateValue` exerts backpressure.
public final class BluetoothOutboundBuffer {
    private var storage = Data()
    private var readOffset: Int = 0

    public init() {}

    public var isEmpty: Bool {
        readOffset >= storage.count
    }

    public var remainingByteCount: Int {
        max(0, storage.count - readOffset)
    }

    public func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        if isEmpty {
            storage = Data()
            readOffset = 0
        }
        storage.append(data)
    }

    public func popNextChunk(maxBytes: Int) -> Data? {
        guard !isEmpty else { return nil }
        let limit = max(1, maxBytes)
        let end = min(readOffset + limit, storage.count)
        let chunk = Data(storage[readOffset..<end])
        readOffset = end
        compactIfNeeded()
        return chunk
    }

    /// Drains chunks of at most `maxChunkBytes` while `sendChunk` returns `true`.
    /// If `sendChunk` returns `false` (notify TX queue full), the unsent chunk remains queued at the head.
    @discardableResult
    public func drain(maxChunkBytes: Int, sendChunk: (Data) -> Bool) -> Int {
        let limit = max(1, maxChunkBytes)
        var sentCount = 0
        while !isEmpty {
            let end = min(readOffset + limit, storage.count)
            let chunk = Data(storage[readOffset..<end])
            guard sendChunk(chunk) else {
                break
            }
            readOffset = end
            sentCount += 1
        }
        compactIfNeeded()
        return sentCount
    }

    public func clear() {
        storage.removeAll(keepingCapacity: false)
        readOffset = 0
    }

    private func compactIfNeeded() {
        if readOffset >= storage.count {
            storage.removeAll(keepingCapacity: false)
            readOffset = 0
        } else if readOffset >= 4096 && readOffset * 2 >= storage.count {
            storage = Data(storage[readOffset..<storage.count])
            readOffset = 0
        }
    }
}

/// Deterministic BLE transport simulator exercising `BluetoothOutboundBuffer` MTU chunking,
/// partial 1..3 byte header splits, `updateValue` notify backpressure, post-connection GATT metadata read,
/// and disconnect handling without requiring physical Bluetooth hardware in automated tests.
public final class SimulatedBLECompanionPipe: BluetoothMetadataAwareTransport {
    public var onReady: (() -> Void)?
    public var onPayload: ((Data) -> Void)?
    public var onClosed: (() -> Void)?
    public var onBluetoothMetadata: ((BluetoothServiceMetadata) -> Void)?

    public let mtu: Int
    public var maxChunksPerFlush: Int?
    public var splitFirstHeaderBytes: Int?
    /// Raw JSON characteristic value served when the peer simulates reading `ChocliftBluetooth.metadataUUID`.
    public var advertisedMetadataData: Data?

    public private(set) var totalChunksSent: Int = 0
    public private(set) var backpressurePauseCount: Int = 0

    private weak var peer: SimulatedBLECompanionPipe?
    private let outbound = BluetoothOutboundBuffer()
    private let inboundCodec = BluetoothFrameCodec()
    private var started = false
    private var closed = false
    private var didSplitFirstChunk = false

    public init(
        mtu: Int = ChocliftBluetooth.minATTChunkSize,
        maxChunksPerFlush: Int? = nil,
        splitFirstHeaderBytes: Int? = nil,
        advertisedMetadataData: Data? = nil
    ) {
        self.mtu = max(1, mtu)
        self.maxChunksPerFlush = maxChunksPerFlush
        self.splitFirstHeaderBytes = splitFirstHeaderBytes
        self.advertisedMetadataData = advertisedMetadataData
    }

    public static func pair(
        mtu: Int = ChocliftBluetooth.minATTChunkSize,
        maxServerChunksPerFlush: Int? = nil,
        maxClientChunksPerFlush: Int? = nil,
        splitFirstHeaderBytes: Int? = nil,
        serverMetadata: BluetoothServiceMetadata? = nil
    ) -> (server: SimulatedBLECompanionPipe, client: SimulatedBLECompanionPipe) {
        let server = SimulatedBLECompanionPipe(
            mtu: mtu,
            maxChunksPerFlush: maxServerChunksPerFlush,
            splitFirstHeaderBytes: splitFirstHeaderBytes,
            advertisedMetadataData: try? serverMetadata?.encodedCharacteristicValue()
        )
        let client = SimulatedBLECompanionPipe(
            mtu: mtu,
            maxChunksPerFlush: maxClientChunksPerFlush,
            splitFirstHeaderBytes: splitFirstHeaderBytes
        )
        server.peer = client
        client.peer = server
        return (server, client)
    }

    public var hasPendingOutboundBytes: Bool {
        !outbound.isEmpty
    }

    public func start() {
        guard !started, !closed else { return }
        started = true
        if let metadataData = peer?.advertisedMetadataData,
           let metadata = try? BluetoothServiceMetadata.decodeCharacteristicValue(metadataData) {
            onBluetoothMetadata?(metadata)
        }
        guard !closed else { return }
        onReady?()
        flush()
    }

    public func send(_ data: Data) {
        guard !closed else { return }
        outbound.enqueue(data)
        if started {
            flush()
        }
    }

    /// Simulates CoreBluetooth's `peripheralManagerIsReady(toUpdateSubscribers:)` callback.
    public func pumpReadyToUpdateSubscribers() {
        guard started, !closed else { return }
        flush()
    }

    public func cancel() {
        guard !closed else { return }
        closed = true
        started = false
        outbound.clear()
        inboundCodec.reset()
        let other = peer
        peer = nil
        other?.peer = nil
        onClosed?()
        if let other, !other.closed {
            other.closed = true
            other.started = false
            other.outbound.clear()
            other.inboundCodec.reset()
            other.onClosed?()
        }
    }

    private func flush() {
        guard started, !closed, let peer, !peer.closed else { return }
        var sentThisTurn = 0
        outbound.drain(maxChunkBytes: mtu) { chunk in
            if let cap = maxChunksPerFlush, sentThisTurn >= cap {
                backpressurePauseCount += 1
                return false
            }
            sentThisTurn += 1
            totalChunksSent += 1
            if let split = splitFirstHeaderBytes, !didSplitFirstChunk, split > 0, chunk.count > split {
                didSplitFirstChunk = true
                peer.receiveChunk(Data(chunk.prefix(split)))
                peer.receiveChunk(Data(chunk.dropFirst(split)))
            } else {
                peer.receiveChunk(chunk)
            }
            return true
        }
    }

    private func receiveChunk(_ chunk: Data) {
        guard !closed else { return }
        do {
            let frames = try inboundCodec.append(chunk)
            for frame in frames {
                onPayload?(frame)
            }
        } catch {
            cancel()
        }
    }
}

#if os(macOS)
@MainActor
public final class BluetoothCompanionAdvertiser: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published public private(set) var isAdvertising = false
    @Published public private(set) var availability: CompanionBluetoothAvailability = .unknown
    @Published public private(set) var lastErrorMessage: String?
    public var onAccepted: ((CompanionFrameTransport) -> Void)?
    public var onStateChanged: ((Bool, CompanionBluetoothAvailability, String?) -> Void)?

    private var manager: CBPeripheralManager?
    private var frameCharacteristic: CBMutableCharacteristic?
    private var metadataCharacteristic: CBMutableCharacteristic?
    private var wantsAdvertising = false
    private var subscribers: [UUID: BluetoothServerLink] = [:]

    public let macID: String
    public var macName: String

    public init(macID: String, macName: String) {
        self.macID = macID
        self.macName = macName
        super.init()
    }

    public func start() {
        guard ChocliftBluetooth.canInitializeCoreBluetoothSafely() else {
            updateAdvertisingState(
                false,
                availability: .unauthorized,
                error: "Missing NSBluetoothAlwaysUsageDescription in Info.plist."
            )
            return
        }
        wantsAdvertising = true
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: .main)
        } else if manager?.state == .poweredOn {
            beginAdvertising()
        }
    }

    public func stop() {
        wantsAdvertising = false
        manager?.stopAdvertising()
        manager?.removeAllServices()
        updateAdvertisingState(false, availability: availability, error: nil)
        let activeLinks = Array(subscribers.values)
        subscribers.removeAll()
        activeLinks.forEach { $0.cancel() }
    }

    private func beginAdvertising() {
        guard wantsAdvertising, let manager, manager.state == .poweredOn else { return }
        let service = CBMutableService(type: ChocliftBluetooth.serviceUUID, primary: true)
        let frame = CBMutableCharacteristic(
            type: ChocliftBluetooth.frameUUID,
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable, .readable]
        )
        let metadata = CBMutableCharacteristic(
            type: ChocliftBluetooth.metadataUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
        service.characteristics = [frame, metadata]
        frameCharacteristic = frame
        metadataCharacteristic = metadata

        manager.stopAdvertising()
        manager.removeAllServices()
        manager.add(service)
    }

    public var connectableAdvertisementData: [String: Any] {
        ChocliftBluetooth.makeConnectableAdvertisementData()
    }

    public func encodedMetadata() -> Data {
        let payload = BluetoothServiceMetadata(
            macID: macID,
            macName: macName,
            protocolVersion: ChocliftDefaults.protocolVersion
        )
        return (try? payload.encodedCharacteristicValue()) ?? Data()
    }

    private func updateAdvertisingState(
        _ advertising: Bool,
        availability nextAvailability: CompanionBluetoothAvailability,
        error: String?
    ) {
        isAdvertising = advertising
        availability = nextAvailability
        lastErrorMessage = error
        onStateChanged?(advertising, nextAvailability, error)
    }

    private nonisolated func runOnMain(_ block: @MainActor @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { block() }
        } else {
            Task { @MainActor in block() }
        }
    }

    public nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        runOnMain {
            let mapped = ChocliftBluetooth.mapAvailability(
                state: peripheral.state,
                authorization: CBPeripheralManager.authorization
            )
            if peripheral.state == .poweredOn {
                self.availability = .ready
                self.beginAdvertising()
            } else {
                let activeLinks = Array(self.subscribers.values)
                self.subscribers.removeAll()
                activeLinks.forEach { $0.cancel() }

                let err = mapped.detailGuidance()
                self.updateAdvertisingState(false, availability: mapped, error: err)
            }
        }
    }

    public nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        runOnMain {
            if let error {
                self.updateAdvertisingState(false, availability: self.availability, error: error.localizedDescription)
                return
            }
            guard self.wantsAdvertising else { return }
            peripheral.startAdvertising(self.connectableAdvertisementData)
        }
    }

    public nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        runOnMain {
            if let error {
                self.updateAdvertisingState(false, availability: self.availability, error: error.localizedDescription)
            } else {
                self.updateAdvertisingState(self.wantsAdvertising, availability: .ready, error: nil)
            }
        }
    }

    public nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        runOnMain {
            switch request.characteristic.uuid {
            case ChocliftBluetooth.metadataUUID:
                let data = self.encodedMetadata()
                guard request.offset <= data.count else {
                    peripheral.respond(to: request, withResult: .invalidOffset)
                    return
                }
                request.value = Data(data[request.offset..<data.count])
                peripheral.respond(to: request, withResult: .success)
            case ChocliftBluetooth.frameUUID:
                request.value = Data()
                peripheral.respond(to: request, withResult: .success)
            default:
                peripheral.respond(to: request, withResult: .attributeNotFound)
            }
        }
    }

    public nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        runOnMain {
            guard let first = requests.first else { return }
            guard first.characteristic.uuid == ChocliftBluetooth.frameUUID else {
                peripheral.respond(to: first, withResult: .attributeNotFound)
                return
            }

            for request in requests where request.characteristic.uuid == ChocliftBluetooth.frameUUID {
                guard let value = request.value, !value.isEmpty else { continue }
                let link = self.link(for: request.central)
                do {
                    try link.accept(value)
                } catch {
                    peripheral.respond(to: first, withResult: .unlikelyError)
                    self.removeLink(for: request.central.identifier)
                    return
                }
            }
            peripheral.respond(to: first, withResult: .success)
        }
    }

    public nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        runOnMain {
            guard characteristic.uuid == ChocliftBluetooth.frameUUID else { return }
            let link = self.link(for: central)
            link.updateCentral(central)
            link.markReady()
        }
    }

    public nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        runOnMain {
            guard characteristic.uuid == ChocliftBluetooth.frameUUID else { return }
            self.removeLink(for: central.identifier)
        }
    }

    public nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        runOnMain {
            for link in self.subscribers.values {
                link.flush()
            }
        }
    }

    private func link(for central: CBCentral) -> BluetoothServerLink {
        let centralID = central.identifier
        if let existing = subscribers[centralID], !existing.closed {
            existing.updateCentral(central)
            return existing
        }
        let link = BluetoothServerLink(
            manager: manager,
            characteristic: frameCharacteristic,
            central: central
        )
        link.onCancelled = { [weak self, weak link] in
            Task { @MainActor [weak self] in
                guard let self, let link, self.subscribers[centralID] === link else { return }
                self.subscribers.removeValue(forKey: centralID)
            }
        }
        subscribers[centralID] = link
        onAccepted?(link)
        return link
    }

    private func removeLink(for id: UUID) {
        guard let existing = subscribers.removeValue(forKey: id) else { return }
        existing.cancel()
    }
}

final class BluetoothServerLink: CompanionFrameTransport {
    var onReady: (() -> Void)?
    var onPayload: ((Data) -> Void)?
    var onClosed: (() -> Void)?
    var onCancelled: (() -> Void)?

    private weak var manager: CBPeripheralManager?
    private weak var frameCharacteristic: CBMutableCharacteristic?
    private var central: CBCentral
    private var ready = false
    private(set) var closed = false
    private let codec = BluetoothFrameCodec()
    private let outbound = BluetoothOutboundBuffer()

    init(manager: CBPeripheralManager?, characteristic: CBMutableCharacteristic?, central: CBCentral) {
        self.manager = manager
        self.frameCharacteristic = characteristic
        self.central = central
    }

    func start() {}

    func updateCentral(_ updated: CBCentral) {
        self.central = updated
    }

    func markReady() {
        guard !closed else { return }
        if !ready {
            ready = true
            onReady?()
        }
        flush()
    }

    func accept(_ chunk: Data) throws {
        guard !closed else { return }
        for wireFrame in try codec.append(chunk) {
            onPayload?(wireFrame)
        }
    }

    func send(_ data: Data) {
        guard !closed else { return }
        outbound.enqueue(data)
        flush()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        ready = false
        outbound.clear()
        codec.reset()
        onCancelled?()
        onClosed?()
    }

    func flush() {
        guard ready, !closed, let manager, let frameCharacteristic else { return }
        let maxUpdate = central.maximumUpdateValueLength
        let chunkSize = max(
            ChocliftBluetooth.minATTChunkSize,
            min(ChocliftBluetooth.defaultChunkSize, maxUpdate > 0 ? maxUpdate : ChocliftBluetooth.minATTChunkSize)
        )
        outbound.drain(maxChunkBytes: chunkSize) { chunk in
            manager.updateValue(chunk, for: frameCharacteristic, onSubscribedCentrals: [central])
        }
    }
}
#endif

@MainActor
public final class BluetoothCompanionBrowser: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published public private(set) var discovered: [DiscoveredBluetoothMac] = []
    @Published public private(set) var isPoweredOn = false
    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var availability: CompanionBluetoothAvailability = .unknown

    public var onPowerStateChanged: ((Bool) -> Void)?
    public var onAvailabilityChanged: ((CompanionBluetoothAvailability) -> Void)?
    public var onDiscoveredChanged: (([DiscoveredBluetoothMac]) -> Void)?
    public var onMetadataResolved: ((DiscoveredBluetoothMac) -> Void)?
    public var onLinkReady: ((CompanionFrameTransport, DiscoveredBluetoothMac) -> Void)?

    private var manager: CBCentralManager?
    private var wantsScanning = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var knownHosts: [UUID: DiscoveredBluetoothMac] = [:]
    private var activeLink: BluetoothClientLink?

    public override init() {
        super.init()
    }

    public func start() {
        guard ChocliftBluetooth.canInitializeCoreBluetoothSafely() else {
            availability = .unauthorized
            isPoweredOn = false
            onAvailabilityChanged?(.unauthorized)
            onPowerStateChanged?(false)
            return
        }
        wantsScanning = true
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main)
        } else if manager?.state == .poweredOn {
            beginScanning()
        }
    }

    public func stop() {
        wantsScanning = false
        manager?.stopScan()
        discovered = []
        onDiscoveredChanged?([])
    }

    public func connect(to host: DiscoveredBluetoothMac) -> CompanionFrameTransport? {
        guard ChocliftBluetooth.canInitializeCoreBluetoothSafely() else {
            availability = .unauthorized
            onAvailabilityChanged?(.unauthorized)
            return nil
        }
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main)
        }
        guard let manager else { return nil }

        let peripheral = peripherals[host.id] ?? manager.retrievePeripherals(withIdentifiers: [host.id]).first
        guard let peripheral else { return nil }

        peripherals[host.id] = peripheral
        knownHosts[host.id] = host

        if let previous = activeLink {
            activeLink = nil
            previous.cancel()
        }

        let link = BluetoothClientLink(manager: manager, peripheral: peripheral, host: host)
        peripheral.delegate = self
        activeLink = link

        switch manager.state {
        case .poweredOn:
            link.isAwaitingPowerOnConnect = false
            manager.connect(peripheral, options: nil)
        case .unknown, .resetting:
            link.isAwaitingPowerOnConnect = true
        default:
            activeLink = nil
            return nil
        }

        return link
    }

    public func retrieveAndConnect(
        peripheralID: UUID,
        fallbackName: String,
        macID: String?
    ) -> CompanionFrameTransport? {
        let host = knownHosts[peripheralID] ?? DiscoveredBluetoothMac(
            id: peripheralID,
            name: fallbackName,
            macID: macID
        )
        return connect(to: host)
    }

    private func beginScanning() {
        guard wantsScanning, let manager, manager.state == .poweredOn else { return }
        manager.scanForPeripherals(
            withServices: [ChocliftBluetooth.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func upsertDiscoveredHost(_ host: DiscoveredBluetoothMac) {
        knownHosts[host.id] = host
        if let idx = discovered.firstIndex(where: { $0.id == host.id }) {
            if discovered[idx] != host {
                discovered[idx] = host
                discovered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                onDiscoveredChanged?(discovered)
            }
        } else {
            discovered.append(host)
            discovered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            onDiscoveredChanged?(discovered)
        }
    }

    private nonisolated func runOnMain(_ block: @MainActor @escaping () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { block() }
        } else {
            Task { @MainActor in block() }
        }
    }

    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        runOnMain {
            self.bluetoothState = central.state
            self.isPoweredOn = (central.state == .poweredOn)
            let mapped = ChocliftBluetooth.mapAvailability(
                state: central.state,
                authorization: CBCentralManager.authorization
            )
            self.availability = mapped
            self.onAvailabilityChanged?(mapped)
            self.onPowerStateChanged?(self.isPoweredOn)

            if central.state == .poweredOn {
                if let link = self.activeLink, link.isAwaitingPowerOnConnect {
                    link.isAwaitingPowerOnConnect = false
                    central.connect(link.peripheral, options: nil)
                }
                if self.wantsScanning {
                    self.beginScanning()
                }
            } else {
                if !self.discovered.isEmpty {
                    self.discovered = []
                    self.onDiscoveredChanged?([])
                }
                if central.state != .unknown, let link = self.activeLink {
                    self.activeLink = nil
                    link.handleDisconnected()
                }
            }
        }
    }

    @discardableResult
    public func ingestAdvertisement(
        peripheralID: UUID,
        peripheralName: String?,
        advertisementData: [String: Any]
    ) -> DiscoveredBluetoothMac? {
        guard ChocliftBluetooth.isAdvertisementConnectable(advertisementData) else {
            return nil
        }

        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = peripheralName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = knownHosts[peripheralID]

        let resolvedName: String = {
            if let existing, existing.macID != nil, !existing.name.isEmpty {
                return existing.name
            }
            if let advName, !advName.isEmpty {
                return advName
            }
            if let fallbackName, !fallbackName.isEmpty {
                return fallbackName
            }
            return existing?.name ?? "Mac"
        }()

        let host = DiscoveredBluetoothMac(
            id: peripheralID,
            name: resolvedName,
            macID: existing?.macID
        )
        upsertDiscoveredHost(host)
        return host
    }

    @discardableResult
    public func applyMetadataCharacteristicValue(
        _ data: Data,
        for peripheralID: UUID,
        fallbackName: String
    ) -> (host: DiscoveredBluetoothMac, metadata: BluetoothServiceMetadata)? {
        guard let metadata = try? BluetoothServiceMetadata.decodeCharacteristicValue(data) else {
            return nil
        }
        let updated = DiscoveredBluetoothMac(
            id: peripheralID,
            name: metadata.macName.isEmpty ? fallbackName : metadata.macName,
            macID: metadata.macID
        )
        upsertDiscoveredHost(updated)
        onMetadataResolved?(updated)
        return (updated, metadata)
    }

    private func activateLinkIfReady(_ link: BluetoothClientLink) {
        guard activeLink === link, link.prepareActivationIfReady() else { return }
        onLinkReady?(link, link.host)
        guard activeLink === link else { return }
        link.fireReadyAndFlush()
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        runOnMain {
            guard ChocliftBluetooth.isAdvertisementConnectable(advertisementData) else {
                return
            }
            self.peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            _ = self.ingestAdvertisement(
                peripheralID: peripheral.identifier,
                peripheralName: peripheral.name,
                advertisementData: advertisementData
            )
        }
    }

    public nonisolated func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        runOnMain {
            guard let updatedName = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !updatedName.isEmpty,
                  let existing = self.knownHosts[peripheral.identifier],
                  existing.macID == nil,
                  existing.name != updatedName else {
                return
            }
            self.upsertDiscoveredHost(
                DiscoveredBluetoothMac(
                    id: peripheral.identifier,
                    name: updatedName,
                    macID: nil
                )
            )
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        runOnMain {
            guard let link = self.activeLink, link.matches(peripheral: peripheral) else { return }
            peripheral.delegate = self
            peripheral.discoverServices([ChocliftBluetooth.serviceUUID])
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        runOnMain {
            if let link = self.activeLink, link.matches(peripheral: peripheral) {
                self.activeLink = nil
                link.handleDisconnected()
            }
            if self.wantsScanning {
                self.beginScanning()
            }
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        runOnMain {
            if let link = self.activeLink, link.matches(peripheral: peripheral) {
                self.activeLink = nil
                link.handleDisconnected()
            }
            if self.wantsScanning {
                self.beginScanning()
            }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        runOnMain {
            guard let link = self.activeLink, link.matches(peripheral: peripheral) else { return }
            if error != nil {
                self.activeLink = nil
                link.failAndCancelConnection()
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == ChocliftBluetooth.serviceUUID }) else {
                self.activeLink = nil
                link.failAndCancelConnection()
                return
            }
            peripheral.discoverCharacteristics(
                [ChocliftBluetooth.frameUUID, ChocliftBluetooth.metadataUUID],
                for: service
            )
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        runOnMain {
            guard let link = self.activeLink, link.matches(peripheral: peripheral) else { return }
            if error != nil {
                self.activeLink = nil
                link.failAndCancelConnection()
                return
            }
            let characteristics = service.characteristics ?? []
            guard let frameChar = characteristics.first(where: { $0.uuid == ChocliftBluetooth.frameUUID }) else {
                self.activeLink = nil
                link.failAndCancelConnection()
                return
            }

            if let metadataChar = characteristics.first(where: { $0.uuid == ChocliftBluetooth.metadataUUID }) {
                peripheral.readValue(for: metadataChar)
            } else {
                link.markMetadataComplete(updatedHost: nil)
            }

            peripheral.setNotifyValue(true, for: frameChar)
            self.activateLinkIfReady(link)
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        runOnMain {
            guard characteristic.uuid == ChocliftBluetooth.frameUUID else { return }
            guard let link = self.activeLink, link.matches(peripheral: peripheral) else { return }
            guard error == nil, characteristic.isNotifying else {
                self.activeLink = nil
                link.failAndCancelConnection()
                return
            }

            link.markNotificationReady(characteristic)
            self.activateLinkIfReady(link)
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        runOnMain {
            guard let link = self.activeLink, link.matches(peripheral: peripheral) else { return }

            if characteristic.uuid == ChocliftBluetooth.metadataUUID {
                var resolvedHost: DiscoveredBluetoothMac?
                if error == nil,
                   let data = characteristic.value,
                   let resolved = self.applyMetadataCharacteristicValue(
                       data,
                       for: peripheral.identifier,
                       fallbackName: link.host.name
                   ) {
                    resolvedHost = resolved.host
                    link.onBluetoothMetadata?(resolved.metadata)
                }
                guard self.activeLink === link else { return }
                link.markMetadataComplete(updatedHost: resolvedHost)
                self.activateLinkIfReady(link)
                return
            }

            guard characteristic.uuid == ChocliftBluetooth.frameUUID else { return }
            if error != nil {
                self.activeLink = nil
                link.failAndCancelConnection()
                return
            }
            guard let value = characteristic.value, !value.isEmpty else { return }
            do {
                try link.accept(value)
            } catch {
                self.activeLink = nil
                link.failAndCancelConnection()
            }
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        runOnMain {
            guard characteristic.uuid == ChocliftBluetooth.frameUUID else { return }
            guard let link = self.activeLink, link.matches(peripheral: peripheral) else { return }
            if error != nil {
                self.activeLink = nil
                link.failAndCancelConnection()
                return
            }
            link.didCompleteInFlightWrite()
        }
    }
}

final class BluetoothClientLink: BluetoothMetadataAwareTransport {
    var onReady: (() -> Void)?
    var onPayload: ((Data) -> Void)?
    var onClosed: (() -> Void)?
    var onBluetoothMetadata: ((BluetoothServiceMetadata) -> Void)?

    private let manager: CBCentralManager
    let peripheral: CBPeripheral
    private(set) var host: DiscoveredBluetoothMac

    var isAwaitingPowerOnConnect = false

    private var characteristic: CBCharacteristic?
    private var pendingFrameCharacteristic: CBCharacteristic?
    private var isNotificationReady = false
    private var isMetadataComplete = false
    private var didActivate = false
    private var writeInFlight = false
    private var isClosed = false

    private let codec = BluetoothFrameCodec()
    private let outbound = BluetoothOutboundBuffer()

    init(manager: CBCentralManager, peripheral: CBPeripheral, host: DiscoveredBluetoothMac) {
        self.manager = manager
        self.peripheral = peripheral
        self.host = host
    }

    func matches(peripheral other: CBPeripheral) -> Bool {
        peripheral.identifier == other.identifier
    }

    func start() {}

    func markNotificationReady(_ frameCharacteristic: CBCharacteristic) {
        pendingFrameCharacteristic = frameCharacteristic
        isNotificationReady = true
    }

    func markMetadataComplete(updatedHost: DiscoveredBluetoothMac?) {
        if let updatedHost {
            host = updatedHost
        }
        isMetadataComplete = true
    }

    /// Transitions to active once both CCCD notification state and GATT metadata read have settled.
    func prepareActivationIfReady() -> Bool {
        guard !isClosed, !didActivate, isNotificationReady, isMetadataComplete,
              let frameCharacteristic = pendingFrameCharacteristic else {
            return false
        }
        didActivate = true
        characteristic = frameCharacteristic
        return true
    }

    func fireReadyAndFlush() {
        guard !isClosed, didActivate else { return }
        onReady?()
        flushNextWrite()
    }

    func accept(_ chunk: Data) throws {
        guard !isClosed else { return }
        for wireFrame in try codec.append(chunk) {
            onPayload?(wireFrame)
        }
    }

    func send(_ data: Data) {
        guard !isClosed else { return }
        outbound.enqueue(data)
        flushNextWrite()
    }

    func didCompleteInFlightWrite() {
        writeInFlight = false
        flushNextWrite()
    }

    func failAndCancelConnection() {
        guard !isClosed else { return }
        isClosed = true
        writeInFlight = false
        outbound.clear()
        codec.reset()
        manager.cancelPeripheralConnection(peripheral)
        onClosed?()
    }

    func handleDisconnected() {
        guard !isClosed else { return }
        isClosed = true
        writeInFlight = false
        outbound.clear()
        codec.reset()
        onClosed?()
    }

    func cancel() {
        guard !isClosed else { return }
        isClosed = true
        writeInFlight = false
        outbound.clear()
        codec.reset()
        manager.cancelPeripheralConnection(peripheral)
        onClosed?()
    }

    private func flushNextWrite() {
        guard !isClosed, !writeInFlight, let characteristic else { return }
        let rawMax = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let chunkSize = max(
            ChocliftBluetooth.minATTChunkSize,
            min(ChocliftBluetooth.defaultChunkSize, rawMax > 0 ? rawMax : ChocliftBluetooth.minATTChunkSize)
        )
        guard let chunk = outbound.popNextChunk(maxBytes: chunkSize) else { return }
        writeInFlight = true
        peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
    }
}
#endif
