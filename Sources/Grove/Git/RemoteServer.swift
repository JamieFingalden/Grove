import Foundation

/// 一台可以连接的远程开发服务器。
///
/// 认证只走 SSH 密钥（ssh-agent / `~/.ssh/config` / 默认密钥），不存密码：
/// 密码交互在 GUI 的子进程里没人能回答，只会挂死。`BatchMode=yes` 保证
/// 密钥不可用时立刻失败，而不是永远等输入。
struct RemoteServer: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// 界面上显示的名字。留空时用 `user@host`。
    var alias = ""
    var host = ""
    var user: String?
    var port: Int?

    /// ssh 目标写法：`user@host` 或纯 `host`。
    var destination: String {
        let prefix = user.map { "\($0)@" } ?? ""
        return "\(prefix)\(host)"
    }

    var displayName: String {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? destination : trimmed
    }
}

/// 已配置的远程服务器，存在 UserDefaults 里（跟仓库路径同一个策略：
/// Grove 不开沙盒，配置本身没有秘密 —— 密钥在 `~/.ssh`，这里只有地址）。
struct RemoteServerStore {
    private let key = "grove.remote-servers"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [RemoteServer] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RemoteServer].self, from: data)) ?? []
    }

    func save(_ servers: [RemoteServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 每台服务器上添加过的项目：`服务器 id → 仓库根目录绝对路径`。
struct RemoteProjectStore {
    private let key = "grove.remote-projects"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String: [String]] {
        defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    func save(_ projects: [String: [String]]) {
        defaults.set(projects, forKey: key)
    }
}

/// 仓库在哪里：本机，还是某台远程服务器上。
enum RepoLocation: Hashable, Sendable {
    case local
    case remote(RemoteServer)

    var server: RemoteServer? {
        if case .remote(let server) = self { return server }
        return nil
    }

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

/// 仓库的唯一标识。只有本机仓库时路径就够了；接入远程服务器之后，
/// 不同机器上可以有同形路径，必须连位置一起比 —— 侧边栏选中项、
/// sheet 路由、模型缓存全都用它做键。
struct RepoID: Hashable, Sendable {
    var location: RepoLocation
    var rootPath: String

    init(location: RepoLocation, root: URL) {
        self.location = location
        self.rootPath = location.isRemote ? root.path : root.groveResolved.path
    }

    var root: URL { URL(fileURLWithPath: rootPath) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.location.server?.id == rhs.location.server?.id && lhs.rootPath == rhs.rootPath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(location.server?.id)
        hasher.combine(rootPath)
    }

    /// 给 `.task(id:)`、通知线程标识这类只能吃字符串的键用的稳定形态。
    var identityKey: String {
        let owner = location.server?.id.uuidString ?? "local"
        return "\(owner):\(rootPath)"
    }
}
