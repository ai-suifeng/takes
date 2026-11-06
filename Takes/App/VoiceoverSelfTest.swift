import AVFoundation
import CoreVideo

/// `Takes --voiceover-test <folder> [--mic]`: measures how closely recorded narration lands on its frames.
/// Default: feeds tone pulses through the real player clock, recorder, composition and export.
/// `--mic`: plays clicks through the speakers and records them with the real mic, measuring the whole round trip.
enum VoiceoverSelfTest {
    private static let rate = 48_000

    static func run(output: URL, realMic: Bool) {
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                checkLayout()
                if realMic { try await micRoundTrip(output) } else { try await pipeline(output) }
                log("DONE")
                exit(0)
            } catch {
                log("FAIL \(error)")
                exit(1)
            }
        }
    }

    private static func log(_ s: String) {
        print("[voiceover-test] \(s)")
        fflush(stdout)
    }

    private static func fail(_ s: String) -> NSError { NSError(domain: s, code: 1) }

    private static func checkLayout() {
        let a = VoiceoverPiece(file: "a", fileStart: 0, start: 0, duration: 10)
        let b = VoiceoverPiece(file: "b", fileStart: 0, start: 4, duration: 2)
        let merged = VoiceoverLayout.overlaying([b], on: [a]).sorted { $0.start < $1.start }
        precondition(merged.count == 3 && merged[0].duration == 4 && merged[1].file == "b"
            && merged[2].start == 6 && merged[2].fileStart == 6, "overlaying")
        var sync = VoiceoverSync()
        sync.add(fileTime: 0, compTime: 1, duration: 0.01)
        sync.add(fileTime: 0.01, compTime: 1.015, duration: 0.01)
        sync.add(fileTime: 0.02, compTime: 3, duration: 0.01)
        precondition(sync.runs.count == 2 && sync.runs[0].duration == 0.02 && sync.runs[1].compStart == 3, "sync")
        let trimmed = VoiceoverLayout.trimmed([VoiceoverRun(fileStart: 0, compStart: 1.9, duration: 1)], from: 2)
        precondition(abs(trimmed[0].fileStart - 0.1) < 1e-9 && trimmed[0].compStart == 2 && abs(trimmed[0].duration - 0.9) < 1e-9, "trimmed")
        var blur = BlurRegion(start: 2, duration: 4, rect: .zero)
        blur.keyframes = [BlurKeyframe(t: 0, rect: NormRect(x: 0, y: 0, w: 0.1, h: 0.1)), BlurKeyframe(t: 4, rect: NormRect(x: 0.8, y: 0, w: 0.1, h: 0.1))]
        let before = blur.rect(at: 4).x
        blur.trim(start: 3, end: 6)
        precondition(abs(blur.rect(at: 4).x - before) < 1e-9 && blur.start == 3 && blur.duration == 3, "tracked mask stays on its frames")
        var pen = Annotation(kind: .pen, start: 1, duration: 3)
        pen.points = [StrokePoint(x: 0, y: 0, t: 0), StrokePoint(x: 1, y: 1, t: 2)]
        pen.trim(start: 2, end: 4)
        precondition(pen.points[1].t == 1 && pen.start == 2 && pen.duration == 2, "stroke stays on its frames")
        log("layout ok")
    }

    // MARK: - Pipeline

    @MainActor
    private static func pipeline(_ out: URL) async throws {
        let bundle = try makeProject(in: out, name: "pipeline", clicks: [])
        let model = try EditorModel(bundle: bundle)
        for _ in 0..<100 where !model.isReady { try await Task.sleep(for: .milliseconds(100)) }
        model.edit.normalizeAudio = false
        try await Task.sleep(for: .milliseconds(400))
        guard let timebase = model.player.currentItem?.timebase else { throw fail("no timebase") }

        try FileManager.default.createDirectory(at: bundle.voiceoverDir, withIntermediateDirectories: true)
        let file = "test.m4a"
        let recorder = try VoiceoverRecorder(url: bundle.voiceoverURL(file))
        recorder.listen(to: timebase)
        model.player.isMuted = true
        model.player.playImmediately(atRate: 1)

        let pulses = [1.0, 2.0, 4.0, 5.0]
        let clock = CMClockGetHostTimeClock()
        var pts = CMClockGetTime(clock)
        let chunk = 480
        var paused = false, resumed = false, pausedAt = Date()
        while CMTimebaseGetTime(timebase).seconds < 5.6 {
            pts = pts + CMTime(value: CMTimeValue(chunk), timescale: CMTimeScale(rate))
            while CMClockGetTime(clock) < pts { try await Task.sleep(for: .milliseconds(2)) }
            let comp = CMSyncConvertTime(pts, from: clock, to: timebase).seconds
            let samples = (0..<chunk).map { i -> Float in
                let t = comp + Double(i) / Double(rate)
                guard pulses.contains(where: { t >= $0 && t < $0 + 0.02 }) else { return 0 }
                return 0.8 * Float(sin(2 * .pi * 1000 * t))
            }
            // A mic dropout: these samples never arrive, so what follows must not slide earlier.
            if comp < 3.3 || comp > 3.5 { recorder.feed(pcm(samples, pts: pts)) }
            // Freeze the picture for a while, as a stall would: the talking meanwhile has no frame to sit on.
            if !paused, comp > 2.5 {
                paused = true
                pausedAt = Date()
                model.player.pause()
            }
            if paused, !resumed, Date().timeIntervalSince(pausedAt) > 0.7 {
                resumed = true
                model.player.playImmediately(atRate: 1)
            }
        }
        let runs = await recorder.stop()
        model.player.pause()
        model.player.isMuted = false
        log("runs=\(runs.map { String(format: "file %.3f comp %.3f dur %.3f", $0.fileStart, $0.compStart, $0.duration) })")
        guard runs.count == 2 else { throw fail("the mic dropout should have split the recording in two") }
        await model.commitVoiceover(file: file, runs: runs)
        log("pieces=\(model.edit.voiceovers.count) duration=\(model.duration)")

        try await checkExport(model, name: "uncut.mp4", expected: pulses, in: out)

        // Cutting frames takes the narration on them along and keeps the rest on its frames.
        model.range = 1.5...2.5
        model.deleteRange()
        try await checkExport(model, name: "cut.mp4", expected: [1.0, 3.0, 4.0], in: out)

        // The narration survives a reopen.
        model.saveNow()
        let reopened = try EditorModel(bundle: bundle)
        for _ in 0..<100 where !reopened.isReady { try await Task.sleep(for: .milliseconds(100)) }
        try await checkExport(reopened, name: "reopened.mp4", expected: [1.0, 3.0, 4.0], in: out)

        // Cutting on the voiceover track takes narration only; the video keeps its length.
        let length = reopened.duration
        func piece(atComp t: Double) throws -> VoiceoverPiece {
            let s = reopened.timeline.sourceTime(t)
            guard let p = reopened.edit.voiceovers.first(where: { s >= $0.start && s < $0.end }) else { throw fail("no narration at \(t)") }
            return p
        }
        reopened.seek(comp: 1.5)
        reopened.select(.voiceover(try piece(atComp: 1.5).id))
        reopened.trimAtPlayhead(keepRight: true)
        try await checkExport(reopened, name: "trim-left.mp4", expected: [3.0, 4.0], in: out)
        reopened.seek(comp: 3.5)
        let whole = try piece(atComp: 3.5)
        reopened.select(.voiceover(whole.id))
        reopened.splitAtPlayhead()
        guard case .voiceover(let rightID) = reopened.selection, rightID != whole.id else { throw fail("split should select the right half") }
        reopened.delete(.voiceover(rightID))
        try await checkExport(reopened, name: "split-delete.mp4", expected: [3.0], in: out)
        guard reopened.duration == length else { throw fail("voiceover cuts changed the video length") }

        // A piece can be narrowed and widened back, but not past what was recorded there.
        let left = try piece(atComp: 3.2)
        let fullEnd = left.end
        reopened.trimVoiceover(left.id, end: fullEnd - 0.2)
        reopened.trimVoiceover(left.id, end: fullEnd + 5)
        let widened = reopened.edit.voiceovers.first { $0.id == left.id }!
        log(String(format: "edge drag: end %.3f -> widened %.3f (limit %.3f)", fullEnd, widened.end, widened.sourceMax ?? -1))
        guard widened.end <= (widened.sourceMax ?? 0) + 0.001 else { throw fail("widened past the recording") }

        // Every other track: a selected item takes the cut, the video does not; playhead outside changes nothing.
        reopened.edit.zooms = [ZoomRegion(start: 0.5, duration: 1.5, isAuto: true)]
        reopened.edit.blurs = [BlurRegion(start: 0.5, duration: 1.5, rect: NormRect(x: 0, y: 0, w: 0.2, h: 0.2))]
        reopened.edit.annotations = [Annotation(kind: .box, start: 0.5, duration: 1.5)]
        let clips = reopened.edit.clips
        reopened.seek(comp: 1)
        reopened.select(.zoom(reopened.edit.zooms[0].id))
        reopened.splitAtPlayhead()
        reopened.select(.blur(reopened.edit.blurs[0].id))
        reopened.trimAtPlayhead(keepRight: true)
        reopened.select(.annotation(reopened.edit.annotations[0].id))
        reopened.trimAtPlayhead(keepRight: false)
        let z = reopened.edit.zooms, b = reopened.edit.blurs[0], a = reopened.edit.annotations[0]
        log(String(format: "zoom split %d (%.2f-%.2f, %.2f-%.2f auto=%d) blur %.2f-%.2f annotation %.2f-%.2f", z.count, z[0].start, z[0].end,
                   z[1].start, z[1].end, z[0].isAuto ? 1 : 0, b.start, b.end, a.start, a.end))
        guard z.count == 2, abs(z[0].end - 1) < 0.001, abs(z[1].start - 1) < 0.001, abs(z[1].end - 2) < 0.001, !z[0].isAuto,
              abs(b.start - 1) < 0.001, abs(b.end - 2) < 0.001, abs(a.start - 0.5) < 0.001, abs(a.end - 1) < 0.001 else { throw fail("track cuts") }
        reopened.seek(comp: 3)
        reopened.select(.zoom(z[0].id))
        reopened.trimAtPlayhead(keepRight: true)
        guard reopened.edit.zooms == z, reopened.edit.clips == clips else { throw fail("a cut outside the item or on the video") }
        reopened.undo()
        guard reopened.edit.clips == clips else { throw fail("undo") }
        log("track cuts ok")
    }

    @MainActor
    private static func checkExport(_ model: EditorModel, name: String, expected: [Double], in out: URL) async throws {
        let url = out.appendingPathComponent(name)
        try await Exporter.export(model: model, options: ExportOptions(resolution: .p720, fps: 60), to: url) { _ in }
        let onsets = try await onsets(in: AVURLAsset(url: url), threshold: 0.1)
        let errors = zip(onsets, expected).map { abs($0 - $1) * 1000 }
        log("\(name): onsets=\(onsets.map { String(format: "%.4f", $0) }) expected=\(expected) error ms=\(errors.map { String(format: "%.1f", $0) })")
        guard onsets.count == expected.count else { throw fail("\(name): wrong pulse count") }
        // One frame at 60 fps.
        guard errors.allSatisfy({ $0 < 16.7 }) else { throw fail("\(name): off by more than a frame") }
    }

    // MARK: - Real mic

    @MainActor
    private static func micRoundTrip(_ out: URL) async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw fail("mic permission not granted") }
        let clicks = [1.0, 2.0, 4.0, 5.0]
        let bundle = try makeProject(in: out, name: "mic", clicks: clicks)
        let model = try EditorModel(bundle: bundle)
        for _ in 0..<100 where !model.isReady { try await Task.sleep(for: .milliseconds(100)) }
        model.edit.normalizeAudio = false
        try await Task.sleep(for: .milliseconds(400))
        guard let timebase = model.player.currentItem?.timebase else { throw fail("no timebase") }

        try FileManager.default.createDirectory(at: bundle.voiceoverDir, withIntermediateDirectories: true)
        let url = bundle.voiceoverURL("mic.m4a")
        let recorder = try VoiceoverRecorder(url: url)
        try await recorder.startCapture(deviceID: AppSettings.shared.micDeviceID)
        try await Task.sleep(for: .milliseconds(500))
        recorder.listen(to: timebase)
        model.player.playImmediately(atRate: 1)
        while CMTimebaseGetTime(timebase).seconds < 5.6 { try await Task.sleep(for: .milliseconds(20)) }
        let runs = await recorder.stop()
        model.player.pause()
        log("runs=\(runs.map { String(format: "file %.3f comp %.3f dur %.3f", $0.fileStart, $0.compStart, $0.duration) })")
        guard let run = runs.first else { throw fail("nothing recorded") }
        let fileOnsets = try await onsets(in: AVURLAsset(url: url), threshold: nil)
        let heard = fileOnsets.map { $0 - run.fileStart + run.compStart }
        let errors = zip(heard, clicks).map { ($0 - $1) * 1000 }
        log("heard=\(heard.map { String(format: "%.4f", $0) }) played=\(clicks) offset ms=\(errors.map { String(format: "%.1f", $0) })")
        if heard.count != clicks.count { log("WARN heard \(heard.count) clicks: on headphones the mic cannot hear them") }
    }

    // MARK: - Helpers

    /// Times where the signal rises above `threshold` (or half its peak when nil), at most one per 0.3 s.
    private static func onsets(in asset: AVURLAsset, threshold: Float?) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw fail("no audio in \(asset.url.lastPathComponent)") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()
        var all: [(t: Double, x: Float)] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let start = buffer.presentationTimeStamp.seconds
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / 4)
            samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for (i, x) in samples.enumerated() { all.append((start + Double(i) / Double(rate), abs(x))) }
        }
        let level = threshold ?? (all.map(\.x).max() ?? 0) * 0.5
        var result: [Double] = []
        for s in all where s.x > level && (result.last.map { s.t - $0 > 0.3 } ?? true) { result.append(s.t) }
        return result
    }

    private static func pcm(_ samples: [Float], pts: CMTime) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        let bytes = samples.count * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = 4
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample!
    }

    /// Two 3-second takes of a black screen, with `clicks` (in output time) on a system-audio track when given.
    private static func makeProject(in folder: URL, name: String, clicks: [Double]) throws -> ProjectBundle {
        let url = folder.appendingPathComponent("\(name).takes", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        let root = folder
        let bundle = try ProjectBundle.create(in: root, name: name)
        var meta = ProjectMeta(name: name, kind: .display, sourceTitle: "test", width: 1280, height: 720, scale: 1)
        for i in 0..<2 {
            let file = "take-00\(i + 1).mov"
            let offset = Double(i) * 3
            try writeTake(bundle.segmentURL(file), seconds: 3, clicks: clicks.map { $0 - offset }.filter { $0 >= 0 && $0 < 3 }, withAudio: !clicks.isEmpty)
            meta.segments.append(SegmentInfo(index: i, file: file, duration: 3))
        }
        meta.status = .ready
        meta.hasSystemAudio = !clicks.isEmpty
        try bundle.writeMeta(meta)
        return bundle
    }

    private static func writeTake(_ url: URL, seconds: Int, clicks: [Double], withAudio: Bool) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        writer.add(video)
        let audio = withAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ]) : nil
        if let audio { writer.add(audio) }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &pixels)
        CVPixelBufferLockBaseAddress(pixels!, [])
        memset(CVPixelBufferGetBaseAddress(pixels!), 0, CVPixelBufferGetDataSize(pixels!))
        CVPixelBufferUnlockBaseAddress(pixels!, [])
        // Audio and video go in side by side: the writer holds one back when the other falls too far behind.
        let chunk = 4_800
        for c in 0..<(seconds * 10) {
            for f in 0..<3 {
                while !video.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                adaptor.append(pixels!, withPresentationTime: CMTime(value: CMTimeValue(c * 3 + f), timescale: 30))
            }
            guard let audio else { continue }
            let t0 = Double(c * chunk) / Double(rate)
            let samples = (0..<chunk).map { i -> Float in
                let t = t0 + Double(i) / Double(rate)
                guard clicks.contains(where: { t >= $0 && t < $0 + 0.03 }) else { return 0 }
                return 0.7 * Float(sin(2 * .pi * 1000 * t))
            }
            while !audio.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            audio.append(pcm(samples, pts: CMTime(value: CMTimeValue(c * chunk), timescale: CMTimeScale(rate))))
        }
        video.markAsFinished()
        audio?.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
