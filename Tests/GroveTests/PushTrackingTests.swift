import XCTest
@testable import Grove

final class PushTrackingTests: XCTestCase {
    func testReadsActualTrackedSHAAndRemoteBranchAfterPush() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("repo")
        let remote = directory.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: root)
        try await git.run(["config", "user.name", "测试"], in: root)
        try await git.run(["config", "user.email", "t@example.invalid"], in: root)
        let file = root.appendingPathComponent("a.txt")
        try Data("初始\n".utf8).write(to: file)
        try await git.stageAll(in: root)
        try await git.commit(message: "初始", in: root)
        try await git.run(["clone", "--bare", root.path, remote.path], in: directory)
        try await git.run(["remote", "add", "origin", remote.path], in: root)
        try await git.run(["config", "branch.main.remote", "origin"], in: root)
        try await git.run(["config", "branch.main.merge", "refs/heads/server-name"], in: root)
        try await git.run(["config", "push.default", "upstream"], in: root)
        let snapshot = try await git.run(["rev-parse", "HEAD"], in: root)

        // 捕获快照后又提交，真正推送的提交必须以更新后的跟踪引用为准。
        try Data("实际推送\n".utf8).write(to: file)
        try await git.stageAll(in: root)
        try await git.commit(message: "推送前追加", in: root)
        let pushedSHA = try await git.run(["rev-parse", "HEAD"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = try await git.push(in: root, remote: nil, branch: "main", setUpstream: false)
        // 推送后继续提交，也不能把当前 HEAD 误认成已经推送的版本。
        try Data("留在本地\n".utf8).write(to: file)
        try await git.stageAll(in: root)
        try await git.commit(message: "推送后追加", in: root)
        let tracked = await git.pushedTrackingCommit(from: output, for: "main", remote: nil, in: root)
        let pushed = try XCTUnwrap(tracked)
        XCTAssertEqual(pushed.target, remote.path)
        XCTAssertEqual(pushed.branch, "server-name")
        XCTAssertEqual(pushed.sha, pushedSHA)
        XCTAssertNotEqual(pushed.sha, snapshot.trimmingCharacters(in: .whitespacesAndNewlines))

        // Git 的简写 refspec 仍可能映射上游分支，不能把命令参数当实际目标。
        let explicitOutput = try await git.push(in: root, remote: "origin", branch: "main", setUpstream: false)
        let explicit = await git.pushedTrackingCommit(from: explicitOutput, for: "main", remote: "origin", in: root)
        let explicitTarget = try XCTUnwrap(explicit)
        let currentSHA = try await git.run(["rev-parse", "HEAD"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(explicitTarget.branch, "server-name")
        XCTAssertEqual(explicitTarget.sha, currentSHA)
        XCTAssertNotEqual(explicitTarget.sha, pushed.sha)

        // 没有实际更新当前分支的记录，不能依据残留的引用启动监控。
        let uncertain = await git.pushedTrackingCommit(from: "To \(remote.path)\nDone", for: "main", remote: nil, in: root)
        XCTAssertNil(uncertain)
    }
}
