import Foundation

struct CodexModelOption: Identifiable, Sendable, Hashable {
    var id: String { model.rawValue }
    var model: AIGenerationModel
    var displayName: String
    var summary: String
    var reasoningEfforts: [AIReviewReasoningEffort]
}

enum CodexModelCatalog {
    static let defaults = AIGenerationModel.allCases.map {
        CodexModelOption(
            model: $0,
            displayName: $0.name,
            summary: $0.summary,
            reasoningEfforts: AIReviewReasoningEffort.available(for: $0)
        )
    }

    static func fetch() async throws -> [CodexModelOption] {
        guard let executable = await ToolLocator.shared.locate("codex") else {
            throw CodexGenerationError.notInstalled
        }
        do {
            let result = try await ProcessRunner.runChecked(
                executable: executable,
                arguments: ["debug", "models"],
                environment: await ToolLocator.shared.childEnvironment(),
                timeout: ProcessRunner.networkTimeout
            )
            return try decode(result.standardOutput)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexGenerationError {
            throw error
        } catch let error as CommandFailure {
            throw CodexGenerationError.commandFailed(error.output)
        } catch {
            throw CodexGenerationError.invalidOutput
        }
    }

    static func decode(_ data: Data) throws -> [CodexModelOption] {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            throw CodexGenerationError.invalidOutput
        }
        let models = catalog.models.compactMap(CodexModelOption.init(entry:))
        guard !models.isEmpty else { throw CodexGenerationError.invalidOutput }
        return models.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private struct Catalog: Decodable {
        var models: [Entry]
    }

    fileprivate struct Entry: Decodable {
        var slug: String
        var displayName: String?
        var description: String?
        var visibility: String?
        var supportedReasoningLevels: [ReasoningLevel]?

        enum CodingKeys: String, CodingKey {
            case slug
            case displayName = "display_name"
            case description
            case visibility
            case supportedReasoningLevels = "supported_reasoning_levels"
        }
    }

    fileprivate struct ReasoningLevel: Decodable {
        var effort: String
    }
}

fileprivate extension CodexModelOption {
    init?(entry: CodexModelCatalog.Entry) {
        guard entry.visibility == "list", let model = AIGenerationModel(rawValue: entry.slug) else {
            return nil
        }
        let efforts = entry.supportedReasoningLevels?
            .compactMap { AIReviewReasoningEffort(rawValue: $0.effort) } ?? []
        self.init(
            model: model,
            displayName: entry.displayName ?? entry.slug,
            summary: entry.description ?? model.summary,
            reasoningEfforts: efforts.isEmpty ? AIReviewReasoningEffort.available(for: model) : efforts
        )
    }
}
