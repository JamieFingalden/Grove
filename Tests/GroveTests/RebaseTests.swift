import XCTest
@testable import Grove

/// 变基。跑真 git —— 变基会改写历史，而且中途可能停在冲突上，
/// 这两件事都只有在真仓库上才验证得了。
final class RebaseTests: XCTestCase {
    private var root: URL!
    private var git: GitClient!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-rebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: root)
        try await git.run(["config", "user.email", "t@example.com"], in: root)
        try await git.run(["config", "user.name", "测试"], in: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func commit(_ message: String) async throws {
        try await git.run(["add", "-A"], in: root)
        try await git.run(["commit", "-qm", message], in: root)
    }

    private func subjects(_ revision: String = "HEAD") async throws -> [String] {
        try await git.log(in: root, limit: 50, revision: revision).map(\.subject)
    }

    /// 造一个「主干往前走了、功能分支也往前走了」的分叉。
    private func makeDivergence(conflicting: Bool) async throws {
        try write("基础\n", to: "base.txt")
        try await commit("初始")

        try await git.run(["checkout", "-q", "-b", "feature"], in: root)
        try write(conflicting ? "功能改的内容\n" : "功能内容\n",
                  to: conflicting ? "shared.txt" : "feature.txt")
        try await commit("功能提交")

        try await git.run(["checkout", "-q", "main"], in: root)
        try write(conflicting ? "主干改的内容\n" : "主干内容\n",
                  to: conflicting ? "shared.txt" : "main.txt")
        try await commit("主干提交")

        try await git.run(["checkout", "-q", "feature"], in: root)
    }

    // MARK: -

    func testRebaseReplaysCommitsOnTop() async throws {
        try await makeDivergence(conflicting: false)

        let before = try await subjects()
        XCTAssertEqual(before, ["功能提交", "初始"])

        try await git.rebase(onto: "main", autostash: false, in: root)

        // 变基之后，主干的提交出现在功能提交下面。
        let after = try await subjects()
        XCTAssertEqual(after, ["功能提交", "主干提交", "初始"])
    }

    func testCommitCountPreviewMatchesWhatGetsReplayed() async throws {
        try await makeDivergence(conflicting: false)
        // 变基前的预览要跟实际重放的数量一致 —— 用户是照这个数字做决定的。
        let count = await git.commitCount(from: "main", in: root)
        XCTAssertEqual(count, 1)
    }

    func testAutostashCarriesUncommittedWorkAcross() async throws {
        try await makeDivergence(conflicting: false)
        try write("还没提交的草稿\n", to: "draft.txt")
        try await git.run(["add", "draft.txt"], in: root)

        // 不带 --autostash 时 git 会因为工作区不干净直接拒绝。
        await XCTAssertThrowsErrorAsync {
            try await self.git.rebase(onto: "main", autostash: false, in: self.root)
        }

        try await git.rebase(onto: "main", autostash: true, in: root)

        // 变基成功，而且没提交的草稿还在。
        let after = try await subjects()
        XCTAssertEqual(after, ["功能提交", "主干提交", "初始"])
        let draft = try String(contentsOf: root.appendingPathComponent("draft.txt"), encoding: .utf8)
        XCTAssertEqual(draft, "还没提交的草稿\n")
    }

    /// 冲突时变基会停下 —— Grove 必须认出这个中间状态，否则用户被卡死。
    func testConflictLeavesDetectableRebaseState() async throws {
        try await makeDivergence(conflicting: true)

        await XCTAssertThrowsErrorAsync {
            try await self.git.rebase(onto: "main", autostash: false, in: self.root)
        }

        let status = try await git.status(in: root)
        // 这个判断是「变基进行中」那条出路条的触发条件。认不出来的话，
        // 界面上什么提示都没有，用户只能自己回终端。
        XCTAssertEqual(status.operation, .rebase)
        XCTAssertTrue(status.hasConflicts)
    }

    /// 中止之后必须完整回到变基前的样子。
    func testAbortRestoresPreviousState() async throws {
        try await makeDivergence(conflicting: true)
        let beforeHead = try await git.run(["rev-parse", "HEAD"], in: root)

        try? await git.rebase(onto: "main", autostash: false, in: root)
        try await git.rebaseStep(.abort, in: root)

        let afterHead = try await git.run(["rev-parse", "HEAD"], in: root)
        XCTAssertEqual(beforeHead, afterHead)

        let status = try await git.status(in: root)
        XCTAssertNil(status.operation, "中止之后不该还留在变基状态里")
        XCTAssertFalse(status.hasConflicts)
    }

    /// 解决冲突 → 暂存 → 继续，整条路要能走通。
    ///
    /// `--continue` 在需要写提交信息时会去起编辑器。GUI 里那个编辑器起不来，
    /// git 就会永远等在那 —— 所以环境里设了 `GIT_EDITOR=true`。
    /// 这条用例同时也在验证那个设置真的生效了。
    func testResolveThenContinueFinishesRebase() async throws {
        try await makeDivergence(conflicting: true)
        try? await git.rebase(onto: "main", autostash: false, in: root)

        // 手工解决冲突。
        try write("合并后的内容\n", to: "shared.txt")
        try await git.run(["add", "shared.txt"], in: root)

        try await git.rebaseStep(.cont, in: root)

        let status = try await git.status(in: root)
        XCTAssertNil(status.operation)
        let after = try await subjects()
        XCTAssertEqual(after, ["功能提交", "主干提交", "初始"])
    }

    func testSkipDropsTheConflictingCommit() async throws {
        try await makeDivergence(conflicting: true)
        try? await git.rebase(onto: "main", autostash: false, in: root)

        try await git.rebaseStep(.skip, in: root)

        let status = try await git.status(in: root)
        XCTAssertNil(status.operation)
        // 冲突的那个提交被丢掉了，只剩主干的历史。
        let after = try await subjects()
        XCTAssertEqual(after, ["主干提交", "初始"])
    }

    func testRefExistenceCheck() async throws {
        try await makeDivergence(conflicting: false)
        let exists = await git.refExists("main", in: root)
        let missing = await git.refExists("origin/根本没有这个分支", in: root)
        XCTAssertTrue(exists)
        // 变基目标可能是用户手敲的，先验一下比让 git 抛一句晦涩的错误友好。
        XCTAssertFalse(missing)
    }
}

/// XCTest 没有内置的 async 版 assertThrows。
func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("本该抛错但没有", file: file, line: line)
    } catch {
        // 预期
    }
}
