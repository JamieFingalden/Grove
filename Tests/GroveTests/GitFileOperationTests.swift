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

    func testEditorSaveReloadsAlreadySelectedDiff() async throws {
        try write("初始\n", to: "a.txt")
        try await git.stageAll(in: root)
        try await git.commit(message: "初始", in: root)
        try write("保存前\n", to: "a.txt")
        let model = model()
        await model.refreshChanges()
        try await waitForDiff(model, containing: "保存前")

        try await model.writeEditorFile("保存后\n", to: root.appendingPathComponent("a.txt"))
        try await waitForDiff(model, containing: "保存后")
        XCTAssertEqual(try read("a.txt"), "保存后\n")
        let additions = model.diff?.flatMap { $0.hunks.flatMap(\.lines) }
            .filter { $0.kind == .addition }.map(\.text)
        XCTAssertEqual(additions, ["保存后"])
    }

    private func waitForDiff(_ model: WorktreeModel, containing text: String) async throws {
        for _ in 0..<200 {
            if model.diff?.flatMap({ $0.hunks.flatMap(\.lines) }).contains(where: { $0.text == text }) == true {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("选中文件的 diff 未更新：\(text)")
    }

    func testRefreshUpdatesCachedAuthorsAndTheirCounts() async throws {
        try write("初始\n", to: "a.txt")
        try await git.stageAll(in: root)
        try await git.commit(message: "初始", in: root)
        let model = model()
        await model.refresh()
        XCTAssertEqual(model.knownAuthors.map(\.name), ["测试"])

        // 外部提交出现新作者，已有作者的计数也必须随手动刷新更新。
        try await git.run(["-c", "user.name=新作者", "-c", "user.email=new@example.invalid",
                           "commit", "--allow-empty", "-qm", "新作者提交"], in: root)
        try await git.run(["commit", "--allow-empty", "-qm", "原作者再次提交"], in: root)
        await model.refresh()
        let counts = Dictionary(uniqueKeysWithValues: model.knownAuthors.map { ($0.name, $0.count) })
        XCTAssertEqual(counts, ["测试": 2, "新作者": 1])
        let author = try XCTUnwrap(model.knownAuthors.first { $0.name == "新作者" })
        await model.toggleAuthor(author)
        XCTAssertEqual(model.commits.map(\.subject), ["新作者提交"])
    }

    func testStagingRefreshesIndexWithoutReloadingHistory() async throws {
        try write("原内容\n", to: "a.txt")
        let executable = root.appendingPathComponent(".git/git-wrapper")
        let log = root.appendingPathComponent(".git/commands")
        try """
        #!/bin/sh
        echo "$*" >> "\(log.path)"
        exec /usr/bin/git "$@"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        git = GitClient(executable: executable, environment: ProcessInfo.processInfo.environment)
        let model = model()
        await model.refreshStatus()
        let change = try XCTUnwrap(model.status.changes.first)
        try Data().write(to: log)
        await model.stage(change)
        XCTAssertEqual(model.status.changes.first?.staged, .added)
        XCTAssertEqual(try read("a.txt"), "原内容\n")
        let commands = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(commands.contains(" status "))
        XCTAssertFalse(commands.contains(" log "), "暂存不应扫描历史和提交人")
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

    func testUnchangedLinesReadsStagedFileNamedWithColon() async throws {
        // 文件名含 `:` 时 `git show :<path>` 会被解析成 stage 语法而失败；
        // 展开未更改区域必须换 ls-files → cat-file 的路径安全路径。
        try write("第一行\n第二行\n", to: "a:b.swift")
        try await git.stageAll(in: root)
        try await git.commit(message: "初始", in: root)

        let model = model()
        model.diffSide = .staged
        let lines = await model.unchangedLines(path: "a:b.swift", startLine: 1, count: 2)
        XCTAssertEqual(lines, ["第一行", "第二行"])
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
