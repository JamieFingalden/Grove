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
        XCTAssertNotNil(repository.pullRequestLoadError)
        try FileManager.default.removeItem(at: failure)
        await repository.refreshPullRequests()
        XCTAssertTrue(repository.hasLoadedPullRequests)
        XCTAssertNil(repository.pullRequestLoadError)
    }
}
