import XCTest
@testable import Grove

final class DiffSideSelectionTests: XCTestCase {
    func testFullyStagedFileSwitchesToStagedDiff() {
        let change = FileChange(
            path: "app.swift",
            originalPath: nil,
            staged: .modified,
            unstaged: nil,
            isConflicted: false
        )

        XCTAssertEqual(WorktreeModel.validDiffSide(for: change, preferred: .worktree), .staged)
    }

    func testUnstagedFileSwitchesBackToWorktreeDiff() {
        let change = FileChange(
            path: "app.swift",
            originalPath: nil,
            staged: nil,
            unstaged: .modified,
            isConflicted: false
        )

        XCTAssertEqual(WorktreeModel.validDiffSide(for: change, preferred: .staged), .worktree)
    }

    func testPartiallyStagedFileKeepsTheSelectedSide() {
        let change = FileChange(
            path: "app.swift",
            originalPath: nil,
            staged: .modified,
            unstaged: .modified,
            isConflicted: false
        )

        XCTAssertEqual(WorktreeModel.validDiffSide(for: change, preferred: .staged), .staged)
        XCTAssertEqual(WorktreeModel.validDiffSide(for: change, preferred: .worktree), .worktree)
    }
}

/// 分行暂存的端到端测试：真的建仓库、真的改文件、真的跑 `git apply`、
/// 再真的去问 git 索引里进了什么。
///
/// 补丁生成是这个功能里唯一会丢代码的地方。纯函数测试只能证明「我拼出的字符串
/// 长得像补丁」，证明不了「git 认这个补丁、而且应用后的结果是对的」——
/// 而后者才是用户关心的。所以这一组一定要跑真 git。
final class PartialStagingTests: XCTestCase {
    private var root: URL!
    private var git: GitClient!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git = try await GitClient.resolve()

        try await run(["init", "-q", "-b", "main"])
        try await run(["config", "user.email", "t@example.com"])
        try await run(["config", "user.name", "测试"])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func run(_ arguments: [String]) async throws -> String {
        try await git.run(arguments, in: root)
    }

    private func write(_ contents: String, to name: String = "app.txt") throws {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String = "app.txt") throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: -

    /// 改了两行，只暂存其中一行。
    func testStagesOnlySelectedLine() async throws {
        try write("一\n二\n三\n四\n五\n")
        try await run(["add", "-A"])
        try await run(["commit", "-qm", "初始"])

        // 改第二行和第四行。
        try write("一\n二改\n三\n四改\n五\n")

        let diffs = try await git.diff(in: root, staged: false)
        XCTAssertEqual(diffs.count, 1)
        let file = diffs[0]

        // 只选「二改」这一行的新增，以及它对应的删除行。
        let additions = file.hunks.flatMap(\.lines).filter { $0.kind == .addition }
        let deletions = file.hunks.flatMap(\.lines).filter { $0.kind == .deletion }
        XCTAssertEqual(additions.count, 2)
        XCTAssertEqual(deletions.count, 2)

        let selected: Set<Int> = [
            additions.first { $0.text == "二改" }!.id,
            deletions.first { $0.text == "二" }!.id
        ]

        let patch = try XCTUnwrap(
            PatchBuilder.patch(for: file, selecting: selected, direction: .forward)
        )
        try await git.applyPatch(patch, in: root, cached: true, reverse: false)

        // 索引里应该只有第二行的改动。
        let staged = try await git.diff(in: root, staged: true)
        let stagedAdditions = staged.flatMap { $0.hunks.flatMap(\.lines) }
            .filter { $0.kind == .addition }.map(\.text)
        XCTAssertEqual(stagedAdditions, ["二改"])

        // 第四行的改动还留在工作区没暂存。
        let unstaged = try await git.diff(in: root, staged: false)
        let unstagedAdditions = unstaged.flatMap { $0.hunks.flatMap(\.lines) }
            .filter { $0.kind == .addition }.map(\.text)
        XCTAssertEqual(unstagedAdditions, ["四改"])

        // 提交之后，HEAD 里只有第二行变了；工作区文件不受影响。
        try await run(["commit", "-qm", "只提交一行"])
        let committed = try await git.run(["show", "HEAD:app.txt"], in: root)
        XCTAssertEqual(committed, "一\n二改\n三\n四\n五\n")
        XCTAssertEqual(try read(), "一\n二改\n三\n四改\n五\n")
    }

    /// 只暂存一个纯新增行，周围的新增行不能被顺带带进去。
    func testStagesOneOfSeveralAddedLines() async throws {
        try write("头\n尾\n")
        try await run(["add", "-A"])
        try await run(["commit", "-qm", "初始"])

        try write("头\n新一\n新二\n新三\n尾\n")

        let file = try await git.diff(in: root, staged: false)[0]
        let additions = file.hunks.flatMap(\.lines).filter { $0.kind == .addition }
        XCTAssertEqual(additions.count, 3)

        let selected: Set<Int> = [additions.first { $0.text == "新二" }!.id]
        let patch = try XCTUnwrap(
            PatchBuilder.patch(for: file, selecting: selected, direction: .forward)
        )
        try await git.applyPatch(patch, in: root, cached: true, reverse: false)

        try await run(["commit", "-qm", "只加一行"])
        // 没选的两行绝不能跟着进去 —— 那是最典型的「悄悄提交了不该提交的代码」。
        let content = try await git.run(["show", "HEAD:app.txt"], in: root)
        XCTAssertEqual(content, "头\n新二\n尾\n")
    }

    /// 只暂存一个删除行。
    func testStagesOneOfSeveralDeletedLines() async throws {
        try write("甲\n乙\n丙\n丁\n")
        try await run(["add", "-A"])
        try await run(["commit", "-qm", "初始"])

        try write("甲\n丁\n")   // 删掉乙和丙

        let file = try await git.diff(in: root, staged: false)[0]
        let deletions = file.hunks.flatMap(\.lines).filter { $0.kind == .deletion }
        let selected: Set<Int> = [deletions.first { $0.text == "乙" }!.id]

        let patch = try XCTUnwrap(
            PatchBuilder.patch(for: file, selecting: selected, direction: .forward)
        )
        try await git.applyPatch(patch, in: root, cached: true, reverse: false)

        try await run(["commit", "-qm", "只删一行"])
        let content = try await git.run(["show", "HEAD:app.txt"], in: root)
        XCTAssertEqual(content, "甲\n丙\n丁\n")
    }

    /// 反向：从索引里撤掉某一行（取消暂存）。
    ///
    /// 反向的基准侧跟正向相反，规则搞反的话 `git apply -R` 会直接拒绝 ——
    /// 这条用例就是为了盯住那个方向。
    func testUnstagesOnlySelectedLine() async throws {
        try write("A\nB\nC\nD\nE\n")
        try await run(["add", "-A"])
        try await run(["commit", "-qm", "初始"])

        try write("A\nB改\nC\nD改\nE\n")
        try await run(["add", "-A"])   // 两行都先暂存

        let staged = try await git.diff(in: root, staged: true)[0]
        let additions = staged.hunks.flatMap(\.lines).filter { $0.kind == .addition }
        let deletions = staged.hunks.flatMap(\.lines).filter { $0.kind == .deletion }
        let selected: Set<Int> = [
            additions.first { $0.text == "D改" }!.id,
            deletions.first { $0.text == "D" }!.id
        ]

        let patch = try XCTUnwrap(
            PatchBuilder.patch(for: staged, selecting: selected, direction: .reverse)
        )
        try await git.applyPatch(patch, in: root, cached: true, reverse: true)

        // 索引里只剩 B 的改动，D 退回未暂存；工作区两行都还在。
        let stillStaged = try await git.diff(in: root, staged: true)
            .flatMap { $0.hunks.flatMap(\.lines) }.filter { $0.kind == .addition }.map(\.text)
        XCTAssertEqual(stillStaged, ["B改"])
        XCTAssertEqual(try read(), "A\nB改\nC\nD改\nE\n")
    }

    /// 跨多个 hunk 各选一行 —— 后一个 hunk 的新起始行号要跟着前面的改动平移。
    func testSelectionAcrossMultipleHunks() async throws {
        let original = (1...40).map { "行\($0)" }.joined(separator: "\n") + "\n"
        try write(original)
        try await run(["add", "-A"])
        try await run(["commit", "-qm", "初始"])

        // 改第 3 行和第 35 行，中间隔得足够远，会分成两个 hunk。
        var lines = original.components(separatedBy: "\n")
        lines[2] = "行3改"
        lines[34] = "行35改"
        try write(lines.joined(separator: "\n"))

        let file = try await git.diff(in: root, staged: false)[0]
        XCTAssertEqual(file.hunks.count, 2, "两处改动应该分成两个 hunk")

        let additions = file.hunks.flatMap(\.lines).filter { $0.kind == .addition }
        let deletions = file.hunks.flatMap(\.lines).filter { $0.kind == .deletion }
        // 两个 hunk 各选一行，一次性应用。
        let selected = Set(additions.map(\.id) + deletions.map(\.id))

        let patch = try XCTUnwrap(
            PatchBuilder.patch(for: file, selecting: selected, direction: .forward)
        )
        try await git.applyPatch(patch, in: root, cached: true, reverse: false)
        try await run(["commit", "-qm", "两处"])

        let committed = try await git.run(["show", "HEAD:app.txt"], in: root)
        XCTAssertTrue(committed.contains("行3改"))
        XCTAssertTrue(committed.contains("行35改"))
    }

    /// 文件末尾没有换行时，`\ No newline at end of file` 标记要跟对。
    func testHandlesMissingTrailingNewline() async throws {
        try write("首行\n末行")      // 末尾故意不带换行
        try await run(["add", "-A"])
        try await run(["commit", "-qm", "初始"])

        try write("首行\n末行改")

        let file = try await git.diff(in: root, staged: false)[0]
        let selected = Set(file.hunks.flatMap(\.lines)
            .filter { $0.kind == .addition || $0.kind == .deletion }.map(\.id))

        let patch = try XCTUnwrap(
            PatchBuilder.patch(for: file, selecting: selected, direction: .forward)
        )
        try await git.applyPatch(patch, in: root, cached: true, reverse: false)
        try await run(["commit", "-qm", "改末行"])
        let content = try await git.run(["show", "HEAD:app.txt"], in: root)
        XCTAssertEqual(content, "首行\n末行改")
    }

    /// 中文和空格路径也要能应用 —— 补丁头里的路径是原样抄 git 的，不该出问题。
    func testWorksWithUnicodeAndSpacedPaths() async throws {
        try write("原内容\n", to: "我的 文档.txt")
        try await run(["add", "-A"])
        try await run(["commit", "-qm", "初始"])
        try write("新内容\n", to: "我的 文档.txt")

        let file = try await git.diff(in: root, staged: false)[0]
        let selected = Set(file.hunks.flatMap(\.lines)
            .filter { $0.kind != .context && $0.kind != .noNewline }.map(\.id))

        let patch = try XCTUnwrap(
            PatchBuilder.patch(for: file, selecting: selected, direction: .forward)
        )
        try await git.applyPatch(patch, in: root, cached: true, reverse: false)
        try await run(["commit", "-qm", "改"])
        let content = try await git.run(["show", "HEAD:我的 文档.txt"], in: root)
        XCTAssertEqual(content, "新内容\n")
    }

    func testNoSelectionYieldsNoPatch() async throws {
        try write("x\n")
        try await run(["add", "-A"])
        try await run(["commit", "-qm", "初始"])
        try write("y\n")

        let file = try await git.diff(in: root, staged: false)[0]
        XCTAssertNil(PatchBuilder.patch(for: file, selecting: [], direction: .forward))
    }
}
