import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    @State private var exporting = false
    @State private var renaming = false
    /// Height of the timeline panel; drag the bar above it to give the preview more room.
    /// 0 means automatic: as tall as the tracks need. Dragging the bar fixes it.
    @AppStorage("editorTimelineHeight2") private var timelineHeight = 0.0
    @State private var idealTimeline: CGFloat = 250
    @State private var dragBase: Double?
    /// The right-hand settings panel; hide it to give the preview the full width.
    @AppStorage("editorInspectorVisible") private var inspectorVisible = true

    var body: some View {
        GeometryReader { geo in
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolStrip
                    ZStack {
                        Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
                        if model.isReady {
                            PreviewCanvas(model: model).padding(.horizontal, 16).padding(.bottom, 12)
                                .allowsHitTesting(model.voiceoverPhase == .idle)
                            VoiceoverOverlay(model: model)
                        } else {
                            ProgressView("正在载入…").controlSize(.large)
                        }
                    }
                }
                if inspectorVisible {
                    Divider()
                    InspectorView(model: model).disabled(model.voiceoverPhase != .idle)
                        .transition(.move(edge: .trailing))
                }
            }
            resizeBar(total: geo.size.height)
            EditorTimeline(model: model).frame(height: clampedTimeline(total: geo.size.height))
                .onPreferenceChange(TimelineIdealHeightKey.self) { h in
                    if h > 0 { withAnimation(.snappy(duration: 0.2)) { idealTimeline = h } }
                }
        }
        }
        .toolbar { toolbar }
        .navigationTitle(model.meta.name)
        .navigationSubtitle("\(model.meta.segments.count) 段 · \(formatDuration(model.duration))")
        .background(shortcuts)
        .sheet(isPresented: $exporting) { ExportSheet(model: model) }
        .sheet(isPresented: $renaming) {
            RenameField(name: model.meta.name) { model.renameProject($0) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { inspectorVisible.toggle() }
            } label: {
                Label(inspectorVisible ? "收起设置面板" : "展开设置面板", systemImage: "sidebar.right")
            }
            .help(inspectorVisible ? "收起右侧设置面板（⌥⌘I）" : "展开右侧设置面板（⌥⌘I）")
            .keyboardShortcut("i", modifiers: [.command, .option])
            Button { renaming = true } label: { Label("重命名", systemImage: "pencil") }
                .disabled(model.voiceoverPhase != .idle)
            Button(action: model.undo) { Label("撤销", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo || model.voiceoverPhase != .idle)
            Button(action: model.redo) { Label("重做", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo || model.voiceoverPhase != .idle)
            Button {
                model.player.pause()
                exporting = true
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(!model.isReady || model.voiceoverPhase != .idle)
        }
    }

    /// Keeps at least ~240pt for the preview and enough timeline for the controls and the clip track.
    private func clampedTimeline(total: Double) -> Double {
        min(max(timelineHeight > 0 ? timelineHeight : idealTimeline, 150), max(150, total - 240))
    }

    /// Drag to resize the timeline against the preview.
    private func resizeBar(total: Double) -> some View {
        ZStack {
            Rectangle().fill(.separator).frame(height: 1)
            Capsule().fill(.tertiary).frame(width: 36, height: 4)
        }
        .frame(height: 12)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                let base = dragBase ?? clampedTimeline(total: total)
                dragBase = base
                timelineHeight = min(max(base - v.translation.height, 150), max(150, total - 240))
            }
            .onEnded { _ in dragBase = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { timelineHeight = 0 })
        .help("拖动调整预览和时间线的大小，双击恢复自动高度")
    }

    private var toolStrip: some View {
        HStack(spacing: 4) {
            ForEach(CanvasTool.allCases, id: \.self) { tool in
                Button {
                    model.tool = tool
                    if tool != .select { model.player.pause() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tool.symbol)
                        if model.tool == tool { Text(tool.label).font(.system(size: 11, weight: .medium)) }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .foregroundStyle(model.tool == tool ? .white : .primary)
                    .background {
                        if model.tool == tool {
                            Capsule().fill(tool == .blur ? AnyShapeStyle(Color.cyan.gradient) : AnyShapeStyle(Theme.brand))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tool.label)
                if tool == .select || tool == .text {
                    Rectangle().fill(.separator).frame(width: 1, height: 18).padding(.horizontal, 4)
                }
            }
        }
        .padding(4)
        .glass(in: Capsule())
        .disabled(model.voiceoverPhase != .idle)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .animation(.snappy(duration: 0.2), value: model.tool)
    }

    /// Invisible buttons carrying the editor's keyboard shortcuts.
    private var shortcuts: some View {
        ZStack {
            Button("", action: model.undo).keyboardShortcut("z", modifiers: .command)
            Button("", action: model.redo).keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") { if model.voiceoverPhase == .idle { exporting = true } }.keyboardShortcut("e", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

/// Countdown before a voiceover starts, then what is being recorded.
private struct VoiceoverOverlay: View {
    var model: EditorModel

    var body: some View {
        Group {
            switch model.voiceoverPhase {
            case .countdown(let n):
                VStack(spacing: 10) {
                    Text("\(n)")
                        .font(.system(size: 88, weight: .bold, design: .rounded).monospacedDigit())
                    Text("准备配音，esc 取消").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 44).padding(.vertical, 22)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            case .recording:
                VStack {
                    HStack(spacing: 8) {
                        RecordingDot(paused: false).frame(width: 18, height: 18)
                        Text("正在配音 \(formatDuration(max(0, model.currentTime - model.voiceoverStart)))")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        Text("按空格结束").font(.system(size: 12)).opacity(0.75)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.top, 14)
                    Spacer()
                }
            default:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
    }
}

private struct RenameField: View {
    @State var name: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名").font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { onSave(name); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
