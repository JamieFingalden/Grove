import Foundation

/// 冲突两侧各是什么，给「当前更改 / 传入的更改」两个按钮配说明。
///
/// git 的 ours / theirs 在变基时是反的：HEAD 停在变基目标上，「当前更改」反而是
/// 别人的分支，自己正在重放的提交成了「传入」。不把两侧的来源写清楚，用户十有八九选反。
struct ConflictContext: Hashable, Sendable {
    var operation: RepositoryOperation?
    /// 「当前更改」（HEAD，索引第 2 阶段）这一侧的来源。
    var oursLabel: String
    /// 「传入的更改」（索引第 3 阶段）这一侧的来源。
    var theirsLabel: String

    static let unknown = ConflictContext(
        operation: nil,
        oursLabel: "HEAD（当前分支）",
        theirsLabel: "正在应用的改动"
    )
}

/// 一个带冲突标记的文件，按「普通文本 / 冲突块」切成段。
///
/// 段是不可变的原始解析结果；用户对每个块的选择另存（见 `WorktreeModel.ConflictEditor`），
/// 渲染时再合成。这样每个块都能撤销：撤销就是把这个块的选择删掉，重新渲染、重新写盘。
struct ConflictDocument: Hashable, Sendable {
    var segments: [ConflictSegment]
    /// 原文件末尾有没有换行。git 写标记时保留了文件本来的结尾，改写时也得保留 ——
    /// 凭空加一个换行会在最终 diff 里多出一处跟冲突无关的改动。
    var endsWithNewline: Bool
    /// 原文件带 UTF-8 BOM。`String(data:encoding:)` 解码时会吃掉它，写回时得补上。
    var hasByteOrderMark = false

    static let empty = ConflictDocument(segments: [], endsWithNewline: false)

    var blocks: [ConflictBlock] {
        segments.compactMap {
            if case .conflict(let block) = $0 { return block }
            return nil
        }
    }

    /// 按给定的选择合成全文。没做选择的块原样保留标记，跟磁盘上 git 写的一致。
    func rendered(with resolutions: [Int: ConflictResolution]) -> String {
        var lines: [String] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                lines.append(contentsOf: text)
            case .conflict(let block):
                if let resolution = resolutions[block.id] {
                    lines.append(contentsOf: block.lines(for: resolution))
                } else {
                    lines.append(contentsOf: block.rawLines)
                }
            }
        }
        var text = lines.joined(separator: "\n")
        if endsWithNewline, !lines.isEmpty { text += "\n" }
        return text
    }
}

enum ConflictSegment: Hashable, Sendable {
    /// 冲突块之间的普通内容，按行存。行尾的 `\r`（CRLF 文件）留在行里不动。
    case text([String])
    case conflict(ConflictBlock)
}

/// 一个 `<<<<<<<` … `>>>>>>>` 块。
struct ConflictBlock: Identifiable, Hashable, Sendable {
    var id: Int
    /// `<<<<<<< HEAD` 整行原文。
    var oursMarker: String
    var ours: [String]
    /// diff3 / zdiff3 风格才有的 `||||||| 共同祖先` 行；默认风格没有。
    var baseMarker: String?
    var base: [String]
    var separator: String
    var theirs: [String]
    /// `>>>>>>> feature` 整行原文。
    var theirsMarker: String

    /// `<<<<<<< HEAD` 里 HEAD 那部分。这是 git 亲手写的、关于这一侧是谁的说明，界面上标在块头。
    var oursLabel: String { Self.label(of: oursMarker) }
    var theirsLabel: String { Self.label(of: theirsMarker) }
    var baseLabel: String? { baseMarker.map(Self.label(of:)) }

    /// 块在磁盘上的原样：标记行 + 两侧内容。
    var rawLines: [String] {
        var lines = [oursMarker] + ours
        if let baseMarker {
            lines.append(baseMarker)
            lines.append(contentsOf: base)
        }
        lines.append(separator)
        lines.append(contentsOf: theirs)
        lines.append(theirsMarker)
        return lines
    }

    func lines(for resolution: ConflictResolution) -> [String] {
        switch resolution {
        case .ours: ours
        case .theirs: theirs
        case .both: ours + theirs
        case .bothReversed: theirs + ours
        }
    }

    static func label(of marker: String) -> String {
        var rest = marker.drop(while: { $0 == "<" || $0 == ">" || $0 == "|" })
        if rest.first == " " { rest = rest.dropFirst() }
        var label = String(rest)
        if label.hasSuffix("\r") { label.removeLast() }
        return label
    }
}

/// 对一个冲突块的选择。
enum ConflictResolution: String, Hashable, Sendable, CaseIterable {
    case ours
    case theirs
    /// 两侧都留，当前在前。合并两个各自新增的函数时就是这个意思。
    case both
    case bothReversed

    var label: String {
        switch self {
        case .ours: "采用当前更改"
        case .theirs: "采用传入的更改"
        case .both: "保留双方更改"
        case .bothReversed: "保留双方（传入在前）"
        }
    }

    /// 已选定之后块头上的说明。
    var doneLabel: String {
        switch self {
        case .ours: "已采用当前更改"
        case .theirs: "已采用传入的更改"
        case .both: "已保留双方（当前在前）"
        case .bothReversed: "已保留双方（传入在前）"
        }
    }
}
