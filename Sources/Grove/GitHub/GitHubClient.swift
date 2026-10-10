import Foundation

/// 通过 GitHub CLI（`gh`）访问 PR。
///
/// 为什么用 `gh` 而不是直接调 GitHub REST/GraphQL API：认证。用 API 就得自己做
/// OAuth device flow、把 token 存进 Keychain、处理过期刷新、还要引导用户建 PAT。
/// 而 `gh` 已经把这些做完了，绝大多数会用 worktree 的人机器上本来就有它。
/// 于是 Grove 不碰任何凭据 —— 没有 token 落盘，也就没有泄露面。
///
/// 代价是多一个外部依赖。所以 `gh` 缺失或未登录时，PR 功能整块降级、
/// git 功能完全不受影响（见 `PullRequestStore` 里的 availability 处理）。
struct GitHubClient: ForgeClient {
    let executable: URL
    let environment: [String: String]
    private static let authProbeTimeout: Double = 8

    var kind: ForgeKind { .github }

    /// 列表视图要的字段。刻意不含 `body` —— PR 正文可能几十 KB，
    /// 列一屏 30 个 PR 就是几 MB 的无用传输，正文留到详情页再单独取。
    private static let listFields = [
        "number", "title", "state", "isDraft", "headRefName", "baseRefName",
        "url", "author", "createdAt", "updatedAt", "additions", "deletions", "changedFiles",
        "reviewDecision", "mergeable", "isCrossRepository", "labels",
        "statusCheckRollup", "headRepositoryOwner"
    ].joined(separator: ",")

    private static let detailFields = listFields + ",body"

    static func resolve() async -> GitHubClient? {
        guard let executable = await ToolLocator.shared.locate("gh") else { return nil }
        return GitHubClient(
            executable: executable,
            environment: await ToolLocator.shared.childEnvironment()
        )
    }

    // MARK: - 底层调用
    //
    // `gh` 的每条子命令都要打 GitHub 的接口，所以统一用网络级超时 ——
    // 按本地查询的 30 秒来卡，网络一慢就会误伤。

    private func gh(
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: Double = ProcessRunner.networkTimeout
    ) async throws -> CommandResult {
        try await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment,
            timeout: timeout
        )
    }

    @discardableResult
    private func ghChecked(_ arguments: [String], in directory: URL? = nil) async throws -> CommandResult {
        try await ProcessRunner.runChecked(
            executable: executable,
            arguments: arguments,
            workingDirectory: directory,
            environment: environment,
            timeout: ProcessRunner.networkTimeout
        )
    }

    // MARK: - 可用性

    /// `gh` 是否已登录。未登录时所有 PR 命令都会失败，提前问一次能给出准确的提示，
    /// 而不是让用户看到一句莫名其妙的 API 错误。
    func isAuthenticated() async -> Bool {
        let result = try? await gh(["auth", "status", "--active"], timeout: Self.authProbeTimeout)
        return result?.isSuccess ?? false
    }

    /// `gh` 配置过的主机列表。
    ///
    /// 用它来判断某个远端「是不是 GitHub」，而不是硬比 `github.com` ——
    /// 这样 GitHub Enterprise（公司自建的 GitHub）也能自动支持：
    /// 用户 `gh auth login --hostname ghe.corp.example` 之后它就出现在这个列表里。
    func configuredHosts() async -> Set<String> {
        guard let result = try? await gh(
            ["auth", "status", "--json", "hosts", "--jq", ".hosts | keys[]"],
            timeout: Self.authProbeTimeout
        ) else { return [] }
        return Set(result.stdout.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// 当前目录对应的 GitHub 仓库全名（`owner/repo`）。不是 GitHub 仓库时返回 nil。
    ///
    /// **调用前必须先确认这个仓库的 origin 确实指向 GitHub**（见 `GitRemote`）。
    /// `gh repo view` 会扫所有 remote 挑一个 GitHub 的，不管它是不是 `origin` ——
    /// 直接信它会把「origin 在内网 GitLab、另挂了个 GitHub 备份」的仓库
    /// 认成那个备份仓库。
    func repositorySlug(in directory: URL) async -> String? {
        let result = try? await gh(
            ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            in: directory
        )
        guard let result, result.isSuccess else { return nil }
        let slug = result.trimmedStdout
        return slug.isEmpty ? nil : slug
    }

    func createRepository(_ request: NewRemoteRepository, in directory: URL) async throws {
        var commandEnvironment = environment
        commandEnvironment["GH_HOST"] = request.host
        try await ProcessRunner.runChecked(
            executable: executable,
            arguments: Self.createRepositoryArguments(request),
            workingDirectory: directory,
            environment: commandEnvironment,
            timeout: ProcessRunner.networkTimeout
        )
    }

    static func createRepositoryArguments(_ request: NewRemoteRepository) -> [String] {
        var arguments = [
            "repo", "create", request.path,
            request.visibility.commandFlag,
            "--source", ".",
            "--remote", "origin"
        ]
        let description = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            arguments.append(contentsOf: ["--description", description])
        }
        return arguments
    }

    // MARK: - 查询

    func pullRequests(in directory: URL, limit: Int = 50, state: PullRequestListState = .open) async throws -> [PullRequest] {
        var arguments = ["pr", "list", "--limit", String(limit), "--json", Self.listFields]
        // 默认只看开放的。已合并 / 已关闭的 PR 数量能到几千，全拉一遍又慢又没用。
        arguments.append(contentsOf: ["--state", state.rawValue])

        let result = try await ghChecked(arguments, in: directory)
        return try Self.decoder.decode([PullRequest].self, from: result.standardOutput)
    }

    func pullRequest(number: Int, in directory: URL) async throws -> PullRequest {
        let result = try await ghChecked(
            ["pr", "view", String(number), "--json", Self.detailFields],
            in: directory
        )
        return try Self.decoder.decode(PullRequest.self, from: result.standardOutput)
    }

    func pullRequestDiff(number: Int, in directory: URL) async throws -> [FileDiff] {
        // 显式禁用颜色，否则用户全局配置了强制彩色时，ANSI 控制符会混进代码和路径。
        let result = try await ghChecked(
            ["pr", "diff", String(number), "--color", "never"],
            in: directory
        )
        return DiffParser.parse(result.stdout)
    }

    /// 某个分支对应的 PR。用来把工作树和 PR 关联起来 —— Grove 的核心视图。
    /// 该分支没有 PR 时返回 nil（不是错误）。
    ///
    /// 同一个分支可能有多个 PR（提了一个、关掉、又提一个），所以取一批再挑：
    /// 优先开放的，其次草稿，最后已合并 / 已关闭。只取第一条的话，
    /// 一个正在评审的 PR 可能被同分支上一个几个月前的废弃 PR 盖掉。
    func pullRequest(forBranch branch: String, in directory: URL) async throws -> PullRequest? {
        let result = try await gh(
            ["pr", "list", "--head", branch, "--state", "all",
             "--limit", "10", "--json", Self.detailFields],
            in: directory
        )
        guard result.isSuccess else { return nil }
        let list = try Self.decoder.decode([PullRequest].self, from: result.standardOutput)
        return Self.mostRelevant(of: list)
    }

    /// 某个工作树分支该关联哪个 PR/MR 的规则在 `ForgeClient` 的协议扩展里，
    /// GitHub 和 GitLab 共用同一套，保证界面和 `--doctor` 看到的一致。

    /// 从同一分支的多个 PR 里挑最该展示的那个。GitLab 那侧也用它。
    static func mostRelevant(of pullRequests: [PullRequest]) -> PullRequest? {
        func rank(_ pullRequest: PullRequest) -> Int {
            switch pullRequest.status {
            case .open: 0
            case .draft: 1
            case .merged: 2
            case .closed: 3
            }
        }
        return pullRequests.min {
            // 同一档里比更新时间，最近动过的更可能是用户关心的那个。
            rank($0) != rank($1) ? rank($0) < rank($1) : $0.updatedAt > $1.updatedAt
        }
    }

    // MARK: - 操作

    /// 创建 PR，返回它的网页地址。
    ///
    /// 调用之前分支必须已经推到远端 —— `gh pr create` 自己也能推，但那会走交互式
    /// 提问（"Where should we push?"），在 GUI 里没人能回答。所以推送这一步由
    /// 调用方先用 git 做掉。
    func createPullRequest(_ request: NewPullRequest, in directory: URL) async throws -> String {
        var arguments = [
            "pr", "create",
            "--title", request.title,
            "--body", request.body,
            "--base", request.base,
            "--head", request.head
        ]
        if request.isDraft { arguments.append("--draft") }

        let result = try await ghChecked(arguments, in: directory)
        // gh 把 PR 地址打在 stdout 最后一行。
        return result.trimmedStdout
            .components(separatedBy: "\n")
            .last(where: { $0.contains("://") }) ?? result.trimmedStdout
    }

    func merge(
        number: Int,
        strategy: MergeStrategy,
        deleteBranch: Bool,
        in directory: URL
    ) async throws {
        var arguments = ["pr", "merge", String(number), "--\(strategy.rawValue)"]
        if deleteBranch { arguments.append("--delete-branch") }
        try await ghChecked(arguments, in: directory)
    }

    func approve(number: Int, in directory: URL) async throws {
        try await ghChecked(["pr", "review", String(number), "--approve"], in: directory)
    }

    func requestChanges(number: Int, body: String, in directory: URL) async throws {
        // GitHub 要求「要求修改」必须带正文，空的会被接口拒绝。
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        try await ghChecked(
            ["pr", "review", String(number), "--request-changes",
             "--body", text.isEmpty ? "请看行内评论。" : text],
            in: directory
        )
    }

    /// 草稿转正式。
    func markReady(number: Int, in directory: URL) async throws {
        try await ghChecked(["pr", "ready", String(number)], in: directory)
    }

    // MARK: - CI/CD（走 gh；GitHub Actions 没有单任务粒度的接口）

    private struct RunListDTO: Decodable {
        let databaseId: Int
        let status: String
        let conclusion: String?
        let displayTitle: String?
        let event: String?
        let headBranch: String?
        let headSha: String?
        let createdAt: Date?
        let updatedAt: Date?
        let url: String?
        let workflowName: String?
    }

    private struct RunViewDTO: Decodable {
        struct JobDTO: Decodable {
            let databaseId: Int
            let name: String
            let status: String
            let conclusion: String?
            let startedAt: Date?
            let completedAt: Date?
            let url: String?
        }
        let jobs: [JobDTO]?
    }

    func pipelines(in directory: URL, limit: Int) async throws -> [CIPipeline] {
        let result = try await ghChecked([
            "run", "list", "--limit", String(limit),
            "--json",
            "databaseId,status,conclusion,displayTitle,event,headBranch,headSha,createdAt,updatedAt,url,workflowName"
        ], in: directory)
        let dtos = try Self.decoder.decode([RunListDTO].self, from: result.standardOutput)
        return dtos.map { dto in
            CIPipeline(
                id: dto.databaseId,
                status: CIStatus.github(status: dto.status, conclusion: dto.conclusion),
                ref: dto.headBranch ?? "",
                sha: dto.headSha ?? "",
                title: dto.displayTitle ?? dto.workflowName,
                trigger: dto.event,
                createdAt: dto.createdAt,
                duration: duration(from: dto.createdAt, to: dto.updatedAt),
                webURL: dto.url
            )
        }
    }

    func jobs(pipelineID: Int, in directory: URL) async throws -> [CIJob] {
        let result = try await ghChecked([
            "run", "view", String(pipelineID), "--json", "jobs"
        ], in: directory)
        let dto = try Self.decoder.decode(RunViewDTO.self, from: result.standardOutput)
        return (dto.jobs ?? []).map { job in
            CIJob(
                id: job.databaseId,
                name: job.name,
                stage: nil,
                status: CIStatus.github(status: job.status, conclusion: job.conclusion),
                duration: duration(from: job.startedAt, to: job.completedAt),
                queuedDuration: nil,
                allowFailure: false,
                webURL: job.url
            )
        }
    }

    func jobLog(jobID: Int, in directory: URL) async throws -> String {
        // 日志下载是重定向，gh api 会自己跟过去再吐正文。
        guard let slug = await repositorySlug(in: directory) else {
            throw GroveError.noGitHubRemote
        }
        let arguments = ["api", "repos/\(slug)/actions/jobs/\(jobID)/logs"]
        // 新版 gh 检测到正文含终端转义序列时拒绝输出，而 Actions 日志天然
        // 带 ANSI 颜色码 —— 必须放行；App 侧本来就会剥掉 ANSI（CILog.plain）。
        // 老版本 gh 不认识这个 flag（报 unknown flag），那时它也没有这个
        // 检查，退回裸命令即可。
        do {
            let result = try await ghChecked(arguments + ["--allow-escape-sequences"], in: directory)
            return String(data: result.standardOutput, encoding: .utf8) ?? ""
        } catch {
            let output = (error as? CommandFailure)?.output ?? ""
            guard output.contains("unknown flag") || output.contains("unknown shorthand flag") else { throw error }
            let result = try await ghChecked(arguments, in: directory)
            return String(data: result.standardOutput, encoding: .utf8) ?? ""
        }
    }

    func retryJob(jobID: Int, in directory: URL) async throws {
        throw GroveError.jobControlUnsupported
    }

    func cancelJob(jobID: Int, in directory: URL) async throws {
        throw GroveError.jobControlUnsupported
    }

    func runManualJob(jobID: Int, in directory: URL) async throws {
        throw GroveError.jobControlUnsupported
    }

    func retryPipeline(id: Int, in directory: URL) async throws {
        // --failed 只重跑失败的，对齐 GitLab 重试流水线的语义。
        _ = try await ghChecked(["run", "rerun", String(id), "--failed"], in: directory)
    }

    func cancelPipeline(id: Int, in directory: URL) async throws {
        _ = try await ghChecked(["run", "cancel", String(id)], in: directory)
    }

    func runPipeline(ref: String, in directory: URL) async throws {
        throw GroveError.pipelineRunUnsupported
    }

    private func duration(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end, end > start else { return nil }
        return end.timeIntervalSince(start)
    }

    func close(number: Int, in directory: URL) async throws {
        try await ghChecked(["pr", "close", String(number)], in: directory)
    }

    func comment(number: Int, body: String, in directory: URL) async throws {
        try await ghChecked(["pr", "comment", String(number), "--body", body], in: directory)
    }

    /// 评论线程：行内评审意见 + 整体讨论。
    ///
    /// 走两个 REST 接口而不是 `gh pr view --json comments`：后者只给整体评论，
    /// 拿不到带文件和行号的行内意见 —— 而 review 时最要紧的恰恰是那些。
    func reviewThreads(number: Int, in directory: URL) async throws -> [ReviewThread] {
        async let inline = fetchComments(
            "repos/{owner}/{repo}/pulls/\(number)/comments?per_page=100", in: directory
        )
        async let general = fetchComments(
            "repos/{owner}/{repo}/issues/\(number)/comments?per_page=100", in: directory
        )
        async let states = reviewThreadStates(number: number, in: directory)
        var threads = try await (inline + general)
        let metadata = try await states
        for index in threads.indices where threads[index].isInline {
            guard let root = threads[index].firstNote?.id, let state = metadata[root] else { continue }
            threads[index].id = state.id
            threads[index].isResolved = state.isResolved
            threads[index].isResolvable = true
            threads[index].canResolve = state.isResolved ? state.viewerCanUnresolve : state.viewerCanResolve
            threads[index].isOutdated = state.isOutdated
        }
        return threads.sorted { ($0.firstNote?.createdAt ?? .distantPast) < ($1.firstNote?.createdAt ?? .distantPast) }
    }

    private func fetchComments(_ path: String, in directory: URL) async throws -> [ReviewThread] {
        let result = try await ghChecked(["api", path, "--paginate", "--slurp"], in: directory)
        let pages = try Self.decoder.decode([[GitHubComment]].self, from: result.standardOutput)
        return Self.threads(from: pages.flatMap { $0 }, source: path)
    }

    private func reviewThreadStates(number: Int, in directory: URL) async throws -> [String: GitHubReviewThreadState] {
        guard let slug = await repositorySlug(in: directory) else { throw GroveError.noGitHubRemote }
        let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw GroveError.noGitHubRemote }
        let query = """
        query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewThreads(first: 100, after: $cursor) {
                nodes { id isResolved isOutdated viewerCanResolve viewerCanUnresolve comments(first: 1) { nodes { databaseId } } }
                pageInfo { hasNextPage endCursor }
              }
            }
          }
        }
        """
        var states: [String: GitHubReviewThreadState] = [:]
        var cursor: String?
        repeat {
            var args = ["api", "graphql", "-f", "query=\(query)", "-f", "owner=\(parts[0])",
                        "-f", "repo=\(parts[1])", "-F", "number=\(number)"]
            if let cursor { args.append(contentsOf: ["-f", "cursor=\(cursor)"]) }
            let result = try await ghChecked(args, in: directory)
            let response = try Self.decoder.decode(GitHubReviewThreadPage.self, from: result.standardOutput)
            guard response.errors?.isEmpty != false,
                  let page = response.data?.repository?.pullRequest?.reviewThreads else {
                throw ReviewDiscussionError.unavailable
            }
            for state in page.nodes {
                if let root = state.comments.nodes.first?.databaseId { states[String(root)] = state }
            }
            if page.pageInfo.hasNextPage {
                guard let next = page.pageInfo.endCursor, next != cursor else { throw ReviewDiscussionError.unavailable }
                cursor = next
            } else { cursor = nil }
        } while cursor != nil
        return states
    }

    func reviewHead(number: Int, in directory: URL) async throws -> String {
        let result = try await ghChecked(["pr", "view", String(number), "--json", "headRefOid", "--jq", ".headRefOid"], in: directory)
        guard !result.trimmedStdout.isEmpty else { throw ReviewDiscussionError.unavailable }
        return result.trimmedStdout
    }

    func createDiscussion(number: Int, body: String, location: ReviewLocation?, expectedHead: String, in directory: URL) async throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReviewDiscussionError.emptyBody }
        guard let location else {
            try await comment(number: number, body: body, in: directory)
            return
        }
        guard !expectedHead.isEmpty, try await reviewHead(number: number, in: directory) == expectedHead else {
            throw ReviewDiscussionError.changedHead
        }
        try await ghChecked([
            "api", "repos/{owner}/{repo}/pulls/\(number)/comments", "--method", "POST",
            "-f", "body=\(body)", "-f", "commit_id=\(expectedHead)", "-f", "path=\(location.newPath)",
            "-F", "line=\(location.line)", "-f", "side=\(location.isOldSide ? "LEFT" : "RIGHT")"
        ], in: directory)
    }

    func reply(number: Int, thread: ReviewThread, body: String, in directory: URL) async throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReviewDiscussionError.emptyBody }
        guard let root = thread.firstNote else { throw ReviewDiscussionError.unavailable }
        if thread.isInline {
            try await ghChecked(["api", "repos/{owner}/{repo}/pulls/\(number)/comments/\(root.id)/replies",
                                 "--method", "POST", "-f", "body=\(body)"], in: directory)
        } else {
            // GitHub 整体评论没有回复线程接口，用引用保留讨论关系。
            let quote = root.body.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
            let mention = root.authorLogin.isEmpty ? "" : "@\(root.authorLogin)\n\n"
            try await comment(number: number, body: "\(mention)\(quote)\n\n\(body)", in: directory)
        }
    }

    func setResolved(number: Int, thread: ReviewThread, resolved: Bool, in directory: URL) async throws {
        guard thread.isResolvable && thread.canResolve else { throw ReviewDiscussionError.unavailable }
        let mutation = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        let query = "mutation($id: ID!) { \(mutation)(input: {threadId: $id}) { thread { id } } }"
        let result = try await ghChecked(["api", "graphql", "-f", "query=\(query)", "-f", "id=\(thread.id)"], in: directory)
        let response = try JSONSerialization.jsonObject(with: result.standardOutput) as? [String: Any]
        guard response?["errors"] == nil, response?["data"] is [String: Any] else { throw ReviewDiscussionError.unavailable }
    }

    /// 把评论按「回复关系」归成线程。
    ///
    /// GitHub 的接口返回的是一个平铺数组，回复靠 `in_reply_to_id` 指回它回复的那条。
    /// 不归组的话，一来一回的讨论会散成一堆孤立条目，读起来完全不知道谁在回谁。
    static func threads(from comments: [GitHubComment], source: String) -> [ReviewThread] {
        var roots: [Int: [GitHubComment]] = [:]
        var order: [Int] = []
        for comment in comments {
            let key = comment.in_reply_to_id ?? comment.id
            if roots[key] == nil { order.append(key) }
            roots[key, default: []].append(comment)
        }

        return order.compactMap { key in
            guard let group = roots[key] else { return nil }
            let ordered = group.sorted {
                if $0.id == $1.id { return false }
                if $0.id == key { return true }
                if $1.id == key { return false }
                return ($0.created_at ?? .distantPast) < ($1.created_at ?? .distantPast)
            }
            guard let first = ordered.first else { return nil }
            return ReviewThread(
                id: "\(source)-\(key)",
                notes: ordered.map { comment in
                    ReviewNote(
                        id: String(comment.id),
                        authorName: comment.user?.login ?? "未知",
                        authorLogin: comment.user?.login ?? "",
                        body: comment.body ?? "",
                        createdAt: comment.created_at,
                        isSystem: false
                    )
                },
                filePath: first.path,
                // `line` 在这一行已经不在最新 diff 里时会是 null，
                // 这时退回 `original_line`（评论刚发时的行号）总比不显示行号好。
                line: first.line ?? first.original_line,
                isResolved: false,
                isResolvable: false,
                isOldSide: first.side == "LEFT",
                diffHunk: first.diff_hunk
            )
        }
    }

    // MARK: -

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // gh 输出的是 RFC 3339（`2026-08-27T14:03:09Z`），标准 iso8601 策略正好吃这个。
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}


/// GitHub 评论接口返回的一条评论。行内评审意见和整体讨论共用这个形状，
/// 只是整体讨论没有 `path` / `line`。
struct GitHubComment: Decodable, Sendable {
    var id: Int
    var body: String?
    var user: User?
    var created_at: Date?
    var path: String?
    var line: Int?
    var original_line: Int?
    /// 行内回复指向它所回复的那条评论。
    var in_reply_to_id: Int?
    var side: String?
    var diff_hunk: String?

    struct User: Decodable, Sendable {
        var login: String
    }
}

private struct GitHubReviewThreadState: Decodable {
    var id: String
    var isResolved: Bool
    var isOutdated: Bool
    var viewerCanResolve: Bool
    var viewerCanUnresolve: Bool
    var comments: Comments
    struct Comments: Decodable {
        var nodes: [Comment]
        struct Comment: Decodable { var databaseId: Int? }
    }
}

private struct GitHubReviewThreadPage: Decodable {
    var data: DataPayload?
    var errors: [GraphError]?
    struct GraphError: Decodable { var message: String }
    struct DataPayload: Decodable {
        var repository: Repository?
        struct Repository: Decodable {
            var pullRequest: Request?
            struct Request: Decodable {
                var reviewThreads: Page
                struct Page: Decodable {
                    var nodes: [GitHubReviewThreadState]
                    var pageInfo: PageInfo
                    struct PageInfo: Decodable { var hasNextPage: Bool; var endCursor: String? }
                }
            }
        }
    }
}
