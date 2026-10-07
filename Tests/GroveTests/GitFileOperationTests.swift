import XCTest
@testable import Grove

/// 状态列表中的文件名必须逐字匹配，索引操作必须保留工作区内容。
@MainActor
final class GitFileOperationTests: XCTestCase {
    private var root: URL!
    private var git: GitClient!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grove-file-operations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: root)
        try await git.run(["config", "user.email", "t@example.com"], in: root)
        try await git.run(["config", "user.name", "测试"], in: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ content: String, to name: String) throws {
        try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private func model() -> WorktreeModel {
        WorktreeModel(
            worktree: Worktree(path: root, head: nil, branch: "main", isBare: false,
                               isDetached: false, lockReason: nil, prunableReason: nil),
            repository: nil, git: git, app: nil
        )
    }

    func testSelectedFileOperationsTreatWildcardsAndMagicAsLiteralNames() async throws {
        let names = ["*.txt", ":(glob)*.txt", "[a].txt", "-leading.txt", "other.txt"]
        for name in names { try write("原内容\n", to: name) }
        try await git.stageAll(in: root)
        try await git.commit(message: "初始", in: root)
        for name in names { try write("新内容\n", to: name) }

        for name in names.dropLast() {
            let selected = try await git.diff(in: root, paths: [name], staged: false)
            XCTAssertEqual(selected.map(\.displayPath), [name])
            try await git.stage(paths: [name], in: root)
            let staged = try await git.diff(in: root, staged: true)
            XCTAssertEqual(staged.map(\.displayPath), [name])
            try await git.unstage(paths: [name], in: root)
            let afterUnstage = try await git.diff(in: root, staged: true)
            XCTAssertTrue(afterUnstage.isEmpty)
            try await git.discard(paths: [name], untracked: [], in: root)
            XCTAssertEqual(try read(name), "原内容\n")
            XCTAssertEqual(try read("other.txt"), "新内容\n")
        }
    }

    func testCleanTreatsWildcardAndMagicAsLiteralNames() async throws {
        for name in ["*.txt", ":(glob)*.txt", "other.txt"] {
            try write("未跟踪\n", to: name)
        }
        for name in ["*.txt", ":(glob)*.txt"] {
            try await git.discard(paths: [], untracked: [name], in: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
            XCTAssertEqual(try read("other.txt"), "未跟踪\n")
        }
    }

    func testUnstageBeforeFirstCommitPreservesFurtherEditsAndOtherStagedFiles() async throws {
        try write("暂存版本\n", to: "*.txt")
        try write("其他文件\n", to: "other.txt")
        try await git.stageAll(in: root)
        try write("暂存后继续编辑\n", to: "*.txt")
        try await git.unstage(paths: ["*.txt"], in: root)

        let staged = try await git.diff(in: root, staged: true)
        XCTAssertEqual(staged.map(\.displayPath), ["other.txt"])
        XCTAssertEqual(try read("*.txt"), "暂存后继续编辑\n")
    }

    func testSingleAndBatchUnstageRestoreBothPathsOfRename() async throws {
        try write("原内容\n", to: "first.txt")
        try await git.stageAll(in: root)
        try await git.commit(message: "初始", in: root)
        try FileManager.default.moveItem(at: root.appendingPathComponent("first.txt"),
                                        to: root.appendingPathComponent("renamed.txt"))
        let model = model()
        for batch in [false, true] {
            try await git.stageAll(in: root)
            await model.refreshStatus()
            let rename = try XCTUnwrap(model.status.changes.first { $0.path == "renamed.txt" })
            XCTAssertEqual(rename.staged, .renamed)
            if batch { await model.unstageAll() } else { await model.unstage(rename) }
            let staged = try await git.diff(in: root, staged: true)
            XCTAssertTrue(staged.isEmpty, "旧路径删除也必须退出暂存区")
            XCTAssertEqual(try read("renamed.txt"), "原内容\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("first.txt").path))
        }
    }
}
