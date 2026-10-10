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

    func testUnknownGitFailureKeepsRawOutputBehindTechnicalDetails() {
        let failure = GroveFailure(title: "操作失败", error: commandFailure("unexpected failure"))

        XCTAssertFalse(failure.detail.contains("unexpected failure"))
        XCTAssertTrue(failure.technicalDetail?.contains("unexpected failure") == true)
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
