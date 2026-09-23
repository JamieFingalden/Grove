import SwiftUI

/// diff 展示布局：统一（传统 ±）还是分栏（旧左新右）。
enum DiffLayout: String, CaseIterable, Identifiable {
    case unified, split

    var id: String { rawValue }
    /// 持久化键。两个入口（变更视图 / PR 评审）共享同一选择，
    /// 用户切一次，处处生效。
    static let storageKey = "grove.diff.layout.v2"
}

/// 阅读偏好：字号可调（9–18pt，默认 12）。review 时想盯紧细节就放大，
/// 看大 diff 想少翻页就缩小 —— 这和专业编辑器的诉求一样。
enum DiffReading {
    static let fontSizeKey = "grove.diff.fontSize.v2"
    static let defaultFontSize: Double = 12
    static let minFontSize: Double = 9
    static let maxFontSize: Double = 18
}

/// 头部阅读控制：布局切换 + 字号调节。多个页面共用，绑同一组 @AppStorage 键。
struct DiffReadingControls: View {
    @AppStorage(DiffLayout.storageKey) private var layout = DiffLayout.unified.rawValue
    @AppStorage(DiffReading.fontSizeKey) private var fontSize = DiffReading.defaultFontSize

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $layout) {
                Text("统一").tag(DiffLayout.unified.rawValue)
                Text("分栏").tag(DiffLayout.split.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("统一：传统 ± 行；分栏：左旧右新对照")

            HStack(spacing: 1) {
                Button {
                    fontSize = max(DiffReading.minFontSize, fontSize - 0.5)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 10))
                }
                Button {
                    fontSize = min(DiffReading.maxFontSize, fontSize + 0.5)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 10))
                }
            }
            .buttonStyle(.borderless)
            .disabled(fontSize <= DiffReading.minFontSize && false)
            .help("调整代码字号（\(Int(fontSize))pt）")
        }
    }
}

/// 把统一 diff 的行序列配成分栏行：左（旧）/ 右（新）。
///
/// 规则：连续的删除块和新增块（中间没有上下文行）算一个「改动簇」，
/// 簇内第 i 个删除行和第 i 个新增行水平对齐，多出来的那侧留空 ——
/// 跟所有主流 diff 工具的排法一致。
enum SplitLayout {
    struct Pair {
        var left: DiffLine?
        var right: DiffLine?
        /// 这一行的某一侧是「文件末尾没有换行符」的标记行。
        var leftNoNewline = false
        var rightNoNewline = false

        var isChange: Bool {
            (left?.kind == .deletion) || (right?.kind == .addition)
        }

        /// 行对的身份：左右行 id 即可；纯上下文行两侧同 id。
        var pairID: String { "\(left?.id ?? 0)-\(right?.id ?? 0)" }
    }

    enum PairSide {
        case old, new

        var number: KeyPath<DiffLine, Int?> {
            switch self {
            case .old: \.oldNumber
            case .new: \.newNumber
            }
        }
    }

    /// 这个 hunk 需要左右对照吗？只有同时有增有删才值得分栏；
    /// 纯增（新建文件、尾部追加）或纯删的 hunk 直接单侧占满全宽 ——
    /// 否则半屏浪费在空栏上，长行内容反而被挤得展不开。
    /// 纯上下文（折叠区展开）也走单侧，内容不必重复两遍。
    static func dominantSide(for lines: [DiffLine]) -> PairSide? {
        let hasDeletion = lines.contains { $0.kind == .deletion }
        let hasAddition = lines.contains { $0.kind == .addition }
        if !hasDeletion { return .new }
        if !hasAddition { return .old }
        return nil
    }

    static func pairs(for lines: [DiffLine]) -> [Pair] {
        var result: [Pair] = []
        var deletions: [DiffLine] = []
        var additions: [DiffLine] = []
        /// 最近的 \ 标记挂在哪一侧，还没落到具体行上。
        var pendingNoNewlineSide: PairSide?

        func flush() {
            let count = max(deletions.count, additions.count)
            guard count > 0 else {
                // 纯上下文行后面的 \（整个文件末尾无换行）：挂到已产出的最后一对。
                if let side = pendingNoNewlineSide, var last = result.last {
                    apply(side, to: &last)
                    result[result.count - 1] = last
                }
                pendingNoNewlineSide = nil
                return
            }
            for index in 0..<count {
                var pair = Pair(
                    left: index < deletions.count ? deletions[index] : nil,
                    right: index < additions.count ? additions[index] : nil
                )
                if let side = pendingNoNewlineSide, index == count - 1 {
                    apply(side, to: &pair)
                }
                result.append(pair)
            }
            deletions.removeAll()
            additions.removeAll()
            pendingNoNewlineSide = nil
        }

        func apply(_ side: PairSide, to pair: inout Pair) {
            if side == .new, pair.right != nil {
                pair.rightNoNewline = true
            } else if pair.left != nil {
                pair.leftNoNewline = true
            }
        }

        for line in lines {
            switch line.kind {
            case .deletion:
                deletions.append(line)
            case .addition:
                additions.append(line)
            case .context:
                flush()
                result.append(Pair(left: line, right: line))
            case .noNewline:
                // git 把 \ 放在所属 run 的最后一行后面；新增行存在时
                // 它描述的是新文件末尾，否则是旧文件末尾。
                pendingNoNewlineSide = additions.isEmpty ? .old : .new
            }
        }
        flush()
        return result
    }
}

// MARK: - 分栏渲染

/// 一个 hunk 的分栏渲染：hunk 头横跨两侧，下面每行左右对照。
struct SplitHunkView: View {
    let hunk: DiffHunk
    var model: WorktreeModel?
    var filePath: String?
    var highlights: [Int: [Range<String.Index>]]

    private var pairs: [SplitLayout.Pair] { SplitLayout.pairs(for: hunk.lines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let model {
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

            // 纯增/纯删的 hunk：单侧占满全宽，没有空栏和分隔线。
            if let side = SplitLayout.dominantSide(for: hunk.lines) {
                ForEach(pairs, id: \.pairID) { pair in
                    singleCell(pair: pair, side: side)
                }
            } else {
                ForEach(pairs, id: \.pairID) { pair in
                    SplitPairRow(
                        pair: pair,
                        model: model,
                        filePath: filePath,
                        highlights: highlights
                    )
                }
            }
        }
    }

    /// 单栏模式：只渲染主导侧的单元格，占满整个面板宽度。
    @ViewBuilder
    private func singleCell(pair: SplitLayout.Pair, side: SplitLayout.PairSide) -> some View {
        let line = side == .old ? pair.left : pair.right
        SplitSideCell(
            line: line,
            noNewline: side == .old ? pair.leftNoNewline : pair.rightNoNewline,
            side: side,
            model: model,
            filePath: filePath,
            highlights: line.map { highlights[$0.id] ?? [] } ?? []
        )
    }

    private func hunkIcon(_ state: WorktreeModel.HunkSelection) -> String {
        switch state {
        case .none: "square"
        case .partial: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }
}

/// 一行对照：左旧右新，中间一条细分隔线。两侧各占一半可用宽度，
/// 长行在各自半边内折行 —— 跟 GitHub 的 split 视图同款，没有横向滚动。
private struct SplitPairRow: View {
    let pair: SplitLayout.Pair
    var model: WorktreeModel?
    var filePath: String?
    var highlights: [Int: [Range<String.Index>]]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SplitSideCell(
                line: pair.left,
                noNewline: pair.leftNoNewline,
                side: .old,
                model: model,
                filePath: filePath,
                highlights: pair.left.map { highlights[$0.id] ?? [] } ?? []
            )

            Rectangle()
                .fill(.separator)
                .frame(width: 1)

            SplitSideCell(
                line: pair.right,
                noNewline: pair.rightNoNewline,
                side: .new,
                model: model,
                filePath: filePath,
                highlights: pair.right.map { highlights[$0.id] ?? [] } ?? []
            )
        }
    }
}

/// 分栏视图里的一侧单元格：占满半边、正文折行。
private struct SplitSideCell: View {
    let line: DiffLine?
    var noNewline: Bool
    var side: SplitLayout.PairSide
    var model: WorktreeModel?
    var filePath: String?
    var highlights: [Range<String.Index>]

    @State private var isGutterHovered = false
    @AppStorage(DiffReading.fontSizeKey) private var fontSize = DiffReading.defaultFontSize

    private var isSelectable: Bool {
        model != nil && (line?.kind == .addition || line?.kind == .deletion)
    }

    private var isSelected: Bool {
        guard let line else { return false }
        return model?.selectedLines.contains(line.id) ?? false
    }

    /// 勾选列只在可交互（变更视图）时预留；只读场景不送给空气。
    private var gutterWidth: CGFloat { model != nil ? 16 + 38 : 38 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                gutter
                    .padding(.top, 1)
                Text(marker)
                    .frame(width: 10, alignment: .leading)
                    .padding(.top, 1)
                if let line {
                    Text(CodeSyntax.attributed(
                        line.text.isEmpty ? " " : line.text,
                        path: filePath,
                        highlights: highlights,
                        highlight: highlightTint
                    ))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)
                } else {
                    // 空侧给一个极淡的底：一眼看出「这半边没有对应行」。
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 1)
                }
            }
            .font(.system(size: fontSize, design: .monospaced))
            .lineSpacing(1.5)
            .padding(.vertical, 0.5)

            if noNewline {
                Text("⟨文件末尾没有换行符⟩")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.leading, gutterWidth + 10)
                    .padding(.bottom, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if line?.kind == .addition || line?.kind == .deletion {
                Rectangle()
                    .fill(line?.kind == .addition ? Color.green.opacity(0.7) : Color.red.opacity(0.7))
                    .frame(width: 2.5)
            }
        }
    }

    /// 与统一视图相同的交互模型：行号栏是唯一点击热区，Shift 范围选择。
    @ViewBuilder
    private var gutter: some View {
        if isSelectable, let line, let model {
            Button {
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
                    Text(line[keyPath: side.number].map(String.init) ?? "")
                        .frame(width: 38, alignment: .trailing)
                }
                .padding(.leading, 4)
                .padding(.vertical, 1)
                .frame(minHeight: 16)
                .background(
                    (isGutterHovered || isSelected)
                        ? Color.accentColor.opacity(isSelected ? 0.22 : 0.12)
                        : Color.clear
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isGutterHovered = hovering
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .help(side == .old ? "选中/取消这个旧行（⇧点击范围选择）" : "选中/取消这个新行（⇧点击范围选择）")
        } else if let line {
            // 上下文行或只读场景：只有行号，不预留勾选空位（除非同栏有可勾选行）。
            HStack(spacing: 0) {
                if model != nil {
                    Color.clear.frame(width: 16)
                }
                Text(line[keyPath: side.number].map(String.init) ?? "")
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.leading, 4)
            .foregroundStyle(.tertiary)
        } else {
            Color.clear.frame(width: gutterWidth, height: 1)
        }
    }

    private var marker: String {
        switch line?.kind {
        case .deletion: "−"
        case .addition: "+"
        default: " "
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        // 空侧用中性淡底标记「此处无对应行」，有行的一侧按增/删着色。
        let base = rowTint
        Rectangle().fill(base.map { Color($0).opacity(0.13) } ?? Color.clear)
    }

    private var rowTint: Color? {
        switch line?.kind {
        case .deletion: .red
        case .addition: .green
        default: nil
        }
    }

    /// 词级高亮底色：跟行的增/删属性走。
    private var highlightTint: Color? {
        switch line?.kind {
        case .deletion: .red.opacity(0.22)
        case .addition: .green.opacity(0.28)
        default: nil
        }
    }
}
