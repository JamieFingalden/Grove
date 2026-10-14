import XCTest
@testable import Grove

@MainActor
final class ForgeSafetyTests: XCTestCase {
    func testOpenPullRequestCountIncludesDraftsAndIgnoresHistoryFilter() {
        let repository = RepositoryModel(root: URL(fileURLWithPath: "/tmp/Grove"),
            git: GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:]), app: nil)
        XCTAssertNil(repository.openPullRequestCountLabel, "加载前不能把未知数量显示成零")
        let request = PullRequest(number: 1, title: "测试请求", state: "OPEN", isDraft: false,
            headRefName: "feature", baseRefName: "main", url: "u", author: nil, updatedAt: Date(),
            additions: 0, deletions: 0, changedFiles: 0, isCrossRepository: false, labels: [])
        var draft = request
        draft.number = 2
        draft.isDraft = true
        var closed = request
        closed.number = 3
        closed.state = "CLOSED"
        repository.listState = .closed
        repository.listPullRequests = [closed]
        repository.updateOpenPullRequests([request, draft], fromOrigin: nil)
        XCTAssertEqual(repository.openPullRequestCountLabel, "2")
        XCTAssertEqual(repository.listPullRequests, [closed])
        XCTAssertTrue(repository.hasLoadedOpenPullRequests)
        XCTAssertFalse(repository.hasLoadedPullRequests, "后台更新开放请求不能把历史筛选标记为已加载")
        repository.updateOpenPullRequests([], fromOrigin: nil)
        XCTAssertNil(repository.openPullRequestCountLabel, "没有开放请求时不显示角标")
        repository.updateOpenPullRequests((1...RepositoryModel.openPullRequestLimit).map { number in
            var copy = request
            copy.number = number
            return copy
        }, fromOrigin: nil)
        XCTAssertEqual(repository.openPullRequestCountLabel, "1000+")
    }

    func testSidebarPullRequestsIncludeHistoryWithoutChangingActiveLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = directory.appendingPathComponent("response.json")
        let executable = directory.appendingPathComponent("gh")
        try Data(#"""
        #!/bin/sh
        if [ "$3" = "--head" ]; then
          cat "$GROVE_TEST_RESPONSE"
        else
          printf '[]\n'
        fi
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var environment = ProcessInfo.processInfo.environment
        environment["GROVE_TEST_RESPONSE"] = response.path
        let forge = GitHubClient(executable: executable, environment: environment)
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: environment)
        let repository = RepositoryModel(root: directory, git: git, app: nil, forge: forge)
        repository.slug = "group/project"
        repository.defaultBranch = "main"
        repository.worktrees = ["main", "feature"].map { branch in
            Worktree(path: directory.appendingPathComponent(branch), head: nil, branch: branch,
                     isBare: false, isDetached: false, lockReason: nil, prunableReason: nil)
        }
        for state in ["MERGED", "CLOSED", "OPEN"] {
            let json = """
            [{"number":42,"title":"评审","state":"\(state)","isDraft":false,"headRefName":"feature",
              "baseRefName":"main","url":"u","updatedAt":"2026-10-10T00:00:00Z",
              "additions":0,"deletions":0,"changedFiles":0,"isCrossRepository":false,"labels":[]}]
            """
            try Data(json.utf8).write(to: response)
            await repository.refreshPullRequests()
            XCTAssertEqual(repository.sidebarPullRequest(forBranch: "feature")?.state, state)
            XCTAssertNil(repository.sidebarPullRequest(forBranch: "main"))
            XCTAssertNil(repository.pullRequest(forBranch: "feature"))
            let linked = await forge.linkedPullRequest(branch: "feature", defaultBranch: "main", in: directory)
            XCTAssertEqual(linked?.state, state == "OPEN" ? state : nil, "历史请求不应占用评审入口")
        }
        try Data("[]".utf8).write(to: response)
        await repository.refreshWorktreePullRequests()
        XCTAssertNil(repository.sidebarPullRequest(forBranch: "feature"), "无关联请求时不应保留旧图标")
    }

    func testLinkedPullRequestIgnoresChangedOriginAndBranchAndClearsCachedModels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = directory.appendingPathComponent("started")
        let release = directory.appendingPathComponent("release")
        let response = directory.appendingPathComponent("response.json")
        let executable = directory.appendingPathComponent("gh")
        let json = """
        {"number":42,"title":"评审","state":"OPEN","isDraft":false,"headRefName":"feature",
         "baseRefName":"main","url":"u","updatedAt":"2026-10-07T00:00:00Z",
         "additions":0,"deletions":0,"changedFiles":0,"isCrossRepository":false,"labels":[]}
        """
        try Data(json.utf8).write(to: response)
        try Data(#"""
        #!/bin/sh
        : > "$GROVE_TEST_STARTED"
        count=0
        while [ ! -f "$GROVE_TEST_RELEASE" ]; do
          count=$((count + 1)); [ "$count" -lt 500 ] || exit 1
          sleep 0.01
        done
        cat "$GROVE_TEST_RESPONSE"
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var environment = ProcessInfo.processInfo.environment
        environment["GROVE_TEST_STARTED"] = started.path
        environment["GROVE_TEST_RELEASE"] = release.path
        environment["GROVE_TEST_RESPONSE"] = response.path
        let git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: directory)
        try await git.run(["config", "user.name", "测试"], in: directory)
        try await git.run(["config", "user.email", "test@example.invalid"], in: directory)
        try await git.run(["commit", "--allow-empty", "-qm", "初始提交"], in: directory)
        try await git.run(["remote", "add", "origin", "https://github.com/group/old.git"], in: directory)
        let oldOrigin = GitRemote.parse("https://github.com/group/old.git")
        let newOrigin = GitRemote.parse("https://github.com/group/new.git")
        let repository = RepositoryModel(root: directory, git: git, app: nil,
            forge: GitHubClient(executable: executable, environment: environment))
        repository.slug = "group/old"
        let model = WorktreeModel(worktree: Worktree(path: directory, head: nil, branch: "pr-42",
            isBare: false, isDetached: false, lockReason: nil, prunableReason: nil),
            repository: repository, git: git, app: nil)

        for changesOrigin in [true, false] {
            repository.origin = oldOrigin
            model.worktree.branch = "pr-42"
            let task = Task { await model.refreshLinkedPullRequest() }
            defer { task.cancel() }
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: started.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "关联查询未启动")
            if changesOrigin { repository.origin = newOrigin } else { model.worktree.branch = "other" }
            try Data().write(to: release)
            await task.value
            XCTAssertNil(model.linkedPullRequest)
            try FileManager.default.removeItem(at: started)
            try FileManager.default.removeItem(at: release)
        }

        try Data().write(to: release)
        model.worktree.branch = "pr-42"
        await model.refreshLinkedPullRequest()
        let request = try XCTUnwrap(model.linkedPullRequest)
        XCTAssertEqual(request.number, 42)
        // 仓库刷新时，未选中工作树中已缓存的关联也必须清掉。
        await repository.refresh(loadForgeMetadata: false)
        let cachedPath = try XCTUnwrap(repository.worktrees.first?.path)
        let cached = try XCTUnwrap(repository.worktreeModel(for: cachedPath))
        cached.linkedPullRequest = request
        try await git.run(["remote", "set-url", "origin", "https://github.com/group/new.git"], in: directory)
        await repository.refresh(loadForgeMetadata: false)
        XCTAssertNil(cached.linkedPullRequest)
    }

    func testForgeCachesIgnoreResultsFromPreviousOrigin() {
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:])
        let repository = RepositoryModel(root: URL(fileURLWithPath: "/tmp/project"), git: git, app: nil)
        let oldOrigin = GitRemote.parse("https://gitlab.com/group/old.git")
        repository.origin = GitRemote.parse("https://gitlab.com/group/new.git")
        var request = PullRequest(
            number: 1, title: "评审", state: "OPEN", isDraft: false,
            headRefName: "feature", baseRefName: "main", url: "u", author: nil,
            updatedAt: Date(), additions: 0, deletions: 0, changedFiles: 0,
            reviewDecision: nil, mergeable: nil, isCrossRepository: false,
            labels: [], statusCheckRollup: nil, body: nil, headRepositoryOwner: nil
        )
        repository.pullRequests = [request]
        repository.listPullRequests = [request]
        request.viewerHasApproved = true
        repository.mergeDetailIntoList(request, fromOrigin: oldOrigin)
        XCTAssertFalse(repository.listPullRequests[0].viewerHasApproved)
        let pipelines = [CIPipeline(id: 1, status: .success, ref: "main", sha: "old")]
        repository.updatePipelineStatuses(from: pipelines, fromOrigin: oldOrigin)
        XCTAssertTrue(repository.pipelineStatusByRef.isEmpty)

        repository.mergeDetailIntoList(request, fromOrigin: repository.origin)
        repository.updatePipelineStatuses(from: pipelines, fromOrigin: repository.origin)
        XCTAssertTrue(repository.listPullRequests[0].viewerHasApproved)
        XCTAssertEqual(repository.pipelineStatusByRef["main"], .success)
    }

    func testGitLabWriteUsesChangedOriginWithoutRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("requests.log")
        let executable = directory.appendingPathComponent("glab")
        let script = #"""
        #!/bin/sh
        case "$1" in
          config) exit 1 ;;
          api) printf '%s\n' "$2" >> "$GROVE_TEST_LOG"; printf '{}\n' ;;
          *) exit 1 ;;
        esac
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var environment = ProcessInfo.processInfo.environment
        environment["GROVE_TEST_LOG"] = log.path
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: environment)
        try await git.run(["init", "--quiet"], in: directory)
        try await git.run(["remote", "add", "origin", "git@gitlab.com:group/old.git"], in: directory)
        let client = GitLabClient(executable: executable, environment: environment)
        try await client.approve(number: 7, in: directory)
        try await git.run(["remote", "set-url", "origin", "git@gitlab.com:group/new.git"], in: directory)
        try await client.approve(number: 7, in: directory)
        let requests = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(requests, [
            "projects/group%2Fold/merge_requests/7/approve",
            "projects/group%2Fnew/merge_requests/7/approve"
        ])
    }

    func testGitHubMergePreservesOccupiedLocalBranchAndWorktree() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("repo")
        let worktree = directory.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = ProcessInfo.processInfo.environment
        environment["GROVE_TEST_REPOSITORY"] = "https://github.example.com/team/project"
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: environment)
        try await git.run(["init", "--quiet", "-b", "main"], in: root)
        try await git.run(["-c", "user.name=测试", "-c", "user.email=test@example.invalid",
                           "commit", "--allow-empty", "-m", "初始提交"], in: root)
        try await git.run(["worktree", "add", "-b", "feature/new-ui", worktree.path], in: root)
        let localFile = worktree.appendingPathComponent("local.txt")
        try Data("未提交的改动\n".utf8).write(to: localFile)

        let executable = directory.appendingPathComponent("gh")
        let script = #"""
        #!/bin/sh
        if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
          [ "$GROVE_TEST_FAIL" = "查询" ] && exit 2
          printf '%s\n' "$GROVE_TEST_REPOSITORY"
          exit 0
        fi
        if [ "$1" = "pr" ] && [ "$2" = "merge" ] && [ "$3" = "9" ]; then
          case "$4" in --squash|--merge|--rebase) ;; *) exit 2 ;; esac
          if [ "$GROVE_TEST_FAIL" = "合并" ]; then
            printf '合并被保护规则拒绝\n' >&2
            exit 3
          fi
          touch merged
          if [ "$5" = "--delete-branch" ]; then
            /usr/bin/git branch -D feature/new-ui
            exit $?
          fi
          if [ "$5" = "--repo" ] && [ "$6" = "$GROVE_TEST_REPOSITORY" ] && [ "$7" = "--delete-branch" ]; then
            touch remote-deleted
            exit 0
          fi
          [ "$#" -eq 4 ] && exit 0
        fi
        printf '非预期的命令\n' >&2
        exit 2
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let merged = root.appendingPathComponent("merged")
        let remoteDeleted = root.appendingPathComponent("remote-deleted")

        for strategy in MergeStrategy.allCases {
            let client = GitHubClient(executable: executable, environment: environment)
            try await client.merge(number: 9, strategy: strategy, deleteBranch: true, in: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: merged.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: remoteDeleted.path))
            try FileManager.default.removeItem(at: remoteDeleted)
            try await client.merge(number: 9, strategy: strategy, deleteBranch: false, in: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: remoteDeleted.path))
        }
        let branch = try await git.run(["branch", "--show-current"], in: worktree)
        XCTAssertEqual(branch.trimmingCharacters(in: .whitespacesAndNewlines), "feature/new-ui")
        XCTAssertEqual(try String(contentsOf: localFile, encoding: .utf8), "未提交的改动\n")
        let mainBranch = try await git.run(["branch", "--show-current"], in: root)
        XCTAssertEqual(mainBranch.trimmingCharacters(in: .whitespacesAndNewlines), "main")

        try FileManager.default.removeItem(at: merged)
        for failure in ["查询", "合并"] {
            environment["GROVE_TEST_FAIL"] = failure
            let client = GitHubClient(executable: executable, environment: environment)
            do {
                try await client.merge(number: 9, strategy: .squash, deleteBranch: true, in: root)
                XCTFail("查询或合并失败时必须保留错误")
            } catch let error as CommandFailure {
                XCTAssertEqual(error.exitCode, failure == "查询" ? 2 : 3)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: merged.path))
        }
    }

    func testForkCheckoutPreservesExistingLocalBranchCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("repo")
        let remote = directory.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: ProcessInfo.processInfo.environment)
        try await git.run(["init", "--quiet", "-b", "main"], in: root)
        try await git.run(["config", "user.name", "测试"], in: root)
        try await git.run(["config", "user.email", "test@example.invalid"], in: root)
        try Data("基础\n".utf8).write(to: root.appendingPathComponent("base.txt"))
        try await git.stageAll(in: root)
        try await git.commit(message: "初始提交", in: root)
        try await git.run(["clone", "--bare", root.path, remote.path], in: directory)
        try await git.run(["update-ref", "refs/pull/42/head", "HEAD"], in: remote)
        try await git.run(["remote", "add", "origin", remote.path], in: root)
        try await git.run(["checkout", "-b", "pr-42"], in: root)
        try Data("评审改动\n".utf8).write(to: root.appendingPathComponent("local.txt"))
        try await git.stageAll(in: root)
        try await git.commit(message: "保留的本地提交", in: root)
        let localHead = try await git.run(["rev-parse", "HEAD"], in: root)
        try await git.run(["checkout", "main"], in: root)
        let repository = RepositoryModel(root: root, git: git, app: nil)
        repository.worktrees = try await git.worktrees(in: root)
        let request = PullRequest(
            number: 42, title: "评审", state: "OPEN", isDraft: false,
            headRefName: "feature", baseRefName: "main", url: "u", author: nil,
            updatedAt: Date(), additions: 0, deletions: 0, changedFiles: 0,
            reviewDecision: nil, mergeable: nil, isCrossRepository: true,
            labels: [], statusCheckRollup: nil, body: nil, headRepositoryOwner: nil
        )
        let worktree = await repository.createWorktree(forPullRequest: request)
        XCTAssertNotNil(worktree)
        let branchHead = try await git.run(["rev-parse", "pr-42"], in: root)
        XCTAssertEqual(branchHead, localHead)
        if let worktree {
            let checkedOutHead = try await git.run(["rev-parse", "HEAD"], in: worktree.path)
            XCTAssertEqual(checkedOutHead, localHead)
        }
    }
}
