import AppKit
import SwiftUI

/// diff 面板：顶部一条「工作区 / 暂存区」切换，下面是内容。
struct DiffPane: View {
    @Bindable var model: WorktreeModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.selectedLineCount > 0 {
                Divider()
                selectionBar
            }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 勾了行之后才出现的操作条。
    ///
    /// 平时不占地方 —— 分行提交是少数场景，常驻一条工具栏会让「整文件暂存」
    /// 这个高频操作反而变远。
    private var selectionBar: some View {
        HStack(spacing: 8) {
            Text("已选 \(model.selectedLineCount) 行")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()

            Spacer()

            Button("选中整个文件") {
                model.selectAllChangesInCurrentFile()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .help("选中这个文件的全部改动行，再取消不要的那几行，适合分散小改动多的文件")

            Button("取消选择") { 
                model.selectedLines.removeAll() 
                model.selectionAnchorLineID = nil
            }
                .buttonStyle(.borderless)
                .font(.system(size: 11))

            if model.diffSide == .worktree {
                Button("丢弃选中行…") {
                    Task { await confirmDiscardLines() }
                }
                .font(.system(size: 11))
                .disabled(!model.canApplySelectedLines)
            }

            Button(model.diffSide == .staged ? "取消暂存选中行" : "暂存选中行") {
                Task { await model.applySelectedLines() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!model.canApplySelectedLines)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    @MainActor
    private func confirmDiscardLines() async {
        let alert = NSAlert()
        alert.messageText = "丢弃选中的 \(model.selectedLineCount) 行改动？"
        alert.informativeText = "这个操作无法撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "丢弃")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await model.discardSelectedLines()
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let change = model.selectedChange {
                Image(systemName: change.primaryKind.systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(change.isConflicted ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                Text(change.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)

                if let originalPath = change.originalPath {
                    Text("← \(originalPath)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                if let kind = change.conflict {
                    Text(kind.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.12), in: Capsule())
                }
            } else {
                Text("未选择文件")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if let change = model.selectedChange, change.conflict?.hasTextualMarkers == true {
                // 逐块解决是主路径；combined diff 留给想看「git 眼里两边各改了什么」的人。
                Picker("", selection: $model.conflictViewMode) {
                    ForEach(WorktreeModel.ConflictViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            } else if let change = model.selectedChange, change.isPartiallyStaged {
                // 只有「两边都有内容」时这个切换才有意义。文件只在一侧有改动时
                // 显示切换只会诱导用户点到一个空面板。
                Picker("", selection: $model.diffSide) {
                    ForEach(WorktreeModel.DiffSide.allCases) { side in
                        Text(side.label).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if model.selectedChange == nil {
                ContentUnavailableView {
                    Label("选择一个文件", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("从左侧列表挑一个文件查看它的改动。")
                }
            } else if let change = model.selectedChange, showsConflictPane(for: change) {
                ConflictPane(model: model, change: change)
            } else if let diff = model.diff {
                if diff.isEmpty {
                    emptyDiffExplanation
                } else {
                    // 冲突文件的 combined diff 只读：从三方 diff 里裁出来的补丁没法 `git apply`，
                    // 勾行暂存只会报一堆看不懂的错。
                    DiffContentView(files: diff, model: model.selectedChange?.isConflicted == true ? nil : model)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 冲突文件默认进解决面板。没有标记可解析的形态（一侧删除、双方删除）
    /// 只有解决面板一种看法 —— 那种文件的 combined diff 是空的。
    private func showsConflictPane(for change: FileChange) -> Bool {
        guard let kind = change.conflict else { return false }
        return !kind.hasTextualMarkers || model.conflictViewMode == .resolve
    }

    /// diff 为空有好几种正当原因。直接显示空白会让人以为程序坏了，
    /// 所以这里把「为什么没内容」说清楚。
    @ViewBuilder
    private var emptyDiffExplanation: some View {
        let change = model.selectedChange
        ContentUnavailableView {
            Label("没有可显示的改动", systemImage: "equal.circle")
        } description: {
            if change?.isPartiallyStaged == false && model.diffSide == .staged {
                Text("这个文件在暂存区没有改动。")
            } else if change?.staged != nil && model.diffSide == .worktree {
                Text("改动全在暂存区里。切到「暂存区」查看。")
            } else {
                Text("可能只是文件权限或换行符变了。")
            }
        }
    }
}

// MARK: - diff 内容

struct DiffContentView: View {
    let files: [FileDiff]
    /// 有模型就允许勾选行（变更视图）；没有就是只读展示（提交历史）。
    var model: WorktreeModel?
    /// 历史页一次只展示一个选中文件，仍要保留文件标题，避免代码失去归属感。
    var showsFileHeaders = false
    /// 提前算好的内容宽度。等宽字体的行宽可以按字符数精确估计，不需要靠
    /// 逐行 GeometryReader 现场量 —— 那套做法在大 diff 下每帧要收集上千个
    /// preference 再重算 body，滚动直接掉帧。
    private let contentWidth: CGFloat

    init(files: [FileDiff], model: WorktreeModel? = nil, showsFileHeaders: Bool = false) {
        self.files = files
        self.model = model
        self.showsFileHeaders = showsFileHeaders
        self.contentWidth = Self.estimatedWidth(for: files)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(files) { file in
                        Section {
                            if file.isBinary {
                                DiffNotice(
                                    text: "二进制文件，无法按行比较。",
                                    systemImage: "doc.badge.gearshape"
                                )
                            } else if file.isModeChangeOnly {
                                DiffNotice(
                                    text: "只有文件权限变了：\(file.oldMode ?? "?") → \(file.newMode ?? "?")",
                                    systemImage: "lock.rotation"
                                )
                            } else if file.hunks.isEmpty {
                                if file.isDiffMissing {
                                    DiffNotice(
                                        text: "文件过大，服务端未返回 diff 内容，本地也没有可补算的提交；请在浏览器中查看。",
                                        systemImage: "exclamationmark.triangle"
                                    )
                                } else {
                                    DiffNotice(text: "内容没有变化。", systemImage: "equal.circle")
                                }
                            } else {
                                ForEach(file.hunks) { hunk in
                                    HunkView(hunk: hunk, model: model)
                                }
                            }
                        } header: {
                            if showsFileHeaders || files.count > 1 {
                                FileDiffHeader(file: file)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: max(geometry.size.width, contentWidth), alignment: .leading)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.visible, axes: [.vertical, .horizontal])
            // 内容比视口小的时候，双向滚动的 ScrollView 会把它居中 ——
            // 一个只改了两行的 diff 就会飘在面板正中间。锚到左上角才是代码该有的样子。
            .defaultScrollAnchor(.topLeading)
            // 文件列表变化后必须创建新的滚动容器。否则 SwiftUI 会沿用上一个文件的
            // 横纵偏移，用户点开新文件时可能直接看到右下角甚至一片空白。
            // 只哈希文件路径而不是整个 diff 内容：这里只需要“文件集合变了就重置
            // 滚动”，深层哈希几千行文本每次 body 求值都是一笔可观的开销。
            .id(files.map(\.id).hashValue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - 宽度估算

    /// 11.5pt 等宽字体单个 ASCII 字符约 6.9pt，取 7 留余量。
    private static let characterWidth: CGFloat = 7
    /// 勾选列 + 两列行号 + 标记列 + 内边距。
    private static let gutterWidth: CGFloat = 16 + 38 + 38 + 6 + 10 + 24

    static func estimatedWidth(for files: [FileDiff]) -> CGFloat {
        var maxUnits = 0
        for file in files {
            // 文件头除了路径还有箭头和增删计数。
            maxUnits = max(maxUnits, displayUnits(file.displayPath) + 24)
            for hunk in file.hunks {
                maxUnits = max(maxUnits, displayUnits(hunk.header) + 12)
                for line in hunk.lines {
                    maxUnits = max(maxUnits, displayUnits(line.text))
                }
            }
        }
        return CGFloat(maxUnits) * characterWidth + gutterWidth
    }

    /// 把一行文本换算成等宽字符单位数：ASCII 算 1，CJK/全角/emoji 算 2，
    /// 制表符按 8 列算。宁可偏宽 —— 估窄了会把长行截没。
    static func displayUnits(_ text: String) -> Int {
        var units = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09: units += 8
            case 0x00...0x7F: units += 1
            default: units += isWide(scalar) ? 2 : 1
            }
        }
        return units
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

private struct FileDiffHeader: View {
    let file: FileDiff

    var body: some View {
        HStack(spacing: 8) {
            // 不截断路径。这个标题栏在双向滚动的 ScrollView 里，宽度由所在分组的
            // 内容决定；让它参与压缩的话，短 diff 里的路径会被截成 `…pp.swift`
            // 这种没法认的样子。让它把内容撑宽、交给横向滚动更合理。
            Text(file.displayPath)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .fixedSize(horizontal: true, vertical: false)

            if file.isRename, let oldPath = file.oldPath {
                Text("← \(oldPath)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            // 增删计数紧跟在路径后面，不用 Spacer 推到右边。
            // 这个标题栏在横向可滚动的容器里，Spacer 会一路撑到滚动内容的宽度，
            // 把计数顶到可视区之外 —— 短 diff 里就表现为「计数不见了」。
            Text("+\(file.additions)")
                .foregroundStyle(.green)
            Text("−\(file.deletions)")
                .foregroundStyle(.red)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// diff 文件导航里的共用行。历史和 PR 评审都使用同一套状态与增删统计。
struct DiffFileRow: View {
    let file: FileDiff

    var body: some View {
        HStack(spacing: 8) {
            Text(badge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 1) {
                Text(file.displayPath)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if file.isRename, let oldPath = file.oldPath {
                    Text("原路径：\(oldPath)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Text("+\(file.additions)")
                .foregroundStyle(.green)
            Text("−\(file.deletions)")
                .foregroundStyle(.red)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .padding(.vertical, 1)
    }

    private var badge: String {
        if file.isNewFile { return "A" }
        if file.isDeletedFile { return "D" }
        if file.isRename { return "R" }
        return "M"
    }

    private var tint: Color {
        if file.isNewFile { return .green }
        if file.isDeletedFile { return .red }
        if file.isRename { return .blue }
        return .orange
    }
}

private struct HunkView: View {
    let hunk: DiffHunk
    var model: WorktreeModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let model {
                    // 整块勾选。逐行点在几十行的 hunk 上太累，
                    // 而「这一块整个要」本来就是最常见的意图。
                    Button {
                        model.toggleHunk(hunk)
                    } label: {
                        Image(systemName: hunkIcon(model.hunkSelectionState(hunk)))
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help("选中/取消这一整块")
                }

                Text(hunk.header)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07))

            ForEach(hunk.lines) { line in
                DiffLineView(line: line, model: model)
            }
        }
    }

    private func hunkIcon(_ state: WorktreeModel.HunkSelection) -> String {
        switch state {
        case .none: "square"
        case .partial: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }
}

private struct DiffLineView: View {
    let line: DiffLine
    var model: WorktreeModel?
    @State private var isGutterHovered = false

    private var isSelectable: Bool {
        model != nil && (line.kind == .addition || line.kind == .deletion)
    }

    private var isSelected: Bool {
        model?.selectedLines.contains(line.id) ?? false
    }

    /// 行号栏宽度固定，让所有行的正文左对齐。跟着内容自适应的话，
    /// 滚过 4 位数行号时整块正文会横向抖动。
    private static let gutterWidth: CGFloat = 38

    var body: some View {
        HStack(spacing: 0) {
            // 勾选标记 + 两列行号是唯一的点击热区。之前整行都能点，
            // 双击选词、三击选段会连带触发勾选（点两次 = 勾上又取消，闪烁），
            // 正文区域必须留给文本选择/复制。
            gutter

            Text(marker)
                .frame(width: 10, alignment: .leading)

            Text(line.text.isEmpty ? " " : line.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(foreground)
        .padding(.vertical, 0.5)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.22) : background)
    }

    /// 勾选列 + 双侧行号列。可选行包成一个 Button；
    /// 上下文行不可选，保持纯展示（宽度一致，正文不错位）。
    @ViewBuilder
    private var gutter: some View {
        if isSelectable, let model {
            Button {
                // Shift + 点击 = 从上次点击的行选到这里，
                // 连续十几行改动不用一行行点。
                model.toggleLine(
                    line,
                    extendingSelection: NSEvent.modifierFlags.contains(.shift)
                )
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 9.5))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 16)

                    Text(line.oldNumber.map(String.init) ?? "")
                        .frame(width: Self.gutterWidth, alignment: .trailing)
                    Text(line.newNumber.map(String.init) ?? "")
                        .frame(width: Self.gutterWidth, alignment: .trailing)
                        .padding(.trailing, 6)
                }
                .contentShape(Rectangle())
                .background(isGutterHovered ? Color.primary.opacity(0.06) : Color.clear)
            }
            .buttonStyle(.borderless)
            .onHover { hovering in
                isGutterHovered = hovering
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .help("点击选中此行；Shift + 点击从上次选的行选到这里")
        } else {
            HStack(spacing: 0) {
                Color.clear.frame(width: 16)
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: Self.gutterWidth, alignment: .trailing)
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: Self.gutterWidth, alignment: .trailing)
                    .padding(.trailing, 6)
            }
        }
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        case .noNewline: "\\"
        }
    }

    private var foreground: Color {
        switch line.kind {
        case .noNewline: .secondary
        default: .primary
        }
    }

    private var background: Color {
        switch line.kind {
        // 用低饱和度的底色而不是纯绿/纯红：整屏高饱和色块看久了眼睛受不了，
        // 而且深色模式下会盖住文字。
        case .addition: .green.opacity(0.13)
        case .deletion: .red.opacity(0.13)
        case .context, .noNewline: .clear
        }
    }
}

private struct DiffNotice: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }
}
