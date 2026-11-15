import AppKit
import ChocliftCore
import CoreFoundation
import CoreGraphics
import Darwin
import Foundation

/// Switches Spaces with the Dock swipe WindowServer still accepts.
/// Synthetic Control+Arrow is ignored on macOS 27.
enum MacSpaceSwipe {
    enum Direction {
        case previous
        case next
    }

    static func switchSpace(_ direction: Direction) -> (success: Bool, message: String) {
        let sign = swipeSign(for: direction)
        let began = post(phase: .began, sign: sign, includeVelocity: false)
        let changed = post(phase: .changed, sign: sign, includeVelocity: false)
        let ended = post(phase: .ended, sign: sign, includeVelocity: true)
        guard began, changed, ended else {
            return (
                false,
                L10n.tr("桌面空间切换失败", "Could not switch Spaces")
            )
        }
        let title = direction == .previous
            ? L10n.tr("已切到上一个桌面空间", "Switched to the previous Space")
            : L10n.tr("已切到下一个桌面空间", "Switched to the next Space")
        return (true, title)
    }

    private enum Phase: Int64 {
        case began = 1
        case changed = 2
        case ended = 4
    }

    private static let eventTypeField = CGEventField(rawValue: 55)!
    private static let hidTypeField = CGEventField(rawValue: 110)!
    private static let motionField = CGEventField(rawValue: 123)!
    private static let progressField = CGEventField(rawValue: 124)!
    private static let positionXField = CGEventField(rawValue: 125)!
    private static let velocityXField = CGEventField(rawValue: 129)!
    private static let phaseField = CGEventField(rawValue: 132)!
    private static let phaseAliasField = CGEventField(rawValue: 134)!
    private static let zoomDeltaField = CGEventField(rawValue: 138)!
    private static let sourcePIDAliasField = CGEventField(rawValue: 169)!
    private static let dockControlType: Int64 = 30
    private static let companionGestureType: Int64 = 29
    private static let dockSwipeHIDType: Int64 = 23
    private static let horizontalMotion: Int64 = 1
    private static let flingVelocity = 9999.0

    private static func swipeSign(for direction: Direction) -> Double {
        let towardNextIsNegative = true
        let natural = naturalScrollingEnabled()
        let base: Double = direction == .next ? (towardNextIsNegative ? -1 : 1) : (towardNextIsNegative ? 1 : -1)
        return natural ? base : -base
    }

    private static func naturalScrollingEnabled() -> Bool {
        let key = "com.apple.swipescrolldirection" as CFString
        var valid = DarwinBoolean(false)
        let natural = CFPreferencesGetAppBooleanValue(key, kCFPreferencesAnyApplication, &valid)
        if !valid.boolValue { return true }
        return natural
    }

    private static func post(phase: Phase, sign: Double, includeVelocity: Bool) -> Bool {
        guard let event = CGEvent(source: nil) else { return false }
        event.setIntegerValueField(eventTypeField, value: dockControlType)
        event.setIntegerValueField(hidTypeField, value: dockSwipeHIDType)
        event.setIntegerValueField(phaseField, value: phase.rawValue)
        event.setIntegerValueField(motionField, value: horizontalMotion)
        event.setDoubleValueField(progressField, value: sign * 0.000016)
        event.setIntegerValueField(phaseAliasField, value: phase.rawValue)
        event.setDoubleValueField(zoomDeltaField, value: 3)
        event.setDoubleValueField(sourcePIDAliasField, value: Double(mach_absolute_time()))
        event.setDoubleValueField(positionXField, value: 0.1)
        if includeVelocity {
            event.setDoubleValueField(velocityXField, value: sign * flingVelocity)
        }
        let posted = augmentedIfNeeded(event)
        guard let companion = CGEvent(source: nil) else { return false }
        companion.setIntegerValueField(eventTypeField, value: companionGestureType)
        posted.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
        return true
    }

    private static func augmentedIfNeeded(_ event: CGEvent) -> CGEvent {
        guard requiresAugmentation() else { return event }
        return MacSpaceSwipePayload.augment(event) ?? event
    }

    private static func requiresAugmentation() -> Bool {
        var version = [CChar](repeating: 0, count: 32)
        var size = version.count
        guard sysctlbyname("kern.osproductversion", &version, &size, nil, 0) == 0 else { return false }
        let text = String(cString: version)
        let major = Int(text.split(separator: ".").first ?? "") ?? 0
        return major >= 27
    }
}

enum MacSpaceSwipePayload {
    static func augment(_ event: CGEvent) -> CGEvent? {
        guard let data = event.data else { return nil }
        let bytes = [UInt8](data as Data)
        guard bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 2 else { return nil }
        guard let payload = iohidPayload(for: event) else { return nil }
        var combined = bytes
        let payloadCount = payload.count
        combined.append(UInt8((payloadCount >> 8) & 0xFF))
        combined.append(UInt8(payloadCount & 0xFF))
        combined.append(UInt8((4205 >> 8) & 0xFF))
        combined.append(UInt8(4205 & 0xFF))
        combined.append(contentsOf: payload)
        let cfData = combined.withUnsafeBytes { raw -> CFData in
            CFDataCreate(kCFAllocatorDefault, raw.bindMemory(to: UInt8.self).baseAddress, combined.count)
        }
        return CGEvent(withDataAllocator: kCFAllocatorDefault, data: cfData)
    }

    private static func iohidPayload(for event: CGEvent) -> [UInt8]? {
        let phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
        let motion = event.getIntegerValueField(CGEventField(rawValue: 123)!)
        let progress = event.getDoubleValueField(CGEventField(rawValue: 124)!)
        let posX = event.getDoubleValueField(CGEventField(rawValue: 125)!)
        let posY = event.getDoubleValueField(CGEventField(rawValue: 126)!)
        let velX = event.getDoubleValueField(CGEventField(rawValue: 129)!)
        let velY = event.getDoubleValueField(CGEventField(rawValue: 130)!)
        let swipeMask = event.getIntegerValueField(CGEventField(rawValue: 115)!)
        let includeVelocity = velX != 0 || velY != 0 || phase == 4
        let fluidSize = 40
        let velocitySize = 28
        let headerSize = 28
        var length = headerSize + fluidSize
        if includeVelocity { length += velocitySize }
        var bytes = [UInt8](repeating: 0, count: length)
        var timestamp = event.timestamp
        if timestamp == 0 { timestamp = mach_absolute_time() }
        write(timestamp, into: &bytes, at: 0)
        write(UInt32(includeVelocity ? 2 : 1), into: &bytes, at: 24)
        write(UInt32(fluidSize), into: &bytes, at: headerSize)
        write(UInt32(23), into: &bytes, at: headerSize + 4)
        write(UInt32((phase & 0xFF) << 24), into: &bytes, at: headerSize + 8)
        write(fixed1616(posX), into: &bytes, at: headerSize + 16)
        write(fixed1616(posY), into: &bytes, at: headerSize + 20)
        write(UInt32(truncatingIfNeeded: swipeMask), into: &bytes, at: headerSize + 28)
        write(UInt16(truncatingIfNeeded: motion), into: &bytes, at: headerSize + 32)
        write(UInt16(3), into: &bytes, at: headerSize + 34)
        write(fixed1616(progress), into: &bytes, at: headerSize + 36)
        if includeVelocity {
            let offset = headerSize + fluidSize
            write(UInt32(velocitySize), into: &bytes, at: offset)
            write(UInt32(9), into: &bytes, at: offset + 4)
            write(fixed1616(velX), into: &bytes, at: offset + 16)
            write(fixed1616(velY), into: &bytes, at: offset + 20)
        }
        return bytes
    }

    private static func fixed1616(_ value: Double) -> Int32 {
        let fixed = Int32(value * 65536)
        if fixed == 0, value != 0 { return value > 0 ? 1 : -1 }
        return fixed
    }

    private static func write(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        var native = value.littleEndian
        withUnsafeBytes(of: &native) { raw in
            for index in 0..<8 { bytes[offset + index] = raw[index] }
        }
    }

    private static func write(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        var native = value.littleEndian
        withUnsafeBytes(of: &native) { raw in
            for index in 0..<4 { bytes[offset + index] = raw[index] }
        }
    }

    private static func write(_ value: Int32, into bytes: inout [UInt8], at offset: Int) {
        write(UInt32(bitPattern: value), into: &bytes, at: offset)
    }

    private static func write(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        var native = value.littleEndian
        withUnsafeBytes(of: &native) { raw in
            for index in 0..<2 { bytes[offset + index] = raw[index] }
        }
    }
}
