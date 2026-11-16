import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Captures everything the Mac plays (Zoom, Meet in a browser, Teams…) through a Core Audio process tap.
/// No virtual driver, no bot. Hush's own process is excluded so prompter sounds never loop back.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var sampleRate: Double = 48000
    /// Called on the audio thread with mono Float samples at `sampleRate`.
    var onSamples: (([Float]) -> Void)?

    func start() throws {
        let exclude = Self.ownProcessObject().map { [$0] } ?? []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID(); desc.muteBehavior = .unmuted; desc.isPrivate = true; desc.name = "Hush system audio"
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create process tap")

        var fmt = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout.size(ofValue: fmt))
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &fmt), "read tap format")
        sampleRate = fmt.mSampleRate

        // Tap-only aggregate: no output sub-device. With voice processing on, the output device gains extra
        // input streams (echo reference); including it mixes those into the call audio (found in QA, run-1/QA-REPORT.md).
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hush Tap", kAudioAggregateDeviceUIDKey: "id.roxst.hush.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "create aggregate device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] _, inData, _, _, _ in
            self?.handle(inData)
        }, "create IO proc")
        try check(AudioDeviceStart(aggID, procID), "start tap")
        Log.write("system tap started \(sampleRate) Hz, \(fmt.mChannelsPerFrame) ch")
    }

    private var dbgFrames = 0, dbgCalls = 0, dbgStart = Date()
    private func handle(_ inData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let first = abl.first, first.mDataByteSize > 0 else { return }
        if ProcessInfo.processInfo.environment["HUSH_DEBUG_TAP"] == "1" {
            dbgCalls += 1; dbgFrames += Int(first.mDataByteSize) / 4 / max(1, Int(first.mNumberChannels))
            if dbgCalls % 200 == 0 { Log.write("tap dbg: buffers=\(abl.count) ch=\(first.mNumberChannels) bytes=\(first.mDataByteSize) frames/s=\(Double(dbgFrames) / Date().timeIntervalSince(dbgStart))") }
        }
        if abl.count == 1 {
            let ch = max(1, Int(first.mNumberChannels)), n = Int(first.mDataByteSize) / 4 / ch
            guard let p = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            var mono = [Float](repeating: 0, count: n)
            for i in 0..<n { var s: Float = 0; for c in 0..<ch { s += p[i * ch + c] }; mono[i] = s / Float(ch) }
            onSamples?(mono)
        } else {
            let n = Int(first.mDataByteSize) / 4
            var mono = [Float](repeating: 0, count: n)
            for b in abl { guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }; for i in 0..<n { mono[i] += p[i] } }
            let k = Float(abl.count); for i in 0..<n { mono[i] /= k }
            onSamples?(mono)
        }
    }

    func stop() {
        if aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown); procID = nil
    }

    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid(); var obj = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    private func check(_ s: OSStatus, _ what: String) throws {
        if s != noErr { throw HushError.engine("system audio: \(what) failed (OSStatus \(s)). Allow Hush in System Settings → Privacy & Security → Screen & System Audio Recording.") }
    }
}

/// Microphone capture. Voice processing (Apple's echo cancellation) removes call audio that leaks from the speakers.
final class MicCapture {
    private let engine = AVAudioEngine()
    private(set) var sampleRate: Double = 48000
    var onSamples: (([Float]) -> Void)?
    var echoCancel = true

    func start() throws {
        let input = engine.inputNode
        if echoCancel {
            do {
                try input.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, *) {
                    // Do not turn down the meeting audio the user is listening to.
                    input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch { Log.write("voice processing unavailable, plain mic: \(error)") }
        }
        let fmt = input.outputFormat(forBus: 0)
        sampleRate = fmt.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let d = buf.floatChannelData else { return }
            let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
            var mono = [Float](repeating: 0, count: n)
            for c in 0..<ch { let p = d[c]; for i in 0..<n { mono[i] += p[i] } }
            if ch > 1 { let k = Float(ch); for i in 0..<n { mono[i] /= k } }
            self?.onSamples?(mono)
        }
        engine.prepare()
        try engine.start()
        Log.write("mic started \(sampleRate) Hz, voice processing \(input.isVoiceProcessingEnabled)")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }
}
