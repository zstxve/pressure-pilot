import CoreAudio

enum AudioActivity {
    /// PIDs with running audio output, from CoreAudio's per-process objects (macOS 14+). Empty on older systems.
    static func playingPIDs() -> Set<pid_t> {
        guard #available(macOS 14.0, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        var playing = Set<pid_t>()
        for object in objects where uint32(object, kAudioProcessPropertyIsRunningOutput) == 1 {
            if let pid = uint32(object, kAudioProcessPropertyPID) { playing.insert(pid_t(bitPattern: pid)) }
        }
        return playing
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
