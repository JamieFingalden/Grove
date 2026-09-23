import AppKit
import SwiftUI

/// diff 面板：顶部一条「工作区 / 暂存区」切换，下面是内容。
struct DiffPane: View {
    @Bindable var model: WorktreeModel

    /// 正在编辑的文件。轻量代码编辑：改个参数值、手写冲突的第三种解法，
    /// 不值得为此开一个 IDE。
    @State private var editingChange: FileChange?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                // 勾行操作条浮在 diff 上方而不是挤进布局：勾选瞬间你正盯着的
                // 那行不该被顶走，取消勾选时内容也不该跳回来。
                .overlay(alignment: .top) {
                    if model.selectedLineCount > 0 {
                        selectionBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.2), value: model.selectedLineCount)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editingChange) { change in
            CodeEditorSheet(
                url: model.path.appendingPathComponent(change.path),
                displayPath: change.path,
                model: model,
                conflictedChange: change.isConflicted ? change : nil
            )
        }
        // 键盘浏览：Space 勾/取消整块，[ / ] 在文件间跳。焦点在 diff 面板时生效。
        .focusable(true)
        .onKeyPress(.space) {
            model.toggleCurrentHunk()
            return .handled
        }
        .onKeyPress("[") {
            model.selectNeighboringChange(offset: -1)
            return .handled
        }
        .onKeyPress("]") {
            model.selectNeighboringChange(offset: 1)
            return .handled
        }
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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

            if let change = model.selectedChange, change.primaryKind != .deleted {
                Button {
                    editingChange = change
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
                .controlSize(.small)
                .help("直接在 Grove 里编辑这个文件（⌘S 保存）；冲突文件改完可以标记为已解决")
            }

            if let change = model.selectedChange, !showsConflictPane(for: change) {
                layoutToggle
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// 阅读（布局 + 字号）控制。选择持久化，变更视图和 PR 评审共用一份。
    private var layoutToggle: some View { DiffReadingControls() }

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
                    DiffContentView(
                        files: diff,
                        model: model.selectedChange?.isConflicted == true ? nil : model,
                        // combined diff 没有可靠的旧/新两侧，分栏只会配出错位的行。
                        allowSplit: model.selectedChange?.isConflicted != true,
                        gapLoader: { path, startLine, count in
                            await model.unchangedLines(path: path, startLine: startLine, count: count)
                        }
                    )
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
    /// 合并冲突的 combined diff 没有可靠的旧/新两侧，禁用分栏。
    var allowSplit = true
    /// 展开未更改区域时读取文件真实内容的加载器：(路径, 起始行, 行数)。
    /// 为 nil（比如 PR 评审没有本地文件可读）时不显示折叠条。
    typealias GapLoader = (_ path: String, _ startLine: Int, _ count: Int) async -> [String]?
    var gapLoader: GapLoader?

    /// 展开过的未更改区域（原始文本行）。key = "文件#hunk"。
    @State private var expandedGapKeys: Set<String> = []
    @State private var expandedGapLines: [String: [String]] = [:]
    @AppStorage(DiffLayout.storageKey) private var layoutRaw = DiffLayout.unified.rawValue

    /// 词级差异区间（line.id 索引）。init 里一次算完，
    /// 滚动时行视图只做查表，不在 body 里反复扫字符串。
    private let wordHighlights: [Int: [Range<String.Index>]]

    private var isSplit: Bool { allowSplit && layoutRaw == DiffLayout.split.rawValue }

    /// 阅读栏的最大宽度（pt）。GitHub 的 diff 页面同样限宽居中：视线扫一行
    /// 100+ 字符已经很吃力，内容左贴边、右侧一大片空背景，观感像布局坏了。
    /// 取值按「常态窗口也能触发」来定：面板超过这个宽就开始居中留边，
    /// 否则只有全屏才生效，用户会觉得改了和没改一样。
    private static let readingColumnWidth: CGFloat = 920

    init(files: [FileDiff], model: WorktreeModel? = nil, showsFileHeaders: Bool = false,
         allowSplit: Bool = true, gapLoader: GapLoader? = nil) {
        self.files = files
        self.model = model
        self.showsFileHeaders = showsFileHeaders
        self.allowSplit = allowSplit
        self.gapLoader = gapLoader

        var highlights: [Int: [Range<String.Index>]] = [:]
        for file in files {
            // line id 是解析器里的全局计数器，跨文件不重复，直接合并。
            for (lineID, ranges) in DiffWordHighlight.ranges(for: file) {
                highlights[lineID, default: []].append(contentsOf: ranges)
            }
        }
        self.wordHighlights = highlights
    }

    var body: some View {
        // 流式文档：长行自动折行、没有横向滚动（旧行为是按最长行定宽的固定画布，
        // 一行 500 字符就把整个文件撑成横向滚动）。
        //
        // 阅读栏限宽 + 居中（GitHub 同款）：超宽窗口下内容像一页居中的文档，
        // 两侧留白对称、读作「边距」；内容左贴边、右侧一大片空背景，
        // 观感上则像布局坏了 —— 短行为主的文件尤其明显。
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
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
                                gapBefore(file: file, hunk: hunk)
                                hunkBody(file: file, hunk: hunk)
                            }
                        }
                    } header: {
                        if showsFileHeaders || files.count > 1 {
                            FileDiffHeader(file: file)
                        }
                    }
                }
            }
            .frame(maxWidth: Self.readingColumnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.visible, axes: .vertical)
        .defaultScrollAnchor(.top)
        .onChange(of: files.map(\.id)) { _, _ in
            // 文件集合变了，展开区域对应的行号已失效，全部收起。
            expandedGapKeys.removeAll()
            expandedGapLines.removeAll()
        }
        // 文件列表或布局变化后必须创建新的滚动容器，否则 SwiftUI 会沿用
        // 上一个文件的纵向偏移。只哈希文件路径而不是整个 diff 内容：
        // 深层哈希几千行文本每次 body 求值都是一笔可观的开销。
        .id("\(files.map(\.id).hashValue)-\(layoutRaw)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - hunk 与折叠区渲染

    @ViewBuilder
    private func hunkBody(file: FileDiff, hunk: DiffHunk) -> some View {
        let path = file.newPath ?? file.oldPath
        if isSplit {
            SplitHunkView(
                hunk: hunk,
                model: model,
                filePath: path,
                highlights: wordHighlights
            )
        } else {
            HunkView(hunk: hunk, model: model, filePath: path, highlights: wordHighlights)
        }
    }

    /// 两个 hunk 之间（以及文件开头到第一个 hunk 之间）被 git 折叠掉的未更改区域。
    /// 展开的内容只进视图层，永远不碰 PatchBuilder —— 那是数据完整性红线。
    @ViewBuilder
    private func gapBefore(file: FileDiff, hunk: DiffHunk) -> some View {
        // 没有 loader（比如 PR 评审没有本地文件）就不显示折叠条。
        if gapLoader != nil, let info = gapInfo(file: file, hunk: hunk) {
            gapContent(file: file, hunk: hunk, info: info)
        }
    }

    @ViewBuilder
    private func gapContent(file: FileDiff, hunk: DiffHunk, info: (startLine: Int, count: Int)) -> some View {
        let key = "\(file.id)#\(hunk.id)"
        if let texts = expandedGapLines[key] {
            gapHunkBody(file: file, hunk: hunk, startLine: info.startLine, texts: texts)
        } else if expandedGapKeys.contains(key) {
            DiffGapSeparator(count: info.count, isLoading: true, action: {})
        } else {
            DiffGapSeparator(count: info.count, isLoading: false) {
                Task {
                    expandedGapKeys.insert(key)
                    guard let path = file.newPath ?? file.oldPath,
                          let texts = await gapLoader?(path, info.startLine, info.count) else { return }
                    expandedGapLines[key] = texts
                }
            }
        }
    }

    /// 计算某个 hunk 前面折叠了多少行未更改内容。
    private func gapInfo(file: FileDiff, hunk: DiffHunk) -> (startLine: Int, count: Int)? {
        let previousNewEnd: Int
        if let index = file.hunks.firstIndex(of: hunk), index > 0 {
            let previous = file.hunks[index - 1]
            previousNewEnd = previous.newStart + previous.newCount - 1
        } else {
            previousNewEnd = 0
        }
        let count = hunk.newStart - previousNewEnd - 1
        guard count > 0 else { return nil }
        return (previousNewEnd + 1, count)
    }

    @ViewBuilder
    private func gapHunkBody(file: FileDiff, hunk: DiffHunk, startLine: Int, texts: [String]) -> some View {
        let path = file.newPath ?? file.oldPath
        let synthetic = Self.gapHunk(hollowing: hunk, startLine: startLine, texts: texts)
        if isSplit {
            SplitHunkView(
                hunk: synthetic,
                model: nil,
                filePath: path,
                highlights: [:]
            )
        } else {
            HunkView(hunk: synthetic, model: nil, filePath: path, highlights: [:], showsHeader: false)
        }
    }

    /// 把展开的原始文本行包成一个合成的 context hunk。行号双侧连续，
    /// id 用负数空间，绝不与解析器分配的正数 id 撞车。
    static func gapHunk(hollowing hunk: DiffHunk, startLine: Int, texts: [String]) -> DiffHunk {
        let base = -(hunk.id * 100_003 + 1)
        var lines: [DiffLine] = []
        lines.reserveCapacity(texts.count)
        for (offset, text) in texts.enumerated() {
            let number = startLine + offset
            lines.append(DiffLine(
                id: base - offset,
                kind: .context,
                text: text.hasSuffix("\r") ? String(text.dropLast()) : text,
                oldNumber: number,
                newNumber: number
            ))
        }
        return DiffHunk(
            id: base,
            header: "",
            oldStart: startLine,
            oldCount: texts.count,
            newStart: startLine,
            newCount: texts.count,
            lines: lines
        )
    }
}

/// hunk 之间未更改区域的折叠条。展开成本是一次文件读取，所以默认收起。
private struct DiffGapSeparator: View {
    let count: Int
    var isLoading = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9.5))
                }
                Text("间隔 \(count) 行未更改，点击展开")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("展开查看这段没有变化的代码")
    }
}

private struct FileDiffHeader: View {
    let file: FileDiff

    var body: some View {
        HStack(spacing: 8) {
            // 文件名完整优先：它是识别文件的主要信息。目录退到后面，
            // 空间不够时截头保尾，而不是把文件名本身截断。
            Text(file.fileName)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .layoutPriority(1)

            if let directory = file.directory {
                Text(directory)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }

            if file.isRename, let oldPath = file.oldPath {
                Text("← \(oldPath)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-2)
            }

            Spacer(minLength: 8)

            Text("+\(file.additions)")
                .foregroundStyle(.green)
            Text("−\(file.deletions)")
                .foregroundStyle(.red)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .help(file.displayPath)
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
                // 文件名永远完整：同目录下的多个文件靠它区分，
                // 中间截断会把唯一有用的信息抹掉。目录另起一行，
                // 截头保尾（保留离文件最近的部分，通常才是区分关键）。
                Text(file.fileName)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .layoutPriority(1)

                if file.isRename, let oldPath = file.oldPath {
                    Text("← \(oldPath)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else if let directory = file.directory {
                    Text(directory)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
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
        // 悬停看完整路径：目录行被截断时的兑底。
        .help(file.displayPath)
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
    var filePath: String?
    var highlights: [Int: [Range<String.Index>]] = [:]
    /// 合成的展开 hunk 没有文件头可显示。
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
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
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07))
            }

            ForEach(hunk.lines) { line in
                DiffLineView(
                    line: line,
                    model: model,
                    filePath: filePath,
                    highlights: highlights[line.id] ?? [],
                    // 行号列按 hunk 自适应：新建文件没有旧行号，
                    // 那一列就是从头到尾的死区，不渲染。
                    showsOldNumber: hunk.hasOldNumbers,
                    showsNewNumber: hunk.hasNewNumbers
                )
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
    var filePath: String?
    /// 词级差异区间：这行里真正变化的片段，叠一层强调底色。
    var highlights: [Range<String.Index>] = []
    /// 这个 hunk 要不要渲染旧/新行号列（新建文件没有旧行号，纯删除没有新行号）。
    var showsOldNumber = true
    var showsNewNumber = true
    @State private var isGutterHovered = false
    /// 阅读字号，与工具条的 A−/A+ 联动（12 = 默认，9…18 可调）。
    @AppStorage(DiffReading.fontSizeKey) private var fontSize = DiffReading.defaultFontSize

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
        HStack(alignment: .top, spacing: 0) {
            // 勾选标记 + 两列行号是唯一的点击热区。之前整行都能点，
            // 双击选词、三击选段会连带触发勾选（点两次 = 勾上又取消，闪烁），
            // 正文区域必须留给文本选择/复制。
            gutter
                .padding(.top, 1)

            Text(marker)
                .frame(width: 10, alignment: .leading)
                .padding(.top, 1)

            Text(CodeSyntax.attributed(
                line.text.isEmpty ? " " : line.text,
                path: filePath,
                highlights: highlights,
                highlight: highlightTint
            ))
            .textSelection(.enabled)
            // 长行折行：这是阅读体验的根。横向滚动意味着读一行要拖一次滚动条，
            // 折行后视线只需纵向移动 —— 和读普通文档一样。
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .foregroundStyle(foreground)
        .lineSpacing(1.5)
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.22) : background)
        // 左缘色条：不用扫整行背景就能一眼分出增/删行（GitHub 同款）。
        .overlay(alignment: .leading) {
            if line.kind == .addition || line.kind == .deletion {
                Rectangle()
                    .fill(line.kind == .addition ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
                    .frame(width: 2.5)
            }
        }
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

                    if showsOldNumber {
                        Text(line.oldNumber.map(String.init) ?? "")
                            .frame(width: Self.gutterWidth, alignment: .trailing)
                    }
                    if showsNewNumber {
                        Text(line.newNumber.map(String.init) ?? "")
                            .frame(width: Self.gutterWidth, alignment: .trailing)
                            .padding(.trailing, 6)
                    }
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
            // 只读场景（历史 / PR 评审）没有勾选交互，
            // 16pt 的勾选空位不预留 —— 那是白送给空气的宽度。
            HStack(spacing: 0) {
                if model != nil {
                    Color.clear.frame(width: 16)
                }
                if showsOldNumber {
                    Text(line.oldNumber.map(String.init) ?? "")
                        .frame(width: Self.gutterWidth, alignment: .trailing)
                }
                if showsNewNumber {
                    Text(line.newNumber.map(String.init) ?? "")
                        .frame(width: Self.gutterWidth, alignment: .trailing)
                        .padding(.trailing, 6)
                }
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

    /// 词级高亮底色：跟着行的增/删属性走，叠在行底色上形成「同色系更深一档」
    /// 的效果 —— 变化片段一眼可辨，又不会满屏刺眼。
    private var highlightTint: Color? {
        switch line.kind {
        case .deletion: .red.opacity(0.22)
        case .addition: .green.opacity(0.28)
        default: nil
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
