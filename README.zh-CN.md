# Grove

[English](README.md)

Grove 是一个原生 macOS 应用，把 git 工作树（worktree）和代码评审请求（GitHub 的 Pull Request、GitLab 的 Merge Request）放在同一个界面里管理。

工作树能让你同时检出多个分支到不同目录、共用一份克隆。功能写到一半来了个 review 要看，这正是它该上场的时候 —— 但命令行下要自己记一堆路径，而其他 git GUI 基本都把工作树当边角功能。Grove 反过来，侧边栏就是工作树列表：每个工作树显示它在哪个分支、有多少未提交改动、对应的 PR 是什么状态。

它围绕的工作流是：看到一个 PR，一键检出成新工作树，不打断手头的活就能review 或者修，合并之后连工作树带分支一起删掉。

## 系统要求

- macOS 14 或更高版本
- `git` —— 装了 Xcode 命令行工具就有
- `gh`（[GitHub CLI](https://cli.github.com)）—— 可选，GitHub 的 PR 功能需要
- `glab`（[GitLab CLI](https://gitlab.com/gitlab-org/cli)）—— 可选，GitLab 的 MR 功能需要

Grove 不保存任何凭据。所有托管商访问都走对应的 CLI，你只需要认证一次。缺了它们的话，除评审之外的功能完全正常。

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

## 功能

**工作树。** 可以从新建分支、已有本地分支或远端分支创建。Grove 默认把工作树放在仓库的兄弟目录里（`<仓库>-worktrees/<分支名>`），这样工作树之间不会互相出现在对方的 `git status` 里。支持锁定、解锁、清理失效项、删除 —— 删除前会检查有没有未提交的改动，也可以选择同时删掉分支。

**推送。** 只有一个远端时是一键推送。配了多个远端（比如内网 GitLab 做主、GitHub 做备份）时，推送按钮变成分离式：主区域按分支自己的上游推（跟终端里敲 `git push` 一致），右边箭头展开选别的远端，每一项都带上目标地址 —— 两个远端名字相近时只看名字分不清推去了哪。推到非上游的远端**不会**悄悄改掉分支的跟踪目标。

**变更。** 按工作树显示文件列表，分「已暂存」和「未暂存」两栏；diff 查看器能正确处理重命名、二进制文件、纯权限变更，以及合并冲突时的 combined diff。支持暂存、取消暂存、丢弃、提交。切换工作树不会丢失写了一半的提交信息。

**分行提交。** 改了两行只想提交其中一行时，在 diff 里逐行勾选（或点 hunk 头整块勾选），然后暂存 / 取消暂存 / 丢弃选中的行。实现是从 git 自己的 diff 里裁出一个只含选中行的补丁，喂给 `git apply` —— 规则见 `Sources/Grove/Git/PatchBuilder.swift`，正向和反向的基准侧是相反的，那里写清楚了为什么。

**变基。** 从工作树的「⋯」菜单进入，选一个目标分支（远端或本地），跑 `git rebase --autostash <目标>`。开始前会先告诉你**将要发生什么**：重放几个提交、这些提交的 SHA 都会变、分支已推送的话之后要强制推。中途遇到冲突会停下，顶部出现「继续 / 跳过 / 中止」——​没有这一条的话，一遇冲突就只能回终端。

**历史筛选。** 按提交信息搜、按提交人筛（下拉框按提交频次排序）、限定路径、切换「只看当前分支 / 所有分支」。搜索词按字面量匹配而不是正则 —— 搜 `foo(bar)` 就是搜这个字符串本身。开着筛选时栏下会显示筛掉了什么，免得以为提交丢了。

**评审请求（PR / MR）。** 浏览开放的请求，带 CI 结果和评审状态；读讨论线程（行内意见会标出文件和行号）、发评论、提修改意见、批准、合并。界面文案按平台走 —— GitLab 下显示「合并请求」和 `!123`，不会给 GitLab 用户看「Pull Request」这种他们不用的说法。可以把 PR 检出成新工作树 —— 同仓库的 PR 会建立跟踪分支，改完能直接推回去；从 fork 提来的 PR 走 `pull/<编号>/head` 抓成本地 `pr-<编号>` 分支。也可以从当前工作树提 PR（Grove 会先帮你把分支推上去），以及用压缩合并 / 合并提交 / 变基三种方式合并。

**关联。** 每个工作树显示它分支对应的 PR，每个 PR 显示它是否已经被检出。这是整个应用的重点。

## 自查

```sh
dist/Grove.app/Contents/MacOS/Grove --doctor [路径]
```

会打印 `git` 和 `gh` 的位置、传给子进程的 PATH、`gh` 有没有登录，然后是仓库的工作树列表、各自状态、关联的 PR，以及开放的 PR 列表。绝大多数「Grove 打不开我的仓库」「PR 那块是空的」，看一眼这个输出就知道原因了。

## 一些设计取舍

**调用 `git` 命令行而不是链接 libgit2。** 工作树是这个应用的主线功能，而 libgit2 对它的支持一直不完整 —— 光是 `git worktree add` 的那些语义就得自己重实现一遍。走命令行的好处是行为跟用户在终端里看到的完全一致，而且 porcelain 输出格式有官方的向后兼容承诺。

**评审走各自的 CLI（`gh` / `glab`）而不是直接调 API。** 直接调 API 就得自己做 OAuth device flow、把 token 存进 Keychain、处理过期刷新 —— 把 CLI 已经做好的事情重做一遍，自建实例的认证细节尤其琐碎。附带的好处是 Grove 手里没有任何凭据，也就没有泄露面。两个平台的差异（Pull Request vs Merge Request、`#` vs `!`、审批模型、流水线 vs checks）全部收敛在 `ForgeClient` 的两个实现里，界面只看到一套模型。

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
