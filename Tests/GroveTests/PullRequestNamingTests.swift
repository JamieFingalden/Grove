import XCTest
@testable import Grove

/// 工作树分支名 ↔ PR 的对应关系。这是 Grove 主线功能的接缝处，
/// 生成和反查两侧必须始终对得上。
final class PullRequestNamingTests: XCTestCase {
    private func makePullRequest(
        number: Int,
        headRefName: String,
        isCrossRepository: Bool,
        state: String = "OPEN",
        isDraft: Bool = false,
        updatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) -> PullRequest {
        PullRequest(
            number: number, title: "t", state: state, isDraft: isDraft,
            headRefName: headRefName, baseRefName: "main", url: "u", author: nil,
            updatedAt: updatedAt, additions: 0, deletions: 0, changedFiles: 0,
            reviewDecision: nil, mergeable: nil, isCrossRepository: isCrossRepository,
            labels: [], statusCheckRollup: nil, body: nil, headRepositoryOwner: nil
        )
    }

    func testSameRepoPullRequestKeepsItsBranchName() {
        let pullRequest = makePullRequest(number: 42, headRefName: "feature/login", isCrossRepository: false)
        // 沿用原分支名才能跟远端建立跟踪关系，改完能直接推回去。
        XCTAssertEqual(PullRequestNaming.branchName(for: pullRequest), "feature/login")
    }

    func testForkPullRequestGetsNumberedBranchName() {
        let pullRequest = makePullRequest(number: 42, headRefName: "main", isCrossRepository: true)
        // fork 的头分支常常就叫 main —— 沿用会跟本地 main 撞名，而且我们对
        // 对方的 fork 没有写权限，用原名只会造成误解。
        XCTAssertEqual(PullRequestNaming.branchName(for: pullRequest), "pr-42")
    }

    func testNumberRoundTripsFromGeneratedBranchName() {
        let pullRequest = makePullRequest(number: 14264, headRefName: "whatever", isCrossRepository: true)
        let branch = PullRequestNaming.branchName(for: pullRequest)
        XCTAssertEqual(PullRequestNaming.number(fromBranch: branch), 14264)
    }

    func testOrdinaryBranchNamesAreNotMistakenForPullRequestNumbers() {
        // `pr-` 开头的正常功能分支不能被当成 PR 编号，否则会去查一个不存在的 PR。
        XCTAssertNil(PullRequestNaming.number(fromBranch: "pr-fix-login"))
        XCTAssertNil(PullRequestNaming.number(fromBranch: "pr-"))
        XCTAssertNil(PullRequestNaming.number(fromBranch: "feature/login"))
        XCTAssertNil(PullRequestNaming.number(fromBranch: "preview-42"))
        XCTAssertEqual(PullRequestNaming.number(fromBranch: "pr-7"), 7)
    }

    // MARK: - 同分支多个 PR 时挑哪个

    func testOpenPullRequestWinsOverClosedOne() {
        let closed = makePullRequest(
            number: 1, headRefName: "feature", isCrossRepository: false,
            state: "CLOSED", updatedAt: Date(timeIntervalSinceReferenceDate: 9_000)
        )
        let open = makePullRequest(
            number: 2, headRefName: "feature", isCrossRepository: false,
            state: "OPEN", updatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )

        // 就算已关闭的那个更新时间更近，正在评审的才是用户关心的。
        XCTAssertEqual(GitHubClient.mostRelevant(of: [closed, open])?.number, 2)
    }

    func testDraftBeatsMergedAndClosed() {
        let merged = makePullRequest(number: 1, headRefName: "f", isCrossRepository: false, state: "MERGED")
        let draft = makePullRequest(number: 2, headRefName: "f", isCrossRepository: false, isDraft: true)
        XCTAssertEqual(GitHubClient.mostRelevant(of: [merged, draft])?.number, 2)
    }

    func testAmongSameStateTheMostRecentWins() {
        let older = makePullRequest(
            number: 1, headRefName: "f", isCrossRepository: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        let newer = makePullRequest(
            number: 2, headRefName: "f", isCrossRepository: false,
            updatedAt: Date(timeIntervalSinceReferenceDate: 9_000)
        )
        XCTAssertEqual(GitHubClient.mostRelevant(of: [older, newer])?.number, 2)
    }

    func testEmptyListYieldsNil() {
        XCTAssertNil(GitHubClient.mostRelevant(of: []))
    }
}
