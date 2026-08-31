import Foundation

struct CodexCommitGenerator {
    static let outputSchema = """
    {"type":"object","properties":{"subject":{"type":"string"},"body":{"type":"string"}},"required":["subject","body"],"additionalProperties":false}
    """

    struct PreparedInput: Sendable {
        var prompt: String
        var wasTruncated: Bool

        var byteCount: Int { Data(prompt.utf8).count }
    }

    struct GeneratedMessage: Sendable {
        var text: String
        var wasTruncated: Bool
    }

    private struct StructuredOutput: Decodable {
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
        return PreparedInput(prompt: result.text, wasTruncated: result.wasTruncated)
    }

    static func generate(
        in directory: URL,
        git: GitClient,
        model: AIGenerationModel
    ) async throws -> GeneratedMessage {
        let input = try await prepare(in: directory, git: git)
        let data = try await CodexRunner.run(
            prompt: input.prompt,
            schema: outputSchema,
            model: model,
            in: directory
        )
        guard let output = try? JSONDecoder().decode(StructuredOutput.self, from: data) else {
            throw CodexGenerationError.invalidOutput
        }
        let subject = CommitMessageCleaner.clean(output.subject)
        let body = CommitMessageCleaner.clean(output.body ?? "")
        guard !subject.isEmpty else { throw CodexGenerationError.emptyOutput }
        let message = body.isEmpty ? subject : "\(subject)\n\n\(body)"
        return GeneratedMessage(text: message, wasTruncated: input.wasTruncated)
    }
}
