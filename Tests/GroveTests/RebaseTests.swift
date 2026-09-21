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

    /// 纯落后（没有本地提交）时，预览必须判定为「快进」而不是「已经最新」。
    /// 旧逻辑只看 `origin/main..HEAD`，为 0 就误报「已经在之上」并禁掉按钮。
    func testPreviewDetectsFastForwardWhenBranchIsBehind() async throws {
        try write("基础\n", to: "base.txt")
        try await commit("初始")

        try await git.run(["checkout", "-q", "-b", "feature"], in: root)

        // 主干往前走，feature 停在原地。
        try await git.run(["checkout", "-q", "main"], in: root)
        try write("主干新内容\n", to: "main.txt")
        try await commit("主干提交")
        try await git.run(["checkout", "-q", "feature"], in: root)

        let behindPreview = await git.rebasePreview(onto: "main", in: root)
        let preview = try XCTUnwrap(behindPreview, "目标引用存在时预览不能为 nil")
        XCTAssertEqual(preview.commitsToReplay, 0)
        XCTAssertEqual(preview.commitsBehind, 1)
        XCTAssertTrue(preview.isFastForward)
        XCTAssertFalse(preview.isUpToDate)

        // 落后场景下变基应当真的把分支快进到 main。
        try await git.rebase(onto: "main", autostash: false, in: root)
        let head = try await git.run(["rev-parse", "HEAD"], in: root)
        let main = try await git.run(["rev-parse", "main"], in: root)
        XCTAssertEqual(
            head.trimmingCharacters(in: .whitespacesAndNewlines),
            main.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testPreviewReportsUpToDateWhenAlreadyOnTarget() async throws {
        try write("基础\n", to: "base.txt")
        try await commit("初始")

        let upToDatePreview = await git.rebasePreview(onto: "main", in: root)
        let preview = try XCTUnwrap(upToDatePreview)
        XCTAssertTrue(preview.isUpToDate)
        XCTAssertEqual(preview.commitsToReplay, 0)
        XCTAssertEqual(preview.commitsBehind, 0)
    }

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

/// 变基拉取：拉取按钮的行为必须是 rebase 而不是 merge / ff-only。
/// 用本地裸仓库当远端，跑真 `git pull`。
final class PullRebaseTests: XCTestCase {
    private var root: URL!
    private var origin: URL!
    private var git: GitClient!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-pullrebase-\(UUID().uuidString)")
        origin = root.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git = try await GitClient.resolve()

        try await git.run(["init", "-q", "--bare", "-b", "main", origin.path], in: root)
        try await git.run(["clone", "-q", origin.path, "clone"], in: root)
        root = root.appendingPathComponent("clone")
        try await git.run(["config", "user.email", "t@example.com"], in: root)
        try await git.run(["config", "user.name", "测试"], in: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func commit(_ message: String) async throws {
        try await git.run(["add", "-A"], in: root)
        try await git.run(["commit", "-qm", message], in: root)
    }

    /// 本地和远端各自前进（分叉）。以前的 --ff-only 在这里会直接报错。
    func testDivergedPullRebasesLocalCommitsOntoRemote() async throws {
        try write("初始\n", to: "a.txt")
        try await commit("初始")
        try await git.run(["push", "-q", "origin", "main"], in: root)

        // 远端新提交：先在克隆里做出来推上去，再让本地退回去 —— 
        // 本地和远端就各有一个对方没有的提交了。
        try write("远端改动\n", to: "remote.txt")
        try await commit("远端提交")
        try await git.run(["push", "-q", "origin", "main"], in: root)
        try await git.run(["reset", "-q", "--hard", "HEAD~1"], in: root)

        // 本地新提交。
        try write("本地改动\n", to: "local.txt")
        try await commit("本地提交")

        // 分叉已经形成：本地和远端各有对方没有的提交。
        let ahead = try await git.run(["rev-list", "--count", "origin/main..HEAD"], in: root)
        let behind = try await git.run(["rev-list", "--count", "HEAD..origin/main"], in: root)
        XCTAssertEqual(ahead.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertEqual(behind.trimmingCharacters(in: .whitespacesAndNewlines), "1")

        try await git.pull(in: root)

        // 历史线性：本地提交在远端提交之上，没有合并提交。
        let subjects = try await git.log(in: root, limit: 10, revision: "HEAD").map(\.subject)
        XCTAssertEqual(subjects.first, "本地提交")
        XCTAssertTrue(subjects.contains("远端提交"))
        XCTAssertFalse(subjects.contains { $0.hasPrefix("Merge") })

        let parents = try await git.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: root)
        XCTAssertEqual(
            parents.split(separator: " ").count, 2,  // HEAD + 单亲 = 没有合并提交
            "拉取产生了合并提交：\(parents)"
        )
    }

    /// 工作区有未提交改动时照样能拉（autostash），改动原样回来。
    func testPullWithDirtyWorktreeAutostashes() async throws {
        try write("初始\n", to: "a.txt")
        try await commit("初始")
        try await git.run(["push", "-q", "origin", "main"], in: root)

        try write("远端改动\n", to: "remote.txt")
        try await commit("远端提交")
        try await git.run(["push", "-q", "origin", "main"], in: root)
        try await git.run(["reset", "-q", "--hard", "HEAD~1"], in: root)

        // 未提交的本地改动 + 需要变基的已提交改动同时存在。
        try write("本地改动\n", to: "local.txt")
        try await commit("本地提交")
        try write("还没提交的东西\n", to: "dirty.txt")

        try await git.pull(in: root)

        let dirty = try String(contentsOf: root.appendingPathComponent("dirty.txt"), encoding: .utf8)
        XCTAssertEqual(dirty, "还没提交的东西\n")
        let subjects = try await git.log(in: root, limit: 10, revision: "HEAD").map(\.subject)
        XCTAssertEqual(subjects.first, "本地提交")
    }
}

/// 「拉取自」：从显式指定的远端拉，不依赖分支上游配置。
final class PullFromRemoteTests: XCTestCase {
    private var root: URL!
    private var git: GitClient!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-pullfrom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git = try await GitClient.resolve()

        // origin 是上游；mirror 是另一个远端，上面有更新的提交。
        try await git.run(["init", "-q", "--bare", "-b", "main", root.appendingPathComponent("origin.git").path], in: root)
        try await git.run(["init", "-q", "--bare", "-b", "main", root.appendingPathComponent("mirror.git").path], in: root)
        try await git.run(["clone", "-q", root.appendingPathComponent("origin.git").path, "clone"], in: root)
        root = root.appendingPathComponent("clone")
        try await git.run(["config", "user.email", "t@example.com"], in: root)
        try await git.run(["config", "user.name", "测试"], in: root)
        try await git.run(["remote", "add", "mirror", root.appendingPathComponent("../mirror.git").path], in: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// 上游（origin）没动、mirror 上有新提交：从 mirror 拉能拿到它的提交，
    /// 而且依然是变基拉取的线性历史。
    func testPullFromExplicitRemoteIgnoresUpstream() async throws {
        try "初始\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "-A"], in: root)
        try await git.run(["commit", "-qm", "初始"], in: root)
        try await git.run(["push", "-q", "-u", "origin", "main"], in: root)

        // mirror 上的新提交：推过去，本地不要。
        try "镜像改动\n".write(to: root.appendingPathComponent("mirror.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "-A"], in: root)
        try await git.run(["commit", "-qm", "镜像提交"], in: root)
        try await git.run(["push", "-q", "mirror", "main"], in: root)
        try await git.run(["reset", "-q", "--hard", "HEAD~1"], in: root)

        // 本地自己的新提交 → 和 mirror 分叉。
        try "本地改动\n".write(to: root.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "-A"], in: root)
        try await git.run(["commit", "-qm", "本地提交"], in: root)

        try await git.pull(in: root, remote: "mirror", branch: "main")

        let subjects = try await git.log(in: root, limit: 10, revision: "HEAD").map(\.subject)
        XCTAssertEqual(subjects.first, "本地提交")
        XCTAssertEqual(subjects.count(where: { $0 == "镜像提交" }), 1)
        XCTAssertFalse(subjects.contains { $0.hasPrefix("Merge") })
    }

    /// 分支没有任何上游时，显式远端 + 分支名也能拉（首推前的分支）。
    func testPullFromExplicitRemoteWithoutUpstream() async throws {
        try "初始\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "-A"], in: root)
        try await git.run(["commit", "-qm", "初始"], in: root)
        try await git.run(["push", "-q", "mirror", "main"], in: root)
        // 本地分支不设 -u，故意没有上游跟踪。
        try await git.run(["branch", "--unset-upstream"], in: root)

        try "本地改动\n".write(to: root.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try await git.run(["add", "-A"], in: root)
        try await git.run(["commit", "-qm", "本地提交"], in: root)

        try await git.pull(in: root, remote: "mirror", branch: "main")

        let subjects = try await git.log(in: root, limit: 10, revision: "HEAD").map(\.subject)
        XCTAssertEqual(subjects.first, "本地提交")
    }
}
