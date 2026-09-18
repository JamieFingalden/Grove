import AppKit
import SwiftUI

/// 冲突文件的解决面板。
///
/// 顶部一条图例说清「当前 / 传入」两侧各是谁 —— git 的 ours/theirs 在变基时是反的，
/// 不写出来用户十有八九选反；中间逐块给出「当前 / 传入 / 双方」三个选择，选一块写一次盘；
/// 全部选完后一键标记为已解决。一侧删除、二进制这类没有「块」可言的形态，
/// 整个文件就是「留下还是删掉」两个按钮。
struct ConflictPane: View {
    @Bindable var model: WorktreeModel
    let change: FileChange

    var body: some View {
        VStack(spacing: 0) {
            ConflictLegend(model: model, change: change)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if let kind = change.conflict, !kind.hasTextualMarkers {
            WholeFileChooser(model: model, change: change, kind: kind, reason: kind.explanation)
        } else {
            switch model.conflictContent {
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                WholeFileChooser(
                    model: model, change: change, kind: change.conflict ?? .bothModified,
                    reason: "工作区里找不到这个文件，可能已经在外部被删掉了。"
                )
            case .binary:
                WholeFileChooser(
                    model: model, change: change, kind: change.conflict ?? .bothModified,
                    reason: "二进制文件没法按块合并，只能整个文件选一边。"
                )
            case .undecodable:
                WholeFileChooser(
                    model: model, change: change, kind: change.conflict ?? .bothModified,
                    reason: "文件不是 UTF-8 文本，Grove 不改写它以免写坏内容。可以整个文件选一边，或者在编辑器里手工解决后标记为已解决。"
                )
            case .editor(let editor):
                if editor.document.blocks.isEmpty {
                    NoMarkersView(model: model, change: change)
                } else {
                    ConflictDocumentView(model: model, editor: editor)
                }
            }
        }
    }
}

// MARK: - 图例与操作条

private struct ConflictLegend: View {
    @Bindable var model: WorktreeModel
    let change: FileChange

    private var editor: WorktreeModel.ConflictEditor? {
        if case .editor(let editor) = model.conflictContent { return editor }
        return nil
    }

    private var hasTextualMarkers: Bool { change.conflict?.hasTextualMarkers ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                SideLabel(color: ConflictColors.ours, name: "当前更改",
                          detail: model.conflictContext?.oursLabel ?? ConflictContext.unknown.oursLabel)
                SideLabel(color: ConflictColors.theirs, name: "传入的更改",
                          detail: model.conflictContext?.theirsLabel ?? ConflictContext.unknown.theirsLabel)
                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                // 进度只对有标记可解析的形态有意义；「传入侧已删除」这类文件里本来就没有标记，
                // 显示「没有冲突标记」只会让人以为已经解决了。
                if let editor, hasTextualMarkers {
                    progressLabel(editor)
                }

                Spacer()

                if let editor, hasTextualMarkers, !editor.document.blocks.isEmpty {
                    Menu("剩余全部…") {
                        ForEach(ConflictResolution.allCases, id: \.self) { resolution in
                            Button(resolution.label) { model.resolveRemainingBlocks(with: resolution) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.system(size: 11))
                    .disabled(editor.isFullyResolved || model.activity != nil)
                    .help("把还没选的块一次性按同一个选择解决")
                }

                Button {
                    Task { await model.reloadConflictContent() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新读取文件。在外部编辑器里改完回来时点它。")

                Button("在编辑器打开") {
                    SystemActions.openFile(in: model.path, path: change.path)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))

                if hasTextualMarkers {
                    Button("恢复冲突标记…") {
                        Task { await confirmRestore() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(model.activity != nil)
                    .help("把文件恢复成 git 刚合并完的样子，丢掉在这个文件里做的所有改动")
                }

                Button("标记为已解决") {
                    Task { await confirmMarkResolved() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.activity != nil)
                .help("把工作区里现在的内容当作解决结果（git add）")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.06))
    }

    @ViewBuilder
    private func progressLabel(_ editor: WorktreeModel.ConflictEditor) -> some View {
        let total = editor.document.blocks.count
        if total == 0 {
            Label("文件里没有冲突标记", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        } else if editor.isFullyResolved {
            Label("\(total) 个冲突块已全部选定，检查无误后标记为已解决", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("还有 \(editor.remainingCount) / \(total) 个冲突块未处理", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    @MainActor
    private func confirmMarkResolved() async {
        let remaining = model.unresolvedMarkerCount(in: change)
        if remaining > 0 {
            let alert = NSAlert()
            alert.messageText = "文件里还有 \(remaining) 处冲突标记"
            alert.informativeText = "「\(change.displayName)」里仍然有 <<<<<<< 这样的标记。现在标记为已解决，这些标记会原样进入提交。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "仍然标记为已解决")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        await model.markConflictResolved(change)
    }

    @MainActor
    private func confirmRestore() async {
        let alert = NSAlert()
        alert.messageText = "恢复「\(change.displayName)」的冲突标记？"
        alert.informativeText = "文件会回到 git 刚合并完的样子，在这个文件里做的所有选择和手工修改都会丢失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await model.restoreConflictMarkers(change)
    }
}

private struct SideLabel: View {
    let color: Color
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("\(name)：\(detail)")
    }
}

private struct ConflictContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ConflictRowMinWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 冲突面板里每一行至少要铺多宽。见 `ConflictDocumentView.contentWidth`。
    fileprivate var conflictRowMinWidth: CGFloat {
        get { self[ConflictRowMinWidthKey.self] }
        set { self[ConflictRowMinWidthKey.self] = newValue }
    }
}

/// 让一行铺满文档宽度，底色才能连成一片。
private struct ConflictRowWidth: ViewModifier {
    @Environment(\.conflictRowMinWidth) private var minWidth

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: minWidth, alignment: .leading)
    }
}

enum ConflictColors {
    /// 当前侧用青色、传入侧用蓝色，跟 VS Code 的冲突编辑器一致 ——
    /// 用红绿的话会被误读成「删除 / 新增」。
    static let ours = Color.teal
    static let theirs = Color.blue
    static let base = Color.gray
}

// MARK: - 整文件选边

/// 没有「块」可言时的选择面板：一侧删除、二进制、不可解码。
private struct WholeFileChooser: View {
    let model: WorktreeModel
    let change: FileChange
    let kind: ConflictKind
    let reason: String

    private var context: ConflictContext { model.conflictContext ?? .unknown }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(kind.label, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(options, id: \.title) { option in
                    Button {
                        Task { await model.resolveConflict(change, taking: option.side) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(.system(size: 12, weight: .medium))
                            Text(option.subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    }
                    .disabled(model.activity != nil)
                }
            }
            .frame(maxWidth: 480)

            if kind.hasTextualMarkers {
                Text("也可以在外部编辑器里手工处理，然后点上方的「标记为已解决」。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct Option {
        var title: String
        var subtitle: String
        var side: GitClient.ConflictSide
    }

    /// 按形态给出两个（双方删除时一个）带解释的选项。「采用当前更改」在一侧删除的形态下
    /// 实际效果可能是删文件，按钮上必须写明结果，不能只写 ours/theirs。
    private var options: [Option] {
        let ours = context.oursLabel
        let theirs = context.theirsLabel
        switch kind {
        case .bothModified, .bothAdded:
            return [
                Option(title: "采用当前更改", subtitle: "整个文件换成 \(ours) 的版本", side: .ours),
                Option(title: "采用传入的更改", subtitle: "整个文件换成 \(theirs) 的版本", side: .theirs)
            ]
        case .deletedByThem:
            return [
                Option(title: "保留文件", subtitle: "采用当前更改：留下 \(ours) 修改后的版本", side: .ours),
                Option(title: "删除文件", subtitle: "采用传入的更改：\(theirs) 删掉了它", side: .theirs)
            ]
        case .deletedByUs:
            return [
                Option(title: "删除文件", subtitle: "采用当前更改：\(ours) 删掉了它", side: .ours),
                Option(title: "保留文件", subtitle: "采用传入的更改：留下 \(theirs) 修改后的版本", side: .theirs)
            ]
        case .addedByUs:
            return [
                Option(title: "保留文件", subtitle: "采用当前更改：只有 \(ours) 有它", side: .ours),
                Option(title: "删除文件", subtitle: "采用传入的更改：\(theirs) 没有它", side: .theirs)
            ]
        case .addedByThem:
            return [
                Option(title: "删除文件", subtitle: "采用当前更改：\(ours) 没有它", side: .ours),
                Option(title: "保留文件", subtitle: "采用传入的更改：只有 \(theirs) 有它", side: .theirs)
            ]
        case .bothDeleted:
            return [
                Option(title: "确认删除", subtitle: "两侧都删掉了它，标记为已解决", side: .ours)
            ]
        }
    }
}

// MARK: - 文件里已经没有标记

private struct NoMarkersView: View {
    let model: WorktreeModel
    let change: FileChange

    var body: some View {
        ContentUnavailableView {
            Label("文件里没有冲突标记", systemImage: "checkmark.seal")
        } description: {
            Text("看起来已经在外部处理过了。确认内容没问题就标记为已解决；想重来可以恢复冲突标记。")
        } actions: {
            Button("标记为已解决") {
                Task { await model.markConflictResolved(change) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.activity != nil)
        }
    }
}

// MARK: - 逐块解决

private struct ConflictDocumentView: View {
    let model: WorktreeModel
    let editor: WorktreeModel.ConflictEditor
    /// 展开了哪些长的上下文段（按段序号）。
    @State private var expandedSegments: Set<Int> = []

    /// 上下文段超过这个行数就折叠，只露出冲突块前后各几行。
    /// 解决冲突时要看的是冲突附近，几百行不相干的代码只会把下一个块推到屏幕外。
    private static let collapseThreshold = 24
    private static let contextLines = 8

    /// 文档的自然宽度（最长一行）。双向滚动的 ScrollView 不给横向宽度提议，行自己不知道
    /// 该铺多宽 —— 量出来再喂回去，每一行至少铺到「视口宽」和「最长行」里大的那个，
    /// 块的底色和左侧色条才不会在最长行处截断。
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                // 普通 VStack 而不是 LazyVStack：所有行一次排完，文档宽度稳定，
                // 不会像 diff 视图那样随离屏长行进出视口而变化。长的上下文段已经折叠，行数可控。
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(numberedSegments.enumerated()), id: \.offset) { index, item in
                        switch item.segment {
                        case .text(let lines):
                            textSegment(index: index, lines: lines, startLine: item.startLine)
                        case .conflict(let block):
                            ConflictBlockView(
                                block: block,
                                resolution: editor.resolutions[block.id],
                                startLine: item.startLine,
                                isBusy: model.activity != nil,
                                resolve: { resolution in model.resolveBlock(block, with: resolution) }
                            )
                        }
                    }
                }
                .padding(.bottom, 12)
                .environment(\.conflictRowMinWidth, max(geometry.size.width, contentWidth))
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ConflictContentWidthKey.self, value: proxy.size.width)
                    }
                )
            }
            .onPreferenceChange(ConflictContentWidthKey.self) { width in
                // 只增不减：最长行被解决掉之后宽度留着也无妨，换文件时整个容器会重建。
                if width > contentWidth { contentWidth = width }
            }
            .defaultScrollAnchor(.topLeading)
            // 文件切换后要新建滚动容器，不然会沿用上一个文件的滚动位置。
            .id(editor.change.path)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// 每段在**当前合成结果**里的起始行号。选定的块只占它选中内容的行数，
    /// 没选的块连标记行一起算 —— 这样行号跟磁盘上的文件对得上。
    private var numberedSegments: [(segment: ConflictSegment, startLine: Int)] {
        var line = 1
        return editor.document.segments.map { segment in
            let start = line
            switch segment {
            case .text(let lines):
                line += lines.count
            case .conflict(let block):
                if let resolution = editor.resolutions[block.id] {
                    line += block.lines(for: resolution).count
                } else {
                    line += block.rawLines.count
                }
            }
            return (segment, start)
        }
    }

    @ViewBuilder
    private func textSegment(index: Int, lines: [String], startLine: Int) -> some View {
        if lines.count > Self.collapseThreshold, !expandedSegments.contains(index) {
            let head = lines.prefix(Self.contextLines)
            let tail = lines.suffix(Self.contextLines)
            let hidden = lines.count - head.count - tail.count
            ForEach(Array(head.enumerated()), id: \.offset) { offset, text in
                ConflictLineView(number: startLine + offset, text: text, tint: nil)
            }
            Button {
                expandedSegments.insert(index)
            } label: {
                Label("展开中间的 \(hidden) 行", systemImage: "arrow.up.and.down")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .modifier(ConflictRowWidth())
            .background(Color.secondary.opacity(0.06))
            ForEach(Array(tail.enumerated()), id: \.offset) { offset, text in
                ConflictLineView(number: startLine + head.count + hidden + offset, text: text, tint: nil)
            }
        } else {
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, text in
                ConflictLineView(number: startLine + offset, text: text, tint: nil)
            }
        }
    }
}

private struct ConflictBlockView: View {
    let block: ConflictBlock
    let resolution: ConflictResolution?
    let startLine: Int
    let isBusy: Bool
    let resolve: (ConflictResolution?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let resolution {
                resolvedLines(resolution)
            } else {
                unresolvedLines
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(resolution == nil ? Color.orange : Color.green)
                .frame(width: 3)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("冲突 \(block.id)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(resolution == nil ? Color.orange : Color.green)

            if let resolution {
                Text(resolution.doneLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Button("撤销") { resolve(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
                    .disabled(isBusy)
            } else {
                Button("采用当前更改") { resolve(.ours) }
                    .tint(ConflictColors.ours)
                Button("采用传入的更改") { resolve(.theirs) }
                    .tint(ConflictColors.theirs)
                Button("保留双方") { resolve(.both) }
                    .help("两侧都留，当前在前")
                Menu {
                    Button(ConflictResolution.bothReversed.label) { resolve(.bothReversed) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .controlSize(.small)
        .disabled(isBusy)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .modifier(ConflictRowWidth())
        .background((resolution == nil ? Color.orange : Color.green).opacity(0.08))
    }

    /// 未解决的块按磁盘上的样子排：标记行也占行号，跟编辑器里看到的对得上。
    @ViewBuilder
    private var unresolvedLines: some View {
        let oursStart = startLine + 1
        let afterOurs = oursStart + block.ours.count
        let baseStart = afterOurs + 1
        let separatorLine = block.baseMarker == nil ? afterOurs : baseStart + block.base.count
        let theirsStart = separatorLine + 1
        let endLine = theirsStart + block.theirs.count

        MarkerLineView(number: startLine, text: block.oursMarker, note: "当前更改")
        sideLines(block.ours, from: oursStart, tint: ConflictColors.ours, emptyNote: "这一侧没有内容（删掉了这几行）")
        if let baseMarker = block.baseMarker {
            MarkerLineView(number: afterOurs, text: baseMarker, note: "共同祖先")
            sideLines(block.base, from: baseStart, tint: ConflictColors.base, emptyNote: "共同祖先里没有这几行")
        }
        MarkerLineView(number: separatorLine, text: block.separator, note: nil)
        sideLines(block.theirs, from: theirsStart, tint: ConflictColors.theirs, emptyNote: "这一侧没有内容（删掉了这几行）")
        MarkerLineView(number: endLine, text: block.theirsMarker, note: "传入的更改")
    }

    @ViewBuilder
    private func resolvedLines(_ resolution: ConflictResolution) -> some View {
        let lines = block.lines(for: resolution)
        if lines.isEmpty {
            ConflictLineView(number: nil, text: "（这一块的内容被整个删掉了）", tint: Color.green.opacity(0.06), isNote: true)
        } else {
            let oursCount = block.ours.count
            let theirsCount = block.theirs.count
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, text in
                ConflictLineView(
                    number: startLine + offset,
                    text: text,
                    tint: tint(for: offset, resolution: resolution, oursCount: oursCount, theirsCount: theirsCount)
                )
            }
        }
    }

    /// 选完后仍按来源着色（淡一点），让人一眼看出保留双方时哪几行来自哪边。
    private func tint(for offset: Int, resolution: ConflictResolution, oursCount: Int, theirsCount: Int) -> Color {
        let isOurs: Bool
        switch resolution {
        case .ours: isOurs = true
        case .theirs: isOurs = false
        case .both: isOurs = offset < oursCount
        case .bothReversed: isOurs = offset >= theirsCount
        }
        return (isOurs ? ConflictColors.ours : ConflictColors.theirs).opacity(0.07)
    }

    @ViewBuilder
    private func sideLines(_ lines: [String], from start: Int, tint: Color, emptyNote: String) -> some View {
        if lines.isEmpty {
            ConflictLineView(number: nil, text: emptyNote, tint: tint.opacity(0.08), isNote: true)
        } else {
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, text in
                ConflictLineView(number: start + offset, text: text, tint: tint.opacity(0.14))
            }
        }
    }
}

private struct MarkerLineView: View {
    let number: Int
    let text: String
    let note: String?

    var body: some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .frame(width: ConflictLineView.gutterWidth, alignment: .trailing)
                .padding(.trailing, 10)
                .foregroundStyle(.tertiary)
            Text(ConflictLineView.display(text))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            if let note {
                Text("  ← \(note)")
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 0.5)
        .modifier(ConflictRowWidth())
        .background(Color.secondary.opacity(0.08))
    }
}

private struct ConflictLineView: View {
    let number: Int?
    let text: String
    let tint: Color?
    var isNote = false

    /// 行号栏宽度固定，跟 diff 视图一样，避免滚过 4 位数行号时正文横向抖动。
    static let gutterWidth: CGFloat = 44

    /// 行尾的 `\r` 不显示。它在 CRLF 文件里是内容的一部分，写盘时会保留。
    static func display(_ line: String) -> String {
        var text = line
        if text.hasSuffix("\r") { text.removeLast() }
        return text.isEmpty ? " " : text
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .frame(width: Self.gutterWidth, alignment: .trailing)
                .padding(.trailing, 10)
                .foregroundStyle(.tertiary)
            Text(Self.display(text))
                .italic(isNote)
                .foregroundStyle(isNote ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.vertical, 0.5)
        .modifier(ConflictRowWidth())
        .background(tint ?? .clear)
    }
}
