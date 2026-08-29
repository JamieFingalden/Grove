import Foundation

/// `Grove --doctor [路径]`：把整条链路跑一遍并打印结果。
///
/// 这不是测试脚手架，是给用户用的自查工具。这类 app 最常见的报障是
/// 「打不开我的仓库」/「PR 那块是空的」，而原因几乎总在 GUI 之外：
/// 从 Finder 启动时 PATH 里没有 `gh`、`gh` 没登录、目录不是仓库、远端不是 GitHub。
/// 界面上很难把这些讲清楚，一条命令把每一步的实际结果摊开最直接。
enum Doctor {
    static func run(path: String?) async {
        // 关掉 stdout 缓冲。诊断工具的价值有一半在于「卡住时能看见走到哪一步了」，
        // 而默认的块缓冲会把输出全攒在内存里，重定向到文件时看到的是一片空白。
        setvbuf(stdout, nil, _IONBF, 0)

        print("Grove 环境自查")
        print(String(repeating: "─", count: 52))

        // 1. 工具链
        let gitURL = await ToolLocator.shared.locate("git")
        let ghURL = await ToolLocator.shared.locate("gh")
        line("git", gitURL?.path ?? "未找到")
        line("gh", ghURL?.path ?? "未找到（PR 功能不可用）")

        let environment = await ToolLocator.shared.childEnvironment()
        line("子进程 PATH", environment["PATH"]?.split(separator: ":").prefix(4).joined(separator: ":") ?? "?")

        guard let git = try? await GitClient.resolve() else {
            print("\n找不到 git，无法继续。请运行 xcode-select --install")
            return
        }

        if let version = try? await git.run(["--version"], in: URL(fileURLWithPath: "/")) {
            line("git 版本", version.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // 2. 托管商 CLI 登录状态
        let github = await GitHubClient.resolve()
        let gitlab = await GitLabClient.resolve()
        line("glab", (await ToolLocator.shared.locate("glab"))?.path ?? "未找到（GitLab 功能不可用）")
        if let github {
            line("gh 登录状态", await github.isAuthenticated() ? "已登录" : "未登录（运行 gh auth login）")
        }
        if let gitlab {
            line("glab 登录状态", await gitlab.isAuthenticated() ? "已登录" : "未登录（运行 glab auth login）")
        }

        // 3. 仓库
        let target = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
        print("\n仓库：\(target.path)")
        print(String(repeating: "─", count: 52))

        guard let root = await git.repositoryRoot(for: target) else {
            print("不是 git 仓库。")
            return
        }
        line("仓库根目录", root.path)
        let originURL = await git.remoteURL(in: root)
        line("远端 origin", originURL ?? "无")

        // 托管商只看 origin。`gh repo view` 会扫所有 remote 挑一个 GitHub 的用，
        // 于是「origin 在内网 GitLab、另挂了个 GitHub 备份」的仓库会被认错，
        // 显示成另一个仓库的 PR。这里按 origin 判断，跟界面里的规则一致。
        let origin = originURL.flatMap(GitRemote.parse)
        if let origin { line("origin 主机", origin.hostWithPort) }

        // 多远端的仓库全列出来。推送推错地方通常就是因为没意识到有第二个远端。
        if let remotes = try? await git.remotes(in: root), remotes.count > 1 {
            print("  远端（\(remotes.count) 个，推送时可选）")
            for remote in remotes {
                print("    • \(remote.name)  →  \(remote.summary)")
            }
        }

        // 托管商只按 origin 认，跟界面里同一套规则。
        let githubHosts = await github?.configuredHosts() ?? []
        let gitlabHosts = await gitlab?.configuredHosts() ?? []
        let forge: (any ForgeClient)? = {
            guard let origin else { return nil }
            if origin.matchesHost("github.com") { return github }
            if origin.matchesHost("gitlab.com") { return gitlab }
            if githubHosts.contains(where: { origin.matchesHost($0) }) { return github }
            if gitlabHosts.contains(where: { origin.matchesHost($0) }) { return gitlab }
            return nil
        }()
        if let forge { line("托管平台", forge.kind.termLong) }

        let defaultBranch = await git.defaultBranch(in: root)
        line("默认分支", defaultBranch ?? "未知")

        // 4. 工作树
        let slug = await forge?.repositorySlug(in: root)

        do {
            let worktrees = try await git.worktrees(in: root)
            print("\n工作树（\(worktrees.count) 个）")
            for worktree in worktrees {
                var flags: [String] = []
                if worktree.isPrimary { flags.append("主") }
                if worktree.isLocked { flags.append("已锁定") }
                if worktree.isPrunable { flags.append("可清理") }
                if worktree.isBare { flags.append("裸仓库") }
                let suffix = flags.isEmpty ? "" : "  [\(flags.joined(separator: " "))]"
                print("  • \(worktree.name)  →  \(worktree.checkoutLabel)\(suffix)")

                let status = try await git.status(in: worktree.path)
                var parts: [String] = []
                if status.isClean {
                    parts.append("干净")
                } else {
                    parts.append("\(status.changes.count) 处改动（暂存 \(status.stagedCount)）")
                }
                if status.ahead > 0 { parts.append("领先 \(status.ahead)") }
                if status.behind > 0 { parts.append("落后 \(status.behind)") }
                if let operation = status.operation { parts.append(operation.rawValue) }
                if status.hasConflicts { parts.append("\(status.conflictCount) 个冲突") }
                print("    \(parts.joined(separator: " · "))")

                // 工作树 ↔ PR 的关联是 Grove 的核心视图，这里一并验证。
                // 走的是跟界面完全同一个入口，免得两边规则不一致。
                if let forge, slug != nil, let branch = worktree.branch,
                   let pullRequest = await forge.linkedPullRequest(
                       branch: branch, defaultBranch: defaultBranch, in: worktree.path
                   ) {
                    var prParts = [pullRequest.displayNumber, pullRequest.status.label]
                    if let checks = pullRequest.checks.label { prParts.append(checks) }
                    if let review = pullRequest.review.label { prParts.append(review) }
                    print("    ↳ \(prParts.joined(separator: " · "))  \(pullRequest.title)")
                }

                for change in status.changes.prefix(5) {
                    let staged = change.staged?.badge ?? "."
                    let unstaged = change.unstaged?.badge ?? "."
                    print("      \(staged)\(unstaged)  \(change.path)")
                }
                if status.changes.count > 5 {
                    print("      …还有 \(status.changes.count - 5) 个")
                }
            }
        } catch {
            print("读取工作树失败：\(error.localizedDescription)")
        }

        // 5. 分支
        if let branches = try? await git.branches(in: root) {
            print("\n本地分支（\(branches.count) 个）")
            for branch in branches.prefix(10) {
                var parts = [branch.name]
                if let upstream = branch.upstream { parts.append("→ \(upstream)") }
                if branch.ahead > 0 || branch.behind > 0 { parts.append("↑\(branch.ahead) ↓\(branch.behind)") }
                if branch.upstreamIsGone { parts.append("[上游已删除]") }
                if let worktree = branch.worktreePath { parts.append("[占用于 \(worktree.lastPathComponent)]") }
                print("  • \(parts.joined(separator: " "))")
            }
        }

        // 6. diff 解析
        if let diffs = try? await git.diff(in: root, staged: false), !diffs.isEmpty {
            print("\n工作区 diff（\(diffs.count) 个文件）")
            for file in diffs.prefix(5) {
                print("  • \(file.displayPath)  +\(file.additions) −\(file.deletions)  hunks=\(file.hunks.count)")
            }
        }

        // 7. 评审请求
        print("\n评审请求（PR / MR）")
        print(String(repeating: "─", count: 52))
        guard let forge else {
            let host = origin?.host ?? "未知主机"
            print("origin 指向 \(host)，Grove 认不出它属于哪个平台 —— 评审功能不可用。")
            print("gh 配置过的主机：\(githubHosts.isEmpty ? "（无）" : githubHosts.sorted().joined(separator: "、"))")
            print("glab 配置过的主机：\(gitlabHosts.isEmpty ? "（无）" : gitlabHosts.sorted().joined(separator: "、"))")
            if let origin {
                var command = "glab auth login --hostname \(origin.host)"
                if let port = origin.port { command += " --api-host \(origin.host):\(port)" }
                print("若这是自建 GitLab，先登录一次：\(command)")
            }
            // 这个仓库如果还挂着别的 GitHub remote，明确说一声 ——
            // 否则用户会奇怪「我明明有 GitHub remote，为什么不显示 PR」。
            if let others = try? await git.run(["remote", "-v"], in: root),
               others.contains("github.com") {
                print("注意：这个仓库另外挂了 GitHub remote，但 Grove 只认 origin，所以不会显示它的 PR。")
            }
            return
        }
        guard let slug else {
            print("gh 无法识别这个 GitHub 仓库。")
            return
        }
        line("仓库", slug)
        do {
            let pullRequests = try await forge.pullRequests(in: root, limit: 10, includeClosed: false)
            print("开放的\(forge.kind.termLong)：\(pullRequests.count) 个")
            for pullRequest in pullRequests {
                var parts = [pullRequest.displayNumber, pullRequest.title]
                parts.append("[\(pullRequest.status.label)]")
                if let checks = pullRequest.checks.label { parts.append(checks) }
                if let review = pullRequest.review.label { parts.append(review) }
                print("  • \(parts.joined(separator: "  "))")
                print("    \(pullRequest.headRefName) → \(pullRequest.baseRefName)"
                      + (pullRequest.isCrossRepository ? "  (来自 fork)" : ""))
            }
        } catch {
            print("读取失败：\(error.localizedDescription)")
        }
    }

    private static func line(_ label: String, _ value: String) {
        let padded = label.padding(toLength: max(label.count, 16), withPad: " ", startingAt: 0)
        print("  \(padded)\(value)")
    }
}
