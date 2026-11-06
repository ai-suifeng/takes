import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable {
    case mp4, gif

    var label: String { self == .mp4 ? "MP4 视频" : "GIF 动图" }
}

enum ExportResolution: String, CaseIterable {
    case p720, p1080, p4k, native

    var label: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p4k: "4K"
        case .native: "原始"
        }
    }

    /// Long side in pixels for a 16:9-ish canvas.
    func longSide(native: Double) -> Double {
        switch self {
        case .p720: min(1280, native)
        case .p1080: min(1920, native)
        case .p4k: min(3840, native)
        case .native: native
        }
    }
}

struct ExportOptions {
    var format: ExportFormat = .mp4
    var resolution: ExportResolution = .p1080
    var fps = 60
    var gifWidth = 960
    var gifFPS = 15
}

enum Exporter {
    /// The folder the user picked for exports, or the library's 导出 folder.
    static func defaultFolder() -> URL {
        if let picked = AppSettings.shared.exportFolder, FileManager.default.fileExists(atPath: picked.path) {
            return picked
        }
        let url = AppSettings.shared.libraryFolder.appendingPathComponent("导出", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A name usable as a file name: no path separators, no leading dot, no repeated extension.
    static func safeFileName(_ name: String, fallback: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        for ext in [".mp4", ".gif"] where n.lowercased().hasSuffix(ext) { n.removeLast(ext.count) }
        while n.hasPrefix(".") { n.removeFirst() }
        return n.isEmpty ? fallback : n
    }

    static func uniqueURL(name: String, ext: String, in folder: URL = defaultFolder()) -> URL {
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Renders the project with a frozen copy of the current edit.
    @MainActor
    static func export(model: EditorModel, options: ExportOptions, to url: URL,
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        let state = model.renderState
        let box = RenderStateBox(state)
        let builder = CompositionBuilder(bundle: model.bundle, meta: model.meta, assets: model.assets, cameraAssets: model.cameraAssets, voiceoverAssets: model.voiceoverAssets)

        switch options.format {
        case .mp4:
            let size = state.canvasSize(longSide: options.resolution.longSide(native: state.nativeLongSide))
            let result = try await builder.build(timeline: model.timeline, box: box, renderSize: size, fps: options.fps, edit: model.edit)
            let preset = size.width * size.height > 1920 * 1200 ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
            guard let session = AVAssetExportSession(asset: result.composition, presetName: preset) else {
                throw CocoaError(.featureUnsupported)
            }
            session.videoComposition = result.videoComposition
            session.audioMix = result.audioMix
            session.shouldOptimizeForNetworkUse = true
            try? FileManager.default.removeItem(at: url)
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { poll.cancel() }
            try await session.export(to: url, as: .mp4)
            progress(1)

        case .gif:
            let width = Double(options.gifWidth)
            let size = state.canvasSize(longSide: state.canvasAspect >= 1 ? width : width / state.canvasAspect)
            let result = try await builder.build(timeline: model.timeline, box: box, renderSize: size, fps: options.gifFPS, edit: model.edit)
            let generator = AVAssetImageGenerator(asset: result.composition)
            generator.videoComposition = result.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = size

            let duration = model.timeline.duration
            let count = max(1, Int(duration * Double(options.gifFPS)))
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let delay = 1.0 / Double(options.gifFPS)
            let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                              kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
            let times = (0..<count).map { CMTime(seconds: Double($0) * delay, preferredTimescale: 600) }
            var done = 0
            for await item in generator.images(for: times) {
                if Task.isCancelled { throw CancellationError() }
                if let image = try? item.image {
                    CGImageDestinationAddImage(dest, image, frameProps)
                }
                done += 1
                progress(Double(done) / Double(count))
            }
            guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
