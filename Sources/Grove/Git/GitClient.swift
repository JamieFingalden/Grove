import Foundation

/// 对 `git` 命令行的封装。所有跟仓库的交互都从这里走。
///
/// 为什么是命令行而不是 libgit2：工作树（worktree）是 Grove 的主线功能，而 libgit2
/// 对它的支持一直不完整（`git worktree add` 的一堆语义要自己重实现）。命令行版本
/// 由 git 官方维护、跟用户终端里的行为完全一致，porcelain 输出格式也有向后兼容承诺。
/// 代价是每次调用都要 fork 一个进程，但这个开销（几毫秒）在 GUI 的刷新频率下无所谓。
///
/// 执行通道是可插拔的（`CommandTransport`）：本地走子进程，远程服务器走 ssh。
/// 远端的 git 输出格式与本地一致，所以这个类型里的解析逻辑对两种通道通用。
struct GitClient: Sendable {
    let transport: any CommandTransport

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

    init(transport: any CommandTransport) {
        self.transport = transport
    }

    /// 本地执行的旧入口，保留成员式初始化的形状（测试和既有调用方在用）。
    init(executable: URL, environment: [String: String]) {
        self.init(transport: LocalTransport(executable: executable, environment: environment))
    }

    static func resolve() async throws -> GitClient {
        guard let executable = await ToolLocator.shared.locate("git") else {
            throw GroveError.gitNotFound
        }
        return GitClient(
            executable: executable,
            environment: await ToolLocator.shared.childEnvironment()
        )
    }

    /// 绑定到一台远程服务器的客户端。git 命令在服务器上执行，
    /// 传入的目录路径按远端绝对路径解释。
    static func remote(_ server: RemoteServer, sshExecutable: URL) -> GitClient {
        GitClient(transport: SSHTransport(sshExecutable: sshExecutable, server: server))
    }

    // MARK: - 底层调用

    @discardableResult
    func run(
        _ arguments: [String],
        in directory: URL,
        timeout: Double = ProcessRunner.localTimeout
    ) async throws -> String {
        let result = try await runRaw(arguments, in: directory, timeout: timeout)
        try ensureSuccess(result, arguments: arguments)
        return result.stdout
    }

    func runRaw(
        _ arguments: [String],
        in directory: URL,
        timeout: Double = ProcessRunner.localTimeout
    ) async throws -> CommandResult {
        try await transport.runGit(
            Self.globalArguments + arguments,
            worktreePath: directory.path,
            timeout: timeout,
            standardInput: nil
        )
    }

    /// 与 `ProcessRunner.runChecked` 同一套错误语义：非零退出抛
    /// `CommandFailure`，报错优先 stderr，stderr 空时退回 stdout。
    private func ensureSuccess(_ result: CommandResult, arguments: [String]) throws {
        guard !result.isSuccess else { return }
        let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = result.trimmedStdout
        throw CommandFailure(
            executable: transport.label,
            arguments: arguments,
            exitCode: result.exitCode,
            output: message.isEmpty ? fallback : message
        )
    }

    /// 跑一条允许失败的命令，只关心「成功了没」。用于探测性查询。
    func succeeds(_ arguments: [String], in directory: URL) async -> Bool {
        let result = try? await runRaw(arguments, in: directory)
        return result?.isSuccess ?? false
    }

    // MARK: - 文件原语（转发到传输层）

    /// diff 面板编辑、冲突重写这些「git 之外」的文件操作用。
    /// 本地走 FileManager，远程走同一条 ssh 连接。
    func fileExists(atPath path: String) async -> Bool {
        await transport.fileExists(atPath: path)
    }

    func directoryExists(atPath path: String) async -> Bool {
        await transport.directoryExists(atPath: path)
    }

    func readData(atPath path: String) async -> Data? {
        await transport.readData(atPath: path)
    }

    func writeData(_ data: Data, toPath path: String, atomic: Bool) async throws {
        try await transport.writeData(data, toPath: path, atomic: atomic)
    }

    func modificationDate(atPath path: String) async -> Date? {
        await transport.modificationDate(atPath: path)
    }

    func createDirectory(atPath path: String) async throws {
        try await transport.createDirectory(atPath: path)
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
        let arguments = Self.globalArguments + [
            // `--untracked-files=all` 让 git 列出未跟踪**目录里的每个文件**。
            // 默认的 `normal` 会把整个未跟踪目录折叠成一行（`try/`），
            // 那种条目既没法单独暂存，点开也没有 diff 可看 —— 界面上就是一片空白。
            // 代价是没被 gitignore 挡住的巨型目录（node_modules 之类）会拖慢这条命令，
            // 但那种情况本来就该往 .gitignore 里加一行。
            "status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"
        ]
        let result = try await transport.runGit(
            arguments,
            worktreePath: directory.path,
            timeout: ProcessRunner.localTimeout,
            standardInput: nil
        )
        try ensureSuccess(result, arguments: arguments)
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
        query: LogQuery? = nil,
        remotes: [String] = []
    ) async throws -> [CommitSummary] {
        var arguments = ["log", "--format=\(LogParser.format)"]
        arguments.append("--max-count=\(query?.limit ?? limit)")
        // 拓扑序：把同一条分支的提交聚在一起。默认的时间序会把不同分支的
        // 提交按时间穿插，画出来的道反复横跳，图根本读不懂。
        // git 自己的 `--graph` 也是默认开启它的。
        arguments.append("--topo-order")

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
        return LogParser.parse(result.stdout, remotes: remotes)
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
        var arguments = ["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--find-renames"]
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
        // 存在性检查走传输层：远程仓库的未跟踪文件同样要能预览。
        let exists = await fileExists(atPath: fileURL.path)
        guard exists else { return nil }
        if await directoryExists(atPath: fileURL.path) {
            return FileDiff(oldPath: nil, newPath: path, hunks: [], isBinary: true,
                            isNewFile: true, isDeletedFile: false, isRename: false,
                            isModeChangeOnly: false, oldMode: nil, newMode: nil)
        }

        guard let data = await readData(atPath: fileURL.path) else { return nil }

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

    // MARK: - AI 提交信息上下文

    /// 这里只读取索引，不能退回普通 `git diff`：未暂存内容不在用户授权的发送边界内。
    func stagedDiffText(in directory: URL) async throws -> String {
        try await run(["diff", "--cached", "--no-color", "--no-ext-diff", "--find-renames"], in: directory)
    }

    func stagedDiffStat(in directory: URL) async throws -> String {
        try await run(["diff", "--cached", "--stat", "--no-color", "--no-ext-diff", "--find-renames"], in: directory)
    }

    /// 只拿标题；合并提交由提示词构造器再统一过滤，避免其他调用点忘记这条风格规则。
    func recentCommitSubjects(in directory: URL, limit: Int) async throws -> [String] {
        let result = try await runRaw(
            ["log", "--max-count=\(limit)", "--format=%s", "--no-merges"],
            in: directory
        )
        guard result.isSuccess else { return [] }
        return result.stdout
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
    }

    /// PR 目标写的是短分支名。只在本地分支和 origin 跟踪分支里解析，避免把用户输入
    /// 当成任意 revision 表达式，也不会因为工作区里还有改动就把它们带进 PR 上下文。
    func resolveBaseCommit(_ branch: String, in directory: URL) async -> String? {
        let name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let candidates = ["refs/heads/\(name)", "refs/remotes/origin/\(name)"]
        for candidate in candidates {
            guard let result = try? await runRaw(
                ["rev-parse", "--verify", "--end-of-options", "\(candidate)^{commit}"],
                in: directory
            ), result.isSuccess else { continue }
            let oid = result.trimmedStdout
            if !oid.isEmpty { return oid }
        }
        return nil
    }

    func committedDiff(from baseOID: String, in directory: URL) async throws -> String {
        try await run(
            ["diff", "--no-color", "--no-ext-diff", "--find-renames", "\(baseOID)...HEAD"],
            in: directory
        )
    }

    func committedDiffStat(from baseOID: String, in directory: URL) async throws -> String {
        try await run(
            ["diff", "--stat", "--no-color", "--no-ext-diff", "--find-renames", "\(baseOID)...HEAD"],
            in: directory
        )
    }

    func commitSubjects(from baseOID: String, in directory: URL) async throws -> [String] {
        let output = try await run(
            ["log", "--max-count=50", "--format=%s", "--no-merges", "\(baseOID)..HEAD"],
            in: directory
        )
        return output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// 检查工作树是不是正处在某个多步操作中间。
    ///
    /// 靠 git 目录里的哨兵文件判断 —— 这是 git 自己在 shell 提示符脚本里用的办法，
    /// 没有别的命令能直接问出来。注意工作树的 git 目录是 `<repo>/.git/worktrees/<name>`，
    /// 不是主仓库的 `.git`，所以必须现问一次。存在性检查走传输层，
    /// 远程工作树同样能识别出「变基中 / 合并中」。
    func currentOperation(in directory: URL) async -> RepositoryOperation? {
        guard let gitDir = await gitDirectory(in: directory) else { return nil }

        func exists(_ name: String) async -> Bool {
            await fileExists(atPath: gitDir.appendingPathComponent(name).path)
        }

        // 顺序有讲究：rebase 期间也可能存在 MERGE_HEAD（交互式 rebase 里的合并冲突），
        // 这时候该报「变基中」而不是「合并中」，否则用户会去点 `git merge --abort`，
        // 那条命令在 rebase 中间是无效的。
        let hasRebaseMerge = await exists("rebase-merge")
        let hasRebaseApply = await exists("rebase-apply")
        if hasRebaseMerge || hasRebaseApply { return .rebase }
        if await exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if await exists("REVERT_HEAD") { return .revert }
        if await exists("MERGE_HEAD") { return .merge }
        if await exists("BISECT_LOG") { return .bisect }
        return nil
    }

    /// 这个工作树自己的 git 目录。主工作树是 `<repo>/.git`，
    /// 其他工作树是 `<repo>/.git/worktrees/<name>` —— 操作状态文件都在这里。
    func gitDirectory(in directory: URL) async -> URL? {
        guard let path = try? await run(
            ["rev-parse", "--path-format=absolute", "--git-dir"], in: directory
        ).trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
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
        // 状态列表里的路径是具体文件名，不能让通配符或 pathspec magic 匹配其他文件。
        try await run(["--literal-pathspecs", "add", "--"] + paths, in: directory)
    }

    func stageAll(in directory: URL) async throws {
        try await run(["add", "--all"], in: directory)
    }

    func unstage(paths: [String], in directory: URL) async throws {
        guard !paths.isEmpty else { return }
        // 不显式传 HEAD：首次提交前 reset 会以空树为基准，只清索引、保留工作区。
        try await run(["--literal-pathspecs", "reset", "--quiet", "--"] + paths, in: directory)
    }

    /// 丢弃工作区改动。未跟踪的文件要单独删，`restore` 管不着它们。
    func discard(paths: [String], untracked: [String], in directory: URL) async throws {
        if !paths.isEmpty {
            try await run(["--literal-pathspecs", "restore", "--worktree", "--"] + paths, in: directory)
        }
        if !untracked.isEmpty {
            // `-d` 连空目录一起清，`-f` 是 git 的强制确认。
            try await run(["--literal-pathspecs", "clean", "-fd", "--"] + untracked, in: directory)
        }
    }

    /// 把一个补丁应用到索引或工作区。分行暂存 / 取消暂存 / 丢弃都走这里。
    ///
    /// 补丁从 stdin 喂进去，不落临时文件 —— 少一处需要清理的东西，
    /// 也避免临时文件路径里有中文或空格时的各种转义问题。
    /// 远程通道下 stdin 由 ssh 原样转发，行为一致。
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

        let full = Self.globalArguments + arguments
        let result = try await transport.runGit(
            full,
            worktreePath: directory.path,
            timeout: ProcessRunner.localTimeout,
            standardInput: Data(patch.utf8)
        )
        try ensureSuccess(result, arguments: full)
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

    /// `remote` / `branch` 都为 nil 时是裸 `git pull`，按分支自己的上游拉。
    /// 指定远端时不依赖上游配置 —— 没推过途的分支也能从任意远端拉。
    /// 注意带上 branch：`git pull <remote>` 不带 refspec 时会拉远端的 HEAD，
    /// 通常不是想要的分支。
    func pull(in directory: URL, remote: String? = nil, branch: String? = nil) async throws {
        // `--rebase`：分叉时把本地提交重放到远端最新之上，绝不产生
        // "Merge branch 'main' of ..." 合并提交。冲突会停在变基中间，
        // 由界面的冲突面板接手，跟显式变基是同一条路。
        // `--autostash`：工作区有未提交改动时先自动存起来，变基完再恢复，
        // 不然裸 pull --rebase 会直接拒绝执行。
        var arguments = ["pull", "--rebase", "--autostash"]
        if let remote { arguments.append(remote) }
        if let branch { arguments.append(branch) }
        try await run(arguments, in: directory, timeout: ProcessRunner.networkTimeout)
    }

    /// 推送。
    ///
    /// `remote` 为 nil 时跑裸 `git push`，由分支自己配置的上游决定推去哪 ——
    /// 这跟用户在终端里敲 `git push` 的行为完全一致，不会有意外。
    /// 指定了 remote 就显式推到那个远端。
    @discardableResult
    func push(
        in directory: URL,
        remote: String?,
        branch: String?,
        setUpstream: Bool,
        forceWithLease: Bool = false
    ) async throws -> String {
        var arguments = Self.pushArguments(
            remote: remote,
            branch: branch,
            setUpstream: setUpstream,
            forceWithLease: forceWithLease
        )
        arguments.insert("--porcelain", at: 1)
        return try await run(
            arguments,
            in: directory,
            timeout: ProcessRunner.networkTimeout
        )
    }

    /// 推送后读取实际更新的跟踪引用，不能用推送前的 HEAD 快照代表结果。
    func pushedTrackingCommit(
        from output: String,
        for branch: String,
        remote: String?,
        in directory: URL
    ) async -> (branch: String, sha: String, target: String)? {
        let lines = output.components(separatedBy: .newlines)
        let targets = lines.filter { $0.hasPrefix("To ") }
        // 多推送地址或没有推当前分支时不猜测；porcelain 结果才是实际更新的引用。
        guard targets.count == 1 else { return nil }
        let refs = lines.compactMap { line -> String? in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 2, fields[0] != "!", fields[0] != "-" else { return nil }
            let pair = fields[1].components(separatedBy: ":")
            guard pair.count == 2, pair[0] == "refs/heads/\(branch)",
                  pair[1].hasPrefix("refs/heads/") else { return nil }
            return String(pair[1].dropFirst("refs/heads/".count))
        }
        guard refs.count == 1 else { return nil }
        let destination = refs[0]
        let resolvedRemote: String
        if let remote {
            resolvedRemote = remote
        } else {
            guard let name = try? await run(
                ["for-each-ref", "--format=%(push:remotename)", "refs/heads/\(branch)"], in: directory
            ).trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            resolvedRemote = name
        }
        // ponytail: 只监控标准 fetch 映射；自定义引用映射需解析 refspec 后再读对应跟踪引用。
        let prefix = "refs/remotes/\(resolvedRemote)/"
        guard let fetch = try? await run(["config", "--get-all", "remote.\(resolvedRemote).fetch"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              fetch == "+refs/heads/*:\(prefix)*" || fetch == "refs/heads/*:\(prefix)*",
              let sha = try? await run(["rev-parse", "--verify", "\(prefix)\(destination)^{commit}"], in: directory)
                .trimmingCharacters(in: .whitespacesAndNewlines), !sha.isEmpty else { return nil }
        return (destination, sha, String(targets[0].dropFirst(3)))
    }

    /// 在指定工作树里开始一次普通合并。服务端拒绝自动合并、需要本地
    /// 解决时用它。冲突时 git 以非零退出，`run` 会抛错 —— 调用方随后用
    /// `currentOperation` 确认是否进入「合并中」，是则走既有的继续/中止流程。
    func startMerge(message: String, of revision: String, in directory: URL) async throws {
        try await run(
            ["merge", "--no-edit", "--no-progress", "-m", message, revision],
            in: directory,
            timeout: ProcessRunner.networkTimeout
        )
    }

    static func pushArguments(
        remote: String?,
        branch: String?,
        setUpstream: Bool,
        forceWithLease: Bool
    ) -> [String] {
        var arguments = ["push"]
        if forceWithLease { arguments.append("--force-with-lease") }
        if setUpstream { arguments.append("--set-upstream") }
        if let remote {
            arguments.append(remote)
            // 显式指定远端时必须连分支一起给：只给远端的话，git 会按
            // `push.default` 配置决定推哪些分支，有些配置下会一次推一堆。
            if let branch { arguments.append(branch) }
        }
        return arguments
    }

    /// 上游是否正好指向本地 HEAD 改写前的位置。
    ///
    /// 普通 amend 后 `HEAD@{1}` 是远端已有的旧提交、`HEAD` 是新提交。
    /// 这个判断不依赖 reflog 的英文动作文本，并且比看到 non-fast-forward
    /// 就建议强推安全得多：远端单纯领先时不会命中。
    func upstreamMatchesPreviousHead(in directory: URL) async -> Bool {
        async let upstream = try? run(["rev-parse", "--verify", "@{upstream}"], in: directory)
        async let previousHead = try? run(["rev-parse", "--verify", "HEAD@{1}"], in: directory)
        let (upstreamOID, previousOID) = await (upstream, previousHead)
        guard let upstreamOID, let previousOID else { return false }
        return upstreamOID.trimmingCharacters(in: .whitespacesAndNewlines)
            == previousOID.trimmingCharacters(in: .whitespacesAndNewlines)
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

    enum OperationStep: String, Sendable {
        case cont = "--continue"
        case skip = "--skip"
        case abort = "--abort"
    }

    typealias RebaseStep = OperationStep

    /// 多步操作中途的出路：继续 / 跳过 / 中止。合并、变基、拣选、回退共用一套。
    /// 没有它们的话，一旦冲突用户就被卡在半截状态里，只能回终端 —— 那等于功能没做完。
    ///
    /// `--continue` 需要提交信息时会去起编辑器；环境里 `GIT_EDITOR=true` 让它直接接受默认信息。
    func operationStep(_ step: OperationStep, of operation: RepositoryOperation, in directory: URL) async throws {
        guard let command = operation.commandName else {
            throw GroveError.operationNotSteppable(operation)
        }
        try await run([command, step.rawValue], in: directory, timeout: ProcessRunner.networkTimeout)
    }

    func rebaseStep(_ step: RebaseStep, in directory: URL) async throws {
        try await operationStep(step, of: .rebase, in: directory)
    }

    /// 变基会重放多少个提交。变基前拿它给用户一个「将要发生什么」的预览。
    func commitCount(from base: String, to head: String = "HEAD", in directory: URL) async -> Int? {
        guard let output = try? await run(
            ["rev-list", "--count", "\(base)..\(head)"], in: directory
        ) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 变基预览：要重放几个提交、落后目标几个提交。
    ///
    /// `target..HEAD` 为 0 只说明「HEAD 没有 target 缺的提交」，此时分支可能在
    /// 目标**之下**（落后）—— 这恰恰是最该变基的场景：纯落后时变基就是一次
    /// 快进，同步主干且不改写任何历史。只看这一个数字会把「落后待快进」
    /// 误判成「已经最新」，还把按钮禁掉。
    struct RebasePreview: Sendable, Equatable {
        var commitsToReplay: Int
        /// HEAD 落后目标的提交数（`HEAD..target`）。
        var commitsBehind: Int

        var isUpToDate: Bool { commitsToReplay == 0 && commitsBehind == 0 }
        /// 没有本地提交、纯粹落后：变基是一次快进。
        var isFastForward: Bool { commitsToReplay == 0 && commitsBehind > 0 }
    }

    /// 目标引用不存在或算不出来时返回 nil。
    func rebasePreview(onto target: String, in directory: URL) async -> RebasePreview? {
        guard await refExists(target, in: directory) else { return nil }
        let (toReplay, behind) = await (
            commitCount(from: target, in: directory),
            commitCount(from: "HEAD", to: target, in: directory)
        )
        guard let toReplay, let behind else { return nil }
        return RebasePreview(commitsToReplay: toReplay, commitsBehind: behind)
    }

    /// 这个引用存不存在。变基目标可能是用户手敲的，先验一下比让 git 报错友好。
    func refExists(_ ref: String, in directory: URL) async -> Bool {
        await succeeds(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: directory)
    }

    // MARK: - 冲突

    enum ConflictSide: String, Sendable {
        /// 当前侧：HEAD，索引第 2 阶段。合并时是当前分支；**变基时是变基目标**，因为 HEAD 停在那儿。
        case ours
        /// 传入侧：索引第 3 阶段。合并时是被合入的分支；变基时是正在重放的提交。
        case theirs

        var checkoutFlag: String {
            switch self {
            case .ours: "--ours"
            case .theirs: "--theirs"
            }
        }

        var actionLabel: String {
            switch self {
            case .ours: "采用当前更改"
            case .theirs: "采用传入的更改"
            }
        }
    }

    /// 整个文件采用一侧。
    ///
    /// 那一侧有内容就检出再 add；那一侧是「删除」就 rm。两种都以「索引里不再有
    /// 未合并条目」结束，也就是 git 眼里的已解决。一侧不存在时 `checkout --ours`
    /// 会报 "does not have our version"，所以必须先看 `kind` 再决定走哪条。
    func resolveConflict(
        path: String,
        taking side: ConflictSide,
        kind: ConflictKind,
        in directory: URL
    ) async throws {
        let sideHasContent = side == .ours ? kind.oursExists : kind.theirsExists
        if sideHasContent {
            try await run(["--literal-pathspecs", "checkout", side.checkoutFlag, "--", path], in: directory)
            try await stage(paths: [path], in: directory)
        } else {
            try await run(["--literal-pathspecs", "rm", "--quiet", "--", path], in: directory)
        }
    }

    /// 把工作区里现在的内容当作解决结果。文件还在就 add，被用户删了就 rm。
    func markConflictResolved(path: String, in directory: URL) async throws {
        let url = directory.appendingPathComponent(path)
        // 存在性语义与本地版一致：不顺着符号链接走到目标（attributesOfItem），
        // 一个指向已删目标的链接会被判成「文件没了」然后被 rm 掉。
        if await fileExists(atPath: url.path) {
            try await stage(paths: [path], in: directory)
        } else {
            try await run(["--literal-pathspecs", "rm", "--quiet", "--", path], in: directory)
        }
    }

    /// 把文件恢复成 git 刚合并完、带冲突标记的样子。用户改乱了想重来时用。
    /// 只对索引里仍未合并的路径有效 —— 一旦 add 过，三个阶段就没了，重来只能中止整个操作。
    /// 注意重建出来的标记标签是固定的 `ours` / `theirs`，不再是分支名。
    func restoreConflictMarkers(path: String, in directory: URL) async throws {
        try await run(["--literal-pathspecs", "checkout", "--merge", "--", path], in: directory)
    }

    /// 冲突两侧各是谁。
    ///
    /// 每种操作把「传入侧」记在不同地方：合并是 `MERGE_HEAD`，变基是 `REBASE_HEAD`
    /// 加 `rebase-merge/` 目录里的 `head-name` / `onto`，拣选和回退各有自己的 `*_HEAD`。
    /// 这里把它们统一翻译成两句人话，供两个按钮旁边显示。
    func conflictContext(
        operation: RepositoryOperation?,
        branch: String?,
        in directory: URL
    ) async -> ConflictContext {
        let current = branch ?? "HEAD"

        switch operation {
        case .merge:
            var incoming = await refName(pointingAt: "MERGE_HEAD", in: directory)
            if incoming == nil { incoming = await commitSummary("MERGE_HEAD", in: directory) }
            return ConflictContext(
                operation: operation,
                oursLabel: "\(current)（当前分支）",
                theirsLabel: "\(incoming ?? "MERGE_HEAD")（正在合入）"
            )

        case .rebase:
            let gitDir = await gitDirectory(in: directory)
            // 状态文件在远端服务器上时也要读得到 —— 冲突上下文的说明
            // （「来自哪个分支」）不因通道而异。读失败按「不知道」处理。
            func stateFile(_ name: String) async -> String? {
                guard let gitDir else { return nil }
                for stateDirectory in ["rebase-merge", "rebase-apply"] {
                    let url = gitDir.appendingPathComponent(stateDirectory).appendingPathComponent(name)
                    if let data = await readData(atPath: url.path),
                       let text = String(data: data, encoding: .utf8) {
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return nil
            }
            let rebasedBranch = await stateFile("head-name").map { name in
                name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
            }
            let onto = await stateFile("onto")
            var ontoName = "变基目标"
            if let onto {
                ontoName = await refName(pointingAt: onto, in: directory) ?? String(onto.prefix(7))
            }
            var incoming = "正在重放的提交"
            if let summary = await commitSummary("REBASE_HEAD", in: directory) {
                incoming += " \(summary)"
            }
            if let rebasedBranch { incoming += "（来自 \(rebasedBranch)）" }
            return ConflictContext(
                operation: operation,
                oursLabel: "\(ontoName)（变基目标，HEAD 停在这里）",
                theirsLabel: incoming
            )

        case .cherryPick:
            let summary = await commitSummary("CHERRY_PICK_HEAD", in: directory) ?? ""
            return ConflictContext(
                operation: operation,
                oursLabel: "\(current)（当前分支）",
                theirsLabel: "拣选的提交 \(summary)".trimmingCharacters(in: .whitespaces)
            )

        case .revert:
            let summary = await commitSummary("REVERT_HEAD", in: directory) ?? ""
            return ConflictContext(
                operation: operation,
                oursLabel: "\(current)（当前分支）",
                theirsLabel: "回退 \(summary) 产生的改动".replacingOccurrences(of: "  ", with: " ")
            )

        case .bisect, nil:
            // 没有操作却有冲突：`git stash pop`、`git checkout -m`、`git apply -3` 之类。
            return ConflictContext(
                operation: operation,
                oursLabel: "\(current)（当前分支）",
                theirsLabel: "正在应用的改动（stash 或补丁）"
            )
        }
    }

    /// 指向某个提交的第一个分支名（本地优先，其次远端）。没有就 nil。
    func refName(pointingAt object: String, in directory: URL) async -> String? {
        guard let result = try? await runRaw(
            ["for-each-ref", "--points-at", object, "--format=%(refname:short)", "refs/heads", "refs/remotes"],
            in: directory
        ), result.isSuccess else { return nil }
        return result.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// `abc1234「提交标题」`。标题太长就截断 —— 这是放在按钮旁边的说明，不是提交详情。
    func commitSummary(_ ref: String, in directory: URL) async -> String? {
        guard let result = try? await runRaw(
            ["log", "-1", "--format=%h%x1f%s", ref], in: directory
        ), result.isSuccess else { return nil }
        let parts = result.trimmedStdout.components(separatedBy: "\u{1F}")
        guard let hash = parts.first, !hash.isEmpty else { return nil }
        var subject = parts.count > 1 ? parts[1] : ""
        if subject.count > 40 { subject = String(subject.prefix(40)) + "…" }
        return subject.isEmpty ? hash : "\(hash)「\(subject)」"
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

    // MARK: - 标签

    /// 标签名是否已被占用。建标签的弹窗在输入框旁边提示重名用 ——
    /// 让用户当场改名字，比提交时收到一句 "tag 'v1.0' already exists" 友好得多。
    func tagExists(_ name: String, in directory: URL) async -> Bool {
        await succeeds(["show-ref", "--verify", "--quiet", "refs/tags/\(name)"], in: directory)
    }

    /// 仓库里全部本地标签名。建标签弹窗用它推下一个版本号候选
    /// （见 `VersionTag`），只需要名字，不需要它们指向哪。
    func tags(in directory: URL) async -> [String] {
        guard let output = try? await run(["tag", "--list"], in: directory) else { return [] }
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 在某个提交上打标签。`message` 非空时建附注标签（annotated）—— 它是独立
    /// 对象，能带说明、能被签名，发布版本用的都该是它；空串建轻量标签，只是个指针。
    /// 附注标签的 message 不能为空（否则 git 会去起交互式编辑器），由调用方保证。
    func createTag(_ name: String, message: String, at revision: String, in directory: URL) async throws {
        var arguments = ["tag"]
        if !message.isEmpty { arguments.append(contentsOf: ["--annotate", "--message", message]) }
        // `--` 之后一律当名字 / 提交解释。git 本身也禁止 `-` 开头的 refname，
        // 双保险，怪名字只会得到一句「不是合法标签名」，不会被当成选项。
        arguments.append(contentsOf: ["--", name, revision])
        try await run(arguments, in: directory)
    }

    /// 推送单个标签。标签没有「上游」一说，推送必须显式给远端。
    /// 注意 `git push` 不支持 `--` 分隔符（会被当成 refspec），不能加。
    func pushTag(_ name: String, to remote: String, in directory: URL) async throws {
        try await run(["push", remote, name], in: directory, timeout: ProcessRunner.networkTimeout)
    }

    /// 删除本地标签。远端上的同名标签不受影响 —— 那需要显式的推送删除，
    /// 风险高一个量级，不放进右键菜单里。
    func deleteTag(_ name: String, in directory: URL) async throws {
        try await run(["tag", "--delete", "--", name], in: directory)
    }
}

/// Grove 自己抛出的错误，跟子进程失败区分开。
enum GroveError: LocalizedError, Sendable {
    case gitNotFound
    case sshNotFound
    case ghNotFound
    case ghNotAuthenticated
    case notARepository(URL)
    case noGitHubRemote
    case worktreePathExists(URL)
    case branchAlreadyCheckedOut(branch: String, worktree: URL)
    case operationNotSteppable(RepositoryOperation)
    /// GitHub Actions 没有单任务重试/取消的接口，只能整条 run 一起。
    case jobControlUnsupported
    /// GitHub 的手动触发要指定 workflow 文件，不支持按 ref 直接跑。
    case pipelineRunUnsupported
    /// 没有找到停在目标分支上的工作树。（本地合并 PR 用）
    case noWorktreeOnBranch(String)
    /// 目标工作树还有未提交的改动，直接合并可能把两摊事情搅在一起。
    case worktreeDirty(String)

    var errorDescription: String? {
        switch self {
        case .gitNotFound:
            "找不到 git。请先安装 Xcode 命令行工具：在终端里运行 xcode-select --install"
        case .sshNotFound:
            "找不到 ssh。远程服务器功能需要系统自带的 ssh（/usr/bin/ssh）。"
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
        case .jobControlUnsupported:
            "GitHub Actions 只能整条流水线重跑或取消，没有单任务粒度。用列表或详情顶部的流水线按钮。"
        case .pipelineRunUnsupported:
            "GitHub Actions 的手动触发要指定 workflow 文件（gh workflow run），这里暂不支持按分支直接跑。"
        case .noWorktreeOnBranch(let branch):
            "没有找到停在「\(branch)」分支上的工作树。请先检出或创建一个「\(branch)」的工作树，再在本地合并。"
        case .worktreeDirty(let name):
            "工作树「\(name)」还有未提交的改动。先提交或贮藏它们，再在本地合并。"
        case .operationNotSteppable(let operation):
            "\(operation.rawValue)的状态无法从 Grove 里继续或中止，请在终端处理。"
        }
    }
}
