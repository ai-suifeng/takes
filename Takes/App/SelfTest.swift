import AVFoundation
import AppKit
import ScreenCaptureKit

/// End-to-end check run with `Takes --selftest <folder>`: records with pauses and redos,
/// then renders frames, exports and scans the result. Writes everything into `<folder>`.
enum SelfTest {
    static func run(output: URL) {
        Task { @MainActor in
            do {
                try await body(output)
                log("DONE")
            } catch {
                log("FAIL \(error)")
            }
            exit(0)
        }
    }

    /// `Takes --render <xxx.takes> <seconds> <out.png>`: renders one output frame with the saved edit.
    static func renderFrame(bundle: URL, at t: Double, to out: URL) {
        Task { @MainActor in
            do {
                let model = try EditorModel(bundle: ProjectBundle(url: bundle))
                for _ in 0..<100 where !model.isReady { await wait(0.1) }
                let state = model.renderState
                let builder = CompositionBuilder(bundle: model.bundle, meta: model.meta, assets: model.assets, cameraAssets: model.cameraAssets, voiceoverAssets: model.voiceoverAssets)
                let size = state.canvasSize(longSide: state.nativeLongSide)
                let result = try await builder.build(timeline: model.timeline, box: RenderStateBox(state), renderSize: size, fps: 30, edit: model.edit)
                let generator = AVAssetImageGenerator(asset: result.composition)
                generator.videoComposition = result.videoComposition
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let (image, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out)
                log("rendered \(image.width)x\(image.height)")
            } catch {
                log("FAIL \(error)")
            }
            exit(0)
        }
    }

    /// `Takes --export <xxx.takes> <out.mp4> [fps]`: exports with the saved edit (after loudness analysis).
    static func exportProject(bundle: URL, to out: URL, fps: Int = 30) {
        Task { @MainActor in
            do {
                let model = try EditorModel(bundle: ProjectBundle(url: bundle))
                for _ in 0..<600 where !model.isReady || model.isMeasuringLoudness || (model.meta.hasMic && model.edit.micAutoGain == nil) {
                    await wait(0.1)
                }
                log(String(format: "mic auto gain %.1f dB", model.edit.micAutoGain ?? -1))
                try? FileManager.default.removeItem(at: out)
                try await Exporter.export(model: model, options: ExportOptions(resolution: .p720, fps: fps), to: out) { _ in }
                log("exported")
            } catch {
                log("FAIL \(error)")
            }
            exit(0)
        }
    }

    private static func log(_ s: String) {
        print("[selftest] \(s)")
        fflush(stdout)
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @MainActor
    private static func body(_ out: URL) async throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let content = try await ShareableContent.fetch()
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { throw CocoaError(.featureUnsupported) }

        // 1. Record: take 1, pause, redo while recording, redo while paused, final take.
        let session = RecordingSession()
        session.folderOverride = out
        session.countdownOverride = 0
        var finished: ProjectBundle?
        session.onFinished = { finished = $0 }
        await session.start(.area(display, CGRect(x: 80, y: 80, width: 960, height: 600)))
        if let e = session.lastError { throw NSError(domain: e, code: 1) }
        log("recording phase=\(session.phase)")
        // Sweep the pointer across the recorded area so the cursor track has data.
        for i in 0..<40 {
            CGWarpMouseCursorPosition(CGPoint(x: display.frame.minX + 200 + Double(i) * 15, y: display.frame.minY + 200 + Double(i) * 6))
            await wait(0.05)
        }
        session.pause()
        log("paused takes=\(session.takeCount) elapsed=\(String(format: "%.2f", session.elapsed))")
        await wait(1)
        session.resume()
        await wait(1.2)
        session.redoTake()
        log("redo while recording -> phase=\(session.phase)")
        await wait(1.5)
        session.pause()
        await wait(0.6)
        log("before paused redo takes=\(session.takeCount)")
        session.redoTake()
        await wait(0.6)
        log("after paused redo takes=\(session.takeCount)")
        session.resume()
        await wait(1.5)
        session.stop()
        for _ in 0..<100 where finished == nil { await wait(0.1) }
        guard let bundle = finished else { throw NSError(domain: "recording did not finish", code: 2) }
        let meta = try bundle.readMeta()
        log("segments=\(meta.segments.map { "\($0.file) \(String(format: "%.2f", $0.duration))s" }) size=\(meta.width)x\(meta.height) mic=\(meta.hasMic) sys=\(meta.hasSystemAudio)")
        log("events=\(bundle.readEvents().count) thumbnail=\(FileManager.default.fileExists(atPath: bundle.thumbnailURL.path))")

        // 2. Edit: open the editor model and add one of everything.
        let model = try EditorModel(bundle: bundle)
        for _ in 0..<100 where !model.isReady { await wait(0.1) }
        log("editor ready=\(model.isReady) duration=\(String(format: "%.2f", model.duration)) source=\(String(format: "%.2f", model.timeline.sourceDuration))")
        // Clip editing: split, delete, trim, reset.
        let before = model.duration
        model.seek(comp: 1.0)
        model.splitAtPlayhead()
        let afterSplit = model.edit.clips.count
        if let first = model.edit.clips.first { model.deleteClip(first.id) }
        let afterDelete = model.duration
        if let first = model.edit.clips.first { model.trimClip(first.id, end: first.end - 0.3) }
        log(String(format: "clips: before=%.2f split->%d clips, delete first -> %.2f, trim -> %.2f", before, afterSplit, afterDelete, model.duration))
        model.resetClips()
        log(String(format: "reset -> %d clips %.2f", model.edit.clips.count, model.duration))
        // Range cut: one inside a clip, one across the boundary between two takes.
        let full = model.duration
        model.range = 0.5...1.2
        model.deleteRange()
        let boundary = model.timeline.entries.first?.compEnd ?? 1
        model.range = (boundary - 0.3)...(boundary + 0.3)
        model.deleteRange()
        log(String(format: "range cuts: %.2f -> %.2f (expected %.2f), %d clips", full, model.duration, full - 1.3, model.edit.clips.count))
        model.resetClips()

        var edit = model.edit
        edit.zooms = [ZoomRegion(start: 0.6, duration: 1.4, scale: 2, mode: .fixed, center: NormPoint(x: 0.3, y: 0.3), isAuto: false)]
        var box = Annotation(kind: .box, start: 0.1, duration: 3)
        box.rect = NormRect(x: 0.55, y: 0.1, w: 0.3, h: 0.12)
        box.step = 1
        var arrow = Annotation(kind: .arrow, start: 0.1, duration: 3)
        arrow.points = [StrokePoint(x: 0.2, y: 0.8, t: 0), StrokePoint(x: 0.5, y: 0.55, t: 0)]
        arrow.color = .yellow
        var text = Annotation(kind: .text, start: 0.1, duration: 3)
        text.rect = NormRect(x: 0.05, y: 0.05, w: 0.2, h: 0.07)
        text.text = "第一步：打开设置"
        text.color = .yellow
        var spot = Annotation(kind: .spotlight, start: 2.4, duration: 1.5)
        spot.rect = NormRect(x: 0.3, y: 0.3, w: 0.4, h: 0.3)
        edit.annotations = [box, arrow, text, spot]
        edit.blurs = [BlurRegion(start: 0, duration: 5, rect: NormRect(x: 0.4, y: 0.3, w: 0.45, h: 0.3), style: .mosaic)]
        model.edit = edit
        await wait(0.5)

        // 3. Render stills through the real compositor.
        let state = model.renderState
        let builder = CompositionBuilder(bundle: bundle, meta: meta, assets: model.assets, cameraAssets: model.cameraAssets, voiceoverAssets: model.voiceoverAssets)
        let size = state.canvasSize(longSide: 1600)
        let result = try await builder.build(timeline: model.timeline, box: RenderStateBox(state), renderSize: size, fps: 30, edit: model.edit)
        // A hole in the screen track means a frame with no source, which fails playback and export.
        let holes = result.composition.tracks(withMediaType: .video).first?.segments.filter(\.isEmpty).count ?? 0
        log("screen track holes=\(holes)")
        if holes > 0 { throw NSError(domain: "composition has holes in its screen track", code: 3) }
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for t in [0.3, 1.3, 1.95, 2.9] {
            let (image, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let url = out.appendingPathComponent(String(format: "frame-%.1f.png", t))
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            log("frame \(t) -> \(image.width)x\(image.height)")
        }

        // 4. Export MP4 and GIF.
        let mp4 = out.appendingPathComponent("export.mp4")
        try await Exporter.export(model: model, options: ExportOptions(format: .mp4, resolution: .p720, fps: 30), to: mp4) { _ in }
        let mp4Duration = try await AVURLAsset(url: mp4).load(.duration).seconds
        log("mp4 duration=\(String(format: "%.2f", mp4Duration)) bytes=\((try? mp4.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)")
        let gif = out.appendingPathComponent("export.gif")
        try await Exporter.export(model: model, options: ExportOptions(format: .gif, gifWidth: 640, gifFPS: 10), to: gif) { _ in }
        log("gif bytes=\((try? gif.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)")

        // 5. Privacy scan (counts only; contents stay local).
        let findings = await SensitiveDetector.scan(model: model) { _ in }
        log("sensitive findings=\(findings.count) kinds=\(Set(findings.map(\.kind.rawValue)).sorted())")
        if let blur = model.edit.blurs.first {
            let frames = await BlurTracker.track(blur, model: model) { _ in }
            log("tracker keyframes=\(frames?.count ?? -1)")
        }
        model.saveNow()

        // 6. Window capture.
        if let window = ShareableContent.pickableWindows(content).first {
            let ws = RecordingSession()
            ws.folderOverride = out
            ws.countdownOverride = 0
            var done: ProjectBundle?
            ws.onFinished = { done = $0 }
            await ws.start(.window(window))
            await wait(1.5)
            ws.stop()
            for _ in 0..<100 where done == nil { await wait(0.1) }
            let m = try done.map { try $0.readMeta() }
            log("window capture '\(window.owningApplication?.applicationName ?? "?")' -> \(m.map { "\($0.width)x\($0.height) takes=\($0.segments.count) \(String(format: "%.2f", $0.duration))s" } ?? "failed")")
        }
    }
}
