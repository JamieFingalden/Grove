import Foundation

enum PullRequestPromptBuilder {
    struct Input: Sendable {
        var committedDiff: String
        var commitSubjects: [String]
        var fileSummary: String
        var maxDiffBytes: Int = 32 * 1024
    }

    struct Result: Sendable {
        var text: String
        var wasTruncated: Bool
    }

    static func build(_ input: Input) -> Result {
        let limit = max(0, input.maxDiffBytes)
        let wasTruncated = Data(input.committedDiff.utf8).count > limit
        let diff = wasTruncated
            ? CommitPromptBuilder.limitedDiff(input.committedDiff, byteLimit: limit)
            : input.committedDiff
        let subjects = input.commitSubjects.prefix(50)
            .map { "- \(CommitPromptBuilder.limited($0, byteLimit: 512))" }
            .joined(separator: "\n")
        let summary = CommitPromptBuilder.limited(input.fileSummary, byteLimit: 16 * 1024)
        let truncationNotice = wasTruncated
            ? "注意：提交 diff 过大，下面只包含按文件截取的片段。不要编造未展示的改动。"
            : "下面是这个 PR 的完整已提交 diff。"

        let text = """
        请只根据下面提供的文本生成 Pull Request 描述，不要读取工作区文件或运行命令。未提交的改动不属于这个 PR，也不应被提及。

        这个 PR 包含的提交标题：
        \(subjects.isEmpty ? "（没有可用的提交标题。）" : subjects)

        文件摘要：
        \(summary)

        \(truncationNotice)

        已提交 diff：
        \(diff)

        按所提供的 JSON schema 输出。body 使用简洁、可直接发布的 Markdown，说明做了什么、为什么以及能从改动中确认的测试情况；不要解释生成过程，不要使用包裹全文的代码块，不要编造信息。
        """
        return Result(text: text, wasTruncated: wasTruncated)
    }
}

struct CodexPullRequestGenerator {
    struct PreparedInput: Sendable {
        var prompt: String
        var wasTruncated: Bool
        var byteCount: Int { Data(prompt.utf8).count }
    }

    struct GeneratedDescription: Sendable {
        var body: String
        var wasTruncated: Bool
    }

    private struct StructuredOutput: Decodable {
        var body: String
    }

    static func prepare(in directory: URL, base: String, git: GitClient) async throws -> PreparedInput {
        guard let baseOID = await git.resolveBaseCommit(base, in: directory) else {
            throw CodexGenerationError.baseBranchNotFound(base)
        }
        async let diff = git.committedDiff(from: baseOID, in: directory)
        async let stat = git.committedDiffStat(from: baseOID, in: directory)
        async let subjects = git.commitSubjects(from: baseOID, in: directory)
        let result = PullRequestPromptBuilder.build(.init(
            committedDiff: try await diff,
            commitSubjects: try await subjects,
            fileSummary: try await stat
        ))
        return PreparedInput(prompt: result.text, wasTruncated: result.wasTruncated)
    }

    static func generate(in directory: URL, base: String, git: GitClient) async throws -> GeneratedDescription {
        let input = try await prepare(in: directory, base: base, git: git)
        let schema = """
        {"type":"object","properties":{"body":{"type":"string"}},"required":["body"],"additionalProperties":false}
        """
        let data = try await CodexRunner.run(prompt: input.prompt, schema: schema, in: directory)
        guard let output = try? JSONDecoder().decode(StructuredOutput.self, from: data) else {
            throw CodexGenerationError.invalidOutput
        }
        let body = CommitMessageCleaner.clean(output.body)
        guard !body.isEmpty else { throw CodexGenerationError.emptyOutput }
        return GeneratedDescription(body: body, wasTruncated: input.wasTruncated)
    }
}
