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
        XCTAssertTrue(result.text.contains("具体行为变化或修复结果"))
        XCTAssertTrue(result.text.contains("不得只用“完善”“优化”“调整”"))
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
        XCTAssertNotNil(result.note)
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
        XCTAssertNil(result.note)
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
        XCTAssertNotNil(result.note)
        XCTAssertTrue(result.text.contains("diff 过大"))
        XCTAssertLessThan(result.text.utf8.count, 2_000)
    }
}

/// DiffBudget：超大 diff 的智能取舍策略。锁定「跳过低价值文件、
/// 优先完整保留核心代码、绝不超预算」这三个行为。
final class DiffBudgetTests: XCTestCase {
    private func fileDiff(_ path: String, lines: Int, marker: String = "+code") -> String {
        """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        @@ -0,0 +1,\(lines) @@
        \(Array(repeating: marker, count: lines).joined(separator: "\n"))
        """
    }

    func testSmallDiffPassesThroughUntouched() {
        let diff = fileDiff("src/app.swift", lines: 5)
        let plan = DiffBudget.plan(diff: diff, byteLimit: 10_000)

        XCTAssertFalse(plan.wasTruncated)
        XCTAssertNil(plan.notice)
        XCTAssertEqual(plan.diff, diff)
    }

    func testTestFilesAreSkippedFirstAndListedByName() {
        let core = fileDiff("src/payment.swift", lines: 30)
        let tests = fileDiff("Tests/PaymentTests.swift", lines: 2_000)
        let diff = core + "\n" + tests
        // 预算只够放核心文件，测试文件必须让路。
        let plan = DiffBudget.plan(diff: diff, byteLimit: Data(core.utf8).count + 600)

        XCTAssertTrue(plan.wasTruncated)
        XCTAssertTrue(plan.diff.contains("src/payment.swift"))
        XCTAssertTrue(plan.diff.contains("Tests/PaymentTests.swift"), "被跳过的文件必须留下名字")
        XCTAssertTrue(plan.diff.contains("已整体省略"))
        XCTAssertFalse(plan.diff.contains(String(repeating: "+code", count: 100)), "测试内容不应占据预算")
        XCTAssertLessThanOrEqual(Data(plan.diff.utf8).count, Data(core.utf8).count + 600)
    }

    func testLockAndGeneratedFilesAreLowValue() {
        XCTAssertTrue(DiffBudget.isLowValue("web/package-lock.json"))
        XCTAssertTrue(DiffBudget.isLowValue("Pods/Alamofire/Swift"))
        XCTAssertTrue(DiffBudget.isLowValue("src/proto/service_pb2.py"))
        XCTAssertTrue(DiffBudget.isLowValue("tests/test_payment.py"))
        XCTAssertTrue(DiffBudget.isLowValue("ios/App/en.lproj/Localizable.strings"))
        XCTAssertTrue(DiffBudget.isLowValue("a/Assets/icon.svg"))
        XCTAssertFalse(DiffBudget.isLowValue("Sources/Grove/AI/DiffBudget.swift"))
        XCTAssertFalse(DiffBudget.isLowValue("model/Building/Masonry_Optimization_Dxf.py"))
        XCTAssertFalse(DiffBudget.isLowValue("latest_news.md"))
    }

    func testCoreFilesAreNeverDroppedSilentlyAndBudgetIsRespected() {
        let sections = (0..<20).map { fileDiff("src/file\($0).swift", lines: 200) }
        let diff = sections.joined(separator: "\n")
        let limit = 4_000
        let plan = DiffBudget.plan(diff: diff, byteLimit: limit)

        XCTAssertTrue(plan.wasTruncated)
        XCTAssertNotNil(plan.notice)
        // 每个核心文件都必须出现（完整或截断或进清单）。
        for index in 0..<20 {
            XCTAssertTrue(plan.diff.contains("src/file\(index).swift"), "file\(index) 消失了")
        }
        XCTAssertLessThanOrEqual(Data(plan.diff.utf8).count, limit, "任何情况下都不能超预算")
    }

    func testLowValueFilesAreKeptWhenBudgetIsAmple() {
        let core = fileDiff("src/app.swift", lines: 50)
        let tests = fileDiff("Tests/AppTests.swift", lines: 60)
        let diff = core + "\n" + tests
        // 预算远大于总 diff：跳过规则不应触发。
        let plan = DiffBudget.plan(diff: diff, byteLimit: 1_000_000)

        XCTAssertFalse(plan.wasTruncated)
        XCTAssertTrue(plan.diff.contains("AppTests.swift"))
    }

    func testSingleOversizedFileIsTrimmedWithMarker() {
        let diff = fileDiff("src/huge.swift", lines: 2_000)
        let plan = DiffBudget.plan(diff: diff, byteLimit: 800)

        XCTAssertTrue(plan.wasTruncated)
        XCTAssertTrue(plan.diff.contains("diff 过大"))
        XCTAssertTrue(plan.diff.contains("被截断"))
        XCTAssertLessThanOrEqual(Data(plan.diff.utf8).count, 800)
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

final class AIGenerationSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AIGenerationSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToDisabled() {
        XCTAssertFalse(AIGenerationSettings(defaults: defaults).isEnabled)
    }

    func testPersistsGlobalEnabledState() {
        let settings = AIGenerationSettings(defaults: defaults)
        settings.setEnabled(true)
        XCTAssertTrue(AIGenerationSettings(defaults: defaults).isEnabled)
    }

    func testUsesSeparateDefaultsAndPersistsSelectedModels() {
        let settings = AIGenerationSettings(defaults: defaults)
        XCTAssertEqual(settings.commitModel, .luna)
        XCTAssertEqual(settings.reviewModel, .terra)

        settings.setCommitModel(.terra)
        settings.setReviewModel(.sol)
        settings.setReviewReasoningEffort(.xhigh)
        let reloaded = AIGenerationSettings(defaults: defaults)
        XCTAssertEqual(reloaded.commitModel, .terra)
        XCTAssertEqual(reloaded.reviewModel, .sol)
        XCTAssertEqual(reloaded.reviewReasoningEffort, .xhigh)
    }

    func testPersistsAPIProviderConfiguration() {
        let settings = AIGenerationSettings(defaults: defaults)
        settings.setProvider(.api)
        settings.setAPIBaseURL("https://api.deepseek.com/v1")
        settings.setAPIModel("deepseek-chat")

        let reloaded = AIGenerationSettings(defaults: defaults)
        XCTAssertEqual(reloaded.provider, .api)
        XCTAssertEqual(reloaded.apiBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(reloaded.apiModel, "deepseek-chat")
    }

    func testPreservesManuallyEnteredCodexModel() throws {
        let settings = AIGenerationSettings(defaults: defaults)
        let custom = try XCTUnwrap(AIGenerationModel(rawValue: "gpt-5.3-codex"))
        settings.setCommitModel(custom)

        XCTAssertEqual(AIGenerationSettings(defaults: defaults).commitModel.rawValue, "gpt-5.3-codex")
    }

    func testPersistsReviewInstructionsPerRepository() {
        let first = URL(fileURLWithPath: "/repo/first")
        let second = URL(fileURLWithPath: "/repo/second")
        let settings = AIGenerationSettings(defaults: defaults)

        settings.setReviewInstructions("重点检查坐标换算", for: first)
        let reloaded = AIGenerationSettings(defaults: defaults)
        XCTAssertEqual(reloaded.reviewInstructions(for: first), "重点检查坐标换算")
        XCTAssertEqual(
            reloaded.reviewInstructions(for: second),
            PullRequestReviewPromptBuilder.defaultInstructions
        )

        reloaded.resetReviewInstructions(for: first)
        XCTAssertEqual(
            AIGenerationSettings(defaults: defaults).reviewInstructions(for: first),
            PullRequestReviewPromptBuilder.defaultInstructions
        )
    }

    func testPersistsReviewAreasPerRepository() {
        let first = URL(fileURLWithPath: "/repo/first")
        let second = URL(fileURLWithPath: "/repo/second")
        let selected: Set<PullRequestAIReview.Assessment.Area> = [.compilation, .performance]
        let settings = AIGenerationSettings(defaults: defaults)

        XCTAssertEqual(
            settings.reviewAreas(for: first),
            Set(PullRequestAIReview.Assessment.Area.allCases)
        )
        settings.setReviewAreas(selected, for: first)

        let reloaded = AIGenerationSettings(defaults: defaults)
        XCTAssertEqual(reloaded.reviewAreas(for: first), selected)
        XCTAssertEqual(
            reloaded.reviewAreas(for: second),
            Set(PullRequestAIReview.Assessment.Area.allCases)
        )
    }
}

final class CodexRunnerArgumentsTests: XCTestCase {
    func testPassesSelectedModelToCodexCLI() throws {
        let arguments = CodexRunner.arguments(
            model: .luna,
            directory: URL(fileURLWithPath: "/repo"),
            outputURL: URL(fileURLWithPath: "/tmp/output.json"),
            schemaURL: URL(fileURLWithPath: "/tmp/schema.json")
        )

        let modelFlag = try XCTUnwrap(arguments.firstIndex(of: "--model"))
        XCTAssertEqual(arguments[modelFlag + 1], "gpt-5.6-luna")
    }

    func testPassesReviewReasoningEffortToCodexCLI() throws {
        let arguments = CodexRunner.arguments(
            model: .terra,
            reasoningEffort: .high,
            directory: URL(fileURLWithPath: "/repo"),
            outputURL: URL(fileURLWithPath: "/tmp/output.json"),
            schemaURL: URL(fileURLWithPath: "/tmp/schema.json")
        )

        let configFlag = try XCTUnwrap(arguments.firstIndex(of: "--config"))
        XCTAssertEqual(arguments[configFlag + 1], "model_reasoning_effort=\"high\"")
    }
}

final class OpenAICompatibleRunnerTests: XCTestCase {
    func testBuildsChatCompletionsRequestFromAPIBaseURL() throws {
        let configuration = AIAPIConfiguration(
            baseURL: "https://api.example.com/v1/",
            model: "example-model",
            apiKey: "test-key"
        )
        let request = try OpenAICompatibleRunner.makeRequest(
            prompt: "根据 diff 生成提交信息。",
            schema: "{\"type\":\"object\"}",
            configuration: configuration,
            timeout: 180
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "example-model")
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("JSON Schema") == true)
        // 默认不发送思考参数，避免不支持的网关拒绝请求。
        XCTAssertNil(object["thinking"])
    }

    func testDisabledThinkingIsSentInRequestBody() throws {
        let configuration = AIAPIConfiguration(
            baseURL: "https://api.example.com/v1",
            model: "example-model",
            apiKey: "test-key",
            thinking: .disabled
        )
        let request = try OpenAICompatibleRunner.makeRequest(
            prompt: "审查这次改动。",
            schema: "{\"type\":\"object\"}",
            configuration: configuration,
            timeout: 300
        )

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try XCTUnwrap(object["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "disabled")
    }

    func testEnabledThinkingIsSentInRequestBody() throws {
        let configuration = AIAPIConfiguration(
            baseURL: "https://api.example.com/v1",
            model: "example-model",
            apiKey: "test-key",
            thinking: .enabled
        )
        let request = try OpenAICompatibleRunner.makeRequest(
            prompt: "审查这次改动。",
            schema: "{\"type\":\"object\"}",
            configuration: configuration,
            timeout: 300
        )

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let thinking = try XCTUnwrap(object["thinking"] as? [String: String])
        XCTAssertEqual(thinking["type"], "enabled")
    }

    func testKeepsExplicitChatCompletionsEndpoint() {
        let configuration = AIAPIConfiguration(
            baseURL: "https://gateway.example.com/custom/chat/completions",
            model: "example-model",
            apiKey: "test-key"
        )

        XCTAssertEqual(
            configuration.endpoint?.absoluteString,
            "https://gateway.example.com/custom/chat/completions"
        )
    }

    func testBuildsModelsRequestFromExplicitChatEndpoint() throws {
        let request = try OpenAICompatibleRunner.makeModelsRequest(configuration: .init(
            baseURL: "https://gateway.example.com/custom/chat/completions",
            model: "example-model",
            apiKey: "test-key"
        ))

        XCTAssertEqual(request.url?.absoluteString, "https://gateway.example.com/custom/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }
}

final class CodexModelCatalogTests: XCTestCase {
    func testDecodesVisibleModelsAndTheirReasoningEfforts() throws {
        let data = Data("""
        {"models":[
          {"slug":"gpt-5.6-sol","display_name":"GPT-5.6 Sol","description":"旗舰模型","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"ultra"}]},
          {"slug":"hidden-model","visibility":"hidden","supported_reasoning_levels":[]}
        ]}
        """.utf8)

        let models = try CodexModelCatalog.decode(data)
        XCTAssertEqual(models.map(\.id), ["gpt-5.6-sol"])
        XCTAssertEqual(models[0].reasoningEfforts, [.low, .ultra])
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

        let result = try await CodexCommitGenerator.generate(in: root, git: git, model: .luna)
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
