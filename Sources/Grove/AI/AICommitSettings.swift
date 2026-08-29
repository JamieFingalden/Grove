import Foundation

struct AICommitSettings {
    // v2 的授权文案同时覆盖提交信息和 PR 描述；旧版只同意发送暂存 diff，不能静默扩权。
    private let key = "grove.aiGeneration.enabledRepositories.v2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled(for root: URL) -> Bool {
        enabledPaths.contains(root.groveResolved.path)
    }

    func setEnabled(_ enabled: Bool, for root: URL) {
        var paths = enabledPaths
        if enabled {
            paths.insert(root.groveResolved.path)
        } else {
            paths.remove(root.groveResolved.path)
        }
        defaults.set(Array(paths).sorted(), forKey: key)
    }

    private var enabledPaths: Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}
