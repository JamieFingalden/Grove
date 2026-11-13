import XCTest
@testable import Grove

@MainActor
final class PullRequestLoadStateTests: XCTestCase {
    /// 用本地裸仓库模拟服务器，检查真实分支状态而不访问网络。
    private func publishedGit(in directory: URL, branch: String = "feature") async throws -> GitClient {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:])
        let remote = directory.appendingPathComponent("origin.git")
        try await git.run(["init", "-q", "-b", "main"], in: directory)
        try await git.run(["config", "user.name", "测试"], in: directory)
        try await git.run(["config", "user.email", "test@example.invalid"], in: directory)
        try await git.run(["commit", "--allow-empty", "-qm", "初始提交"], in: directory)
        try await git.run(["switch", "-qc", branch], in: directory)
        try await git.run(["init", "--bare", "-q", remote.path], in: directory)
        try await git.run(["remote", "add", "origin", remote.path], in: directory)
        try await git.push(in: directory, remote: "origin", branch: branch, setUpstream: true)
        return git
    }

    func testHistoryListPublishesBeforeSlowOpenCountAndSurvivesItsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let release = directory.appendingPathComponent("release")
        let executable = directory.appendingPathComponent("gh")
        try """
        #!/bin/sh
        case "$*" in
          *'--state open'*)
            : > "\(started.path)"
            count=0
            while [ ! -f "\(release.path)" ]; do
              count=$((count + 1)); [ "$count" -lt 200 ] || exit 1
              /bin/sleep 0.01
            done
            echo '开放数量查询失败' >&2
            exit 1 ;;
          *) printf '[]' ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let repository = RepositoryModel(root: directory,
            git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:]), app: nil,
            forge: GitHubClient(executable: executable, environment: [:]))
        repository.slug = "group/project"
        let loading = Task { await repository.setPullRequestListState(.all) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: started.path), repository.hasLoadedPullRequests { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertTrue(repository.hasLoadedPullRequests, "历史列表不应等待侧栏开放数量")
        XCTAssertFalse(repository.isRefreshingPullRequests)
        try Data().write(to: release)
        await loading.value
        XCTAssertNil(repository.pullRequestLoadError, "侧栏查询失败不能让成功的历史列表报错")
        XCTAssertFalse(repository.hasLoadedOpenPullRequests)
    }

    func testAutomaticLoadsShareRequestsAndReuseFreshResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("requests.log")
        let executable = directory.appendingPathComponent("gh")
        try """
        #!/bin/sh
        echo "$*" >> "\(log.path)"
        /bin/sleep 0.1
        printf '%s' '[{"number":42,"title":"评审","state":"OPEN","isDraft":false,"headRefName":"feature","baseRefName":"main","url":"u","updatedAt":"2026-10-10T00:00:00Z","additions":0,"deletions":0,"changedFiles":0,"isCrossRepository":false,"labels":[]}]'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let repository = RepositoryModel(root: directory,
            git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:]), app: nil,
            forge: GitHubClient(executable: executable, environment: [:]))
        repository.slug = "group/project"
        repository.defaultBranch = "main"
        repository.worktrees = ["main", "feature", "pr-42"].map { branch in
            Worktree(path: directory.appendingPathComponent(branch), head: nil, branch: branch,
                     isBare: false, isDetached: false, lockReason: nil, prunableReason: nil)
        }

        let first = Task { await repository.refreshPullRequests(ifNeeded: true) }
        for _ in 0..<100 where !repository.isRefreshingPullRequests {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(repository.isRefreshingPullRequests)
        // 页面切走不能取消其他入口共享的请求。
        first.cancel()
        await repository.refreshPullRequests(ifNeeded: true)
        await first.value
        await repository.refreshPullRequests(ifNeeded: true)
        var commands = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(commands.count, 1, "并发进入、短时间切回和已有开放关联都不应重复联网")
        XCTAssertEqual(repository.sidebarPullRequest(forBranch: "feature")?.number, 42)
        XCTAssertEqual(repository.sidebarPullRequest(forBranch: "pr-42")?.number, 42)

        await repository.refreshPullRequests()
        commands = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(commands.count, 2, "手动刷新必须绕过缓存")

        repository.origin = GitRemote.parse("https://github.com/group/other.git")
        await repository.refreshPullRequests(ifNeeded: true)
        commands = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(commands.count, 3, "不能跨 origin 复用缓存")

        await repository.setPullRequestListState(.all)
        await repository.refreshPullRequests(ifNeeded: true)
        commands = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(commands.count, 5, "切换筛选需要新请求，随后自动进入仍复用结果")
        XCTAssertNil(repository.pullRequestLoadError)
    }

    func testListFinishesLoadingBeforeSlowSidebarHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let release = directory.appendingPathComponent("release")
        let executable = directory.appendingPathComponent("gh")
        try """
        #!/bin/sh
        if [ "$3" = "--head" ]; then
          : > "\(started.path)"
          count=0
          while [ ! -f "\(release.path)" ]; do
            count=$((count + 1)); [ "$count" -lt 200 ] || exit 1
            /bin/sleep 0.01
          done
        fi
        printf '[]'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let repository = RepositoryModel(root: directory,
            git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:]), app: nil,
            forge: GitHubClient(executable: executable, environment: [:]))
        repository.slug = "group/project"
        repository.worktrees = [Worktree(path: directory, head: nil, branch: "old-feature",
            isBare: false, isDetached: false, lockReason: nil, prunableReason: nil)]
        let loading = Task { await repository.refreshPullRequests() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "应继续补查历史关联")
        XCTAssertTrue(repository.hasLoadedPullRequests)
        XCTAssertFalse(repository.isRefreshingPullRequests, "空列表已返回时不能继续显示加载中")
        try Data().write(to: release)
        await loading.value
    }

    func testFailureRetryAndFilterNeverTreatFailureAsEmptyData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = directory.appendingPathComponent("failure")
        let executable = directory.appendingPathComponent("gh")
        // 只返回空集合；失败由本地标记控制，不访问真实平台或生成示例 PR。
        try """
        #!/bin/sh
        if [ -f "\(failure.path)" ]; then
          echo 'HTTP 403: Resource not accessible' >&2
          exit 1
        fi
        printf '[]'
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let repository = RepositoryModel(root: directory,
            git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:]), app: nil,
            forge: GitHubClient(executable: executable, environment: [:]))
        repository.slug = "group/project"
        XCTAssertFalse(repository.hasLoadedPullRequests)

        try Data().write(to: failure)
        await repository.refreshPullRequests()
        XCTAssertFalse(repository.hasLoadedPullRequests, "失败不能成为成功的空结果")
        XCTAssertNotNil(repository.pullRequestLoadError)
        XCTAssertFalse(repository.isRefreshingPullRequests)

        try FileManager.default.removeItem(at: failure)
        await repository.refreshPullRequests()
        XCTAssertTrue(repository.hasLoadedPullRequests)
        XCTAssertNil(repository.pullRequestLoadError)
        XCTAssertTrue(repository.listPullRequests.isEmpty)

        try Data().write(to: failure)
        await repository.setPullRequestListState(.all)
        XCTAssertEqual(repository.listState, .all)
        XCTAssertFalse(repository.hasLoadedPullRequests, "切换筛选后不能复用上一筛选的加载结果")
        XCTAssertTrue(repository.hasLoadedOpenPullRequests, "切换筛选失败不能清除侧栏开放请求的加载状态")
        XCTAssertNotNil(repository.pullRequestLoadError)
        try FileManager.default.removeItem(at: failure)
        await repository.refreshPullRequests()
        XCTAssertTrue(repository.hasLoadedPullRequests)
        XCTAssertNil(repository.pullRequestLoadError)
    }
    func testReviewActionDoesNotWaitForRemoteMetadataOrListRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("requested")
        let executable = directory.appendingPathComponent("gh")
        try """
        #!/bin/sh
        : > "\(marker.path)"
        /bin/sleep 0.1
        echo 'HTTP 503: 远端暂时不可用' >&2
        exit 1
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let git = try await publishedGit(in: directory)
        let repository = RepositoryModel(root: directory, git: git, app: nil,
            forge: GitHubClient(executable: executable, environment: [:]))
        repository.origin = GitRemote.parse("https://github.com/team/Grove.git")
        repository.hasRemote = true
        repository.hasOrigin = true
        repository.defaultBranch = "main"
        let worktree = Worktree(path: directory, head: nil, branch: "feature", isBare: false,
                                isDetached: false, lockReason: nil, prunableReason: nil)
        let model = WorktreeModel(worktree: worktree, repository: repository, git: git, app: nil)
        repository.resolveForgeMetadata()
        await model.refreshReviewSource()
        XCTAssertEqual(repository.slug, "team/Grove")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "解析本地信息不能发网络请求")
        guard case .create = model.pullRequestAction else { return XCTFail("列表未加载时也应能打开评审表单") }
        let loading = Task { await repository.refreshPullRequests() }
        for _ in 0..<100 where !repository.isRefreshingPullRequests {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(repository.isRefreshingPullRequests)
        guard case .create = model.pullRequestAction else { return XCTFail("列表加载中不能禁用评审入口") }
        await loading.value
        XCTAssertNotNil(repository.pullRequestLoadError)
        guard case .create = model.pullRequestAction else { return XCTFail("列表失败应独立显示，不能把本地项目当作无法识别") }
        model.worktree.branch = "main"
        guard case .unavailable = model.pullRequestAction else { return XCTFail("默认分支仍应禁止发起评审") }
        model.worktree.branch = "feature"
        model.worktree.isDetached = true
        guard case .unavailable = model.pullRequestAction else { return XCTFail("游离 HEAD 仍应禁止发起评审") }
        model.worktree.isDetached = false
        repository.hasRemote = false
        guard case .unavailable = model.pullRequestAction else { return XCTFail("无远端不能发起评审") }
        let gitlab = RepositoryModel(root: directory, git: git, app: nil,
            forge: GitLabClient(executable: executable, environment: [:]))
        gitlab.origin = GitRemote.parse("https://gitlab.example.com/team/subgroup/Grove.git")
        gitlab.resolveForgeMetadata()
        XCTAssertEqual(gitlab.slug, "team/subgroup/Grove", "GitLab 不能截断嵌套群组")
        let unconfigured = RepositoryModel(root: directory, git: git, app: nil)
        unconfigured.hasRemote = true
        unconfigured.origin = repository.origin
        XCTAssertNotNil(unconfigured.pullRequestUnavailableReason, "缺少平台客户端仍应禁止创建")
    }

    func testReviewActionDoesNotDependOnGlobalForgeProbe() async throws {
        let app = AppModel()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = try await publishedGit(in: directory, branch: "fix/fgj")
        let repository = RepositoryModel(root: directory, git: git, app: app,
            forge: GitLabClient(executable: URL(fileURLWithPath: "/bin/false"), environment: [:]))
        repository.origin = GitRemote.parse("http://192.168.251.253:8929/team/Grove.git")
        repository.hasRemote = true
        repository.hasOrigin = true
        repository.slug = "team/Grove"
        repository.defaultBranch = "master"
        let model = WorktreeModel(worktree: Worktree(path: repository.root, head: nil, branch: "fix/fgj",
            isBare: false, isDetached: false, lockReason: nil, prunableReason: nil),
            repository: repository, git: git, app: app)
        model.status.upstream = "origin/fix/fgj"
        model.status.ahead = 0
        await model.refreshReviewSource()

        // 仓库客户端已就绪时，全局探测尚未就绪也不能阻止已推送分支进入表单。
        XCTAssertFalse(app.availability(of: .gitlab).isReady)
        XCTAssertNil(repository.pullRequestUnavailableReason)
        guard case .create = model.pullRequestAction else { return XCTFail("全局探测不能禁用仓库的评审入口") }

        model.worktree.branch = "master"
        guard case .unavailable = model.pullRequestAction else { return XCTFail("默认分支仍不能发起评审") }
        repository.hasOrigin = false
        XCTAssertEqual(repository.pullRequestUnavailableReason, "这个仓库没有配置 origin。")
    }

    func testDeletedRemoteBranchIsRecheckedBeforeCreatingAndNeverRepushed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = try await publishedGit(in: directory)
        let marker = directory.appendingPathComponent("created")
        let executable = directory.appendingPathComponent("gh")
        try """
        #!/bin/sh
        if [ "$1" = "pr" ] && [ "$2" = "create" ]; then
          : > "\(marker.path)"
          printf 'https://github.com/team/Grove/pull/1'
        else
          printf '[]'
        fi
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let repository = RepositoryModel(root: directory, git: git, app: nil,
            forge: GitHubClient(executable: executable, environment: [:]))
        repository.origin = GitRemote.parse("https://github.com/team/Grove.git")
        repository.hasRemote = true
        repository.hasOrigin = true
        repository.defaultBranch = "main"
        repository.resolveForgeMetadata()
        let model = WorktreeModel(worktree: Worktree(path: directory, head: nil, branch: "feature",
            isBare: false, isDetached: false, lockReason: nil, prunableReason: nil), repository: repository, git: git, app: nil)
        await model.refreshReviewSource()
        guard case .create = model.pullRequestAction else { return XCTFail("已发布分支应能发起评审") }

        // 模拟表单打开后在服务器删除分支，保留本地上游与跟踪引用，且不执行 fetch。
        let remote = directory.appendingPathComponent("origin.git")
        try await git.run(["update-ref", "-d", "refs/heads/feature"], in: remote)
        let staleReference = await git.succeeds(["show-ref", "--verify", "refs/remotes/origin/feature"], in: directory)
        XCTAssertTrue(staleReference)
        for upstream in [nil, "origin/feature"] as [String?] {
            model.status.upstream = upstream
            model.status.ahead = 1
            let url = await model.createPullRequest(title: "测试评审", body: "", base: "main", isDraft: false)
            XCTAssertNil(url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "分支已删时不能调用创建接口")
            let remoteOID = try await git.remoteBranchOID("feature", in: directory)
            XCTAssertNil(remoteOID, "评审不能隐式推送并复活已删除的分支")
            guard case .unavailable(let reason) = model.pullRequestAction else { return XCTFail("分支已删时入口应不可用") }
            XCTAssertTrue(reason.contains("origin 上不存在分支"))
        }

        // 明确重新推送后才能恢复入口，并能实际调用创建接口。
        try await git.push(in: directory, remote: "origin", branch: "feature", setUpstream: true)
        await model.refreshReviewSource()
        guard case .create = model.pullRequestAction else { return XCTFail("明确重新推送后应恢复评审") }
        let url = await model.createPullRequest(title: "测试评审", body: "", base: "main", isDraft: false)
        XCTAssertEqual(url, "https://github.com/team/Grove/pull/1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUnpublishedCommitsAndConnectionFailureCannotCreateReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = try await publishedGit(in: directory)
        let repository = RepositoryModel(root: directory, git: git, app: nil,
            forge: GitHubClient(executable: URL(fileURLWithPath: "/bin/false"), environment: [:]))
        repository.origin = GitRemote.parse("https://github.com/team/Grove.git")
        repository.hasRemote = true
        repository.hasOrigin = true
        repository.defaultBranch = "main"
        repository.resolveForgeMetadata()
        let model = WorktreeModel(worktree: Worktree(path: directory, head: nil, branch: "feature",
            isBare: false, isDetached: false, lockReason: nil, prunableReason: nil), repository: repository, git: git, app: nil)
        try await git.run(["commit", "--allow-empty", "-qm", "尚未发布"], in: directory)
        await model.refreshReviewSource()
        guard case .unavailable(let unpublished) = model.pullRequestAction else { return XCTFail("本地新提交未推送时不能发起评审") }
        XCTAssertTrue(unpublished.contains("提交不一致"))

        try await git.run(["remote", "set-url", "origin", directory.appendingPathComponent("missing.git").path], in: directory)
        await model.refreshReviewSource()
        guard case .unavailable(let failure) = model.pullRequestAction else { return XCTFail("查询失败不能假定分支存在") }
        XCTAssertTrue(failure.contains("无法确认"), "网络或访问错误不能冒充远端分支已删除")
    }

    func testReviewActionUsesOpenRequestAlreadyLoadedByRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = try await publishedGit(in: directory)
        let repository = RepositoryModel(root: directory, git: git, app: nil,
            forge: GitHubClient(executable: URL(fileURLWithPath: "/bin/false"), environment: [:]))
        repository.origin = GitRemote.parse("https://github.com/team/Grove.git")
        repository.hasRemote = true
        repository.hasOrigin = true
        repository.defaultBranch = "main"
        repository.resolveForgeMetadata()
        let request = PullRequest(number: 8, title: "已有评审", state: "OPEN", isDraft: false,
            headRefName: "feature", baseRefName: "main", url: "u", author: nil, updatedAt: Date(),
            additions: 0, deletions: 0, changedFiles: 0, isCrossRepository: false, labels: [])
        repository.updateOpenPullRequests([request], fromOrigin: repository.origin)
        let model = WorktreeModel(worktree: Worktree(path: repository.root, head: nil, branch: "feature",
            isBare: false, isDetached: false, lockReason: nil, prunableReason: nil), repository: repository, git: git, app: nil)
        guard case .view(let linked) = model.pullRequestAction else { return XCTFail("已有开放评审时应直接查看，不能再次创建") }
        XCTAssertEqual(linked.number, 8)
        repository.pullRequests[0].state = "CLOSED"
        await model.refreshReviewSource()
        guard case .create = model.pullRequestAction else { return XCTFail("已关闭的缓存请求不能阻止再次创建") }
    }

}
