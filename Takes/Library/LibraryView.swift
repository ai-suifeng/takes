import AppKit
import SwiftUI

enum LibraryFilter: Hashable {
    case all, favorites, recent, recovered
    case tag(String)

    var title: String {
        switch self {
        case .all: "全部录制"
        case .favorites: "收藏"
        case .recent: "最近 7 天"
        case .recovered: "已恢复"
        case .tag(let t): "# \(t)"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .favorites: "star"
        case .recent: "clock"
        case .recovered: "bandage"
        case .tag: "number"
        }
    }
}

struct LibraryView: View {
    var model: AppModel
    @State private var filter: LibraryFilter = .all
    @State private var search = ""
    @State private var selection: Set<UUID> = []
    @State private var renaming: LibraryItem?
    @State private var tagging: LibraryItem?

    private var library: LibraryStore { model.library }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .sheet(item: $renaming) { item in
            RenameSheet(name: item.meta.name) { name in
                library.update(item.id) { $0.name = name }
            }
        }
        .sheet(item: $tagging) { item in
            TagSheet(tags: item.meta.tags, allTags: library.allTags) { tags in
                library.update(item.id) { $0.tags = tags }
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { filter }, set: { filter = $0 ?? .all })) {
            Section("资料库") {
                row(.all, count: library.items.count)
                row(.favorites, count: library.items.filter(\.meta.favorite).count)
                row(.recent, count: library.items.filter { $0.meta.createdAt > Date().addingTimeInterval(-7 * 86400) }.count)
                let recovered = library.items.filter { $0.meta.status == .recovered }.count
                if recovered > 0 { row(.recovered, count: recovered) }
            }
            if !library.allTags.isEmpty {
                Section("标签") {
                    ForEach(library.allTags, id: \.self) { tag in
                        row(.tag(tag), count: library.items.filter { $0.meta.tags.contains(tag) }.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { storageFooter }
    }

    private func row(_ f: LibraryFilter, count: Int) -> some View {
        Label {
            HStack {
                Text(f.title)
                Spacer()
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: f.symbol)
        }
        .tag(f)
    }

    private var storageFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                Text("已用 \(ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.open(AppSettings.shared.libraryFolder)
            } label: {
                Label("在访达中显示", systemImage: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: Detail

    private var filtered: [LibraryItem] {
        let week = Date().addingTimeInterval(-7 * 86400)
        let base = library.items.filter { item in
            switch filter {
            case .all: true
            case .favorites: item.meta.favorite
            case .recent: item.meta.createdAt > week
            case .recovered: item.meta.status == .recovered
            case .tag(let t): item.meta.tags.contains(t)
            }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { item in
            let fields = [item.meta.name, item.meta.sourceTitle, item.meta.apps.joined(separator: " "),
                          item.meta.tags.joined(separator: " "), item.screenText]
            return fields.contains { $0.lowercased().contains(q) }
        }
    }

    private var groups: [(title: String, items: [LibraryItem])] {
        let cal = Calendar.current
        var order: [String] = []
        var dict: [String: [LibraryItem]] = [:]
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "yyyy 年 M 月"
        for item in filtered {
            let d = item.meta.createdAt
            let key: String
            if cal.isDateInToday(d) { key = "今天" }
            else if cal.isDateInYesterday(d) { key = "昨天" }
            else if d > Date().addingTimeInterval(-7 * 86400) { key = "本周" }
            else { key = monthFormatter.string(from: d) }
            if dict[key] == nil { order.append(key) }
            dict[key, default: []].append(item)
        }
        return order.map { ($0, dict[$0]!) }
    }

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 270), spacing: 24, alignment: .top)]

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if filtered.isEmpty {
                    emptyState
                } else {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: group.title)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                                ForEach(group.items) { item in
                                    ProjectCard(item: item, selected: selection.contains(item.id),
                                                onDelete: { confirmDelete(selection.contains(item.id) ? selection : [item.id]) })
                                        .onTapGesture(count: 2) { model.openEditor(item.bundle) }
                                        .onTapGesture { toggleSelect(item.id) }
                                        .contextMenu { contextMenu(item) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
        .background(.background)
        .searchable(text: $search, placement: .toolbar, prompt: "搜索名称、App、标签或画面中的文字")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showCaptureBar()
                } label: {
                    Label("新录制", systemImage: "record.circle")
                }
                .help("新录制 \(HotKeys.record.display)")
            }
        }
        .onDeleteCommand { confirmDelete(selection) }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(filter.title).font(.system(size: 28, weight: .bold))
                Text(search.isEmpty ? "\(filtered.count) 个录制 · 共 \(formatDuration(filtered.reduce(0) { $0 + $1.meta.duration }))"
                                    : "找到 \(filtered.count) 个结果")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.showCaptureBar()
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(.white).frame(width: 10, height: 10)
                    Text("新录制")
                    Text(HotKeys.record.display).font(.system(size: 11, weight: .medium)).opacity(0.75)
                }
            }
            .buttonStyle(BrandButtonStyle(large: true))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.brand.opacity(0.15)).frame(width: 140, height: 140)
                Circle().fill(Theme.brand.opacity(0.25)).frame(width: 96, height: 96)
                Image(systemName: search.isEmpty ? "record.circle" : "magnifyingglass")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Theme.brand)
            }
            Text(search.isEmpty ? "还没有录制" : "没有找到相关录制")
                .font(.system(size: 20, weight: .semibold))
            Text(search.isEmpty ? "按 \(HotKeys.record.display) 随时开始录制。录制中可以随时暂停，\n每次暂停都会自动分成一段，讲错了一键重录这一段。"
                                : "试试搜索录制时屏幕上出现过的文字。")
                .multilineTextAlignment(.center)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder
    private func contextMenu(_ item: LibraryItem) -> some View {
        Button("打开编辑器") { model.openEditor(item.bundle) }
        Button(item.meta.favorite ? "取消收藏" : "收藏") { library.update(item.id) { $0.favorite.toggle() } }
        Button("重命名…") { renaming = item }
        Button("编辑标签…") { tagging = item }
        Divider()
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.bundle.url]) }
        Divider()
        Button("移到废纸篓") {
            let ids = selection.contains(item.id) ? selection : [item.id]
            library.trash(ids)
            selection.subtract(ids)
        }
        Button("彻底删除…", role: .destructive) {
            confirmDelete(selection.contains(item.id) ? selection : [item.id])
        }
    }

    private func confirmDelete(_ ids: Set<UUID>) {
        let targets = library.items.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = targets.count == 1 ? "彻底删除「\(targets[0].meta.name)」？" : "彻底删除这 \(targets.count) 个录制？"
        let size = ByteCountFormatter.string(fromByteCount: targets.reduce(0) { $0 + $1.sizeBytes }, countStyle: .file)
        alert.informativeText = "录制文件会直接从磁盘删除（\(size)），不会进入废纸篓，无法恢复。"
        let exports = targets.flatMap(\.meta.exportedFiles).filter { FileManager.default.fileExists(atPath: $0) }
        let checkbox = NSButton(checkboxWithTitle: "同时删除导出的视频（\(exports.count) 个）", target: nil, action: nil)
        if !exports.isEmpty { alert.accessoryView = checkbox }
        alert.addButton(withTitle: "彻底删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.deletePermanently(Set(targets.map(\.id)), includingExports: !exports.isEmpty && checkbox.state == .on)
        selection.subtract(ids)
    }

    private func toggleSelect(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }
}

private struct ProjectCard: View {
    let item: LibraryItem
    let selected: Bool
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The frame sets the size; the thumbnail fills it inside an overlay so a wide image cannot widen the card.
            Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                Rectangle().fill(.quaternary)
                if let image = ThumbnailCache.shared.image(for: item.bundle) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.meta.kind.symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
                }
                if hovering {
                    Color.black.opacity(0.25)
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .glass(in: Circle())
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Badge(text: formatDuration(item.meta.duration)).padding(8)
            }
            .overlay(alignment: .bottomLeading) {
                if item.meta.segments.count > 1 {
                    Badge(text: "\(item.meta.segments.count) 段", symbol: "square.stack").padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("彻底删除")
                    .padding(8)
                    .transition(.opacity)
                } else if item.meta.favorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(6)
                        .background(.black.opacity(0.5), in: Circle())
                        .padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if item.meta.status == .recovered {
                    Badge(text: "已恢复", symbol: "bandage").padding(8)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Theme.coral : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 0.5)
            )
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.08), radius: hovering ? 16 : 6, y: hovering ? 8 : 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.meta.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: item.meta.kind.symbol)
                    Text(item.meta.createdAt, format: .dateTime.month().day().hour().minute())
                        .lineLimit(1).fixedSize()
                    if !item.meta.apps.isEmpty {
                        Text("·")
                        Text(item.meta.apps.prefix(3).joined(separator: "、")).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                if !item.meta.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.meta.tags.prefix(4), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.coral.opacity(0.14), in: Capsule())
                                .foregroundStyle(Theme.coral)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for bundle: ProjectBundle) -> NSImage? {
        let url = bundle.thumbnailURL as NSURL
        if let image = cache.object(forKey: url) { return image }
        guard let image = NSImage(contentsOf: bundle.thumbnailURL) else { return nil }
        cache.setObject(image, forKey: url)
        return image
    }

    func invalidate(_ bundle: ProjectBundle) {
        cache.removeObject(forKey: bundle.thumbnailURL as NSURL)
    }
}

private struct RenameSheet: View {
    @State var name: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名").font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onSave(trimmed) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct TagSheet: View {
    @State var tags: [String]
    var allTags: [String]
    var onSave: ([String]) -> Void
    @State private var newTag = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("标签").font(.headline)
            HStack {
                TextField("新标签", text: $newTag).textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("添加", action: add).disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(Set(allTags + tags)).sorted(), id: \.self) { tag in
                    let on = tags.contains(tag)
                    Button {
                        if on { tags.removeAll { $0 == tag } } else { tags.append(tag) }
                    } label: {
                        Text(tag)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.quaternary), in: Capsule())
                            .foregroundStyle(on ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("完成") { onSave(tags); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func add() {
        let t = newTag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if !tags.contains(t) { tags.append(t) }
        newTag = ""
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
