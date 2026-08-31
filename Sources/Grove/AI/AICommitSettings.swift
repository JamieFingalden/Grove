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
}

/// Grove 全局 AI 偏好。是否发送代码和使用哪个模型都属于应用行为，
/// 不应该散落在每个仓库自己的菜单里。
struct AIGenerationSettings {
    private let enabledKey = "grove.aiGeneration.enabled.v3"
    private let modelKey = "grove.aiGeneration.model.v1"
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

    var model: AIGenerationModel {
        defaults.string(forKey: modelKey).flatMap(AIGenerationModel.init(rawValue:)) ?? .luna
    }

    func setModel(_ model: AIGenerationModel) {
        defaults.set(model.rawValue, forKey: modelKey)
    }
}
