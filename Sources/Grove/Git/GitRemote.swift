import Foundation

/// 解析出来的 git 远端地址。
///
/// 存在的理由：判断「这个仓库到底托管在哪」不能交给 `gh` 自己猜。`gh` 会扫一遍
/// 所有 remote、挑任意一个 GitHub 的来用 —— 而一个 `origin` 指向内网 GitLab、
/// 另外还挂了个 GitHub remote 做备份的仓库，会被它认成那个 GitHub 仓库，
/// 于是界面上显示的是**另一个仓库**的 PR。比什么都不显示更糟。
/// 仓库里配置的一个远端。
struct NamedRemote: Identifiable, Hashable, Sendable {
    var name: String
    var fetchURL: String
    /// 推送地址。绝大多数情况跟 fetchURL 相同，但 git 允许分开配
    /// （`remote.<name>.pushurl`），比如读走只读镜像、写走可写地址。
    var pushURL: String

    var id: String { name }

    /// 解析过的推送地址，用来在界面上显示主机名。
    var parsed: GitRemote? { GitRemote.parse(pushURL) }

    /// 界面上给用户看的一行说明：主机 + 仓库路径。
    var summary: String {
        guard let parsed else { return pushURL }
        return "\(parsed.hostWithPort)/\(parsed.path)"
    }
}

/// 解析 `git remote -v` 的输出。
///
/// 格式是 `<名字>\t<地址> (fetch)` / `<名字>\t<地址> (push)`，每个远端两行。
/// 用制表符切分名字和地址 —— 地址里可能有空格（少见但合法），按空格切会散架。
enum RemoteListParser {
    static func parse(_ output: String) -> [NamedRemote] {
        var fetchURLs: [String: String] = [:]
        var pushURLs: [String: String] = [:]
        var order: [String] = []

        for line in output.components(separatedBy: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let name = String(line[line.startIndex..<tab])
            var rest = String(line[line.index(after: tab)...])

            // 去掉末尾的 ` (fetch)` / ` (push)` 标记。
            var kind = "fetch"
            if let paren = rest.lastIndex(of: "(") {
                kind = rest[rest.index(after: paren)...].prefix(while: { $0 != ")" }).lowercased()
                rest = String(rest[rest.startIndex..<paren])
            }
            let url = rest.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !url.isEmpty else { continue }

            if order.contains(name) == false { order.append(name) }
            if kind == "push" { pushURLs[name] = url } else { fetchURLs[name] = url }
        }

        return order.map { name in
            let fetch = fetchURLs[name] ?? pushURLs[name] ?? ""
            return NamedRemote(name: name, fetchURL: fetch, pushURL: pushURLs[name] ?? fetch)
        }
    }

    /// 从上游引用（`origin/feature/login`）里切出远端名。
    ///
    /// 不能简单按第一个斜杠切：分支名本身可以带斜杠，而且远端也可能叫别的名字。
    /// 拿已知的远端名去比对才可靠 —— 否则 `github/main` 会被当成远端 `github`
    /// 即使根本没有这个远端。
    static func remoteName(inUpstream upstream: String, knownRemotes: [String]) -> String? {
        knownRemotes.first { upstream == $0 || upstream.hasPrefix("\($0)/") }
    }
}

struct GitRemote: Sendable, Hashable {
    /// 主机名，不含端口。`github.com` / `10.0.0.1` / `gitlab.corp.example`。
    var host: String
    /// 非默认端口。内网 GitLab 常见 `http://10.0.0.1:8929` 这种形态。
    var port: Int?
    /// 远端地址的协议。内网实例很多是纯 http —— 生成 `glab auth login`
    /// 命令时必须带上 `--api-protocol http`，否则 glab 默认走 https，
    /// 登录会以一个跟协议毫无关系的报错失败。
    var scheme: String?
    /// 仓库在主机上的路径，已去掉首尾斜杠和 `.git` 后缀。
    /// GitLab 的子群组会让它有多段：`group/subgroup/repo`。
    var path: String

    /// 带端口的主机写法。CLI 工具对「主机」的记法不统一 —— `glab` 的配置键
    /// 可能是 `10.0.0.1` 也可能是 `10.0.0.1:8929`（取决于登录时怎么写的
    /// `--hostname` 和 `--api-host`）。匹配时两种都要试，否则内网带端口的
    /// 实例永远认不出来。
    var hostWithPort: String {
        guard let port else { return host }
        return "\(host):\(port)"
    }

    /// 明文 http 的远端。生成登录命令时要额外带协议参数。
    var isInsecureHTTP: Bool { scheme?.lowercased() == "http" }

    /// 匹配某个 CLI 记录的主机名时，两种写法都算命中。
    func matchesHost(_ candidate: String) -> Bool {
        let normalized = candidate.lowercased()
        return normalized == host.lowercased() || normalized == hostWithPort.lowercased()
    }

    /// `owner/repo` 形式。GitLab 嵌套群组下取最后两段 —— gh 和 GitHub API 只认这个形状。
    var slug: String {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return path }
        return parts.suffix(2).joined(separator: "/")
    }

    var name: String {
        String(path.split(separator: "/").last ?? "")
    }

    /// 解析 git 支持的各种远端写法。认不出来返回 nil（比如本地路径远端）。
    static func parse(_ raw: String) -> GitRemote? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // scp 风格：`git@github.com:owner/repo.git`。注意它没有 `//`，
        // 而且冒号后面直接跟路径 —— 用 URLComponents 解会把 `owner/repo.git`
        // 当成端口号解析失败。
        if !trimmed.contains("://"), let colon = trimmed.firstIndex(of: ":") {
            let hostPart = String(trimmed[trimmed.startIndex..<colon])
            let pathPart = String(trimmed[trimmed.index(after: colon)...])
            let host = hostPart.contains("@")
                ? String(hostPart.split(separator: "@").last ?? "")
                : hostPart
            guard !host.isEmpty, !pathPart.isEmpty else { return nil }
            // scp 写法（git@host:path）走的是 ssh，API 协议无从得知，留空。
            return GitRemote(host: host, port: nil, scheme: nil, path: normalize(pathPart))
        }

        guard let components = URLComponents(string: trimmed), let host = components.host else {
            return nil
        }
        // `file://` 或本地路径没有托管商可言。
        guard let scheme = components.scheme?.lowercased(),
              ["http", "https", "ssh", "git"].contains(scheme) else { return nil }

        let path = normalize(components.path)
        guard !path.isEmpty else { return nil }
        return GitRemote(host: host, port: components.port, scheme: scheme, path: path)
    }

    private static func normalize(_ path: String) -> String {
        var value = path
        while value.hasPrefix("/") { value.removeFirst() }
        if value.hasSuffix(".git") { value.removeLast(4) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
