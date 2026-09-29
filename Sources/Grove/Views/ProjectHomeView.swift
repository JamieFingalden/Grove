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

    @State private var tab: ProjectHomeTab = .pullRequests

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch tab {
                case .pullRequests:
                    PullRequestListView(repository: repository)
                case .ci:
                    CIView(repository: repository)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(repository.root.lastPathComponent)
                    .font(.system(size: 12.5, weight: .semibold))
                HStack(spacing: 5) {
                    Text(repository.root.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 远端身份跟在路径后面：这页上的功能都作用于这个远端。
                    if let forge = repository.forge {
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(forge.kind.displayName)
                    }
                    if let slug = repository.slug {
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(slug)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            if let remote = remoteURL {
                Button {
                    NSWorkspace.shared.open(remote)
                } label: {
                    Label("浏览器", systemImage: "safari")
                }
                .controlSize(.small)
                .help("在平台的网页上打开这个仓库")
            }

            Picker("分栏", selection: $tab) {
                Text(repository.reviewTerm).tag(ProjectHomeTab.pullRequests)
                Text("CI/CD").tag(ProjectHomeTab.ci)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 220)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
