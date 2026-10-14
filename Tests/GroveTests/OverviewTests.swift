import AppKit
import SwiftUI
import XCTest
@testable import Grove

@MainActor
final class OverviewTests: XCTestCase {
    private func request(author: String = "other", reviewers: [String] = []) -> PullRequest {
        PullRequest(number: 8, title: "统一设计系统", state: "OPEN", isDraft: false,
                    headRefName: "feature", baseRefName: "main", url: "https://github.com/team/Grove/pull/8",
                    author: .init(login: author), updatedAt: Date(), additions: 1, deletions: 0,
                    changedFiles: 1, isCrossRepository: false, labels: [],
                    reviewRequests: reviewers.map { .init(login: $0) })
    }
    private func item(_ request: PullRequest, viewer: String? = "me") -> WorkspaceItem {
        .request(request, viewer: viewer, project: "github:github.com:team/grove", repository: "local:/tmp/Grove", name: "Grove")
    }

    func testInboxUsesExplicitPersonalEvidenceAndKeepsStatesSeparate() throws {
        XCTAssertTrue(item(request()).inboxReasons.isEmpty)
        XCTAssertEqual(item(request(reviewers: ["me"])).inboxReasons, ["请求我评审"])
        XCTAssertTrue(item(request(reviewers: ["me"]), viewer: nil).inboxReasons.isEmpty)
        var mine = request(author: "me")
        mine.mergeable = "CONFLICTING"
        mine.reviewDecision = "APPROVED"
        mine.statusCheckRollup = [.init(name: "检查", conclusion: "FAILURE")]
        XCTAssertEqual(Set(item(mine).inboxReasons), ["Git 合并冲突", "CI 检查失败"])
        XCTAssertTrue(item(mine).matches(type: "pullRequest", status: "Git 冲突"))
        XCTAssertTrue(item(mine).matches(type: "ci", status: "已失败"))
        mine.state = "MERGED"
        XCTAssertTrue(item(mine).inboxReasons.isEmpty)
        var draft = request(reviewers: ["me"])
        draft.isDraft = true
        XCTAssertTrue(item(draft).inboxReasons.isEmpty)
        draft.isDraft = false
        draft.viewerHasApproved = true
        XCTAssertTrue(item(draft).inboxReasons.isEmpty)
        let encoded = try JSONEncoder().encode(item(mine))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceItem.self, from: encoded).id, item(mine).id)
    }

    func testProjectIdentityPreservesDistinctHostsPortsAndPaths() throws {
        let first = try XCTUnwrap(GitRemote.parse("https://gitlab.example.com:8443/team/Grove.git"))
        let second = try XCTUnwrap(GitRemote.parse("https://gitlab.example.com:9443/team/Grove.git"))
        let third = try XCTUnwrap(GitRemote.parse("https://gitlab.example.com:8443/another/Grove.git"))
        XCTAssertNotEqual(WorkspaceItem.projectIdentity(provider: .gitlab, origin: first), WorkspaceItem.projectIdentity(provider: .gitlab, origin: second))
        XCTAssertNotEqual(WorkspaceItem.projectIdentity(provider: .gitlab, origin: first), WorkspaceItem.projectIdentity(provider: .gitlab, origin: third))
        let ssh = try XCTUnwrap(GitRemote.parse("git@github.com:Team/Grove.git"))
        let https = try XCTUnwrap(GitRemote.parse("https://github.com/team/grove"))
        XCTAssertEqual(WorkspaceItem.projectIdentity(provider: .github, origin: ssh), WorkspaceItem.projectIdentity(provider: .github, origin: https))
    }

    func testDailyReadsRealGitDatesEmailsWorktreesAndAhead() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = container.appendingPathComponent("Grove")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let base = try await GitClient.resolve()
        try await base.run(["init", "-q", "-b", "main"], in: root)
        let today = Calendar.current.startOfDay(for: Date())
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_DATE"] = "2020-01-01T12:00:00+08:00"
        environment["GIT_COMMITTER_DATE"] = today.addingTimeInterval(3600).ISO8601Format()
        let executable = await ToolLocator.shared.locate("git")
        let git = GitClient(executable: try XCTUnwrap(executable), environment: environment)
        try await git.run(["-c", "user.name=本人", "-c", "user.email=me@example.com", "commit", "--allow-empty", "-qm", "本人今日记录"], in: root)
        let ownHash = try await git.run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try await git.run(["remote", "add", "origin", "https://example.invalid/Grove.git"], in: root)
        try await git.run(["update-ref", "refs/remotes/origin/main", ownHash], in: root)
        try await git.run(["branch", "--set-upstream-to=origin/main", "main"], in: root)
        try await git.run(["-c", "user.name=他人", "-c", "user.email=other@example.com", "commit", "--allow-empty", "-qm", "他人今日记录"], in: root)
        let worktree = container.appendingPathComponent("feature")
        try await git.run(["worktree", "add", "-q", "-b", "feature", worktree.path], in: root)
        let identity = try await DailyActivityService.repositoryIdentity(git: git, root: root)
        let siblingIdentity = try await DailyActivityService.repositoryIdentity(git: git, root: worktree)
        XCTAssertEqual(identity, siblingIdentity)
        let end = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: today))
        let source = DailyActivityService.Source(identity: identity, repositoryKey: "repo", name: "Grove", root: root, git: git)
        let snapshot = try await DailyActivityService.scan(source, start: today, end: end)
        let personal = DailyActivityService.personal(snapshot.commits + snapshot.commits, emails: ["ME@example.com"])
        XCTAssertEqual(personal.count, 1)
        XCTAssertEqual(DailyActivityService.personal(snapshot.commits, emails: ["me@example.com", "other@example.com"]).count, 2)
        XCTAssertEqual(personal.first?.hash, ownHash)
        XCTAssertTrue(personal.first?.knownOnRemote == true)
        XCTAssertTrue(Calendar.current.isDate(try XCTUnwrap(personal.first?.date), inSameDayAs: today), "活动日期必须使用提交者日期")
        XCTAssertEqual(snapshot.branches.first(where: { $0.name == "main" })?.ahead, 1)
        XCTAssertNil(snapshot.branches.first(where: { $0.name == "feature" })?.ahead, "无上游不能当作已同步")
        var independent = try XCTUnwrap(personal.first)
        independent.repositoryIdentity = "独立仓库"
        XCTAssertEqual(DailyActivityService.personal(personal + [independent], emails: ["me@example.com"]).count, 2)
        let trend = DailyViewModel(cacheName: "test-unused")
        var yesterday = try XCTUnwrap(personal.first)
        yesterday.hash = "另一个提交"
        yesterday.date = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: yesterday.date))
        trend.commits = personal + [yesterday]
        XCTAssertEqual(trend.days.count, 7)
        XCTAssertEqual(trend.activity(on: today).count, 1)
        XCTAssertEqual(trend.activity(on: yesterday.date).count, 1)
        XCTAssertEqual(trend.activeRepositories(on: yesterday.date), 1)
        trend.branches = snapshot.branches
        XCTAssertEqual(trend.aheadRepositoryCount, 1)
        let emptyRoot = container.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try await git.run(["init", "-q"], in: emptyRoot)
        let empty = DailyActivityService.Source(identity: "empty", repositoryKey: "empty", name: "空仓库", root: emptyRoot, git: git)
        let emptySnapshot = try await DailyActivityService.scan(empty, start: today, end: end)
        XCTAssertTrue(emptySnapshot.commits.isEmpty)
        let detached = container.appendingPathComponent("detached")
        try await git.run(["worktree", "add", "-q", "--detach", detached.path], in: root)
        try await git.run(["-c", "user.name=本人", "-c", "user.email=me@example.com", "commit", "--allow-empty", "-qm", "游离工作树中的今日记录"], in: detached)
        let detachedIdentity = try await DailyActivityService.repositoryIdentity(git: git, root: detached)
        XCTAssertEqual(detachedIdentity, identity)
        let detachedSource = DailyActivityService.Source(identity: identity, repositoryKey: "detached", name: "Grove", root: detached, git: git)
        let rootSnapshot = try await DailyActivityService.scan(source, start: today, end: end)
        let detachedSnapshot = try await DailyActivityService.scan(detachedSource, start: today, end: end)
        XCTAssertEqual(DailyActivityService.personal(rootSnapshot.commits + detachedSnapshot.commits, emails: ["me@example.com"]).count, 2,
                       "所有工作树的游离 HEAD 提交必须可见，且不同入口不能重复计数")
    }

    func testDateSwitchUsesIndexedActivityAndRefreshReplacesOldSummaries() throws {
        let model = DailyViewModel(cacheName: "test-unused")
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))
        let first = DailyCommit(repositoryIdentity: "grove", repositoryKey: "grove", repositoryName: "Grove",
                                hash: "a", authorEmail: "me@example.com", date: today.addingTimeInterval(60),
                                subject: "今日记录", knownOnRemote: false)
        var second = first
        second.hash = "b"
        second.date = yesterday.addingTimeInterval(60)
        var third = second
        third.repositoryIdentity = "lightsnap"
        third.repositoryName = "LightSnap"
        third.hash = "c"
        model.commits = [first, second, third]
        model.selectedDate = yesterday
        XCTAssertEqual(model.selectedDate, yesterday)
        XCTAssertEqual(model.activity(on: yesterday).map(\.hash), ["b", "c"])
        XCTAssertEqual(model.activeRepositories(on: yesterday), 2)
        XCTAssertEqual(model.projectSummary(on: yesterday), "Grove · 1 个提交   LightSnap · 1 个提交")
        model.selectedDate = today
        XCTAssertEqual(model.activity(on: today.addingTimeInterval(600)).map(\.hash), ["a"])
        XCTAssertFalse(model.isRefreshing, "日期切换应读取缓存，不触发仓库扫描")
        model.commits = [first]
        XCTAssertTrue(model.activity(on: yesterday).isEmpty)
        XCTAssertEqual(model.activeRepositories(on: yesterday), 0)
        XCTAssertEqual(model.projectSummary(on: yesterday), "")
    }

    func testNavigationRestoresPageAndRetainsRepositoryDraft() async throws {
        let suite = "grove.overview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = AppNavigationState(defaults: defaults)
        let app = AppModel(aiGenerationSettings: AIGenerationSettings(defaults: defaults), navigation: navigation)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = try await GitClient.resolve()
        try await git.run(["init", "-q", "-b", "main"], in: root)
        let repository = RepositoryModel(root: root, git: git, app: nil)
        await repository.refresh(loadForgeMetadata: false)
        app.repositories = [repository]
        let path = try XCTUnwrap(repository.worktrees.first?.path)
        app.selection = .worktree(repository: repository.id, worktree: path)
        let worktree = try XCTUnwrap(repository.worktreeModel(for: path))
        worktree.commitMessage = "尚未提交的中文草稿"
        worktree.logQuery.text = "保留筛选"
        navigation.show(.daily)
        navigation.show(.workspace)
        XCTAssertEqual(app.selection, .worktree(repository: repository.id, worktree: path))
        app.selection = .worktree(repository: repository.id, worktree: path)
        XCTAssertTrue(repository.worktreeModel(for: path) === worktree)
        XCTAssertEqual(worktree.commitMessage, "尚未提交的中文草稿")
        XCTAssertEqual(worktree.logQuery.text, "保留筛选")
        XCTAssertEqual(navigation.visited.count, 1)
        navigation.authorEmails = ["me@example.com"]
        navigation.autoRefresh = false
        navigation.show(.daily)
        let restored = AppNavigationState(defaults: defaults)
        XCTAssertEqual(restored.page, .daily)
        XCTAssertEqual(restored.authorEmails, ["me@example.com"])
        XCTAssertFalse(restored.autoRefresh)
        let next = AppModel(aiGenerationSettings: AIGenerationSettings(defaults: defaults), navigation: restored)
        next.repositories = [repository]
        restored.withRestoration { next.selection = .repositoryHome(repository: repository.id) }
        restored.restore(in: next)
        XCTAssertEqual(next.selection, .worktree(repository: repository.id, worktree: path))
        XCTAssertEqual(restored.page, .daily, "恢复仓库不能覆盖全局页面")
        restored.startup = .workspace
        XCTAssertEqual(AppNavigationState(defaults: defaults).page, .workspace)
        restored.startup = .repository
        XCTAssertEqual(AppNavigationState(defaults: defaults).page, .repositories)
    }

    func testMixedProvidersDeduplicateAndIsolateFailuresWithCache() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let script = container.appendingPathComponent("forge")
        try Data(#"""
        #!/bin/sh
        if [ -f "$GROVE_FAILURE" ]; then
          echo 'HTTP 401: 身份认证失效或网络不可用' >&2
          exit 1
        fi
        case "$1 $2" in
          "api user")
            if [ "$GROVE_PROVIDER" = "github" ]; then printf 'me\n'; else printf '{"username":"me"}\n'; fi ;;
          "pr list") cat "$GROVE_REQUESTS" ;;
          "run list") cat "$GROVE_PIPELINES" ;;
          *)
            case "$2" in
              *merge_requests*) cat "$GROVE_REQUESTS" ;;
              *pipelines*) cat "$GROVE_PIPELINES" ;;
              *) printf '{}\n' ;;
            esac ;;
        esac
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let suite = "grove.overview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(aiGenerationSettings: AIGenerationSettings(defaults: defaults), navigation: AppNavigationState(defaults: defaults))
        let git = try await GitClient.resolve()
        for (index, provider) in [ForgeKind.github, .github, .gitlab].enumerated() {
            let root = container.appendingPathComponent("repo-\(index)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await git.run(["init", "-q"], in: root)
            let remote = provider == .github ? "https://github.com/team/Grove.git" : "https://gitlab.example.com/team/Grove.git"
            try await git.run(["remote", "add", "origin", remote], in: root)
            let requests = container.appendingPathComponent("requests-\(index).json")
            let pipelines = container.appendingPathComponent("pipelines-\(index).json")
            if provider == .github {
                try Data(#"[{"number":8,"title":"待我评审","state":"OPEN","isDraft":false,"headRefName":"feature","baseRefName":"main","url":"u","updatedAt":"2026-10-14T01:00:00Z","additions":0,"deletions":0,"changedFiles":0,"isCrossRepository":false,"labels":[],"reviewRequests":[{"login":"me"}]}]"#.utf8).write(to: requests)
                try Data(#"[{"databaseId":22,"status":"completed","conclusion":"failure","headBranch":"main","updatedAt":"2026-10-14T02:00:00Z"}]"#.utf8).write(to: pipelines)
            } else {
                try Data(#"[{"iid":8,"title":"普通开放 MR","state":"opened","source_branch":"feature","target_branch":"main","web_url":"u","updated_at":"2026-10-14T01:00:00Z","merge_status":"cannot_be_merged","has_conflicts":false,"author":{"username":"other"}}]"#.utf8).write(to: requests)
                try Data(#"[{"id":22,"status":"running","ref":"main","updated_at":"2026-10-14T02:00:00Z"}]"#.utf8).write(to: pipelines)
            }
            var environment = ProcessInfo.processInfo.environment
            environment["GROVE_PROVIDER"] = provider.rawValue
            environment["GROVE_REQUESTS"] = requests.path
            environment["GROVE_PIPELINES"] = pipelines.path
            environment["GROVE_FAILURE"] = container.appendingPathComponent("failure-\(provider.rawValue)").path
            let forge: any ForgeClient = provider == .github ? GitHubClient(executable: script, environment: environment) : GitLabClient(executable: script, environment: environment)
            let repository = RepositoryModel(root: root, git: git, app: nil, forge: forge)
            repository.origin = GitRemote.parse(remote)
            app.repositories.append(repository)
        }
        let cache = "test-workspace-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: OverviewCache.url(cache)) }
        let store = WorkspaceAggregationService(cacheName: cache)
        await store.refresh(in: app)
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertEqual(store.items.count, 4, "同远端项目的本地副本不能重复展示")
        XCTAssertEqual(store.items.filter { !$0.inboxReasons.isEmpty }.count, 1)
        XCTAssertEqual(store.items.first(where: { $0.provider == .gitlab && $0.pullRequest != nil })?.kind, .pullRequest, "审批阻塞不等于 Git 冲突")
        try Data().write(to: container.appendingPathComponent("failure-gitlab"))
        await store.refresh(in: app)
        XCTAssertEqual(store.items.count, 4)
        XCTAssertTrue(store.isCached)
        XCTAssertFalse(store.issues.isEmpty)
        XCTAssertTrue(store.items.filter { $0.provider == .github }.allSatisfy { $0.isCached == false })
        XCTAssertTrue(store.items.filter { $0.provider == .gitlab }.allSatisfy { $0.isCached == true })
        let cached = WorkspaceAggregationService(cacheName: cache)
        await cached.refresh(in: app)
        XCTAssertEqual(cached.items.count, 4)
        XCTAssertEqual(cached.items.first(where: { $0.provider == .gitlab && $0.pullRequest != nil })?.pullRequest?.forge, .gitlab)
        let target = try XCTUnwrap(store.items.first(where: { $0.pullRequest != nil && $0.provider == .github }))
        await app.openWorkspaceItem(target)
        XCTAssertEqual(app.navigation.route?.pullRequest?.number, 8)
        XCTAssertTrue(app.navigation.route?.matches(app.repositories[0]) == true)
        let oldOrigin = app.repositories[0].origin
        app.repositories[0].origin = GitRemote.parse("https://github.com/another/Grove.git")
        XCTAssertFalse(app.navigation.route?.matches(app.repositories[0]) == true, "旧路由不能跨远端项目定位同编号请求")
        app.repositories[0].origin = oldOrigin
        XCTAssertEqual(app.selection, .repositoryHome(repository: app.repositories[0].id))
    }
    func testRenderOverviewPages() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GROVE_RENDER"] == "1", "设置 GROVE_RENDER=1 才会渲染")
        let suite = "grove.overview.render.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(aiGenerationSettings: AIGenerationSettings(defaults: defaults), navigation: AppNavigationState(defaults: defaults))
        app.navigation.authorEmails = ["me@example.com"]
        // 预览数据仅用于测试，不进入正式页面的数据来源。
        var conflict = request(author: "me")
        conflict.mergeable = "CONFLICTING"
        conflict.statusCheckRollup = [.init(name: "检查", conclusion: "FAILURE")]
        var review = request(reviewers: ["me"])
        review.number = 12
        review.title = "调整文件状态列表的键盘导航"
        app.workspace.items = [item(conflict), item(review)]
        app.daily.commits = [DailyCommit(repositoryIdentity: "repo", repositoryKey: "repo", repositoryName: "Grove",
            hash: "abcdef123456", authorEmail: "me@example.com", date: Date(), subject: "保留跨页面切换时的提交草稿", branch: "feature", knownOnRemote: false)]
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/overview-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for page in ["daily", "workspace", "settings"] {
                let content: AnyView
                switch page {
                case "daily": content = AnyView(DailyView().environment(app).environment(\.colorScheme, scheme))
                case "workspace": content = AnyView(WorkspaceView().environment(app).environment(\.colorScheme, scheme))
                default: content = AnyView(PreferencesView().environment(app).environment(\.colorScheme, scheme))
                }
                let hosting = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: page == "settings" ? 620 : 740, height: 740),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.contentView = hosting
                window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(250))
                window.layoutIfNeeded()
                let target = output.appendingPathComponent("\(page)-\(scheme == .light ? "light" : "dark").png")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l", String(window.windowNumber), target.path]
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: target)
                }
                XCTAssertGreaterThan(try Data(contentsOf: target).count, 1000)
                window.orderOut(nil)
                window.contentView = nil
            }
        }
    }

}
