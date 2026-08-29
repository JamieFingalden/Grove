import Foundation
import Observation

/// 一个工作树的详细状态：变更、历史、diff，以及关联的 PR。
@MainActor
@Observable
final class WorktreeModel: Identifiable {
    /// 工作树的路径。`worktree` 本身是可变的（刷新时会替换），所以身份标识
    /// 另存一份不可变的 —— `Identifiable` 的 `id` 要能从非隔离上下文读，
    /// 而且一个模型对象的身份本来就不该在生命周期内变化。
    nonisolated let identity: URL
    var worktree: Worktree
    private(set) weak var repository: RepositoryModel?
    private let git: GitClient
    private weak var app: AppModel?

    var status = WorktreeStatus.empty
    var commits: [CommitSummary] = []
    /// 历史筛选条件。改动后由视图调 `reloadHistory()`。
    var logQuery = LogQuery()
    /// 这个仓库出现过的提交身份，填筛选下拉框用。
    var knownAuthors: [CommitAuthor] = []
    var isLoadingHistory = false
    var linkedPullRequest: PullRequest?

    var isLoading = false
    var activity: String?

    /// 当前选中的文件。切换时会去取它的 diff。
    var selectedPath: String? {
        didSet {
            guard selectedPath != oldValue else { return }
            diff = nil
            diffTask?.cancel()
            diffTask = Task { await loadDiff() }
        }
    }

    /// 看的是工作区改动还是暂存区改动。
    var diffSide: DiffSide = .worktree {
        didSet {
            guard diffSide != oldValue else { return }
            diffTask?.cancel()
            diffTask = Task { await loadDiff() }
        }
    }

    enum DiffSide: String, CaseIterable, Identifiable, Sendable {
        case worktree, staged

        var id: String { rawValue }
        var label: String {
            switch self {
            case .worktree: "工作区"
            case .staged: "暂存区"
            }
        }
    }

    private(set) var diff: [FileDiff]?
    private var diffTask: Task<Void, Never>?

    /// 用户在 diff 里勾中的行（按 `DiffLine.id`）。用于「只提交其中一行」。
    ///
    /// 行 id 是每次解析 diff 时重新编号的，所以 diff 一重载就必须清空 ——
    /// 留着旧 id 会让勾选落到完全不相干的行上，那是会丢代码的。
    var selectedLines: Set<Int> = []

    /// 提交信息输入框的内容。存在模型里而不是视图里，这样切走再切回来草稿不丢 ——
    /// 写了半屏的提交信息因为点了下别的工作树就没了，是最让人火大的那种 bug。
    var commitMessage = ""
    var amendLastCommit = false

    /// 选中的提交（历史 tab 里点开看 diff 用）。
    var selectedCommit: String? {
        didSet {
            guard selectedCommit != oldValue else { return }
            commitDiff = nil
            guard let selectedCommit else { return }
            Task { await loadCommitDiff(selectedCommit) }
        }
    }
    private(set) var commitDiff: [FileDiff]?

    nonisolated var id: URL { identity }
    var path: URL { worktree.path }
    var repositoryRoot: URL { repository?.root ?? worktree.path }

    init(worktree: Worktree, repository: RepositoryModel?, git: GitClient, app: AppModel?) {
        self.identity = worktree.path
        self.worktree = worktree
        self.repository = repository
        self.git = git
        self.app = app
    }

    // MARK: - 刷新

    /// 只刷状态。侧边栏要给**每个**工作树显示改动数和领先/落后角标，
    /// 而完整的 `refresh()` 还要拉历史、查 PR —— 一个仓库挂十几个工作树的话
    /// 那就是几十次 git 调用外加十几次网络请求。
    func refreshStatus() async {
        do {
            status = try await git.status(in: path)
        } catch {
            // 侧边栏的角标读不出来不值得打断用户 —— 大概率是这个工作树的目录
            // 被手工删了，它本来就会被标成「可清理」。
            status = .empty
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        await refreshStatus()

        await reloadHistory()

        if knownAuthors.isEmpty {
            knownAuthors = await git.authors(in: path)
        }

        // 选中的文件可能已经不在变更列表里了（被暂存/丢弃/提交掉）。
        // 不清掉的话 diff 面板会一直显示一份过时内容。
        if let selectedPath, !status.changes.contains(where: { $0.path == selectedPath }) {
            self.selectedPath = status.changes.first?.path
        } else if selectedPath == nil {
            selectedPath = status.changes.first?.path
        } else {
            // 文件还在，但内容可能变了，重新取一次 diff。
            diffTask?.cancel()
            diffTask = Task { await loadDiff() }
        }

        await refreshLinkedPullRequest()
    }

    /// 按当前筛选条件重新拉历史。
    func reloadHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            commits = try await git.log(in: path, query: logQuery)
        } catch {
            // 筛选条件本身不会让 git 报错（空结果就是空结果），
            // 走到这儿基本是仓库还没有任何提交。
            commits = []
        }
        // 筛完之后原来选中的提交可能已经不在列表里了。
        if let selectedCommit, !commits.contains(where: { $0.oid == selectedCommit }) {
            self.selectedCommit = nil
        }
    }

    /// 勾选 / 取消勾选一个提交人。
    func toggleAuthor(_ author: CommitAuthor) async {
        let token = author.filterToken
        if let index = logQuery.authors.firstIndex(of: token) {
            logQuery.authors.remove(at: index)
        } else {
            logQuery.authors.append(token)
        }
        await reloadHistory()
    }

    func isAuthorSelected(_ author: CommitAuthor) -> Bool {
        logQuery.authors.contains(author.filterToken)
    }

    func clearAuthors() async {
        logQuery.authors.removeAll()
        await reloadHistory()
    }

    /// 筛选栏上「提交人」按钮的文字。
    var authorFilterLabel: String {
        switch logQuery.authors.count {
        case 0: "提交人"
        case 1:
            // 显示姓名而不是存进去的邮箱 —— 邮箱又长又不好认。
            knownAuthors.first { $0.filterToken == logQuery.authors[0] }?.name
                ?? logQuery.authors[0]
        default: "提交人（\(logQuery.authors.count)）"
        }
    }

    func clearLogQuery() async {
        logQuery = LogQuery()
        await reloadHistory()
    }

    func refreshLinkedPullRequest() async {
        guard let forge = repository?.forge, let branch = worktree.branch, repository?.slug != nil else {
            linkedPullRequest = nil
            return
        }

        // 先用仓库已经拉到的列表填上（瞬时、无网络），界面不会先空一下再跳出来。
        // 那份列表只有开放的 PR，所以紧接着再按完整规则查一次确认。
        linkedPullRequest = repository?.pullRequest(forBranch: branch)

        linkedPullRequest = await forge.linkedPullRequest(
            branch: branch,
            defaultBranch: repository?.defaultBranch,
            in: path
        )
    }

    private func loadDiff() async {
        selectedLines.removeAll()
        guard let selectedPath else {
            diff = nil
            return
        }
        guard let change = status.changes.first(where: { $0.path == selectedPath }) else {
            diff = nil
            return
        }

        // 未跟踪文件 git 不认，得自己造 diff。
        if change.unstaged == .untracked {
            let synthetic = await git.untrackedFileDiff(in: path, path: selectedPath)
            guard !Task.isCancelled else { return }
            diff = synthetic.map { [$0] } ?? []
            return
        }

        do {
            // 重命名要把来源路径也传给 git，否则 `git diff -- <新路径>` 拿不到内容。
            var paths = [selectedPath]
            if let originalPath = change.originalPath { paths.append(originalPath) }
            let result = try await git.diff(in: path, paths: paths, staged: diffSide == .staged)
            guard !Task.isCancelled else { return }
            diff = result
        } catch {
            guard !Task.isCancelled else { return }
            diff = []
            app?.report(title: "读取 diff 失败", error: error)
        }
    }

    private func loadCommitDiff(_ oid: String) async {
        do {
            let result = try await git.commitDiff(in: path, oid: oid)
            guard !Task.isCancelled else { return }
            commitDiff = result
        } catch {
            commitDiff = []
        }
    }

    /// 选中的文件在当前 diffSide 下是否可能没有内容 —— 用来在界面上给出解释，
    /// 而不是显示一片空白让人以为坏了。
    var selectedChange: FileChange? {
        guard let selectedPath else { return nil }
        return status.changes.first { $0.path == selectedPath }
    }

    // MARK: - 暂存

    func stage(_ change: FileChange) async {
        await mutate("暂存 \(change.displayName)") {
            try await self.git.stage(paths: [change.path], in: self.path)
        }
    }

    func stageAll() async {
        await mutate("全部暂存") {
            try await self.git.stageAll(in: self.path)
        }
    }

    func unstage(_ change: FileChange) async {
        await mutate("取消暂存 \(change.displayName)") {
            try await self.git.unstage(paths: [change.path], in: self.path)
        }
    }

    func unstageAll() async {
        let staged = status.changes.filter(\.isStaged).map(\.path)
        guard !staged.isEmpty else { return }
        await mutate("全部取消暂存") {
            try await self.git.unstage(paths: staged, in: self.path)
        }
    }

    func discard(_ change: FileChange) async {
        await mutate("丢弃 \(change.displayName) 的改动") {
            if change.unstaged == .untracked {
                try await self.git.discard(paths: [], untracked: [change.path], in: self.path)
            } else {
                // 重命名的情况下来源路径也要恢复，不然旧文件不会回来。
                var paths = [change.path]
                if let originalPath = change.originalPath { paths.append(originalPath) }
                try await self.git.discard(paths: paths, untracked: [], in: self.path)
            }
        }
    }

    // MARK: - 分行暂存

    func toggleLine(_ line: DiffLine) {
        guard line.kind == .addition || line.kind == .deletion else { return }
        if selectedLines.contains(line.id) {
            selectedLines.remove(line.id)
        } else {
            selectedLines.insert(line.id)
        }
    }

    /// 整块勾上 / 取消。逐行点在大 hunk 上太累，而「这一块整个要」是最常见的意图。
    func toggleHunk(_ hunk: DiffHunk) {
        let changed = hunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id)
        guard !changed.isEmpty else { return }
        if changed.allSatisfy(selectedLines.contains) {
            selectedLines.subtract(changed)
        } else {
            selectedLines.formUnion(changed)
        }
    }

    func hunkSelectionState(_ hunk: DiffHunk) -> HunkSelection {
        let changed = hunk.lines.filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id)
        guard !changed.isEmpty else { return .none }
        let picked = changed.filter(selectedLines.contains).count
        if picked == 0 { return .none }
        return picked == changed.count ? .all : .partial
    }

    enum HunkSelection { case none, partial, all }

    var selectedLineCount: Int { selectedLines.count }

    /// 选中的行能不能做分行操作。二进制文件和未跟踪文件没有可裁的补丁。
    var canApplySelectedLines: Bool {
        guard !selectedLines.isEmpty, activity == nil else { return false }
        guard let diff, diff.contains(where: { !$0.isBinary && !$0.hunks.isEmpty }) else { return false }
        return selectedChange?.unstaged != .untracked
    }

    /// 把选中的行暂存 / 取消暂存。方向由当前看的是哪一侧决定：
    /// 看工作区就是「加进索引」，看暂存区就是「从索引撤掉」。
    func applySelectedLines() async {
        let staged = diffSide == .staged
        await applyPatch(
            direction: staged ? .reverse : .forward,
            cached: true,
            reverse: staged,
            label: staged ? "取消暂存选中行" : "暂存选中行"
        )
    }

    /// 丢弃工作区里选中的行。不可撤销，调用方必须先确认过。
    func discardSelectedLines() async {
        await applyPatch(direction: .reverse, cached: false, reverse: true, label: "丢弃选中行")
    }

    private func applyPatch(
        direction: PatchBuilder.Direction,
        cached: Bool,
        reverse: Bool,
        label: String
    ) async {
        guard let diff else { return }
        activity = "正在\(label)…"
        defer { activity = nil }

        do {
            for file in diff {
                guard let patch = PatchBuilder.patch(
                    for: file, selecting: selectedLines, direction: direction
                ) else { continue }
                try await git.applyPatch(patch, in: path, cached: cached, reverse: reverse)
            }
            selectedLines.removeAll()
        } catch {
            app?.report(title: "\(label)失败", error: error)
        }
        await refresh()
    }

    // MARK: - 变基

    /// 变基的默认目标：优先当前分支的上游，其次 `origin/<默认分支>`。
    /// 「把我的分支同步到主干最新」是绝大多数变基的实际意图。
    var suggestedRebaseTarget: String? {
        if let upstream = status.upstream { return upstream }
        guard let repository else { return nil }
        if let defaultBranch = repository.defaultBranch {
            let remote = repository.remotes.first { $0.name == "origin" } ?? repository.remotes.first
            if let remote { return "\(remote.name)/\(defaultBranch)" }
            return defaultBranch
        }
        return nil
    }

    /// 变基会重放多少个提交。nil 表示目标引用不存在或算不出来。
    func rebaseCommitCount(onto target: String) async -> Int? {
        guard await git.refExists(target, in: path) else { return nil }
        return await git.commitCount(from: target, in: path)
    }

    /// 开始变基。冲突导致中断**不算失败** —— 那是变基的正常分支，
    /// 界面会切到「变基进行中」的状态让用户解决。
    func rebase(onto target: String, autostash: Bool) async {
        activity = "正在变基到 \(target)…"
        defer { activity = nil }
        do {
            try await git.rebase(onto: target, autostash: autostash, in: path)
        } catch {
            await refresh()
            // 停在冲突上时 git 也是非零退出。这时候不该报「失败」——
            // 用户接下来要做的是解决冲突，而不是以为操作没生效。
            if status.operation == .rebase {
                app?.report(
                    title: "变基遇到冲突",
                    detail: "解决冲突后在上方点「继续变基」；不想继续就点「中止」，仓库会回到变基前的样子。"
                )
            } else {
                app?.report(title: "变基失败", error: error)
            }
            return
        }
        await refresh()
        await repository?.refresh()
    }

    func rebaseStep(_ step: GitClient.RebaseStep) async {
        let label: String
        switch step {
        case .cont: label = "继续变基"
        case .skip: label = "跳过这个提交"
        case .abort: label = "中止变基"
        }
        activity = "正在\(label)…"
        defer { activity = nil }
        do {
            try await git.rebaseStep(step, in: path)
        } catch {
            await refresh()
            // `--continue` 在还有未解决冲突时会拒绝，这是提醒不是故障。
            if status.operation == .rebase, step == .cont {
                app?.report(
                    title: "还有冲突没解决",
                    detail: "把冲突文件改好并暂存之后，再点「继续变基」。"
                )
            } else {
                app?.report(title: "\(label)失败", error: error)
            }
            return
        }
        await refresh()
        await repository?.refresh()
    }

    /// 正处在变基中途。界面据此显示「继续 / 跳过 / 中止」那一条。
    var isRebasing: Bool { status.operation == .rebase }

    // MARK: - 提交与同步

    var canCommit: Bool {
        guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard status.operation == nil || status.hasConflicts == false else { return false }
        // amend 不需要有暂存内容（可以只改提交信息）。
        return amendLastCommit || status.stagedCount > 0
    }

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        activity = "正在提交…"
        defer { activity = nil }
        do {
            try await git.commit(message: message, amend: amendLastCommit, in: path)
            // 只有提交真的成功了才清空草稿。失败还清了，用户就得重写一遍。
            commitMessage = ""
            amendLastCommit = false
        } catch {
            app?.report(title: "提交失败", error: error)
        }
        await refresh()
    }

    func pull() async {
        await mutate("拉取") {
            try await self.git.pull(in: self.path)
        }
    }

    /// 当前分支的上游在哪个远端。没设上游时为 nil。
    var upstreamRemoteName: String? {
        guard let upstream = status.upstream else { return nil }
        return RemoteListParser.remoteName(
            inUpstream: upstream,
            knownRemotes: repository?.remotes.map(\.name) ?? []
        )
    }

    /// 一键推送时默认推去哪：优先分支自己的上游，其次 origin，再退回第一个远端。
    var defaultPushRemote: NamedRemote? {
        let remotes = repository?.remotes ?? []
        if let name = upstreamRemoteName, let match = remotes.first(where: { $0.name == name }) {
            return match
        }
        return remotes.first { $0.name == "origin" } ?? remotes.first
    }

    /// 推送到指定远端。`remote` 为 nil 表示「按分支自己的上游推」，
    /// 也就是终端里裸 `git push` 的行为。
    func push(to remote: NamedRemote? = nil) async {
        let label = remote.map { "正在推送到 \($0.name)…" } ?? "正在推送…"
        activity = label
        defer { activity = nil }
        do {
            // 没有上游就顺手建立跟踪关系。不然第一次 push 会被 git 拒掉，
            // 并要求用户去终端里敲 --set-upstream。
            //
            // 但**已经有上游**时不动它：用户显式推到另一个远端（比如备份仓库）
            // 不代表他想把分支改跟踪到那边去，悄悄改掉会让之后的 pull 拉错地方。
            let needsUpstream = status.upstream == nil
            try await git.push(
                in: path,
                remote: remote?.name,
                branch: worktree.branch,
                setUpstream: needsUpstream
            )
        } catch {
            app?.report(title: "推送失败", error: error)
        }
        await refresh()
        await repository?.refreshPullRequests()
    }

    private func mutate(_ label: String, _ work: @escaping () async throws -> Void) async {
        activity = "正在\(label)…"
        defer { activity = nil }
        do {
            try await work()
        } catch {
            app?.report(title: "\(label)失败", error: error)
        }
        await refresh()
    }

    // MARK: - PR

    /// 头部那个评审按钮此刻该是什么。
    ///
    /// 刻意不返回一个光秃秃的 Bool：条件不满足时**按钮不能直接消失**。
    /// 一个说没就没的按钮会让人以为功能坏了或者自己点错了地方，
    /// 而真正的原因（在默认分支上 / 远端没登录 / 已经有 PR 了）界面上一个字都没提。
    /// 所以这里连原因一起给出来，视图把按钮留在原位、禁用掉、把原因放进提示。
    var pullRequestAction: PullRequestAction {
        if let linkedPullRequest { return .view(linkedPullRequest) }

        guard let repository else { return .unavailable("仓库信息还没加载完。") }
        let term = repository.reviewTerm

        if let reason = repository.pullRequestUnavailableReason {
            return .unavailable(reason)
        }
        guard let branch = worktree.branch, !worktree.isDetached else {
            return .unavailable("当前是游离 HEAD，没有分支可以提\(term)。先切到一个分支。")
        }
        if branch == repository.defaultBranch {
            return .unavailable(
                "当前在默认分支 \(branch) 上。\(term)要从另一个分支提出 —— "
                + "用工具栏的「新建工作树」开一个功能分支。"
            )
        }
        return .create(term: term)
    }

    enum PullRequestAction {
        case view(PullRequest)
        case create(term: String)
        case unavailable(String)
    }

    /// 提 PR 之前必须先把分支推上去。这个方法把「推送 + 创建」串成一步，
    /// 因为分开做的话用户十次里有九次会忘记先推。
    func createPullRequest(title: String, body: String, base: String, isDraft: Bool) async -> String? {
        guard let forge = repository?.forge, let branch = worktree.branch else { return nil }

        activity = "正在推送分支…"
        defer { activity = nil }

        do {
            if status.upstream == nil {
                // 提 PR 必须推到 origin —— 托管商就是按 origin 认的。
                try await git.push(in: path, remote: "origin", branch: branch, setUpstream: true)
            } else if status.ahead > 0 {
                try await git.push(in: path, remote: nil, branch: branch, setUpstream: false)
            }
        } catch {
            app?.report(title: "推送分支失败", error: error)
            return nil
        }

        activity = "正在创建 PR…"
        do {
            let url = try await forge.createPullRequest(
                NewPullRequest(
                    title: title, body: body, base: base, head: branch, isDraft: isDraft
                ),
                in: path
            )
            await refresh()
            await repository?.refreshPullRequests()
            return url
        } catch {
            app?.report(title: "创建 PR 失败", error: error)
            return nil
        }
    }

    /// 提 PR 时的默认标题：优先用最新提交的标题，那几乎总是用户想要的。
    var suggestedPullRequestTitle: String {
        if let subject = commitsAheadOfBase.first?.subject, !subject.isEmpty { return subject }
        return worktree.branch ?? ""
    }

    /// 提 PR 时的默认正文：多个提交时把标题列成清单，单个提交就留空
    /// （标题已经说完了，正文再重复一遍是噪音）。
    var suggestedPullRequestBody: String {
        let ahead = commitsAheadOfBase
        guard ahead.count > 1 else { return "" }
        return ahead.map { "- \($0.subject)" }.joined(separator: "\n")
    }

    /// 相对上游领先的那些提交。没有上游时退回最近的提交列表。
    private var commitsAheadOfBase: [CommitSummary] {
        guard status.ahead > 0 else { return Array(commits.prefix(1)) }
        return Array(commits.prefix(status.ahead))
    }
}
