import XCTest
@testable import Grove

final class PullRequestDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> [PullRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PullRequest].self, from: Data(json.utf8))
    }

    /// 取自 `gh pr list --repo cli/cli --json ...` 的真实输出（裁剪过）。
    func testDecodesRealGhOutput() throws {
        let json = """
        [{
          "additions": 3,
          "author": {"is_bot": true, "login": "app/dependabot"},
          "baseRefName": "trunk",
          "changedFiles": 2,
          "createdAt": "2026-08-27T13:01:02Z",
          "deletions": 3,
          "headRefName": "dependabot/go_modules/bubbles",
          "headRepositoryOwner": {"login": "cli"},
          "isCrossRepository": false,
          "isDraft": false,
          "labels": [{"name": "dependencies", "color": "0366d6"}],
          "mergeable": "MERGEABLE",
          "number": 14275,
          "reviewDecision": "REVIEW_REQUIRED",
          "state": "OPEN",
          "title": "Bump bubbles from 2.2.0 to 2.2.1",
          "updatedAt": "2026-08-27T14:03:09Z",
          "url": "https://github.com/cli/cli/pull/14275",
          "statusCheckRollup": [
            {"__typename": "CheckRun", "conclusion": "SUCCESS", "name": "lint",
             "status": "COMPLETED", "workflowName": "Lint",
             "detailsUrl": "https://github.com/cli/cli/actions/runs/1/job/2"},
            {"__typename": "CheckRun", "conclusion": "SKIPPED", "name": "label-external",
             "status": "COMPLETED", "workflowName": "PR Triaging"}
          ]
        }]
        """

        let pullRequests = try decode(json)

        XCTAssertEqual(pullRequests.count, 1)
        let pullRequest = pullRequests[0]
        XCTAssertEqual(pullRequest.number, 14275)
        XCTAssertEqual(pullRequest.status, .open)
        XCTAssertEqual(pullRequest.review, .pending)
        // gh 这个字段是蛇形命名，跟同一份 JSON 里其他字段的驼峰不一致 ——
        // 不显式映射的话机器人 PR 会被当成普通用户。
        XCTAssertEqual(pullRequest.author?.isBot, true)
        // 机器人的 login 形如 `app/dependabot`，展示时要去掉前缀。
        XCTAssertEqual(pullRequest.author?.displayName, "dependabot")
        XCTAssertEqual(pullRequest.headRepositoryOwner?.login, "cli")
        XCTAssertEqual(pullRequest.listTimestamp, Date(timeIntervalSince1970: 1_787_835_662))
    }

    func testFutureRelativeDateIsClampedToNow() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            RelativeDate.normalizedForDisplay(Date(timeIntervalSince1970: 1_015), now: now),
            now
        )
    }

    func testDraftAndMergedStatesOverrideOpen() throws {
        let json = """
        [
         {"number":1,"title":"草稿","state":"OPEN","isDraft":true,"headRefName":"a","baseRefName":"main",
          "url":"u","updatedAt":"2026-08-27T14:03:09Z","additions":0,"deletions":0,"changedFiles":0,
          "isCrossRepository":false,"labels":[]},
         {"number":2,"title":"已合并","state":"MERGED","isDraft":false,"headRefName":"b","baseRefName":"main",
          "url":"u","updatedAt":"2026-08-27T14:03:09Z","additions":0,"deletions":0,"changedFiles":0,
          "isCrossRepository":false,"labels":[]}
        ]
        """

        let pullRequests = try decode(json)
        // 草稿在 GitHub 那边 state 仍然是 OPEN，得靠 isDraft 区分 ——
        // 不区分的话草稿会显示成可合并，而 GitHub 会拒绝。
        XCTAssertEqual(pullRequests[0].status, .draft)
        XCTAssertEqual(pullRequests[1].status, .merged)
        XCTAssertTrue(pullRequests[0].isActive)
        XCTAssertFalse(pullRequests[1].isActive)
    }

    func testMissingOptionalFieldsDecodeCleanly() throws {
        // 没人被要求评审时 reviewDecision 是 null；没 CI 时没有 statusCheckRollup。
        let json = """
        [{"number":9,"title":"极简","state":"OPEN","isDraft":false,"headRefName":"x","baseRefName":"main",
          "url":"u","updatedAt":"2026-08-27T14:03:09Z","additions":1,"deletions":0,"changedFiles":1,
          "reviewDecision":null,"isCrossRepository":false,"labels":[]}]
        """

        let pullRequest = try decode(json)[0]
        XCTAssertEqual(pullRequest.review, .none)
        XCTAssertNil(pullRequest.review.label)
        XCTAssertEqual(pullRequest.checks, .none)
        XCTAssertNil(pullRequest.author)
    }

    func testStatusContextShapeIsUnderstood() throws {
        // 老式的第三方状态服务走 StatusContext，字段名跟 CheckRun 完全不同。
        // 两种形状必须都能读出结论，否则 CI 状态会显示成「无」。
        let json = """
        [{"number":3,"title":"t","state":"OPEN","isDraft":false,"headRefName":"x","baseRefName":"main",
          "url":"u","updatedAt":"2026-08-27T14:03:09Z","additions":0,"deletions":0,"changedFiles":0,
          "isCrossRepository":false,"labels":[],
          "statusCheckRollup":[
            {"__typename":"StatusContext","context":"ci/jenkins","state":"FAILURE",
             "targetUrl":"https://ci.example.com/1"}
          ]}]
        """

        let pullRequest = try decode(json)[0]
        XCTAssertEqual(pullRequest.statusCheckRollup?.first?.outcome, .failure)
        XCTAssertEqual(pullRequest.statusCheckRollup?.first?.displayName, "ci/jenkins")
        XCTAssertTrue(pullRequest.checks.isFailing)
    }
}

final class CheckRollupTests: XCTestCase {
    fileprivate func check(status: String? = "COMPLETED", conclusion: String?) -> StatusCheck {
        StatusCheck(
            __typename: "CheckRun", name: "test", status: status, conclusion: conclusion,
            detailsUrl: nil, workflowName: nil, context: nil, state: nil, targetUrl: nil
        )
    }

    private func pullRequest(with checks: [StatusCheck]) -> PullRequest {
        PullRequest(
            number: 1, title: "t", state: "OPEN", isDraft: false,
            headRefName: "h", baseRefName: "b", url: "u", author: nil,
            updatedAt: Date(), additions: 0, deletions: 0, changedFiles: 0,
            reviewDecision: nil, mergeable: nil, isCrossRepository: false,
            labels: [], statusCheckRollup: checks, body: nil, headRepositoryOwner: nil
        )
    }

    func testAnyFailureDominates() {
        // 一个失败就该报失败，哪怕其他全绿 —— 合并前用户最需要知道的就是这个。
        let rollup = pullRequest(with: [
            check(conclusion: "SUCCESS"),
            check(conclusion: "FAILURE"),
            check(conclusion: "SUCCESS")
        ]).checks

        XCTAssertTrue(rollup.isFailing)
        XCTAssertEqual(rollup.label, "1/3 项检查失败")
    }

    func testRunningBeatsPassingWhenNothingFailed() {
        let rollup = pullRequest(with: [
            check(conclusion: "SUCCESS"),
            check(status: "IN_PROGRESS", conclusion: nil)
        ]).checks

        XCTAssertEqual(rollup.label, "检查中 1/2")
    }

    func testSkippedChecksDoNotCountAsFailure() {
        // SKIPPED / NEUTRAL 是「没跑」，不是「跑挂了」。当成失败的话
        // 大量用了条件跳过的仓库会永远显示红色。
        let rollup = pullRequest(with: [
            check(conclusion: "SUCCESS"),
            check(conclusion: "SKIPPED"),
            check(conclusion: "NEUTRAL")
        ]).checks

        XCTAssertFalse(rollup.isFailing)
        XCTAssertEqual(rollup.label, "1 项检查通过")
    }

    func testCancelledAndTimedOutCountAsFailure() {
        XCTAssertEqual(check(conclusion: "CANCELLED").outcome, .failure)
        XCTAssertEqual(check(conclusion: "TIMED_OUT").outcome, .failure)
        XCTAssertEqual(check(conclusion: "ACTION_REQUIRED").outcome, .failure)
    }

    func testIncompleteCheckRunIsPendingRegardlessOfConclusion() {
        // 还没跑完就没有结论可言。GitHub 偶尔会在 QUEUED 状态下带一个陈旧的
        // conclusion，信它会显示成已完成。
        XCTAssertEqual(check(status: "QUEUED", conclusion: "SUCCESS").outcome, .pending)
    }
}
