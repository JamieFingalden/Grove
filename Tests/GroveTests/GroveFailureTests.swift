import XCTest
@testable import Grove

final class GroveFailureTests: XCTestCase {
    @MainActor
    func testPullRequestReadFailureIdentifiesRepository() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("gh")
        try Data("#!/bin/sh\nprintf 'repository not found\\n' >&2\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let app = AppModel()
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:])
        let forge = GitHubClient(executable: executable, environment: ProcessInfo.processInfo.environment)
        let repository = RepositoryModel(root: directory, git: git, app: app, forge: forge)
        repository.slug = "group/project"

        await repository.refreshPullRequests()
        await repository.refreshPullRequests()

        XCTAssertEqual(app.failures.count, 1)
        XCTAssertEqual(app.failures.first?.title, "读取 PR 列表失败")
        XCTAssertEqual(app.failures.first?.context, "\(repository.name) · 本机 · \(repository.root.path)")
    }

    @MainActor
    func testRepositoryFailuresKeepContextAndDoNotStackDuplicates() {
        let app = AppModel()
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:])
        let repository = RepositoryModel(
            root: URL(fileURLWithPath: "/tmp/grove-notification/first/Grove"), git: git, app: app
        )
        let otherRepository = RepositoryModel(
            root: URL(fileURLWithPath: "/tmp/grove-notification/second/Grove"), git: git, app: app
        )
        let error = commandFailure("unexpected failure")

        app.report(title: "读取 PR 列表失败", error: error, repository: repository)
        app.report(title: "读取 PR 列表失败", error: error, repository: repository)
        XCTAssertEqual(app.failures.count, 1)
        XCTAssertEqual(app.failures.first?.context, "Grove · 本机 · \(repository.root.path)")

        app.report(title: "读取 PR 列表失败", error: error, repository: otherRepository)
        XCTAssertEqual(app.failures.count, 2)
        XCTAssertEqual(app.failures.last?.context, "Grove · 本机 · \(otherRepository.root.path)")

        app.report(title: "读取 PR 列表失败", error: commandFailure("different failure"), repository: repository)
        XCTAssertEqual(app.failures.count, 3)

        app.dismiss(app.failures[0])
        app.report(title: "读取 PR 列表失败", error: error, repository: repository)
        XCTAssertEqual(app.failures.count, 3)

        app.failures.removeAll()
        for host in ["first.example", "second.example"] {
            let remote = RepositoryModel(
                root: repository.root, git: git, app: app,
                server: RemoteServer(alias: "Ubuntu", host: host)
            )
            app.report(title: "读取 PR 列表失败", error: error, repository: remote)
        }
        XCTAssertEqual(app.failures.count, 2)
        XCTAssertNotEqual(app.failures[0].repositoryID, app.failures[1].repositoryID)
        XCTAssertTrue(app.failures[0].context?.contains("first.example") == true)
        XCTAssertTrue(app.failures[1].context?.contains("second.example") == true)
    }

    @MainActor
    func testFailureContextSeparatesRequestsAndSettingsWithoutUsingSelection() {
        let app = AppModel()
        let git = GitClient(executable: URL(fileURLWithPath: "/usr/bin/git"), environment: [:])
        let repository = RepositoryModel(root: URL(fileURLWithPath: "/tmp/Grove"), git: git, app: app)
        for number in [1, 2, 2] {
            app.report(title: "AI Review 失败", error: commandFailure("unexpected failure"),
                       repository: repository, context: "PR #\(number) · 读取差异")
        }
        XCTAssertEqual(app.failures.count, 2)
        XCTAssertEqual(app.failures.last?.context, "Grove · 本机 · \(repository.root.path)\nPR #2 · 读取差异")

        app.report(title: "保存密钥失败", error: commandFailure("unexpected failure"), context: "设置 · AI · 钥匙串")
        XCTAssertEqual(app.failures.last?.context, "设置 · AI · 钥匙串")
        XCTAssertNil(app.failures.last?.repositoryID)
        app.report(title: "取消", error: CancellationError(), repository: repository)
        XCTAssertEqual(app.failures.count, 3)
    }

    func testDivergingPullGetsActionableMessage() {
        let failure = GroveFailure(
            title: "拉取失败",
            error: commandFailure("fatal: Not possible to fast-forward, aborting.")
        )

        XCTAssertTrue(failure.detail.contains("变基"))
        XCTAssertFalse(failure.detail.contains("fatal:"))
        XCTAssertTrue(failure.technicalDetail?.contains("Not possible to fast-forward") == true)
    }

    func testRejectedPushExplainsThatRemoteIsAhead() {
        let failure = GroveFailure(
            title: "推送失败",
            error: commandFailure("! [rejected] main -> main (non-fast-forward)")
        )

        XCTAssertTrue(failure.detail.contains("远端"))
        XCTAssertTrue(failure.detail.contains("拉取"))
    }

    func testUnknownCommandFailureShowsReasonWithoutOpeningTechnicalDetails() {
        let failure = GroveFailure(title: "操作失败", error: commandFailure("unexpected failure"))

        XCTAssertTrue(failure.detail.contains("unexpected failure"))
        XCTAssertTrue(failure.detail.contains("git 执行失败（退出码 1）"))
        XCTAssertTrue(failure.technicalDetail?.contains("unexpected failure") == true)
    }

    func testForgeFailureNamesTheToolAndDoesNotInventRepositoryCreationProblem() {
        let failure = GroveFailure(title: "读取 PR 列表失败", error: CommandFailure(
            executable: "/opt/homebrew/bin/gh", arguments: ["pr", "list"], exitCode: 7,
            output: "warning: cache unavailable\nHTTP 403: Resource not accessible by integration"
        ))
        XCTAssertTrue(failure.detail.contains("gh 执行失败（退出码 7）"))
        XCTAssertTrue(failure.detail.contains("HTTP 403: Resource not accessible by integration"))
        XCTAssertFalse(failure.detail.contains("创建仓库"))
        XCTAssertFalse(failure.detail.contains("Git 没有完成"))
        XCTAssertTrue(failure.technicalDetail?.contains("warning: cache unavailable") == true)
    }

    func testEmptyAndLongCommandOutputRemainUsefulAndBounded() {
        let empty = GroveFailure(title: "操作失败", error: commandFailure(""))
        XCTAssertTrue(empty.detail.contains("退出码 1"))
        XCTAssertTrue(empty.detail.contains("没有返回错误说明"))
        let output = String(repeating: "诊断内容", count: 500)
        let long = GroveFailure(title: "操作失败", error: commandFailure(output))
        XCTAssertLessThan(long.detail.count, 550)
        XCTAssertTrue(long.technicalDetail?.contains(output) == true)
    }

    func testLocalCommandTimeoutNamesTheCommandAndDuration() {
        let failure = GroveFailure(title: "AI Review 失败", error: CommandTimeout(
            executable: "/usr/local/bin/codex", arguments: ["exec"], seconds: 90
        ))
        XCTAssertTrue(failure.detail.contains("codex 执行超过 90 秒"))
        XCTAssertFalse(failure.detail.contains("远端响应时间"))
    }

    private func commandFailure(_ output: String) -> CommandFailure {
        CommandFailure(
            executable: "/usr/bin/git",
            arguments: ["pull", "--ff-only"],
            exitCode: 1,
            output: output
        )
    }
}
