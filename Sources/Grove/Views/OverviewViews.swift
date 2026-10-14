import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var app
    @State private var inbox = true
    @State private var project = ""
    @State private var type = ""
    @State private var state = ""
    @State private var relatedOnly = false
    private var store: WorkspaceAggregationService { app.workspace }
    private var visible: [WorkspaceItem] {
        store.items.filter {
            (!inbox || !$0.inboxReasons.isEmpty) && (project.isEmpty || $0.projectKey == project) &&
            $0.matches(type: type, status: state) && (!relatedOnly || $0.relatedToMe)
        }.sorted {
            if inbox && $0.priority != $1.priority { return $0.priority > $1.priority }
            return ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
        }
    }
    private var projects: [WorkspaceItem] {
        var seen = Set<String>()
        return store.items.filter { seen.insert($0.projectKey).inserted }.sorted { $0.repositoryName < $1.repositoryName }
    }
    private var refreshKey: String {
        "\(app.navigation.page == .workspace):\(app.overviewReady):\(app.navigation.autoRefresh):" +
            app.repositories.map { "\($0.id.identityKey):\($0.origin?.hostWithPort ?? ""):\($0.origin?.path ?? ""):\($0.forge?.kind.rawValue ?? "")" }.joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OverviewHeader(title: "Workspace", subtitle: "\(store.items.filter { !$0.inboxReasons.isEmpty }.count) 个待处理事项",
                           refreshing: store.isRefreshing, lastRefresh: store.lastRefresh, cached: store.isCached) {
                Task { await store.refresh(in: app) }
            }
            HStack(spacing: GroveStyle.Space.section) {
                OverviewMetric(title: "待处理 PR / MR", value: store.items.filter { $0.pullRequest != nil && !$0.inboxReasons.isEmpty }.count)
                OverviewMetric(title: "CI 检查异常", value: store.items.filter { $0.inboxReasons.contains("CI 检查失败") }.count)
                OverviewMetric(title: "我的合并冲突", value: store.items.filter { $0.inboxReasons.contains("Git 合并冲突") }.count)
                Spacer()
            }
            .padding(.horizontal, GroveStyle.Space.section).padding(.bottom, GroveStyle.Space.lg)
            Divider()
            HStack {
                Picker("工作台视图", selection: $inbox) {
                    Text("Inbox").tag(true)
                    Text("All Activity").tag(false)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 230)
                Spacer()
                Toggle("与我相关", isOn: $relatedOnly).toggleStyle(.checkbox)
            }.padding(.horizontal, GroveStyle.Space.section).padding(.vertical, GroveStyle.Space.md)
            HStack {
                Picker("项目", selection: $project) {
                    Text("全部项目").tag("")
                    ForEach(projects) { Text("\($0.repositoryName) · \($0.projectKey)").tag($0.projectKey) }
                }.frame(maxWidth: 260)
                Picker("类型", selection: $type) {
                    Text("全部类型").tag("")
                    Text("PR / MR").tag(WorkspaceItem.Kind.pullRequest.rawValue)
                    Text("CI").tag(WorkspaceItem.Kind.ci.rawValue)
                    Text("Conflict").tag(WorkspaceItem.Kind.conflict.rawValue)
                }.frame(width: 145)
                Picker("状态", selection: $state) {
                    Text("全部状态").tag("")
                    ForEach(["开放", "草稿", "已合并", "已关闭", "等待中", "运行中", "已通过", "已失败", "已取消", "待评审", "要求修改", "Git 冲突"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 145)
                Spacer(minLength: 0)
            }.labelsHidden().padding(.horizontal, GroveStyle.Space.section).padding(.bottom, GroveStyle.Space.md)
            Text(inbox ? "只显示明确指定给我的评审、我的 PR 冲突 / 检查失败 / 要求修改。团队评审及流水线个人归属无法确认时不推断。" : "当前状态快照：开放请求及最近最多 50 条历史请求、50 条流水线；时间来自平台更新或创建时间，并非完整事件历史。")
                .font(GroveStyle.caption).foregroundStyle(.secondary)
                .padding(.horizontal, GroveStyle.Space.section).padding(.bottom, GroveStyle.Space.md)
            OverviewIssues(issues: store.issues)
            Divider()
            if visible.isEmpty {
                if store.isRefreshing && store.items.isEmpty {
                    GroveLoadingState(title: "正在同步各项目…")
                } else {
                    GroveEmptyState(title: inbox ? "没有符合条件的待办" : "没有符合条件的活动", systemImage: inbox ? "tray" : "clock",
                                    description: app.repositories.isEmpty ? "打开本地仓库后，Grove 会复用现有 GitHub / GitLab 集成。" : "调整筛选或刷新数据。个人归属无法确认的动态只会出现在 All Activity。")
                }
            } else {
                List(visible) { item in
                    Button { Task { await app.openWorkspaceItem(item) } } label: { WorkspaceRow(item: item) }
                        .buttonStyle(.plain).modifier(GroveRowHover())
                        .listRowSeparator(.visible)
                }.listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GroveStyle.content)
        .task(id: refreshKey) {
            guard app.navigation.page == .workspace, app.overviewReady else { return }
            // 新任务等取消中的旧刷新退出，避免来源变化时漏掉首次同步。
            while store.isRefreshing && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            await store.refresh(in: app)
            while app.navigation.autoRefresh && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await store.refresh(in: app)
            }
        }
    }
}

private struct WorkspaceRow: View {
    let item: WorkspaceItem
    private var tint: Color {
        if item.kind == .conflict || item.inboxReasons.contains("CI 检查失败") { return .red }
        if let pipeline = item.pipeline { return pipeline.status.tint }
        if item.pullRequest?.status == .merged { return .purple }
        return .secondary
    }
    var body: some View {
        HStack(alignment: .top, spacing: GroveStyle.Space.md) {
            Image(systemName: item.kind == .conflict ? "exclamationmark.triangle" : item.pipeline?.status.systemImage ?? item.pullRequest?.status.systemImage ?? "tray")
                .foregroundStyle(tint).frame(width: 18).padding(.top, 3)
            VStack(alignment: .leading, spacing: GroveStyle.Space.xs) {
                HStack {
                    Text(item.repositoryName).font(GroveStyle.sectionTitle)
                    Text("\(item.provider.displayName) · \(item.objectLabel)").font(GroveStyle.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(item.statusLabel).font(GroveStyle.caption).foregroundStyle(item.pipeline?.status.tint ?? .secondary)
                }
                Text(item.title).font(GroveStyle.body).lineLimit(2)
                HStack {
                    Text(item.branch).lineLimit(1).truncationMode(.middle)
                    if let author = item.pullRequest?.author { Text("· \(author.login)") }
                    Spacer()
                    if let date = item.timestamp {
                        Text("\(item.pipeline != nil && item.pipeline?.updatedAt == nil ? "创建" : "更新") \(CIFormat.relative(date))")
                    } else { Text("时间未知") }
                }.font(GroveStyle.caption).foregroundStyle(.secondary)
                if item.isCached == true, let date = item.cacheTimestamp {
                    Text("缓存 · 同步于 \(CIFormat.relative(date))").font(GroveStyle.caption).foregroundStyle(.orange)
                }
                if let pr = item.pullRequest {
                    HStack(spacing: GroveStyle.Space.md) {
                        if pr.mergeable == "CONFLICTING" && pr.isActive { Text("Git 合并冲突").foregroundStyle(.red) }
                        if let checks = pr.checks.label { Text(checks).foregroundStyle(pr.checks.tint) }
                        if let review = pr.review.label { Text(review).foregroundStyle(.secondary) }
                        if item.inboxReasons.contains("请求我评审") { Text("请求我评审").foregroundStyle(.orange) }
                    }.font(GroveStyle.caption)
                }
            }
        }.padding(.vertical, GroveStyle.Space.sm).contentShape(Rectangle())
    }
}

struct DailyView: View {
    @Environment(AppModel.self) private var app
    private var store: DailyViewModel { app.daily }
    private var today: Date { Calendar.current.startOfDay(for: Date()) }
    private var refreshKey: String {
        "\(app.navigation.page == .daily):\(app.overviewReady):\(app.navigation.autoRefresh):" + app.repositories.map { $0.id.identityKey }.joined(separator: "|") + app.navigation.authorEmails.joined(separator: "|")
    }
    private var projectSummary: String {
        store.projectSummary(on: store.selectedDate)
    }
    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            OverviewHeader(title: "Daily", subtitle: today.formatted(date: .complete, time: .omitted),
                           refreshing: store.isRefreshing, lastRefresh: store.lastRefresh, cached: store.isCached) {
                Task { await store.refresh(in: app) }
            }
            HStack(spacing: GroveStyle.Space.section) {
                OverviewMetric(title: "今日个人提交", value: store.activity(on: today).count)
                OverviewMetric(title: "今日活跃仓库", value: store.activeRepositories(on: today))
                OverviewMetric(title: "存在领先提交的仓库", value: store.aheadRepositoryCount)
                Spacer()
            }.padding(.horizontal, GroveStyle.Space.section).padding(.bottom, GroveStyle.Space.lg)
            Text("按已确认的 Author Email 匹配，使用 Committer Date 与本地时区；仅扫描本地仓库。远端状态基于本地引用，未联网校验。")
                .font(GroveStyle.caption).foregroundStyle(.secondary)
                .padding(.horizontal, GroveStyle.Space.section).padding(.bottom, GroveStyle.Space.lg)
            Divider()
            HStack(spacing: GroveStyle.Space.sm) {
                ForEach(store.days, id: \.self) { day in
                    Button { store.selectedDate = day } label: {
                        VStack(spacing: 5) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated).day())).font(GroveStyle.caption)
                            Text("\(store.activity(on: day).count)").font(GroveStyle.sectionTitle)
                            Text("\(store.activeRepositories(on: day)) 个仓库").font(GroveStyle.micro).foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Calendar.current.isDate(day, inSameDayAs: store.selectedDate) ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(height: 3)
                        }.frame(maxWidth: .infinity).padding(8)
                            .background(Calendar.current.isDate(day, inSameDayAs: store.selectedDate) ? GroveStyle.selection : Color.clear,
                                        in: RoundedRectangle(cornerRadius: GroveStyle.smallRadius))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(day.formatted(date: .complete, time: .omitted))，\(store.activity(on: day).count) 个提交")
                }
            }.padding(.horizontal, GroveStyle.Space.lg).padding(.vertical, GroveStyle.Space.md)
            OverviewIssues(issues: store.issues)
            HStack {
                Text(store.selectedDate.formatted(date: .long, time: .omitted)).font(GroveStyle.sectionTitle)
                Spacer()
                SettingsLink { Label("个人身份", systemImage: "person.crop.circle") }.font(GroveStyle.caption)
            }.padding(.horizontal, GroveStyle.Space.section).padding(.vertical, GroveStyle.Space.sm)
            if !projectSummary.isEmpty {
                Text("活跃项目：\(projectSummary)").font(GroveStyle.caption).foregroundStyle(.secondary)
                    .lineLimit(1).help(projectSummary)
                    .padding(.horizontal, GroveStyle.Space.section).padding(.bottom, GroveStyle.Space.sm)
            }
            if app.navigation.authorEmails.isEmpty {
                GroveEmptyState(title: "先确认你的 Git 身份", systemImage: "person.crop.circle",
                                description: "在设置中添加或确认用于个人记录的 Author Email。未确认前不会把其他开发者的提交计入 Daily。") {
                    SettingsLink { Text("打开设置") }
                }
            } else if store.isRefreshing && store.commits.isEmpty {
                GroveLoadingState(title: "正在读取开发记录…")
            } else if store.activity(on: store.selectedDate).isEmpty {
                GroveEmptyState(title: "这一天还没有个人提交", systemImage: "book.closed", description: "选择其他日期，或刷新本地 Git 记录。")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.activity(on: store.selectedDate)) { commit in
                            Button { Task { await app.openDailyCommit(commit) } } label: {
                                HStack(alignment: .top, spacing: GroveStyle.Space.lg) {
                                    Text(commit.date.formatted(date: .omitted, time: .shortened))
                                        .font(GroveStyle.caption).foregroundStyle(.secondary).frame(width: 55, alignment: .leading)
                                    VStack(alignment: .leading, spacing: GroveStyle.Space.xs) {
                                        Text(commit.subject).font(GroveStyle.body).lineLimit(2)
                                        HStack {
                                            Text(commit.repositoryName).font(GroveStyle.sectionTitle)
                                            Text(String(commit.hash.prefix(8))).monospaced()
                                            if let branch = commit.branch { Text("分支顶端：\(branch)").lineLimit(1).truncationMode(.middle) }
                                            Spacer()
                                            Text(commit.knownOnRemote ? "本地远端引用已包含" : "推送状态未确认")
                                        }.font(GroveStyle.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, GroveStyle.Space.sm).contentShape(Rectangle())
                            }.buttonStyle(.plain).modifier(GroveRowHover())
                                .help("在项目历史中查看提交")
                            Divider()
                        }
                    }.padding(.horizontal, GroveStyle.Space.lg)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(store.selectedDate)
            }
            Divider()
            DisclosureGroup("分支与未推送状态 · \(store.aheadRepositoryCount) 个仓库存在领先提交") {
                ScrollView {
                    VStack(alignment: .leading, spacing: GroveStyle.Space.sm) {
                        ForEach(store.branches) { branch in
                            HStack {
                                Text(branch.repositoryName).font(GroveStyle.sectionTitle)
                                Text(branch.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(branch.label).foregroundStyle((branch.ahead ?? 0) > 0 ? Color.orange : Color.secondary)
                            }.font(GroveStyle.caption)
                        }
                        if store.branches.isEmpty { Text("没有本地分支信息。读取失败或无上游时，推送状态无法确认。").font(GroveStyle.caption).foregroundStyle(.secondary) }
                    }
                }.frame(maxHeight: 145)
            }.font(GroveStyle.metadata).padding(GroveStyle.Space.lg)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(GroveStyle.content)
        .task(id: refreshKey) {
            guard app.navigation.page == .daily, app.overviewReady else { return }
            while store.isRefreshing && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            await store.refresh(in: app)
            while app.navigation.autoRefresh && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                await store.refresh(in: app)
            }
        }
    }
}

private struct OverviewHeader: View {
    var title: String
    var subtitle: String
    var refreshing: Bool
    var lastRefresh: Date?
    var cached: Bool
    var refresh: () -> Void
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: GroveStyle.Space.xs) {
                Text(title).font(GroveStyle.title)
                Text(subtitle).font(GroveStyle.metadata).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: GroveStyle.Space.xs) {
                if let lastRefresh { Text("\(cached ? "最近尝试" : "最近同步") \(CIFormat.relative(lastRefresh))") }
                if cached { Text("部分数据为缓存，可能已过期").foregroundStyle(.orange) }
            }.font(GroveStyle.caption).foregroundStyle(.secondary)
            if refreshing { ProgressView().controlSize(.small) }
            Button(action: refresh) { Label("刷新", systemImage: "arrow.clockwise") }.disabled(refreshing)
        }.padding(GroveStyle.Space.section)
    }
}

private struct OverviewMetric: View {
    var title: String
    var value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: GroveStyle.Space.xs) {
            Text("\(value)").font(GroveStyle.title).monospacedDigit()
            Text(title).font(GroveStyle.caption).foregroundStyle(.secondary)
        }
    }
}

private struct OverviewIssues: View {
    let issues: [OverviewIssue]
    var body: some View {
        if !issues.isEmpty {
            DisclosureGroup("\(issues.count) 项同步提示 · 其他项目仍可使用") {
                ScrollView {
                    VStack(alignment: .leading, spacing: GroveStyle.Space.sm) {
                        ForEach(issues) { Text("\($0.source)：\($0.message)").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }.frame(maxHeight: 110)
            }.font(GroveStyle.caption).foregroundStyle(.orange)
                .padding(.horizontal, GroveStyle.Space.section).padding(.bottom, GroveStyle.Space.md)
        }
    }
}

private extension PullRequest.CheckRollup {
    var tint: Color {
        switch self {
        case .failing: .red
        case .passing: .green
        case .running, .none: .secondary
        }
    }
}
