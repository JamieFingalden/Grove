import SwiftUI

/// 新建工作树。三种来源覆盖了实际用到的所有情况：开新功能（新建分支）、
/// 回到某个已有分支、或者检出别人推上来的远端分支。
struct NewWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    let repository: RepositoryModel

    @State private var source: Source = .newBranch
    @State private var branchName = ""
    @State private var startPoint = ""
    @State private var selectedLocalBranch: String?
    @State private var selectedRemoteBranch: String?
    @State private var path = ""
    /// 用户有没有手动改过路径。没改过的话路径跟着分支名自动走；
    /// 改过之后就不能再覆盖 —— 那是用户明确的选择。
    @State private var pathWasEdited = false
    @State private var isWorking = false

    enum Source: String, CaseIterable, Identifiable {
        case newBranch, localBranch, remoteBranch

        var id: String { rawValue }
        var label: String {
            switch self {
            case .newBranch: "新建分支"
            case .localBranch: "已有分支"
            case .remoteBranch: "远端分支"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("来源", selection: $source) {
                        ForEach(Source.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    sourceFields
                    Divider()
                    pathField
                }
                .padding(18)
            }

            Divider()
            footer
        }
        .frame(width: 540, height: 470)
        .onAppear(perform: prefill)
        .onChange(of: effectiveBranchName) { _, newValue in
            guard !pathWasEdited, !newValue.isEmpty else { return }
            path = repository.suggestedWorktreePath(for: newValue).path
        }
    }

    // MARK: -

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("新建工作树")
                .font(.system(size: 15, weight: .semibold))
            Text("在 \(repository.name) 里开一份独立的检出，跟现有工作树互不干扰。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sourceFields: some View {
        switch source {
        case .newBranch:
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("分支名") {
                    TextField("feature/我的新功能", text: $branchName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("起点") {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField(repository.defaultBranch ?? "HEAD", text: $startPoint)
                            .textFieldStyle(.roundedBorder)
                        Text("留空则从 \(repository.defaultBranch ?? "当前 HEAD") 开始。可填分支名、标签或提交 SHA。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                if !branchName.isEmpty, repository.branches.contains(where: { $0.name == branchName }) {
                    Label("这个分支已经存在了。换成「已有分支」来检出它。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }

        case .localBranch:
            branchPicker

        case .remoteBranch:
            remoteBranchPicker
        }
    }

    private var branchPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("选择一个本地分支")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if repository.branches.isEmpty {
                Text("没有本地分支。").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                List(selection: $selectedLocalBranch) {
                    ForEach(repository.branches) { branch in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Text(branch.name)
                                .font(.system(size: 11.5))
                                .lineLimit(1)

                            if branch.ahead > 0 { Badge(text: "\(branch.ahead)", systemImage: "arrow.up", tint: .blue) }
                            if branch.behind > 0 { Badge(text: "\(branch.behind)", systemImage: "arrow.down", tint: .purple) }
                            if branch.upstreamIsGone {
                                MiniBadge(text: "上游已删", systemImage: "trash", tint: .orange)
                            }

                            Spacer()

                            if let worktreePath = branch.worktreePath {
                                // 已被占用的分支不能再检出一份，标出来并禁掉。
                                MiniBadge(text: worktreePath.lastPathComponent, systemImage: "leaf.fill", tint: .teal)
                            }
                            Text(branch.lastCommitDate.map(RelativeDate.format) ?? "")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        .tag(branch.name)
                        .opacity(branch.isCheckedOut ? 0.45 : 1)
                    }
                }
                .frame(height: 210)
                .listStyle(.bordered)

                if let selectedLocalBranch,
                   let holder = repository.worktreeHoldingBranch(selectedLocalBranch) {
                    Label(
                        "「\(selectedLocalBranch)」已经在工作树「\(holder.name)」里检出了。git 不允许同一分支同时存在于两个工作树。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var remoteBranchPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("选择一个远端分支")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("抓取远端") {
                    Task { await repository.fetch() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .disabled(!repository.hasRemote)
            }

            if repository.remoteBranches.isEmpty {
                Text(repository.hasRemote ? "没有远端分支，先抓取一次。" : "这个仓库没有配置远端。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                List(selection: $selectedRemoteBranch) {
                    ForEach(repository.remoteBranches) { branch in
                        HStack(spacing: 6) {
                            Image(systemName: "cloud")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Text(branch.name)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                            Spacer()
                            Text(branch.lastCommitDate.map(RelativeDate.format) ?? "")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        .tag(branch.name)
                    }
                }
                .frame(height: 210)
                .listStyle(.bordered)

                Text("会新建一个同名本地分支并跟踪它。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var pathField: some View {
        LabeledContent("位置") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onChange(of: path) { _, _ in pathWasEdited = true }

                    Button("浏览…") {
                        let suggestion = URL(fileURLWithPath: path.isEmpty
                            ? repository.suggestedWorktreePath(for: effectiveBranchName).path
                            : path)
                        if let chosen = FolderPicker.chooseWorktreeLocation(suggesting: suggestion) {
                            path = chosen.path
                            pathWasEdited = true
                        }
                    }
                }

                if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                    Label("这个目录已经存在，git 不会往里创建工作树。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                } else {
                    Text("默认放在仓库的兄弟目录里，这样工作树不会互相出现在彼此的 git status 里。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if isWorking {
                ProgressView().controlSize(.small)
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

    // MARK: - 逻辑

    private func prefill() {
        selectedLocalBranch = repository.branches.first { !$0.isCheckedOut }?.name
        selectedRemoteBranch = repository.remoteBranches.first?.name
        if !effectiveBranchName.isEmpty {
            path = repository.suggestedWorktreePath(for: effectiveBranchName).path
        }
    }

    /// 当前会用到的分支名 —— 路径自动推导和校验都基于它。
    private var effectiveBranchName: String {
        switch source {
        case .newBranch:
            branchName.trimmingCharacters(in: .whitespaces)
        case .localBranch:
            selectedLocalBranch ?? ""
        case .remoteBranch:
            selectedRemoteBranch.map(RefParser.stripRemotePrefix) ?? ""
        }
    }

    private var canCreate: Bool {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !FileManager.default.fileExists(atPath: path) else { return false }

        switch source {
        case .newBranch:
            let name = branchName.trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && !repository.branches.contains { $0.name == name }
        case .localBranch:
            guard let selectedLocalBranch else { return false }
            return repository.worktreeHoldingBranch(selectedLocalBranch) == nil
        case .remoteBranch:
            return selectedRemoteBranch != nil
        }
    }

    private func create() async {
        isWorking = true
        defer { isWorking = false }

        let target = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespaces))
        let gitSource: GitClient.WorktreeSource

        switch source {
        case .newBranch:
            let start = startPoint.trimmingCharacters(in: .whitespaces)
            gitSource = .newBranch(
                name: branchName.trimmingCharacters(in: .whitespaces),
                startPoint: start.isEmpty ? repository.defaultBranch : start
            )
        case .localBranch:
            guard let selectedLocalBranch else { return }
            gitSource = .existingBranch(selectedLocalBranch)
        case .remoteBranch:
            guard let selectedRemoteBranch else { return }
            let localName = RefParser.stripRemotePrefix(selectedRemoteBranch)
            // 本地已经有同名分支就直接检出它，不然 `-b` 会因为「分支已存在」失败。
            if repository.branches.contains(where: { $0.name == localName }) {
                gitSource = .existingBranch(localName)
            } else {
                gitSource = .newBranch(name: localName, startPoint: selectedRemoteBranch)
            }
        }

        guard let worktree = await repository.createWorktree(at: target, source: gitSource) else { return }
        appModel.selection = .worktree(repository: repository.root, worktree: worktree.path)
        dismiss()
    }
}
