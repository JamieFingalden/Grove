import Foundation

/// 通过 GitLab CLI（`glab`）访问 Merge Request。
///
/// 跟 GitHub 那一侧同样的取舍：认证交给 `glab`，Grove 不碰任何 token。
/// 自建实例（尤其是内网的 http + 非标准端口）的认证细节相当琐碎，
/// `glab auth login` 已经把它做完了，重写一遍只会多一处出错的地方。
///
/// 读操作一律走 `glab api` 直连 REST 接口，而不是 `glab mr list -F json`：
/// 前者能自己控制查询参数（`with_labels_details`、分页、按分支过滤），
/// 拿到的也是 GitLab 原始 JSON，字段含义有官方文档可查。
/// 写操作优先走 REST API；只有合并需要复用 `glab mr` 对合并策略的处理。
struct GitLabClient: ForgeClient {
    let executable: URL
    let environment: [String: String]
    private let projectContextCache = ProjectContextCache()
    private static let authProbeTimeout: Double = 8

    var kind: ForgeKind { .gitlab }

    init(executable: URL, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    static func resolve() async -> GitLabClient? {
        guard let executable = await ToolLocator.shared.locate("glab") else { return nil }
        return GitLabClient(
            executable: executable,
            environment: await ToolLocator.shared.childEnvironment()
        )
    }

    // MARK: - 底层调用

    private func run(
        _ arguments: [String],
        in directory: URL?,
        timeout: Double = ProcessRunner.networkTimeout
    ) async throws -> CommandResult {
        let command = await preparedCommand(arguments, in: directory)
        return try await ProcessRunner.run(
            executable: executable,
            arguments: command.arguments,
            workingDirectory: directory,
            environment: command.environment,
            timeout: timeout
        )
    }

    @discardableResult
    private func runChecked(_ arguments: [String], in directory: URL?) async throws -> CommandResult {
        let command = await preparedCommand(arguments, in: directory)
        return try await ProcessRunner.runChecked(
            executable: executable,
            arguments: command.arguments,
            workingDirectory: directory,
            environment: command.environment,
            timeout: ProcessRunner.networkTimeout
        )
    }

    /// 给带非标准端口的自建 GitLab 补齐项目上下文。
    ///
    /// glab 把远程的 `host:port` 和认证配置的 `host` 当成两台主机，
    /// 即使 `api_host` 明确指向该端口，它也不会展开 `:id`。这里改用明确的
    /// 项目路径和认证主机，同时给 `glab mr` 指定仓库，读写操作都走同一套规则。
    private func preparedCommand(
        _ original: [String],
        in directory: URL?
    ) async -> (arguments: [String], environment: [String: String]) {
        guard let directory,
              let command = original.first,
              command == "api" || command == "mr",
              let context = await projectContext(in: directory) else {
            return (original, environment)
        }

        var arguments = original
        var commandEnvironment = environment
        commandEnvironment["GITLAB_HOST"] = context.hostname

        if command == "api", arguments.count > 1 {
            arguments[1] = arguments[1].replacingOccurrences(of: ":id", with: context.encodedProjectID)
        } else if !arguments.contains("--repo") && !arguments.contains("-R") {
            arguments.append(contentsOf: ["--repo", context.projectPath])
        }
        return (arguments, commandEnvironment)
    }

    private func projectContext(in directory: URL) async -> ProjectContext? {
        let cacheKey = directory.standardizedFileURL
        if let cached = await projectContextCache.value(for: cacheKey) { return cached }

        guard let git = await ToolLocator.shared.locate("git"),
              let result = try? await ProcessRunner.run(
                  executable: git,
                  arguments: ["remote", "get-url", "origin"],
                  workingDirectory: directory,
                  environment: environment
              ),
              result.isSuccess,
              let remote = GitRemote.parse(result.trimmedStdout) else { return nil }

        let hostname = await configuredHostname(for: remote)
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedProjectID = remote.path.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            return nil
        }
        let context = ProjectContext(
            hostname: hostname,
            projectPath: remote.path,
            encodedProjectID: encodedProjectID
        )
        await projectContextCache.insert(context, for: cacheKey)
        return context
    }

    /// 读本地 glab 配置来匹配认证主机，不为每次 API 调用额外发一次网络请求。
    private func configuredHostname(for remote: GitRemote) async -> String {
        for candidate in [remote.hostWithPort, remote.host] {
            guard let result = try? await ProcessRunner.run(
                executable: executable,
                arguments: ["config", "get", "api_host", "--host", candidate],
                environment: environment
            ) else { continue }
            if result.isSuccess, !result.trimmedStdout.isEmpty { return candidate }
        }
        return remote.hostWithPort
    }

    private struct ProjectContext {
        var hostname: String
        var projectPath: String
        var encodedProjectID: String
    }

    /// 一个仓库的 origin 和 glab 主机配置在一次运行期里基本不会变。
    /// 缓存后，连续拉详情、审批、流水线和讨论时不用每次再启动 git/glab 探测子进程。
    private actor ProjectContextCache {
        private var values: [URL: ProjectContext] = [:]

        func value(for directory: URL) -> ProjectContext? { values[directory] }
        func insert(_ context: ProjectContext, for directory: URL) { values[directory] = context }
    }

    /// 从 glab 的 YAML 配置里只读主机名，不触发任何网络认证。
    /// token 在更深一层，解析器既不读取也不返回它。
    static func configuredHosts(fromConfig text: String) -> Set<String> {
        var sectionIndent: Int?
        var hostIndent: Int?
        var hosts: Set<String> = []

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = rawLine.prefix { $0 == " " }.count

            if sectionIndent == nil {
                if trimmed == "hosts:" { sectionIndent = indent }
                continue
            }
            guard let sectionIndent else { continue }
            if indent <= sectionIndent { break }
            if hostIndent == nil { hostIndent = indent }
            guard indent == hostIndent, trimmed.hasSuffix(":") else { continue }

            var host = String(trimmed.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if host.count >= 2,
               (host.first == "\"" && host.last == "\""
                || host.first == "'" && host.last == "'") {
                host.removeFirst()
                host.removeLast()
            }
            if !host.isEmpty { hosts.insert(host) }
        }
        return hosts
    }

    /// 调一个 REST 接口。
    ///
    /// `:id` 会在底层调用前替换成 URL 编码的项目路径，避免 glab
    /// 在带非标准端口的自建实例上无法展开占位符。
    private func api(
        _ path: String,
        in directory: URL,
        method: String? = nil,
        fields: [String: String] = [:]
    ) async throws -> Data {
        var arguments = ["api", path]
        if let method { arguments.append(contentsOf: ["--method", method]) }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            // `--raw-field` 不做类型推断，原样当字符串传。评论正文里出现
            // 数字、`true` 这种内容时不会被误转成 JSON 标量。
            arguments.append(contentsOf: ["--raw-field", "\(key)=\(value)"])
        }
        let result = try await runChecked(arguments, in: directory)
        return result.standardOutput
    }

    // MARK: - 可用性

    func isAuthenticated() async -> Bool {
        // 裸 `glab auth status` 会检查所有配置过的主机：只要其中一台的
        // 令牌过期，整条命令就返回失败，连已正常登录的内网 GitLab 也会被
        // Grove 误判成不可用。逐台检查，任意一台可用就足以启用 GitLab 功能；
        // 当前仓库若恰好指向未登录的另一台，后续 API 调用会给出该主机的原始错误。
        let hosts = await configuredHosts()
        return await withTaskGroup(of: Bool.self) { group in
            for host in hosts {
                group.addTask {
                    let result = try? await run(
                        ["auth", "status", "--hostname", host],
                        in: nil,
                        timeout: Self.authProbeTimeout
                    )
                    return result?.isSuccess == true
                }
            }
            for await authenticated in group where authenticated {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    func configuredHosts() async -> Set<String> {
        // `glab auth status --all` 会联网验证每台主机；启动时用它列主机，
        // 一台离线实例就能拖住整个应用。配置文件路径和内容都是本地读取。
        if let pathResult = try? await run(
            ["config", "path"],
            in: nil,
            timeout: ProcessRunner.localTimeout
        ), pathResult.isSuccess,
           let text = try? String(contentsOfFile: pathResult.trimmedStdout, encoding: .utf8) {
            let hosts = Self.configuredHosts(fromConfig: text)
            if !hosts.isEmpty { return hosts }
        }

        // 极老版本 glab 没有标准配置路径时才退回 CLI，并给探测设置短超时。
        guard let result = try? await run(
            ["auth", "status", "--all"],
            in: nil,
            timeout: Self.authProbeTimeout
        ) else { return [] }
        return AuthStatusParser.hosts(in: result.stdout + "\n" + result.stderr)
    }

    func repositorySlug(in directory: URL) async -> String? {
        struct Project: Decodable { var pathWithNamespace: String }
        guard let data = try? await api("projects/:id", in: directory),
              let project = try? Self.decoder.decode(Project.self, from: data) else {
            return nil
        }
        return project.pathWithNamespace
    }

    func createRepository(_ request: NewRemoteRepository, in directory: URL) async throws {
        var commandEnvironment = environment
        commandEnvironment["GITLAB_HOST"] = request.host
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
            "--remoteName", "origin"
        ]
        let description = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            arguments.append(contentsOf: ["--description", description])
        }
        return arguments
    }

    // MARK: - 查询

    func pullRequests(in directory: URL, limit: Int, includeClosed: Bool) async throws -> [PullRequest] {
        var query = "projects/:id/merge_requests?per_page=\(limit)&order_by=updated_at"
        query += "&with_labels_details=true"
        query += includeClosed ? "&state=all" : "&state=opened"

        let data = try await api(query, in: directory)
        let merges = try Self.decoder.decode([GitLabMergeRequest].self, from: data)
        // 列表视图不逐个去拉审批和任务列表 —— 那会变成几十个串行请求。
        return merges.map { $0.asPullRequest() }
    }

    func pullRequest(number: Int, in directory: URL) async throws -> PullRequest {
        let data = try await api(
            "projects/:id/merge_requests/\(number)?with_labels_details=true",
            in: directory
        )
        let merge = try Self.decoder.decode(GitLabMergeRequest.self, from: data)

        // 详情页才值得补齐这两样。任何一个失败都不该让整个详情页打不开 ——
        // 自建实例上审批是收费功能，社区版直接返回 404。
        async let approvalRequest = try? approvals(number: number, in: directory)
        async let jobRequest = pipelineJobs(pipelineID: merge.headPipeline?.id, in: directory)
        let (loadedApprovals, loadedJobs) = await (approvalRequest, jobRequest)
        return merge.asPullRequest(approvals: loadedApprovals, jobs: loadedJobs)
    }

    func pullRequestDiff(number: Int, in directory: URL) async throws -> [FileDiff] {
        // raw_diffs 返回完整 unified diff，既保留文件头，也不需要逐文件分页请求。
        do {
            let data = try await api(
                "projects/:id/merge_requests/\(number)/raw_diffs",
                in: directory
            )
            return DiffParser.parse(CommandResult.decode(data))
        } catch let error as CommandFailure where error.output.contains("HTTP 404") {
            // 较老的自建 GitLab 没有 raw_diffs，只能走已废弃但仍可用的 changes 接口。
            // access_raw_diffs 绕过数据库的单文件大小限制，否则较大的文件会返回空 diff。
            // changes 里的 diff 从 @@ 开始，先补齐文件头再交给同一个解析器。
            let data = try await api(
                "projects/:id/merge_requests/\(number)/changes?access_raw_diffs=true",
                in: directory
            )
            let response = try Self.decoder.decode(GitLabMergeRequestChanges.self, from: data)
            return DiffParser.parse(response.unifiedDiff)
        }
    }

    func pullRequest(forBranch branch: String, in directory: URL) async throws -> PullRequest? {
        guard let encoded = branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        let data = try await api(
            "projects/:id/merge_requests?source_branch=\(encoded)&state=all&per_page=10&with_labels_details=true",
            in: directory
        )
        let merges = try Self.decoder.decode([GitLabMergeRequest].self, from: data)
        // 同一个分支可能提过多个 MR（提了、关了、又提一个），挑最该展示的那个。
        return GitHubClient.mostRelevant(of: merges.map { $0.asPullRequest() })
    }

    private func approvals(number: Int, in directory: URL) async throws -> GitLabApprovals {
        let data = try await api("projects/:id/merge_requests/\(number)/approvals", in: directory)
        return try Self.decoder.decode(GitLabApprovals.self, from: data)
    }

    private func pipelineJobs(pipelineID: Int?, in directory: URL) async -> [GitLabJob]? {
        guard let pipelineID else { return nil }
        guard let data = try? await api(
            "projects/:id/pipelines/\(pipelineID)/jobs?per_page=100",
            in: directory
        ) else { return nil }
        return try? Self.decoder.decode([GitLabJob].self, from: data)
    }

    func reviewThreads(number: Int, in directory: URL) async throws -> [ReviewThread] {
        let data = try await api(
            "projects/:id/merge_requests/\(number)/discussions?per_page=100",
            in: directory
        )
        let discussions = try Self.decoder.decode([GitLabDiscussion].self, from: data)
        return discussions.compactMap { $0.asReviewThread() }
    }

    // MARK: - 操作

    func createPullRequest(_ request: NewPullRequest, in directory: URL) async throws -> String {
        // `glab mr create` 会把 GITLAB_HOST 和 Git remote 的 host:port 严格比较。
        // 自建实例的认证主机不带端口、远端带端口时，即使 API 配置完全正确也会拒绝创建。
        // REST 接口直接使用已经解析好的项目路径，不需要再让 glab 猜仓库。
        let title = request.isDraft ? "Draft: \(request.title)" : request.title
        let data = try await api(
            "projects/:id/merge_requests",
            in: directory,
            method: "POST",
            fields: [
                "description": request.body,
                "source_branch": request.head,
                "target_branch": request.base,
                "title": title
            ]
        )
        return try Self.decoder.decode(GitLabMergeRequest.self, from: data).webUrl
    }

    func merge(number: Int, strategy: MergeStrategy, deleteBranch: Bool, in directory: URL) async throws {
        var arguments = ["mr", "merge", String(number), "--yes"]
        switch strategy {
        case .squash: arguments.append("--squash")
        case .rebase: arguments.append("--rebase")
        case .merge: break      // 默认就是普通合并提交
        }
        if deleteBranch { arguments.append("--remove-source-branch") }

        // 关键：`glab mr merge` 在流水线还在跑时**默认启用 auto-merge**
        // （等流水线过了再合），而不是立刻合并。用户在 Grove 里点「合并」
        // 期待的是现在就合，不写这个参数会表现成「点了没反应」。
        arguments.append("--auto-merge=false")

        try await runChecked(arguments, in: directory)
    }

    func approve(number: Int, in directory: URL) async throws {
        // `glab mr approve` 完成批准后还会再查一次请求详情；在同时存在
        // GitHub 备份 remote 的仓库里，那次查询可能误走 GitHub GraphQL。
        // 批准本身是一个稳定的 GitLab REST 接口，直接调它不做多余查询。
        _ = try await api(
            "projects/:id/merge_requests/\(number)/approve",
            in: directory,
            method: "POST"
        )
    }

    func unapprove(number: Int, in directory: URL) async throws {
        _ = try await api(
            "projects/:id/merge_requests/\(number)/unapprove",
            in: directory,
            method: "POST"
        )
    }

    func requestChanges(number: Int, body: String, in directory: URL) async throws {
        // GitLab 没有「要求修改」这个独立动作（那是 GitHub 评审模型的概念）。
        // 最接近的等价物是留一条评论 —— 加个前缀让对方一眼看出意图。
        try await comment(number: number, body: "**要求修改**\n\n\(body)", in: directory)
    }

    func comment(number: Int, body: String, in directory: URL) async throws {
        // 用 API 而不是 `glab mr note`：后者的正文参数在不同版本间有过变化，
        // 而 notes 接口十年没动过。
        _ = try await api(
            "projects/:id/merge_requests/\(number)/notes",
            in: directory,
            fields: ["body": body]
        )
    }

    // MARK: -

    private struct GitLabMergeRequestChanges: Decodable {
        var changes: [Change]

        struct Change: Decodable {
            var oldPath: String
            var newPath: String
            var diff: String
            var newFile: Bool
            var deletedFile: Bool
            var renamedFile: Bool
            var aMode: String?
            var bMode: String?

            var unifiedDiff: String {
                var lines = ["diff --git a/\(oldPath) b/\(newPath)"]

                if newFile {
                    lines.append("new file mode \(bMode ?? "100644")")
                } else if deletedFile {
                    lines.append("deleted file mode \(aMode ?? "100644")")
                } else if let aMode, let bMode, aMode != bMode {
                    lines.append("old mode \(aMode)")
                    lines.append("new mode \(bMode)")
                }
                if renamedFile {
                    lines.append("rename from \(oldPath)")
                    lines.append("rename to \(newPath)")
                }

                lines.append(newFile ? "--- /dev/null" : "--- a/\(oldPath)")
                lines.append(deletedFile ? "+++ /dev/null" : "+++ b/\(newPath)")
                if !diff.isEmpty { lines.append(diff) }
                return lines.joined(separator: "\n")
            }
        }

        var unifiedDiff: String {
            changes.map(\.unifiedDiff).joined(separator: "\n")
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom(GitLabClient.decodeDate)
        return decoder
    }()

    /// GitLab 的时间戳带毫秒（`2026-08-28T10:45:10.425Z`），而 GitHub 的不带。
    ///
    /// 不用 `JSONDecoder` 内置的 `.iso8601` 策略，是因为它对小数秒的支持没有文档
    /// 保证：早期的 Foundation 实现遇到小数秒直接失败，新版本才变得宽松。
    /// 而「日期解析失败」在这里的后果是**整条 MR 解不出来**、界面上一个都不显示，
    /// 错误信息还只含糊地说某个字段格式不对 —— 不值得赌运行时的宽容度。
    /// `Date.ISO8601FormatStyle` 两种写法都明确支持，而且是值类型、天然 Sendable。
    static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = DateParsing.iso8601(text) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析时间戳：\(text)"
            )
        }
        return date
    }
}
