import Foundation

/// 解析 `git status --porcelain=v2 --branch -z`。
///
/// 用 v2 而不是 v1，因为 v1 把暂存区和工作区的状态挤在两个字符里、重命名的两个路径
/// 用 ` -> ` 连接 —— 文件名里有箭头就废了。v2 每条记录字段固定、路径单独一段，能解析干净。
///
/// 用 `-z` 而不是换行分隔，因为文件名可以包含换行符。代价是重命名记录会跨两段
/// （见下面 `2` 分支的注释），解析时必须用游标而不能简单 map。
enum StatusParser {
    static func parse(_ data: Data) -> WorktreeStatus {
        let text = CommandResult.decode(data)
        // 末尾那个 NUL 会切出一个空段，直接滤掉。
        let fields = text.components(separatedBy: "\0").filter { !$0.isEmpty }

        var status = WorktreeStatus.empty
        var changes: [FileChange] = []
        var index = 0

        while index < fields.count {
            let field = fields[index]
            index += 1

            guard let marker = field.first else { continue }
            switch marker {
            case "#":
                applyHeader(field, to: &status)
            case "1":
                if let change = parseOrdinary(field) { changes.append(change) }
            case "2":
                // 重命名 / 复制：来源路径是**下一段**，不在本段里。
                // git 这么设计是为了让两个路径都能安全地含任意字节。
                let originalPath = index < fields.count ? fields[index] : nil
                if originalPath != nil { index += 1 }
                if let change = parseRename(field, originalPath: originalPath) { changes.append(change) }
            case "u":
                if let change = parseUnmerged(field) { changes.append(change) }
            case "?":
                let path = String(field.dropFirst(2))
                if !path.isEmpty {
                    changes.append(FileChange(path: path, originalPath: nil, staged: nil, unstaged: .untracked, isConflicted: false))
                }
            case "!":
                break   // 被忽略的文件不进变更列表
            default:
                break
            }
        }

        // 按路径排序，让列表在两次刷新之间保持稳定 —— git 的输出顺序本身也是稳定的，
        // 但混合了 untracked 之后就不是全局有序了，跳来跳去很难点中。
        status.changes = changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }

    // MARK: - 表头

    private static func applyHeader(_ field: String, to status: inout WorktreeStatus) {
        let parts = field.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return }
        let value = parts[2]

        switch parts[1] {
        case "branch.oid":
            // 全新仓库还没有提交时 git 给的是字面量 `(initial)`。
            status.oid = value == "(initial)" ? nil : value
        case "branch.head":
            status.branch = value == "(detached)" ? nil : value
        case "branch.upstream":
            status.upstream = value
        case "branch.ab":
            // 形如 `+2 -1`。
            for token in value.split(separator: " ") {
                guard let sign = token.first, let count = Int(token.dropFirst()) else { continue }
                if sign == "+" { status.ahead = count }
                if sign == "-" { status.behind = count }
            }
        default:
            break
        }
    }

    // MARK: - 变更记录

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private static func parseOrdinary(_ field: String) -> FileChange? {
        let parts = field.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 9 else { return nil }
        let (staged, unstaged) = decodeXY(parts[1])
        return FileChange(path: parts[8], originalPath: nil, staged: staged, unstaged: unstaged, isConflicted: false)
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>`，来源路径在下一段。
    private static func parseRename(_ field: String, originalPath: String?) -> FileChange? {
        let parts = field.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 10 else { return nil }
        let (staged, unstaged) = decodeXY(parts[1])
        return FileChange(path: parts[9], originalPath: originalPath, staged: staged, unstaged: unstaged, isConflicted: false)
    }

    /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
    private static func parseUnmerged(_ field: String) -> FileChange? {
        let parts = field.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 11 else { return nil }
        return FileChange(path: parts[10], originalPath: nil, staged: .unmerged, unstaged: .unmerged, isConflicted: true)
    }

    /// XY 两个字符分别是暂存区、工作区的状态，`.` 表示这一侧没变化。
    private static func decodeXY(_ code: String) -> (ChangeKind?, ChangeKind?) {
        let characters = Array(code)
        guard characters.count == 2 else { return (nil, nil) }
        return (kind(for: characters[0]), kind(for: characters[1]))
    }

    private static func kind(for character: Character) -> ChangeKind? {
        switch character {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .unmerged
        default: nil    // "." = 这一侧无变化
        }
    }
}
