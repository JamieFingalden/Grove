# Grove 3.0 交付说明

本次在原有 Git 客户端上增加 Daily、全局 Workspace 和原生 Settings 扩展。Repository / Worktree、Diff、Changes、History、PR/MR、CI/CD、远程环境及 AI Review 继续使用原实现。应用版本元数据为 3.0.0（build 9）。未创建提交、标签或发布。

## 1. 新增模块与目录

```text
Sources/Grove/
  Overview/
    DailyActivityService.swift          Git 读取、日期口径、身份与提交去重
    DailyViewModel.swift                七天活动、缓存、异步刷新及错误隔离
    WorkspaceItem.swift                 跨平台事项身份、Inbox 与筛选规则
    WorkspaceAggregationService.swift   现有平台服务聚合、限流与缓存
    OverviewCache.swift                 异步业务快照读写
    OverviewRouting.swift               跳转原项目 PR、CI 和提交历史
  Stores/
    AppNavigationState.swift            顶层导航、访问过的页面与非敏感偏好
  Views/
    OverviewViews.swift                 Daily / Workspace 与共用行、状态、标题
    OverviewPreferences.swift           原 Settings 表单的新增设置区
Tests/GroveTests/
  OverviewTests.swift                   新模块的 Git、平台、导航与渲染验证
```

UI 使用现有 GroveStyle 字体、间距、动态颜色及 SF Symbols。未引入依赖。

## 2. 导航与状态

Sidebar 顶部新增 OVERVIEW / Daily / Workspace，原仓库树和远程管理区保留。全局页面与原有 `AppModel.Selection` 分开；访问 Daily / Workspace 不清空选中的 Repository / Worktree。

RootView 以稳定 Selection 为身份保留访问过的项目页，远端 origin 改变时仍保留原有重建项目页的行为；路由额外校验远端项目身份。用可见性、命中测试和辅助功能可见性切换内容。已访问的 Changes / History 和 PR / CI 分栏也保持挂载，因此局部筛选、选中文件、Diff 模式、滚动位置和编辑状态不因切换而销毁。WorktreeModel 的原有缓存继续保存 Commit Message。隐藏 CI 分栏停止轮询。

启动时先恢复可用仓库，再恢复上次 Repository / Worktree。用户在启动过程中主动导航后，不再覆盖其选择。启动页支持上次页面（默认）、Daily、Workspace、上次 Repository。Repository 无法恢复时保留可用的默认仓库或空状态。

全局 PR/MR 跳转原 PullRequestDetailView；Pipeline 跳转原 CIView 并定位 ID。Daily 用 Commit Hash 作为 History revision，清除目标历史的查询条件后选择该提交，复用 History / Diff。点击全局记录时校验当前远端或 Git 公共目录身份，避免旧缓存指向已更换的项目。返回全局页面保留原筛选、日期与列表状态。

页面保留范围是当前窗口的运行期；本次不把完整编辑草稿和所有局部界面状态跨进程持久化。

## 3. Workspace 来源与 Inbox

通过现有 `ForgeClient` 调用 `GitHubClient`（gh）和 `GitLabClient`（glab），不新增第二套 API 客户端。使用现有 PullRequest、StatusCheck、CIPipeline、CIStatus 规范化数据。增加当前主机登录账号查询及评审人字段映射。

Inbox 只收录：

- 平台明确指定当前登录账号为评审人的非草稿开放 PR/MR；已知本人已批准时排除。
- 当前账号创建的开放 PR/MR 存在明确 Git 冲突。
- 当前账号创建的开放 PR/MR 有失败检查或要求修改的 Review。

普通开放请求不自动成为待办。团队评审请求不推断成员身份。Pipeline 列表没有可靠的个人归属字段，普通失败流水线只展示在 All Activity；我的 PR 的失败检查可进入 Inbox。AI Review 结果不参与 Git 可合并性或 CI 状态判断。

事项 ID 使用 Provider + 主机（含端口）+ 远端项目路径 + PR/MR 编号或 Pipeline ID。GitHub 路径按大小写不敏感处理，GitLab 保留路径大小写。多个 Worktree 或同远端项目的多个本地副本不重复展示；同名不同项目不合并。

All Activity 明确标记为当前状态快照，包括最多 1000 条开放请求、平台列表最近最多 50 条请求以及 50 条流水线，按可靠的更新时间排序；缺少 Pipeline 更新时间时标注创建时间。历史窗口受现有平台列表能力限制，不生成虚构事件。

GitLab 只为本人创建或指定给本人的开放请求补充详情，每项目最多 50 条；超过上限显示提示，其余仅使用列表明确提供的字段。

首次加载、手动刷新及可见全局页面每 5 分钟自动刷新均可用，自动刷新可关闭。不同平台轮流安排请求，同时最多处理三个项目。PR/MR 和 CI 失败分别隔离，成功部分正常展示；失败部分保留缓存并提示。磁盘缓存中的 Inbox 归属需要重新确认当前账号与缓存账号一致。

额外修正了原共享 GitLab 冲突映射：`cannot_be_merged` 可能源自审批或 CI 阻塞，不能直接等同于 Git 冲突。只有 `has_conflicts=true` 或明确的 `detailed_merge_status=conflict` 才标记冲突。

字段依据：[GitHub CLI PR JSON 字段](https://cli.github.com/manual/gh_pr_list)、[GitLab Merge Requests API](https://docs.gitlab.com/api/merge_requests/)。

## 4. Daily 统计口径

- 仅扫描 Grove 管理的本地 Git 仓库。
- 使用用户明确确认的多个 Author Email 匹配 `%ae`；不以姓名或 Committer Email 猜测作者。
- 活动日期使用 `%ct`（Committer Date），按用户本地 Calendar / 时区分组。
- 扫描所有引用及 Worktree HEAD，查询最近七个本地自然日；使用 `--since-as-filter` 避免遇到旧日期父提交时提前停止遍历。
- 仓库身份来自实际 `git rev-parse --git-common-dir` 的归一化路径；同一公共目录 + Hash 只统计一次，独立仓库中的相同 Hash 保留为不同记录。
- 仅在本地分支顶端确实指向某提交时显示分支信息，不推断提交所属分支。
- Push 相关信息基于本地远端引用。远端引用包含提交时标注“本地远端引用已包含”，其他情况标注“推送状态未确认”。
- 对所有本地 Branch 读取既有 upstream / track 数据。无上游、上游引用缺失与领先上游明确区分；零 Ahead 只表示本地引用无领先，不宣称远端实时同步。

今日 Commit 数、活跃仓库数、存在 Ahead 的仓库数、七天日期切换、时间线与活跃项目摘要均来自真实读取结果。Git 命令和解析在异步服务中运行，最多同时扫描三个仓库；业务快照磁盘读写离开主线程。单仓库失败保留缓存并提示。

## 5. Settings 与存储

继续使用原生 SwiftUI Settings Scene / PreferencesView，系统菜单支持 Command + ,。原 AI 表单、AI Provider / Model / Review 配置、API Key 安全存储和已有工具、工作树设置保留。

新增 General 启动页及自动刷新、Git / Daily Email 多身份及 Git 配置候选确认、Appearance 系统/浅色/深色、Integrations 当前 CLI 状态及重新检测、Remote 复用现有服务器编辑和添加表单。

非敏感偏好继续存入现有 UserDefaults：`grove.navigation.*`、`grove.daily.authorEmails`、`grove.overview.autoRefresh`、`grove.appearance`。Git 候选邮箱只作为确认入口，不自动启用，也不改写 Git 配置。

业务缓存位于用户 Caches/Grove/Overview；不存 Token 或 API Key。GitHub / GitLab 认证仍由 CLI 管理，AI Key 继续使用原安全存储。

## 6. 修改文件清单

新增文件见第 1 节，另新增本说明 `docs/Grove3-implementation.md`。

已修改：

```text
Sources/Grove/App/GroveApp.swift
Sources/Grove/Forge/Forge.swift
Sources/Grove/GitHub/GitHubClient.swift
Sources/Grove/GitLab/GitLabClient.swift
Sources/Grove/GitLab/GitLabMergeRequest.swift
Sources/Grove/Models/CIPipeline.swift
Sources/Grove/Models/PullRequest.swift
Sources/Grove/Stores/AppModel.swift
Sources/Grove/Stores/RepositoryModel.swift
Sources/Grove/Views/CIView.swift
Sources/Grove/Views/ProjectHomeView.swift
Sources/Grove/Views/PullRequestListView.swift
Sources/Grove/Views/RootView.swift
Sources/Grove/Views/Sheets.swift
Sources/Grove/Views/SidebarView.swift
Sources/Grove/Views/WorktreeDetailView.swift
Support/Info.plist
Tests/GroveTests/GitLabTests.swift
```

## 7. 实际验证

验证环境：macOS 27.0.1 / Apple Swift 6.4 / Apple Git 2.54.0。最低部署目标保持 macOS 14。

- 各实施阶段执行 `swift build`，最终 Debug 构建通过。
- 相关回归命令：`swift test --filter 'OverviewTests|GitLabTests|CITests|HistorySelectionTests|PullRequestLoadStateTests|AppModelProjectTests|StatusParserTests|DiffParserTests|WorktreeParserTests|ForgeSafetyTests|GitRemoteTests|PushTrackingTests|GitFileOperationTests|ConflictResolutionTests'`。
- 102 项中 101 项通过，1 项可选渲染测试默认跳过；零失败。
- 此后新增筛选、七天统计、游离 Worktree 和跨远端路由断言，重跑 OverviewTests 通过；最终相关的 32 项中 31 项通过，1 项可选渲染跳过，零失败。
- `GROVE_RENDER=1 swift test --filter OverviewTests/testRenderOverviewPages` 单独通过，生成 Daily、Workspace、Settings 共六张浅色/深色预览，目录 `.build/overview-preview/`。
- 截屏权限不可用，渲染使用 NSHostingView 离屏回退；已检查布局和动态颜色，未把它当作完整真实窗口交互验证。
- Release 通过原有 `scripts/build.sh` 生成 `dist/Grove.app`，使用现有 Apple Development 身份签名。`codesign --verify --deep --strict`、Info.plist 检查及应用 `--help` 运行检查通过。

新增验证覆盖真实 Git 的 Author / Committer 日期差异、邮箱过滤、多 Worktree 公共目录、重复提交、独立仓库相同 Hash、空仓库、Ahead / 无上游、七天分组；通过测试专用 CLI 响应覆盖 GitHub + GitLab、PR 评审归属、冲突与检查分离、认证/请求失败、部分缓存、跨页面路由和启动偏好恢复。正式页面不使用这些测试数据。

编码检查：修改与新增文本按 UTF-8 无 BOM 检查；diff 中检查替换字符、连续问号和空白错误；检查通过，无乱码或 BOM，`git diff --check` 通过。

## 8. 尚未完成的验证与边界

- 尚未使用真实 GitHub / GitLab 账号完成端到端人工验收。平台错误隔离与数据映射通过测试专用 CLI 验证，不能代替真实服务集成验收。
- 完整原生窗口中的鼠标/键盘切换、滚动恢复和长时间使用尚未人工逐项验收；状态生命周期按保留视图树实现，模型草稿与查询恢复已有测试。
- 未在 macOS 14 真机运行；构建仍以 macOS 14 为最低目标。Daily 的 `--since-as-filter` 需要 Git 2.36 或更新版本，旧工具的读取失败会显示错误。
- Workspace 复用现有本地目录驱动的 Forge 集成。远程 SSH 仓库保留原 Git 功能，但现有实现未接入 Forge，因此本次不聚合纯远程项目的 PR/CI；Daily 按需求仅扫描本地仓库。
- 团队评审成员、普通 Pipeline 的个人归属以及平台列表窗口之外的完整历史事件缺少可靠数据，V1 不推断或伪造。
- 本次不新增 Push、Merge、自动修复或 AI 自动处理动作，也不修改原有 AI Review 算法。
