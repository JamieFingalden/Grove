import Foundation

enum CodexRunner {
    static func run(
        prompt: String,
        schema: String,
        model: AIGenerationModel,
        in directory: URL
    ) async throws -> Data {
        guard let executable = await ToolLocator.shared.locate("codex") else {
            throw CodexGenerationError.notInstalled
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grove-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("message.json")
        let schemaURL = temporaryDirectory.appendingPathComponent("schema.json")
        try Data(schema.utf8).write(to: schemaURL, options: .atomic)

        do {
            try await ProcessRunner.runChecked(
                executable: executable,
                arguments: arguments(
                    model: model,
                    directory: directory,
                    outputURL: outputURL,
                    schemaURL: schemaURL
                ),
                workingDirectory: directory,
                environment: await ToolLocator.shared.childEnvironment(),
                timeout: ProcessRunner.networkTimeout,
                standardInput: Data(prompt.utf8)
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch is CommandTimeout {
            throw CodexGenerationError.timeout
        } catch let failure as CommandFailure {
            throw CodexGenerationError.commandFailed(failure.output)
        }

        guard let data = try? Data(contentsOf: outputURL), !data.isEmpty else {
            throw CodexGenerationError.invalidOutput
        }
        return data
    }

    static func arguments(
        model: AIGenerationModel,
        directory: URL,
        outputURL: URL,
        schemaURL: URL
    ) -> [String] {
        [
            "exec", "--cd", directory.path,
            "--model", model.rawValue,
            "--sandbox", "read-only",
            "--ephemeral",
            "--output-last-message", outputURL.path,
            "--output-schema", schemaURL.path,
            "-"
        ]
    }
}

enum CodexGenerationError: LocalizedError, Sendable, Equatable {
    case notInstalled
    case timeout
    case commandFailed(String)
    case invalidOutput
    case emptyOutput
    case baseBranchNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "找不到 Codex CLI。请在终端运行 npm install -g @openai/codex，然后运行 codex login。"
        case .timeout:
            "模型没在 180 秒内返回。你可以点“重试”再生成一次。"
        case .commandFailed(let detail):
            if detail.localizedCaseInsensitiveContains("auth")
                || detail.localizedCaseInsensitiveContains("login")
                || detail.localizedCaseInsensitiveContains("unauthorized") {
                detail + "\n\n请在终端运行 codex login 后重试。"
            } else {
                detail
            }
        case .invalidOutput:
            "Codex 返回了无法读取的结果。请重试；如果仍然失败，请先运行 codex --version 确认 CLI 已更新。"
        case .emptyOutput:
            "Codex 返回了空内容。请重试。"
        case .baseBranchNotFound(let branch):
            "找不到目标分支 \(branch)。请检查目标分支名称，必要时先抓取远端。"
        }
    }
}
