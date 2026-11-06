import AVFoundation
import MediaToolbox

/// Loudness for the microphone track: measure the speech level once, then apply gain with a soft limiter
/// through an audio processing tap, so both preview and export get the same result.
enum AudioLeveling {
    /// Typical (median) speech-window RMS we aim for, in dBFS; lands around -16 LUFS.
    static let targetLevel = -18.0
    static let maxBoost = 24.0

    struct Analysis {
        /// Boost to bring speech to the target level, in dB.
        var gain: Double
        /// Background noise level in dBFS (before gain), used by the noise gate.
        var noiseFloor: Double
    }

    /// Speech level and noise floor of the mic tracks, or nil if there is nothing to measure.
    static func analyze(assets: [AVURLAsset], micTrackIndex: Int) async -> Analysis? {
        var windowLevels: [Double] = []

        for asset in assets {
            guard let tracks = try? await asset.loadTracks(withMediaType: .audio), micTrackIndex < tracks.count,
                  let reader = try? AVAssetReader(asset: asset) else { continue }
            let output = AVAssetReaderTrackOutput(track: tracks[micTrackIndex], outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
            ])
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            guard reader.startReading() else { continue }

            var window: [Float] = []
            window.reserveCapacity(800)
            while let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var samples = [Float](repeating: 0, count: length / 4)
                samples.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                for x in samples {
                    window.append(x)
                    if window.count == 800 { // 50 ms
                        let energy = window.reduce(0) { $0 + Double($1 * $1) } / 800
                        windowLevels.append(10 * log10(max(energy, 1e-12)))
                        window.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
        // Speech = windows clearly above the room's noise floor. The median ignores rare bangs and clicks,
        // which would otherwise make quiet narration look loud.
        let sorted = windowLevels.sorted()
        guard sorted.count > 20 else { return nil }
        let noiseFloor = sorted[sorted.count / 10]
        let speech = sorted.filter { $0 > max(noiseFloor + 10, -60) }
        guard speech.count > 10 else { return nil }
        let level = speech[speech.count / 2]

        // Loud moments are handled by the compressor in the tap, so the boost only depends on the speech level.
        return Analysis(gain: min(maxBoost, max(0, targetLevel - level)), noiseFloor: noiseFloor)
    }

    static func dbToGain(_ db: Double) -> Float { Float(pow(10, db / 20)) }

    /// Noise-gate threshold (linear RMS, before gain) above the noise floor; 0 = off.
    /// Only used when the boost is big enough to make room noise audible.
    /// The floor is a 50 ms RMS level, so the gate compares RMS too: noise peaks sit ~10 dB above
    /// its RMS and would otherwise keep the gate open.
    static func gateLevel(for edit: EditDocument) -> Float {
        gateLevel(normalize: edit.normalizeAudio, gain: edit.micAutoGain, noiseFloor: edit.micNoiseFloor)
    }

    static func voiceoverGateLevel(for edit: EditDocument) -> Float {
        gateLevel(normalize: edit.normalizeAudio, gain: edit.voiceoverAutoGain, noiseFloor: edit.voiceoverNoiseFloor)
    }

    private static func gateLevel(normalize: Bool, gain: Double?, noiseFloor: Double?) -> Float {
        guard normalize, (gain ?? 0) > 6, let noiseFloor else { return 0 }
        return Float(pow(10, (noiseFloor + 12) / 20))
    }

    /// Gain while the gate is closed (-26 dB).
    static let gateFloor: Float = 0.05
    /// How long the gate stays open after the level drops, in seconds, so word endings aren't cut.
    static let gateHold = 0.15

    /// A tap that applies `gain`, then a fast compressor and a soft limiter, so quiet speech gets louder
    /// without loud moments clipping.
    /// `gateLevel` (linear, before gain): below it the signal is treated as room noise and turned down.
    static func makeTap(gain: Float, gateLevel: Float = 0) -> MTAudioProcessingTap? {
        let context = Unmanaged.passRetained(TapContext(gain: gain, gateLevel: gateLevel)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context,
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let c = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let f = format.pointee
                c.isFloat = f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && f.mBitsPerChannel == 32
                let rate = Float(f.mSampleRate > 0 ? f.mSampleRate : 48_000)
                c.attack = exp(-1 / (0.002 * rate))
                c.release = exp(-1 / (0.25 * rate))
                c.envelope = 0
                c.gateRMS = exp(-1 / (0.01 * rate))
                c.gateOpen = exp(-1 / (0.003 * rate))
                c.gateClose = exp(-1 / (0.05 * rate))
                c.gateHoldFrames = Int(AudioLeveling.gateHold * Double(rate))
                c.gateHeld = 0
                c.gateEnergy = 0
                c.gateGain = 1
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let c = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard c.isFloat else { return }
                let list = UnsafeMutableAudioBufferListPointer(buffers)
                // Either one buffer per channel, or one interleaved buffer.
                let planar = list.count > 1
                let channels = planar ? list.count : Int(max(list.first?.mNumberChannels ?? 1, 1))
                let count = Int(framesOut.pointee)
                let pointers = list.compactMap { $0.mData?.bindMemory(to: Float.self, capacity: Int($0.mDataByteSize) / 4) }
                guard pointers.count == list.count else { return }
                for i in 0..<count {
                    var raw: Float = 0
                    for ch in 0..<channels {
                        raw = max(raw, abs(planar ? pointers[ch][i] : pointers[0][i * channels + ch]))
                    }
                    let level = raw * c.gain
                    // Noise gate on a 10 ms RMS: opens fast, holds through word endings, then fades
                    // room noise down by 26 dB.
                    if c.gateLevel > 0 {
                        c.gateEnergy = c.gateRMS * c.gateEnergy + (1 - c.gateRMS) * raw * raw
                        if c.gateEnergy > c.gateLevel * c.gateLevel { c.gateHeld = c.gateHoldFrames }
                        else if c.gateHeld > 0 { c.gateHeld -= 1 }
                        let target: Float = c.gateHeld > 0 ? 1 : AudioLeveling.gateFloor
                        let k = target > c.gateGain ? c.gateOpen : c.gateClose
                        c.gateGain = k * c.gateGain + (1 - k) * target
                    }
                    // Peak envelope: instant attack, smooth release. Gain is reduced by scaling, not by
                    // clipping the waveform, so loud bangs stay clean after encoding.
                    c.envelope = max(level, c.release * c.envelope)
                    // 3:1 compression above -4 dBFS, then a hard ceiling at -1 dBFS.
                    let threshold: Float = 0.63, ceiling: Float = 0.89
                    let comp = c.envelope > threshold ? (threshold + (c.envelope - threshold) / 3) / c.envelope : 1
                    let compressed = c.envelope * comp
                    let reduction = comp * (compressed > ceiling ? ceiling / compressed : 1)
                    let g = c.gain * reduction * c.gateGain
                    for ch in 0..<channels {
                        if planar { pointers[ch][i] = softLimit(pointers[ch][i] * g) }
                        else { pointers[0][i * channels + ch] = softLimit(pointers[0][i * channels + ch] * g) }
                    }
                }
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        return status == noErr ? tap : nil
    }
}

private final class TapContext {
    let gain: Float
    let gateLevel: Float
    var isFloat = true
    var gateRMS: Float = 0.999
    var gateOpen: Float = 0.99
    var gateClose: Float = 0.9995
    var gateHoldFrames = 7200
    var gateHeld = 0
    var gateEnergy: Float = 0
    var gateGain: Float = 1
    var attack: Float = 0.99
    var release: Float = 0.9999
    var envelope: Float = 0

    init(gain: Float, gateLevel: Float) {
        self.gain = gain
        self.gateLevel = gateLevel
    }
}

/// Linear below 0.7, then eases towards a -1 dBFS ceiling, leaving headroom for AAC encoding overshoot.
private func softLimit(_ x: Float) -> Float {
    let a = abs(x)
    guard a > 0.7 else { return x }
    let y = 0.7 + 0.19 * tanh((a - 0.7) / 0.19)
    return x < 0 ? -y : y
}
