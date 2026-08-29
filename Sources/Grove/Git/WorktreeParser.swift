import Foundation

/// 解析 `git worktree list --porcelain`。
///
/// 输出是「每行一个 key [value]、空行分隔记录」的格式：
/// ```
/// worktree /Users/me/proj
/// HEAD 8ed3be38...
/// branch refs/heads/main
///
/// worktree /Users/me/proj-feature
/// HEAD a1b2c3d4...
/// detached
/// locked 放在移动硬盘上
/// ```
/// 只有 `worktree` 一行是必定存在的；`bare` 仓库连 HEAD 都没有。
enum WorktreeParser {
    static func parse(_ output: String) -> [Worktree] {
        var worktrees: [Worktree] = []
        var current: Partial?

        func flush() {
            guard let partial = current, let path = partial.path else { return }
            worktrees.append(
                Worktree(
                    path: URL(fileURLWithPath: path),
                    head: partial.head,
                    branch: partial.branch,
                    isBare: partial.isBare,
                    isDetached: partial.isDetached,
                    lockReason: partial.lockReason,
                    prunableReason: partial.prunableReason,
                    // git 保证主工作树排第一位，不用另外去问。
                    isPrimary: worktrees.isEmpty
                )
            )
            current = nil
        }

        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                flush()
                continue
            }

            let (key, value) = splitKeyValue(line)
            switch key {
            case "worktree":
                // 没遇到空行就来了新记录（输出末尾缺空行时会这样），先把上一条收了。
                flush()
                current = Partial(path: value)
            case "HEAD":
                current?.head = value
            case "branch":
                current?.branch = value.map(Self.shortBranchName)
            case "bare":
                current?.isBare = true
            case "detached":
                current?.isDetached = true
            case "locked":
                // `locked` 后面的原因是可选的。没写原因也得算「已锁定」，
                // 所以这里存空串而不是 nil —— nil 的语义是「没锁」。
                current?.lockReason = value ?? ""
            case "prunable":
                current?.prunableReason = value ?? ""
            default:
                break
            }
        }
        flush()
        return worktrees
    }

    /// `refs/heads/feature/login` → `feature/login`。
    /// 只剥 `refs/heads/`：分支名本身可以带斜杠，不能按最后一段切。
    static func shortBranchName(_ ref: String) -> String {
        let prefix = "refs/heads/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }

    private static func splitKeyValue(_ line: String) -> (String, String?) {
        guard let space = line.firstIndex(of: " ") else { return (line, nil) }
        let key = String(line[line.startIndex..<space])
        let value = String(line[line.index(after: space)...])
        return (key, value.isEmpty ? nil : value)
    }

    private struct Partial {
        var path: String?
        var head: String?
        var branch: String?
        var isBare = false
        var isDetached = false
        var lockReason: String?
        var prunableReason: String?
    }
}
