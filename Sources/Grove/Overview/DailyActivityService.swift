import Foundation

struct DailyCommit: Identifiable, Hashable, Codable, Sendable {
    var repositoryIdentity: String
    var repositoryKey: String
    var repositoryName: String
    var hash: String
    var authorEmail: String
    var date: Date
    var subject: String
    var branch: String?
    var knownOnRemote: Bool
    var id: String { repositoryIdentity + ":" + hash }
}

struct DailyBranch: Identifiable, Codable, Sendable {
    var repositoryIdentity: String
    var repositoryKey: String
    var repositoryName: String
    var name: String
    var ahead: Int?
    var upstream: String?
    var upstreamGone: Bool
    var id: String { repositoryIdentity + ":" + name }
    var label: String {
        if upstream == nil { return "未设上游，推送状态未知" }
        if upstreamGone { return "上游引用缺失，远端状态未知" }
        if let ahead, ahead > 0 { return "领先上游 \(ahead) 个提交（本地引用）" }
        return "本地引用无领先；远端未校验"
    }
}

/// 与 History 使用同一 Git 通道；日期使用提交者日期，身份使用原始作者邮箱。
enum DailyActivityService {
    struct Source: Sendable {
        var identity: String
        var repositoryKey: String
        var name: String
        var root: URL
        var git: GitClient
    }
    struct Snapshot: Codable, Sendable {
        var commits: [DailyCommit]
        var branches: [DailyBranch]
        var syncedAt: Date
    }
    static func repositoryIdentity(git: GitClient, root: URL) async throws -> String {
        let output = try await git.run(["rev-parse", "--git-common-dir"], in: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = output.hasPrefix("/") ? URL(fileURLWithPath: output) : root.appendingPathComponent(output)
        return path.groveResolved.path
    }

    static func scan(_ source: Source, start: Date, end: Date) async throws -> Snapshot {
        let format = "%H%x00%ae%x00%ct%x00%s"
        // --since-as-filter 不因一个旧日期父提交提前停止，避免漏掉变基后的提交。
        let since = "--since-as-filter=@\(Int(start.timeIntervalSince1970) - 1)"
        let until = "--until=@\(Int(end.timeIntervalSince1970))"
        async let log = source.git.run(["log", "--all", since, until, "--format=\(format)"], in: source.root)
        async let remote = source.git.run(["log", "--remotes", since, until, "--format=%H"], in: source.root)
        async let branches = source.git.branches(in: source.root)
        let (output, remoteOutput, localBranches) = try await (log, remote, branches)
        let remoteHashes = Set(remoteOutput.split(separator: "\n").map(String.init))
        let commits = parse(output, source: source, start: start, end: end).map { commit in
            var commit = commit
            commit.knownOnRemote = remoteHashes.contains(commit.hash)
            let tips = localBranches.filter { $0.oid == commit.hash }.map(\.name).sorted()
            commit.branch = tips.isEmpty ? nil : tips.joined(separator: ", ")
            return commit
        }
        let branchStates = localBranches.map {
            DailyBranch(repositoryIdentity: source.identity, repositoryKey: source.repositoryKey, repositoryName: source.name,
                        name: $0.name, ahead: $0.upstream != nil && !$0.upstreamIsGone ? $0.ahead : nil,
                        upstream: $0.upstream, upstreamGone: $0.upstreamIsGone)
        }
        return Snapshot(commits: commits, branches: branchStates, syncedAt: Date())
    }

    static func parse(_ output: String, source: Source, start: Date, end: Date) -> [DailyCommit] {
        var seen = Set<String>()
        return output.components(separatedBy: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 4, let epoch = TimeInterval(fields[2]),
                  seen.insert(fields[0]).inserted else { return nil }
            let date = Date(timeIntervalSince1970: epoch)
            guard date >= start && date < end else { return nil }
            return DailyCommit(repositoryIdentity: source.identity, repositoryKey: source.repositoryKey, repositoryName: source.name,
                               hash: fields[0], authorEmail: fields[1], date: date, subject: fields[3], knownOnRemote: false)
        }
    }

    static func personal(_ commits: [DailyCommit], emails: [String]) -> [DailyCommit] {
        let identities = Set(emails.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var seen = Set<String>()
        return commits.filter { identities.contains($0.authorEmail.lowercased()) && seen.insert($0.id).inserted }
            .sorted { $0.date > $1.date }
    }
}
