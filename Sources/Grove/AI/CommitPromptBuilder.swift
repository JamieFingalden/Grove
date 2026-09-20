import Foundation

enum CommitPromptBuilder {
    /// 256KB：直接对齐 AI Review 的预算。现代模型的上下文足够容纳，而且
    /// DiffBudget 会先跳过测试/生成代码这些低价值文件，实际能覆盖的改动
    /// 比数字看起来大得多。
    static let defaultMaxDiffBytes = 256 * 1024

    struct Input: Sendable {
        var stagedDiff: String
        var recentSubjects: [String]
        var fileSummary: String
        var maxDiffBytes: Int = CommitPromptBuilder.defaultMaxDiffBytes
    }

    struct Result: Sendable {
        var text: String
        var wasTruncated: Bool
        /// 取舍说明（跳过了哪些、截断了哪些）。没有内容丢失时为 nil。
        var note: String?
    }

    static func prompt(_ input: Input) -> String {
        build(input).text
    }

    static func build(_ input: Input) -> Result {
        let limit = max(0, input.maxDiffBytes)
        let plan = DiffBudget.plan(diff: input.stagedDiff, byteLimit: limit)
        let diff = plan.diff
        let subjects = input.recentSubjects
            .filter { !$0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("merge ") }
            .prefix(20)
        let styleSamples = subjects.isEmpty
            ? "（没有可用的历史提交标题，请根据改动生成简洁、自然的提交信息。）"
            : subjects.map { "- \(limited($0, byteLimit: 512))" }.joined(separator: "\n")
        let summaryWasTruncated = Data(input.fileSummary.utf8).count > 16 * 1024
        let summary = limited(input.fileSummary, byteLimit: 16 * 1024)
            + (summaryWasTruncated ? "\n（文件摘要也已达到提示词上限。）" : "")
        let truncationNotice = plan.notice ?? "下面是完整的暂存区 diff。"

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

        return Result(text: text, wasTruncated: plan.wasTruncated, note: plan.notice)
    }

    /// 旧接口：超限时智能取舍后返回 diff 文本，细节见 `DiffBudget`。
    static func limitedDiff(_ diff: String, byteLimit: Int) -> String {
        DiffBudget.plan(diff: diff, byteLimit: byteLimit).diff
    }

    /// 字节安全截断的单一实现在 `DiffBudget.limited`。
    static func limited(_ text: String, byteLimit: Int) -> String {
        DiffBudget.limited(text, byteLimit: byteLimit)
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
