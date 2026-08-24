import CoreAudio
import Darwin
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
        guard #available(macOS 14, *),
              let processListSelector = selector(named: "kAudioHardwarePropertyProcessObjectList"),
              let processPropertyPIDSelector = selector(named: "kAudioProcessPropertyPID"),
              let processPropertyIsRunningInputSelector = selector(named: "kAudioProcessPropertyIsRunningInput"),
              let processPropertyIsRunningOutputSelector = selector(named: "kAudioProcessPropertyIsRunningOutput"),
              let processPropertyBundleIDSelector = selector(named: "kAudioProcessPropertyBundleID")
        else {
            return []
        }

        return listForMacOS14(processListSelector: processListSelector,
                              processPropertyPIDSelector: processPropertyPIDSelector,
                              processPropertyIsRunningInputSelector: processPropertyIsRunningInputSelector,
                              processPropertyIsRunningOutputSelector: processPropertyIsRunningOutputSelector,
                              processPropertyBundleIDSelector: processPropertyBundleIDSelector)
    }

    static func processesUsingMicrophone() -> [AudioProcessInfo] {
        list().filter(\.isRunningInput)
    }

    @available(macOS 14, *)
    private static func listForMacOS14(
        processListSelector: AudioObjectPropertySelector,
        processPropertyPIDSelector: AudioObjectPropertySelector,
        processPropertyIsRunningInputSelector: AudioObjectPropertySelector,
        processPropertyIsRunningOutputSelector: AudioObjectPropertySelector,
        processPropertyBundleIDSelector: AudioObjectPropertySelector
    ) -> [AudioProcessInfo] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: processListSelector,
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
        return objectIDs.compactMap { objectID in
            info(for: objectID,
                 processPropertyPIDSelector: processPropertyPIDSelector,
                 processPropertyIsRunningInputSelector: processPropertyIsRunningInputSelector,
                 processPropertyIsRunningOutputSelector: processPropertyIsRunningOutputSelector,
                 processPropertyBundleIDSelector: processPropertyBundleIDSelector)
        }
    }

    private static func info(
        for objectID: AudioObjectID,
        processPropertyPIDSelector: AudioObjectPropertySelector,
        processPropertyIsRunningInputSelector: AudioObjectPropertySelector,
        processPropertyIsRunningOutputSelector: AudioObjectPropertySelector,
        processPropertyBundleIDSelector: AudioObjectPropertySelector
    ) -> AudioProcessInfo? {
        guard let pid: pid_t = scalar(objectID, processPropertyPIDSelector) else { return nil }
        let input: UInt32 = scalar(objectID, processPropertyIsRunningInputSelector) ?? 0
        let output: UInt32 = scalar(objectID, processPropertyIsRunningOutputSelector) ?? 0
        return AudioProcessInfo(
            objectID: objectID,
            pid: pid,
            bundleID: string(objectID, processPropertyBundleIDSelector) ?? "",
            isRunningInput: input != 0,
            isRunningOutput: output != 0)
    }

    private static func selector(named symbolName: String) -> AudioObjectPropertySelector? {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, symbolName) else {
            return nil
        }
        return symbol.assumingMemoryBound(to: AudioObjectPropertySelector.self).pointee
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
