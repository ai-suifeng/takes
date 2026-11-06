import AVFoundation
import CoreMedia

enum VoiceoverPhase: Equatable {
    case idle, preparing, countdown(Int), recording, finishing
}

/// A stretch of a voiceover file that was recorded while the video played without interruption.
struct VoiceoverRun: Equatable {
    var fileStart: Double
    var compStart: Double
    var duration: Double

    var compEnd: Double { compStart + duration }
}

/// Follows how a recording lines up with the video. Whenever the two slip apart (the video stalled, the mic
/// dropped samples, their clocks drifted) a new run begins, so each run sits exactly on the frames it was
/// recorded over.
struct VoiceoverSync {
    /// Slip before a new run starts: below what can be noticed as lip sync, above timestamp jitter.
    static let tolerance = 0.03

    private(set) var runs: [VoiceoverRun] = []
    private var offset: Double?

    mutating func add(fileTime: Double, compTime: Double, duration: Double) {
        let current = compTime - fileTime
        if let offset, abs(current - offset) <= Self.tolerance {
            runs[runs.count - 1].duration = fileTime + duration - runs[runs.count - 1].fileStart
        } else {
            offset = current
            runs.append(VoiceoverRun(fileStart: fileTime, compStart: compTime, duration: duration))
        }
    }
}

/// One kept stretch of narration at its place in the output.
struct VoiceoverPlacement: Hashable {
    var pieceID: UUID
    /// Index of the timeline entry it plays in. With the piece it identifies this stretch through a trim.
    var entry: Int
    var file: String
    var fileStart: Double
    /// Source time of its first sample.
    var source: Double
    var at: Double
    var duration: Double

    var stableID: String { "\(pieceID)/\(entry)" }
}

/// Moves narration between output time, where it is recorded and heard, and source time, where it is stored.
enum VoiceoverLayout {
    /// `runs` from output time `start` on. The first mic buffer usually began before playback did; that
    /// audio has no frame, and would overwrite narration just before the recording.
    static func trimmed(_ runs: [VoiceoverRun], from start: Double) -> [VoiceoverRun] {
        runs.compactMap { run in
            let cut = start - run.compStart
            guard cut > 0 else { return run }
            guard run.duration > cut else { return nil }
            return VoiceoverRun(fileStart: run.fileStart + cut, compStart: start, duration: run.duration - cut)
        }
    }

    /// Pieces for a finished recording. A run crossing a cut is split there, because the two sides are far
    /// apart in source time.
    static func pieces(file: String, runs: [VoiceoverRun], timeline: Timeline) -> [VoiceoverPiece] {
        var result: [VoiceoverPiece] = []
        for run in runs {
            for e in timeline.entries {
                let a = max(run.compStart, e.compStart), b = min(run.compEnd, e.compEnd)
                guard b - a > 0.01 else { continue }
                let start = e.sourceStart + a - e.compStart
                result.append(VoiceoverPiece(file: file, fileStart: run.fileStart + a - run.compStart,
                                             start: start, duration: b - a,
                                             sourceMin: start, sourceMax: start + b - a))
            }
        }
        return result
    }

    /// What can be heard, in output order: only the parts of each piece whose frames were kept.
    static func placements(_ pieces: [VoiceoverPiece], entries: [Timeline.Entry]) -> [VoiceoverPlacement] {
        var result: [VoiceoverPlacement] = []
        for (index, e) in entries.enumerated() {
            for p in pieces {
                let a = max(p.start, e.sourceStart), b = min(p.end, e.sourceEnd)
                guard b - a > 0.01 else { continue }
                result.append(VoiceoverPlacement(pieceID: p.id, entry: index, file: p.file, fileStart: p.fileStart + a - p.start,
                                                 source: a, at: e.compStart + a - e.sourceStart, duration: b - a))
            }
        }
        return result.sorted { $0.at < $1.at }
    }

    /// `pieces` without the given source-time span; a piece across it is split in two.
    static func removing(start: Double, end: Double, from pieces: [VoiceoverPiece]) -> [VoiceoverPiece] {
        var result: [VoiceoverPiece] = []
        for p in pieces {
            guard p.start < end, p.end > start else { result.append(p); continue }
            if start - p.start > 0.01 {
                var left = p
                left.duration = start - p.start
                result.append(left)
            }
            if p.end - end > 0.01 {
                var right = p
                right.id = UUID()
                right.fileStart = p.fileStart + end - p.start
                right.start = end
                right.duration = p.end - end
                result.append(right)
            }
        }
        return result
    }

    /// Lays new pieces over the old ones, replacing whatever they cover. Later pieces win.
    static func overlaying(_ added: [VoiceoverPiece], on existing: [VoiceoverPiece]) -> [VoiceoverPiece] {
        added.reduce(existing) { removing(start: $1.start, end: $1.end, from: $0) + [$1] }
    }
}

/// Records the mic into one audio file and notes which output time each sample was heard against, read from
/// the player's own clock. Samples are written back to back, so a position in the file is an exact sample count.
final class VoiceoverRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let sampleRate = 48_000

    let url: URL
    /// Called on the main queue with an output time and the mic's RMS level around it.
    var onLevel: ((Double, Float) -> Void)?

    private let session = AVCaptureSession()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "takes.voiceover", qos: .userInitiated)
    // Everything below is confined to `queue`.
    private var timebase: CMTimebase?
    private var clock: CMClock = CMClockGetHostTimeClock()
    private var written = CMTime.zero
    private var sync = VoiceoverSync()
    private var levelEnergy: Float = 0
    private var levelFrames = 0

    init(url: URL) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        super.init()
    }

    /// Opens the mic. Nothing is written until `listen(to:)`.
    func startCapture(deviceID: String?) async throws {
        guard let device = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .audio) else {
            throw CocoaError(.featureUnsupported)
        }
        let deviceInput = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CocoaError(.featureUnsupported)
        }
        session.addInput(deviceInput)
        session.addOutput(output)
        session.commitConfiguration()
        let session = session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
                done.resume()
            }
        }
        if let clock = session.synchronizationClock { queue.sync { self.clock = clock } }
    }

    /// From now on, samples heard while `timebase` runs are recorded against it.
    func listen(to timebase: CMTimebase) {
        queue.sync { self.timebase = timebase }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(sampleBuffer)
    }

    /// Takes one buffer of mono float samples stamped on `clock`. Must run on `queue`.
    private func append(_ buffer: CMSampleBuffer) {
        // A stopped clock means the picture is frozen: there is no frame for this audio to belong to.
        guard let timebase, CMTimebaseGetEffectiveRate(timebase) > 0,
              writer.status == .writing, input.isReadyForMoreMediaData else { return }
        let frames = CMSampleBufferGetNumSamples(buffer)
        let rate = buffer.formatDescription?.audioStreamBasicDescription?.mSampleRate ?? Double(Self.sampleRate)
        guard frames > 0, rate > 0 else { return }
        let compTime = CMSyncConvertTime(buffer.presentationTimeStamp, from: clock, to: timebase).seconds
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: written, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &retimed)
        guard let retimed, input.append(retimed) else { return }
        let duration = Double(frames) / rate
        sync.add(fileTime: written.seconds, compTime: compTime, duration: duration)
        written = written + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
        reportLevel(buffer, frames: frames, at: compTime, rate: rate)
    }

    private func reportLevel(_ buffer: CMSampleBuffer, frames: Int, at compTime: Double, rate: Double) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        samples.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        levelEnergy += samples.reduce(0) { $0 + $1 * $1 }
        levelFrames += samples.count
        guard Double(levelFrames) >= rate / 30 else { return }
        let level = (levelEnergy / Float(levelFrames)).squareRoot()
        levelEnergy = 0
        levelFrames = 0
        let onLevel = onLevel
        DispatchQueue.main.async { onLevel?(compTime, level) }
    }

    /// Closes the mic and the file, and returns how the file lines up with the output.
    func stop() async -> [VoiceoverRun] {
        session.stopRunning()
        let (end, runs): (CMTime, [VoiceoverRun]) = queue.sync {
            timebase = nil
            return (written, sync.runs)
        }
        guard end > .zero else {
            cancel()
            return []
        }
        writer.endSession(atSourceTime: end)
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? runs : []
    }

    func cancel() {
        session.stopRunning()
        queue.sync { timebase = nil }
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }

    /// Test hook: feeds one buffer as if it came from the mic.
    func feed(_ buffer: CMSampleBuffer) {
        queue.sync { append(buffer) }
    }
}
