import Foundation
import XCTest
@testable import Grove

final class CommitPromptBuilderTests: XCTestCase {
    func testSmallDiffIsIncludedWithoutTruncation() {
        let diff = "diff --git a/a.txt b/a.txt\n+hello"
        let result = CommitPromptBuilder.build(.init(
            stagedDiff: diff,
            recentSubjects: ["feat: 添加问候"],
            fileSummary: "a.txt | 1 +",
            maxDiffBytes: 1024
        ))

        XCTAssertFalse(result.wasTruncated)
        XCTAssertTrue(result.text.contains(diff))
        XCTAssertTrue(result.text.contains("下面是完整的暂存区 diff"))
    }

    func testLargeDiffIsBoundedAndDisclosesTruncation() {
        let diff = "diff --git a/a.txt b/a.txt\n" + String(repeating: "+很长的改动\n", count: 100)
        let result = CommitPromptBuilder.build(.init(
            stagedDiff: diff,
            recentSubjects: [],
            fileSummary: "a.txt | 100 +",
            maxDiffBytes: 120
        ))

        XCTAssertTrue(result.wasTruncated)
        XCTAssertTrue(result.text.contains("diff 过大"))
        XCTAssertLessThan(result.text.utf8.count, 18_000)
    }

    func testManyFilesCannotExceedDiffBudgetThroughSeparators() {
        let diff = (0..<1_000).map { "diff --git a/\($0) b/\($0)\n+x" }.joined(separator: "\n")
        let result = CommitPromptBuilder.build(.init(
            stagedDiff: diff,
            recentSubjects: [],
            fileSummary: "",
            maxDiffBytes: 100
        ))

        XCTAssertTrue(result.wasTruncated)
        XCTAssertLessThan(result.text.utf8.count, 2_000)
    }

    func testMergeSubjectsAreExcludedFromStyleSamples() {
        let result = CommitPromptBuilder.prompt(.init(
            stagedDiff: "+change",
            recentSubjects: ["Merge branch 'main'", "fix: 修复刷新"],
            fileSummary: "a.txt | 1 +"
        ))

        XCTAssertFalse(result.contains("Merge branch"))
        XCTAssertTrue(result.contains("fix: 修复刷新"))
    }

    func testNoHistoryDoesNotCrash() {
        let result = CommitPromptBuilder.prompt(.init(
            stagedDiff: "+change",
            recentSubjects: [],
            fileSummary: "a.txt | 1 +"
        ))
        XCTAssertTrue(result.contains("没有可用的历史提交标题"))
    }
}

final class CommitMessageCleanerTests: XCTestCase {
    func testCleansFencesPrefixesAndLineEndings() {
        XCTAssertEqual(
            CommitMessageCleaner.clean("\r\n```text\r\nfeat: 添加搜索\r\n```\r\n"),
            "feat: 添加搜索"
        )
        XCTAssertEqual(
            CommitMessageCleaner.clean("Here is the commit message:\n\nfix: handle empty response\n"),
            "fix: handle empty response"
        )
        XCTAssertEqual(
            CommitMessageCleaner.clean("提交信息：chore: 更新依赖\n\n"),
            "chore: 更新依赖"
        )
    }
}

final class CodexOutputSchemaTests: XCTestCase {
    func testCommitSchemaRequiresEveryProperty() throws {
        let data = try XCTUnwrap(CodexCommitGenerator.outputSchema.data(using: .utf8))
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let required = Set(try XCTUnwrap(schema["required"] as? [String]))

        XCTAssertEqual(required, Set(properties.keys))
    }
}

final class PullRequestPromptBuilderTests: XCTestCase {
    func testUsesOnlyProvidedCommittedContext() {
        let result = PullRequestPromptBuilder.build(.init(
            committedDiff: "diff --git a/a.txt b/a.txt\n+published change",
            commitSubjects: ["feat: published change"],
            fileSummary: "a.txt | 1 +"
        ))

        XCTAssertFalse(result.wasTruncated)
        XCTAssertTrue(result.text.contains("published change"))
        XCTAssertTrue(result.text.contains("未提交的改动不属于这个 PR"))
    }

    func testLargePullRequestDiffIsTruncatedWithDisclosure() {
        let result = PullRequestPromptBuilder.build(.init(
            committedDiff: String(repeating: "+change\n", count: 1_000),
            commitSubjects: ["feat: large change"],
            fileSummary: "a.txt | 1000 +",
            maxDiffBytes: 100
        ))

        XCTAssertTrue(result.wasTruncated)
        XCTAssertTrue(result.text.contains("提交 diff 过大"))
        XCTAssertLessThan(result.text.utf8.count, 2_000)
    }
}

final class PullRequestAIContextTests: XCTestCase {
    func testCommittedDiffDoesNotIncludeUncommittedChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-pr-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = try await GitClient.resolve()
        _ = try await git.run(["init", "-b", "main"], in: root)
        _ = try await git.run(["config", "user.name", "Grove Tests"], in: root)
        _ = try await git.run(["config", "user.email", "grove@example.invalid"], in: root)
        let file = root.appendingPathComponent("feature.txt")
        try Data("base\n".utf8).write(to: file)
        try await git.stageAll(in: root)
        try await git.commit(message: "base", in: root)

        _ = try await git.run(["switch", "-c", "feature"], in: root)
        try Data("base\npublished change\n".utf8).write(to: file)
        try await git.stageAll(in: root)
        try await git.commit(message: "feat: published change", in: root)
        try Data("base\npublished change\nPRIVATE WORKING CHANGE\n".utf8).write(to: file)

        let resolvedBase = await git.resolveBaseCommit("main", in: root)
        let base = try XCTUnwrap(resolvedBase)
        let diff = try await git.committedDiff(from: base, in: root)
        XCTAssertTrue(diff.contains("published change"))
        XCTAssertFalse(diff.contains("PRIVATE WORKING CHANGE"))
    }
}

final class AICommitSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AICommitSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToDisabled() {
        XCTAssertFalse(AICommitSettings(defaults: defaults).isEnabled(for: URL(fileURLWithPath: "/tmp/repo")))
    }

    func testUsesNormalizedRepositoryPath() {
        let settings = AICommitSettings(defaults: defaults)
        settings.setEnabled(true, for: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(settings.isEnabled(for: URL(fileURLWithPath: "/private/tmp")))
    }
}

final class CodexCommitLiveTests: XCTestCase {
    func testGeneratesMessageWithRealCodex() async throws {
        guard ProcessInfo.processInfo.environment["GROVE_LIVE"] == "1" else {
            throw XCTSkip("设置 GROVE_LIVE=1 才运行联网测试")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-ai-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = try await GitClient.resolve()
        _ = try await git.run(["init"], in: root)
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("hello.txt"))
        try await git.stageAll(in: root)

        let result = try await CodexCommitGenerator.generate(in: root, git: git)
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
