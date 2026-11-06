import AVFoundation
import CoreImage
import Metal

final class TakesInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let box: RenderStateBox

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, box: RenderStateBox) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.box = box
        requiredSourceTrackIDs = ([screenTrackID] + (cameraTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

final class TakesCompositor: NSObject, AVVideoCompositing {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let sharedContext: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false,
                                               .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]
        if let device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    private let queue = DispatchQueue(label: "takes.compositor", qos: .userInitiated)
    private let renderer = FrameRenderer()
    private var cancelled = false

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            if self.cancelled {
                request.finishCancelledRequest()
                return
            }
            guard let instruction = request.videoCompositionInstruction as? TakesInstruction,
                  let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID),
                  let output = request.renderContext.newPixelBuffer() else {
                NSLog("[compositor] no source frame at %.3f tracks=%@", request.compositionTime.seconds,
                      "\(request.sourceTrackIDs)")
                request.finish(with: NSError(domain: "Takes", code: 1))
                return
            }
            let camera = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
            let size = request.renderContext.size
            let image = self.renderer.render(screen: CIImage(cvPixelBuffer: screenBuffer), camera: camera,
                                             compTime: request.compositionTime.seconds, canvas: size,
                                             state: instruction.box.state)
            Self.sharedContext.render(image, to: output, bounds: CGRect(origin: .zero, size: size),
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            request.finish(withComposedVideoFrame: output)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelled = true
        queue.async(flags: .barrier) { self.cancelled = false }
    }
}

/// Builds the playable/exportable composition for a project.
struct CompositionBuilder {
    struct Result {
        var composition: AVMutableComposition
        var videoComposition: AVMutableVideoComposition
        var audioMix: AVMutableAudioMix
    }

    let bundle: ProjectBundle
    let meta: ProjectMeta
    let assets: [Int: AVURLAsset]
    let cameraAssets: [Int: AVURLAsset]
    /// Keyed by file name. Like the others these must outlive the composition: it fails once they are released.
    let voiceoverAssets: [String: AVURLAsset]

    func build(timeline: Timeline, box: RenderStateBox, renderSize: CGSize, fps: Int, edit: EditDocument) async throws -> Result {
        let comp = AVMutableComposition()
        guard let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.featureUnsupported)
        }
        let camera = meta.hasCamera && !cameraAssets.isEmpty
            ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let system = meta.hasSystemAudio ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        let mic = meta.hasMic ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        for entry in timeline.entries {
            guard let asset = assets[entry.segment] else { continue }
            let (at, range) = Self.placement(of: entry)
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let trackRange = try await track.load(.timeRange)
                try video.insertTimeRange(Self.fitted(range, in: trackRange), of: track, at: at)
            }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            var audioIndex = 0
            if let system, audioIndex < audio.count {
                let r = try await audio[audioIndex].load(.timeRange)
                try? system.insertTimeRange(range.intersection(r), of: audio[audioIndex], at: at)
                audioIndex += 1
            }
            if let mic, audioIndex < audio.count {
                let r = try await audio[audioIndex].load(.timeRange)
                try? mic.insertTimeRange(range.intersection(r), of: audio[audioIndex], at: at)
            }
            if let camera, let camAsset = cameraAssets[entry.segment],
               let track = try await camAsset.loadTracks(withMediaType: .video).first {
                let r = try await track.load(.timeRange)
                try? camera.insertTimeRange(range.intersection(r), of: track, at: at)
            }
        }

        let voiceover = try await addVoiceover(to: comp, timeline: timeline, edit: edit)

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = TakesCompositor.self
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        vc.renderSize = renderSize
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        // Cover exactly the video track: a frame requested past its end has no source and fails the whole export.
        let videoEnd = video.timeRange.end
        let duration = videoEnd > .zero ? videoEnd : CMTime(seconds: 0.1, preferredTimescale: 600)
        vc.instructions = [TakesInstruction(timeRange: CMTimeRange(start: .zero, duration: duration),
                                            screenTrackID: video.trackID, cameraTrackID: camera?.trackID, box: box)]

        let mix = AVMutableAudioMix()
        var params: [AVMutableAudioMixInputParameters] = []
        if let system {
            let p = AVMutableAudioMixInputParameters(track: system)
            p.audioTapProcessor = AudioLeveling.makeTap(gain: Float(edit.systemVolume))
            params.append(p)
        }
        if let mic {
            // Gain goes through a tap so it can exceed 1 without clipping; the mix volume stays at 1.
            let p = AVMutableAudioMixInputParameters(track: mic)
            let auto = edit.normalizeAudio ? AudioLeveling.dbToGain(edit.micAutoGain ?? 0) : 1
            // Gate a little above the noise floor, only when the boost would make the noise audible.
            let gate = AudioLeveling.gateLevel(for: edit)
            p.audioTapProcessor = AudioLeveling.makeTap(gain: auto * Float(edit.micVolume), gateLevel: gate)
            params.append(p)
        }
        if let voiceover {
            let p = AVMutableAudioMixInputParameters(track: voiceover)
            let auto = edit.normalizeAudio ? AudioLeveling.dbToGain(edit.voiceoverAutoGain ?? 0) : 1
            p.audioTapProcessor = AudioLeveling.makeTap(gain: auto * Float(edit.voiceoverVolume),
                                                        gateLevel: AudioLeveling.voiceoverGateLevel(for: edit))
            params.append(p)
        }
        mix.inputParameters = params
        return Result(composition: comp, videoComposition: vc, audioMix: mix)
    }

    /// Lays the narration on its own track. Uses the clips' tick grid, so it never outlasts the video.
    private func addVoiceover(to comp: AVMutableComposition, timeline: Timeline, edit: EditDocument) async throws -> AVMutableCompositionTrack? {
        let placements = VoiceoverLayout.placements(edit.voiceovers, entries: timeline.entries)
        guard !placements.isEmpty,
              let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        func ticks(_ seconds: Double) -> CMTimeValue { CMTimeValue((seconds * 600).rounded()) }
        var sources: [String: (track: AVAssetTrack, range: CMTimeRange)] = [:]
        for p in placements {
            if sources[p.file] == nil {
                guard let asset = voiceoverAssets[p.file],
                      let source = try? await asset.loadTracks(withMediaType: .audio).first,
                      let range = try? await source.load(.timeRange) else { continue }
                sources[p.file] = (source, range)
            }
            guard let source = sources[p.file] else { continue }
            let at = ticks(p.at)
            let range = CMTimeRange(start: CMTime(value: ticks(p.fileStart), timescale: 600),
                                    duration: CMTime(value: ticks(p.at + p.duration) - at, timescale: 600))
                .intersection(source.range)
            guard !range.isEmpty else { continue }
            try track.insertTimeRange(range, of: source.track, at: CMTime(value: at, timescale: 600))
        }
        return track
    }

    /// Where a clip lands in the composition and which part of its take it plays.
    ///
    /// Both clip edges are snapped to one tick grid, so a clip ends on exactly the tick where the next begins.
    /// Rounding start and duration separately can leave a 1/600 s hole between clips; a frame that falls in
    /// the hole has no source, which stalls playback and fails the export.
    static func placement(of entry: Timeline.Entry) -> (at: CMTime, range: CMTimeRange) {
        func ticks(_ seconds: Double) -> CMTimeValue { CMTimeValue((seconds * 600).rounded()) }
        let at = ticks(entry.compStart)
        let start = CMTime(value: ticks(entry.sourceStart - entry.takeStart), timescale: 600)
        let duration = CMTime(value: ticks(entry.compEnd) - at, timescale: 600)
        return (CMTime(value: at, timescale: 600), CMTimeRange(start: start, duration: duration))
    }

    /// Slides a range that rounding pushed past the end of the track back inside it, keeping its length.
    static func fitted(_ range: CMTimeRange, in track: CMTimeRange) -> CMTimeRange {
        guard range.end > track.end else { return range }
        let start = CMTimeMaximum(track.start, track.end - range.duration)
        return CMTimeRange(start: start, duration: range.duration).intersection(track)
    }
}
