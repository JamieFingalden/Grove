import Foundation

/// 一个 git 工作树。对应 `git worktree list --porcelain` 的一条记录。
struct Worktree: Identifiable, Hashable, Sendable {
    var path: URL
    /// HEAD 指向的 commit。全新的空仓库还没有 HEAD，所以是可选的。
    var head: String?
    /// 短分支名（已剥掉 `refs/heads/` 前缀）。detached HEAD 时为 nil。
    var branch: String?
    var isBare: Bool
    var isDetached: Bool
    /// 被锁定的原因。锁定的工作树不会被 `git worktree prune` 清掉，
    /// 常见于放在可移动磁盘上的工作树。nil 表示没锁。
    var lockReason: String?
    /// 可被 prune 的原因（通常是「目录已经不存在了」）。nil 表示健康。
    var prunableReason: String?

    var id: URL { path }
    var isLocked: Bool { lockReason != nil }
    var isPrunable: Bool { prunableReason != nil }

    /// 目录名。工作树列表里主要靠它认人 —— 比完整路径短，比分支名稳定
    /// （分支可以改名，目录不会自己动）。
    var name: String { path.lastPathComponent }

    /// 主工作树（也就是仓库本体）。git 保证它排在 `worktree list` 第一位。
    var isPrimary: Bool = false

    /// 界面上显示的「当前在哪」。detached 时给短 oid，否则给分支名。
    var checkoutLabel: String {
        if let branch { return branch }
        if let head { return String(head.prefix(7)) + "（游离 HEAD）" }
        return "空仓库"
    }
}

/// 一个本地分支。字段来自 `git for-each-ref`。
struct Branch: Identifiable, Hashable, Sendable {
    var name: String
    var oid: String
    /// 上游分支短名，比如 `origin/main`。没设上游时为 nil。
    var upstream: String?
    /// 相对上游领先 / 落后多少个提交。没有上游时都是 0。
    var ahead: Int
    var behind: Int
    /// 上游已经在远端被删了（`[gone]`）。这种分支通常是 PR 合并后的残留，可以清理。
    var upstreamIsGone: Bool
    /// 已经被某个工作树占用。git 不允许同一个分支同时在两个工作树里检出，
    /// 所以「新建工作树」时必须把这些分支灰掉。
    var worktreePath: URL?
    var lastCommitDate: Date?
    var subject: String

    var id: String { name }
    var isCheckedOut: Bool { worktreePath != nil }
    var hasUpstream: Bool { upstream != nil }
}

/// 一个远端分支的精简信息，用于「基于远端分支建工作树」。
struct RemoteBranch: Identifiable, Hashable, Sendable {
    /// 完整短名，例如 `origin/feature/login`。
    var name: String
    /// 去掉 remote 前缀之后的分支名，例如 `feature/login`。新建本地分支时用它作默认名。
    var localName: String
    var oid: String
    var lastCommitDate: Date?

    var id: String { name }
}
