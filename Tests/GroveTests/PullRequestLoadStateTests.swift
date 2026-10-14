import XCTest
@testable import Grove

@MainActor
final class PullRequestLoadStateTests: XCTestCase {
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
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:])
        let repository = RepositoryModel(root: directory, git: git, app: nil,
            forge: GitHubClient(executable: executable, environment: [:]))
        repository.origin = GitRemote.parse("https://github.com/team/Grove.git")
        repository.hasRemote = true
        repository.defaultBranch = "main"
        let worktree = Worktree(path: directory, head: nil, branch: "feature", isBare: false,
                                isDetached: false, lockReason: nil, prunableReason: nil)
        let model = WorktreeModel(worktree: worktree, repository: repository, git: git, app: nil)
        repository.resolveForgeMetadata()
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

    func testReviewActionUsesOpenRequestAlreadyLoadedByRepository() {
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:])
        let repository = RepositoryModel(root: URL(fileURLWithPath: "/tmp/Grove"), git: git, app: nil,
            forge: GitHubClient(executable: URL(fileURLWithPath: "/bin/false"), environment: [:]))
        repository.origin = GitRemote.parse("https://github.com/team/Grove.git")
        repository.hasRemote = true
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
        guard case .create = model.pullRequestAction else { return XCTFail("已关闭的缓存请求不能阻止再次创建") }
    }

}
