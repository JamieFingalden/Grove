import SwiftUI

struct HistoryView: View {
    @Bindable var model: WorktreeModel

    var body: some View {
        // 跟 ChangesView 同理：HSplitView 不会自己撑满父容器，得显式声明。
        HSplitView {
            commitList
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 480, maxHeight: .infinity)

            commitDetail
                .frame(minWidth: 380, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 筛选栏。参照 IDEA 的 git log：搜索框 + 提交人 + 更多条件。
    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                TextField("搜索提交信息", text: $model.logQuery.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    // 每敲一个字符就跑一次 git log 太浪费，等回车再查。
                    .onSubmit { Task { await model.reloadHistory() } }

                if model.isLoadingHistory {
                    ProgressView().controlSize(.mini)
                }

                Menu {
                    Button("全部提交人") { Task { await model.clearAuthors() } }
                    Divider()
                    // 多选。同一个人在本地和远端用不同名字提交是常态
                    // （本地 jamie、GitLab 上中文名），只能选一个的话
                    // 永远看不全自己的提交。
                    ForEach(model.knownAuthors) { author in
                        Toggle(isOn: Binding(
                            get: { model.isAuthorSelected(author) },
                            set: { _ in Task { await model.toggleAuthor(author) } }
                        )) {
                            // 姓名后面带上邮箱：同名不同人、同人不同名都靠它分辨。
                            Text("\(author.display)  ·  \(author.count)")
                        }
                    }
                } label: {
                    Label(model.authorFilterLabel, systemImage: "person")
                        .font(.system(size: 10.5))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    Toggle("包含所有分支", isOn: $model.logQuery.allBranches)
                        .onChange(of: model.logQuery.allBranches) { _, _ in
                            Task { await model.reloadHistory() }
                        }
                    Divider()
                    // 路径筛选放进菜单而不是常驻输入框 —— 它用得远没有
                    // 搜索和提交人频繁，常驻只会把栏挤窄。
                    LabeledContent("限定路径") {
                        TextField("src/app.swift", text: $model.logQuery.path)
                            .frame(width: 180)
                            .onSubmit { Task { await model.reloadHistory() } }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))

            if let summary = model.logQuery.summary {
                HStack(spacing: 6) {
                    // 明确告诉用户「你看到的不是全部」——
                    // 忘了自己开着筛选、然后以为提交丢了，是这类界面最常见的困惑。
                    Text("已筛选：\(summary)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("清除") {
                        Task { await model.clearLogQuery() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var commitList: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            commitListBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commitListBody: some View {
        Group {
            if model.commits.isEmpty {
                ContentUnavailableView {
                    Label(model.logQuery.isActive ? "没有匹配的提交" : "还没有提交",
                          systemImage: model.logQuery.isActive ? "line.3.horizontal.decrease.circle" : "clock")
                } description: {
                    Text(model.logQuery.isActive ? "换个筛选条件试试。" : "这个分支上还没有历史。")
                }
            } else {
                List(selection: Binding(
                    get: { model.selectedCommit },
                    set: { model.selectedCommit = $0 }
                )) {
                    ForEach(Array(model.commits.enumerated()), id: \.element.oid) { index, commit in
                        CommitRow(
                            commit: commit,
                            graphRow: model.showsGraph && index < model.graph.rows.count
                                ? model.graph.rows[index] : nil,
                            laneCount: model.graph.laneCount
                        )
                            .tag(commit.oid)
                            .contextMenu {
                                Button("复制完整 SHA") { SystemActions.copyToPasteboard(commit.oid) }
                                Button("复制短 SHA") { SystemActions.copyToPasteboard(commit.shortOID) }
                                Button("复制标题") { SystemActions.copyToPasteboard(commit.subject) }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var commitDetail: some View {
        if let oid = model.selectedCommit {
            VStack(spacing: 0) {
                if let commit = model.commits.first(where: { $0.oid == oid }) {
                    CommitHeader(commit: commit)
                    Divider()
                }

                if let diff = model.commitDiff {
                    if diff.isEmpty {
                        ContentUnavailableView {
                            Label("没有文件改动", systemImage: "equal.circle")
                        } description: {
                            Text("这可能是一个空提交或合并提交。")
                        }
                    } else {
                        DiffContentView(files: diff)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("选择一个提交", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("从左侧挑一个提交查看它改了什么。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CommitRow: View {
    let commit: CommitSummary
    /// nil 表示这一行不画图（筛选激活时）。
    var graphRow: CommitGraphLayout.Row?
    var laneCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let graphRow {
                CommitGraphCell(row: graphRow, laneCount: laneCount)
            } else {
                // 不画图时仍然给个圆点，行的视觉结构保持一致。
                Image(systemName: commit.isMerge ? "arrow.triangle.merge" : "circle.fill")
                    .font(.system(size: commit.isMerge ? 11 : 6))
                    .foregroundStyle(commit.isMerge ? Color.purple : Color.secondary)
                    .frame(width: 14, height: 14)
            }

            VStack(alignment: .leading, spacing: 2) {
                if !commit.refs.isEmpty { RefBadges(refs: commit.refs) }

                Text(commit.subject)
                    .font(.system(size: 12))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(commit.shortOID)
                        .font(.system(size: 9.5, design: .monospaced))
                    Text(commit.authorName)
                        .lineLimit(1)
                    Text(RelativeDate.format(commit.date))
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CommitHeader: View {
    let commit: CommitSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(commit.subject)
                .font(.system(size: 13.5, weight: .semibold))
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Label(commit.shortOID, systemImage: "number")
                    .font(.system(size: 10.5, design: .monospaced))
                Label(commit.authorName, systemImage: "person")
                Label(commit.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                if commit.isMerge {
                    Label("合并提交", systemImage: "arrow.triangle.merge")
                        .foregroundStyle(.purple)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

enum RelativeDate {
    /// 用 `.relative` FormatStyle 而不是 `RelativeDateTimeFormatter`：
    /// 后者是引用类型、非 Sendable，共享静态实例在 Swift 6 下过不了编译。
    static func format(_ date: Date) -> String {
        date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }
}

// MARK: - 提交图

/// 一行里的图形部分。
///
/// 每行自己画自己那一段，而不是在整个列表上盖一张大画布 ——
/// List 是虚拟化的，只有可见行会被渲染，大画布拿不到全局坐标。
private struct CommitGraphCell: View {
    let row: CommitGraphLayout.Row
    let laneCount: Int

    /// 道间距和圆点半径。行高固定，圆点必须落在垂直正中，
    /// 否则上下两半的线接不上。
    private let laneWidth: CGFloat = 14
    private let dotRadius: CGFloat = 3.5

    private var width: CGFloat {
        CGFloat(max(laneCount, 1)) * laneWidth
    }

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2

            func x(_ lane: Int) -> CGFloat {
                CGFloat(lane) * laneWidth + laneWidth / 2
            }

            // 上半行：从行顶连到中线。
            for link in row.incoming {
                var path = Path()
                path.move(to: CGPoint(x: x(link.from), y: 0))
                if link.from == link.to {
                    path.addLine(to: CGPoint(x: x(link.to), y: midY))
                } else {
                    // 拐弯画成曲线。直角折线在密集的图上会糊成一片网格，
                    // 曲线更容易一眼跟住某一条线。
                    path.addCurve(
                        to: CGPoint(x: x(link.to), y: midY),
                        control1: CGPoint(x: x(link.from), y: midY * 0.6),
                        control2: CGPoint(x: x(link.to), y: midY * 0.4)
                    )
                }
                context.stroke(path, with: .color(Self.color(link.color)), lineWidth: 1.6)
            }

            // 下半行：从中线连到行底。
            for link in row.outgoing {
                var path = Path()
                path.move(to: CGPoint(x: x(link.from), y: midY))
                if link.from == link.to {
                    path.addLine(to: CGPoint(x: x(link.to), y: size.height))
                } else {
                    path.addCurve(
                        to: CGPoint(x: x(link.to), y: size.height),
                        control1: CGPoint(x: x(link.from), y: midY + midY * 0.4),
                        control2: CGPoint(x: x(link.to), y: midY + midY * 0.6)
                    )
                }
                context.stroke(path, with: .color(Self.color(link.color)), lineWidth: 1.6)
            }

            // 提交圆点画在最后，盖住穿过它的线。
            let center = CGPoint(x: x(row.commitLane), y: midY)
            let radius = row.isMerge ? dotRadius + 1 : dotRadius
            let dot = Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
            // 先用背景色描一圈，让圆点从线里「浮」出来。
            context.stroke(dot, with: .color(Color(nsColor: .textBackgroundColor)), lineWidth: 3)
            context.fill(dot, with: .color(Self.color(row.color)))
            // 合并提交画成空心，一眼能跟普通提交区分开。
            if row.isMerge {
                let inner = radius - 1.6
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner,
                                           width: inner * 2, height: inner * 2)),
                    with: .color(Color(nsColor: .textBackgroundColor))
                )
            }
        }
        .frame(width: width)
        // 撑满行高，上下两半才接得上。
        .frame(maxHeight: .infinity)
    }

    /// 道的配色。刻意避开纯红纯绿 —— 那两个颜色在 diff 里已经有固定含义
    /// （新增/删除），在图上再用会造成误读。
    private static let palette: [Color] = [
        .blue, .purple, .orange, .teal, .pink, .indigo, .brown, .cyan
    ]

    static func color(_ index: Int) -> Color {
        palette[abs(index) % palette.count]
    }
}

/// 提交上挂着的分支 / 标签。
private struct RefBadges: View {
    let refs: [CommitRef]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(refs.prefix(4)) { ref in
                HStack(spacing: 2) {
                    Image(systemName: icon(ref.kind))
                        .font(.system(size: 7, weight: .bold))
                    Text(ref.name)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(tint(ref.kind))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(tint(ref.kind).opacity(0.14), in: RoundedRectangle(cornerRadius: 3.5))
            }
            if refs.count > 4 {
                Text("+\(refs.count - 4)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func icon(_ kind: CommitRef.Kind) -> String {
        switch kind {
        case .head: "location.fill"
        case .localBranch: "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag.fill"
        }
    }

    private func tint(_ kind: CommitRef.Kind) -> Color {
        switch kind {
        case .head: .green
        case .localBranch: .blue
        case .remoteBranch: .purple
        case .tag: .orange
        }
    }
}
