import XCTest
@testable import Grove

/// 冲突解决。跑真 git —— 三个索引阶段、`checkout --ours`、`rm` 在未合并条目上的行为，
/// 只有真仓库才验证得了。
final class ConflictResolutionTests: XCTestCase {
    private var root: URL!
    private var git: GitClient!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-conflict-\(UUID().uuidString)")
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

    private func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    private func commit(_ message: String) async throws {
        try await git.run(["add", "-A"], in: root)
        try await git.run(["commit", "-qm", message], in: root)
    }

    private func change(_ name: String) async throws -> FileChange? {
        try await git.status(in: root).changes.first { $0.path == name }
    }

    /// 四种形态一次造齐：双方修改（both.txt）、双方新增（added.txt）、
    /// 传入侧删除（delme.txt）、当前侧删除（theirs-del.txt）。
    private func makeMergeConflict() async throws {
        try write("line1\nline2\nline3\n", to: "both.txt")
        try write("keep\n", to: "delme.txt")
        try write("x\n", to: "theirs-del.txt")
        try await commit("初始")

        try await git.run(["checkout", "-q", "-b", "feature"], in: root)
        try write("line1\nFEATURE\nline3\n", to: "both.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("delme.txt"))
        try write("feature-new\n", to: "added.txt")
        try write("x\nfeature-change\n", to: "theirs-del.txt")
        try await commit("功能提交")

        try await git.run(["checkout", "-q", "main"], in: root)
        try write("line1\nMAIN\nline3\n", to: "both.txt")
        try write("keep\nmain-change\n", to: "delme.txt")
        try write("main-new\n", to: "added.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("theirs-del.txt"))
        try await commit("主干提交")

        await XCTAssertThrowsErrorAsync {
            try await self.git.run(["merge", "feature"], in: self.root)
        }
    }

    // MARK: - 状态

    func testMergeConflictReportsKindsAndOperation() async throws {
        try await makeMergeConflict()
        let status = try await git.status(in: root)

        XCTAssertEqual(status.operation, .merge)
        XCTAssertEqual(status.conflictCount, 4)
        let kinds = Dictionary(uniqueKeysWithValues: status.conflictedChanges.map { ($0.path, $0.conflict) })
        XCTAssertEqual(kinds["both.txt"], .bothModified)
        XCTAssertEqual(kinds["added.txt"], .bothAdded)
        XCTAssertEqual(kinds["delme.txt"], .deletedByThem)
        XCTAssertEqual(kinds["theirs-del.txt"], .deletedByUs)
        // 冲突文件不能混进「已暂存」，否则提交按钮会把它们数进去。
        XCTAssertEqual(status.stagedCount, 0)
    }

    // MARK: - 整文件选边

    func testTakingOursOnBothModifiedKeepsHeadVersion() async throws {
        try await makeMergeConflict()
        try await git.resolveConflict(path: "both.txt", taking: .ours, kind: .bothModified, in: root)

        XCTAssertEqual(try read("both.txt"), "line1\nMAIN\nline3\n")
        // 当前分支的版本跟 HEAD 一样，所以这个文件从变更列表里彻底消失 —— 这就是「已解决」。
        let remaining = try await change("both.txt")
        XCTAssertNil(remaining)
    }

    func testTakingTheirsOnBothModifiedStagesIncomingVersion() async throws {
        try await makeMergeConflict()
        try await git.resolveConflict(path: "both.txt", taking: .theirs, kind: .bothModified, in: root)

        XCTAssertEqual(try read("both.txt"), "line1\nFEATURE\nline3\n")
        let resolved = try await change("both.txt")
        XCTAssertEqual(resolved?.isConflicted, false)
        XCTAssertEqual(resolved?.staged, .modified)
    }

    func testTakingTheirsOnDeletedByThemRemovesTheFile() async throws {
        try await makeMergeConflict()
        // 传入侧删了它：采用传入 = 删文件。这里不能走 checkout --theirs，那一侧没有版本。
        try await git.resolveConflict(path: "delme.txt", taking: .theirs, kind: .deletedByThem, in: root)

        XCTAssertFalse(exists("delme.txt"))
        let resolved = try await change("delme.txt")
        XCTAssertEqual(resolved?.isConflicted, false)
        XCTAssertEqual(resolved?.staged, .deleted)
    }

    func testTakingOursOnDeletedByThemKeepsTheFile() async throws {
        try await makeMergeConflict()
        try await git.resolveConflict(path: "delme.txt", taking: .ours, kind: .deletedByThem, in: root)

        XCTAssertEqual(try read("delme.txt"), "keep\nmain-change\n")
        let remaining = try await change("delme.txt")
        XCTAssertNil(remaining, "跟 HEAD 一致，不该再出现在变更里")
    }

    func testTakingOursOnDeletedByUsRemovesTheFile() async throws {
        try await makeMergeConflict()
        try await git.resolveConflict(path: "theirs-del.txt", taking: .ours, kind: .deletedByUs, in: root)

        XCTAssertFalse(exists("theirs-del.txt"))
        let remaining = try await change("theirs-del.txt")
        XCTAssertNil(remaining)
    }

    func testTakingTheirsOnDeletedByUsRestoresIncomingFile() async throws {
        try await makeMergeConflict()
        try await git.resolveConflict(path: "theirs-del.txt", taking: .theirs, kind: .deletedByUs, in: root)

        XCTAssertEqual(try read("theirs-del.txt"), "x\nfeature-change\n")
        let resolved = try await change("theirs-del.txt")
        XCTAssertEqual(resolved?.isConflicted, false)
        XCTAssertEqual(resolved?.staged, .added)
    }

    // MARK: - 手工解决

    func testMarkResolvedAfterManualEdit() async throws {
        try await makeMergeConflict()
        try write("line1\n手工合并\nline3\n", to: "both.txt")
        try await git.markConflictResolved(path: "both.txt", in: root)

        let resolved = try await change("both.txt")
        XCTAssertEqual(resolved?.isConflicted, false)
        XCTAssertEqual(resolved?.staged, .modified)
    }

    func testMarkResolvedOnDeletedWorktreeFileRemovesIt() async throws {
        try await makeMergeConflict()
        try FileManager.default.removeItem(at: root.appendingPathComponent("both.txt"))
        try await git.markConflictResolved(path: "both.txt", in: root)

        let resolved = try await change("both.txt")
        XCTAssertEqual(resolved?.isConflicted, false)
        XCTAssertEqual(resolved?.staged, .deleted)
    }

    func testRestoreConflictMarkersRecreatesGitsMergeResult() async throws {
        try await makeMergeConflict()
        try write("改乱了\n", to: "both.txt")
        try await git.restoreConflictMarkers(path: "both.txt", in: root)

        let text = try read("both.txt")
        // 重建出来的标记标签是 git 固定写的 ours / theirs，不再是原来的分支名 ——
        // 这正是界面上那条「当前 / 传入各是谁」的图例存在的理由。
        let document = ConflictParser.parse(text)
        XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks.first?.ours, ["MAIN"])
        XCTAssertEqual(document.blocks.first?.theirs, ["FEATURE"])
    }

    // MARK: - 两侧是谁

    func testMergeContextNamesBothBranches() async throws {
        try await makeMergeConflict()
        let context = await git.conflictContext(operation: .merge, branch: "main", in: root)

        XCTAssertTrue(context.oursLabel.contains("main"), context.oursLabel)
        XCTAssertTrue(context.theirsLabel.contains("feature"), context.theirsLabel)
    }

    func testRebaseContextPutsTheTargetOnTheOursSide() async throws {
        try write("base\n", to: "shared.txt")
        try await commit("初始")
        try await git.run(["checkout", "-q", "-b", "feature"], in: root)
        try write("feature\n", to: "shared.txt")
        try await commit("功能提交")
        try await git.run(["checkout", "-q", "main"], in: root)
        try write("main\n", to: "shared.txt")
        try await commit("主干提交")
        try await git.run(["checkout", "-q", "feature"], in: root)
        try? await git.rebase(onto: "main", autostash: false, in: root)

        let status = try await git.status(in: root)
        XCTAssertEqual(status.operation, .rebase)
        let context = await git.conflictContext(operation: .rebase, branch: status.branch, in: root)

        // 变基时 ours 是变基目标、theirs 是自己正在重放的提交 —— 界面必须把这一点写出来。
        XCTAssertTrue(context.oursLabel.contains("main"), context.oursLabel)
        XCTAssertTrue(context.oursLabel.contains("变基目标"), context.oursLabel)
        XCTAssertTrue(context.theirsLabel.contains("功能提交"), context.theirsLabel)
        XCTAssertTrue(context.theirsLabel.contains("feature"), context.theirsLabel)
    }

    func testCherryPickContextNamesThePickedCommit() async throws {
        try write("base\n", to: "shared.txt")
        try await commit("初始")
        try await git.run(["checkout", "-q", "-b", "feature"], in: root)
        try write("feature\n", to: "shared.txt")
        try await commit("要拣的提交")
        try await git.run(["checkout", "-q", "main"], in: root)
        try write("main\n", to: "shared.txt")
        try await commit("主干提交")
        await XCTAssertThrowsErrorAsync {
            try await self.git.run(["cherry-pick", "feature"], in: self.root)
        }

        let status = try await git.status(in: root)
        XCTAssertEqual(status.operation, .cherryPick)
        let context = await git.conflictContext(operation: .cherryPick, branch: "main", in: root)
        XCTAssertTrue(context.theirsLabel.contains("要拣的提交"), context.theirsLabel)

        // 拣选也能从 Grove 里中止。
        try await git.operationStep(.abort, of: .cherryPick, in: root)
        let after = try await git.status(in: root)
        XCTAssertNil(after.operation)
        XCTAssertFalse(after.hasConflicts)
    }

    // MARK: - 继续 / 中止

    func testAbortMergeRestoresCleanState() async throws {
        try await makeMergeConflict()
        try await git.operationStep(.abort, of: .merge, in: root)

        let status = try await git.status(in: root)
        XCTAssertNil(status.operation)
        XCTAssertTrue(status.isClean)
        XCTAssertEqual(try read("both.txt"), "line1\nMAIN\nline3\n")
    }

    func testContinueMergeIsRefusedWhileConflictsRemain() async throws {
        try await makeMergeConflict()
        await XCTAssertThrowsErrorAsync {
            try await self.git.operationStep(.cont, of: .merge, in: self.root)
        }
        let status = try await git.status(in: root)
        XCTAssertEqual(status.operation, .merge)
    }

    func testContinueMergeAfterResolvingEverythingCreatesMergeCommit() async throws {
        try await makeMergeConflict()
        try await git.resolveConflict(path: "both.txt", taking: .theirs, kind: .bothModified, in: root)
        try await git.resolveConflict(path: "added.txt", taking: .ours, kind: .bothAdded, in: root)
        try await git.resolveConflict(path: "delme.txt", taking: .theirs, kind: .deletedByThem, in: root)
        try await git.resolveConflict(path: "theirs-del.txt", taking: .theirs, kind: .deletedByUs, in: root)

        // `--continue` 需要提交信息时会起编辑器；环境里 GIT_EDITOR=true 让它接受默认信息。
        try await git.operationStep(.cont, of: .merge, in: root)

        let status = try await git.status(in: root)
        XCTAssertNil(status.operation)
        XCTAssertTrue(status.isClean)
        let head = try await git.log(in: root, limit: 1)
        XCTAssertEqual(head.first?.parents.count, 2, "应该是一个合并提交")
        XCTAssertEqual(try read("both.txt"), "line1\nFEATURE\nline3\n")
        XCTAssertEqual(try read("added.txt"), "main-new\n")
        XCTAssertFalse(exists("delme.txt"))
        XCTAssertEqual(try read("theirs-del.txt"), "x\nfeature-change\n")
    }

    func testBisectCannotBeStepped() async throws {
        await XCTAssertThrowsErrorAsync {
            try await self.git.operationStep(.abort, of: .bisect, in: self.root)
        }
    }
}

/// 逐块解决走的是 WorktreeModel。整个类跑在主线程上 —— 模型是 @MainActor 的。
@MainActor
final class ConflictEditorModelTests: XCTestCase {
    private var root: URL!
    private var git: GitClient!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-conflict-model-\(UUID().uuidString)")
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

    private func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func commit(_ message: String) async throws {
        try await git.run(["add", "-A"], in: root)
        try await git.run(["commit", "-qm", message], in: root)
    }

    private func makeMergeConflict() async throws {
        try write("line1\nline2\nline3\n", to: "both.txt")
        try await commit("初始")
        try await git.run(["checkout", "-q", "-b", "feature"], in: root)
        try write("line1\nFEATURE\nline3\n", to: "both.txt")
        try await commit("功能提交")
        try await git.run(["checkout", "-q", "main"], in: root)
        try write("line1\nMAIN\nline3\n", to: "both.txt")
        try await commit("主干提交")
        // 冲突时 merge 以非零退出，这里要的就是那个中间状态。
        _ = try? await git.run(["merge", "feature"], in: root)
        let status = try await git.status(in: root)
        XCTAssertEqual(status.operation, .merge)
    }

    /// 逐块选择要真的落到磁盘上，撤销要能把标记还回来，
    /// 而且不能盖掉用户同时在外部编辑器里做的改动。
    func testBlockResolutionWritesFileSupportsUndoAndRespectsExternalEdits() async throws {
        try await makeMergeConflict()
        let worktree = Worktree(
            path: root, head: nil, branch: "main", isBare: false, isDetached: false,
            lockReason: nil, prunableReason: nil, isPrimary: true
        )
        let model = WorktreeModel(worktree: worktree, repository: nil, git: git, app: nil)
        await model.refresh()
        XCTAssertEqual(model.status.operation, .merge)
        XCTAssertNotNil(model.conflictContext)

        model.selectedPath = "both.txt"
        let editor = try await waitForEditor(model)
        XCTAssertEqual(editor.document.blocks.count, 1)
        XCTAssertEqual(editor.remainingCount, 1)
        let block = editor.document.blocks[0]

        model.resolveBlock(block, with: .theirs)
        XCTAssertEqual(try read("both.txt"), "line1\nFEATURE\nline3\n")
        guard case .editor(let resolved) = model.conflictContent else { XCTFail("应该还在编辑器里"); return }
        XCTAssertTrue(resolved.isFullyResolved)
        XCTAssertEqual(model.unresolvedMarkerCount(in: resolved.change), 0)

        // 撤销：标记回到磁盘上。
        model.resolveBlock(block, with: nil)
        XCTAssertTrue(try read("both.txt").contains("<<<<<<< HEAD"))
        XCTAssertEqual(model.unresolvedMarkerCount(in: resolved.change), 1)

        // 刷新不能把已做的选择冲掉（磁盘内容没变时保留编辑器状态）。
        model.resolveBlock(block, with: .both)
        await model.refresh()
        let afterRefresh = try await waitForEditor(model)
        XCTAssertEqual(afterRefresh.resolutions[block.id], .both)
        XCTAssertEqual(try read("both.txt"), "line1\nMAIN\nFEATURE\nline3\n")

        // 外部改动：写盘前发现磁盘内容变了，这次选择不能覆盖上去。
        try write("外部编辑器写的\n", to: "both.txt")
        model.resolveBlock(block, with: .ours)
        XCTAssertEqual(try read("both.txt"), "外部编辑器写的\n")

        // 重新读取后按磁盘内容来：已经没有标记了。
        await model.reloadConflictContent()
        let reloaded = try await waitForEditor(model)
        XCTAssertTrue(reloaded.document.blocks.isEmpty)

        await model.markConflictResolved(reloaded.change)
        XCTAssertFalse(model.status.hasConflicts || model.status.conflictedChanges.contains { $0.path == "both.txt" })
        XCTAssertEqual(model.status.changes.first { $0.path == "both.txt" }?.staged, .modified)
    }

    private func waitForEditor(_ model: WorktreeModel) async throws -> WorktreeModel.ConflictEditor {
        for _ in 0..<50 {
            if case .editor(let editor) = model.conflictContent { return editor }
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTFail("冲突编辑器没有加载出来")
        throw XCTSkip("超时")
    }
}
