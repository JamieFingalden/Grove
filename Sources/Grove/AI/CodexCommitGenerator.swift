import Foundation

struct CodexCommitGenerator {
    /// `type` 是标题的 Conventional Commits 类型，用 enum 限制取值。
    /// 让模型单独填一个枚举字段，比指望它在自由文本里记得加前缀可靠得多；
    /// 标题整个漏掉前缀时，`CommitSubjectFormatter` 会用这个字段补上。
    static let outputSchema: String = {
        let types = CommitSubjectFormatter.allowedTypes
            .map { "\"\($0)\"" }
            .joined(separator: ",")
        return """
        {"type":"object","properties":{"type":{"type":"string","enum":[\(types)]},"subject":{"type":"string"},"body":{"type":"string"}},"required":["type","subject","body"],"additionalProperties":false}
        """
    }()

    struct PreparedInput: Sendable {
        var prompt: String
        var wasTruncated: Bool
        /// 取舍说明（跳过/截断了哪些文件），无内容丢失时为 nil。
        var note: String?

        var byteCount: Int { Data(prompt.utf8).count }
    }

    struct GeneratedMessage: Sendable {
        var text: String
        var wasTruncated: Bool
        var note: String?
    }

    private struct StructuredOutput: Decodable {
        /// 类型声明是冗余信号：schema 限制为枚举，但 API 网关不一定严格执行
        /// schema，所以按可选解码，交给 `CommitSubjectFormatter` 校验取用。
        var type: String?
        var subject: String
        var body: String?
    }

    static func prepare(in directory: URL, git: GitClient) async throws -> PreparedInput {
        async let diff = git.stagedDiffText(in: directory)
        async let stat = git.stagedDiffStat(in: directory)
        async let subjects = git.recentCommitSubjects(in: directory, limit: 20)
        let input = CommitPromptBuilder.Input(
            stagedDiff: try await diff,
            recentSubjects: try await subjects,
            fileSummary: try await stat
        )
        let result = CommitPromptBuilder.build(input)
        return PreparedInput(prompt: result.text, wasTruncated: result.wasTruncated, note: result.note)
    }

    static func generate(
        in directory: URL,
        git: GitClient,
        model: AIGenerationModel,
        service: AIGenerationService? = nil
    ) async throws -> GeneratedMessage {
        let input = try await prepare(in: directory, git: git)
        return try await AIGenerationRunner.run(
            prompt: input.prompt,
            schema: outputSchema,
            service: service ?? .codex(model: model, reasoningEffort: nil),
            in: directory,
            operation: "提交信息"
        ) { data in
            guard let output = try? JSONDecoder().decode(StructuredOutput.self, from: data) else {
                throw CodexGenerationError.invalidOutput
            }
            let subject = CommitSubjectFormatter.canonicalize(
                CommitMessageCleaner.clean(output.subject),
                declaredType: output.type
            )
            let body = CommitMessageCleaner.clean(output.body ?? "")
            guard !subject.isEmpty else { throw CodexGenerationError.emptyOutput }
            let message = body.isEmpty ? subject : "\(subject)\n\n\(body)"
            return GeneratedMessage(text: message, wasTruncated: input.wasTruncated, note: input.note)
        }
    }
}
