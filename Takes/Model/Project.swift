import Foundation
import CoreGraphics

enum CaptureKind: String, Codable {
    case display, window, area

    var label: String {
        switch self {
        case .display: "全屏"
        case .window: "窗口"
        case .area: "区域"
        }
    }

    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }
}

enum ProjectStatus: String, Codable {
    case recording, ready, recovered
}

struct SegmentInfo: Codable, Hashable {
    var index: Int
    var file: String
    var cameraFile: String?
    var duration: Double
}

struct ProjectMeta: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var status: ProjectStatus = .recording
    var kind: CaptureKind
    var sourceTitle: String
    /// Capture size in pixels.
    var width: Int
    var height: Int
    /// Backing scale of the captured display (pixels per point).
    var scale: Double
    var segments: [SegmentInfo] = []
    var hasMic = false
    var hasSystemAudio = false
    var hasCamera = false
    var favorite = false
    var tags: [String] = []
    /// Apps that were frontmost during the recording, in order of first appearance.
    var apps: [String] = []
    var exportedFiles: [String] = []

    var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    var aspect: Double { height > 0 ? Double(width) / Double(height) : 16.0 / 9.0 }
}

/// A recorded input event. `t` is seconds since the start of segment `seg`; coordinates are normalized.
struct InputEvent: Codable, Hashable {
    enum Kind: String, Codable {
        case move, down, up, rightDown, key
    }

    var seg: Int
    var t: Double
    var kind: Kind
    var x: Double
    var y: Double
    var key: String?
}

/// Live annotations created during recording, stored relative to their segment until the editor adopts them.
struct LiveAnnotation: Codable {
    var seg: Int
    var t: Double
    var annotation: Annotation
}

/// Wraps a `.takes` project folder on disk.
struct ProjectBundle: Hashable {
    let url: URL

    var metaURL: URL { url.appendingPathComponent("meta.json") }
    var eventsURL: URL { url.appendingPathComponent("events.jsonl") }
    var liveAnnotationsURL: URL { url.appendingPathComponent("live-annotations.json") }
    var editURL: URL { url.appendingPathComponent("edit.json") }
    var thumbnailURL: URL { url.appendingPathComponent("thumbnail.jpg") }
    var ocrURL: URL { url.appendingPathComponent("ocr.json") }
    var segmentsDir: URL { url.appendingPathComponent("segments", isDirectory: true) }

    var voiceoverDir: URL { url.appendingPathComponent("voiceover", isDirectory: true) }

    func segmentURL(_ file: String) -> URL { segmentsDir.appendingPathComponent(file) }
    func voiceoverURL(_ file: String) -> URL { voiceoverDir.appendingPathComponent(file) }

    static func create(in root: URL, name: String) throws -> ProjectBundle {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root.appendingPathComponent("\(name).takes", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(name) \(n).takes", isDirectory: true)
            n += 1
        }
        let bundle = ProjectBundle(url: url)
        try fm.createDirectory(at: bundle.segmentsDir, withIntermediateDirectories: true)
        return bundle
    }

    func readMeta() throws -> ProjectMeta {
        try JSONDecoder.takes.decode(ProjectMeta.self, from: Data(contentsOf: metaURL))
    }

    func writeMeta(_ meta: ProjectMeta) throws {
        try JSONEncoder.takes.encode(meta).write(to: metaURL, options: .atomic)
    }

    func readEvents() -> [InputEvent] {
        guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(InputEvent.self, from: Data(line.utf8))
        }
    }

    func readLiveAnnotations() -> [LiveAnnotation] {
        guard let data = try? Data(contentsOf: liveAnnotationsURL) else { return [] }
        return (try? JSONDecoder.takes.decode([LiveAnnotation].self, from: data)) ?? []
    }

    func readEdit() -> EditDocument? {
        guard let data = try? Data(contentsOf: editURL) else { return nil }
        return try? JSONDecoder.takes.decode(EditDocument.self, from: data)
    }

    func writeEdit(_ edit: EditDocument) throws {
        try JSONEncoder.takes.encode(edit).write(to: editURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var takes: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var takes: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
