import Foundation

/// 统一 diff 里的一行。
struct DiffLine: Identifiable, Hashable, Sendable {
    enum Kind: Sendable, Hashable {
        case context
        case addition
        case deletion
        /// `\ No newline at end of file`。不是内容，但漏掉它会让人以为 diff 少了一行。
        case noNewline
    }

    var id: Int
    var kind: Kind
    var text: String
    /// 旧文件里的行号。新增行没有。
    var oldNumber: Int?
    /// 新文件里的行号。删除行没有。
    var newNumber: Int?
}

/// diff 里的一段 hunk。
struct DiffHunk: Identifiable, Hashable, Sendable {
    var id: Int
    /// `@@ -1,7 +1,9 @@ func foo()` 整行原文，包含后面的上下文函数名。
    var header: String
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var lines: [DiffLine]
}

/// 一个文件的 diff。
struct FileDiff: Identifiable, Hashable, Sendable {
    var oldPath: String?
    var newPath: String?
    var hunks: [DiffHunk]
    /// 二进制文件。git 只会说「Binary files differ」，没有行级内容可展示。
    var isBinary: Bool
    var isNewFile: Bool
    var isDeletedFile: Bool
    var isRename: Bool
    /// 只改了权限位（比如加了可执行位），内容一个字节没动。
    var isModeChangeOnly: Bool
    var oldMode: String?
    var newMode: String?
    /// 从 `diff --git` 到第一个 `@@` 之间的原始行，原样保留。
    ///
    /// 分行暂存要重新拼一个补丁喂给 `git apply`，而补丁头必须跟 git 自己生成的
    /// 完全一致（index 行的 blob 哈希、模式位、重命名标记都在里面）。
    /// 自己按字段重新拼一遍迟早会漏掉某种情况 —— 直接把原文抄过去最稳。
    var headerLines: [String] = []

    var id: String { newPath ?? oldPath ?? "unknown" }
    var displayPath: String { newPath ?? oldPath ?? "未知文件" }

    var additions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
    }

    var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count }
    }

    /// 没有 hunk 也不是二进制 —— 纯权限变更或者空文件重命名。
    var hasNoTextChanges: Bool { hunks.isEmpty && !isBinary }
}
