import AppKit
import Security
import SwiftUI

/// Updates from GitHub Releases: the latest release's `Takes-<version>.zip` asset replaces the running app.
/// The new app must carry the same code signature as this one, so a tampered download is never installed.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    static let repo = "ai-suifeng/takes"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }

    struct Release: Equatable {
        var version: String
        var notes: String
        var downloadURL: URL
        var page: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), downloading(Double), installing, failed(String)
    }

    private(set) var state: State = .idle
    var automaticChecks: Bool {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: "autoCheckUpdates") }
    }
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var download: URLSessionDownloadTask?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {
        automaticChecks = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }

    /// Quietly checks at most once a day; only shows a window when there is something new.
    func checkInBackground() {
        guard automaticChecks else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if userInitiated { showWindow() }
        state = .checking
        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            let skipped = UserDefaults.standard.string(forKey: "skippedVersion")
            if let release, Self.isNewer(release.version, than: Self.currentVersion),
               userInitiated || release.version != skipped {
                state = .available(release)
                showWindow()
            } else {
                state = .upToDate
            }
        } catch {
            state = userInitiated ? .failed("检查更新失败：\(error.localizedDescription)") : .idle
        }
    }

    func skip(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: "skippedVersion")
        closeWindow()
    }

    func closeWindow() {
        download?.cancel()
        window?.close()
        window = nil
        if case .downloading = state { state = .idle }
    }

    // MARK: - GitHub

    private func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        // No release published yet.
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let body: String?
            let html_url: URL
            let assets: [Asset]
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard let asset = p.assets.first(where: { $0.name.hasPrefix("Takes") && $0.name.hasSuffix(".zip") }) else { return nil }
        let version = p.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return Release(version: version, notes: p.body ?? "", downloadURL: asset.browser_download_url, page: p.html_url)
    }

    /// Numeric comparison of dotted versions: 0.10.0 is newer than 0.9.2.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Install

    func install(_ release: Release) {
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: release.downloadURL) { [weak self] file, _, error in
            // The temporary file is deleted when this handler returns, so move it first.
            var kept: URL?
            if let file {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Takes-update-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: file, to: dest)) != nil { kept = dest }
            }
            Task { @MainActor in
                guard let self else { return }
                if let kept {
                    self.finishInstall(zip: kept)
                } else if (error as? URLError)?.code != .cancelled {
                    self.state = .failed("下载失败：\(error?.localizedDescription ?? "未知错误")")
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in
                if case .downloading = self?.state { self?.state = .downloading(f) }
            }
        }
        download = task
        task.resume()
    }

    func finishInstall(zip: URL) {
        state = .installing
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Takes-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw message("更新包里没有找到 App") }
            try verifySignature(of: newApp)

            let current = Bundle.main.bundleURL
            guard fm.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
                throw message("没有权限替换 \(current.deletingLastPathComponent().path) 里的 App，请手动下载安装")
            }
            // Swap once this process has quit, then reopen the new version.
            let script = """
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(current.path)"
            /usr/bin/ditto "\(newApp.path)" "\(current.path)"
            /usr/bin/xattr -dr com.apple.quarantine "\(current.path)"
            /usr/bin/open "\(current.path)"
            rm -rf "\(work.path)" "\(zip.path)"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("安装失败：\(error.localizedDescription)")
        }
    }

    /// The download must satisfy this app's own designated requirement (same bundle id and certificate).
    private func verifySignature(of app: URL) throws {
        var selfCode: SecCode?
        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyDesignatedRequirement(unsafeBitCast(selfCode, to: SecStaticCode.self), [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw message("无法读取签名信息")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess else {
            throw message("更新包的签名和当前 App 不一致，已停止安装")
        }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw message("解压失败") }
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Takes.Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    // MARK: - Window

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 300),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.title = "软件更新"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: UpdateView(updater: self))
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

private struct UpdateView: View {
    var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .bold))
                    Text("当前版本 \(Updater.currentVersion)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(24)
        .padding(.top, 10)
        .frame(width: 460, alignment: .leading)
    }

    private var title: String {
        switch updater.state {
        case .available(let r): "Takes \(r.version) 可以更新了"
        case .upToDate: "已是最新版本"
        case .checking: "正在检查更新…"
        case .downloading, .installing: "正在更新…"
        case .failed: "更新出错"
        case .idle: "软件更新"
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .available(let release):
            ScrollView {
                Text(release.notes.isEmpty ? "修复和改进。" : release.notes)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 120)
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("跳过这个版本") { updater.skip(release) }
                Spacer()
                Button("稍后") { updater.closeWindow() }.keyboardShortcut(.cancelAction)
                Button("立即更新") { updater.install(release) }
                    .buttonStyle(BrandButtonStyle()).keyboardShortcut(.defaultAction)
            }
        case .downloading(let p):
            ProgressView(value: p)
            Text("正在下载 \(Int(p * 100))%，完成后会自动重启 Takes").font(.system(size: 12)).foregroundStyle(.secondary)
        case .installing:
            ProgressView().controlSize(.small)
            Text("正在安装，马上重启…").font(.system(size: 12)).foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate, .idle:
            HStack { Spacer(); Button("好") { updater.closeWindow() }.keyboardShortcut(.defaultAction) }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            HStack {
                Button("打开下载页面") { NSWorkspace.shared.open(Updater.releasesPage) }
                Spacer()
                Button("关闭") { updater.closeWindow() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
