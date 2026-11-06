import SwiftUI

@main
struct TakesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            SelfTest.run(output: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--voiceover-test"), i + 1 < CommandLine.arguments.count {
            VoiceoverSelfTest.run(output: URL(fileURLWithPath: CommandLine.arguments[i + 1]), realMic: CommandLine.arguments.contains("--mic"))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--export"), i + 2 < CommandLine.arguments.count {
            let a = CommandLine.arguments
            let fps = (i + 3 < a.count ? Int(a[i + 3]) : nil) ?? 30
            SelfTest.exportProject(bundle: URL(fileURLWithPath: a[i + 1]), to: URL(fileURLWithPath: a[i + 2]), fps: fps)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 3 < CommandLine.arguments.count {
            let a = CommandLine.arguments
            SelfTest.renderFrame(bundle: URL(fileURLWithPath: a[i + 1]), at: Double(a[i + 2]) ?? 0, to: URL(fileURLWithPath: a[i + 3]))
            return
        }
        // Debug: install an update zip directly, to test the swap without a GitHub release.
        if let i = CommandLine.arguments.firstIndex(of: "--install-update"), i + 1 < CommandLine.arguments.count {
            Updater.shared.finishInstall(zip: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            if case .failed(let msg) = Updater.shared.state { print(msg); exit(1) }
            return
        }
        NSApp.setActivationPolicy(.regular)
        let model = AppModel.shared
        statusItem = StatusItemController(model: model)
        model.registerHotKeys()
        if !AppSettings.shared.skipsOnboarding || !Permissions.shared.canRecord {
            model.showOnboarding()
        } else {
            model.openLibrary()
        }
        Updater.shared.checkInBackground()
        if let i = CommandLine.arguments.firstIndex(of: "--demo"), i + 1 < CommandLine.arguments.count {
            model.showCaptureBar()
            if CommandLine.arguments[i + 1] == "hud" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    model.session.folderOverride = AppSettings.shared.libraryFolder
                    model.setupForDemo()
                }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count {
            model.openEditor(ProjectBundle(url: URL(fileURLWithPath: CommandLine.arguments[i + 1])))
            if ["--tab", "--seek", "--select"].contains(where: CommandLine.arguments.contains) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.debugConfigureFrontEditor(arguments: CommandLine.arguments) }
            }
            if CommandLine.arguments.contains("--play") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.debugPlayFrontEditor() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.openLibrary() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        Permissions.shared.refresh()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let session = AppModel.shared.session
        guard session.isActive else { return .terminateNow }
        session.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
