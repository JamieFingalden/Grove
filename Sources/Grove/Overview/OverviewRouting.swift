import Foundation

extension AppNavigationState {
    struct Route {
        var id = UUID()
        var repository: RepoID
        var projectKey: String? = nil
        var pullRequest: PullRequest?
        var pipeline: CIPipeline?
        var worktree: URL?
        var commit: String?

        @MainActor
        func matches(_ model: RepositoryModel) -> Bool {
            guard repository == model.id else { return false }
            guard let projectKey else { return true }
            guard let origin = model.origin, let kind = model.forge?.kind else { return false }
            return WorkspaceItem.projectIdentity(provider: kind, origin: origin) == projectKey
        }
    }
}

extension AppModel {
    func openWorkspaceItem(_ item: WorkspaceItem) async {
        guard let repository = repositories.first(where: { $0.id.identityKey == item.repositoryKey }),
              let origin = repository.origin, WorkspaceItem.projectIdentity(provider: item.provider, origin: origin) == item.projectKey else { return }
        if let git {
            guard let raw = await git.remoteURL(in: repository.root), let current = GitRemote.parse(raw),
                  WorkspaceItem.projectIdentity(provider: item.provider, origin: current) == item.projectKey else {
                report(title: "无法定位 Workspace 事项", detail: "origin 已变化或无法读取，请先刷新仓库再选择事项。", repository: repository)
                return
            }
        }
        navigation.route = .init(repository: repository.id, projectKey: item.projectKey, pullRequest: item.pullRequest, pipeline: item.pipeline)
        selection = .repositoryHome(repository: repository.id)
    }

    func openDailyCommit(_ commit: DailyCommit) async {
        guard let repository = repositories.first(where: { $0.id.identityKey == commit.repositoryKey }),
              let worktree = repository.worktrees.first(where: { !$0.isPrunable }) else { return }
        if let git {
            guard let identity = try? await DailyActivityService.repositoryIdentity(git: git, root: repository.root), identity == commit.repositoryIdentity else {
                report(title: "无法定位 Daily 记录", detail: "Git 仓库身份已变化或无法读取，请先刷新 Daily。", repository: repository)
                return
            }
        }
        navigation.route = .init(repository: repository.id, worktree: worktree.path, commit: commit.hash)
        selection = .worktree(repository: repository.id, worktree: worktree.path)
    }
}
