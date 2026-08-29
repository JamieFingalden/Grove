import Foundation

/// 一个文件相对 HEAD / 索引发生了什么。
enum ChangeKind: String, Sendable, Hashable {
    case added = "新增"
    case modified = "修改"
    case deleted = "删除"
    case renamed = "重命名"
    case copied = "复制"
    case typeChanged = "类型变更"
    case untracked = "未跟踪"
    case unmerged = "冲突"

    /// SF Symbol 名。列表里靠图标区分状态比靠颜色可靠 —— 色盲用户也能分辨。
    var systemImage: String {
        switch self {
        case .added, .untracked: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.right.circle.fill"
        case .copied: "doc.on.doc.fill"
        case .typeChanged: "arrow.triangle.2.circlepath.circle.fill"
        case .unmerged: "exclamationmark.triangle.fill"
        }
    }

    /// 单字母角标，跟 `git status --short` 的记号对齐，老手一眼就懂。
    var badge: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "?"
        case .unmerged: "U"
        }
    }
}

/// 工作区里的一个变更条目。
///
/// git 的状态是二维的：同一个文件可以「暂存区里是新增、工作区里又被改了」。
/// 所以这里保留 `staged` 和 `unstaged` 两个独立的可选值，而不是压成一个状态 ——
/// 压扁之后就没法正确渲染「部分暂存」，而那恰恰是提交前最需要看清楚的情况。
struct FileChange: Identifiable, Hashable, Sendable {
    var path: String
    /// 重命名 / 复制的来源路径。
    var originalPath: String?
    var staged: ChangeKind?
    var unstaged: ChangeKind?
    /// 冲突中。此时 staged/unstaged 都是 `.unmerged`。
    var isConflicted: Bool

    var id: String { path }

    var isStaged: Bool { staged != nil }
    var isFullyStaged: Bool { staged != nil && unstaged == nil }
    var isPartiallyStaged: Bool { staged != nil && unstaged != nil }

    /// 主状态：优先展示工作区的变化，因为那是「还没定下来」的部分。
    var primaryKind: ChangeKind {
        unstaged ?? staged ?? .modified
    }

    var displayName: String {
        (path as NSString).lastPathComponent
    }

    var directory: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }
}

/// 工作树的整体状态，`git status --porcelain=v2 --branch` 一次拿全。
struct WorktreeStatus: Sendable, Hashable {
    var branch: String?
    var upstream: String?
    var ahead: Int
    var behind: Int
    var oid: String?
    var changes: [FileChange]
    /// 仓库处于某种「多步操作进行中」的状态（rebase / merge / cherry-pick 等）。
    /// 这时候大部分按钮都该禁用，否则用户一点就把自己坑进更深的洞里。
    var operation: RepositoryOperation?

    static let empty = WorktreeStatus(
        branch: nil, upstream: nil, ahead: 0, behind: 0,
        oid: nil, changes: [], operation: nil
    )

    var isClean: Bool { changes.isEmpty }
    var stagedCount: Int { changes.filter(\.isStaged).count }
    var unstagedCount: Int { changes.filter { $0.unstaged != nil }.count }
    var conflictCount: Int { changes.filter(\.isConflicted).count }
    var hasConflicts: Bool { conflictCount > 0 }
}

/// 进行中的多步 git 操作。靠 `.git` 目录里的状态文件判断。
enum RepositoryOperation: String, Sendable, Hashable {
    case merge = "合并中"
    case rebase = "变基中"
    case cherryPick = "拣选中"
    case revert = "回退中"
    case bisect = "二分查找中"

    var systemImage: String {
        switch self {
        case .merge: "arrow.triangle.merge"
        case .rebase: "arrow.triangle.branch"
        case .cherryPick: "hand.point.up.left"
        case .revert: "arrow.uturn.backward"
        case .bisect: "magnifyingglass"
        }
    }
}

/// 历史筛选条件。对应 `git log` 的几个过滤参数。
struct LogQuery: Sendable, Hashable {
    /// 在提交信息里搜。对应 `--grep`。
    var text = ""
    /// 提交人筛选。可以多选 —— 同一个人在本地和远端用不同名字提交是常态
    /// （本地 `jamie`、GitLab 上「范高健」），只能选一个的话永远看不全自己的提交。
    /// git 的多个 `--author` 之间是「或」，正好对上。
    /// 存的是邮箱（更精确）或姓名，取决于哪个能唯一定位。
    var authors: [String] = []
    /// 只看动过某个路径的提交。对应 `git log -- <路径>`。
    var path = ""
    /// 只看当前分支，还是所有分支。
    var allBranches = false
    var limit = 200

    var isActive: Bool {
        !text.isEmpty || !authors.isEmpty || !path.isEmpty || allBranches
    }

    /// 界面上显示「筛掉了什么」，让用户知道看到的不是全部。
    var summary: String? {
        var parts: [String] = []
        if !authors.isEmpty {
            parts.append(authors.count == 1
                         ? "提交人 \(authors[0])"
                         : "提交人 \(authors.count) 位")
        }
        if !text.isEmpty { parts.append("包含「\(text)」") }
        if !path.isEmpty { parts.append("路径 \(path)") }
        if allBranches { parts.append("所有分支") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 仓库里出现过的一个提交身份。
///
/// 姓名和邮箱分开存，因为「同一个人」在 git 里可以有好几个身份：
/// 换过邮箱、公司机器和个人机器配得不一样、本地用英文名远端用中文名。
/// 界面上两个都显示，用户才分得清哪个是哪个。
struct CommitAuthor: Identifiable, Hashable, Sendable {
    var name: String
    var email: String
    /// 提交数。多的排前面 —— 下拉框里最常打交道的人该在最上面。
    var count: Int

    var id: String { "\(name)|\(email)" }

    /// 传给 `git log --author=` 的值。
    /// 优先用邮箱：它比姓名更能唯一定位一个身份，而且同一邮箱换过显示名时
    /// 按邮箱筛能一次把两种名字的提交都捞出来。
    var filterToken: String { email.isEmpty ? name : email }

    var display: String { email.isEmpty ? name : "\(name) <\(email)>" }
}

/// 提交历史里的一行。
struct CommitSummary: Identifiable, Hashable, Sendable {
    var oid: String
    var subject: String
    var authorName: String
    var authorEmail: String
    var date: Date
    /// 父提交个数 > 1 即合并提交。
    var parentCount: Int

    var id: String { oid }
    var shortOID: String { String(oid.prefix(7)) }
    var isMerge: Bool { parentCount > 1 }
}
