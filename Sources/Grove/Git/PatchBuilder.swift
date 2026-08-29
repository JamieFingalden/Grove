import Foundation

/// 从一个文件的 diff 里挑出**部分行**，生成一个只包含这些改动的补丁，
/// 喂给 `git apply` 来做分行暂存 / 取消暂存 / 丢弃。
///
/// 这是整个功能里唯一会丢代码的地方，所以规则写死在这儿、有测试兜着。
///
/// 核心是：`git apply` 需要补丁的**基准侧**跟目标内容逐字对上，否则整块拒绝。
/// 而正向和反向的基准侧是相反的，两套规则不能混用：
///
/// 正向（暂存选中行，基准是旧内容 = 索引里的样子）：
/// - 上下文行 → 上下文
/// - 选中的删除行 → 删除
/// - **没选**的删除行 → 变成上下文（它在基准里存在，而且这次不删它）
/// - 选中的新增行 → 新增
/// - **没选**的新增行 → 整行丢掉（它在基准里根本不存在）
///
/// 反向（取消暂存 / 丢弃选中行，基准是新内容 = 工作区或索引现在的样子）：
/// - 选中的新增行 → 新增（反向应用时被删掉）
/// - **没选**的新增行 → 变成上下文（它在基准里存在且保留）
/// - 选中的删除行 → 删除（反向应用时被恢复）
/// - **没选**的删除行 → 整行丢掉（它在基准里不存在）
///
/// 把这两套搞反的话，`git apply` 会报 "patch does not apply" —— 那还算走运，
/// 因为它至少拒绝了；真正危险的是规则只错一半、补丁却恰好能应用上。
enum PatchBuilder {
    enum Direction: Sendable {
        /// 把选中的行加进索引（暂存）。
        case forward
        /// 把选中的行从索引 / 工作区撤掉（取消暂存、丢弃）。
        case reverse
    }

    /// 生成补丁。没有任何选中行落在这个文件里时返回 nil。
    static func patch(
        for file: FileDiff,
        selecting selected: Set<Int>,
        direction: Direction
    ) -> String? {
        guard !file.isBinary, !file.hunks.isEmpty else { return nil }

        var body: [String] = []
        // 前面的 hunk 部分应用之后，后续 hunk 在新文件里的起始行会整体平移。
        // git 自己生成补丁时也是这么累计的。
        var offset = 0

        for hunk in file.hunks {
            guard hunk.lines.contains(where: { selected.contains($0.id) }) else { continue }

            var lines: [String] = []
            var oldCount = 0
            var newCount = 0
            var previousWasEmitted = false

            for line in hunk.lines {
                let isSelected = selected.contains(line.id)

                switch line.kind {
                case .context:
                    lines.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    previousWasEmitted = true

                case .addition:
                    switch (direction, isSelected) {
                    case (.forward, true), (.reverse, true):
                        lines.append("+" + line.text)
                        newCount += 1
                        previousWasEmitted = true
                    case (.forward, false):
                        // 基准（旧内容）里没有这一行，补丁里也不能提它。
                        previousWasEmitted = false
                    case (.reverse, false):
                        // 基准（新内容）里有这一行，而且要保留 —— 当上下文。
                        lines.append(" " + line.text)
                        oldCount += 1
                        newCount += 1
                        previousWasEmitted = true
                    }

                case .deletion:
                    switch (direction, isSelected) {
                    case (.forward, true), (.reverse, true):
                        lines.append("-" + line.text)
                        oldCount += 1
                        previousWasEmitted = true
                    case (.forward, false):
                        // 基准（旧内容）里有这一行，这次不删它 —— 当上下文。
                        lines.append(" " + line.text)
                        oldCount += 1
                        newCount += 1
                        previousWasEmitted = true
                    case (.reverse, false):
                        // 基准（新内容）里没有这一行。
                        previousWasEmitted = false
                    }

                case .noNewline:
                    // 「文件末尾没有换行」这个标记属于它前面那一行。
                    // 前面那行没被写进补丁的话，标记也不能留 —— 否则 git 会认为
                    // 上一行（一个上下文行）没有换行，跟实际文件对不上、整块拒绝。
                    if previousWasEmitted {
                        lines.append("\\ No newline at end of file")
                    }
                }
            }

            // 全是上下文，等于什么都没改，这种 hunk 不该出现在补丁里。
            guard lines.contains(where: { $0.hasPrefix("+") || $0.hasPrefix("-") }) else { continue }

            let newStart = hunk.oldStart + offset
            body.append("@@ -\(range(hunk.oldStart, oldCount)) +\(range(newStart, newCount)) @@")
            body.append(contentsOf: lines)
            offset += newCount - oldCount
        }

        guard !body.isEmpty else { return nil }

        // 文件头原样抄 git 自己生成的那几行（含 `index` 的 blob 哈希）——
        // 自己按字段拼一遍迟早会漏掉重命名、模式位之类的情况。
        let header = file.headerLines.isEmpty ? fallbackHeader(for: file) : file.headerLines
        // 补丁必须以换行结尾，否则 git apply 会说 "corrupt patch at line N"。
        return (header + body).joined(separator: "\n") + "\n"
    }

    /// `<起始>,<行数>`。行数为 1 时 git 会省略逗号部分，这里跟着省
    /// —— 格式跟 git 自己的输出一致，排查问题时对照起来方便。
    private static func range(_ start: Int, _ count: Int) -> String {
        // 行数为 0 时起始行号要减 1（表示「插入到这一行之后」），这是统一 diff 的规矩。
        if count == 0 { return "\(max(0, start - 1)),0" }
        return count == 1 ? "\(start)" : "\(start),\(count)"
    }

    /// 极少数情况下拿不到原始头（比如 diff 是我们自己合成的），按字段拼一个。
    private static func fallbackHeader(for file: FileDiff) -> [String] {
        let old = file.oldPath ?? file.newPath ?? "unknown"
        let new = file.newPath ?? file.oldPath ?? "unknown"
        return [
            "diff --git a/\(old) b/\(new)",
            "--- a/\(old)",
            "+++ b/\(new)"
        ]
    }
}
