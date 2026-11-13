import XCTest
@testable import Grove

@MainActor
final class RepositoryFileWatcherTests: XCTestCase {
    private var root: URL!
    private var git: GitClient!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-watcher-\(UUID().uuidString)").groveResolved
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: root)
        try await git.run(["config", "user.name", "测试"], in: root)
        try await git.run(["config", "user.email", "test@example.invalid"], in: root)
        try write("初始\n", to: "文件.txt")
        try write("build/\n*.log\n", to: ".gitignore")
        try await git.stageAll(in: root)
        try await git.commit(message: "初始", in: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testExternalSaveStageCommitAndBranchSwitchRefreshWithoutManualAction() async throws {
        let app = AppModel()
        let repository = RepositoryModel(root: root, git: git, app: app)
        app.repositories = [repository]
        await repository.refresh(loadForgeMetadata: false)
        let path = try XCTUnwrap(repository.worktrees.first?.path)
        let model = try XCTUnwrap(repository.worktreeModel(for: path))
        app.selection = .worktree(repository: repository.id, worktree: path)
        await model.refresh(loadForgeMetadata: false)

        try write("外部保存\n", to: "文件.txt")
        try await waitUntil { model.status.changes.count == 1 && self.diff(model, contains: "外部保存") }
        try write("再次保存\n", to: "文件.txt")
        try await waitUntil { self.diff(model, contains: "再次保存") }

        try await git.stageAll(in: root)
        try await waitUntil { model.status.stagedCount == 1 && model.diffSide == .staged }
        try await git.commit(message: "终端提交", in: root)
        try await waitUntil { model.status.isClean && model.commits.first?.subject == "终端提交" }
        try await git.run(["checkout", "-qb", "external"], in: root)
        try await waitUntil { model.worktree.branch == "external" && repository.branches.contains { $0.name == "external" } }
    }

    func testNewLinkedWorktreeAndItsGitDirectoryAreWatched() async throws {
        let repository = RepositoryModel(root: root, git: git, app: nil)
        await repository.refresh(loadForgeMetadata: false)
        let linked = root.deletingLastPathComponent().appendingPathComponent("grove-linked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linked) }
        try await git.run(["worktree", "add", "-qb", "linked", linked.path], in: root)
        try await waitUntil {
            repository.worktrees.first { $0.path.isSameLocation(as: linked) }
                .flatMap { repository.worktreeModel(for: $0.path) } != nil
        }
        let path = try XCTUnwrap(repository.worktrees.first { $0.path.isSameLocation(as: linked) }?.path)
        let model = try XCTUnwrap(repository.worktreeModel(for: path))
        try "附加工作树\n".write(to: linked.appendingPathComponent("文件.txt"), atomically: true, encoding: .utf8)
        try await waitUntil { model.status.changes.count == 1 }
        try await git.stageAll(in: linked)
        try await waitUntil { model.status.stagedCount == 1 }
        try await git.commit(message: "附加提交", in: linked)
        let head = try await git.run(["rev-parse", "HEAD"], in: linked).trimmingCharacters(in: .whitespacesAndNewlines)
        try await waitUntil { model.worktree.head == head && model.status.isClean }
        try await git.run(["worktree", "remove", linked.path], in: root)
        try await waitUntil { repository.worktreeModel(for: path) == nil }
    }

    func testIgnoreFilteringStillIncludesTrackedFilesAndUnusualNames() async throws {
        try write("已跟踪\n", to: "tracked.log")
        try await git.run(["add", "-f", "tracked.log"], in: root)
        try await git.commit(message: "跟踪日志", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try write("产物\n", to: "build/output")
        let ignored = await git.hasUnignoredPaths(["build/output", "untracked.log"], in: root)
        let tracked = await git.hasUnignoredPaths(["tracked.log"], in: root)
        let unusual = await git.hasUnignoredPaths(["换行\n文件.txt", ":路径.txt"], in: root)
        XCTAssertFalse(ignored)
        XCTAssertTrue(tracked)
        XCTAssertTrue(unusual)
    }

    func testIdleAndIgnoredBuildOutputDoNotQueryStatusOrHistory() async throws {
        let executable = root.appendingPathComponent(".git/git-wrapper")
        let commands = root.appendingPathComponent(".git/commands")
        try """
        #!/bin/sh
        echo "$*" >> "\(commands.path)"
        exec /usr/bin/git "$@"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let instrumented = GitClient(executable: executable, environment: ProcessInfo.processInfo.environment)
        let app = AppModel()
        let repository = RepositoryModel(root: root, git: instrumented, app: app)
        app.repositories = [repository]
        await repository.refresh(loadForgeMetadata: false)
        let path = try XCTUnwrap(repository.worktrees.first?.path)
        let model = try XCTUnwrap(repository.worktreeModel(for: path))
        app.selection = .worktree(repository: repository.id, worktree: path)
        await model.refresh(loadForgeMetadata: false)
        try "".write(to: commands, atomically: true, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(try String(contentsOf: commands, encoding: .utf8), "", "空闲时不应轮询 Git")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        for index in 0..<50 { try write("产物\n", to: "build/\(index)") }
        try await Task.sleep(for: .milliseconds(1200))
        let ignoredCommands = try String(contentsOf: commands, encoding: .utf8)
        XCTAssertFalse(ignoredCommands.contains(" status "), "忽略的构建产物不应触发状态扫描")
        XCTAssertFalse(ignoredCommands.contains(" log "))

        try write("代码更新\n", to: "文件.txt")
        try await waitUntil { self.diff(model, contains: "代码更新") }
        let changedCommands = try String(contentsOf: commands, encoding: .utf8)
        XCTAssertTrue(changedCommands.contains(" status "))
        XCTAssertFalse(changedCommands.contains(" log "), "普通保存不应重新读取提交历史")
    }

    func testBurstEventsAreCoalescedAndChangesDuringRefreshAreNotLost() async throws {
        var batches: [RepositoryFileWatcher.Batch] = []
        var release: CheckedContinuation<Void, Never>?
        var active = 0
        var maximumActive = 0
        let watcher = RepositoryFileWatcher(delay: .milliseconds(20)) { batch in
            active += 1
            maximumActive = max(maximumActive, active)
            batches.append(batch)
            if batches.count == 1 { await withCheckedContinuation { release = $0 } }
            active -= 1
        }
        for _ in 0..<100 { watcher.receive(path: root.appendingPathComponent("first").path) }
        try await waitUntil { release != nil }
        for _ in 0..<100 { watcher.receive(path: root.appendingPathComponent("second").path) }
        release?.resume()
        try await waitUntil { batches.count == 2 }
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(batches.map { $0.paths.count }, [1, 1])
        XCTAssertTrue(batches[1].paths.contains(root.appendingPathComponent("second").path))
    }

    func testMetadataNoiseIsIgnoredAndDroppedEventsRequestRescan() async throws {
        var batches: [RepositoryFileWatcher.Batch] = []
        let watcher = RepositoryFileWatcher(delay: .milliseconds(20)) { batches.append($0) }
        let directory = root.appendingPathComponent(".git")
        watcher.watch(worktrees: [root], gitDirectories: [directory])
        for path in ["index.lock", "objects/ab/object", "logs/HEAD", "hooks/pre-commit"] {
            watcher.receive(path: directory.appendingPathComponent(path).path)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(batches.isEmpty)
        watcher.receive(path: directory.appendingPathComponent("index").path)
        try await waitUntil { batches.count == 1 }
        XCTAssertTrue(batches[0].refreshAll)
        XCTAssertFalse(batches[0].reloadRepository)
        watcher.receive(path: root.path, mustRescan: true)
        try await waitUntil { batches.count == 2 }
        XCTAssertTrue(batches[1].reloadRepository)
        XCTAssertTrue(batches[1].refreshAll)
    }

    private func write(_ text: String, to path: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func diff(_ model: WorktreeModel, contains text: String) -> Bool {
        model.diff?.contains { $0.hunks.contains { $0.lines.contains { $0.text == text } } } == true
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("自动刷新未在预期时间内完成", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
