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

        let typeList = CommitSubjectFormatter.allowedTypes.joined(separator: "、")
        let text = """
        请只根据下面提供的文本生成一条提交信息草稿，不要读取工作区文件或运行命令。目标是让不看 diff 的维护者也能从标题理解这次提交最主要的具体行为变化或修复结果。参考最近的人工提交标题学习这个仓库惯用的语言和措辞；历史标题只用于学习风格，不得用它们代替对当前改动的理解。

        标题必须使用 Conventional Commits 格式：以类型前缀开头，后接半角冒号和一个空格，类型后可以用括号注明 scope（如 `fix(parser): ...`）。类型只能从 \(typeList) 中按改动实质选择（新功能 feat、修 bug fix、只改文档 docs……）；无论历史标题是否带前缀，这次都必须带。前缀只出现在标题，正文不重复前缀。

        最近的提交标题：
        \(styleSamples)

        文件摘要：
        \(summary)

        \(truncationNotice)

        暂存区 diff：
        \(diff)

        标题先识别主改动，写清具体对象和改动后的结果；修复问题时，在篇幅允许的范围内优先体现触发场景、原有问题或修复结果。不得只用“完善”“优化”“调整”“相关逻辑”“若干改进”等笼统措辞概括改动，也不要只复述文件名、类型名或 diff 术语。

        按所提供的 JSON schema 输出：type 填标题使用的类型（小写、不含冒号和 scope），subject 填包含类型前缀的完整标题。当标题无法交代关键原因、多个紧密相关的变化或可从 diff 确认的测试时，body 用 1～3 行补充；否则留空。不要编造测试结果。字段内容只写提交信息本身，不要解释，不要使用代码块，不要添加“这是提交信息”之类的开场白。
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

/// 提交标题的 Conventional Commits 前缀规范化。提示词要求模型自带前缀，
/// 但模型输出的写法不稳定（全角冒号、漏空格、大写），也可能整个漏掉前缀，
/// 所以在拿到结果后再规范一次：
/// - 标题里已识别出前缀 → 统一成 `type(scope)!: 正文` 的标准写法；
/// - 标题没有前缀但 schema 的 `type` 字段有效 → 用它补上；
/// - 两边都给不出可信类型 → 原样返回。宁可没有前缀，也不猜一个错的类型。
enum CommitSubjectFormatter {
    /// 允许的类型清单，同时是提示词、输出 schema 的唯一事实来源。
    static let allowedTypes: [String] = [
        "feat", "fix", "refactor", "perf", "docs", "test",
        "chore", "style", "build", "ci", "revert"
    ]

    /// `^(type)(scope)?(!)?[:：]`。类型用分组捕获；冒号兼容半角/全角
    /// （中文语境的模型经常吐全角冒号）；大小写不敏感。
    private static let prefixExpression: NSRegularExpression = {
        // 模式是编译期常量，构造不可能失败；失败也应在启动期立刻暴露。
        try! NSRegularExpression(
            pattern: "^(feat|fix|refactor|perf|docs|test|chore|style|build|ci|revert)(\\([^)\\s]*\\))?(!)?\\s*[:：]\\s*",
            options: [.caseInsensitive]
        )
    }()

    static func canonicalize(_ subject: String, declaredType: String?) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = prefixExpression.firstMatch(
            in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)
        ), let whole = Range(match.range, in: trimmed) else {
            // 标题没有可用前缀，靠 type 字段兜底。
            guard let fallback = normalizedType(declaredType), !trimmed.isEmpty else { return trimmed }
            return "\(fallback): \(trimmed)"
        }

        func piece(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: trimmed) else { return nil }
            return String(trimmed[range])
        }

        // 标题自带的前缀优先于 type 字段：它和措辞是一起选定的，
        // 两个字段打架时（罕见）信标题。
        guard let type = piece(1)?.lowercased() else { return trimmed }
        let scope = piece(2) ?? ""
        let bang = piece(3) != nil ? "!" : ""
        let rest = String(trimmed[whole.upperBound...])
        guard !rest.isEmpty else { return trimmed }
        return "\(type)\(scope)\(bang): \(rest)"
    }

    private static func normalizedType(_ raw: String?) -> String? {
        guard let lowered = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              allowedTypes.contains(lowered) else { return nil }
        return lowered
    }
}
