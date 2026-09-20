import Foundation

/// 把超过预算的 unified diff 压缩进提示词。
///
/// 旧策略是把预算平均分给每个文件 —— 30 个文件超预算时，每个文件只剩几十行，
/// 模型等于什么都没看到。新策略按信息价值取舍：
///
/// 1. 测试、锁文件、生成代码、快照这类「体积大、对概括改动帮助小」的文件
///    整个跳过，只留一行名字和增删统计，让模型知道它们存在；
/// 2. 省下的预算让核心代码文件尽量**完整**出现（放不下的按 hunk 边界截断，
///    绝不把一个 hunk 切一半）；
/// 3. 还有余量时，低价值文件也会按原样放进来 —— 跳过它们只是预算紧张时的
///    让步，不是永久排除。
///
/// 任何内容丢失都会在结果里给出一句人话说明，界面直接展示，不再笼统地说
/// 「只分析了一部分」。
enum DiffBudget {
    struct Outcome: Sendable {
        var diff: String
        /// 有任何内容被省略或截断都是 true（包括只跳过了测试文件）。
        var wasTruncated: Bool
        /// 取舍说明。没有内容丢失时为 nil。
        var notice: String?
    }

    /// 单个文件在预算里至少要分到这么多字节，否则整个省略（只留名字）。
    /// 少于这个数的片段既看不懂又浪费省略清单的篇幅。
    private static let minFragmentBytes = 96

    /// 省略清单最多列这么多个文件，避免几百个测试文件把清单本身撑爆预算。
    private static let maxOmissionLines = 40

    // MARK: - 入口

    static func plan(diff: String, byteLimit: Int) -> Outcome {
        let limit = max(0, byteLimit)
        guard limit > 0 else {
            return Outcome(
                diff: "",
                wasTruncated: !diff.isEmpty,
                notice: diff.isEmpty ? nil : "diff 过大，内容已整体省略。"
            )
        }
        guard Data(diff.utf8).count > limit else {
            return Outcome(diff: diff, wasTruncated: false, notice: nil)
        }

        let sections = splitFileDiffs(diff).map(parseSection)
        // 只有一个文件时没有取舍空间：直接按 hunk 边界截这一段。
        guard sections.count > 1 else {
            let trimmed = trim(sections[0], byteLimit: limit)
            return Outcome(
                diff: trimmed.text,
                wasTruncated: true,
                notice: "diff 过大，这个文件只保留了能放下的部分。"
            )
        }

        let lowValue = sections.filter(\.isLowValue)
        let core = sections.filter { !$0.isLowValue }

        // 先给省略清单留预算，剩下的才轮得到核心文件。预算本身很小的时候
        // 清单退化成一句话，不能让清单自己吃光预算。
        let omissionBudget = max(120, limit / 3)
        let omissionBlock = renderOmissions(lowValue, extra: [], maxBytes: omissionBudget)
        var remaining = limit - Data(omissionBlock.utf8).count - 1

        var parts: [String] = []
        var trimmedCoreCount = 0
        var extraOmitted: [Section] = []

        for (index, section) in core.enumerated() {
            let filesLeft = core.count - index
            let allowance = remaining / filesLeft
            if section.byteCount <= allowance {
                parts.append(section.raw)
                remaining -= section.byteCount + 1
            } else if allowance >= minFragmentBytes {
                let trimmed = trim(section, byteLimit: allowance)
                parts.append(trimmed.text)
                remaining -= Data(trimmed.text.utf8).count + 1
                if trimmed.wasTrimmed { trimmedCoreCount += 1 }
            } else {
                // 连最小说明片段都放不下：整个省略，进清单。
                extraOmitted.append(section)
            }
        }

        // 核心文件放完还有明显余量时，低价值文件也尽量按原样放进去。
        var includedLowValue: [Section] = []
        var stillOmitted = lowValue
        if remaining > minFragmentBytes * 2 {
            for section in lowValue where section.byteCount + 1 <= remaining {
                includedLowValue.append(section)
                remaining -= section.byteCount + 1
            }
            let included = Set(includedLowValue.map(\.path))
            stillOmitted = lowValue.filter { !included.contains($0.path) }
        }

        let finalBlock = renderOmissions(stillOmitted, extra: extraOmitted, maxBytes: omissionBudget)
        var pieces = [finalBlock]
        pieces.append(contentsOf: parts)
        pieces.append(contentsOf: includedLowValue.map(\.raw))

        var text = pieces.joined(separator: "\n")
        // 省略清单在核心文件取舍后重新渲染过，可能比预留的略长；这里兜底裁掉
        // 尾部的低价值文件，保证总量不超预算。
        while Data(text.utf8).count > limit, !includedLowValue.isEmpty {
            let dropped = includedLowValue.removeLast()
            stillOmitted.append(dropped)
            pieces = [renderOmissions(stillOmitted, extra: extraOmitted, maxBytes: omissionBudget)]
            pieces.append(contentsOf: parts)
            pieces.append(contentsOf: includedLowValue.map(\.raw))
            text = pieces.joined(separator: "\n")
        }
        if Data(text.utf8).count > limit {
            // 极端情况下（清单加核心文件本身超限）：只保留省略清单。
            text = finalBlock
        }

        return Outcome(diff: text, wasTruncated: true, notice: notice(
            omitted: stillOmitted.count + extraOmitted.count,
            trimmed: trimmedCoreCount
        ))
    }

    private static func notice(omitted: Int, trimmed: Int) -> String {
        var segments: [String] = []
        if omitted > 0 {
            segments.append("跳过了 \(omitted) 个低价值文件（测试/锁文件/生成代码等，名字列在 diff 开头）")
        }
        if trimmed > 0 {
            segments.append("截断了 \(trimmed) 个核心文件（只保留能放下的 hunk）")
        }
        return "diff 过大：" + segments.joined(separator: "，") + "。"
    }

    // MARK: - 省略清单

    private static func renderOmissions(_ skipped: [Section], extra: [Section], maxBytes: Int) -> String {
        let all = skipped + extra
        guard !all.isEmpty else { return "" }

        var lines = ["（diff 过大，以下 \(all.count) 个文件已整体省略，只列名字：）"]
        let listed = all.prefix(maxOmissionLines)
        lines.append(contentsOf: listed.map {
            "- \($0.path)（+\($0.additions) −\($0.deletions)）"
        })
        if all.count > listed.count {
            lines.append("（另有 \(all.count - listed.count) 个文件未一一列出。）")
        }
        let full = lines.joined(separator: "\n")
        if Data(full.utf8).count <= maxBytes { return full }
        return "（diff 过大，已省略 \(all.count) 个文件：测试/锁文件/生成代码等低价值改动优先跳过。）"
    }

    // MARK: - 截断

    /// 按预算截一段文件 diff。优先按 hunk 边界保留完整 hunk；单个 hunk 比预算
    /// 还大时退回原始硬截断（保住开头也比什么都不给强）。
    private static func trim(_ section: Section, byteLimit: Int) -> (text: String, wasTrimmed: Bool) {
        guard section.byteCount > byteLimit else { return (section.raw, false) }

        let marker = "\n（…… 该文件 diff 过大，以下内容被截断）"
        let usable = byteLimit - Data(marker.utf8).count
        guard usable > 0 else {
            let head = limited(section.raw, byteLimit: byteLimit)
            return (head, true)
        }

        let lines = SectionSplitter.lines(section.raw)
        var headerEnd = 0
        while headerEnd < lines.count, !lines[headerEnd].hasPrefix("@@ ") {
            headerEnd += 1
        }
        guard headerEnd < lines.count else {
            // 没有 hunk 边界（理论上不该发生）：硬截。
            return (limited(section.raw, byteLimit: usable) + marker, true)
        }

        var byteCount = 0
        var hunkStart = headerEnd
        var lastFittingEnd = headerEnd
        var index = headerEnd
        while index < lines.count {
            if lines[index].hasPrefix("@@ "), index != hunkStart {
                if byteCount > usable { break }
                lastFittingEnd = index
                hunkStart = index
            }
            byteCount += lines[index].utf8.count + 1
            index += 1
        }
        if byteCount <= usable { lastFittingEnd = lines.count }

        if lastFittingEnd > headerEnd {
            let kept = lines[0..<lastFittingEnd].joined(separator: "\n")
            return (kept + marker, true)
        }
        // 连第一个完整 hunk 都放不下：硬截开头。
        return (limited(section.raw, byteLimit: usable) + marker, true)
    }

    // MARK: - 解析

    struct Section {
        var raw: String
        var path: String
        var additions: Int
        var deletions: Int
        var isLowValue: Bool
        var byteCount: Int
    }

    private static func parseSection(_ raw: String) -> Section {
        let firstLine = raw.prefix { $0 != "\n" }
        var path = String(firstLine)
        if path.hasPrefix("diff --git ") {
            path.removeFirst("diff --git ".count)
            if let range = path.range(of: " b/") {
                path = String(path[range.upperBound...])
            } else {
                path = String(path.dropFirst(2))
            }
        }
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count > 1 {
            path = String(path.dropFirst().dropLast())
        }

        var additions = 0
        var deletions = 0
        for line in SectionSplitter.lines(raw) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { additions += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { deletions += 1 }
        }

        return Section(
            raw: raw,
            path: path,
            additions: additions,
            deletions: deletions,
            isLowValue: Self.isLowValue(path),
            byteCount: Data(raw.utf8).count
        )
    }

    /// 路径是不是「对概括改动帮助小」的文件。只在预算吃紧时才会真的跳过，
    /// 所以误伤的代价是「这个文件只留了一行名字」，可以接受。
    static func isLowValue(_ rawPath: String) -> Bool {
        let path = rawPath.lowercased()
        let segments = path.split(separator: "/").map(String.init)
        let name = segments.last ?? path

        if lowValueBasenames.contains(name) || name.hasSuffix(".lock") || name == "conftest.py" {
            return true
        }
        let directoryHints: Set<String> = [
            "test", "tests", "__tests__", "spec", "specs", "fixtures", "test_fixtures",
            "__snapshots__", "snapshots", "testdata", "mocks", "__mocks__",
            "vendor", "node_modules", "pods", "dist", "build", "target",
            "generated", "__generated__"
        ]
        if segments.dropLast().contains(where: directoryHints.contains) { return true }

        if name.hasPrefix("test_") || name == "conftest.py" {
            return true
        }
        let nameHints = [
            "_test.", "_tests.", ".test.", ".spec.", "_spec.",
            ".min.js", ".min.css", ".snap", ".pb.go", "_pb2.py", "_pb2_grpc.py",
            ".generated.", ".g.dart", ".g.cs",
            ".strings", ".stringsdict", ".po", ".svg"
        ]
        return nameHints.contains { name.contains($0) }
    }

    private static let lowValueBasenames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
        "podfile.lock", "cartfile.resolved", "package.resolved",
        "cargo.lock", "go.sum", "go.work.sum", "poetry.lock", "composer.lock",
        "gemfile.lock", "flake.lock", "uv.lock", "mix.lock", "packages.lock.json"
    ]

    /// 按 `diff --git` 行切分成单文件段。每段都带自己的文件头。
    static func splitFileDiffs(_ diff: String) -> [String] {
        SectionSplitter.split(diff)
    }

    // MARK: - 字节安全截断（借调自 CommitPromptBuilder 的通用实现）

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

/// 行切分的小工具。独立出来是为了测试里也能按行重组文本。
enum SectionSplitter {
    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func split(_ diff: String) -> [String] {
        var sections: [String] = []
        var current: [String] = []
        for line in lines(diff) {
            if line.hasPrefix("diff --git "), !current.isEmpty {
                sections.append(current.joined(separator: "\n"))
                current.removeAll(keepingCapacity: true)
            }
            current.append(line)
        }
        if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
        return sections
    }
}
