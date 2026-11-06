import Foundation

// All times in the edit document are "source time": seconds from the start of take 1,
// with takes laid end to end at their full recorded durations.

/// A kept piece of a take. The output is all clips played in order.
struct Clip: Codable, Hashable, Identifiable {
    var id = UUID()
    var segment: Int
    /// Range within the take, in seconds from the take's start.
    var start: Double
    var end: Double

    var duration: Double { end - start }
}

/// Something on a track that spans a stretch of source time and can be cut at the playhead.
protocol TimelineItem {
    var id: UUID { get set }
    var start: Double { get }
    var end: Double { get }
    /// Narrows or widens the item. What it shows or plays stays on the same frames.
    mutating func trim(start: Double, end: Double)
}

/// A stretch of narration recorded over the video. It is anchored to source time, like zooms and blurs,
/// so it stays on its frames through any later cut.
struct VoiceoverPiece: Codable, Hashable, Identifiable {
    var id = UUID()
    /// File name inside the project's voiceover folder.
    var file: String
    /// Where this stretch begins in that file, in seconds.
    var fileStart: Double
    /// Source time the first sample belongs to.
    var start: Double
    var duration: Double
    /// Source-time span this stretch of recording can be widened to; nil means no wider than it is now.
    var sourceMin: Double?
    var sourceMax: Double?

    var end: Double { start + duration }
}

extension VoiceoverPiece: TimelineItem {
    mutating func trim(start newStart: Double, end newEnd: Double) {
        fileStart += newStart - start
        start = newStart
        duration = newEnd - newStart
    }
}

/// Per-take trims from the first editor version; read only to migrate to clips.
struct SegmentEdit: Codable, Hashable {
    var index: Int
    var enabled = true
    /// Seconds trimmed from the start and end of the take.
    var trimStart: Double = 0
    var trimEnd: Double = 0
}

struct ZoomRegion: Codable, Hashable, Identifiable {
    enum Mode: String, Codable { case follow, fixed }

    var id = UUID()
    var start: Double
    var duration: Double
    var scale: Double = 2
    var mode: Mode = .follow
    /// Focus point for `.fixed` mode.
    var center = NormPoint(x: 0.5, y: 0.5)
    var isAuto = true

    var end: Double { start + duration }
}

extension ZoomRegion: TimelineItem {
    mutating func trim(start newStart: Double, end newEnd: Double) {
        start = newStart
        duration = newEnd - newStart
        isAuto = false
    }
}

struct StrokePoint: Codable, Hashable {
    var x: Double
    var y: Double
    /// Seconds since the annotation's start.
    var t: Double
}

struct Annotation: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case box, spotlight, magnify, arrow, rect, pen, highlighter, text

        var label: String {
            switch self {
            case .box: "高亮框"
            case .spotlight: "聚光灯"
            case .magnify: "放大镜"
            case .arrow: "箭头"
            case .rect: "矩形"
            case .pen: "画笔"
            case .highlighter: "荧光笔"
            case .text: "文字"
            }
        }

        var symbol: String {
            switch self {
            case .box: "square.dashed"
            case .spotlight: "light.max"
            case .magnify: "plus.magnifyingglass"
            case .arrow: "arrow.up.right"
            case .rect: "rectangle"
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .text: "character.textbox"
            }
        }

        /// Kinds whose geometry is a single rect (as opposed to a stroke).
        var isRectBased: Bool { [.box, .spotlight, .magnify, .rect, .text].contains(self) }
    }

    var id = UUID()
    var kind: Kind
    var start: Double
    var duration: Double = 3
    var rect: NormRect = .zero
    var points: [StrokePoint] = []
    var color: RGBA = .red
    var lineWidth: Double = 4
    var text: String = ""
    /// Step badge number, shown next to highlight boxes.
    var step: Int?
    /// Laser-pointer style: fades out shortly after it is drawn.
    var fades = false

    var end: Double { start + duration }
}

extension Annotation: TimelineItem {
    /// Points may end up before the new start: those are simply already drawn.
    mutating func trim(start newStart: Double, end newEnd: Double) {
        let shift = start - newStart
        for i in points.indices { points[i].t += shift }
        start = newStart
        duration = newEnd - newStart
    }
}

struct BlurKeyframe: Codable, Hashable {
    /// Seconds since the region's start.
    var t: Double
    var rect: NormRect
}

struct BlurRegion: Codable, Hashable, Identifiable {
    enum Style: String, Codable, CaseIterable {
        case mosaic, blur, solid

        var label: String {
            switch self {
            case .mosaic: "马赛克"
            case .blur: "模糊"
            case .solid: "色块"
            }
        }
    }

    var id = UUID()
    var start: Double
    var duration: Double
    var rect: NormRect
    var style: Style = .mosaic
    var keyframes: [BlurKeyframe] = []
    /// Why it was created, e.g. "邮箱: a@b.com" for auto-detected regions.
    var label: String = ""

    var end: Double { start + duration }

    func rect(at t: Double) -> NormRect {
        let local = t - start
        guard keyframes.count > 1 else { return keyframes.first?.rect ?? rect }
        if local <= keyframes[0].t { return keyframes[0].rect }
        for i in 1..<keyframes.count where keyframes[i].t >= local {
            let a = keyframes[i - 1], b = keyframes[i]
            let f = b.t > a.t ? (local - a.t) / (b.t - a.t) : 0
            return NormRect.lerp(a.rect, b.rect, f)
        }
        return keyframes.last!.rect
    }
}

extension BlurRegion: TimelineItem {
    /// Keyframes stay on their frames, so a tracked mask keeps covering what it tracked. Ones outside the
    /// new span are kept: they let `rect(at:)` interpolate at the edges and allow widening it again.
    mutating func trim(start newStart: Double, end newEnd: Double) {
        let shift = start - newStart
        for i in keyframes.indices { keyframes[i].t += shift }
        start = newStart
        duration = newEnd - newStart
    }
}

enum AspectRatio: String, Codable, CaseIterable {
    case auto, wide, vertical, square, classic

    var label: String {
        switch self {
        case .auto: "原始"
        case .wide: "16:9"
        case .vertical: "9:16"
        case .square: "1:1"
        case .classic: "4:3"
        }
    }

    func value(source: Double) -> Double {
        switch self {
        case .auto: source
        case .wide: 16.0 / 9.0
        case .vertical: 9.0 / 16.0
        case .square: 1
        case .classic: 4.0 / 3.0
        }
    }
}

struct BackgroundStyle: Codable, Hashable {
    enum Kind: String, Codable { case gradient, solid, none }

    var kind: Kind = .gradient
    var gradient: Int = 0
    var solid: RGBA = RGBA(r: 0.12, g: 0.12, b: 0.14)

    static let gradients: [(name: String, a: RGBA, b: RGBA)] = [
        ("落日", RGBA(r: 1.0, g: 0.42, b: 0.42), RGBA(r: 0.56, g: 0.27, b: 0.96)),
        ("海洋", RGBA(r: 0.13, g: 0.59, b: 0.95), RGBA(r: 0.11, g: 0.85, b: 0.75)),
        ("极光", RGBA(r: 0.16, g: 0.85, b: 0.55), RGBA(r: 0.12, g: 0.36, b: 0.85)),
        ("蜜桃", RGBA(r: 1.0, g: 0.75, b: 0.55), RGBA(r: 1.0, g: 0.45, b: 0.6)),
        ("薰衣草", RGBA(r: 0.75, g: 0.65, b: 1.0), RGBA(r: 0.45, g: 0.5, b: 0.95)),
        ("午夜", RGBA(r: 0.12, g: 0.13, b: 0.25), RGBA(r: 0.33, g: 0.18, b: 0.45)),
        ("石墨", RGBA(r: 0.28, g: 0.3, b: 0.34), RGBA(r: 0.1, g: 0.1, b: 0.12)),
        ("柠檬", RGBA(r: 0.98, g: 0.93, b: 0.45), RGBA(r: 0.45, g: 0.85, b: 0.5)),
    ]
}

struct StyleSettings: Codable, Hashable {
    var background = BackgroundStyle()
    /// Padding around the screen, as a fraction of the canvas' shorter side.
    var padding: Double = 0.07
    /// Corner radius as a fraction of the screen's shorter side.
    var cornerRadius: Double = 0.018
    var shadow: Double = 0.6
    var aspect: AspectRatio = .auto
    var transition: TakeTransition = .fade
}

enum TakeTransition: String, Codable, CaseIterable {
    case none, fade

    var label: String { self == .none ? "直接拼接" : "淡入淡出" }
}

struct CursorSettings: Codable, Hashable {
    var visible = true
    var scale: Double = 1.6
    /// 0 = raw movement, 1 = heavily smoothed.
    var smoothing: Double = 0.6
    var hideWhenIdle = true
    var clickEffect = true
}

struct CameraSettings: Codable, Hashable {
    enum Corner: String, Codable, CaseIterable {
        case bottomRight, bottomLeft, topRight, topLeft
    }

    enum Shape: String, Codable, CaseIterable {
        case circle, rounded

        var label: String { self == .circle ? "圆形" : "圆角矩形" }
    }

    var visible = true
    var corner: Corner = .bottomRight
    /// Diameter as a fraction of the canvas' shorter side.
    var size: Double = 0.22
    var shape: Shape = .circle
}

struct EditDocument: Codable, Hashable {
    var clips: [Clip] = []
    var segments: [SegmentEdit] = []
    var zooms: [ZoomRegion] = []
    var annotations: [Annotation] = []
    var blurs: [BlurRegion] = []
    var style = StyleSettings()
    var cursor = CursorSettings()
    var camera = CameraSettings()
    var showKeystrokes = true
    var autoZoom = true
    var defaultZoomScale: Double = 1.8
    var micVolume: Double = 1
    var systemVolume: Double = 1
    /// Raise quiet narration to a standard loudness (with a limiter).
    var normalizeAudio = true
    /// Measured boost for the mic in dB; nil until analysed.
    var micAutoGain: Double?
    /// Measured background noise of the mic in dBFS, for the noise gate.
    var micNoiseFloor: Double?
    var voiceovers: [VoiceoverPiece] = []
    var voiceoverVolume: Double = 1
    /// Measured boost and background noise of the voiceover, like the mic's.
    var voiceoverAutoGain: Double?
    var voiceoverNoiseFloor: Double?

    init() {}

    // Tolerant decoding, so documents from older versions keep their edits.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditDocument()
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? d.clips
        segments = try c.decodeIfPresent([SegmentEdit].self, forKey: .segments) ?? d.segments
        zooms = try c.decodeIfPresent([ZoomRegion].self, forKey: .zooms) ?? d.zooms
        annotations = try c.decodeIfPresent([Annotation].self, forKey: .annotations) ?? d.annotations
        blurs = try c.decodeIfPresent([BlurRegion].self, forKey: .blurs) ?? d.blurs
        style = try c.decodeIfPresent(StyleSettings.self, forKey: .style) ?? d.style
        cursor = try c.decodeIfPresent(CursorSettings.self, forKey: .cursor) ?? d.cursor
        camera = try c.decodeIfPresent(CameraSettings.self, forKey: .camera) ?? d.camera
        showKeystrokes = try c.decodeIfPresent(Bool.self, forKey: .showKeystrokes) ?? d.showKeystrokes
        autoZoom = try c.decodeIfPresent(Bool.self, forKey: .autoZoom) ?? d.autoZoom
        defaultZoomScale = try c.decodeIfPresent(Double.self, forKey: .defaultZoomScale) ?? d.defaultZoomScale
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? d.micVolume
        systemVolume = try c.decodeIfPresent(Double.self, forKey: .systemVolume) ?? d.systemVolume
        normalizeAudio = try c.decodeIfPresent(Bool.self, forKey: .normalizeAudio) ?? d.normalizeAudio
        micAutoGain = try c.decodeIfPresent(Double.self, forKey: .micAutoGain)
        micNoiseFloor = try c.decodeIfPresent(Double.self, forKey: .micNoiseFloor)
        voiceovers = try c.decodeIfPresent([VoiceoverPiece].self, forKey: .voiceovers) ?? d.voiceovers
        voiceoverVolume = try c.decodeIfPresent(Double.self, forKey: .voiceoverVolume) ?? d.voiceoverVolume
        voiceoverAutoGain = try c.decodeIfPresent(Double.self, forKey: .voiceoverAutoGain)
        voiceoverNoiseFloor = try c.decodeIfPresent(Double.self, forKey: .voiceoverNoiseFloor)
    }
}
