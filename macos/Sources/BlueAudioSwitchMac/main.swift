import Foundation
import CoreAudio
import IOKit
import IOKit.hid

private let appVersion = "0.1.0-macos"

private func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
    return formatter.string(from: Date())
}

private func log(_ message: String) {
    print("\(timestamp()) \(message)")
    fflush(stdout)
}

private struct AudioDeviceInfo: Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let isAlive: Bool

    var isBuiltIn: Bool {
        transport == kAudioDeviceTransportTypeBuiltIn
    }

    var isHS5: Bool {
        let lowered = name.lowercased()
        return lowered.contains("dp-hs-1015") || lowered.contains("dark project hs5")
    }

    var isEligibleExternal: Bool {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeAirPlay,
             kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeFireWire:
            return true
        default:
            return false
        }
    }

    var transportName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        default: return String(format: "0x%08X", transport)
        }
    }
}

private final class CoreAudioManager {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func outputDevices() -> [AudioDeviceInfo] {
        allDeviceIDs().compactMap { id in
            guard hasOutputStreams(id), isAlive(id) else { return nil }
            let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? "device-\(id)"
            let name = stringProperty(id, selector: kAudioObjectPropertyName) ?? "Audio Device \(id)"
            let transport = uint32Property(id, selector: kAudioDevicePropertyTransportType) ?? kAudioDeviceTransportTypeUnknown
            return AudioDeviceInfo(id: id, uid: uid, name: name, transport: transport, isAlive: true)
        }
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    @discardableResult
    func setDefaultOutputDevice(_ id: AudioDeviceID) -> Bool {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value = id
            let size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectSetPropertyData(systemObject, &address, 0, nil, size, &value)
            if status != noErr {
                log("CoreAudio: failed to set default output selector \(selector), OSStatus=\(status)")
                return false
            }
        }
        return true
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return status == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private func isAlive(_ id: AudioDeviceID) -> Bool {
        (uint32Property(id, selector: kAudioDevicePropertyDeviceIsAlive) ?? 1) != 0
    }

    private func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value as String
    }

    private func uint32Property(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }
}

private final class HS5HIDMonitor {
    private let manager: IOHIDManager
    private let onStateChanged: (Bool) -> Void
    private var started = false

    init(onStateChanged: @escaping (Bool) -> Void) {
        self.onStateChanged = onStateChanged
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func start() {
        guard !started else { return }
        started = true

        let match: [CFString: Any] = [
            kIOHIDVendorIDKey as CFString: NSNumber(value: 0x10D6),
            kIOHIDProductIDKey as CFString: NSNumber(value: 0xB011)
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, _, _, reportID, report, reportLength in
            guard result == kIOReturnSuccess,
                  let context,
                  reportLength > 0 else { return }

            let monitor = Unmanaged<HS5HIDMonitor>.fromOpaque(context).takeUnretainedValue()
            let bytes = UnsafeBufferPointer(start: UnsafePointer(report), count: reportLength)

            // Some HID stacks include the report ID in the buffer, others expose it separately.
            if reportLength >= 3, bytes[0] == 0x55, bytes[1] == 0x6B {
                if bytes[2] == 0x00 { monitor.onStateChanged(true) }
                if bytes[2] == 0x01 { monitor.onStateChanged(false) }
                return
            }

            if reportID == 0x55, reportLength >= 2, bytes[0] == 0x6B {
                if bytes[1] == 0x00 { monitor.onStateChanged(true) }
                if bytes[1] == 0x01 { monitor.onStateChanged(false) }
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            log("HS5: HID monitor active for VID_10D6&PID_B011")
        } else {
            log("HS5: could not open HID monitor, IOReturn=\(result)")
        }
    }

    deinit {
        if started {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
}

private final class AudioSwitchController {
    private let audio = CoreAudioManager()
    private var hidMonitor: HS5HIDMonitor?

    private var previousAvailableUIDs = Set<String>()
    private var connectionOrder: [String: UInt64] = [:]
    private var sequence: UInt64 = 0
    private var lastDefaultUID: String?
    private var lastProgrammaticUID: String?

    private var hs5StateKnown = false
    private var hs5Connected = false

    init() {
        let devices = audio.outputDevices()
        previousAvailableUIDs = Set(devices.map(\.uid))

        if let defaultID = audio.defaultOutputDeviceID(),
           let current = devices.first(where: { $0.id == defaultID }) {
            sequence = 1
            connectionOrder[current.uid] = sequence
            lastDefaultUID = current.uid
            log("Startup default: \(current.name) [\(current.transportName)]")
        }
    }

    func start() {
        hidMonitor = HS5HIDMonitor { [weak self] connected in
            self?.handleHS5State(connected)
        }
        hidMonitor?.start()

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func listDevices() {
        let devices = audio.outputDevices()
        let defaultID = audio.defaultOutputDeviceID()
        for device in devices {
            let marker = device.id == defaultID ? "*" : " "
            print("\(marker) \(device.name) | \(device.transportName) | uid=\(device.uid)")
        }
    }

    private func tick() {
        let devices = audio.outputDevices()
        let byUID = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })
        let availableUIDs = Set(devices.map(\.uid))
        let removedUIDs = previousAvailableUIDs.subtracting(availableUIDs)
        let previousDefaultDisappeared = lastDefaultUID.map { removedUIDs.contains($0) } ?? false

        // A CoreAudio endpoint appearing is the best public signal for a normal
        // Bluetooth/AirPlay/USB output becoming available on macOS.
        let addedUIDs = availableUIDs.subtracting(previousAvailableUIDs)
        var newestAddedExternal: AudioDeviceInfo?
        for uid in addedUIDs {
            guard let device = byUID[uid], device.isEligibleExternal else { continue }
            if device.isHS5 && hs5StateKnown && !hs5Connected { continue }
            markConnected(device)
            newestAddedExternal = device
        }

        let defaultDevice = audio.defaultOutputDeviceID().flatMap { id in devices.first(where: { $0.id == id }) }

        // When Core Audio auto-falls back because a device vanished, do not treat
        // that automatic change as a manual user selection. We still want our
        // remembered last-connected external priority to decide the fallback.
        if !previousDefaultDisappeared,
           let defaultDevice,
           defaultDevice.uid != lastDefaultUID {
            if defaultDevice.uid != lastProgrammaticUID {
                markConnected(defaultDevice)
                log("Default changed outside BlueAudioSwitch: \(defaultDevice.name)")
            }
            lastDefaultUID = defaultDevice.uid
            lastProgrammaticUID = nil
        }

        if let newestAddedExternal {
            switchTo(newestAddedExternal, reason: "became available")
        } else if previousDefaultDisappeared {
            selectFallback(from: devices, reason: "previous output disappeared")
        } else {
            let currentIsLogicallyAvailable: Bool
            if let defaultDevice {
                currentIsLogicallyAvailable = logicalAvailability(of: defaultDevice)
            } else {
                currentIsLogicallyAvailable = false
            }

            if !currentIsLogicallyAvailable {
                selectFallback(from: devices, reason: "current output is unavailable")
            }
        }

        previousAvailableUIDs = availableUIDs
    }

    private func handleHS5State(_ connected: Bool) {
        if hs5StateKnown && hs5Connected == connected { return }
        hs5StateKnown = true
        hs5Connected = connected

        let devices = audio.outputDevices()
        guard let hs5 = devices.first(where: { $0.isHS5 }) else {
            log("HS5: link changed to \(connected ? "connected" : "disconnected"), but no DP-HS-1015 CoreAudio output is visible")
            return
        }

        if connected {
            log("HS5 connected (HID 55-6B-00)")
            markConnected(hs5)
            switchTo(hs5, reason: "HS5 radio link connected")
        } else {
            log("HS5 disconnected (HID 55-6B-01)")
            if audio.defaultOutputDeviceID() == hs5.id {
                selectFallback(from: devices, reason: "HS5 radio link disconnected")
            }
        }
    }

    private func logicalAvailability(of device: AudioDeviceInfo) -> Bool {
        guard device.isAlive else { return false }
        if device.isHS5, hs5StateKnown {
            return hs5Connected
        }
        return true
    }

    private func markConnected(_ device: AudioDeviceInfo) {
        sequence &+= 1
        connectionOrder[device.uid] = sequence
        log("Available: \(device.name) [\(device.transportName)] order=\(sequence)")
    }

    private func switchTo(_ device: AudioDeviceInfo, reason: String) {
        guard logicalAvailability(of: device) else { return }
        if audio.defaultOutputDeviceID() == device.id {
            lastDefaultUID = device.uid
            return
        }
        if audio.setDefaultOutputDevice(device.id) {
            lastProgrammaticUID = device.uid
            lastDefaultUID = device.uid
            log("Selected: \(device.name) [\(device.transportName)] — \(reason)")
        }
    }

    private func selectFallback(from devices: [AudioDeviceInfo], reason: String) {
        let externals = devices
            .filter { $0.isEligibleExternal && logicalAvailability(of: $0) }
            .sorted { (connectionOrder[$0.uid] ?? 0) > (connectionOrder[$1.uid] ?? 0) }

        if let bestExternal = externals.first {
            switchTo(bestExternal, reason: reason)
            return
        }

        if let builtIn = devices.first(where: { $0.isBuiltIn && logicalAvailability(of: $0) }) {
            switchTo(builtIn, reason: "\(reason); no external output remains")
            return
        }

        log("No suitable fallback output found")
    }
}

private let args = Set(CommandLine.arguments.dropFirst())

if args.contains("--version") {
    print("BlueAudioSwitch macOS \(appVersion)")
    exit(0)
}

private let controller = AudioSwitchController()

if args.contains("--list") {
    controller.listDevices()
    exit(0)
}

log("BlueAudioSwitch macOS \(appVersion) started")
controller.start()
RunLoop.main.run()
