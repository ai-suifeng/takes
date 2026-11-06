import AVFoundation
import AppKit
import Observation

enum EditorSelection: Hashable {
    case none
    case zoom(UUID)
    case annotation(UUID)
    case blur(UUID)
    case clip(UUID)
    case voiceover(UUID)
}

/// A cut at the playhead: split in two, or drop one side.
enum PlayheadCut { case split, keepRight, keepLeft }

enum CanvasTool: String, CaseIterable {
    case select, box, spotlight, magnify, arrow, rect, text, blur

    var label: String {
        switch self {
        case .select: "选择"
        case .blur: "打码"
        default: annotationKind!.label
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .blur: "eye.slash"
        default: annotationKind!.symbol
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .box: .box
        case .spotlight: .spotlight
        case .magnify: .magnify
        case .arrow: .arrow
        case .rect: .rect
        case .text: .text
        default: nil
        }
    }
}

enum InspectorTab: String, CaseIterable {
    case style, cursor, zoom, annotations, privacy, media

    var label: String {
        switch self {
        case .style: "画面"
        case .cursor: "光标"
        case .zoom: "缩放"
        case .annotations: "标注"
        case .privacy: "打码"
        case .media: "音视频"
        }
    }

    var symbol: String {
        switch self {
        case .style: "paintpalette"
        case .cursor: "cursorarrow.motionlines"
        case .zoom: "plus.magnifyingglass"
        case .annotations: "pencil.and.outline"
        case .privacy: "eye.slash"
        case .media: "waveform"
        }
    }
}

@Observable
final class EditorModel {
    let bundle: ProjectBundle
    private(set) var meta: ProjectMeta
    var edit: EditDocument {
        didSet { editChanged(from: oldValue) }
    }

    let player = AVPlayer()
    private(set) var timeline = Timeline()
    private(set) var renderState: RenderState
    /// Playhead in composition time.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var isMeasuringLoudness = false
    /// Timeline item under the mouse; ⌫ deletes it without clicking first.
    var hovered: EditorSelection = .none
    /// Output-time span picked by dragging across the clips (or with I / O); ⌫ cuts it out.
    var range: ClosedRange<Double>?
    /// Output time shown in the preview while the mouse hovers over the timeline; the playhead stays put.
    private(set) var skimTime: Double?
    var skimEnabled = true
    var playbackRate: Float = 1 {
        didSet { player.defaultRate = playbackRate; if player.rate != 0 { player.rate = playbackRate } }
    }
    @ObservationIgnored private var rangeEndObserver: Any?
    var selection: EditorSelection = .none {
        didSet {
            if selection != oldValue, case .zoom = selection { refreshRenderState() }
            else if case .zoom = oldValue, selection != oldValue { refreshRenderState() }
        }
    }
    var tool: CanvasTool = .select
    var inspectorTab: InspectorTab = .style
    var timelineZoom: Double = 1
    /// Items being dragged on the canvas are drawn by the overlay, not the renderer.
    var canvasEditingID: UUID? { didSet { if canvasEditingID != oldValue { refreshRenderState() } } }
    var statusMessage: String?

    @ObservationIgnored let box: RenderStateBox
    @ObservationIgnored private(set) var assets: [Int: AVURLAsset] = [:]
    @ObservationIgnored private(set) var cameraAssets: [Int: AVURLAsset] = [:]
    @ObservationIgnored private var voiceoverAssetCache: [String: AVURLAsset] = [:]
    @ObservationIgnored private var durations: [Int: Double] = [:]
    @ObservationIgnored private var rawMoves: [(t: Double, x: Double, y: Double)] = []
    @ObservationIgnored private(set) var clickTimes: [(t: Double, p: NormPoint)] = []
    @ObservationIgnored private var keyPresses: [(t: Double, key: String)] = []
    @ObservationIgnored private var cursorTrack = CursorTrack()
    @ObservationIgnored private var cursorKey: Double = -1
    @ObservationIgnored private var cameraPath = CameraPath()
    @ObservationIgnored private var cameraKey: [ZoomRegion]? = nil
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemStatus: NSKeyValueObservation?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var undoStack: [EditDocument] = []
    @ObservationIgnored private var redoStack: [EditDocument] = []
    @ObservationIgnored private var lastUndoPush = Date.distantPast
    @ObservationIgnored private var applyingUndo = false
    private(set) var filmstrips: [Int: [CGImage]] = [:]
    private(set) var waveforms: [Int: Waveform] = [:]
    /// Waveform of each voiceover file, on the file's own timeline.
    private(set) var voiceoverWaveforms: [String: Waveform] = [:]
    private(set) var voiceoverPhase: VoiceoverPhase = .idle
    /// Output time where the running recording began, and its levels so far.
    private(set) var voiceoverStart: Double = 0
    private(set) var voiceoverLevels: [(t: Double, level: Float)] = []
    @ObservationIgnored private var voiceoverRecorder: VoiceoverRecorder?
    @ObservationIgnored private var rateBeforeVoiceover: Float = 1
    @ObservationIgnored private var rebuildAfterVoiceover = false

    static let previewLongSide = 1920.0

    init(bundle: ProjectBundle) throws {
        self.bundle = bundle
        let meta = try bundle.readMeta()
        self.meta = meta
        let edit = bundle.readEdit() ?? EditDocument()
        self.edit = edit
        let state = RenderState(edit: edit, meta: meta, timeline: Timeline(), cursor: CursorTrack(), camera: CameraPath(),
                                clicks: [], keys: [])
        renderState = state
        box = RenderStateBox(state)
        _ = AnnotationPainter.cursorImage

        for seg in meta.segments {
            assets[seg.index] = AVURLAsset(url: bundle.segmentURL(seg.file))
            if let cam = seg.cameraFile { cameraAssets[seg.index] = AVURLAsset(url: bundle.segmentURL(cam)) }
        }
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self else { return }
            self.isPlaying = self.player.rate != 0
            // While skimming the player shows the hovered frame, not the playhead.
            if self.skimTime != nil, self.player.rate == 0 { return }
            self.currentTime = t.seconds
            if self.voiceoverPhase == .recording, t.seconds >= self.duration - 0.05 { self.toggleVoiceover() }
        }
        Task { @MainActor in await self.load() }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        for seg in meta.segments {
            guard let asset = assets[seg.index] else { continue }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let range = try? await track.load(.timeRange) {
                durations[seg.index] = range.duration.seconds
            } else if let d = try? await asset.load(.duration) {
                durations[seg.index] = d.seconds
            }
        }
        var e = edit
        if e.clips.isEmpty {
            // One clip per take, carrying over trims from older documents.
            e.clips = meta.segments.compactMap { seg in
                let full = durations[seg.index] ?? seg.duration
                let old = e.segments.first { $0.index == seg.index } ?? SegmentEdit(index: seg.index)
                guard old.enabled else { return nil }
                return Clip(segment: seg.index, start: old.trimStart, end: max(old.trimStart, full - old.trimEnd))
            }
            e.segments = []
        }
        timeline = Timeline(segments: meta.segments, durations: durations, clips: e.clips)
        loadEvents()

        if bundle.readEdit() == nil {
            // First open: adopt live annotations and generate auto zooms.
            e.annotations = bundle.readLiveAnnotations().map { live in
                var a = live.annotation
                a.start = timeline.sourceTime(segment: live.seg, local: live.t)
                return a
            }
            if e.autoZoom {
                e.zooms = AutoZoom.regions(clicks: clickTimes.map(\.t), scale: e.defaultZoomScale,
                                           duration: timeline.sourceDuration)
            }
        }
        applyingUndo = true
        edit = e
        applyingUndo = false
        refreshRenderState()
        await rebuildPlayerItem()
        isReady = true
        saveNow()
        Task { await self.loadFilmstrips() }
        if meta.hasMic || meta.hasSystemAudio { Task { await self.loadWaveforms() } }
        if meta.hasMic, edit.micAutoGain == nil { Task { await self.measureLoudness() } }
        Task { await self.loadVoiceoverWaveforms() }
    }

    private func loadEvents() {
        let events = bundle.readEvents()
        rawMoves = []
        clickTimes = []
        keyPresses = []
        for e in events.sorted(by: { timeline.sourceTime(segment: $0.seg, local: $0.t) < timeline.sourceTime(segment: $1.seg, local: $1.t) }) {
            let t = timeline.sourceTime(segment: e.seg, local: e.t)
            switch e.kind {
            case .move, .up:
                rawMoves.append((t, e.x, e.y))
            case .down, .rightDown:
                rawMoves.append((t, e.x, e.y))
                clickTimes.append((t, NormPoint(x: e.x, y: e.y)))
            case .key:
                if let k = e.key { keyPresses.append((t, k)) }
            }
        }
    }

    @MainActor
    private func measureLoudness() async {
        isMeasuringLoudness = true
        let takes = meta.segments.compactMap { assets[$0.index] }
        let micIndex = meta.hasSystemAudio ? 1 : 0
        let analysis = await Task.detached(priority: .utility) {
            await AudioLeveling.analyze(assets: takes, micTrackIndex: micIndex)
        }.value
        isMeasuringLoudness = false
        // Not an edit of the user's, so keep it out of the undo history.
        applyingUndo = true
        edit.micNoiseFloor = analysis?.noiseFloor
        edit.micAutoGain = analysis?.gain ?? 0
        applyingUndo = false
    }

    @MainActor
    private func loadWaveforms() async {
        let hasSystem = meta.hasSystemAudio, hasMic = meta.hasMic
        for seg in meta.segments {
            guard let asset = assets[seg.index] else { continue }
            let wave = await Task.detached(priority: .utility) {
                await Waveform.load(asset: asset, hasSystem: hasSystem, hasMic: hasMic)
            }.value
            waveforms[seg.index] = wave
        }
    }

    /// Every voiceover file in use. Kept for the model's lifetime, so undo and compositions can rely on them.
    var voiceoverAssets: [String: AVURLAsset] {
        for file in Set(edit.voiceovers.map(\.file)) where voiceoverAssetCache[file] == nil {
            voiceoverAssetCache[file] = AVURLAsset(url: bundle.voiceoverURL(file))
        }
        return voiceoverAssetCache
    }

    @MainActor
    private func loadVoiceoverWaveforms() async {
        for file in Set(edit.voiceovers.map(\.file)) where voiceoverWaveforms[file] == nil {
            let asset = AVURLAsset(url: bundle.voiceoverURL(file))
            voiceoverWaveforms[file] = await Task.detached(priority: .utility) {
                await Waveform.load(asset: asset, hasSystem: false, hasMic: true)
            }.value
        }
    }

    /// Gain and gate the voiceover waveform is drawn with, matching what is heard.
    var voiceoverWaveformGain: (gain: Float, gate: Float) {
        let auto = edit.normalizeAudio ? AudioLeveling.dbToGain(edit.voiceoverAutoGain ?? 0) : 1
        return (auto * Float(edit.voiceoverVolume), AudioLeveling.voiceoverGateLevel(for: edit))
    }

    /// Gains the waveform is drawn with, matching what is heard.
    var waveformGains: (mic: Float, system: Float, gate: Float) {
        let auto = edit.normalizeAudio ? AudioLeveling.dbToGain(edit.micAutoGain ?? 0) : 1
        return (auto * Float(edit.micVolume), Float(edit.systemVolume), micGateLevel)
    }

    /// Noise-gate threshold for the mic (linear, before gain); 0 when the gate is off.
    var micGateLevel: Float { AudioLeveling.gateLevel(for: edit) }

    @MainActor
    private func loadFilmstrips() async {
        for seg in meta.segments {
            guard let asset = assets[seg.index] else { continue }
            let duration = durations[seg.index] ?? seg.duration
            let count = max(2, min(40, Int(duration / 1.5)))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 200, height: 200)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            var images: [CGImage] = []
            for i in 0..<count {
                let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                if let (img, _) = try? await generator.image(at: t) { images.append(img) }
            }
            filmstrips[seg.index] = images
        }
    }

    // MARK: - Render state

    private func refreshRenderState() {
        if cursorKey != edit.cursor.smoothing || cursorTrack.xs.isEmpty && !rawMoves.isEmpty {
            cursorTrack = CursorTrack(moves: rawMoves, duration: timeline.sourceDuration, smoothing: edit.cursor.smoothing)
            cursorKey = edit.cursor.smoothing
            cameraKey = nil
        }
        // While a zoom is selected the preview shows the whole frame, so its area can be adjusted on the canvas.
        let zooms = edit.zooms.filter { .zoom($0.id) != selection }
        if cameraKey != zooms {
            cameraPath = CameraPath(zooms: zooms, cursor: cursorTrack, duration: timeline.sourceDuration)
            cameraKey = zooms
        }
        let state = RenderState(edit: edit, meta: meta, timeline: timeline, cursor: cursorTrack, camera: cameraPath,
                                clicks: clickTimes, keys: keyPresses,
                                hiddenIDs: canvasEditingID.map { [$0] } ?? [])
        renderState = state
        box.state = state
        redrawIfPaused()
    }

    private func redrawIfPaused() {
        guard !isPlaying, player.currentItem != nil else { return }
        let t = player.currentTime()
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func editChanged(from old: EditDocument) {
        guard old != edit else { return }
        if !applyingUndo {
            if Date().timeIntervalSince(lastUndoPush) > 0.6 { undoStack.append(old) }
            lastUndoPush = Date()
            redoStack = []
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        let timelineChanged = old.clips != edit.clips
        if timelineChanged {
            timeline = Timeline(segments: meta.segments, durations: durations, clips: edit.clips)
        }
        refreshRenderState()
        if timelineChanged || old.style.aspect != edit.style.aspect || old.style.background.kind != edit.style.background.kind
            || old.micVolume != edit.micVolume || old.systemVolume != edit.systemVolume
            || old.normalizeAudio != edit.normalizeAudio || old.micAutoGain != edit.micAutoGain
            || old.voiceovers != edit.voiceovers || old.voiceoverVolume != edit.voiceoverVolume
            || old.voiceoverAutoGain != edit.voiceoverAutoGain || old.voiceoverNoiseFloor != edit.voiceoverNoiseFloor {
            scheduleRebuild()
        }
        scheduleSave()
    }

    private func scheduleRebuild() {
        // A new player item would pull the running recording's clock out from under it.
        if voiceoverPhase != .idle {
            rebuildAfterVoiceover = true
            return
        }
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self.rebuildPlayerItem()
        }
    }

    @MainActor
    private func rebuildPlayerItem() async {
        let builder = CompositionBuilder(bundle: bundle, meta: meta, assets: assets, cameraAssets: cameraAssets, voiceoverAssets: voiceoverAssets)
        let size = renderState.canvasSize(longSide: min(Self.previewLongSide, renderState.nativeLongSide))
        do {
            let result = try await builder.build(timeline: timeline, box: box, renderSize: size, fps: 60, edit: edit)
            let sourceNow = timeline.sourceTime(currentTime)
            let item = AVPlayerItem(asset: result.composition)
            item.videoComposition = result.videoComposition
            item.audioMix = result.audioMix
            let wasPlaying = isPlaying
            itemStatus = item.observe(\.status) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let error = item.error as NSError?
                NSLog("[editor] player item failed: %@ underlying: %@", "\(String(describing: error))",
                      "\(String(describing: error?.userInfo[NSUnderlyingErrorKey]))")
                DispatchQueue.main.async { self?.statusMessage = "预览失败：\(error?.localizedDescription ?? "未知错误")" }
            }
            player.replaceCurrentItem(with: item)
            let resume = timeline.compTime(sourceNow)
            await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = resume
            if wasPlaying { player.play() }
        } catch {
            statusMessage = "无法生成预览：\(error.localizedDescription)"
        }
    }

    // MARK: - Playback

    var duration: Double { timeline.duration }
    var sourceTime: Double { timeline.sourceTime(currentTime) }

    func togglePlay() {
        if voiceoverPhase != .idle {
            toggleVoiceover()
            return
        }
        stopAtRangeEnd(nil)
        if skimTime != nil { skim(to: nil) }
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.05 { seek(comp: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(comp: Double) {
        skimTime = nil
        let t = comp.clamped(0, max(0, duration - 0.001))
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(source: Double) {
        seek(comp: timeline.compTime(source))
    }

    /// Shows the frame at `comp` without moving the playhead; nil goes back to the playhead.
    func skim(to comp: Double?) {
        guard skimEnabled || comp == nil, player.rate == 0, voiceoverPhase == .idle else { return }
        if let comp {
            let t = comp.clamped(0, max(0, duration - 0.001))
            skimTime = t
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else if skimTime != nil {
            skimTime = nil
            player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Plays just the selected range, to check what is about to be cut.
    func playRange() {
        guard let r = range else { return }
        seek(comp: r.lowerBound)
        stopAtRangeEnd(r.upperBound)
        player.play()
        isPlaying = true
    }

    private func stopAtRangeEnd(_ end: Double?) {
        if let rangeEndObserver { player.removeTimeObserver(rangeEndObserver) }
        rangeEndObserver = nil
        guard let end else { return }
        rangeEndObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))],
                                                          queue: .main) { [weak self] in
            self?.player.pause()
            self?.isPlaying = false
            self?.stopAtRangeEnd(nil)
        }
    }

    func step(frames: Int) {
        player.pause()
        isPlaying = false
        seek(comp: currentTime + Double(frames) / 60)
    }

    // MARK: - Undo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard voiceoverPhase == .idle, let prev = undoStack.popLast() else { return }
        range = nil
        redoStack.append(edit)
        applyingUndo = true
        edit = prev
        applyingUndo = false
    }

    func redo() {
        guard voiceoverPhase == .idle, let next = redoStack.popLast() else { return }
        range = nil
        undoStack.append(edit)
        applyingUndo = true
        edit = next
        applyingUndo = false
    }

    // MARK: - Voiceover

    /// R, the 配音 button, and space while recording: start, cancel the countdown, or finish.
    func toggleVoiceover() {
        switch voiceoverPhase {
        case .idle: Task { @MainActor in await self.startVoiceover() }
        case .countdown, .preparing: cancelVoiceover()
        case .recording: Task { @MainActor in await self.stopVoiceover() }
        case .finishing: break
        }
    }

    /// Starts the mic, counts down, then plays from the playhead at normal speed and records over it.
    @MainActor
    private func startVoiceover() async {
        guard isReady, voiceoverPhase == .idle, duration > 0.2 else { return }
        voiceoverPhase = .preparing
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            Permissions.shared.refresh()
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            voiceoverPhase = .idle
            statusMessage = "没有麦克风权限，请在系统设置里允许 Takes 使用麦克风"
            Permissions.shared.requestMicrophone()
            return
        }
        stopAtRangeEnd(nil)
        skim(to: nil)
        player.pause()
        isPlaying = false
        range = nil
        tool = .select
        statusMessage = nil
        if currentTime >= duration - 0.05 { seek(comp: 0) }

        let recorder: VoiceoverRecorder
        do {
            try FileManager.default.createDirectory(at: bundle.voiceoverDir, withIntermediateDirectories: true)
            let file = "voiceover-\(UUID().uuidString.prefix(8)).m4a"
            recorder = try VoiceoverRecorder(url: bundle.voiceoverURL(file))
            voiceoverRecorder = recorder
            try await recorder.startCapture(deviceID: AppSettings.shared.micDeviceID)
        } catch {
            voiceoverRecorder?.cancel()
            voiceoverRecorder = nil
            voiceoverPhase = .idle
            statusMessage = "无法启动麦克风：\(error.localizedDescription)"
            return
        }
        await rebuildTask?.value
        for n in [3, 2, 1] {
            guard voiceoverRecorder === recorder else { return }
            voiceoverPhase = .countdown(n)
            try? await Task.sleep(for: .seconds(1))
        }
        guard voiceoverRecorder === recorder, let timebase = player.currentItem?.timebase else {
            if voiceoverRecorder === recorder { cancelVoiceover() }
            return
        }
        rateBeforeVoiceover = playbackRate
        playbackRate = 1
        // The speakers would otherwise leak into the mic.
        player.isMuted = true
        voiceoverStart = currentTime
        voiceoverLevels = []
        recorder.onLevel = { [weak self] t, level in self?.voiceoverLevels.append((t, level)) }
        recorder.listen(to: timebase)
        player.playImmediately(atRate: 1)
        isPlaying = true
        voiceoverPhase = .recording
    }

    /// Drops a recording that has not started yet.
    private func cancelVoiceover() {
        voiceoverRecorder?.cancel()
        voiceoverRecorder = nil
        voiceoverPhase = .idle
    }

    @MainActor
    private func stopVoiceover() async {
        guard voiceoverPhase == .recording, let recorder = voiceoverRecorder else { return }
        voiceoverPhase = .finishing
        player.pause()
        isPlaying = false
        let runs = VoiceoverLayout.trimmed(await recorder.stop(), from: voiceoverStart)
        voiceoverRecorder = nil
        player.isMuted = false
        playbackRate = rateBeforeVoiceover
        await commitVoiceover(file: recorder.url.lastPathComponent, runs: runs)
        voiceoverLevels = []
        voiceoverPhase = .idle
        if rebuildAfterVoiceover {
            rebuildAfterVoiceover = false
            scheduleRebuild()
        }
        seek(comp: voiceoverStart)
        saveNow()
    }

    /// Turns a finished recording into pieces on the timeline. New narration replaces what it records over.
    @MainActor
    func commitVoiceover(file: String, runs: [VoiceoverRun]) async {
        let added = VoiceoverLayout.pieces(file: file, runs: runs, timeline: timeline)
        let total = added.reduce(0) { $0 + $1.duration }
        guard total > 0.1 else {
            try? FileManager.default.removeItem(at: bundle.voiceoverURL(file))
            statusMessage = "没有录到声音"
            return
        }
        var e = edit
        e.voiceovers = VoiceoverLayout.overlaying(added, on: e.voiceovers)
        let takes = Set(e.voiceovers.map(\.file)).map { AVURLAsset(url: bundle.voiceoverURL($0)) }
        let analysis = await Task.detached(priority: .userInitiated) {
            await AudioLeveling.analyze(assets: takes, micTrackIndex: 0)
        }.value
        e.voiceoverAutoGain = analysis?.gain ?? 0
        e.voiceoverNoiseFloor = analysis?.noiseFloor
        // The whole recording is one undo step, measured gain included.
        lastUndoPush = .distantPast
        edit = e
        statusMessage = String(format: "已录入 %.1f 秒配音，按空格回听，⌘Z 撤销", total)
        await loadVoiceoverWaveforms()
    }

    /// Finishes a running recording when the window closes, and keeps it.
    func finishVoiceoverOnClose() {
        switch voiceoverPhase {
        case .recording: toggleVoiceover()
        case .countdown, .preparing: cancelVoiceover()
        case .idle, .finishing: break
        }
    }

    /// Whether the selected output range has narration in it.
    var rangeHasVoiceover: Bool {
        guard let r = range else { return false }
        return VoiceoverLayout.placements(edit.voiceovers, entries: timeline.entries)
            .contains { $0.at < r.upperBound && $0.at + $0.duration > r.lowerBound }
    }

    /// Removes the narration in the selected output range and keeps the picture.
    func deleteVoiceoverInRange() {
        guard let r = range else { return }
        var pieces = edit.voiceovers
        for e in timeline.entries {
            let a = max(r.lowerBound, e.compStart), b = min(r.upperBound, e.compEnd)
            guard b > a else { continue }
            pieces = VoiceoverLayout.removing(start: e.sourceStart + a - e.compStart, end: e.sourceStart + b - e.compStart, from: pieces)
        }
        edit.voiceovers = pieces
        range = nil
        selection = .none
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        try? bundle.writeEdit(edit)
    }

    func renameProject(_ name: String) {
        meta.name = name
        try? bundle.writeMeta(meta)
    }

    func recordExport(_ url: URL) {
        meta.exportedFiles.append(url.path)
        try? bundle.writeMeta(meta)
    }

    // MARK: - Editing helpers

    func takeDuration(_ index: Int) -> Double { durations[index] ?? meta.segments.first { $0.index == index }?.duration ?? 0 }

    func takeNumber(_ index: Int) -> Int { (meta.segments.firstIndex { $0.index == index } ?? 0) + 1 }

    // MARK: - Clips

    /// Timeline entry under the playhead.
    var entryAtPlayhead: Timeline.Entry? {
        timeline.entries.first { currentTime >= $0.compStart && currentTime < $0.compEnd } ?? timeline.entries.last
    }

    /// Splits the clip under the playhead in two (剪映's "分割").
    func splitAtPlayhead() {
        if cutSelectedItem(.split) { return }
        let t = currentTime
        guard let entry = timeline.entries.first(where: { t > $0.compStart + 0.05 && t < $0.compEnd - 0.05 }),
              let i = edit.clips.firstIndex(where: { $0.id == entry.clipID }) else {
            statusMessage = "把播放头移到片段中间再分割"
            return
        }
        let clip = edit.clips[i]
        let cut = clip.start + (t - entry.compStart)
        var left = clip, right = clip
        left.end = cut
        right.id = UUID()
        right.start = cut
        edit.clips.replaceSubrange(i...i, with: [left, right])
        selection = .clip(right.id)
        statusMessage = nil
    }

    /// 剪映's 向左裁剪 / 向右裁剪: drop the part of the clip under the playhead that lies left (or right) of it.
    func trimAtPlayhead(keepRight: Bool) {
        if cutSelectedItem(keepRight ? .keepRight : .keepLeft) { return }
        let t = currentTime
        guard let entry = timeline.entries.first(where: { t > $0.compStart + 0.05 && t < $0.compEnd - 0.05 }),
              let i = edit.clips.firstIndex(where: { $0.id == entry.clipID }) else {
            statusMessage = "把播放头移到片段中间再裁剪"
            return
        }
        let cut = edit.clips[i].start + (t - entry.compStart)
        if keepRight {
            edit.clips[i].start = cut
            seek(comp: entry.compStart)
        } else {
            edit.clips[i].end = cut
            seek(comp: max(entry.compStart, t - 0.02))
        }
        selection = .clip(edit.clips[i].id)
        statusMessage = nil
    }

    /// Name of the selected track item that S, Q and W act on instead of the video.
    var cutTargetName: String? {
        switch selection {
        case .zoom: "缩放"
        case .annotation: "标注"
        case .blur: "打码"
        case .voiceover: "配音"
        case .clip, .none: nil
        }
    }

    /// Applies a cut to the selected track item. False when no such item is selected, so the cut goes to the
    /// video. With one selected the cut never falls through: that would silently remove picture.
    private func cutSelectedItem(_ cut: PlayheadCut) -> Bool {
        switch selection {
        case .zoom(let id): cutItem(\.zooms, id: id, cut, select: EditorSelection.zoom)
        case .annotation(let id): cutItem(\.annotations, id: id, cut, select: EditorSelection.annotation)
        case .blur(let id): cutItem(\.blurs, id: id, cut, select: EditorSelection.blur)
        case .voiceover(let id): cutItem(\.voiceovers, id: id, cut, select: EditorSelection.voiceover)
        case .clip, .none: return false
        }
        return true
    }

    private func cutItem<T: TimelineItem & Identifiable>(_ path: WritableKeyPath<EditDocument, [T]>, id: UUID, _ cut: PlayheadCut,
                                                          select: (UUID) -> EditorSelection) where T.ID == UUID {
        let t = sourceTime
        guard let i = edit[keyPath: path].firstIndex(where: { $0.id == id }) else { return }
        let item = edit[keyPath: path][i]
        guard t > item.start + 0.05, t < item.end - 0.05 else {
            statusMessage = "把播放头移到选中的\(cutTargetName ?? "内容")中间再操作"
            return
        }
        var left = item, right = item
        left.trim(start: item.start, end: t)
        right.trim(start: t, end: item.end)
        switch cut {
        case .split:
            right.id = UUID()
            edit[keyPath: path].replaceSubrange(i...i, with: [left, right])
            selection = select(right.id)
        case .keepRight:
            edit[keyPath: path][i] = right
        case .keepLeft:
            edit[keyPath: path][i] = left
        }
        statusMessage = nil
    }

    /// Moves a voiceover edge, limited by what was recorded there and by the pieces next to it.
    func trimVoiceover(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let i = edit.voiceovers.firstIndex(where: { $0.id == id }) else { return }
        var piece = edit.voiceovers[i]
        let others = edit.voiceovers.filter { $0.id != id }
        var newStart = piece.start, newEnd = piece.end
        if let start {
            let floor = max(piece.sourceMin ?? piece.start, others.filter { $0.end <= piece.start + 0.001 }.map(\.end).max() ?? 0)
            newStart = start.clamped(min(floor, piece.start), piece.end - 0.2)
        }
        if let end {
            let ceiling = min(piece.sourceMax ?? piece.end, others.filter { $0.start >= piece.end - 0.001 }.map(\.start).min() ?? .infinity)
            newEnd = end.clamped(piece.start + 0.2, max(ceiling, piece.end))
        }
        piece.trim(start: newStart, end: newEnd)
        edit.voiceovers[i] = piece
    }

    /// I: the range starts at the playhead (and runs to the end until O is pressed).
    func markIn() {
        let t = currentTime
        if let r = range, t < r.upperBound - 0.05 { range = t...r.upperBound } else { range = t...duration }
    }

    /// O: the range ends at the playhead.
    func markOut() {
        let t = currentTime
        if let r = range, t > r.lowerBound + 0.05 { range = r.lowerBound...t } else { range = 0...t }
    }

    /// Cuts the selected output range out of every clip it touches; what follows moves up.
    func deleteRange() {
        guard let r = range, r.upperBound - r.lowerBound > 0.01 else { range = nil; return }
        var result: [Clip] = []
        for clip in edit.clips {
            guard let e = timeline.entries.first(where: { $0.clipID == clip.id }) else { result.append(clip); continue }
            let a = max(r.lowerBound, e.compStart), b = min(r.upperBound, e.compEnd)
            guard b > a else { result.append(clip); continue }
            let cutStart = clip.start + (a - e.compStart), cutEnd = clip.start + (b - e.compStart)
            let keepsLeft = cutStart - clip.start > 0.05
            if keepsLeft { var left = clip; left.end = cutStart; result.append(left) }
            if clip.end - cutEnd > 0.05 {
                var right = clip
                if keepsLeft { right.id = UUID() }
                right.start = cutEnd
                result.append(right)
            }
        }
        guard !result.isEmpty else {
            statusMessage = "至少要保留一点内容"
            return
        }
        edit.clips = result
        range = nil
        selection = .none
        seek(comp: r.lowerBound)
        statusMessage = String(format: "已删除 %.1f 秒，⌘Z 撤销", r.upperBound - r.lowerBound)
    }

    func deleteClip(_ id: UUID) {
        guard edit.clips.count > 1 else {
            statusMessage = "至少要保留一个片段"
            return
        }
        edit.clips.removeAll { $0.id == id }
        if selection == .clip(id) { selection = .none }
        seek(comp: currentTime)
    }

    /// Moves a clip edge, limited by the take's length and by neighbouring clips from the same take.
    func trimClip(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let i = edit.clips.firstIndex(where: { $0.id == id }) else { return }
        var clip = edit.clips[i]
        let siblings = edit.clips.filter { $0.segment == clip.segment && $0.id != id }
        let full = takeDuration(clip.segment)
        if let start {
            let floor = siblings.filter { $0.end <= clip.start + 0.001 }.map(\.end).max() ?? 0
            clip.start = start.clamped(floor, clip.end - 0.2)
        }
        if let end {
            let ceiling = siblings.filter { $0.start >= clip.end - 0.001 }.map(\.start).min() ?? full
            clip.end = end.clamped(clip.start + 0.2, ceiling)
        }
        edit.clips[i] = clip
    }

    /// Back to one untouched clip per take.
    func resetClips() {
        edit.clips = meta.segments.map { Clip(segment: $0.index, start: 0, end: takeDuration($0.index)) }
    }

    func regenerateAutoZoom() {
        let manual = edit.zooms.filter { !$0.isAuto }
        edit.zooms = manual + AutoZoom.regions(clicks: clickTimes.map(\.t), scale: edit.defaultZoomScale,
                                               duration: timeline.sourceDuration)
    }

    func addZoom(at source: Double, duration: Double = 2.5) {
        let z = ZoomRegion(start: max(0, source), duration: max(0.4, duration), scale: edit.defaultZoomScale, isAuto: false)
        edit.zooms.append(z)
        selection = .zoom(z.id)
        inspectorTab = .zoom
    }

    func addAnnotation(_ kind: Annotation.Kind, rect: NormRect, points: [StrokePoint] = []) {
        var a = Annotation(kind: kind, start: sourceTime, duration: 3)
        a.rect = rect
        a.points = points
        a.color = AppSettings.shared.highlightColor
        a.lineWidth = kind == .rect || kind == .box ? 3 : 5
        if kind == .text { a.text = "在这里输入" ; a.color = .yellow }
        edit.annotations.append(a)
        selection = .annotation(a.id)
        inspectorTab = .annotations
    }

    func addBlur(rect: NormRect) {
        let start = sourceTime
        let b = BlurRegion(start: start, duration: min(5, max(1, timeline.sourceDuration - start)), rect: rect)
        edit.blurs.append(b)
        selection = .blur(b.id)
        inspectorTab = .privacy
    }

    func deleteSelection() {
        if range != nil { deleteRange(); return }
        let target = hovered != .none ? hovered : selection
        hovered = .none
        if target != selection { selection = .none }
        delete(target)
    }

    func delete(_ target: EditorSelection) {
        switch target {
        case .zoom(let id): edit.zooms.removeAll { $0.id == id }
        case .annotation(let id): edit.annotations.removeAll { $0.id == id }
        case .blur(let id): edit.blurs.removeAll { $0.id == id }
        case .clip(let id): deleteClip(id); return
        case .voiceover(let id): edit.voiceovers.removeAll { $0.id == id }
        case .none: return
        }
        selection = .none
    }

    /// Cursor position at the playhead, used to place the box of a follow-mode zoom.
    func cursorPosition(atSource t: Double) -> NormPoint? { cursorTrack.position(at: t) }

    func setHovered(_ item: EditorSelection, _ inside: Bool) {
        if inside { hovered = item } else if hovered == item { hovered = .none }
    }

    func select(_ s: EditorSelection) {
        selection = s
        switch s {
        case .zoom: inspectorTab = .zoom
        case .annotation: inspectorTab = .annotations
        case .blur: inspectorTab = .privacy
        default: break
        }
    }

    func binding<T>(annotation id: UUID, _ keyPath: WritableKeyPath<Annotation, T>) -> (get: () -> T?, set: (T) -> Void) {
        ({ self.edit.annotations.first { $0.id == id }?[keyPath: keyPath] },
         { v in if let i = self.edit.annotations.firstIndex(where: { $0.id == id }) { self.edit.annotations[i][keyPath: keyPath] = v } })
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
