import Foundation

enum AIGenerationModel: String, CaseIterable, Identifiable, Sendable {
    case luna = "gpt-5.6-luna"
    case terra = "gpt-5.6-terra"
    case sol = "gpt-5.6-sol"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .luna: "GPT-5.6 Luna"
        case .terra: "GPT-5.6 Terra"
        case .sol: "GPT-5.6 Sol"
        }
    }

    var summary: String {
        switch self {
        case .luna: "速度快、开销低，适合生成提交信息和日常 PR 描述。"
        case .terra: "能力与速度更均衡，适合改动较复杂的仓库。"
        case .sol: "能力最强，但通常更慢；适合复杂改动和高要求描述。"
        }
    }

    var reviewSummary: String {
        switch self {
        case .luna: "速度最快，但代码审查能力有限，适合很小、风险低的改动。"
        case .terra: "AI Review 默认模型，速度和代码推理能力更均衡。"
        case .sol: "审查能力最强、耗时也更长，适合复杂或高风险改动。"
        }
    }
}

/// Grove 全局 AI 偏好。是否发送代码和使用哪个模型都属于应用行为，
/// 不应该散落在每个仓库自己的菜单里。
struct AIGenerationSettings {
    private let enabledKey = "grove.aiGeneration.enabled.v3"
    private let commitModelKey = "grove.aiGeneration.model.v1"
    private let reviewModelKey = "grove.aiReview.model.v1"
    private let reviewInstructionsKey = "grove.aiReview.promptByRepository.v2"
    private let reviewAreasKey = "grove.aiReview.areasByRepository.v1"
    private let legacyReviewInstructionsKey = "grove.aiReview.instructionsByRepository.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.bool(forKey: enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: enabledKey)
    }

    var commitModel: AIGenerationModel {
        defaults.string(forKey: commitModelKey).flatMap(AIGenerationModel.init(rawValue:)) ?? .luna
    }

    func setCommitModel(_ model: AIGenerationModel) {
        defaults.set(model.rawValue, forKey: commitModelKey)
    }

    var reviewModel: AIGenerationModel {
        defaults.string(forKey: reviewModelKey).flatMap(AIGenerationModel.init(rawValue:)) ?? .terra
    }

    func setReviewModel(_ model: AIGenerationModel) {
        defaults.set(model.rawValue, forKey: reviewModelKey)
    }

    func reviewInstructions(for repository: URL) -> String {
        let values = defaults.dictionary(forKey: reviewInstructionsKey) as? [String: String] ?? [:]
        let key = repository.standardizedFileURL.path
        if let prompt = values[key] { return prompt }

        let legacy = defaults.dictionary(forKey: legacyReviewInstructionsKey) as? [String: String] ?? [:]
        if let supplemental = legacy[key], !supplemental.isEmpty {
            return PullRequestReviewPromptBuilder.defaultInstructions
                + "\n\n项目补充规则：\n"
                + supplemental
        }
        return PullRequestReviewPromptBuilder.defaultInstructions
    }

    func setReviewInstructions(_ instructions: String, for repository: URL) {
        var values = defaults.dictionary(forKey: reviewInstructionsKey) as? [String: String] ?? [:]
        let key = repository.standardizedFileURL.path
        values[key] = instructions
        defaults.set(values, forKey: reviewInstructionsKey)
    }

    func resetReviewInstructions(for repository: URL) {
        let key = repository.standardizedFileURL.path
        var values = defaults.dictionary(forKey: reviewInstructionsKey) as? [String: String] ?? [:]
        values.removeValue(forKey: key)
        defaults.set(values, forKey: reviewInstructionsKey)

        var legacy = defaults.dictionary(forKey: legacyReviewInstructionsKey) as? [String: String] ?? [:]
        legacy.removeValue(forKey: key)
        defaults.set(legacy, forKey: legacyReviewInstructionsKey)
    }

    func reviewAreas(for repository: URL) -> Set<PullRequestAIReview.Assessment.Area> {
        let values = defaults.dictionary(forKey: reviewAreasKey) ?? [:]
        let key = repository.standardizedFileURL.path
        guard let rawValues = values[key] as? [String] else {
            return Set(PullRequestAIReview.Assessment.Area.allCases)
        }
        let areas = Set(rawValues.compactMap(PullRequestAIReview.Assessment.Area.init(rawValue:)))
        return areas.isEmpty ? Set(PullRequestAIReview.Assessment.Area.allCases) : areas
    }

    func setReviewAreas(
        _ areas: Set<PullRequestAIReview.Assessment.Area>,
        for repository: URL
    ) {
        guard !areas.isEmpty else { return }
        var values = defaults.dictionary(forKey: reviewAreasKey) ?? [:]
        values[repository.standardizedFileURL.path] = PullRequestAIReview.Assessment.Area.allCases
            .filter(areas.contains)
            .map(\.rawValue)
        defaults.set(values, forKey: reviewAreasKey)
    }
}
