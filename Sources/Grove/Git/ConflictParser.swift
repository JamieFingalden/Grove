import Foundation

/// 把带冲突标记的文件切成「普通文本 / 冲突块」。
///
/// 标记的形状是 git 定的：`<<<<<<< 标签`、`=======`、`>>>>>>> 标签`，diff3 风格多一行
/// `||||||| 标签`。标记默认 7 个字符，但仓库可以通过 `conflict-marker-size` 属性改长 ——
/// 所以这里不写死 7，而是以块的开头行为准：**同一个块里所有标记的长度必须一致**。
/// 这条规则顺便挡掉了最常见的误判：Markdown 里 `========` 这种下划线，
/// 长度对不上就不会被当成分隔线。
///
/// 读不完整的块（缺分隔线或缺结束标记）整个退回普通文本。半截标记多半是
/// 文件内容里本来就有的东西 —— 讲冲突解决的教程、测试用的样例。
enum ConflictParser {
    static func parse(_ text: String) -> ConflictDocument {
        guard !text.isEmpty else { return .empty }

        // 按 \n 切；\r 留在行尾不动，跟 DiffParser 一样 —— 它是文件内容的一部分。
        var lines = text.components(separatedBy: "\n")
        var endsWithNewline = false
        if lines.last == "" {
            lines.removeLast()
            endsWithNewline = true
        }

        var segments: [ConflictSegment] = []
        var pending: [String] = []
        var index = 0
        var blockCount = 0

        while index < lines.count {
            let line = lines[index]
            guard let size = markerSize(of: line, character: "<"),
                  let (block, next) = parseBlock(lines, from: index, markerSize: size, id: blockCount + 1)
            else {
                pending.append(line)
                index += 1
                continue
            }
            if !pending.isEmpty {
                segments.append(.text(pending))
                pending = []
            }
            blockCount += 1
            segments.append(.conflict(block))
            index = next
        }
        if !pending.isEmpty { segments.append(.text(pending)) }

        return ConflictDocument(segments: segments, endsWithNewline: endsWithNewline)
    }

    /// 这一行是不是由 `character` 组成的标记行；是的话返回标记长度。
    /// 标记后面要么直接结束，要么是一个空格再跟标签。
    static func markerSize(of line: String, character: Character) -> Int? {
        var content = Substring(line)
        if content.hasSuffix("\r") { content = content.dropLast() }
        let run = content.prefix(while: { $0 == character }).count
        guard run >= 7 else { return nil }
        let rest = content.dropFirst(run)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return run
    }

    private static func isMarker(_ line: String, _ character: Character, size: Int) -> Bool {
        markerSize(of: line, character: character) == size
    }

    private static func parseBlock(
        _ lines: [String],
        from start: Int,
        markerSize size: Int,
        id: Int
    ) -> (ConflictBlock, Int)? {
        enum Phase { case ours, base, theirs }

        var phase = Phase.ours
        var ours: [String] = []
        var base: [String] = []
        var theirs: [String] = []
        var baseMarker: String?
        var separator: String?
        var index = start + 1

        while index < lines.count {
            let line = lines[index]
            // 块还没结束又碰到一个开始标记：当前这个块不完整，放弃。
            if isMarker(line, "<", size: size) { return nil }

            switch phase {
            case .ours:
                if isMarker(line, "|", size: size) {
                    baseMarker = line
                    phase = .base
                } else if isMarker(line, "=", size: size) {
                    separator = line
                    phase = .theirs
                } else {
                    ours.append(line)
                }
            case .base:
                if isMarker(line, "=", size: size) {
                    separator = line
                    phase = .theirs
                } else {
                    base.append(line)
                }
            case .theirs:
                if isMarker(line, ">", size: size), let separator {
                    let block = ConflictBlock(
                        id: id,
                        oursMarker: lines[start],
                        ours: ours,
                        baseMarker: baseMarker,
                        base: base,
                        separator: separator,
                        theirs: theirs,
                        theirsMarker: line
                    )
                    return (block, index + 1)
                }
                theirs.append(line)
            }
            index += 1
        }
        return nil
    }
}
