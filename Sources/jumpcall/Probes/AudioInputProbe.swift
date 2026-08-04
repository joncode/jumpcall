import CoreAudio
import Foundation

struct AudioProcessInfo: Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

/// CoreAudio "process objects" (macOS 14+): metadata about which processes
/// currently run live audio IO. Reading it triggers no TCC prompt — it is
/// not audio capture. `isRunningInput` == "this app has the mic open right
/// now", which is our generic in-a-call signal for Teams/Webex/FaceTime.
///
/// Property *listeners* on these objects are known-flaky, so callers poll.
enum AudioInputProbe {
    static func list() -> [AudioProcessInfo] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        var objectIDs = [AudioObjectID](
            repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.stride)
        let status = objectIDs.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return objectIDs.compactMap(info(for:))
    }

    static func processesUsingMicrophone() -> [AudioProcessInfo] {
        list().filter(\.isRunningInput)
    }

    private static func info(for objectID: AudioObjectID) -> AudioProcessInfo? {
        guard let pid: pid_t = scalar(objectID, kAudioProcessPropertyPID) else { return nil }
        let input: UInt32 = scalar(objectID, kAudioProcessPropertyIsRunningInput) ?? 0
        let output: UInt32 = scalar(objectID, kAudioProcessPropertyIsRunningOutput) ?? 0
        return AudioProcessInfo(
            objectID: objectID,
            pid: pid,
            bundleID: string(objectID, kAudioProcessPropertyBundleID) ?? "",
            isRunningInput: input != 0,
            isRunningOutput: output != 0)
    }

    private static func scalar<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr) == noErr else {
            return nil
        }
        return ptr.pointee
    }

    private static func string(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { p in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, p)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
