import Foundation

enum TagMessageGenerator {
    private struct Output: Decodable {
        var body: String
    }

    static func prepare(
        in directory: URL, name: String, commit: CommitSummary, git: GitClient
    ) async throws -> (prompt: String, note: String?) {
        let files = try await git.commitDiff(in: directory, oid: commit.oid)
        let safeFiles = files.filter { !DiffBudget.isSecretFile($0) }
        let plan = DiffBudget.plan(
            diff: PullRequestReviewPromptBuilder.unifiedDiff(safeFiles),
            byteLimit: CommitPromptBuilder.defaultMaxDiffBytes
        )
        let secretCount = files.count - safeFiles.count
        let notices = [plan.notice, secretCount > 0 ? "已排除 \(secretCount) 个疑似凭据文件的内容。" : nil]
            .compactMap { $0 }
        let summary = files.map { "\($0.displayPath)：+\($0.additions) / -\($0.deletions)" }
            .joined(separator: "\n")
        let prompt = """
        请只根据下面提供的所选提交生成附注标签说明，不要读取工作区文件或运行命令。
        说明只覆盖这个提交，不代表上个标签以来的完整发布记录。不要提及未提交的改动，不要编造测试结果或版本范围。

        标签名：\(CommitPromptBuilder.limited(name, byteLimit: 512))
        所选提交：\(commit.oid)
        提交标题：\(CommitPromptBuilder.limited(commit.subject, byteLimit: 2 * 1024))
        提交正文：
        \(CommitPromptBuilder.limited(commit.body, byteLimit: 8 * 1024))

        文件摘要：
        \(CommitPromptBuilder.limited(summary, byteLimit: 16 * 1024))

        \(notices.isEmpty ? "下面是所选提交的完整 diff。" : notices.joined(separator: "\n"))
        \(plan.diff)

        按提供的 JSON schema 输出，body 使用简洁中文说明主要变化及其作用，可直接作为标签正文；不要解释生成过程，不要使用包裹全文的代码块。
        """
        return (prompt, notices.isEmpty ? nil : notices.joined(separator: "\n"))
    }

    static func generate(
        in directory: URL, name: String, commit: CommitSummary, git: GitClient,
        service: AIGenerationService
    ) async throws -> (message: String, note: String?) {
        let input = try await prepare(in: directory, name: name, commit: commit, git: git)
        let message = try await AIGenerationRunner.run(
            prompt: input.prompt,
            schema: """
            {"type":"object","properties":{"body":{"type":"string"}},"required":["body"],"additionalProperties":false}
            """,
            service: service,
            in: directory,
            operation: "标签说明",
            context: .init(head: commit.oid),
            decode: decode
        )
        return (message, input.note)
    }

    static func decode(_ data: Data) throws -> String {
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else {
            throw CodexGenerationError.invalidOutput
        }
        let message = CommitMessageCleaner.clean(output.body)
        guard !message.isEmpty else { throw CodexGenerationError.emptyOutput }
        return message
    }
}
