import CoreAudio
import Foundation

/// Tells whether other apps are using the microphone, through Core Audio. Nothing is
/// recorded; only the state of the audio system is read.
public enum MicrophoneActivity {
    /// Bundle identifiers of the processes other than this one that are recording audio, or
    /// `nil` when macOS cannot tell (older systems). Helper processes report their own
    /// identifiers, such as "com.google.Chrome.helper".
    public static func inputProcessBundleIDs(excluding pid: pid_t = getpid()) -> [String]? {
        guard
            let processes: [AudioObjectID] = arrayProperty(
                kAudioHardwarePropertyProcessObjectList, of: AudioObjectID(kAudioObjectSystemObject)
            )
        else { return nil }
        var result: [String] = []
        for process in processes {
            guard
                let running: UInt32 = scalarProperty(
                    kAudioProcessPropertyIsRunningInput, of: process),
                running != 0
            else { continue }
            let processID: pid_t? = scalarProperty(kAudioProcessPropertyPID, of: process)
            guard processID != pid else { continue }
            if let bundleID = stringProperty(kAudioProcessPropertyBundleID, of: process),
                !bundleID.isEmpty
            {
                result.append(bundleID)
            }
        }
        return result
    }

    /// Whether the default input device is running in any process, this one included.
    public static var isDefaultInputRunning: Bool {
        guard
            let device: AudioObjectID = scalarProperty(
                kAudioHardwarePropertyDefaultInputDevice,
                of: AudioObjectID(kAudioObjectSystemObject)),
            device != kAudioObjectUnknown,
            let running: UInt32 = scalarProperty(
                kAudioDevicePropertyDeviceIsRunningSomewhere, of: device)
        else { return false }
        return running != 0
    }

    // MARK: - Core Audio properties

    private static func address(
        _ selector: AudioObjectPropertySelector
    )
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func scalarProperty<T>(
        _ selector: AudioObjectPropertySelector, of object: AudioObjectID
    ) -> T? {
        var address = address(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr,
            size == UInt32(MemoryLayout<T>.size)
        else { return nil }
        return pointer.load(as: T.self)
    }

    private static func arrayProperty(
        _ selector: AudioObjectPropertySelector, of object: AudioObjectID
    ) -> [AudioObjectID]? {
        var address = address(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else {
            return nil
        }
        var items = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !items.isEmpty else { return [] }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &items) == noErr else {
            return nil
        }
        return Array(items.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector, of object: AudioObjectID
    ) -> String? {
        var address = address(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
