import Foundation
import Observation
import SwiftUI

/// 全局导航只切换可见内容，仓库选择和已挂载页面由原模型继续持有。
@MainActor
@Observable
final class AppNavigationState {
    enum Page: String, CaseIterable { case daily, workspace, repositories }
    enum Startup: String, CaseIterable, Identifiable {
        case lastPage, daily, workspace, repository
        var id: String { rawValue }
        var label: String {
            switch self {
            case .lastPage: "上次访问页面"
            case .daily: "Daily"
            case .workspace: "Workspace"
            case .repository: "上次选中的 Repository"
            }
        }
    }

    private let defaults: UserDefaults
    var page: Page = .repositories {
        didSet { defaults.set(page.rawValue, forKey: "grove.navigation.lastPage") }
    }
    var visited: [AppModel.Selection] = []
    var route: Route?
    var startup: Startup {
        didSet { defaults.set(startup.rawValue, forKey: "grove.navigation.startup") }
    }
    var authorEmails: [String] {
        didSet { defaults.set(authorEmails, forKey: "grove.daily.authorEmails") }
    }
    var autoRefresh: Bool {
        didSet { defaults.set(autoRefresh, forKey: "grove.overview.autoRefresh") }
    }
    var appearance: String {
        didSet { defaults.set(appearance, forKey: "grove.appearance") }
    }
    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    private let restoredPage: Page
    private let restoredRepository: String?
    private let restoredWorktree: String?
    private(set) var hasUserNavigated = false
    private var restoring = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startup = Startup(rawValue: defaults.string(forKey: "grove.navigation.startup") ?? "") ?? .lastPage
        authorEmails = defaults.stringArray(forKey: "grove.daily.authorEmails") ?? []
        autoRefresh = defaults.object(forKey: "grove.overview.autoRefresh") as? Bool ?? true
        appearance = defaults.string(forKey: "grove.appearance") ?? "system"
        restoredPage = Page(rawValue: defaults.string(forKey: "grove.navigation.lastPage") ?? "") ?? .repositories
        restoredRepository = defaults.string(forKey: "grove.navigation.repository")
        restoredWorktree = defaults.string(forKey: "grove.navigation.worktree")
        page = startup == .daily ? .daily : startup == .workspace ? .workspace : startup == .lastPage ? restoredPage : .repositories
    }

    func show(_ page: Page) {
        hasUserNavigated = true
        self.page = page
    }

    func selected(_ selection: AppModel.Selection?) {
        guard let selection else { return }
        if !visited.contains(selection) { visited.append(selection) }
        if !restoring { show(.repositories) }
        switch selection {
        case .repositoryHome(let id):
            defaults.set(id.identityKey, forKey: "grove.navigation.repository")
            defaults.removeObject(forKey: "grove.navigation.worktree")
        case .worktree(let id, let path):
            defaults.set(id.identityKey, forKey: "grove.navigation.repository")
            defaults.set(path.path, forKey: "grove.navigation.worktree")
        }
    }

    func restore(in app: AppModel) {
        guard !hasUserNavigated else { return }
        restoring = true
        if let repository = app.allRepositories.first(where: { $0.id.identityKey == restoredRepository }) {
            if let path = restoredWorktree, repository.worktrees.contains(where: { $0.path.path == path }) {
                app.selection = .worktree(repository: repository.id, worktree: URL(fileURLWithPath: path))
            } else {
                app.selection = .repositoryHome(repository: repository.id)
            }
        }
        restoring = false
    }

    /// 启动中的默认选中不能覆盖用户的启动页面偏好。
    func withRestoration(_ action: () -> Void) {
        restoring = true
        action()
        restoring = false
    }
}

private struct RepositoryPageActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var repositoryPageActive: Bool {
        get { self[RepositoryPageActiveKey.self] }
        set { self[RepositoryPageActiveKey.self] = newValue }
    }
}
