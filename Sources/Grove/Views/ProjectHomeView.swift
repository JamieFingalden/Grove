import SwiftUI

/// 主页的分栏。
enum ProjectHomeTab: Hashable {
    case pullRequests
    case ci
}

/// 项目主页：仓库级功能的唯一入口。
///
/// 侧边栏每个仓库只有一行（名字即入口），PR、CI/CD 等仓库级功能
/// 都是主页里的分栏 tab —— 以后加仓库级能力只加 tab，
/// 侧边栏不会再一行行长下去。
///
/// 不做「概览」落地页：几个卡片根本撑不满一屏，剩下的全是空白，
/// 看起来像没做完。落地就直接是拉取请求列表。
struct ProjectHomeView: View {
    let repository: RepositoryModel
    @Environment(AppModel.self) private var appModel

    @Environment(\.repositoryPageActive) private var active
    @State private var tab: ProjectHomeTab = .pullRequests
    @State private var visitedCI = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                PullRequestListView(repository: repository, projectTab: $tab)
                    .environment(\.repositoryPageActive, active && tab == .pullRequests)
                    .retainedPage(tab == .pullRequests)
                if visitedCI {
                    CIView(repository: repository, projectTab: $tab)
                        .environment(\.repositoryPageActive, active && tab == .ci)
                        .retainedPage(tab == .ci)
                }
            }
            .onChange(of: tab) { _, tab in if tab == .ci { visitedCI = true } }
            .onChange(of: appModel.navigation.route?.id, initial: true) { _, _ in
                guard let route = appModel.navigation.route, route.matches(repository) else { return }
                if route.pipeline != nil { visitedCI = true; tab = .ci }
                if route.pullRequest != nil { tab = .pullRequests }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: GroveStyle.Space.md) {
                VStack(alignment: .leading, spacing: GroveStyle.Space.xs) {
                    Text(repository.name)
                        .font(GroveStyle.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(repository.name)
                    HStack(spacing: GroveStyle.Space.xs) {
                        if let forge = repository.forge {
                            Text(forge.kind.displayName).fixedSize()
                            Text("·")
                        }
                        Text(repository.slug ?? repository.root.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(GroveStyle.caption)
                    .foregroundStyle(.secondary)
                    .help(repository.root.path)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if repository.forge != nil {
                    ViewThatFits(in: .horizontal) {
                        automaticReviewToggle(compact: false)
                        automaticReviewToggle(compact: true)
                    }
                }

                if let remote = remoteURL {
                    Button { NSWorkspace.shared.open(remote) } label: {
                        Label("浏览器", systemImage: "arrow.up.forward.square")
                            .labelStyle(.iconOnly)
                            .font(GroveStyle.toolIcon)
                            .frame(width: GroveStyle.toolHitArea, height: GroveStyle.toolHitArea)
                    }
                    .buttonStyle(.borderless)
                    .modifier(GroveRowHover())
                    .tint(.secondary)
                    .help("在平台的网页上打开这个仓库")
                    .accessibilityLabel("在浏览器打开仓库")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, GroveStyle.Space.lg)
            .frame(height: 56)

        }
        .background(.bar)
    }

    private func automaticReviewToggle(compact: Bool) -> some View {
        let enabled = appModel.automaticAIReviewEnabled(for: repository.root)
        let running = repository.pullRequests.contains {
            appModel.isAIReviewing(for: repository.root, pullRequestNumber: $0.number)
        }
        let status = !enabled ? "已关闭" : !appModel.canUseAIGeneration ? "已暂停" : running ? "审查中" : "已开启"
        return Toggle(isOn: Binding(
            get: { appModel.automaticAIReviewEnabled(for: repository.root) },
            set: { appModel.setAutomaticAIReviewEnabled($0, for: repository.root) }
        )) {
            HStack(spacing: GroveStyle.Space.xs) {
                if running && enabled && appModel.canUseAIGeneration {
                    ProgressView().controlSize(.mini)
                        .frame(width: GroveStyle.Space.lg, height: GroveStyle.Space.lg)
                        .help(status)
                } else {
                    Image(systemName: "sparkles").font(GroveStyle.toolIcon).foregroundStyle(.secondary)
                        .frame(width: GroveStyle.Space.lg, height: GroveStyle.Space.lg)
                }
                if !compact {
                    Text("自动审查").font(GroveStyle.metadata)
                    if enabled && !appModel.canUseAIGeneration {
                        Image(systemName: "pause.circle").foregroundStyle(.secondary).help(status)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .fixedSize()
        .disabled(!appModel.canUseAIGeneration)
        .accessibilityLabel("当前仓库自动审查")
        .accessibilityValue(status)
        .help(appModel.canUseAIGeneration
              ? "当前仓库自动审查\(status)。Grove 运行期间自动审查新 PR；后续推送只通知你，由你决定是否重新审查。"
              : "AI 功能当前不可用，自动审查已暂停。请在设置中启用 AI 并配置服务。")
    }

    /// 远端网页地址：从 origin 的 host/path 拼，不依赖平台接口。
    private var remoteURL: URL? {
        guard let origin = repository.origin else { return nil }
        let scheme = origin.scheme ?? "https"
        var components = URLComponents()
        components.scheme = scheme
        components.host = origin.host
        if let port = origin.port { components.port = port }
        components.path = "/\(origin.path)"
        return components.url
    }
}

/// 项目导航与内容操作共用一条工具栏，避免重复标题占用纵向空间。
struct ProjectHomeNavigation: View {
    let repository: RepositoryModel
    @Binding var selection: ProjectHomeTab

    var body: some View {
        Picker("项目导航", selection: $selection) {
            Text(repository.reviewTerm).tag(ProjectHomeTab.pullRequests)
            Text("CI/CD").tag(ProjectHomeTab.ci)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .fixedSize()
    }
}
