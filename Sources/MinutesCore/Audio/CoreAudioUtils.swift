import AudioToolbox
import CoreAudio
import Foundation

/// Thin helpers over the Core Audio HAL property API.
enum CoreAudioUtils {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result)
        return status == noErr ? result : nil
    }

    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, element: T) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.size
        var items = [T](repeating: element, count: count)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &items) == noErr else { return [] }
        return items
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static var defaultOutputDevice: AudioObjectID? {
        property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
    }

    static var defaultInputDevice: AudioObjectID? {
        property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0))
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        getString(device, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioObjectID) -> String? {
        getString(device, kAudioObjectPropertyName)
    }

    /// Asks for larger IO buffers for this process on `device` (clamped to the device's range), so its IOProc wakes
    /// up less often. Returns the size in effect.
    @discardableResult
    static func setBufferFrames(_ device: AudioObjectID, _ frames: UInt32) -> UInt32? {
        var range = AudioValueRange()
        var addr = address(kAudioDevicePropertyBufferFrameSizeRange)
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &range) == noErr else { return nil }
        var value = UInt32(min(max(Double(frames), range.mMinimum), range.mMaximum))
        addr = address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return property(device, kAudioDevicePropertyBufferFrameSize, default: UInt32(0))
    }

    /// True when the default output is the Mac's own speakers or a display's speakers, so the microphone hears
    /// what the Mac plays. Headphones on the built-in jack, USB and Bluetooth devices count as headphones.
    static var outputIsSpeaker: Bool {
        guard let device = defaultOutputDevice, device != 0 else { return false }
        let transport = property(device, kAudioDevicePropertyTransportType, default: UInt32(0)) ?? 0
        if transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort { return true }
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        var addr = address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &source) == noErr else { return true }
        return source != 0x6864_706E  // 'hdpn': headphones plugged into the jack
    }

    static func isBluetooth(_ device: AudioObjectID) -> Bool {
        let transport = property(device, kAudioDevicePropertyTransportType, default: UInt32(0)) ?? 0
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The Mac's own microphone, if it has one.
    static var builtInInputDevice: AudioObjectID? {
        getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, element: AudioObjectID(0))
            .first { device in
                guard property(device, kAudioDevicePropertyTransportType, default: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
                else { return false }
                var addr = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
                var size: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
                let list = AudioBufferList.allocate(maximumBuffers: Int(size) / MemoryLayout<AudioBuffer>.size + 1)
                defer { list.unsafeMutablePointer.deallocate() }
                guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, list.unsafeMutablePointer) == noErr else { return false }
                return list.contains { $0.mNumberChannels > 0 }
            }
    }

    /// Translates a PID to the HAL process object (macOS 14.2+). Returns nil if the process has no audio presence.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// All processes the HAL knows about (macOS 14.2+).
    static var processObjects: [AudioObjectID] {
        getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, element: AudioObjectID(0))
    }

    static func processPID(_ object: AudioObjectID) -> pid_t? {
        property(object, kAudioProcessPropertyPID, default: pid_t(0))
    }

    static func processBundleID(_ object: AudioObjectID) -> String? {
        getString(object, kAudioProcessPropertyBundleID)
    }

    static func processIsRunningInput(_ object: AudioObjectID) -> Bool {
        (property(object, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) ?? 0) != 0
    }

    static func processIsRunningOutput(_ object: AudioObjectID) -> Bool {
        (property(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) ?? 0) != 0
    }

    /// Registers a listener block on a system-object property. Returns a token to remove it.
    @discardableResult
    static func addSystemListener(
        _ selector: AudioObjectPropertySelector, queue: DispatchQueue, block: @escaping () -> Void
    ) -> AudioObjectPropertyListenerBlock {
        var addr = address(selector)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in block() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        return listener
    }

    static func removeSystemListener(
        _ selector: AudioObjectPropertySelector, queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var addr = address(selector)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
    }
}

/// Converts host time ticks to seconds.
enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static var now: UInt64 { mach_absolute_time() }
}

public enum AudioRoute {
    /// The Mac plays through speakers the microphone can hear. With Data Protection on this matters: without system
    /// audio there is no echo check, so the other side of a call would be transcribed from the microphone.
    public static var playsThroughSpeakers: Bool { CoreAudioUtils.outputIsSpeaker }
}
