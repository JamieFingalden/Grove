import Foundation

/// 把 `git diff` 的统一 diff 输出解析成结构化的文件 / hunk / 行。
///
/// 三个容易踩空的地方在这里都处理了：
///
/// 1. **路径带空格**。`diff --git a/my file b/my file` 无法靠分词切开。所以优先用
///    `--- a/…` / `+++ b/…` 两行取路径（它们一行只有一个路径，到行尾结束），
///    只有二进制文件没有这两行时才回退去猜 `diff --git` 行。
///
/// 2. **combined diff**。合并冲突期间 `git diff` 输出的是 `@@@ -1,2 -1,2 +1,3 @@@`，
///    每行前面有 N 个前缀列而不是 1 个。按 `@` 的个数算出前缀宽度就能通吃两种格式，
///    否则冲突文件的每一行都会被当成上下文，diff 看起来「什么都没改」。
///
/// 3. **空的上下文行**。规范里空行应该是单个空格，但经过某些工具（编辑器、
///    邮件补丁）之后尾部空格会被吃掉，变成真正的空字符串。当成上下文处理，
///    不然会漏行导致后面所有行号错位。
enum DiffParser {
    static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var current: Partial?
        var lineID = 0
        var hunkID = 0

        func flushHunk() {
            guard var partial = current, let hunk = partial.currentHunk else { return }
            partial.hunks.append(hunk)
            partial.currentHunk = nil
            current = partial
        }

        func flushFile() {
            flushHunk()
            guard let partial = current else { return }
            files.append(partial.build())
            current = nil
        }

        // 按 \n 切；\r 留在行尾不动 —— 它是文件内容的一部分（CRLF 换行的文件），
        // 擅自剥掉会让「行尾符变更」这种 diff 显示成空 diff。
        var lines = text.components(separatedBy: "\n")

        // git 的输出以换行结尾，切出来的最后一个空串不是 diff 的内容。
        // 不丢掉的话它会被当成一个「空的上下文行」（见下面对空行的处理），
        // 于是每个 diff 末尾都凭空多出一行、还占掉一个行号。
        // 只丢一个：真正的空上下文行 git 写的是一个空格，不是空串。
        if lines.last?.isEmpty == true { lines.removeLast() }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flushFile()
                var partial = Partial()
                let paths = parseGitHeaderPaths(String(line.dropFirst("diff --git ".count)))
                partial.oldPath = paths?.old
                partial.newPath = paths?.new
                partial.headerLines = [line]
                current = partial
                continue
            }

            // combined diff 的分隔行，出现在 `diff --cc` 输出里，没有信息量。
            if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                flushFile()
                var partial = Partial()
                let path = line.contains(" --cc ")
                    ? String(line.dropFirst("diff --cc ".count))
                    : String(line.dropFirst("diff --combined ".count))
                partial.oldPath = unquote(path)
                partial.newPath = unquote(path)
                partial.headerLines = [line]
                current = partial
                continue
            }

            guard current != nil else { continue }

            if line.hasPrefix("@@") {
                flushHunk()
                guard let header = parseHunkHeader(line) else { continue }
                hunkID += 1
                current?.currentHunk = DiffHunk(
                    id: hunkID,
                    header: line,
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    lines: []
                )
                current?.prefixWidth = header.prefixWidth
                current?.oldCursor = header.oldStart
                current?.newCursor = header.newStart
                continue
            }

            // 还没进 hunk，说明是文件级元信息。
            if current?.currentHunk == nil, current?.hunks.isEmpty == true {
                current?.headerLines.append(line)
                applyFileHeader(line, to: &current!)
                continue
            }
            if current?.currentHunk == nil {
                applyFileHeader(line, to: &current!)
                continue
            }

            lineID += 1
            appendContentLine(line, id: lineID, to: &current!)
        }

        flushFile()
        return files
    }

    // MARK: - 文件头

    private static func applyFileHeader(_ line: String, to partial: inout Partial) {
        if line.hasPrefix("new file mode ") {
            partial.isNewFile = true
            partial.newMode = String(line.dropFirst("new file mode ".count))
        } else if line.hasPrefix("deleted file mode ") {
            partial.isDeletedFile = true
            partial.oldMode = String(line.dropFirst("deleted file mode ".count))
        } else if line.hasPrefix("old mode ") {
            partial.oldMode = String(line.dropFirst("old mode ".count))
        } else if line.hasPrefix("new mode ") {
            partial.newMode = String(line.dropFirst("new mode ".count))
        } else if line.hasPrefix("rename from ") {
            partial.isRename = true
            partial.oldPath = unquote(String(line.dropFirst("rename from ".count)))
        } else if line.hasPrefix("rename to ") {
            partial.isRename = true
            partial.newPath = unquote(String(line.dropFirst("rename to ".count)))
        } else if line.hasPrefix("--- ") {
            let path = String(line.dropFirst(4))
            // `/dev/null` 是「这一侧不存在」的哨兵值，不是真路径。
            if path == "/dev/null" {
                partial.isNewFile = true
            } else {
                partial.oldPath = stripPathPrefix(path)
            }
        } else if line.hasPrefix("+++ ") {
            let path = String(line.dropFirst(4))
            if path == "/dev/null" {
                partial.isDeletedFile = true
            } else {
                partial.newPath = stripPathPrefix(path)
            }
        } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
            partial.isBinary = true
        }
        // `index abc..def 100644` 和 `similarity index 95%` 对界面没用，忽略。
    }

    // MARK: - hunk 头

    struct HunkHeader {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        /// 内容行前面有几个前缀列。普通 diff 是 1，双亲 combined diff 是 2。
        var prefixWidth: Int
    }

    /// `@@ -3,7 +3,9 @@ func foo()` 或 combined 的 `@@@ -1,2 -1,2 +1,3 @@@`。
    static func parseHunkHeader(_ line: String) -> HunkHeader? {
        let atCount = line.prefix(while: { $0 == "@" }).count
        guard atCount >= 2 else { return nil }
        // N 个 `@` 对应 N-1 个前缀列：普通 diff `@@` → 1 列，`@@@` → 2 列。
        let prefixWidth = atCount - 1

        let marker = String(repeating: "@", count: atCount)
        guard let start = line.range(of: marker),
              let end = line.range(of: marker, range: start.upperBound..<line.endIndex)
        else { return nil }

        let ranges = line[start.upperBound..<end.lowerBound]
            .split(separator: " ")
            .map(String.init)

        var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
        var sawOld = false
        for token in ranges {
            guard let sign = token.first else { continue }
            let (start, count) = parseRange(String(token.dropFirst()))
            if sign == "-" {
                // combined diff 有多个 `-` 段（每个父提交一个）。只认第一个，
                // 界面上展示的是「相对第一父提交」的变化。
                if !sawOld {
                    oldStart = start
                    oldCount = count
                    sawOld = true
                }
            } else if sign == "+" {
                newStart = start
                newCount = count
            }
        }
        return HunkHeader(
            oldStart: oldStart, oldCount: oldCount,
            newStart: newStart, newCount: newCount,
            prefixWidth: prefixWidth
        )
    }

    /// `3,7` → (3, 7)；`3` → (3, 1)。省略计数时按规范默认为 1。
    private static func parseRange(_ token: String) -> (Int, Int) {
        let parts = token.split(separator: ",")
        let start = Int(parts.first ?? "0") ?? 0
        let count = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        return (start, count)
    }

    // MARK: - 内容行

    private static func appendContentLine(_ line: String, id: Int, to partial: inout Partial) {
        guard var hunk = partial.currentHunk else { return }

        // `\ No newline at end of file`：元信息，不占任何一侧的行号。
        if line.hasPrefix("\\") {
            hunk.lines.append(DiffLine(id: id, kind: .noNewline, text: String(line.dropFirst(2)), oldNumber: nil, newNumber: nil))
            partial.currentHunk = hunk
            return
        }

        let width = partial.prefixWidth
        let prefix = String(line.prefix(width))
        let content = line.count >= width ? String(line.dropFirst(width)) : ""

        let kind: DiffLine.Kind
        if prefix.contains("+") {
            kind = .addition
        } else if prefix.contains("-") {
            kind = .deletion
        } else {
            // 包括真正的空字符串行（尾部空格被吃掉的上下文行）。
            kind = .context
        }

        var oldNumber: Int?
        var newNumber: Int?
        switch kind {
        case .addition:
            newNumber = partial.newCursor
            partial.newCursor += 1
        case .deletion:
            oldNumber = partial.oldCursor
            partial.oldCursor += 1
        case .context:
            oldNumber = partial.oldCursor
            newNumber = partial.newCursor
            partial.oldCursor += 1
            partial.newCursor += 1
        case .noNewline:
            break
        }

        hunk.lines.append(DiffLine(id: id, kind: kind, text: content, oldNumber: oldNumber, newNumber: newNumber))
        partial.currentHunk = hunk
    }

    // MARK: - 路径处理

    /// 从 `a/foo.swift b/foo.swift` 里取出两个路径。
    ///
    /// 非重命名的情况下两个路径完全相同，于是可以按「正中间那个空格」切开 ——
    /// 这样即使路径里有空格也不会错。只有重命名（两边不同）才需要退回启发式，
    /// 而重命名一定伴随 `rename from/to` 两行，稍后会覆盖掉这里的结果。
    static func parseGitHeaderPaths(_ remainder: String) -> (old: String, new: String)? {
        let characters = Array(remainder)
        let middle = characters.count / 2
        if characters.count % 2 == 1, characters[middle] == " " {
            let left = String(characters[0..<middle])
            let right = String(characters[(middle + 1)...])
            if left.count == right.count {
                return (stripPathPrefix(left), stripPathPrefix(right))
            }
        }

        // 退路：找 " b/"。重命名时可能猜错，但紧随其后的 `rename from/to` 会纠正。
        if let separator = remainder.range(of: " b/") {
            let left = String(remainder[remainder.startIndex..<separator.lowerBound])
            let right = String(remainder[remainder.index(after: separator.lowerBound)...])
            return (stripPathPrefix(left), stripPathPrefix(right))
        }
        return nil
    }

    /// 去掉 diff 里的 `a/` `b/` 前缀，处理 C 风格引号，并切掉路径后面的制表符。
    ///
    /// 那个制表符是统一 diff 的历史包袱：规范允许 `--- <路径>\t<时间戳>`。git 不写
    /// 时间戳，但**路径含空格时会补一个裸制表符**来标记路径到哪结束。不切掉的话
    /// 路径末尾多一个不可见字符，后续 `git diff -- <路径>` 全部匹配不上，
    /// 表现是「点了带空格的文件，diff 面板永远空白」。
    static func stripPathPrefix(_ path: String) -> String {
        var candidate = path

        if candidate.hasPrefix("\"") {
            // 带引号时路径边界就是最后一个引号，制表符在引号外面。
            if let close = candidate.lastIndex(of: "\""), close > candidate.startIndex {
                candidate = String(candidate[candidate.startIndex...close])
            }
        } else if let tab = candidate.firstIndex(of: "\t") {
            // 不带引号就不可能含字面制表符 —— 含制表符的路径 git 一定会加引号，
            // 所以切第一个制表符是安全的。
            candidate = String(candidate[candidate.startIndex..<tab])
        }

        let unquoted = unquote(candidate)
        if unquoted.hasPrefix("a/") || unquoted.hasPrefix("b/") {
            return String(unquoted.dropFirst(2))
        }
        return unquoted
    }

    /// git 在路径含特殊字符（引号、换行、制表符）时会套双引号并做 C 转义。
    /// 我们已经用 `core.quotePath=false` 关掉了非 ASCII 的八进制转义，
    /// 但这几个字符仍然会被引起来，所以还得还原。
    static func unquote(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 else { return path }
        let inner = String(path.dropFirst().dropLast())
        var result = ""
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else { break }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            default: result.append(escaped)
            }
        }
        return result
    }

    // MARK: -

    private struct Partial {
        var oldPath: String?
        var newPath: String?
        var hunks: [DiffHunk] = []
        var currentHunk: DiffHunk?
        var isBinary = false
        var isNewFile = false
        var isDeletedFile = false
        var isRename = false
        var oldMode: String?
        var newMode: String?
        var prefixWidth = 1
        var oldCursor = 0
        var newCursor = 0
        var headerLines: [String] = []

        func build() -> FileDiff {
            FileDiff(
                oldPath: oldPath,
                newPath: newPath,
                hunks: hunks,
                isBinary: isBinary,
                isNewFile: isNewFile,
                isDeletedFile: isDeletedFile,
                isRename: isRename,
                // 有 old/new mode 两行、却没有任何 hunk，就是纯权限变更。
                isModeChangeOnly: hunks.isEmpty && !isBinary && oldMode != nil && newMode != nil && oldMode != newMode,
                oldMode: oldMode,
                newMode: newMode,
                headerLines: headerLines
            )
        }
    }
}
