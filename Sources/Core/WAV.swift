import Foundation
import AVFoundation

/// 16 kHz mono 16-bit PCM — the one audio format Hush stores and feeds to its engines.
public enum WAV {
    public static let sampleRate = 16000

    /// Reads a PCM16 WAV file (any channel count; channels are averaged) into Float samples.
    public static func read(_ url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let d = try Data(contentsOf: url)
        guard d.count >= 44, String(data: d[0..<4], encoding: .ascii) == "RIFF",
              String(data: d[8..<12], encoding: .ascii) == "WAVE" else { throw HushError.badAudio("not a WAV file: \(url.lastPathComponent)") }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var off = 12, channels = 1, rate = sampleRate, bits = 16, fmtTag = 1
        var dataStart = -1, dataLen = 0
        while off + 8 <= d.count {
            let id = String(data: d[off..<off + 4], encoding: .ascii) ?? ""
            let len = u32(off + 4)
            if id == "fmt " { fmtTag = u16(off + 8); channels = u16(off + 10); rate = u32(off + 12); bits = u16(off + 22) }
            if id == "data" { dataStart = off + 8; dataLen = min(len, d.count - dataStart); break }
            off += 8 + len + (len & 1)
        }
        guard dataStart >= 0 else { throw HushError.badAudio("no data chunk") }
        guard fmtTag == 1, bits == 16 else { throw HushError.badAudio("only PCM16 WAV supported here (got tag \(fmtTag), \(bits) bit)") }
        let frames = dataLen / (2 * channels)
        var out = [Float](repeating: 0, count: frames)
        d.withUnsafeBytes { raw in
            let p = raw.baseAddress!.advanced(by: dataStart).assumingMemoryBound(to: Int16.self)
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += Float(Int16(littleEndian: p[i * channels + c])) }
                out[i] = s / Float(channels) / 32768
            }
        }
        return (out, rate)
    }

    public static func header(frames: Int, rate: Int = sampleRate) -> Data {
        var d = Data()
        func w32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func w16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); w32(UInt32(36 + frames * 2))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); w32(16); w16(1); w16(1)
        w32(UInt32(rate)); w32(UInt32(rate * 2)); w16(2); w16(16)
        d.append(contentsOf: Array("data".utf8)); w32(UInt32(frames * 2))
        return d
    }

    public static func pcm16(_ samples: ArraySlice<Float>) -> Data {
        var ints = samples.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        return Data(bytes: &ints, count: ints.count * 2)
    }

    public static func write(_ samples: ArraySlice<Float>, to url: URL, rate: Int = sampleRate) throws {
        var d = header(frames: samples.count, rate: rate)
        d.append(pcm16(samples))
        try d.write(to: url, options: .atomic)
    }

    /// Converts any audio file AVFoundation can read (wav, m4a, mp3, aiff, mp4 audio…) to 16 kHz mono PCM16.
    public static func convert(_ input: URL, to output: URL) throws {
        let file = try AVAudioFile(forReading: input)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else { throw HushError.badAudio("cannot convert \(input.lastPathComponent)") }
        var out: [Float] = []
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768)!
        var eof = false
        while true {
            let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 32768)!
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                if eof { st.pointee = .endOfStream; return nil }
                do { try file.read(into: inBuf) } catch { eof = true; st.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { eof = true; st.pointee = .endOfStream; return nil }
                st.pointee = .haveData; return inBuf
            }
            if let err { throw err }
            if outBuf.frameLength > 0, let p = outBuf.floatChannelData?[0] {
                out.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
            if outBuf.frameLength == 0 && eof { break }
        }
        try write(out[...], to: output)
    }

    public static func duration(_ url: URL) -> Double {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 44 else { return 0 }
        return Double(size - 44) / Double(sampleRate * 2)
    }

    public static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Float = 0
        for x in s { acc += x * x }
        return (acc / Float(s.count)).squareRoot()
    }
}

/// Appends 16 kHz mono PCM16 to a WAV file while recording, and keeps the header valid after every flush,
/// so a crash still leaves a playable file.
public final class WAVStreamWriter {
    public let url: URL
    private let handle: FileHandle
    private(set) public var frames = 0
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: WAV.header(frames: 0))
        handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
    }

    /// The throwing FileHandle calls: on a full disk the old `write(_:)` raises an exception that kills the app.
    /// Here the write fails, the audio so far stays valid, and `failed` tells the recorder.
    private(set) public var failed = false
    public func append(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return }
        do {
            try handle.write(contentsOf: WAV.pcm16(samples[...]))
            frames += samples.count
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: WAV.header(frames: frames))
            try handle.seekToEnd()
        } catch {
            failed = true
            Log.write("audio write failed (disk full?): \(error)")
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle.synchronize()
        try? handle.close()
    }
}

/// Resampler + low-pass (box average) to 16 kHz mono, for live capture buffers. Keeps state across calls.
public struct Downsampler {
    public let inRate: Double
    private var buf: [Float] = []
    private var pos: Double = 0

    public init(inRate: Double) { self.inRate = inRate }

    /// `mono` must already be mixed down to one channel.
    public mutating func process(_ mono: [Float]) -> [Float] {
        let step = inRate / Double(WAV.sampleRate)
        if abs(step - 1) < 1e-9 { return mono }
        buf.append(contentsOf: mono)
        let half = max(0, Int(step / 2))
        var out: [Float] = []
        out.reserveCapacity(Int(Double(mono.count) / step) + 2)
        while Int(pos) + half + 1 < buf.count {
            let c = Int(pos)
            let lo = max(0, c - half), hi = c + half
            var acc: Float = 0
            for k in lo...hi { acc += buf[k] }
            out.append(acc / Float(hi - lo + 1))
            pos += step
        }
        let drop = max(0, min(Int(pos) - half, buf.count))
        if drop > 0 { buf.removeFirst(drop); pos -= Double(drop) }
        return out
    }
}

/// Cuts a 16 kHz stream into speech chunks at pauses, for live transcription.
public struct Chunker {
    public var buf: [Float] = []
    public var consumed: Double = 0
    public let minLen = 2.5, maxLen = 9.0, pause = 0.4

    /// Appends samples; returns finished chunks (start time, samples).
    public init() {}
    public mutating func push(_ s: [Float]) -> [(Double, [Float])] {
        buf += s
        var out: [(Double, [Float])] = []
        while true {
            let len = Double(buf.count) / 16000
            if len < minLen { break }
            let tailN = Int(pause * 16000)
            let tailQuiet = WAV.rms(buf.suffix(tailN)[...]) < 0.008
            if tailQuiet || len >= maxLen {
                let cut = len >= maxLen ? quietestCut() : buf.count
                let chunk = Array(buf[..<cut])
                out.append((consumed, chunk))
                consumed += Double(cut) / 16000
                buf.removeFirst(cut)
            } else { break }
        }
        return out
    }

    /// For over-long chunks, cut at the quietest 100 ms window between (maxLen − 4 s) and maxLen.
    public func quietestCut() -> Int {
        let win = 1600, hi = min(buf.count, Int(maxLen * 16000)), from = max(0, hi - 64000)
        var best = hi, bestR = Float.greatestFiniteMagnitude
        var i = from
        while i + win <= hi { let r = WAV.rms(buf[i..<i + win]); if r < bestR { bestR = r; best = i + win / 2 }; i += win / 2 }
        return best
    }
}

