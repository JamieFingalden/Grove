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

/// 冲突的具体形态，来自 `git status` 未合并条目的 XY 两列。
///
/// X 说的是「当前侧」（HEAD，索引第 2 阶段），Y 是「传入侧」（第 3 阶段）。
/// 这个信息决定了「采用一侧」该跑哪条命令：那一侧被删掉的文件没有内容可检出，
/// 只能 `git rm`；不分清楚就会对着不存在的版本 `checkout --ours`，然后报错。
enum ConflictKind: String, Sendable, Hashable, CaseIterable {
    case bothModified = "UU"
    case bothAdded = "AA"
    /// 当前侧改了、传入侧删了。工作区里留着的是当前侧的版本。
    case deletedByThem = "UD"
    /// 当前侧删了、传入侧改了。工作区里留着的是传入侧的版本。
    case deletedByUs = "DU"
    case addedByUs = "AU"
    case addedByThem = "UA"
    /// 双方都删了。只会出现在重命名冲突里，解决办法只有一个：确认删除。
    case bothDeleted = "DD"

    var label: String {
        switch self {
        case .bothModified: "双方修改"
        case .bothAdded: "双方新增"
        case .deletedByThem: "传入侧已删除"
        case .deletedByUs: "当前侧已删除"
        case .addedByUs: "仅当前侧新增"
        case .addedByThem: "仅传入侧新增"
        case .bothDeleted: "双方删除"
        }
    }

    /// 界面上的一句话解释，说清两侧各做了什么。
    var explanation: String {
        switch self {
        case .bothModified: "两侧都改了这个文件，而且改到了同一片区域。"
        case .bothAdded: "两侧各自新增了同名文件，内容不同。"
        case .deletedByThem: "当前侧修改了这个文件，传入侧把它删了。"
        case .deletedByUs: "当前侧删除了这个文件，传入侧又修改了它。"
        case .addedByUs: "只有当前侧有这个文件（通常来自重命名冲突）。"
        case .addedByThem: "只有传入侧有这个文件（通常来自重命名冲突）。"
        case .bothDeleted: "两侧都删掉了这个文件。"
        }
    }

    /// 当前侧（索引第 2 阶段）有没有内容。
    var oursExists: Bool {
        switch self {
        case .bothModified, .bothAdded, .deletedByThem, .addedByUs: true
        case .deletedByUs, .addedByThem, .bothDeleted: false
        }
    }

    /// 传入侧（索引第 3 阶段）有没有内容。
    var theirsExists: Bool {
        switch self {
        case .bothModified, .bothAdded, .deletedByUs, .addedByThem: true
        case .deletedByThem, .addedByUs, .bothDeleted: false
        }
    }

    /// git 只在两侧都有内容时才往工作区文件里写 `<<<<<<<` 标记。其余形态没有
    /// 「逐块选」可言，整个文件就是「留下还是删掉」两个选项。
    var hasTextualMarkers: Bool {
        self == .bothModified || self == .bothAdded
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
    /// 处于冲突中时的具体形态。非 nil 即为冲突文件，此时 `unstaged` 是 `.unmerged`、
    /// `staged` 为 nil —— 索引里躺着的是三个阶段的半成品，不是能提交的内容，不算「已暂存」。
    var conflict: ConflictKind?

    var id: String { path }
    var isConflicted: Bool { conflict != nil }

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
    var conflictedChanges: [FileChange] { changes.filter(\.isConflicted) }
    var conflictCount: Int { conflictedChanges.count }
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

    /// 动作本身的名字，拼进「继续合并」「中止变基」这类文案。
    var verb: String {
        switch self {
        case .merge: "合并"
        case .rebase: "变基"
        case .cherryPick: "拣选"
        case .revert: "回退"
        case .bisect: "二分查找"
        }
    }

    /// 对应的 git 子命令，`--continue / --skip / --abort` 都挂在它下面。
    /// 二分查找没有这一套（它用 `bisect reset`），交给终端。
    var commandName: String? {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        case .bisect: nil
        }
    }

    /// 能不能从 Grove 里「继续 / 中止」。
    var isSteppable: Bool { commandName != nil }

    /// `--skip` 只对逐个重放提交的操作有意义；合并只有一个结果可言，没得跳。
    var supportsSkip: Bool {
        switch self {
        case .rebase, .cherryPick, .revert: true
        case .merge, .bisect: false
        }
    }
}

/// 指向某个提交的引用。
struct CommitRef: Hashable, Sendable, Identifiable {
    enum Kind: Sendable, Hashable { case head, localBranch, remoteBranch, tag }

    var name: String
    var kind: Kind
    var id: String { "\(kind)-\(name)" }

    /// `%D` 给的是逗号分隔的一串，形如
    /// `HEAD -> main, origin/main, tag: v1.0`。
    ///
    /// `remotes` 是仓库里已配置的远端名。**必须拿它来判断，不能看有没有斜杠** ——
    /// `feature/login` 是个再正常不过的本地分支名，按斜杠判会把它错标成远端分支。
    /// 判断时要连斜杠一起比，否则远端 `orig` 会先命中 `origin/main`。
    static func parse(_ raw: String, remotes: [String] = []) -> [CommitRef] {
        raw.components(separatedBy: ",").compactMap { piece in
            var token = piece.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { return nil }

            if token.hasPrefix("tag: ") {
                return CommitRef(name: String(token.dropFirst(5)), kind: .tag)
            }
            // `HEAD -> main` 是一个条目，表示 HEAD 指向 main。
            // 界面上要显示成分支 main 并标出 HEAD 在这儿。
            if token.hasPrefix("HEAD -> ") {
                return CommitRef(name: String(token.dropFirst(8)), kind: .head)
            }
            if token == "HEAD" {
                return CommitRef(name: "HEAD", kind: .head)
            }
            let isRemote = remotes.contains { token.hasPrefix("\($0)/") }
            return CommitRef(name: token, kind: isRemote ? .remoteBranch : .localBranch)
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
    /// 父提交的 oid。画提交图要靠它连线，光有个数不够。
    /// 第一个父提交是「主线」——合并时它代表被合入的那条分支的延续。
    var parents: [String]
    /// 指向这个提交的引用（分支、标签、HEAD）。来自 `%D`。
    /// 没有它的话，图上分不出哪条道是 main。
    var refs: [CommitRef]

    var id: String { oid }
    var shortOID: String { String(oid.prefix(7)) }
    var parentCount: Int { parents.count }
    var isMerge: Bool { parents.count > 1 }
}
