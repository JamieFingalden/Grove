import SwiftUI
import XCTest
@testable import Grove

/// GitLab Merge Request 的解码和映射。
///
/// 用的是从 gitlab.com 真实接口抓下来的数据（裁剪掉了超长的 description）。
/// 手写的假数据测不出真正的坑 —— 比如时间戳带毫秒、标签颜色带 `#`、
/// `changes_count` 有时是数字有时是字符串，这些都是照着文档写代码时想不到的。
final class GitLabMergeRequestTests: XCTestCase {
    /// `glab api "projects/:id/merge_requests?with_labels_details=true"` 的真实输出。
    private let listJSON = """
    [
      {
        "iid": 252497,
        "title": "Document Offline Transfer recovery path",
        "state": "opened",
        "draft": false,
        "source_branch": "jnutt/622286-document-ot-recovery-path",
        "target_branch": "master",
        "web_url": "https://gitlab.com/gitlab-org/gitlab/-/merge_requests/252497",
        "author": { "username": "jnutt", "name": "James Nutt" },
        "updated_at": "2026-08-28T13:04:02.802Z",
        "created_at": "2026-08-28T13:02:39.730Z",
        "merge_status": "can_be_merged",
        "detailed_merge_status": "ci_still_running",
        "has_conflicts": false,
        "source_project_id": 278964,
        "target_project_id": 278964,
        "labels": [
          { "name": "Category:Importers", "color": "#428BCA" },
          { "name": "Importer:Offline Transfer", "color": "#cc338b" }
        ],
        "user_notes_count": 0,
        "description": "略"
      }
    ]
    """

    private func decodeList() throws -> [GitLabMergeRequest] {
        try GitLabClient.decoder.decode([GitLabMergeRequest].self, from: Data(listJSON.utf8))
    }

    func testDecodesRealListPayload() throws {
        let merges = try decodeList()
        XCTAssertEqual(merges.count, 1)
        let merge = merges[0]
        XCTAssertEqual(merge.iid, 252497)
        XCTAssertEqual(merge.sourceBranch, "jnutt/622286-document-ot-recovery-path")
        XCTAssertEqual(merge.targetBranch, "master")
        XCTAssertEqual(merge.author?.username, "jnutt")
        XCTAssertFalse(merge.isCrossProject)
    }

    /// GitLab 的时间戳带毫秒（`...T13:04:02.802Z`），GitHub 的不带。
    /// 解码器必须两种都能吃 —— 差一个小数点就是「一个 MR 都读不出来」。
    func testTimestampsWithAndWithoutFractionalSecondsBothDecode() throws {
        let merge = try decodeList()[0]
        XCTAssertNotNil(merge.updatedAt)
        XCTAssertNotNil(merge.createdAt)

        struct Probe: Decodable { var at: Date }
        for sample in ["2026-08-28T13:04:02.802Z", "2026-08-27T14:03:09Z", "2026-08-28T13:04:02.802+08:00"] {
            let json = Data("{\"at\":\"\(sample)\"}".utf8)
            XCTAssertNoThrow(
                try GitLabClient.decoder.decode(Probe.self, from: json),
                "解不出 \(sample)"
            )
        }
    }

    func testMapsToPullRequest() throws {
        let pullRequest = try decodeList()[0].asPullRequest()

        XCTAssertEqual(pullRequest.number, 252497)
        XCTAssertEqual(pullRequest.forge, .gitlab)
        // GitLab 社区写 `!123`，不是 `#123`。
        XCTAssertEqual(pullRequest.displayNumber, "!252497")
        XCTAssertEqual(pullRequest.status, .open)
        XCTAssertEqual(pullRequest.headRefName, "jnutt/622286-document-ot-recovery-path")
        XCTAssertEqual(pullRequest.mergeable, "MERGEABLE")
        XCTAssertEqual(pullRequest.labels.count, 2)
        XCTAssertEqual(pullRequest.labels[0].name, "Category:Importers")
    }

    func testLabelColorWithHashStillParses() throws {
        let pullRequest = try decodeList()[0].asPullRequest()
        // GitLab 给的颜色带 `#`，GitHub 不带。渲染层要能同时吃下两种。
        XCTAssertEqual(pullRequest.labels[0].color, "#428BCA")
        XCTAssertNotNil(Color(hex: pullRequest.labels[0].color))
        XCTAssertNotNil(Color(hex: "428BCA"))
    }

    // MARK: - 状态映射

    func testStateMapping() {
        XCTAssertEqual(GitLabMergeRequest.normalizedState("opened"), "OPEN")
        XCTAssertEqual(GitLabMergeRequest.normalizedState("merged"), "MERGED")
        XCTAssertEqual(GitLabMergeRequest.normalizedState("closed"), "CLOSED")
        // `locked` 是合并过程中的临时状态，对用户来说它还开着。
        XCTAssertEqual(GitLabMergeRequest.normalizedState("locked"), "OPEN")
    }

    func testDraftReadsBothOldAndNewFieldNames() throws {
        // 老版本 GitLab 只有 work_in_progress，新版本才加的 draft。
        // 自建实例落后几个大版本很常见，只认新字段会把草稿显示成正常 MR。
        let json = """
        [{"iid":1,"title":"t","state":"opened","work_in_progress":true,
          "source_branch":"a","target_branch":"b","web_url":"u"}]
        """
        let merge = try GitLabClient.decoder.decode([GitLabMergeRequest].self, from: Data(json.utf8))[0]
        XCTAssertTrue(merge.isDraft)
        XCTAssertEqual(merge.asPullRequest().status, .draft)
    }

    func testConflictsOverrideMergeStatus()  {
        XCTAssertEqual(
            GitLabMergeRequest.mergeable(status: "can_be_merged", hasConflicts: true),
            "CONFLICTING"
        )
        XCTAssertEqual(GitLabMergeRequest.mergeable(status: "checking", hasConflicts: false), "UNKNOWN")
        XCTAssertEqual(GitLabMergeRequest.mergeable(status: "cannot_be_merged", hasConflicts: nil), "CONFLICTING")
    }

    func testChangesCountAcceptsIntStringAndCapped() throws {
        func decode(_ raw: String) throws -> Int {
            let json = """
            [{"iid":1,"title":"t","state":"opened","source_branch":"a","target_branch":"b",
              "web_url":"u","changes_count":\(raw)}]
            """
            let merge = try GitLabClient.decoder.decode([GitLabMergeRequest].self, from: Data(json.utf8))[0]
            return merge.changesCount?.value ?? -1
        }
        XCTAssertEqual(try decode("6"), 6)
        XCTAssertEqual(try decode("\"6\""), 6)
        // 超过上限时 GitLab 返回 "1000+"，硬转 Int 会崩或归零。
        XCTAssertEqual(try decode("\"1000+\""), 1000)
    }

    func testCrossProjectDetection() throws {
        let json = """
        [{"iid":1,"title":"t","state":"opened","source_branch":"a","target_branch":"b",
          "web_url":"u","source_project_id":11,"target_project_id":22}]
        """
        let merge = try GitLabClient.decoder.decode([GitLabMergeRequest].self, from: Data(json.utf8))[0]
        XCTAssertTrue(merge.isCrossProject)
        // fork 来的 MR 检出时要用 pr-<编号> 分支名，不能沿用对方的源分支名。
        XCTAssertEqual(PullRequestNaming.branchName(for: merge.asPullRequest()), "pr-1")
    }

    // MARK: - CI 与审批

    func testPipelineCollapsesToSingleCheckWhenJobsUnknown() {
        let pipeline = GitLabPipeline(id: 1, status: "running", webUrl: "https://x")
        let checks = GitLabMergeRequest.checks(pipeline: pipeline, jobs: nil)
        XCTAssertEqual(checks?.count, 1)
        XCTAssertEqual(checks?[0].outcome, .pending)
        XCTAssertEqual(checks?[0].displayName, "流水线")
    }

    func testAllowFailureJobDoesNotCountAsFailure() {
        // GitLab 里「允许失败」的任务挂了不阻塞合并。当成失败的话，
        // 大量使用可选任务的项目会永远显示红色。
        let jobs = [
            GitLabJob(id: 1, name: "test", stage: "test", status: "success", webUrl: nil, allowFailure: false),
            GitLabJob(id: 2, name: "lint", stage: "test", status: "failed", webUrl: nil, allowFailure: true)
        ]
        let checks = GitLabMergeRequest.checks(pipeline: nil, jobs: jobs) ?? []
        XCTAssertEqual(checks.count, 2)
        XCTAssertEqual(checks[1].outcome, .skipped)

        let pullRequest = PullRequest(
            number: 1, title: "t", state: "OPEN", isDraft: false, headRefName: "a",
            baseRefName: "b", url: "u", author: nil, updatedAt: Date(), additions: 0,
            deletions: 0, changedFiles: 0, reviewDecision: nil, mergeable: nil,
            isCrossRepository: false, labels: [], statusCheckRollup: checks,
            body: nil, headRepositoryOwner: nil, forge: .gitlab
        )
        XCTAssertFalse(pullRequest.checks.isFailing)
    }

    func testApprovalsDriveReviewDecision() throws {
        let approved = GitLabApprovals(
            approvalsRequired: 1, approvalsLeft: 0, approvedBy: nil,
            userHasApproved: true, userCanApprove: false
        )
        XCTAssertEqual(GitLabMergeRequest.reviewDecision(approvals: approved, detailedStatus: nil), "APPROVED")
        XCTAssertTrue(try decodeList()[0].asPullRequest(approvals: approved).viewerHasApproved)

        let pending = GitLabApprovals(
            approvalsRequired: 2, approvalsLeft: 2, approvedBy: [],
            userHasApproved: false, userCanApprove: true
        )
        XCTAssertEqual(GitLabMergeRequest.reviewDecision(approvals: pending, detailedStatus: nil), "REVIEW_REQUIRED")
    }

    func testFallsBackToDetailedMergeStatusWhenApprovalsUnavailable() {
        // 列表视图不逐个拉审批接口（那会变成几十个请求），
        // 退回用 detailed_merge_status 给个粗略信号。
        XCTAssertEqual(
            GitLabMergeRequest.reviewDecision(approvals: nil, detailedStatus: "not_approved"),
            "REVIEW_REQUIRED"
        )
        XCTAssertNil(GitLabMergeRequest.reviewDecision(approvals: nil, detailedStatus: "ci_still_running"))
    }
}

/// 托管商相关的共用逻辑。
final class ForgeTests: XCTestCase {
    func testGitLabAuthenticationAcceptsOneWorkingHost() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("glab")
        let script = """
        #!/bin/sh
        if [ "$1" = "auth" ] && [ "$2" = "status" ] && [ "$3" = "--hostname" ]; then
          [ "$4" = "192.168.251.253" ]
          exit $?
        fi
        printf 'gitlab.com\n192.168.251.253\n' >&2
        exit 1
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = GitLabClient(executable: executable, environment: ProcessInfo.processInfo.environment)

        // 全局状态因 gitlab.com 未登录而失败，但内网主机可用时不应禁用全部 GitLab 功能。
        let isAuthenticated = await client.isAuthenticated()
        XCTAssertTrue(isAuthenticated)
    }

    func testGitLabResolvesRepositoryWhenRemotePortDiffersFromAuthHost() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let git = URL(fileURLWithPath: "/usr/bin/git")
        try await ProcessRunner.runChecked(executable: git, arguments: ["init", "--quiet"], workingDirectory: directory)
        try await ProcessRunner.runChecked(
            executable: git,
            arguments: [
                "remote", "add", "origin",
                "http://192.168.251.253:8929/cad_pic_llm/cad_llms_group.git"
            ],
            workingDirectory: directory
        )

        let executable = directory.appendingPathComponent("glab")
        let script = """
        #!/bin/sh
        if [ "$1" = "config" ] && [ "$2" = "get" ]; then
          if [ "$5" = "192.168.251.253" ]; then
            printf '192.168.251.253:8929\n'
          fi
          exit 0
        fi
        if [ "$1" = "api" ] && [ "$2" = "projects/cad_pic_llm%2Fcad_llms_group" ] && [ "$GITLAB_HOST" = "192.168.251.253" ]; then
          printf '{"path_with_namespace":"cad_pic_llm/cad_llms_group"}\n'
          exit 0
        fi
        if [ "$1" = "api" ] && [ "$2" = "projects/cad_pic_llm%2Fcad_llms_group/merge_requests/589/approve" ] && [ "$3" = "--method" ] && [ "$4" = "POST" ] && [ "$GITLAB_HOST" = "192.168.251.253" ]; then
          printf '{}\n'
          exit 0
        fi
        if [ "$1" = "api" ] && [ "$2" = "projects/cad_pic_llm%2Fcad_llms_group/merge_requests/589/raw_diffs" ] && [ "$GITLAB_HOST" = "192.168.251.253" ]; then
          printf 'diff --git a/old.txt b/new.txt\nrename from old.txt\nrename to new.txt\n--- a/old.txt\n+++ b/new.txt\n@@ -1 +1 @@\n-old\n+new\n'
          exit 0
        fi
        if [ "$1" = "api" ] && [ "$2" = "projects/cad_pic_llm%2Fcad_llms_group/merge_requests/588/raw_diffs" ]; then
          printf 'glab: HTTP 404\n' >&2
          exit 1
        fi
        if [ "$1" = "api" ] && [ "$2" = "projects/cad_pic_llm%2Fcad_llms_group/merge_requests/588/changes?access_raw_diffs=true" ]; then
          printf '%s\n' '{"changes":[{"old_path":"Sources/旧 文件.swift","new_path":"Sources/新 文件.swift","diff":"@@ -1 +1 @@\\n-old\\n+new\\n","new_file":false,"deleted_file":false,"renamed_file":true,"a_mode":"100644","b_mode":"100755"}]}'
          exit 0
        fi
        if [ "$1" = "api" ] && [ "$2" = "projects/cad_pic_llm%2Fcad_llms_group/merge_requests" ] && [ "$3" = "--method" ] && [ "$4" = "POST" ] && [ "$5" = "--raw-field" ] && [ "$6" = "description=说明" ] && [ "$7" = "--raw-field" ] && [ "$8" = "source_branch=xf-dev" ] && [ "$9" = "--raw-field" ] && [ "${10}" = "target_branch=main" ] && [ "${11}" = "--raw-field" ] && [ "${12}" = "title=Draft: 新功能" ] && [ "$GITLAB_HOST" = "192.168.251.253" ]; then
          printf '{"iid":590,"title":"Draft: 新功能","state":"opened","draft":true,"source_branch":"xf-dev","target_branch":"main","web_url":"http://192.168.251.253:8929/cad_pic_llm/cad_llms_group/-/merge_requests/590"}\n'
          exit 0
        fi
        if [ "$1" = "mr" ] && [ "$2" = "merge" ] && [ "$3" = "587" ] && [ "$4" = "--yes" ] && [ "$5" = "--squash" ] && [ "$6" = "--remove-source-branch" ] && [ "$7" = "--auto-merge=false" ] && [ "$8" = "--repo" ] && [ "$9" = "cad_pic_llm/cad_llms_group" ] && [ "$GITLAB_HOST" = "192.168.251.253" ]; then
          exit 0
        fi
        exit 2
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let client = GitLabClient(executable: executable, environment: ProcessInfo.processInfo.environment)

        // 远程带 8929 端口、认证主机不带端口时，仍要能识别完整项目路径。
        let slug = await client.repositorySlug(in: directory)
        XCTAssertEqual(slug, "cad_pic_llm/cad_llms_group")
        try await client.approve(number: 589, in: directory)
        let diff = try await client.pullRequestDiff(number: 589, in: directory)
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff[0].oldPath, "old.txt")
        XCTAssertEqual(diff[0].newPath, "new.txt")
        XCTAssertTrue(diff[0].isRename)
        XCTAssertEqual(diff[0].additions, 1)
        XCTAssertEqual(diff[0].deletions, 1)
        let legacyDiff = try await client.pullRequestDiff(number: 588, in: directory)
        XCTAssertEqual(legacyDiff.count, 1)
        XCTAssertEqual(legacyDiff[0].oldPath, "Sources/旧 文件.swift")
        XCTAssertEqual(legacyDiff[0].newPath, "Sources/新 文件.swift")
        XCTAssertTrue(legacyDiff[0].isRename)
        XCTAssertEqual(legacyDiff[0].oldMode, "100644")
        XCTAssertEqual(legacyDiff[0].newMode, "100755")
        XCTAssertEqual(legacyDiff[0].additions, 1)
        XCTAssertEqual(legacyDiff[0].deletions, 1)
        try await client.merge(number: 587, strategy: .squash, deleteBranch: true, in: directory)
        let createdURL = try await client.createPullRequest(
            NewPullRequest(
                title: "新功能", body: "说明", base: "main", head: "xf-dev", isDraft: true
            ),
            in: directory
        )
        XCTAssertEqual(
            createdURL,
            "http://192.168.251.253:8929/cad_pic_llm/cad_llms_group/-/merge_requests/590"
        )
    }

    func testRefspecsMatchEachPlatform() {
        // 两个平台都提供一个只读的服务端 ref 指向请求的头提交，
        // 走它才能检出 fork / 跨仓库来的改动 —— 我们对对方仓库没有权限。
        XCTAssertEqual(
            ForgeKind.github.headRefspec(number: 42, localBranch: "pr-42"),
            "+refs/pull/42/head:refs/heads/pr-42"
        )
        XCTAssertEqual(
            ForgeKind.gitlab.headRefspec(number: 42, localBranch: "pr-42"),
            "+refs/merge-requests/42/head:refs/heads/pr-42"
        )
    }

    func testTerminologyDiffersPerPlatform() {
        // GitLab 用户不认识「Pull Request」这个说法，反之亦然。
        XCTAssertEqual(ForgeKind.github.numberPrefix, "#")
        XCTAssertEqual(ForgeKind.gitlab.numberPrefix, "!")
        XCTAssertEqual(ForgeKind.gitlab.termLong, "合并请求")
    }

    func testAuthStatusParsingPicksHostsOnly() {
        // gh 和 glab 的 auth status 输出格式碰巧一致：主机名顶格，详情缩进。
        let output = """
        github.com
          ✓ Logged in to github.com account jamie (keyring)
          - Active account: true
        10.0.0.1:8929
          ✓ Token: glpat-****

           ERROR

          X could not authenticate to one or more of the configured GitLab instances.
        """
        let hosts = AuthStatusParser.hosts(in: output)
        XCTAssertEqual(hosts, ["github.com", "10.0.0.1:8929"])
        // "ERROR" 和那句英文提示都不能被当成主机名。
        XCTAssertFalse(hosts.contains("error"))
    }

    func testGlabConfigHostParsingStaysLocalAndIgnoresTokens() {
        let config = """
        hosts:
          gitlab.com:
            token: glpat-secret
          "192.168.251.253":
            api_host: 192.168.251.253:8929
            token: another-secret
        check_update: false
        """
        XCTAssertEqual(
            GitLabClient.configuredHosts(fromConfig: config),
            ["gitlab.com", "192.168.251.253"]
        )
    }

    func testHostMatchingHandlesPortedInstances() {
        // 内网 GitLab 常见 `http://10.0.0.1:8929`，而 glab 的配置键可能带端口
        // 也可能不带（取决于登录时 --hostname 怎么写）。两种都要能匹配上，
        // 否则这台实例永远认不出来、评审功能一直是灰的。
        let remote = GitRemote.parse("http://10.0.0.1:8929/internal-group/internal-repo.git")
        XCTAssertNotNil(remote)
        XCTAssertTrue(remote!.matchesHost("10.0.0.1"))
        XCTAssertTrue(remote!.matchesHost("10.0.0.1:8929"))
        XCTAssertFalse(remote!.matchesHost("10.0.0.2"))
        XCTAssertEqual(remote?.hostWithPort, "10.0.0.1:8929")
    }
}
