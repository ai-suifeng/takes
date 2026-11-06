import AVFoundation
import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// Coordinates recording, overlays and windows.
@Observable
final class AppModel {
    static let shared = AppModel()

    let session = RecordingSession()
    let library = LibraryStore.shared
    let setup = CaptureSetup()
    @ObservationIgnored lazy var annotations = LiveAnnotationController(session: session)

    @ObservationIgnored private var captureBar: FloatingPanel?
    @ObservationIgnored private var windowPicker: FloatingPanel?
    @ObservationIgnored private var areaWindows: [OverlayWindow] = []
    @ObservationIgnored private var screenPickWindows: [CGDirectDisplayID: OverlayWindow] = [:]
    @ObservationIgnored private var hud: FloatingPanel?
    @ObservationIgnored private var countdownWindow: OverlayWindow?
    @ObservationIgnored private var borderWindow: OverlayWindow?
    @ObservationIgnored private var libraryWindow: NSWindow?
    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var editors: [URL: NSWindow] = [:]
    @ObservationIgnored private var editorModels: [URL: EditorModel] = [:]

    private init() {
        session.onFinished = { [weak self] bundle in
            guard let self else { return }
            self.library.activeRecording = nil
            self.library.reload()
            self.openEditor(bundle)
            ScreenTextIndexer.indexInBackground(bundle)
        }
        session.onClick = { [weak self] click in self?.annotations.handleClick(click) }
        observeSession()
    }

    func registerHotKeys() {
        HotKeys.shared.register(HotKeys.record) { [weak self] in
            guard let self else { return }
            if self.session.isActive { self.session.stop() } else { self.showCaptureBar() }
        }
        HotKeys.shared.register(HotKeys.pause) { [weak self] in self?.session.togglePause() }
        HotKeys.shared.register(HotKeys.redo) { [weak self] in self?.session.redoTake() }
        HotKeys.shared.register(HotKeys.draw) { [weak self] in self?.annotations.toggleDrawing() }
    }

    // MARK: - Capture bar

    func showCaptureBar() {
        guard !session.isActive else { return }
        Permissions.shared.refresh()
        guard Permissions.shared.canRecord else {
            showOnboarding()
            return
        }
        if let captureBar {
            captureBar.makeKeyAndOrderFront(nil)
            return
        }
        Task { @MainActor in await setup.refresh() }
        let bar = FloatingPanel(level: .popUpMenu, keyable: true, movable: true) {
            CaptureBarView(setup: self.setup,
                           onPickWindow: { [weak self] in self?.showWindowPicker() },
                           onPickArea: { [weak self] in self?.showAreaSelector() },
                           onStart: { [weak self] in self?.startRecording() },
                           onClose: { [weak self] in self?.hideCaptureBar() })
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        bar.place(on: screen, fromBottom: 60)
        bar.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        captureBar = bar
        observeSetup()
    }

    func hideCaptureBar() {
        captureBar?.close(); captureBar = nil
        windowPicker?.close(); windowPicker = nil
        closeAreaSelector()
        syncScreenPick()
    }

    private func observeSetup() {
        withObservationTracking {
            _ = setup.mode
            _ = setup.selectedDisplayID
        } onChange: {
            DispatchQueue.main.async {
                self.syncScreenPick()
                if self.captureBar != nil { self.observeSetup() }
            }
        }
        syncScreenPick()
    }

    /// In full-screen mode, marks the screen that will be recorded and lets the others be picked.
    private func syncScreenPick() {
        let show = captureBar != nil && setup.mode == .display && setup.selectedDisplayID != nil
        guard show else {
            screenPickWindows.values.forEach { $0.close() }
            screenPickWindows = [:]
            return
        }
        for screen in NSScreen.screens {
            let id = screen.displayID
            let window = screenPickWindows[id] ?? {
                let w = OverlayWindow(screenFrame: screen.frame, interactive: true) {
                    ScreenPickOverlayView(setup: self.setup, screen: screen) { [weak self] in
                        self?.setup.selectedDisplayID = id
                    }
                }
                w.level = .floating
                w.orderFrontRegardless()
                screenPickWindows[id] = w
                return w
            }()
            // The chosen screen stays usable; the others catch the click that selects them.
            window.ignoresMouseEvents = setup.selectedDisplayID == id
        }
        captureBar?.orderFrontRegardless()
    }

    private func showWindowPicker() {
        closeAreaSelector()
        windowPicker?.close()
        Task { @MainActor in
            await setup.refresh()
            let picker = FloatingPanel(level: .popUpMenu, keyable: true) {
                WindowPickerView(setup: self.setup, onPick: { [weak self] w in
                    self?.setup.selectedWindow = w
                    self?.windowPicker?.close()
                    self?.windowPicker = nil
                }, onCancel: { [weak self] in
                    self?.windowPicker?.close()
                    self?.windowPicker = nil
                })
            }
            let screen = self.captureBar?.screen ?? NSScreen.main!
            picker.place(on: screen, fromBottom: 140)
            picker.makeKeyAndOrderFront(nil)
            self.windowPicker = picker
        }
    }

    private func showAreaSelector() {
        windowPicker?.close(); windowPicker = nil
        closeAreaSelector()
        for screen in NSScreen.screens {
            let id = screen.displayID
            let initial = setup.area?.displayID == id ? setup.area?.rect : nil
            let window = OverlayWindow(screenFrame: screen.frame, interactive: true, keyable: true) {
                AreaSelectorView(screenSize: screen.frame.size, initial: initial, onSelect: { [weak self] rect in
                    self?.setup.area = (id, rect)
                    self?.setup.mode = .area
                    self?.closeAreaSelector(except: id)
                    self?.captureBar?.orderFrontRegardless()
                }, onCancel: { [weak self] in self?.closeAreaSelector() })
            }
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            areaWindows.append(window)
        }
        captureBar?.orderFrontRegardless()
    }

    private func closeAreaSelector(except keep: CGDirectDisplayID? = nil) {
        areaWindows.removeAll { w in
            if let keep, w.screen?.displayID == keep { return false }
            w.close()
            return true
        }
    }

    /// Debug: start an area recording straight away.
    func setupForDemo() {
        setup.mode = .area
        setup.area = (CGMainDisplayID(), CGRect(x: 200, y: 160, width: 900, height: 560))
        startRecording()
    }

    private func startRecording() {
        guard let target = setup.target else { return }
        hideCaptureBar()
        Task { @MainActor in
            // Ask now rather than silently recording without the mic or camera.
            let settings = AppSettings.shared
            if settings.recordMic, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            if settings.recordCamera, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            Permissions.shared.refresh()
            await session.start(target)
            if let error = session.lastError { showError(error) }
            library.activeRecording = session.bundle?.url
        }
    }

    // MARK: - Recording overlays

    private func observeSession() {
        withObservationTracking {
            _ = session.phase
            _ = annotations.isDrawing
        } onChange: {
            DispatchQueue.main.async {
                self.syncOverlays()
                self.observeSession()
            }
        }
    }

    private func syncOverlays() {
        let phase = session.phase
        let active = phase == .countdown || phase == .recording || phase == .paused
        let screen = NSScreen.screens.first { $0.cgFrame.intersects(session.captureRect) } ?? NSScreen.main!
        let local = session.captureRect.offsetBy(dx: -screen.cgFrame.minX, dy: -screen.cgFrame.minY)

        if active, hud == nil {
            let panel = FloatingPanel(level: .statusBar, movable: true) {
                HUDHost(model: self)
            }
            panel.place(on: screen, fromTop: 8)
            panel.orderFrontRegardless()
            hud = panel
        } else if !active {
            hud?.close(); hud = nil
        }

        if phase == .countdown, countdownWindow == nil {
            let w = OverlayWindow(screenFrame: screen.frame, interactive: false) {
                CountdownOverlayView(session: self.session, captureRect: local, screenSize: screen.frame.size)
            }
            w.level = .floating
            w.orderFrontRegardless()
            countdownWindow = w
            hud?.orderFrontRegardless()
        } else if phase != .countdown {
            countdownWindow?.close(); countdownWindow = nil
        }

        if active, session.target?.kind == .area || session.target?.kind == .display {
            if borderWindow == nil {
                let isDisplay = session.target?.kind == .display
                let w = OverlayWindow(screenFrame: screen.frame, interactive: false) {
                    if isDisplay {
                        RecordingScreenBorderView(session: self.session)
                    } else {
                        BorderHost(session: self.session, captureRect: local, screenSize: screen.frame.size)
                    }
                }
                w.level = .floating
                w.orderFrontRegardless()
                borderWindow = w
            }
        } else {
            borderWindow?.close(); borderWindow = nil
            closeAreaSelector()
        }

        if phase != .recording, annotations.isDrawing { annotations.endDrawing() }
    }

    // MARK: - Windows

    func openLibrary() {
        if let libraryWindow {
            libraryWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Takes"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 820, height: 520)
        window.contentView = NSHostingView(rootView: LibraryView(model: self))
        window.setFrameAutosaveName("LibraryWindow")
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow = window
        library.reload()
    }

    func openEditor(_ bundle: ProjectBundle) {
        if let existing = editors[bundle.url] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let doc = try? EditorModel(bundle: bundle) else {
            showError("无法打开这个录制，文件可能已损坏。")
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1320, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = doc.meta.name
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 1000, height: 640)
        window.contentView = NSHostingView(rootView: EditorView(model: doc))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editors[bundle.url] = window
        editorModels[bundle.url] = doc
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window, !(window.firstResponder is NSText) else { return event }
            return EditorKeys.handle(event, model: doc) ? nil : event
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            if let keys { NSEvent.removeMonitor(keys) }
            doc.finishVoiceoverOnClose()
            doc.saveNow()
            doc.player.pause()
            self?.editors[bundle.url] = nil
            self?.editorModels[bundle.url] = nil
            self?.library.reload()
        }
    }

    /// Debug: start playback in the open editor.
    func debugPlayFrontEditor() {
        editorModels.values.first?.togglePlay()
    }

    /// Debug (promo screenshots): put the open editor in a given state.
    /// `--tab <InspectorTab>`, `--seek <output seconds>`, `--select zoom|blur|voiceover|clip[:index]`.
    func debugConfigureFrontEditor(arguments a: [String]) {
        guard let model = editorModels.values.first else { return }
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        if let t = value("--tab").flatMap(InspectorTab.init(rawValue:)) { model.inspectorTab = t }
        if let s = value("--seek").flatMap(Double.init) { model.seek(comp: s) }
        if let sel = value("--select") {
            let parts = sel.split(separator: ":")
            let i = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            switch parts.first {
            case "zoom": if model.edit.zooms.indices.contains(i) { model.selection = .zoom(model.edit.zooms[i].id) }
            case "blur": if model.edit.blurs.indices.contains(i) { model.selection = .blur(model.edit.blurs[i].id) }
            case "voiceover": if model.edit.voiceovers.indices.contains(i) { model.selection = .voiceover(model.edit.voiceovers[i].id) }
            case "clip": if model.edit.clips.indices.contains(i) { model.selection = .clip(model.edit.clips[i].id) }
            default: break
            }
        }
    }

    func showOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(onDone: { [weak self] in
            AppSettings.shared.hasCompletedOnboarding = true
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.openLibrary()
        }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private struct HUDHost: View {
    var model: AppModel

    var body: some View {
        RecordingHUDView(session: model.session, drawing: model.annotations.isDrawing,
                         onToggleDraw: model.annotations.toggleDrawing)
    }
}

private struct BorderHost: View {
    var session: RecordingSession
    var captureRect: CGRect
    var screenSize: CGSize

    var body: some View {
        AreaBorderView(captureRect: captureRect, screenSize: screenSize, paused: session.phase == .paused)
    }
}

/// Single-key editor shortcuts, skipped while a text field has focus.
enum EditorKeys {
    static func handle(_ event: NSEvent, model: EditorModel) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        // While narrating only the keys that end it work, so nothing shifts the timeline underneath.
        if model.voiceoverPhase != .idle {
            if event.keyCode == 49 || event.keyCode == 53 || event.charactersIgnoringModifiers == "r" { model.toggleVoiceover() }
            return true
        }
        switch event.keyCode {
        case 49: model.togglePlay()
        case 123: model.step(frames: shift ? -60 : -1)
        case 124: model.step(frames: shift ? 60 : 1)
        case 51, 117: model.deleteSelection()
        case 53:
            model.tool = .select
            model.selection = .none
            model.range = nil
        default:
            switch event.charactersIgnoringModifiers {
            case "r": model.toggleVoiceover()
            case "z": model.addZoom(at: model.sourceTime)
            case "s": model.splitAtPlayhead()
            case "i": model.markIn()
            case "o": model.markOut()
            case "q": model.trimAtPlayhead(keepRight: true)
            case "w": model.trimAtPlayhead(keepRight: false)
            case "v": model.tool = .select
            case "b": model.tool = .box
            case "m": model.tool = .blur
            default: return false
            }
        }
        return true
    }
}
