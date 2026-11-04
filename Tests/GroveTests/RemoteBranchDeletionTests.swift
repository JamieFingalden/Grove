import XCTest
@testable import Grove

/// 记录全部命令；查询类子命令一律成功返回空输出（各解析器对空串都产出空结果），
/// 让 RepositoryModel 的 refresh 流程能顺利走完。
private actor RecordingTransport: CommandTransport {
    nonisolated let label = "受控远端分支删除"
    private(set) var commands: [[String]] = []
    /// 命令里包含这段文本就让整条失败（模拟远端拒绝删除）。
    private var failingNeedle: String?

    func failCommands(containing needle: String) {
        failingNeedle = needle
    }

    func runGit(_ arguments: [String], worktreePath: String, timeout: Double,
                standardInput: Data?) async throws -> CommandResult {
        commands.append(arguments)
        if let failingNeedle, arguments.joined(separator: " ").contains(failingNeedle) {
            return CommandResult(
                exitCode: 1,
                standardOutput: Data(),
                standardError: Data("remote rejection: 不允许删除".utf8)
            )
        }
        return CommandResult(exitCode: 0, standardOutput: Data(), standardError: Data())
    }

    /// 末尾恰好是 `needle` 的命令是否跑过。用后缀匹配而不是子串：
    /// `feature/a` 不会误命中 `feature/ab`。
    func didRun(_ needle: [String]) -> Bool {
        commands.contains { Array($0.suffix(needle.count)) == needle }
    }

    func fileExists(atPath path: String) async -> Bool { false }
    func directoryExists(atPath path: String) async -> Bool { false }
    func readData(atPath path: String) async -> Data? { nil }
    func writeData(_ data: Data, toPath path: String, atomic: Bool) async throws {}
    func modificationDate(atPath path: String) async -> Date? { nil }
    func createDirectory(atPath path: String) async throws {}
}

@MainActor
final class RemoteBranchDeletionTests: XCTestCase {
    private func makeRepository(_ transport: RecordingTransport) -> RepositoryModel {
        RepositoryModel(
            root: URL(fileURLWithPath: "/tmp/grove-remote-branches"),
            git: GitClient(transport: transport),
            app: nil
        )
    }

    private func branch(_ name: String) -> RemoteBranch {
        RemoteBranch(
            name: name,
            localName: RefParser.stripRemotePrefix(name),
            oid: "0000000000000000000000000000000000000000",
            lastCommitDate: nil,
            subject: "测试提交"
        )
    }

    func testDeleteArgumentsShape() {
        XCTAssertEqual(
            GitClient.remoteBranchDeleteArguments(remote: "origin", branch: "feature/login"),
            ["push", "origin", "--delete", "feature/login"]
        )
    }

    func testDeletesAcrossRemotesThenPrunes() async {
        let transport = RecordingTransport()
        let repository = makeRepository(transport)
        repository.remotes = [
            NamedRemote(name: "origin", fetchURL: "https://example.com/a.git", pushURL: "https://example.com/a.git"),
            NamedRemote(name: "backup", fetchURL: "https://backup.example.com/a.git", pushURL: "https://backup.example.com/a.git")
        ]

        await repository.deleteRemoteBranches([branch("origin/feature/a"), branch("backup/feature/b")])

        let pushes = await transport.commands.filter { $0.contains("--delete") }
        XCTAssertEqual(pushes.count, 2)
        let deletedOrigin = await transport.didRun(["push", "origin", "--delete", "feature/a"])
        let deletedBackup = await transport.didRun(["push", "backup", "--delete", "feature/b"])
        XCTAssertTrue(deletedOrigin)
        XCTAssertTrue(deletedBackup)
        // 删完统一抓取修剪，远端分支列表才会消失、本地 [gone] 才会出现。
        let pruned = await transport.didRun(["fetch", "--all", "--prune"])
        XCTAssertTrue(pruned)
    }

    func testDefaultBranchIsNeverPushedForDeletion() async {
        let transport = RecordingTransport()
        let repository = makeRepository(transport)
        repository.remotes = [
            NamedRemote(name: "origin", fetchURL: "https://example.com/a.git", pushURL: "https://example.com/a.git")
        ]
        repository.defaultBranch = "main"

        await repository.deleteRemoteBranches([branch("origin/main"), branch("origin/feature/keep")])

        let hasDeletionOfMain = await transport.commands.contains {
            $0.contains("--delete") && $0.contains(" main")
        }
        XCTAssertFalse(hasDeletionOfMain)
        let kept = await transport.didRun(["push", "origin", "--delete", "feature/keep"])
        XCTAssertTrue(kept)
    }

    func testOneRejectionDoesNotBlockTheRest() async {
        let transport = RecordingTransport()
        await transport.failCommands(containing: "push origin --delete feature/a")
        let repository = makeRepository(transport)
        repository.remotes = [
            NamedRemote(name: "origin", fetchURL: "https://example.com/a.git", pushURL: "https://example.com/a.git")
        ]

        await repository.deleteRemoteBranches([branch("origin/feature/a"), branch("origin/feature/b")])

        let stillDeleted = await transport.didRun(["push", "origin", "--delete", "feature/b"])
        XCTAssertTrue(stillDeleted)
        // 失败的那条之后依然抓取修剪，成功删除的部分要反映到列表里。
        let pruned = await transport.didRun(["fetch", "--all", "--prune"])
        XCTAssertTrue(pruned)
    }
}
