# Grove

[English](README.md)

Grove 是一个原生 macOS 应用，把 git 工作树（worktree）和代码评审请求（GitHub 的 Pull Request、GitLab 的 Merge Request）放在同一个界面里管理。

工作树能让你同时检出多个分支到不同目录、共用一份克隆。功能写到一半来了个 review 要看，这正是它该上场的时候 —— 但命令行下要自己记一堆路径，而其他 git GUI 基本都把工作树当边角功能。Grove 反过来，侧边栏按项目组织工作树：每个工作树显示它在哪个分支、有多少未提交改动、对应的评审请求是什么状态。

它围绕的工作流是：看到一个 PR，一键检出成新工作树，不打断手头的活就能review 或者修，合并之后连工作树带分支一起删掉。

## 快速开始

从 [Releases](https://github.com/JamieFingalden/Grove/releases) 下载 DMG，或通过项目自有的 Homebrew tap 安装：

```sh
brew tap JamieFingalden/grove https://github.com/JamieFingalden/Grove.git
brew install --cask JamieFingalden/grove/grove
```

发布的安装包需要 **Apple Silicon 和 macOS 14+**，未经过 Apple 公证。首次启动被 macOS 拦截时，请按[首次打开说明](docs/getting-started.zh-CN.md#首次打开)操作。

跟随[快速入门](docs/getting-started.zh-CN.md)完成打开仓库、创建工作树和检出 PR/MR。tap 的发布和更新方式见 [Homebrew 维护说明](docs/release/homebrew.md)。

## 系统要求

- macOS 14 或更高版本
- `git` —— 装了 Xcode 命令行工具就有
- `gh`（[GitHub CLI](https://cli.github.com)）—— 可选，GitHub 的 PR 功能需要
- `glab`（[GitLab CLI](https://gitlab.com/gitlab-org/cli)）—— 可选，GitLab 的 MR 功能需要

AI 生成功能是可选的。在 Grove 设置中可选择已登录的 Codex CLI，或填写 OpenAI Chat Completions 兼容 API 的地址、模型名和密钥。后者可接入 OpenAI 或其他兼容服务，不需要开通 ChatGPT 订阅；API 密钥只保存在 macOS 钥匙串中。

GitHub 和 GitLab 的凭据由各自的 CLI 管理，Grove 不另行保存副本。通过 `gh auth login` 或 `glab auth login` 认证一次即可。缺少某个平台的 CLI 时，该平台的评审和 CI/CD 功能不可用，本地 Git 功能仍可正常使用。

自建 / 内网 GitLab（含非标准端口和 http）：

```sh
glab auth login --hostname 10.0.0.1 --api-host 10.0.0.1:8929 --api-protocol http
```

Grove 只按 `origin` 判断仓库属于哪个平台。一个仓库同时挂着内网 GitLab 的 origin 和 GitHub 备份 remote 时，它不会去显示那个备份仓库的 PR —— 那会把另一个项目的数据显示到这里。

## 构建

```sh
zsh scripts/build.sh
```

产物是 `dist/Grove.app`。脚本会生成图标、编译 release 版本、组装 bundle 并签名（有 Apple Development 证书就用它，没有就临时签名）。

### GitHub Actions

[CI](.github/workflows/ci.yml) 在推送到 `main`、推送版本标签（`v*`）、提交 Pull Request 或手动触发时运行。它使用 macOS 15 和 Xcode 26.3，运行 `swift test`、构建并验证应用，再打包 Apple Silicon（`arm64`）DMG。安装包及其 SHA-256 校验文件可从该次运行的构建产物中下载，保留 14 天。访问真实平台 API 的测试和界面渲染测试仍需显式启用。

发布版本前，先更新 `Support/Info.plist` 中的 `CFBundleShortVersionString`（三个数字组成的版本号），并递增 `CFBundleVersion`，提交并推送修改，等待 `main` 的 CI 通过。然后在包含版本修改的提交上创建并推送匹配的标签，例如：

```sh
git tag -a v0.2.1 -m "Grove v0.2.1"
git push origin v0.2.1
```

标签必须与 plist 版本完全一致（`v<版本号>`）。arm64 构建通过后，CI 才会创建 GitHub Release，附带自动生成的版本说明、DMG 和校验文件。已有 Release 不会被覆盖，发布修复时应使用新版本号。手动运行只生成构建产物，即使选择标签也不会发布 Release。

无需配置自定义密钥，发布使用内置的 `GITHUB_TOKEN`。CI 安装包采用临时签名，未经过 Apple 公证，macOS Gatekeeper 可能要求你显式批准后才能打开。

CI 还会根据 DMG 的实际校验值生成 `grove.rb`，随 Release 一起发布。发布后用该文件更新 `Casks/grove.rb`，tap 才会提供新版；步骤见 [Homebrew 维护说明](docs/release/homebrew.md)。

## 功能

**项目导航。** 每个项目都有主页，评审请求与 CI/CD 分别放在不同分栏中，侧边栏的工作树列表可折叠。同一项目的本地与 SSH 远程副本按 `origin` 分组，每个工作树标明所在位置。评审请求图标区分开放、草稿、已合并和已关闭状态，分支关联的历史请求也会显示。

**工作树。** 可以从新建分支、已有本地分支或远端分支创建。Grove 默认把工作树放在仓库的兄弟目录里（`<仓库>-worktrees/<分支名>`），这样工作树之间不会互相出现在对方的 `git status` 里。支持锁定、解锁、清理失效项、删除 —— 删除前会检查有没有未提交的改动，也可以选择同时删掉分支。

**推送。** 只有一个远端时是一键推送。配了多个远端（比如内网 GitLab 做主、GitHub 做备份）时，推送按钮变成分离式：主区域按分支自己的上游推（跟终端里敲 `git push` 一致），右边箭头展开选别的远端，每一项都带上目标地址 —— 两个远端名字相近时只看名字分不清推去了哪。推到非上游的远端**不会**悄悄改掉分支的跟踪目标。

**标签。** 从工具栏、历史提交的右键菜单或提交详情头部创建标签：默认建附注标签（带说明），也可以只建轻量指针。弹窗会预填下一个版本号，也可以选择「创建后推送」。AI 可根据所选提交的已提交改动生成附注说明，排除疑似凭据文件内容和未提交改动。提交上已有的标签同样右键就能推送（多远端时选推去哪）或删除本地副本 —— 删除只动本地，远端上的标签要显式推送删除，Grove 不偷偷做。

**变更。** 按工作树显示文件列表，分「已暂存」和「未暂存」两栏；diff 查看器能正确处理重命名、二进制文件、纯权限变更，以及合并冲突时的 combined diff。支持暂存、取消暂存、丢弃、提交。切换工作树不会丢失写了一半的提交信息。

**分行提交。** 改了两行只想提交其中一行时，在 diff 里逐行勾选（或点 hunk 头整块勾选），然后暂存 / 取消暂存 / 丢弃选中的行。实现是从 git 自己的 diff 里裁出一个只含选中行的补丁，喂给 `git apply` —— 规则见 `Sources/Grove/Git/PatchBuilder.swift`，正向和反向的基准侧是相反的，那里写清楚了为什么。

**变基。** 从工作树的「⋯」菜单进入，选一个目标分支（远端或本地），跑 `git rebase --autostash <目标>`。开始前会先告诉你**将要发生什么**：重放几个提交、这些提交的 SHA 都会变、分支已推送的话之后要强制推。中途遇到冲突会停下，顶部出现「继续 / 跳过 / 中止」——​没有这一条的话，一遇冲突就只能回终端。

**冲突解决。** 合并、变基、拣选、回退停在冲突上时，顶部横幅给出「继续 / 跳过 / 中止」，变更列表最上面多出一个「冲突」区。点开冲突文件，右侧是按 `<<<<<<<` 标记切好的块：每块可以「采用当前更改 / 采用传入的更改 / 保留双方」，选一块写一次盘，可以撤销；全部选完后「标记为已解决」（就是 `git add`）。一侧删除、二进制这类没有标记可言的文件，只有「保留 / 删除」两个按钮。面板顶部写明「当前」和「传入」各是哪个分支 —— 变基时 git 的 ours/theirs 是反的（HEAD 停在变基目标上，「当前」反而是别人的分支），不写出来必然选反。标记为已解决前会数一遍文件里还剩多少标记；写盘前会比对磁盘内容，不会盖掉你同时在外部编辑器里做的改动。

**历史筛选。** 按提交信息搜、按提交人筛（下拉框按提交频次排序）、限定路径、切换「只看当前分支 / 所有分支」。搜索词按字面量匹配而不是正则 —— 搜 `foo(bar)` 就是搜这个字符串本身。开着筛选时栏下会显示筛掉了什么，免得以为提交丢了。长分支名不会挤压搜索框，超长提交正文可以折叠或独立滚动，不会挤走文件列表和 diff。

**评审请求（PR / MR）。** 浏览请求，查看 CI 结果、评审状态、合并冲突和已缓存的 AI 审查结论；读带代码上下文的讨论、跳转到对应 diff 行、直接从代码行发起评论、回复、提修改意见、批准和合并。讨论支持按全部、待解决和已解决筛选，已解决讨论默认折叠，过期意见有明确标记。详情页将讨论正文与状态、讨论导航分区展示，窄窗口下导航可折叠。界面文案按平台走 —— GitLab 下显示「合并请求」和 `!123`。可以把 PR 检出成新工作树 —— 同仓库的 PR 会建立跟踪分支，改完能直接推回去；从 fork 提来的 PR 走 `pull/<编号>/head` 抓成本地 `pr-<编号>` 分支。也可以从当前工作树提评审请求（Grove 会先帮你把分支推上去），以及用压缩合并 / 合并提交 / 变基三种方式合并。平台和当前权限允许时，可直接解决或重新打开讨论。

**AI Review。** 按项目配置评审提示词和审查范围，也可在单次审查时临时调整。较大的 diff 按文件相关性分组审查后汇总结论，遗漏或截断的内容会明确提示，疑似凭据文件内容会从审查提示词中排除。风险意见可以发布到 GitHub / GitLab 讨论中，并匹配到有效的 diff 行——但发布永远不会静默进行：手动审查不会自动发布（在审查页逐条发布），按项目的自动审查也只生成结论和通知；把风险意见发到讨论区是独立的按项目开关，默认关闭。重审结合历史意见、回复和解决状态，核实问题是否仍然存在。配置并启用 AI 后，可按项目控制自动审查：Grove 运行期间每分钟检查新 PR / MR 并自动审查，已有请求收到新推送时只发通知，由你决定是否重审。设置中可查看最近三天的 AI 调用记录，包括模型、触发方式、耗时、结果和服务返回的 token 用量，日志不保存密钥、提示词或源码正文。

**CI/CD。** 从项目主页查看流水线、任务和日志。推送后 Grove 自动跟踪流水线，并通过系统通知反馈结果。

**SSH 远程仓库。** 添加远程服务器后，可以直接管理其 Git 项目，包括提交、同步、工作树、冲突处理和文件编辑。远程工作树与同一项目的本地副本一起显示。

**关联。** 每个工作树显示它分支对应的 PR，每个 PR 显示它是否已经被检出。这是整个应用的重点。

## 自查

```sh
dist/Grove.app/Contents/MacOS/Grove --doctor [路径]
```

会打印 `git` 和 `gh` 的位置、传给子进程的 PATH、`gh` 有没有登录，然后是仓库的工作树列表、各自状态、关联的 PR，以及开放的 PR 列表。绝大多数「Grove 打不开我的仓库」「PR 那块是空的」，看一眼这个输出就知道原因了。

## 一些设计取舍

**调用 `git` 命令行而不是链接 libgit2。** 工作树是这个应用的主线功能，而 libgit2 对它的支持一直不完整 —— 光是 `git worktree add` 的那些语义就得自己重实现一遍。走命令行的好处是行为跟用户在终端里看到的完全一致，而且 porcelain 输出格式有官方的向后兼容承诺。

**评审通过各自的 CLI（`gh` / `glab`）访问平台，而不自行实现 API 认证。** 自行认证就得自己做 OAuth device flow、把 token 存进 Keychain、处理过期刷新 —— 把 CLI 已经做好的事情重做一遍，自建实例的认证细节尤其琐碎。Grove 不另行保存 GitHub 或 GitLab 的凭据。两个平台的差异（Pull Request vs Merge Request、`#` vs `!`、审批模型、流水线 vs checks）全部收敛在 `ForgeClient` 的两个实现里，界面只看到一套模型。

**在 GUI 里跑命令行才是真正出 bug 的地方。** `Sources/Grove/Git/ProcessRunner.swift` 里记录了四个这个应用真的踩到或差点踩到的坑：大输出时的管道死锁、git 卡在没人能回答的凭据提示上、命令永不返回、以及后台孙进程（`git gc --auto`）在 git 早已退出后还握着 stdout 管道不放。`Sources/Grove/Git/ToolLocator.swift` 记录了第五个：从 Finder 启动的 app 继承的 PATH 里没有 Homebrew。

## 测试

```sh
swift test
```

各个解析器（worktree 列表、status porcelain v2、for-each-ref、log、统一 diff、`gh` 的 JSON）都是纯函数，有单元测试覆盖。`ProcessRunner` 的测试会真的 fork 子进程 —— 管道死锁和线程亲缘性导致的挂起，只有在真实的内核行为下才复现得出来。

界面布局另有一个离屏渲染工具，把真实视图渲成 PNG 供肉眼检查：

```sh
GROVE_RENDER=1 swift test --filter LayoutRenderHarness   # 产物在 /tmp/grove-render-*.png
```

SwiftUI 的布局问题（视图不撑满、内容被裁、元素被推出可视区）编译器和断言都发现不了，只能看。默认跳过，不拖慢日常测试。
