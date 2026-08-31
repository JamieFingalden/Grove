import Foundation

enum CommitPromptBuilder {
    static let defaultMaxDiffBytes = 32 * 1024

    struct Input: Sendable {
        var stagedDiff: String
        var recentSubjects: [String]
        var fileSummary: String
        var maxDiffBytes: Int = CommitPromptBuilder.defaultMaxDiffBytes
    }

    struct Result: Sendable {
        var text: String
        var wasTruncated: Bool
    }

    static func prompt(_ input: Input) -> String {
        build(input).text
    }

    static func build(_ input: Input) -> Result {
        let limit = max(0, input.maxDiffBytes)
        let diffData = Data(input.stagedDiff.utf8)
        let wasTruncated = diffData.count > limit
        let diff = wasTruncated ? limitedDiff(input.stagedDiff, byteLimit: limit) : input.stagedDiff
        let subjects = input.recentSubjects
            .filter { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("merge ") }
            .prefix(20)
        let styleSamples = subjects.isEmpty
            ? "（没有可用的历史提交标题，请根据改动生成简洁、自然的提交信息。）"
            : subjects.map { "- \(limited($0, byteLimit: 512))" }.joined(separator: "\n")
        let summaryWasTruncated = Data(input.fileSummary.utf8).count > 16 * 1024
        let summary = limited(input.fileSummary, byteLimit: 16 * 1024)
            + (summaryWasTruncated ? "\n（文件摘要也已达到提示词上限。）" : "")
        let truncationNotice = wasTruncated
            ? "注意：暂存区 diff 过大，下面只包含按文件截取的片段。请结合文件摘要概括，不要编造未展示的改动。"
            : "下面是完整的暂存区 diff。"

        let text = """
        请只根据下面提供的文本生成一条提交信息草稿，不要读取工作区文件或运行命令。目标是让不看 diff 的维护者也能从标题理解这次提交最主要的具体行为变化或修复结果。参考最近的人工提交标题，自行推断仓库惯用的格式、语言、措辞和是否使用 scope；历史标题只用于学习风格，不得用它们代替对当前改动的理解。

        最近的提交标题：
        \(styleSamples)

        文件摘要：
        \(summary)

        \(truncationNotice)

        暂存区 diff：
        \(diff)

        标题先识别主改动，写清具体对象和改动后的结果；修复问题时，在篇幅允许的范围内优先体现触发场景、原有问题或修复结果。不得只用“完善”“优化”“调整”“相关逻辑”“若干改进”等笼统措辞概括改动，也不要只复述文件名、类型名或 diff 术语。

        按所提供的 JSON schema 输出：subject 放标题。当标题无法交代关键原因、多个紧密相关的变化或可从 diff 确认的测试时，body 用 1～3 行补充；否则留空。不要编造测试结果。字段内容只写提交信息本身，不要解释，不要使用代码块，不要添加“这是提交信息”之类的开场白。
        """

        return Result(text: text, wasTruncated: wasTruncated)
    }

    /// 超限时给每个文件留一段，而不是让排在前面的单个大文件吃完整个预算。
    static func limitedDiff(_ diff: String, byteLimit: Int) -> String {
        guard byteLimit > 0 else { return "" }
        let sections = splitFileDiffs(diff)
        guard sections.count > 1 else { return limited(diff, byteLimit: byteLimit) }

        var remaining = byteLimit
        var output = ""
        for (index, section) in sections.enumerated() {
            if !output.isEmpty {
                guard remaining > 1 else { break }
                output.append("\n")
                remaining -= 1
            }
            let remainingFiles = sections.count - index
            let allowance = max(1, remaining / remainingFiles)
            let fragment = limited(section, byteLimit: allowance)
            output.append(fragment)
            remaining -= Data(fragment.utf8).count
            if remaining == 0 { break }
        }
        return output
    }

    private static func splitFileDiffs(_ diff: String) -> [String] {
        var sections: [String] = []
        var current: [Substring] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git "), !current.isEmpty {
                sections.append(current.joined(separator: "\n"))
                current.removeAll(keepingCapacity: true)
            }
            current.append(line)
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
        return sections
    }

    static func limited(_ text: String, byteLimit: Int) -> String {
        guard Data(text.utf8).count > byteLimit else { return text }
        guard byteLimit > 0 else { return "" }

        var bytes = 0
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            let characterBytes = text[end..<next].utf8.count
            if bytes + characterBytes > byteLimit { break }
            bytes += characterBytes
            end = next
        }
        return String(text[..<end])
    }
}

enum CommitMessageCleaner {
    static func clean(_ value: String) -> String {
        var lines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        trimBlankLines(&lines)
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        trimBlankLines(&lines)

        if let first = lines.first {
            let prefixes = [
                "提交信息：", "提交信息:", "Commit message:", "Commit Message:",
                "Here is the commit message:", "Here's the commit message:"
            ]
            for prefix in prefixes where first.hasPrefix(prefix) {
                lines[0] = String(first.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if lines[0].isEmpty { lines.removeFirst() }
                break
            }
        }

        trimBlankLines(&lines)
        return lines.joined(separator: "\n")
    }

    private static func trimBlankLines(_ lines: inout [String]) {
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
    }
}
