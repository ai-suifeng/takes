import SwiftUI

struct InspectorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.inspectorTab {
                    case .style: StyleInspector(model: model)
                    case .cursor: CursorInspector(model: model)
                    case .zoom: ZoomInspector(model: model)
                    case .annotations: AnnotationInspector(model: model)
                    case .privacy: PrivacyInspector(model: model)
                    case .media: MediaInspector(model: model)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 300)
        .background(.background.secondary)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.inspectorTab = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 14, weight: .medium))
                        Text(tab.label).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(model.inspectorTab == tab ? Theme.coral : .secondary)
                    .background(model.inspectorTab == tab ? Theme.coral.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
    }
}

// MARK: - Building blocks

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            content
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(format(value)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

struct ColorRow: View {
    @Binding var color: RGBA

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RGBA.palette, id: \.self) { c in
                Circle().fill(c.color).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                    .overlay(Circle().stroke(Color.primary, lineWidth: color == c ? 2 : 0).padding(-3))
                    .onTapGesture { color = c }
            }
            ColorPicker("", selection: Binding(get: { color.color }, set: { color = RGBA($0) }), supportsOpacity: false)
                .labelsHidden()
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(title, systemImage: symbol).font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - Style

private struct StyleInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        InspectorSection(title: "背景") {
            Picker("", selection: $model.edit.style.background.kind) {
                Text("渐变").tag(BackgroundStyle.Kind.gradient)
                Text("纯色").tag(BackgroundStyle.Kind.solid)
                Text("无").tag(BackgroundStyle.Kind.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.edit.style.background.kind {
            case .gradient:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(BackgroundStyle.gradients.indices, id: \.self) { i in
                        let g = BackgroundStyle.gradients[i]
                        let selected = model.edit.style.background.gradient == i
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [g.a.color, g.b.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .aspectRatio(1.3, contentMode: .fit)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.primary, lineWidth: selected ? 2 : 0).padding(-3))
                            .help(g.name)
                            .onTapGesture { model.edit.style.background.gradient = i }
                    }
                }
                .padding(3)
            case .solid:
                ColorPicker("颜色", selection: Binding(get: { model.edit.style.background.solid.color },
                                                     set: { model.edit.style.background.solid = RGBA($0) }),
                            supportsOpacity: false)
                    .font(.system(size: 12))
            case .none:
                Text("画面将铺满输出，不加边距与圆角。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }

        if model.edit.style.background.kind != .none {
            InspectorSection(title: "画面") {
                LabeledSlider(title: "边距", value: $model.edit.style.padding, range: 0...0.2)
                LabeledSlider(title: "圆角", value: $model.edit.style.cornerRadius, range: 0...0.06,
                              format: { String(format: "%.0f", $0 * 1000) })
                LabeledSlider(title: "阴影", value: $model.edit.style.shadow, range: 0...1)
            }
        }

        InspectorSection(title: "比例") {
            Picker("", selection: $model.edit.style.aspect) {
                ForEach(AspectRatio.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }

        InspectorSection(title: "片段衔接") {
            Picker("", selection: $model.edit.style.transition) {
                ForEach(TakeTransition.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("每次暂停都会切成一段。在时间线上拖动片段两端的黄色把手可以裁剪，右键可以跳过整段。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Cursor

private struct CursorInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        InspectorSection(title: "光标") {
            ToggleRow(title: "显示光标", symbol: "cursorarrow", isOn: $model.edit.cursor.visible)
            if model.edit.cursor.visible {
                LabeledSlider(title: "大小", value: $model.edit.cursor.scale, range: 0.8...3,
                              format: { String(format: "%.1f×", $0) })
                LabeledSlider(title: "平滑", value: $model.edit.cursor.smoothing, range: 0...1)
                ToggleRow(title: "静止时自动隐藏", symbol: "eye.slash", isOn: $model.edit.cursor.hideWhenIdle)
                ToggleRow(title: "点击动效", symbol: "cursorarrow.click.2", isOn: $model.edit.cursor.clickEffect)
            }
        }
        InspectorSection(title: "按键") {
            ToggleRow(title: "显示快捷键", symbol: "command", isOn: $model.edit.showKeystrokes)
            Text("录制时按下的 ⌘ ⌃ ⌥ 组合键会显示在画面底部。需要辅助功能权限。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Zoom

private struct ZoomInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        InspectorSection(title: "自动缩放") {
            ToggleRow(title: "跟随点击自动放大", symbol: "sparkles", isOn: Binding(
                get: { model.edit.autoZoom },
                set: { on in
                    model.edit.autoZoom = on
                    if on { model.regenerateAutoZoom() } else { model.edit.zooms.removeAll { $0.isAuto } }
                }))
            LabeledSlider(title: "默认倍数", value: $model.edit.defaultZoomScale, range: 1.2...3.5,
                          format: { String(format: "%.1f×", $0) })
            Button {
                model.regenerateAutoZoom()
            } label: {
                Label("根据点击重新生成", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            Text("在时间线的「缩放」轨道上双击可手动添加。").font(.system(size: 11)).foregroundStyle(.secondary)
        }

        if case .zoom(let id) = model.selection, let i = model.edit.zooms.firstIndex(where: { $0.id == id }) {
            InspectorSection(title: "选中的缩放") {
                LabeledSlider(title: "倍数", value: $model.edit.zooms[i].scale, range: 1.1...4,
                              format: { String(format: "%.1f×", $0) })
                Picker("", selection: $model.edit.zooms[i].mode) {
                    Text("跟随鼠标").tag(ZoomRegion.Mode.follow)
                    Text("固定位置").tag(ZoomRegion.Mode.fixed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.edit.zooms[i].mode == .fixed {
                    LabeledSlider(title: "水平位置", value: $model.edit.zooms[i].center.x, range: 0...1)
                    LabeledSlider(title: "垂直位置", value: $model.edit.zooms[i].center.y, range: 0...1)
                }
                deleteButton("删除缩放") { model.deleteSelection() }
            }
        }

        InspectorSection(title: "全部 \(model.edit.zooms.count) 个") {
            ForEach(model.edit.zooms.sorted { $0.start < $1.start }) { z in
                ItemRow(symbol: z.isAuto ? "sparkles" : "plus.magnifyingglass",
                        title: String(format: "%.1f× · %@", z.scale, z.mode == .follow ? "跟随" : "固定"),
                        time: z.start, selected: model.selection == .zoom(z.id)) {
                    model.select(.zoom(z.id))
                    model.seek(source: z.start)
                }
            }
        }
    }
}

// MARK: - Annotations

private struct AnnotationInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        if case .annotation(let id) = model.selection, let i = model.edit.annotations.firstIndex(where: { $0.id == id }) {
            let kind = model.edit.annotations[i].kind
            InspectorSection(title: kind.label) {
                if kind.isRectBased && kind != .text {
                    Picker("", selection: $model.edit.annotations[i].kind) {
                        ForEach([Annotation.Kind.box, .spotlight, .magnify, .rect], id: \.self) { k in
                            Label(k.label, systemImage: k.symbol).tag(k)
                        }
                    }
                    .labelsHidden()
                }
                if kind == .text {
                    TextField("文字", text: $model.edit.annotations[i].text).textFieldStyle(.roundedBorder)
                }
                ColorRow(color: $model.edit.annotations[i].color)
                if kind != .text && kind != .spotlight {
                    LabeledSlider(title: "粗细", value: $model.edit.annotations[i].lineWidth, range: 1...24,
                                  format: { String(format: "%.0f", $0) })
                }
                LabeledSlider(title: "时长", value: $model.edit.annotations[i].duration, range: 0.3...15,
                              format: { String(format: "%.1f 秒", $0) })
                if kind == .box {
                    ToggleRow(title: "步骤编号", symbol: "number.circle", isOn: Binding(
                        get: { model.edit.annotations[i].step != nil },
                        set: { on in
                            model.edit.annotations[i].step = on ? model.edit.annotations.compactMap(\.step).max().map { $0 + 1 } ?? 1 : nil
                        }))
                    if let step = model.edit.annotations[i].step {
                        Stepper("编号 \(step)", value: Binding(get: { step }, set: { model.edit.annotations[i].step = max(1, $0) }))
                            .font(.system(size: 12))
                    }
                }
                ToggleRow(title: "结束时淡出", symbol: "wand.and.rays", isOn: $model.edit.annotations[i].fades)
                deleteButton("删除标注") { model.deleteSelection() }
            }
        } else {
            InspectorSection(title: "添加标注") {
                Text("在预览上方的工具栏选择工具，然后在画面上拖拽。录制时按住 \(AppSettings.shared.highlightTrigger.label) 点击，会自动框出被点的按钮。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }

        InspectorSection(title: "全部 \(model.edit.annotations.count) 个") {
            if model.edit.annotations.isEmpty {
                Text("还没有标注").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(model.edit.annotations.sorted { $0.start < $1.start }) { a in
                ItemRow(symbol: a.kind.symbol,
                        title: a.step.map { "\(a.kind.label) · 步骤 \($0)" } ?? (a.kind == .text ? a.text : a.kind.label),
                        time: a.start, selected: model.selection == .annotation(a.id), tint: a.color.color) {
                    model.select(.annotation(a.id))
                    model.seek(source: a.start + min(0.4, a.duration / 2))
                }
            }
        }
    }
}

// MARK: - Media

private struct MediaInspector: View {
    @Bindable var model: EditorModel

    var body: some View {
        InspectorSection(title: "声音") {
            if model.meta.hasMic || hasVoiceover {
                ToggleRow(title: "声音增强", symbol: "waveform.badge.plus", isOn: $model.edit.normalizeAudio)
            }
            if model.meta.hasMic {
                Group {
                    if model.isMeasuringLoudness {
                        Text("正在分析讲解音量…")
                    } else if model.edit.normalizeAudio, let db = model.edit.micAutoGain {
                        Text(db > 0.5 ? String(format: "已把讲解声音提高 %.1f dB 到标准响度，并防止爆音。", db)
                                      : "讲解声音已经够响，无需提高。")
                    } else {
                        Text("关闭后使用麦克风的原始音量。")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                LabeledSlider(title: "麦克风", value: $model.edit.micVolume, range: 0...2)
            }
            if model.meta.hasSystemAudio {
                LabeledSlider(title: "系统声音", value: $model.edit.systemVolume, range: 0...2)
            }
            if hasVoiceover {
                LabeledSlider(title: "配音", value: $model.edit.voiceoverVolume, range: 0...2)
            }
            if !model.meta.hasMic && !model.meta.hasSystemAudio && !hasVoiceover {
                Text("这次录制没有声音。可以点时间线上的「配音」，边看边录一段。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        InspectorSection(title: "摄像头") {
            if model.meta.hasCamera {
                ToggleRow(title: "显示摄像头", symbol: "video", isOn: $model.edit.camera.visible)
                Picker("形状", selection: $model.edit.camera.shape) {
                    ForEach(CameraSettings.Shape.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: "大小", value: $model.edit.camera.size, range: 0.1...0.45)
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        cornerButton(.topLeft)
                        cornerButton(.topRight)
                    }
                    GridRow {
                        cornerButton(.bottomLeft)
                        cornerButton(.bottomRight)
                    }
                }
            } else {
                Text("这次录制没有开启摄像头。可以在录制工具条中选择摄像头。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var hasVoiceover: Bool { !model.edit.voiceovers.isEmpty }

    private func cornerButton(_ c: CameraSettings.Corner) -> some View {
        let selected = model.edit.camera.corner == c
        let align: Alignment = switch c {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
        return RoundedRectangle(cornerRadius: 8)
            .fill(.primary.opacity(0.06))
            .frame(height: 52)
            .overlay(alignment: align) {
                Circle().fill(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary.opacity(0.5)))
                    .frame(width: 16, height: 16).padding(7)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.coral : .clear, lineWidth: 1.5))
            .onTapGesture { model.edit.camera.corner = c }
    }
}

// MARK: - Shared rows

struct ItemRow: View {
    let symbol: String
    let title: String
    let time: Double
    let selected: Bool
    var tint: Color = Theme.coral
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Text(formatDuration(time, showFraction: true))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .background(selected ? Theme.coral.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func deleteButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(role: .destructive, action: action) {
        Label(title, systemImage: "trash")
    }
    .controlSize(.small)
}
