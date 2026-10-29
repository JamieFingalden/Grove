import Foundation

enum AIGenerationModel: Identifiable, Sendable, Hashable {
    case luna
    case terra
    case sol
    case custom(String)

    static let allCases: [Self] = [.luna, .terra, .sol]

    init?(rawValue: String) {
        switch rawValue {
        case "gpt-5.6-luna": self = .luna
        case "gpt-5.6-terra": self = .terra
        case "gpt-5.6-sol": self = .sol
        default:
            guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            self = .custom(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .luna: "gpt-5.6-luna"
        case .terra: "gpt-5.6-terra"
        case .sol: "gpt-5.6-sol"
        case .custom(let value): value
        }
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .luna: "GPT-5.6 Luna"
        case .terra: "GPT-5.6 Terra"
        case .sol: "GPT-5.6 Sol"
        case .custom(let value): value
        }
    }

    var summary: String {
        switch self {
        case .luna: "速度快、开销低，适合生成提交信息和日常 PR 描述。"
        case .terra: "能力与速度更均衡，适合改动较复杂的仓库。"
        case .sol: "能力最强，但通常更慢；适合复杂改动和高要求描述。"
        case .custom: "从 Codex 获取或手动输入的模型。"
        }
    }

    var reviewSummary: String {
        switch self {
        case .luna: "速度最快，但代码审查能力有限，适合很小、风险低的改动。"
        case .terra: "AI Review 默认模型，速度和代码推理能力更均衡。"
        case .sol: "审查能力最强、耗时也更长，适合复杂或高风险改动。"
        case .custom: "从 Codex 获取或手动输入的模型。"
        }
    }
}

/// AI Review 的思考深度。较高档位会给模型更多推理预算，也会相应增加等待时间和额度消耗。
enum AIReviewReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var id: String { rawValue }

    var name: String {
        switch self {
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "很高"
        case .max: "最高"
        case .ultra: "极限"
        }
    }

    var summary: String {
        switch self {
        case .low: "速度优先，适合小改动的快速筛查。"
        case .medium: "速度与判断质量更均衡。"
        case .high: "默认值，适合常规合并前审查。"
        case .xhigh: "适合复杂改动，等待时间会更长。"
        case .max: "适合高风险或跨模块改动。"
        case .ultra: "仅用于最复杂的审查，耗时和额度消耗最高。"
        }
    }

    static func available(for model: AIGenerationModel) -> [Self] {
        switch model {
        case .luna: allCases.filter { $0 != .ultra }
        case .terra, .sol: allCases
        case .custom: allCases
        }
    }
}

/// Grove 全局 AI 偏好。是否发送代码和使用哪个模型都属于应用行为，
/// 不应该散落在每个仓库自己的菜单里。
struct AIGenerationSettings {
    private let enabledKey = "grove.aiGeneration.enabled.v3"
    private let providerKey = "grove.aiGeneration.provider.v1"
    private let commitModelKey = "grove.aiGeneration.model.v1"
    private let reviewModelKey = "grove.aiReview.model.v1"
    private let reviewReasoningEffortKey = "grove.aiReview.reasoningEffort.v1"
    private let apiBaseURLKey = "grove.aiGeneration.api.baseURL.v1"
    private let apiModelKey = "grove.aiGeneration.api.model.v1"
    private let apiThinkingKey = "grove.aiGeneration.api.thinking.v1"
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

    func automaticReviewEnabled(for repository: URL) -> Bool {
        let values = defaults.dictionary(forKey: "grove.aiReview.automaticByRepository.v1") as? [String: Bool] ?? [:]
        return values[repository.standardizedFileURL.path] ?? true
    }

    func setAutomaticReviewEnabled(_ enabled: Bool, for repository: URL) {
        var values = defaults.dictionary(forKey: "grove.aiReview.automaticByRepository.v1") as? [String: Bool] ?? [:]
        values[repository.standardizedFileURL.path] = enabled
        defaults.set(values, forKey: "grove.aiReview.automaticByRepository.v1")
    }

    /// 自动审查发现的风险是否**自动发布**到托管平台讨论区。与「是否自动审查」
    /// 分离且默认关闭：Grove 不在未明确授权的情况下以用户账号对外发言。
    /// 关闭时风险意见保留在本地缓存与通知里，可在请求详情页逐条发布；
    /// 手动 Review 一律不自动发布（AppModel.startAIReview 强制）。
    func automaticReviewPublishEnabled(for repository: URL) -> Bool {
        let values = defaults.dictionary(forKey: "grove.aiReview.autoPublishByRepository.v1") as? [String: Bool] ?? [:]
        return values[repository.standardizedFileURL.path] ?? false
    }

    func setAutomaticReviewPublishEnabled(_ enabled: Bool, for repository: URL) {
        var values = defaults.dictionary(forKey: "grove.aiReview.autoPublishByRepository.v1") as? [String: Bool] ?? [:]
        values[repository.standardizedFileURL.path] = enabled
        defaults.set(values, forKey: "grove.aiReview.autoPublishByRepository.v1")
    }

    // MARK: - 自动评审 head 簿记（v2）

    /// 按 URL 记录的自动评审状态。v1 是三个独立 UserDefaults 字典、按 URL
    /// 只增不减（PR 不经 Grove 关闭/合并就永远留着）。v2 合并为一个 JSON
    /// blob：`order` 记 URL 的最近使用顺序，超过 `headStateURLLimit` 个 URL
    /// 时淘汰最久未用的——增长有了硬上限，与「PR 关闭时清理」的软钩子互补。
    private struct HeadState: Codable {
        var published: [String: String] = [:]
        var initial: [String: String] = [:]
        var notified: [String: [String]] = [:]
        var order: [String] = []
    }

    /// 跟踪的请求 URL 总量上限。覆盖一个仓库几百个开放 PR 的量级绰绰有余，
    /// 超过即按最久未用淘汰。
    private static let headStateURLLimit = 400
    private static let headStateKey = "grove.aiReview.headState.v2"
    private static let legacyHeadStateKeys = [
        "grove.aiReview.publishedHeads.v1", "grove.aiReview.initialHeads.v1", "grove.aiReview.notifiedHeads.v1"
    ]

    /// 进程内缓存：设置以值类型传递，但读写都经过同一个引用箱子，
    /// UserDefaults 只在状态变更时真正落盘，读取不重复解码。
    private final class HeadStateBox {
        var state: HeadState?
    }
    private let headStateBox = HeadStateBox()

    private func loadHeadState() -> HeadState {
        if let cached = headStateBox.state { return cached }
        var state = HeadState()
        var migrated = false
        if let data = defaults.data(forKey: Self.headStateKey) {
            state = (try? JSONDecoder().decode(HeadState.self, from: data)) ?? HeadState()
        } else {
            // v1 → v2 一次性迁移：三个字典合并；order 无历史信息，按任意顺序起步。
            state.published = defaults.dictionary(forKey: Self.legacyHeadStateKeys[0]) as? [String: String] ?? [:]
            state.initial = defaults.dictionary(forKey: Self.legacyHeadStateKeys[1]) as? [String: String] ?? [:]
            state.notified = defaults.dictionary(forKey: Self.legacyHeadStateKeys[2]) as? [String: [String]] ?? [:]
            state.order = Array(Set(state.published.keys).union(state.initial.keys).union(state.notified.keys))
            migrated = !(state.published.isEmpty && state.initial.isEmpty && state.notified.isEmpty)
        }
        if migrated {
            persistHeadState(state)
            for key in Self.legacyHeadStateKeys {
                defaults.removeObject(forKey: key)
            }
        }
        headStateBox.state = state
        return state
    }

    private func persistHeadState(_ state: HeadState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.headStateKey)
    }

    /// 把 URL 标记为最近使用，并按上限淘汰最久未用的 URL（三个字典一起清）。
    private func touch(_ url: String, of state: inout HeadState) {
        state.order.removeAll { $0 == url }
        state.order.append(url)
        while state.order.count > Self.headStateURLLimit {
            let evicted = state.order.removeFirst()
            state.published.removeValue(forKey: evicted)
            state.initial.removeValue(forKey: evicted)
            state.notified.removeValue(forKey: evicted)
        }
    }

    func automaticReviewHead(for requestURL: String) -> String? {
        loadHeadState().published[requestURL]
    }

    func setAutomaticReviewHead(_ head: String, for requestURL: String) {
        var state = loadHeadState()
        state.published[requestURL] = head
        touch(requestURL, of: &state)
        headStateBox.state = state
        persistHeadState(state)
    }

    func initialReviewHead(for requestURL: String) -> String? {
        loadHeadState().initial[requestURL]
    }

    func setInitialReviewHead(_ head: String, for requestURL: String) {
        var state = loadHeadState()
        state.initial[requestURL] = head
        touch(requestURL, of: &state)
        headStateBox.state = state
        persistHeadState(state)
    }

    func hasNotifiedReviewHead(_ head: String, for requestURL: String) -> Bool {
        loadHeadState().notified[requestURL]?.contains(head) == true
    }

    /// 每 URL 只保留最近几个已通知的 head。PR 的 force-push 能让这个数组
    /// 无限增长，而第 6 个以前的 head 再也不会被比对——留着没有意义。
    private static let notifiedHeadLimit = 5

    func setNotifiedReviewHead(_ head: String, for requestURL: String) {
        var state = loadHeadState()
        if state.notified[requestURL]?.contains(head) != true {
            state.notified[requestURL, default: []].append(head)
        }
        if (state.notified[requestURL]?.count ?? 0) > Self.notifiedHeadLimit {
            state.notified[requestURL] = Array(state.notified[requestURL]!.suffix(Self.notifiedHeadLimit))
        }
        touch(requestURL, of: &state)
        headStateBox.state = state
        persistHeadState(state)
    }

    /// 请求结束（合并 / 关闭）时忘掉它的全部自动评审状态。
    func removeAutomaticReviewState(for requestURL: String) {
        var state = loadHeadState()
        var changed = false
        if state.published.removeValue(forKey: requestURL) != nil { changed = true }
        if state.initial.removeValue(forKey: requestURL) != nil { changed = true }
        if state.notified.removeValue(forKey: requestURL) != nil { changed = true }
        let orderCount = state.order.count
        state.order.removeAll { $0 == requestURL }
        if state.order.count != orderCount { changed = true }
        guard changed else { return }
        headStateBox.state = state
        persistHeadState(state)
    }

    /// 清掉「路径已不在本机、且当前未打开」的仓库的项目级设置。
    /// 提示词 / 审查范围 / 自动审查 / 自动发布四个字典按仓库路径为键、
    /// 只增不减，仓库删除后条目成了死数据。仍在本机磁盘上的路径保留——
    /// 重新打开时这些配置理应还在；当前打开的（可能在移动卷上）也保留。
    func pruneRepositorySettings(keeping openRepositories: [URL]) {
        let keep = Set(openRepositories.map { $0.standardizedFileURL.path })
        let settingsKeys = [
            reviewInstructionsKey, reviewAreasKey, legacyReviewInstructionsKey,
            "grove.aiReview.automaticByRepository.v1", "grove.aiReview.autoPublishByRepository.v1"
        ]
        for key in settingsKeys {
            guard var values = defaults.dictionary(forKey: key), !values.isEmpty else { continue }
            let original = values
            for path in original.keys {
                guard !keep.contains(path), !FileManager.default.fileExists(atPath: path) else { continue }
                values.removeValue(forKey: path)
            }
            if values.count != original.count {
                defaults.set(values, forKey: key)
            }
        }
    }

    var provider: AIGenerationProvider {
        defaults.string(forKey: providerKey)
            .flatMap(AIGenerationProvider.init(rawValue:)) ?? .codex
    }

    func setProvider(_ provider: AIGenerationProvider) {
        defaults.set(provider.rawValue, forKey: providerKey)
    }

    var apiBaseURL: String {
        defaults.string(forKey: apiBaseURLKey) ?? "https://api.openai.com/v1"
    }

    func setAPIBaseURL(_ url: String) {
        defaults.set(url, forKey: apiBaseURLKey)
    }

    var apiModel: String {
        defaults.string(forKey: apiModelKey) ?? "gpt-4o-mini"
    }

    func setAPIModel(_ model: String) {
        defaults.set(model, forKey: apiModelKey)
    }

    var apiThinking: AIAPIThinkingMode {
        defaults.string(forKey: apiThinkingKey)
            .flatMap(AIAPIThinkingMode.init(rawValue:)) ?? .default
    }

    func setAPIThinking(_ mode: AIAPIThinkingMode) {
        defaults.set(mode.rawValue, forKey: apiThinkingKey)
    }

    var hasAPIKey: Bool {
        AIAPIKeychain.read()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func saveAPIKey(_ key: String) throws {
        try AIAPIKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func removeAPIKey() throws {
        try AIAPIKeychain.remove()
    }

    var service: AIGenerationService? {
        switch provider {
        case .codex:
            return .codex(model: commitModel, reasoningEffort: nil)
        case .api:
            guard let key = AIAPIKeychain.read() else { return nil }
            let configuration = AIAPIConfiguration(
                baseURL: apiBaseURL,
                model: apiModel,
                apiKey: key,
                thinking: apiThinking
            )
            return configuration.endpoint == nil ? nil : .api(configuration)
        }
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

    var reviewReasoningEffort: AIReviewReasoningEffort {
        defaults.string(forKey: reviewReasoningEffortKey)
            .flatMap(AIReviewReasoningEffort.init(rawValue:)) ?? .high
    }

    func setReviewReasoningEffort(_ effort: AIReviewReasoningEffort) {
        defaults.set(effort.rawValue, forKey: reviewReasoningEffortKey)
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
