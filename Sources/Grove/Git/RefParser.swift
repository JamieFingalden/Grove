import Foundation

/// 解析 `git for-each-ref` 的输出。
///
/// 字段分隔用 NUL（格式串里的 `%00`）而不是制表符或竖线：commit subject 里出现
/// 制表符很常见，出现 NUL 不可能。记录之间用换行分隔是安全的，因为 `%(subject)`
/// 只取提交信息的第一行，本身不含换行。
enum RefParser {
    /// 本地分支查询要用的格式串。字段顺序必须跟 `parseBranches` 里的下标对应。
    static let branchFormat = [
        "%(refname:short)",
        "%(objectname)",
        "%(upstream:short)",
        "%(upstream:track)",
        "%(worktreepath)",
        "%(committerdate:iso8601-strict)",
        "%(subject)"
    ].joined(separator: "%00")

    static let remoteBranchFormat = [
        "%(refname:short)",
        "%(objectname)",
        "%(committerdate:iso8601-strict)"
    ].joined(separator: "%00")

    static func parseBranches(_ output: String, currentBranch: String?) -> [Branch] {
        output.components(separatedBy: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count >= 7, !fields[0].isEmpty else { return nil }

            let track = parseTrack(fields[3])
            let worktree = fields[4].isEmpty ? nil : URL(fileURLWithPath: fields[4])

            return Branch(
                name: fields[0],
                oid: fields[1],
                upstream: fields[2].isEmpty ? nil : fields[2],
                ahead: track.ahead,
                behind: track.behind,
                upstreamIsGone: track.isGone,
                worktreePath: worktree,
                lastCommitDate: DateParsing.iso8601(fields[5]),
                subject: fields[6]
            )
        }
    }

    static func parseRemoteBranches(_ output: String) -> [RemoteBranch] {
        output.components(separatedBy: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            let name = fields[0]
            // `origin/HEAD` 是个符号引用，不是真分支，检出它没有意义。
            guard !name.hasSuffix("/HEAD") else { return nil }

            return RemoteBranch(
                name: name,
                localName: stripRemotePrefix(name),
                oid: fields[1],
                lastCommitDate: DateParsing.iso8601(fields[2])
            )
        }
    }

    /// `origin/feature/login` → `feature/login`。只切第一段，因为分支名可以带斜杠。
    static func stripRemotePrefix(_ name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// 解析 `%(upstream:track)`：`[ahead 2, behind 1]` / `[ahead 3]` / `[behind 4]` /
    /// `[gone]` / 空串。
    ///
    /// 直接用 `%(ahead-behind:...)` 更省事，但那是 git 2.41 才有的；这个格式串
    /// 十几年没变过，兼容面更宽。
    static func parseTrack(_ raw: String) -> (ahead: Int, behind: Int, isGone: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return (0, 0, false) }
        let inner = String(trimmed.dropFirst().dropLast())
        if inner == "gone" { return (0, 0, true) }

        var ahead = 0
        var behind = 0
        for segment in inner.components(separatedBy: ",") {
            let tokens = segment.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard tokens.count == 2, let count = Int(tokens[1]) else { continue }
            if tokens[0] == "ahead" { ahead = count }
            if tokens[0] == "behind" { behind = count }
        }
        return (ahead, behind, false)
    }
}

/// 解析 `git log` 的自定义格式输出。
enum LogParser {
    /// 字段用 0x1F（Unit Separator）、记录用 0x1E（Record Separator）分隔。
    /// 这两个控制字符是 ASCII 专门为此设计的，提交信息里出现的概率可以忽略。
    static let format = [
        "%H",   // 完整 oid
        "%P",   // 父提交 oid，空格分隔
        "%an",  // 作者名
        "%ae",  // 作者邮箱
        "%aI",  // 作者日期，ISO 8601 严格格式
        "%s",   // 标题（提交信息第一行）
        "%D"    // 指向这个提交的引用（分支、标签、HEAD）
    ].joined(separator: "\u{1F}") + "\u{1E}"

    static func parse(_ output: String, remotes: [String] = []) -> [CommitSummary] {
        output.components(separatedBy: "\u{1E}").compactMap { record in
            // git 会在每条记录后面额外加一个换行，去掉它才不会污染第一个字段。
            let cleaned = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }

            let fields = cleaned.components(separatedBy: "\u{1F}")
            guard fields.count >= 6 else { return nil }

            let parents = fields[1].split(separator: " ")
                .filter { !$0.isEmpty }
                .map(String.init)
            return CommitSummary(
                oid: fields[0],
                subject: fields[5],
                authorName: fields[2],
                authorEmail: fields[3],
                date: DateParsing.iso8601(fields[4]) ?? Date(timeIntervalSince1970: 0),
                parents: parents,
                // `%D` 是第 7 个字段。老的日志格式没有它，缺了就是没有引用。
                refs: fields.count >= 7 ? CommitRef.parse(fields[6], remotes: remotes) : []
            )
        }
    }
}

enum DateParsing {
    /// 用 `Date.ISO8601FormatStyle` 而不是 `ISO8601DateFormatter`：后者是引用类型、
    /// 不是 `Sendable`，做成共享静态常量在 Swift 6 严格并发下过不了编译；
    /// 每次新建一个又太浪费（刷新一次历史要解析几百个日期）。
    /// FormatStyle 是值类型，共享它没有任何数据竞争风险。
    private static let style = Date.ISO8601FormatStyle()

    static func iso8601(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // git 的 `%aI` 带时区偏移（`+08:00`），这个 style 能正确吃下来。
        return try? style.parse(trimmed)
    }
}
