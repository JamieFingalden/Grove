import Foundation

/// 对 `git` 命令行的封装。所有跟仓库的交互都从这里走。
///
/// 为什么是命令行而不是 libgit2：工作树（worktree）是 Grove 的主线功能，而 libgit2
/// 对它的支持一直不完整（`git worktree add` 的一堆语义要自己重实现）。命令行版本
/// 由 git 官方维护、跟用户终端里的行为完全一致，porcelain 输出格式也有向后兼容承诺。
/// 代价是每次调用都要 fork 一个进程，但这个开销（几毫秒）在 GUI 的刷新频率下无所谓。
struct GitClient: Sendable {
    let executable: URL
    let environment: [String: String]

    /// 每条命令都带上的全局参数。
    private static let globalArguments = [
        // 非 ASCII 路径不做八进制转义。不加这个，中文文件名在状态和 diff 里
        // 会变成 `\344\270\255\346\226\207` 这种没法看的东西。
        "-c", "core.quotePath=false",
        // 永不输出 ANSI 颜色码。用户如果在 ~/.gitconfig 里写了 color.ui=always，
        // 不覆盖的话所有解析器都会被转义序列打乱。
        "-c", "color.ui=false",
        // 只读查询不去抢索引锁。GUI 会周期性刷新状态，而用户很可能同时在终端里
        // 跑 git —— 不加这个两边会互相锁死，终端那侧莫名其妙报 "index.lock exists"。
        "--no-optional-locks",
        // 不让 git 顺手跑后台垃圾回收。那个 `git gc --auto` 会继承我们的 stdout
        // 管道并活上好几分钟，把一条本该瞬间返回的命令拖成几分钟（详见 ProcessRunner.drain）。
        // 仓库的 gc 交给用户自己在终端里做，GUI 不该偷偷占着仓库。
        "-c", "gc.auto=0"
    ]

    static func resolve() async throws -> GitClient {
        guard let executable = await ToolLocator.shared.locate("git") else {
            throw GroveError.gitNotFound
        }
        return GitClient(
            executable: executable,
            environment: await ToolLocator.shared.childEnvironment()
        )
    }

    // MARK: - 底层调用

    @discardableResult
    func run(
        _ arguments: [String],
        in directory: URL,
        timeout: Double = ProcessRunner.localTimeout
    ) async throws -> String {
        let result = try await ProcessRunner.runChecked(
            executable: executable,
            arguments: Self.globalArguments + arguments,
            workingDirectory: directory,
            environment: environment,
            timeout: timeout
        )
        return result.stdout
    }

    func runRaw(
        _ arguments: [String],
        in directory: URL,
        timeout: Double = ProcessRunner.localTimeout
    ) async throws -> CommandResult {
        try await ProcessRunner.run(
            executable: executable,
            arguments: Self.globalArguments + arguments,
            workingDirectory: directory,
            environment: environment,
            timeout: timeout
        )
    }

    /// 跑一条允许失败的命令，只关心「成功了没」。用于探测性查询。
    func succeeds(_ arguments: [String], in directory: URL) async -> Bool {
        let result = try? await runRaw(arguments, in: directory)
        return result?.isSuccess ?? false
    }

    // MARK: - 仓库识别

    /// 找到某个路径所属仓库的主工作树根目录。不是仓库则返回 nil。
    func repositoryRoot(for directory: URL) async -> URL? {
        // `--show-toplevel` 给的是**当前工作树**的根；要拿仓库本体得走 common-dir。
        guard let commonDir = try? await run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory
        ).trimmingCharacters(in: .whitespacesAndNewlines), !commonDir.isEmpty else {
            return nil
        }

        let common = URL(fileURLWithPath: commonDir).groveResolved
        // 普通仓库的 common dir 是 `<root>/.git`，裸仓库就是仓库目录本身。
        if common.lastPathComponent == ".git" {
            return common.deletingLastPathComponent()
        }
        return common
    }

    /// 仓库的唯一标识：共享的 `.git` 目录路径。同一仓库的所有工作树都指向它，
    /// 所以可以用来判断「这两个目录是不是同一个仓库」。
    func commonDirectory(for directory: URL) async -> URL? {
        guard let path = try? await run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory
        ).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).groveResolved
    }

    // MARK: - 查询

    func worktrees(in directory: URL) async throws -> [Worktree] {
        let output = try await run(["worktree", "list", "--porcelain"], in: directory)
        return WorktreeParser.parse(output)
    }

    func status(in directory: URL) async throws -> WorktreeStatus {
        let result = try await ProcessRunner.runChecked(
            executable: executable,
            // `--untracked-files=all` 让 git 列出未跟踪**目录里的每个文件**。
            // 默认的 `normal` 会把整个未跟踪目录折叠成一行（`try/`），
            // 那种条目既没法单独暂存，点开也没有 diff 可看 —— 界面上就是一片空白。
            // 代价是没被 gitignore 挡住的巨型目录（node_modules 之类）会拖慢这条命令，
            // 但那种情况本来就该往 .gitignore 里加一行。
            arguments: Self.globalArguments + ["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"],
            workingDirectory: directory,
            environment: environment
        )
        var status = StatusParser.parse(result.standardOutput)
        status.operation = await currentOperation(in: directory)
        return status
    }

    func branches(in directory: URL) async throws -> [Branch] {
        let output = try await run(
            ["for-each-ref", "--format=\(RefParser.branchFormat)", "refs/heads"],
            in: directory
        )
        let current = try? await run(["branch", "--show-current"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RefParser.parseBranches(output, currentBranch: current)
            .sorted { ($0.lastCommitDate ?? .distantPast) > ($1.lastCommitDate ?? .distantPast) }
    }

    func remoteBranches(in directory: URL) async throws -> [RemoteBranch] {
        let output = try await run(
            ["for-each-ref", "--format=\(RefParser.remoteBranchFormat)", "refs/remotes"],
            in: directory
        )
        return RefParser.parseRemoteBranches(output)
            .sorted { ($0.lastCommitDate ?? .distantPast) > ($1.lastCommitDate ?? .distantPast) }
    }

    func log(
        in directory: URL,
        limit: Int = 100,
        revision: String? = nil,
        query: LogQuery? = nil
    ) async throws -> [CommitSummary] {
        var arguments = ["log", "--format=\(LogParser.format)"]
        arguments.append("--max-count=\(query?.limit ?? limit)")

        if let query {
            // `--grep` / `--author` 默认按正则解释。用户在搜索框里敲 `foo(bar)`
            // 或者 `C++` 时，正则会把它们理解成完全不同的东西 ——
            // 要么报错，要么静默匹配到别的提交。强制当字面量。
            if !query.text.isEmpty || !query.authors.isEmpty {
                arguments.append("--fixed-strings")
                arguments.append("--regexp-ignore-case")
            }
            if !query.text.isEmpty { arguments.append("--grep=\(query.text)") }
            // 多个 `--author` 之间 git 按「或」处理，正好是多选想要的语义。
            for author in query.authors { arguments.append("--author=\(author)") }
            if query.allBranches { arguments.append("--all") }
        }

        if let revision { arguments.append(revision) }

        if let query, !query.path.isEmpty {
            // `--` 之后一律当路径，避免以 `-` 开头或者跟分支重名的路径被误解析。
            arguments.append("--")
            arguments.append(query.path)
        }
        let result = try await runRaw(arguments, in: directory)
        // 空仓库（还没有任何提交）跑 git log 会以非零状态退出。那不是错误，
        // 只是「还没有历史」，返回空数组比抛错更贴合用户预期。
        guard result.isSuccess else { return [] }
        return LogParser.parse(result.stdout)
    }

    /// 仓库里出现过的提交人，按出现频次排序。用来填筛选下拉框。
    ///
    /// 只扫最近若干条提交而不是整个历史：大仓库全量扫一遍要几秒，
    /// 而筛选框里真正会被选的几乎总是最近活跃的那几个人。
    func authors(in directory: URL, sampling limit: Int = 2000) async -> [CommitAuthor] {
        // `%aN` / `%aE` 会走 .mailmap —— 用户如果配了 mailmap 把多个身份
        // 归并成一个，这里就直接是归并后的结果，不用我们再猜。
        guard let output = try? await run(
            ["log", "--format=%aN\u{1F}%aE", "--max-count=\(limit)", "--all"], in: directory
        ) else { return [] }

        var counts: [CommitAuthor: Int] = [:]
        for line in output.components(separatedBy: "\n") {
            let fields = line.components(separatedBy: "\u{1F}")
            guard fields.count >= 2 else { continue }
            let name = fields[0].trimmingCharacters(in: .whitespaces)
            let email = fields[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty || !email.isEmpty else { continue }
            let key = CommitAuthor(name: name, email: email, count: 0)
            counts[key, default: 0] += 1
        }

        return counts
            .map { CommitAuthor(name: $0.key.name, email: $0.key.email, count: $0.value) }
            .sorted {
                $0.count != $1.count ? $0.count > $1.count
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// 工作区 diff（未暂存的改动）。传 `staged: true` 拿暂存区 diff。
    func diff(in directory: URL, paths: [String] = [], staged: Bool) async throws -> [FileDiff] {
        var arguments = ["diff", "--no-color", "--no-ext-diff", "--find-renames"]
        if staged { arguments.append("--cached") }
        if !paths.isEmpty {
            arguments.append("--")
            arguments.append(contentsOf: paths)
        }
        let output = try await run(arguments, in: directory)
        return DiffParser.parse(output)
    }

    /// 未跟踪文件没有 diff 可言（git 不认识它）。这里手工造一个「全是新增行」的
    /// FileDiff，让界面上未跟踪文件和已跟踪文件的预览体验一致。
    func untrackedFileDiff(in directory: URL, path: String) async -> FileDiff? {
        let fileURL = directory.appendingPathComponent(path)

        // 目录进不了 diff。正常情况下 `--untracked-files=all` 已经把未跟踪目录
        // 展开成具体文件了，走到这里的只剩子模块、符号链接这类特殊条目 ——
        // 给个二进制标记，界面会显示「无法按行比较」，总好过一片空白。
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            return FileDiff(oldPath: nil, newPath: path, hunks: [], isBinary: true,
                            isNewFile: true, isDeletedFile: false, isRename: false,
                            isModeChangeOnly: false, oldMode: nil, newMode: nil)
        }

        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        // 判定二进制：前 8000 字节里出现 NUL 就当二进制处理 —— 这也是 git 自己的启发式。
        let sample = data.prefix(8000)
        if sample.contains(0) {
            return FileDiff(oldPath: nil, newPath: path, hunks: [], isBinary: true,
                            isNewFile: true, isDeletedFile: false, isRename: false,
                            isModeChangeOnly: false, oldMode: nil, newMode: nil)
        }

        let content = CommandResult.decode(data)
        var lines = content.components(separatedBy: "\n")
        // 文件以换行结尾时会切出一个末尾空串，那不是真的一行。
        if lines.last == "" { lines.removeLast() }

        let diffLines = lines.enumerated().map { index, text in
            DiffLine(id: index + 1, kind: .addition, text: text, oldNumber: nil, newNumber: index + 1)
        }
        let hunk = DiffHunk(
            id: 1,
            header: "@@ -0,0 +1,\(diffLines.count) @@",
            oldStart: 0, oldCount: 0, newStart: 1, newCount: diffLines.count,
            lines: diffLines
        )
        return FileDiff(oldPath: nil, newPath: path, hunks: diffLines.isEmpty ? [] : [hunk],
                        isBinary: false, isNewFile: true, isDeletedFile: false, isRename: false,
                        isModeChangeOnly: false, oldMode: nil, newMode: nil)
    }

    func commitDiff(in directory: URL, oid: String) async throws -> [FileDiff] {
        // 合并提交用 `-m` 展开成「相对每个父提交」的 diff，不然 git 默认什么都不输出。
        let output = try await run(
            ["show", "--no-color", "--no-ext-diff", "--find-renames", "--format=", "-m", "--first-parent", oid],
            in: directory
        )
        return DiffParser.parse(output)
    }

    /// 检查工作树是不是正处在某个多步操作中间。
    ///
    /// 靠 git 目录里的哨兵文件判断 —— 这是 git 自己在 shell 提示符脚本里用的办法，
    /// 没有别的命令能直接问出来。注意工作树的 git 目录是 `<repo>/.git/worktrees/<name>`，
    /// 不是主仓库的 `.git`，所以必须现问一次。
    func currentOperation(in directory: URL) async -> RepositoryOperation? {
        guard let gitDirPath = try? await run(
            ["rev-parse", "--path-format=absolute", "--git-dir"], in: directory
        ).trimmingCharacters(in: .whitespacesAndNewlines), !gitDirPath.isEmpty else {
            return nil
        }
        let gitDir = URL(fileURLWithPath: gitDirPath)
        let fileManager = FileManager.default

        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: gitDir.appendingPathComponent(name).path)
        }

        // 顺序有讲究：rebase 期间也可能存在 MERGE_HEAD（交互式 rebase 里的合并冲突），
        // 这时候该报「变基中」而不是「合并中」，否则用户会去点 `git merge --abort`，
        // 那条命令在 rebase 中间是无效的。
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        if exists("MERGE_HEAD") { return .merge }
        if exists("BISECT_LOG") { return .bisect }
        return nil
    }

    /// 仓库配置的所有远端。多远端的仓库推送时要让用户选推到哪个。
    func remotes(in directory: URL) async throws -> [NamedRemote] {
        let output = try await run(["remote", "-v"], in: directory)
        return RemoteListParser.parse(output)
    }

    /// 远端 `origin` 的 URL，用来判断这个仓库有没有 GitHub 远端。
    func remoteURL(in directory: URL, remote: String = "origin") async -> String? {
        let result = try? await runRaw(["remote", "get-url", remote], in: directory)
        guard let result, result.isSuccess else { return nil }
        let url = result.trimmedStdout
        return url.isEmpty ? nil : url
    }

    /// 远端的默认分支（`origin/HEAD` 指向谁）。新建分支时拿它当默认起点。
    func defaultBranch(in directory: URL) async -> String? {
        if let result = try? await runRaw(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: directory),
           result.isSuccess {
            let value = result.trimmedStdout
            if !value.isEmpty { return RefParser.stripRemotePrefix(value) }
        }
        // origin/HEAD 没设（克隆方式或 git 版本导致）时的兜底：挑一个常见名字。
        for candidate in ["main", "master", "develop"] {
            if await succeeds(["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], in: directory) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - 暂存与提交

    func stage(paths: [String], in directory: URL) async throws {
        guard !paths.isEmpty else { return }
        // `--` 之后的都当路径处理，避免以 `-` 开头的文件名被当成选项。
        try await run(["add", "--"] + paths, in: directory)
    }

    func stageAll(in directory: URL) async throws {
        try await run(["add", "--all"], in: directory)
    }

    func unstage(paths: [String], in directory: URL) async throws {
        guard !paths.isEmpty else { return }
        // 用 `restore --staged` 而不是 `reset HEAD`：空仓库（还没有 HEAD）时
        // reset 会失败，而 restore 能正确把首次 add 的文件退回未跟踪。
        try await run(["restore", "--staged", "--"] + paths, in: directory)
    }

    /// 丢弃工作区改动。未跟踪的文件要单独删，`restore` 管不着它们。
    func discard(paths: [String], untracked: [String], in directory: URL) async throws {
        if !paths.isEmpty {
            try await run(["restore", "--worktree", "--"] + paths, in: directory)
        }
        if !untracked.isEmpty {
            // `-d` 连空目录一起清，`-f` 是 git 的强制确认。
            try await run(["clean", "-fd", "--"] + untracked, in: directory)
        }
    }

    /// 把一个补丁应用到索引或工作区。分行暂存 / 取消暂存 / 丢弃都走这里。
    ///
    /// 补丁从 stdin 喂进去，不落临时文件 —— 少一处需要清理的东西，
    /// 也避免临时文件路径里有中文或空格时的各种转义问题。
    func applyPatch(
        _ patch: String,
        in directory: URL,
        cached: Bool,
        reverse: Bool
    ) async throws {
        var arguments = ["apply"]
        if cached { arguments.append("--cached") }
        if reverse { arguments.append("--reverse") }
        // 空白字符问题不该在这里报警：补丁是我们从 git 自己的 diff 里裁出来的，
        // 原样是什么就是什么，跑出一堆 warning 只会淹没真正的错误。
        arguments.append("--whitespace=nowarn")

        try await ProcessRunner.runChecked(
            executable: executable,
            arguments: Self.globalArguments + arguments,
            workingDirectory: directory,
            environment: environment,
            standardInput: Data(patch.utf8)
        )
    }

    func commit(message: String, amend: Bool = false, in directory: URL) async throws {
        var arguments = ["commit", "--message", message]
        if amend { arguments.append("--amend") }
        try await run(arguments, in: directory)
    }

    // MARK: - 同步
    //
    // 这一组都要走网络，超时给得比本地查询宽松得多：慢的远端、大的仓库，
    // 几十秒是正常的，按本地查询的 30 秒来卡会误伤。

    func fetch(in directory: URL, prune: Bool = true) async throws {
        var arguments = ["fetch", "--all"]
        // 顺手清掉远端已删除的分支引用。不清的话「上游已消失」永远检测不出来，
        // PR 合并后留下的本地分支就一直显示成正常状态。
        if prune { arguments.append("--prune") }
        try await run(arguments, in: directory, timeout: ProcessRunner.networkTimeout)
    }

    func pull(in directory: URL) async throws {
        // `--ff-only`：拉取绝不自动产生合并提交。真需要合并时让用户显式选，
        // 免得 GUI 悄悄造出一堆 "Merge branch 'main' of ..." 的垃圾提交。
        try await run(["pull", "--ff-only"], in: directory, timeout: ProcessRunner.networkTimeout)
    }

    /// 推送。
    ///
    /// `remote` 为 nil 时跑裸 `git push`，由分支自己配置的上游决定推去哪 ——
    /// 这跟用户在终端里敲 `git push` 的行为完全一致，不会有意外。
    /// 指定了 remote 就显式推到那个远端。
    func push(
        in directory: URL,
        remote: String?,
        branch: String?,
        setUpstream: Bool
    ) async throws {
        var arguments = ["push"]
        if setUpstream { arguments.append("--set-upstream") }
        if let remote {
            arguments.append(remote)
            // 显式指定远端时必须连分支一起给：只给远端的话，git 会按
            // `push.default` 配置决定推哪些分支，有些配置下会一次推一堆。
            if let branch { arguments.append(branch) }
        }
        try await run(arguments, in: directory, timeout: ProcessRunner.networkTimeout)
    }

    // MARK: - 变基

    /// 把当前分支重放到 `onto` 上。
    ///
    /// `--autostash` 会在开始前自动把未提交的改动 stash 起来、结束后再还原。
    /// 没有它的话，工作区一脏 git 就直接拒绝，用户得先手工 stash 一次 ——
    /// 而「我改了点东西，顺手同步一下主干」恰恰是最常见的变基场景。
    func rebase(onto: String, autostash: Bool, in directory: URL) async throws {
        var arguments = ["rebase"]
        if autostash { arguments.append("--autostash") }
        arguments.append(onto)
        // 变基要重放提交、可能跑 hook，比普通本地查询慢得多。
        try await run(arguments, in: directory, timeout: ProcessRunner.networkTimeout)
    }

    enum RebaseStep: String, Sendable {
        case cont = "--continue"
        case skip = "--skip"
        case abort = "--abort"
    }

    /// 变基中途的三种出路。没有它们的话，一旦冲突用户就被卡在半截状态里，
    /// 只能回终端 —— 那等于这个功能没做完。
    func rebaseStep(_ step: RebaseStep, in directory: URL) async throws {
        try await run(["rebase", step.rawValue], in: directory, timeout: ProcessRunner.networkTimeout)
    }

    /// 变基会重放多少个提交。变基前拿它给用户一个「将要发生什么」的预览。
    func commitCount(from base: String, to head: String = "HEAD", in directory: URL) async -> Int? {
        guard let output = try? await run(
            ["rev-list", "--count", "\(base)..\(head)"], in: directory
        ) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 这个引用存不存在。变基目标可能是用户手敲的，先验一下比让 git 报错友好。
    func refExists(_ ref: String, in directory: URL) async -> Bool {
        await succeeds(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: directory)
    }

    // MARK: - 工作树管理

    enum WorktreeSource: Sendable {
        /// 检出一个已存在的本地分支。
        case existingBranch(String)
        /// 新建分支，从 startPoint 开始（nil 表示当前 HEAD）。
        case newBranch(name: String, startPoint: String?)
        /// 游离 HEAD，直接指向某个提交 / 标签。
        case detached(String)
    }

    func addWorktree(at path: URL, source: WorktreeSource, in directory: URL) async throws {
        var arguments = ["worktree", "add"]
        switch source {
        case .existingBranch(let branch):
            arguments.append(contentsOf: [path.path, branch])
        case .newBranch(let name, let startPoint):
            arguments.append(contentsOf: ["-b", name, path.path])
            if let startPoint { arguments.append(startPoint) }
        case .detached(let commit):
            arguments.append(contentsOf: ["--detach", path.path, commit])
        }
        try await run(arguments, in: directory)
    }

    func removeWorktree(at path: URL, force: Bool, in directory: URL) async throws {
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path.path)
        try await run(arguments, in: directory)
    }

    func pruneWorktrees(in directory: URL) async throws {
        try await run(["worktree", "prune"], in: directory)
    }

    func lockWorktree(at path: URL, reason: String?, in directory: URL) async throws {
        var arguments = ["worktree", "lock"]
        if let reason, !reason.isEmpty { arguments.append(contentsOf: ["--reason", reason]) }
        arguments.append(path.path)
        try await run(arguments, in: directory)
    }

    func unlockWorktree(at path: URL, in directory: URL) async throws {
        try await run(["worktree", "unlock", path.path], in: directory)
    }

    func moveWorktree(from source: URL, to destination: URL, in directory: URL) async throws {
        try await run(["worktree", "move", source.path, destination.path], in: directory)
    }

    // MARK: - 分支

    func deleteBranch(_ name: String, force: Bool, in directory: URL) async throws {
        try await run(["branch", force ? "-D" : "-d", name], in: directory)
    }

    /// 把某个远端分支抓到本地并建立跟踪关系。给「从 PR 建工作树」用。
    func fetchRefspec(_ refspec: String, remote: String = "origin", in directory: URL) async throws {
        try await run(["fetch", remote, refspec], in: directory, timeout: ProcessRunner.networkTimeout)
    }

    func localBranchExists(_ name: String, in directory: URL) async -> Bool {
        await succeeds(["show-ref", "--verify", "--quiet", "refs/heads/\(name)"], in: directory)
    }
}

/// Grove 自己抛出的错误，跟子进程失败区分开。
enum GroveError: LocalizedError, Sendable {
    case gitNotFound
    case ghNotFound
    case ghNotAuthenticated
    case notARepository(URL)
    case noGitHubRemote
    case worktreePathExists(URL)
    case branchAlreadyCheckedOut(branch: String, worktree: URL)

    var errorDescription: String? {
        switch self {
        case .gitNotFound:
            "找不到 git。请先安装 Xcode 命令行工具：在终端里运行 xcode-select --install"
        case .ghNotFound:
            "找不到 GitHub CLI。PR 功能需要它：brew install gh"
        case .ghNotAuthenticated:
            "GitHub CLI 尚未登录。请在终端里运行 gh auth login"
        case .notARepository(let url):
            "\(url.lastPathComponent) 不是一个 git 仓库"
        case .noGitHubRemote:
            "这个仓库没有 GitHub 远端，无法使用 PR 功能"
        case .worktreePathExists(let url):
            "目录已存在：\(url.path)"
        case .branchAlreadyCheckedOut(let branch, let worktree):
            "分支 \(branch) 已经在工作树「\(worktree.lastPathComponent)」里检出了。git 不允许同一分支同时存在于两个工作树。"
        }
    }
}
