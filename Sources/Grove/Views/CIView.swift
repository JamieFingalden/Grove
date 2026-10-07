import SwiftUI

/// CI/CD 的可视化客户端 + 控制台。
///
/// 定位：看状态、看日志、按按钮（重试 / 取消 / 触发）。跑构建的永远是
/// 平台自己的 Runner —— Grove 不解析配置、不执行步骤、不变成 CI。
struct CIView: View {
    let repository: RepositoryModel

    @State private var pipelines: [CIPipeline] = []
    @State private var selectedPipelineID: Int?
    @State private var jobs: [CIJob] = []
    @State private var isLoading = false
    @State private var isLoadingJobs = false
    @State private var jobsPipelineID: Int?
    @State private var jobsRequestID: UUID?
    @State private var failureText: String?
    @State private var jobsFailureText: String?
    @State private var logJob: CIJob?
    @State private var showsRunSheet = false
    @State private var didLoadOnce = false

    private var selectedPipeline: CIPipeline? {
        pipelines.first { $0.id == selectedPipelineID }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if repository.forge == nil {
                    unavailableView
                } else if pipelines.isEmpty && (isLoading || !didLoadOnce) {
                    ProgressView("正在加载流水线…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failureText, pipelines.isEmpty {
                    loadFailureView(failureText)
                } else if pipelines.isEmpty && didLoadOnce {
                    ContentUnavailableView {
                        Label("没有流水线记录", systemImage: "bolt.horizontal")
                    } description: {
                        Text("推送提交或手动触发后，平台的 Runner 会在这里出现记录。")
                    }
                } else {
                    HSplitView {
                        pipelineList
                        pipelineDetail
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            guard !didLoadOnce else { return }
            await reload()
        }
        // 控制台手感：页面开着就定期刷新，不用手点。视图消失自动停。
        .task(id: pollKey) {
            guard didLoadOnce else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(hasRunning ? 10 : 30))
                guard !Task.isCancelled else { return }
                await reload(silent: true)
            }
        }
        .sheet(isPresented: $showsRunSheet) {
            RunPipelineSheet(
                repository: repository,
                suggestedRefs: suggestedRefs,
                onRan: { Task { await reload() } }
            )
        }
        .sheet(item: $logJob) { job in
            JobLogSheet(
                job: job,
                pipelineID: selectedPipelineID ?? 0,
                repository: repository,
                onFinished: { Task { await reload(silent: true) } }
            )
        }
    }

    /// 轮询节奏跟着状态走：有在跑的刷得勤。key 变了（选中变化/有无 running）
    /// 任务会重启，循环从新的节奏开始。
    private var pollKey: String {
        "\(selectedPipelineID ?? -1)-\(hasRunning)"
    }

    /// 手动跑流水线时建议的 ref：最近流水线里出现过的分支，新到旧去重。
    private var suggestedRefs: [String] {
        var seen: Set<String> = []
        return pipelines.compactMap { pipeline in
            guard !pipeline.ref.isEmpty, seen.insert(pipeline.ref).inserted else { return nil }
            return pipeline.ref
        }
    }

    private var hasRunning: Bool {
        pipelines.contains { !$0.status.isFinal }
    }

    // MARK: - 工具条

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("CI/CD")
                .font(.system(size: 12, weight: .semibold))
            Text(repository.root.lastPathComponent)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 12)

            // 手动触发：在平台 Runner 上跑一条新流水线（GitLab 支持，GitHub 没有）。
            if repository.forge?.kind.supportsPipelineRun == true {
                Button {
                    showsRunSheet = true
                } label: {
                    Label("运行流水线…", systemImage: "play.circle")
                }
                .controlSize(.small)
            }

            if isLoading { ProgressView().controlSize(.small) }

            if let failureText, !pipelines.isEmpty {
                Label("刷新失败", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .help(failureText)
            }

            Button {
                Task { await reload() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(isLoading || repository.forge == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label("没有识别出托管平台", systemImage: "bolt.slash")
        } description: {
            Text("CI/CD 状态需要 GitHub 或 GitLab 远端。\(ForgeKind.github.setupHint)")
        }
    }

    private func loadFailureView(_ text: String) -> some View {
        ContentUnavailableView {
            Label("流水线加载失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(text)
        } actions: {
            Button("重试") { Task { await reload() } }
        }
    }

    // MARK: - 列表

    private var pipelineList: some View {
        List(pipelines, selection: $selectedPipelineID) { pipeline in
            PipelineRow(pipeline: pipeline)
                .tag(pipeline.id)
                .contextMenu {
                    if let urlString = pipeline.webURL, let url = URL(string: urlString) {
                        Button("在浏览器打开") { NSWorkspace.shared.open(url) }
                    }
                    if pipeline.status == .running {
                        Button("取消这条流水线") { Task { await cancelPipeline(pipeline) } }
                    }
                    if pipeline.status == .failed || pipeline.status == .canceled {
                        Button("重试失败的任务") { Task { await retryPipeline(pipeline) } }
                    }
                }
        }
        .listStyle(.inset)
        .frame(minWidth: 260, idealWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: pipelines, initial: true) { _, newValue in
            // 刷新后选中的可能没了（列表变短），保住选择或回落到第一条。
            if let id = selectedPipelineID, newValue.contains(where: { $0.id == id }) { return }
            selectedPipelineID = newValue.first?.id
        }
    }

    // MARK: - 详情

    private var pipelineDetail: some View {
        Group {
            if let pipeline = selectedPipeline {
                detailContent(pipeline)
            } else {
                ContentUnavailableView {
                    Label("选择一条流水线", systemImage: "bolt.horizontal")
                } description: {
                    Text("看它的阶段、任务和日志。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        .task(id: selectedPipelineID) {
            await loadJobs()
        }
    }

    private func detailContent(_ pipeline: CIPipeline) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerBlock(pipeline)
                jobsBlock(pipeline)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func headerBlock(_ pipeline: CIPipeline) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusIcon(status: pipeline.status)
                Text(pipeline.status.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pipeline.status.tint)

                Text(pipeline.ref)
                    .font(.system(size: 11.5, design: .monospaced))
                Text("@\(pipeline.shortSHA)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await retryPipeline(pipeline) }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(pipeline.status != .failed && pipeline.status != .canceled)
                .help("重跑这条流水线里失败或被取消的任务")

                if pipeline.status == .running {
                    Button(role: .destructive) {
                        Task { await cancelPipeline(pipeline) }
                    } label: {
                        Label("取消", systemImage: "stop.circle")
                    }
                    .controlSize(.small)
                }

                if let urlString = pipeline.webURL, let url = URL(string: urlString) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("浏览器", systemImage: "safari")
                    }
                    .controlSize(.small)
                    .help("在平台的网页上打开这条流水线")
                }
            }

            if let title = pipeline.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                stat("耗时", CIFormat.duration(pipeline.duration))
                stat("开始", CIFormat.relative(pipeline.createdAt))
                if let trigger = pipeline.trigger, !trigger.isEmpty {
                    stat("触发", trigger)
                }
            }
            .font(.system(size: 10.5))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func jobsBlock(_ pipeline: CIPipeline) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("任务")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if jobsPipelineID != pipeline.id || (isLoadingJobs && jobs.isEmpty) {
                ProgressView("正在加载任务…")
                    .controlSize(.small)
            } else if let jobsFailureText, jobs.isEmpty {
                Label(jobsFailureText, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if jobs.isEmpty {
                Text("没有任务。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                // 按阶段分组（保持服务端给的顺序）。GitHub 没有阶段，统一进「任务」组。
                let grouped = Dictionary(grouping: jobs, by: { $0.stage ?? "" })
                    .sorted { a, b in
                        stageIndex(a.key) < stageIndex(b.key)
                    }
                ForEach(grouped, id: \.key) { stage, stageJobs in
                    VStack(alignment: .leading, spacing: 4) {
                        if !stage.isEmpty {
                            Text(stage)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(stageJobs) { job in
                            JobRow(
                                job: job,
                                supportsJobControl: repository.forge?.kind.supportsJobLevelControl ?? false,
                                supportsJobLog: repository.forge?.kind.supportsJobLog(status: job.status) ?? false
                            ) {
                                logJob = job
                            } onRetry: {
                                Task { await retryJob(job) }
                            } onCancel: {
                                Task { await cancelJob(job) }
                            } onPlay: {
                                Task { await runManualJob(job) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 阶段按首次出现顺序排，别让字典把服务端的阶段顺序打乱。
    private func stageIndex(_ stage: String) -> Int {
        jobs.firstIndex { ($0.stage ?? "") == stage } ?? .max
    }

    // MARK: - 动作

    private func reload(silent: Bool = false) async {
        guard let forge = repository.forge else { return }
        let expectedOrigin = repository.origin
        if !silent { isLoading = true }
        failureText = nil
        defer {
            isLoading = false
        }
        do {
            let loaded = try await forge.pipelines(in: repository.root, limit: 50)
            try Task.checkCancellation()
            guard repository.origin == expectedOrigin else { return }
            pipelines = loaded
            didLoadOnce = true
            // 分支 → 状态的索引顺手刷新：侧边栏工作树行的 CI 小点靠它。
            repository.updatePipelineStatuses(from: pipelines, fromOrigin: expectedOrigin)
            if selectedPipelineID != nil {
                await loadJobs(silent: true)
            }
        } catch is CancellationError {
            // 切换页面或流水线导致的请求取消，不是加载失败。
        } catch {
            guard !Task.isCancelled else { return }
            didLoadOnce = true
            failureText = error.localizedDescription
        }
    }

    private func loadJobs(silent: Bool = false) async {
        guard let forge = repository.forge, let id = selectedPipelineID else {
            jobs = []
            jobsPipelineID = nil
            jobsRequestID = nil
            jobsFailureText = nil
            isLoadingJobs = false
            return
        }
        let requestID = UUID()
        jobsRequestID = requestID
        isLoadingJobs = !silent || jobsPipelineID != id || jobs.isEmpty
        jobsFailureText = nil
        // 旧请求的取消、失败和收尾，都不能覆盖后启动的请求。
        defer {
            if jobsRequestID == requestID { isLoadingJobs = false }
        }
        do {
            let loaded = try await forge.jobs(pipelineID: id, in: repository.root)
            try Task.checkCancellation()
            guard jobsRequestID == requestID, selectedPipelineID == id else { return }
            jobs = loaded
            jobsPipelineID = id
        } catch is CancellationError {
            // SwiftUI 取消旧任务时保持等待态，新的任务会继续加载。
        } catch {
            guard !Task.isCancelled, jobsRequestID == requestID,
                  selectedPipelineID == id else { return }
            if jobsPipelineID != id { jobs = [] }
            jobsPipelineID = id
            jobsFailureText = error.localizedDescription
        }
    }

    private func retryPipeline(_ pipeline: CIPipeline) async {
        await perform("重试流水线") { forge in
            try await forge.retryPipeline(id: pipeline.id, in: repository.root)
        }
    }

    private func cancelPipeline(_ pipeline: CIPipeline) async {
        await perform("取消流水线") { forge in
            try await forge.cancelPipeline(id: pipeline.id, in: repository.root)
        }
    }

    private func retryJob(_ job: CIJob) async {
        await perform("重试任务") { forge in
            try await forge.retryJob(jobID: job.id, in: repository.root)
        }
    }

    private func cancelJob(_ job: CIJob) async {
        await perform("取消任务") { forge in
            try await forge.cancelJob(jobID: job.id, in: repository.root)
        }
    }

    private func runManualJob(_ job: CIJob) async {
        await perform("触发任务") { forge in
            try await forge.runManualJob(jobID: job.id, in: repository.root)
        }
    }

    /// 控制台动作的统一收口：跑完刷新（成功与否都刷，取消半路也可能改了状态）。
    private func perform(_ label: String, _ work: @escaping (ForgeClient) async throws -> Void) async {
        guard let forge = repository.forge else { return }
        do {
            try await work(forge)
        } catch {
            failureText = "\(label)失败：\(error.localizedDescription)"
            return
        }
        await reload(silent: true)
    }
}

// MARK: - 行视图

private struct PipelineRow: View {
    let pipeline: CIPipeline

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(status: pipeline.status)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pipeline.ref.isEmpty ? "（无分支）" : pipeline.ref)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                    Text(pipeline.shortSHA)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let title = pipeline.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(CIFormat.duration(pipeline.duration))
                    .font(.system(size: 10.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Text(CIFormat.relative(pipeline.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .help(pipeline.webURL ?? "")
    }
}

/// 状态图标。运行中的用真转圈，控制台感更强。
private struct StatusIcon: View {
    let status: CIStatus

    var body: some View {
        Group {
            if status == .running {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: status.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(status.tint)
            }
        }
        .frame(width: 16)
    }
}

private struct JobRow: View {
    let job: CIJob
    let supportsJobControl: Bool
    let supportsJobLog: Bool
    let onLog: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StatusIcon(status: job.status)

            Text(job.name)
                .font(.system(size: 11.5))
                .lineLimit(1)

            if job.allowFailure {
                Text("允许失败")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            Text(CIFormat.duration(job.duration))
                .font(.system(size: 10.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            if let queued = job.queuedDuration, queued >= 1 {
                Text("排队 \(CIFormat.duration(queued))")
                    .font(.system(size: 10.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .help("进 runner 之前等了这么久 —— 一直很长说明 runner 不够用")
            }

            Spacer(minLength: 6)

            // 手动任务是 GitHub 没有的概念，按钮只在支持单任务控制的平台出现。
            if supportsJobControl && job.status == .manual {
                Button(action: onPlay) {
                    Label("触发", systemImage: "play.fill")
                }
                .controlSize(.small)
            }

            Menu {
                if supportsJobLog {
                    Button("查看日志", action: onLog)
                }
                if supportsJobControl && (job.status == .failed || job.status == .canceled) {
                    Button("重试这个任务", action: onRetry)
                }
                if supportsJobControl && job.status == .running {
                    Button("取消这个任务", action: onCancel)
                }
                if let urlString = job.webURL, let url = URL(string: urlString) {
                    Button("在浏览器打开") { NSWorkspace.shared.open(url) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 24, height: 20)

            if supportsJobLog {
                Button(action: onLog) {
                    Label("日志", systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - 日志控制台

private struct JobLogSheet: View {
    let job: CIJob
    let pipelineID: Int
    let repository: RepositoryModel
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.excerptJump) private var excerptJump
    @State private var logText: String = ""
    @State private var isLoading = false
    @State private var failureText: String?
    @State private var filterText: String = ""
    @State private var showsFilter = false

    private var allLines: [String] {
        logText.components(separatedBy: .newlines)
    }

    /// 超长的日志退回整块渲染：逐行建视图太重，跳转功能跟着让位。
    private var rendersPerLine: Bool {
        allLines.count <= 2500
    }

    private var displayPairs: [(index: Int, line: String)] {
        if filterText.isEmpty {
            return allLines.enumerated().map { (index: $0.offset, line: $0.element) }
        }
        return allLines.enumerated()
            .filter { $0.element.localizedCaseInsensitiveContains(filterText) }
            .map { (index: $0.offset, line: $0.element) }
    }

    /// 失败任务的「疑似病因」：日志里第一处像错误的地方 + 后文几行。
    private var failureExcerpts: [CILog.FailureExcerpt] {
        guard job.status == .failed, !allLines.isEmpty else { return [] }
        return CILog.failureExcerpts(lines: allLines)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showsFilter {
                filterBar
                Divider()
            }
            ScrollViewReader { proxy in
                let jump = ExcerptJump { lineNumber in
                    guard rendersPerLine else { return }
                    withAnimation(.snappy(duration: 0.2)) {
                        proxy.scrollTo(lineNumber - 1, anchor: .top)
                    }
                }
                if !failureExcerpts.isEmpty {
                    summaryPanel
                        .environment(\.excerptJump, jump)
                    Divider()
                }
                consoleBody(proxy: proxy)
            }
        }
        .frame(minWidth: 680, idealWidth: 860, minHeight: 460, idealHeight: 620)
        .task {
            await load()
            // 跑着的时候 5 秒追一次日志，控制台手感；终态就静止。
            while !Task.isCancelled && !job.status.isFinal {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await load(autoscroll: true)
            }
            onFinished()
        }
    }

    /// 摘要区下面的主体：等待态 / 错误态 / 空态 / 日志正文。
    /// 等待态优先于错误态 —— 正在加载时显示什么由这一次加载决定，
    /// 上一次的报错不该抢在转圈前面。
    @ViewBuilder
    private func consoleBody(proxy: ScrollViewProxy) -> some View {
        Group {
            if isLoading && logText.isEmpty {
                ProgressView("正在读取日志…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failureText, logText.isEmpty {
                    ContentUnavailableView {
                        Label("日志加载失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failureText)
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                } else if displayPairs.isEmpty {
                    ContentUnavailableView {
                        Label(filterText.isEmpty ? "还没有日志" : "没有匹配的行", systemImage: "doc")
                    } description: {
                        Text(filterText.isEmpty
                             ? "任务还没产生输出，或者平台没保留这份日志。"
                             : "换个关键词试试。")
                    }
                } else {
                    logConsole(proxy: proxy)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Divider()
        bottomBar
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusIcon(status: job.status)
            Text(job.name)
                .font(.system(size: 12.5, weight: .semibold))
            Text(job.status.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(job.status.tint)
            Text(CIFormat.duration(job.duration))
                .font(.system(size: 10.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            if let queued = job.queuedDuration, queued >= 1 {
                Text("排队 \(CIFormat.duration(queued))")
                    .font(.system(size: 10.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("过滤（只显示匹配的行）", text: $filterText)
                .font(.system(size: 11.5, design: .monospaced))
                .textFieldStyle(.plain)
            if !filterText.isEmpty {
                Text("\(displayPairs.count) 行")
                    .font(.system(size: 10.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// 疑似错误摘要：不用翻几千行日志找第一处报错。
    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("疑似错误（\(failureExcerpts.count) 处）", systemImage: "stethoscope")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.red)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(failureExcerpts, id: \.lineNumber) { excerpt in
                        excerptCard(excerpt)
                    }
                }
            }
            .frame(maxHeight: 118)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func excerptCard(_ excerpt: CILog.FailureExcerpt) -> some View {
        Button {
            // 摘要点一下跳到日志原文那行（跳转通道由外层注入）。
            excerptJump.jump(excerpt.lineNumber)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("第 \(excerpt.lineNumber) 行")
                        .font(.system(size: 9.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Text(excerpt.snippet)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(rendersPerLine ? "点击跳到日志原文" : "日志太长，已退回整块渲染，跳转不可用")
    }

    private func logConsole(proxy: ScrollViewProxy) -> some View {
        ScrollView {
                if rendersPerLine || !filterText.isEmpty {
                    // 逐行渲染（带行号）：摘要跳转和过滤都要行身份。
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayPairs, id: \.index) { pair in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(pair.index + 1)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundStyle(.quaternary)
                                    .frame(width: 40, alignment: .trailing)
                                Text(pair.line.isEmpty ? " " : pair.line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(pair.index)
                        }
                    }
                    .padding(10)
                } else {
                    // 超长日志：一整块文本，滚动性能优先。
                    Text(logText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("log-bottom")
                }
            }
        .onChange(of: logText) { _, _ in
            // 只有还在跑的时候自动追底；读历史日志别把人拽来拽去。
            guard !job.status.isFinal else { return }
            withAnimation(.snappy(duration: 0.15)) {
                if let lastID = displayPairs.last?.index {
                    proxy.scrollTo(lastID, anchor: .bottom)
                } else {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text("\(logText.components(separatedBy: .newlines).count) 行")
                .font(.system(size: 10.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.15)) {
                    showsFilter.toggle()
                    if !showsFilter { filterText = "" }
                }
            } label: {
                Label("过滤", systemImage: "line.3.horizontal.decrease.circle")
            }
            .controlSize(.small)
            Button("刷新") { Task { await load() } }
                .controlSize(.small)
            Button("完成") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func load(autoscroll: Bool = false) async {
        guard let forge = repository.forge else { return }
        isLoading = true
        // 重新加载时清掉上次的报错：加载期间该显示等待态而不是旧错误 ——
        // 日志面板会边跑边轮询，一次网络抖动不该把后面的每次加载都染成错误页。
        failureText = nil
        defer { isLoading = false }
        do {
            let raw = try await forge.jobLog(jobID: job.id, in: repository.root)
            logText = CILog.plain(raw)
        } catch is CancellationError {
            // 面板关掉 / 切走时请求被取消 —— 不是加载失败，别显示错误。
        } catch {
            // localizedDescription 有时只有一句笼统的「未能完成操作」——
            // 把错误的完整形态（类型 + 错误域 + 错误码）一并展示，
            // 否则没法区分是命令失败、启动失败还是系统层错误。
            let description = error.localizedDescription
            let details = String(reflecting: error)
            failureText = details == description ? description : "\(description)\n\n\(details)"
        }
    }
}

/// 摘要卡 → 日志原文的跳转通道。环境注入，免掉把 proxy 到处传。
fileprivate struct ExcerptJump: Sendable {
    var jump: @MainActor @Sendable (_ lineNumber: Int) -> Void
}

private struct ExcerptJumpKey: EnvironmentKey {
    static let defaultValue = ExcerptJump { _ in }
}

extension EnvironmentValues {
    fileprivate var excerptJump: ExcerptJump {
        get { self[ExcerptJumpKey.self] }
        set { self[ExcerptJumpKey.self] = newValue }
    }
}

// MARK: - 手动跑流水线

private struct RunPipelineSheet: View {
    let repository: RepositoryModel
    let suggestedRefs: [String]
    let onRan: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var refText: String = ""
    @State private var isRunning = false
    @State private var failureText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("运行流水线")
                .font(.system(size: 13, weight: .semibold))

            Text("在指定分支或 Tag 上跑一条新流水线。构建仍然由平台自己的 Runner 执行，Grove 只是按一下。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("分支或 Tag（如 main）", text: $refText)
                    .font(.system(size: 12, design: .monospaced))
            }
            .textFieldStyle(.roundedBorder)

            if !suggestedRefs.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("最近跑过的")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    FlowChips(refs: Array(suggestedRefs.prefix(8))) { ref in
                        refText = ref
                    }
                }
            }

            if let failureText {
                Label(failureText, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("跑") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(refText.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
                if isRunning {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func run() async {
        guard let forge = repository.forge else { return }
        let ref = refText.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            try await forge.runPipeline(ref: ref, in: repository.root)
            onRan()
            dismiss()
        } catch {
            failureText = error.localizedDescription
        }
    }
}

/// 建议 ref 的胶囊条：单行横排，放不下就横向滚动 —— 换行流式布局的
/// 对齐技巧在 SwiftUI 里又绕又有并发警告，不值得为八个胶囊上那种手段。
private struct FlowChips: View {
    let refs: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(refs, id: \.self) { ref in
                    Button {
                        onSelect(ref)
                    } label: {
                        Text(ref)
                            .font(.system(size: 10.5, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }
}
