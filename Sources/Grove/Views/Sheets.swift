import SwiftUI

/// 提 PR。会先把分支推上去，再调 `gh pr create`。
struct CreatePullRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorktreeModel

    @State private var title = ""
    @State private var body_ = ""
    @State private var base = ""
    @State private var isDraft = false
    @State private var isWorking = false
    @State private var createdURL: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let createdURL {
                successView(createdURL)
            } else {
                form
                Divider()
                footer
            }
        }
        .frame(width: 560, height: 520)
        .onAppear(perform: prefill)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("创建 Pull Request")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 5) {
                Text(model.worktree.branch ?? "")
                    .font(.system(size: 11, design: .monospaced))
                Image(systemName: "arrow.right").font(.system(size: 9))
                Text(base.isEmpty ? "?" : base)
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("目标分支") {
                    TextField("main", text: $base)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                }

                LabeledContent("标题") {
                    TextField("", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("描述")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $body_)
                        .font(.system(size: 11.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(height: 180)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7).stroke(.separator, lineWidth: 0.5)
                        }
                }

                Toggle("创建为草稿", isOn: $isDraft)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .help("草稿 PR 不会触发评审请求，也不能被合并")

                if model.status.upstream == nil {
                    Label("这个分支还没推到远端。创建时会自动 push 并建立跟踪关系。",
                          systemImage: "info.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.status.ahead > 0 {
                    Label("本地领先远端 \(model.status.ahead) 个提交，创建时会先推送。",
                          systemImage: "info.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                if !model.status.isClean {
                    Label("工作区还有 \(model.status.changes.count) 个未提交的改动，它们不会进入这个 PR。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
    }

    private var footer: some View {
        HStack {
            if isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.activity ?? "处理中…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("创建") {
                Task { await create() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate || isWorking)
        }
        .padding(14)
    }

    private func successView(_ url: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("PR 已创建")
                .font(.system(size: 15, weight: .semibold))
            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button("复制链接") { SystemActions.copyToPasteboard(url) }
                Button("在浏览器打开") { SystemActions.openInBrowser(url) }
                    .buttonStyle(.borderedProminent)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !base.trimmingCharacters(in: .whitespaces).isEmpty
            && base.trimmingCharacters(in: .whitespaces) != model.worktree.branch
    }

    private func prefill() {
        title = model.suggestedPullRequestTitle
        body_ = model.suggestedPullRequestBody
        base = model.repository?.defaultBranch ?? "main"
    }

    private func create() async {
        isWorking = true
        defer { isWorking = false }
        let url = await model.createPullRequest(
            title: title.trimmingCharacters(in: .whitespaces),
            body: body_,
            base: base.trimmingCharacters(in: .whitespaces),
            isDraft: isDraft
        )
        if let url {
            createdURL = url
        } else {
            // 失败原因已经通过 AppModel 的错误横幅显示了，这里只需要把弹窗关掉，
            // 让用户能看见那条横幅。
            dismiss()
        }
    }
}

// MARK: - 删除工作树

struct RemoveWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repository: RepositoryModel
    let worktree: Worktree

    @State private var deleteBranch = false
    @State private var force = false
    @State private var isWorking = false
    @State private var isDirty: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 26))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text("删除工作树「\(worktree.name)」？")
                        .font(.system(size: 14, weight: .semibold))
                    Text(worktree.path.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Text("目录会从磁盘上删除。分支和提交默认保留 —— 之后可以再检出一份新工作树。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                if let branch = worktree.branch {
                    Toggle("同时删除分支「\(branch)」", isOn: $deleteBranch)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                }

                Toggle("强制删除（丢弃未提交的改动）", isOn: $force)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }

            if isDirty == true && !force {
                Label("这个工作树里有未提交的改动。不勾「强制删除」的话 git 会拒绝。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if worktree.isLocked {
                Label("这个工作树是锁定状态，需要先解锁或勾选强制删除。",
                      systemImage: "lock.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }

            Spacer()

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("删除") {
                    Task {
                        isWorking = true
                        await repository.removeWorktree(worktree, force: force, deleteBranch: deleteBranch)
                        isWorking = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 480, height: 330)
        .task {
            // 现查一次脏状态，而不是用缓存 —— 用户可能几分钟前打开的界面，
            // 期间在终端里改了文件。这里判断错会导致「强制删除」提示缺失。
            guard let model = repository.worktreeModel(for: worktree.path) else {
                isDirty = nil
                return
            }
            await model.refreshStatus()
            isDirty = !model.status.isClean
        }
    }
}

// MARK: - 清理分支

struct CleanupBranchesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repository: RepositoryModel

    @State private var selected: Set<String> = []
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("清理已合并分支")
                    .font(.system(size: 15, weight: .semibold))
                Text("这些分支的上游已经在远端被删除了 —— 通常意味着对应的 PR 已经合并。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if repository.staleBranches.isEmpty {
                ContentUnavailableView {
                    Label("没有可清理的分支", systemImage: "checkmark.seal")
                } description: {
                    Text("先「抓取远端」再回来看看。")
                }
            } else {
                List {
                    ForEach(repository.staleBranches) { branch in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { selected.contains(branch.name) },
                                set: { isOn in
                                    if isOn { selected.insert(branch.name) } else { selected.remove(branch.name) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 1) {
                                Text(branch.name)
                                    .font(.system(size: 11.5))
                                Text(branch.subject)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(branch.lastCommitDate.map(RelativeDate.format) ?? "")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button(selected.count == repository.staleBranches.count ? "全不选" : "全选") {
                    if selected.count == repository.staleBranches.count {
                        selected.removeAll()
                    } else {
                        selected = Set(repository.staleBranches.map(\.name))
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(repository.staleBranches.isEmpty)

                if isWorking { ProgressView().controlSize(.small) }

                Spacer()

                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("删除 \(selected.count) 个分支") {
                    Task { await cleanup() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selected.isEmpty || isWorking)
            }
            .padding(14)
        }
        .frame(width: 520, height: 420)
    }

    private func cleanup() async {
        isWorking = true
        defer { isWorking = false }
        for name in selected {
            guard let branch = repository.branches.first(where: { $0.name == name }) else { continue }
            // 上游已经没了，git 判断不出「合并过没有」，所以只能强制删。
            // 用户在这个界面上勾选就是明确同意了。
            await repository.deleteBranch(branch, force: true)
        }
        dismiss()
    }
}

// MARK: - 合并 PR

struct MergePullRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repository: RepositoryModel
    let pullRequest: PullRequest

    @State private var strategy: MergeStrategy = .squash
    @State private var deleteBranch = true
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("合并 PR #\(pullRequest.number)")
                    .font(.system(size: 15, weight: .semibold))
                Text(pullRequest.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if pullRequest.checks.isFailing {
                Label("有检查未通过。合并前最好先确认一下。", systemImage: "xmark.circle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }
            if pullRequest.review == .changesRequested {
                Label("有评审者要求修改。", systemImage: "exclamationmark.bubble.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
            if pullRequest.mergeable?.uppercased() == "CONFLICTING" {
                Label("跟目标分支有冲突，GitHub 无法自动合并。", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("合并方式")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                ForEach(MergeStrategy.allCases) { option in
                    Button {
                        strategy = option
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: strategy == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(strategy == option ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label).font(.system(size: 11.5, weight: .medium))
                                Text(option.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Toggle("合并后删除远端分支", isOn: $deleteBranch)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))

            if let failure {
                Text(failure)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("合并") {
                    Task { await merge() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }

    private func merge() async {
        isWorking = true
        defer { isWorking = false }
        failure = nil

        guard let github = await GitHubClient.resolve() else {
            failure = GroveError.ghNotFound.localizedDescription
            return
        }
        do {
            try await github.merge(
                number: pullRequest.number,
                strategy: strategy,
                deleteBranch: deleteBranch,
                in: repository.root
            )
        } catch {
            // 合并失败的原因（缺权限、检查未过、分支保护规则）都在 gh 的报错里，
            // 直接显示在弹窗里而不是关掉窗口 —— 用户正要决定下一步怎么办。
            failure = error.localizedDescription
            return
        }
        await repository.fetch()
        dismiss()
    }
}

// MARK: - 偏好设置

struct PreferencesView: View {
    var body: some View {
        Form {
            Section("外部工具") {
                Text("Grove 会自动找系统里已装的 git 和 GitHub CLI（gh）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                LabeledContent("git") { ToolStatusLabel(tool: "git") }
                LabeledContent("gh") { ToolStatusLabel(tool: "gh") }
            }

            Section("工作树位置") {
                Text("新工作树默认创建在 <仓库>-worktrees/<分支名> 里 —— 仓库的兄弟目录。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
    }
}

private struct ToolStatusLabel: View {
    let tool: String
    @State private var path: String?
    @State private var checked = false

    var body: some View {
        Group {
            if let path {
                Text(path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if checked {
                Label("未找到", systemImage: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .task {
            path = await ToolLocator.shared.locate(tool)?.path
            checked = true
        }
    }
}

// MARK: - 变基

/// 选一个目标分支，把当前分支重放上去。
///
/// 变基会改写历史，所以这个弹窗的重点不是「选哪个分支」，而是把
/// **将要发生什么**说清楚：重放几个提交、已推送的提交会不会被改写。
struct RebaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorktreeModel

    @State private var target = ""
    @State private var autostash = true
    @State private var commitCount: Int?
    @State private var targetExists = true
    @State private var isWorking = false

    private var repository: RepositoryModel? { model.repository }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 540, height: 480)
        .onAppear {
            target = model.suggestedRebaseTarget ?? ""
            Task { await refreshPreview() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("变基")
                .font(.system(size: 15, weight: .semibold))
            HStack(spacing: 5) {
                Text(model.worktree.branch ?? "当前分支")
                    .font(.system(size: 11, design: .monospaced))
                Text("重放到")
                Text(target.isEmpty ? "?" : target)
                    .font(.system(size: 11, design: .monospaced))
                Text("之上")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("目标")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        TextField("origin/main", text: $target)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .onSubmit { Task { await refreshPreview() } }

                        Menu {
                            if let remotes = repository?.remoteBranches, !remotes.isEmpty {
                                Section("远端分支") {
                                    ForEach(remotes.prefix(30)) { branch in
                                        Button(branch.name) { pick(branch.name) }
                                    }
                                }
                            }
                            if let locals = repository?.branches, !locals.isEmpty {
                                Section("本地分支") {
                                    ForEach(locals.prefix(30)) { branch in
                                        Button(branch.name) { pick(branch.name) }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }

                    if !target.isEmpty && !targetExists {
                        Label("找不到这个引用。抓取一次远端，或者从右边的列表里选。",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }
                }

                Toggle("自动暂存未提交的改动（--autostash）", isOn: $autostash)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .help("变基前自动 stash，结束后自动还原。不勾的话工作区一脏 git 就会拒绝。")

                Divider()

                // 把「将要发生什么」摊开。变基是改写历史的操作，
                // 点之前看不到影响范围的话，出了事只能靠 reflog 补救。
                VStack(alignment: .leading, spacing: 6) {
                    Text("将要发生")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    if let commitCount {
                        if commitCount == 0 {
                            Label("已经在 \(target) 之上了，没有提交需要重放。",
                                  systemImage: "checkmark.circle")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        } else {
                            Label("\(commitCount) 个提交会被重放到 \(target) 上，它们的 SHA 会全部变化。",
                                  systemImage: "arrow.triangle.branch")
                                .font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if targetExists {
                        ProgressView().controlSize(.small)
                    }

                    if model.status.ahead > 0, model.status.upstream != nil {
                        Label("这个分支已经推到 \(model.status.upstream!)。变基之后再推需要强制推送，"
                              + "而别人如果已经基于它工作，会受影响。",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !model.status.isClean {
                        Label(autostash
                              ? "工作区有 \(model.status.changes.count) 个未提交改动，会被自动暂存并在结束后还原。"
                              : "工作区有 \(model.status.changes.count) 个未提交改动 —— 不勾自动暂存的话 git 会拒绝执行。",
                              systemImage: autostash ? "info.circle" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(autostash ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Label("中途遇到冲突会停下来，Grove 会在顶部给出「继续 / 跳过 / 中止」。",
                          systemImage: "info.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
    }

    private var footer: some View {
        HStack {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("开始变基") {
                Task {
                    isWorking = true
                    await model.rebase(onto: target.trimmingCharacters(in: .whitespaces), autostash: autostash)
                    isWorking = false
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty
                      || !targetExists || isWorking || commitCount == 0)
        }
        .padding(14)
    }

    private func pick(_ name: String) {
        target = name
        Task { await refreshPreview() }
    }

    private func refreshPreview() async {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            targetExists = true
            commitCount = nil
            return
        }
        commitCount = nil
        let count = await model.rebaseCommitCount(onto: trimmed)
        targetExists = count != nil
        commitCount = count
    }
}
