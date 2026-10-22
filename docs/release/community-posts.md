# Grove v0.2.1 社区发布文稿

以下是待发布文稿，尚未对外发帖。先确认 v0.2.1 Release 可下载、默认分支中的 Cask 已更新，再使用含 Homebrew 安装说明的正文。博客正文见 [blog.zh-CN.md](blog.zh-CN.md)。

## V2EX · 分享创造

发布入口：[分享创造](https://www.v2ex.com/go/create)。该节点欢迎分享自己的作品；发帖前再检查当日规则。

标题：做了一个原生 macOS 小工具 Grove，把 Git worktree 和 PR/MR 放在一起

正文：

写功能到一半，经常会遇到临时要看的 PR。网页上看完 diff 还不够，想在本地跑一下，又不想打断当前目录里没提交的代码。

Git worktree 能让不同分支各用一个目录。我做的 Grove 就是围绕这个工作流：从 PR/MR 检出独立工作树，在新目录里运行或修改，完成后切回原来的工作。也能查看 diff、按行暂存、提交、推送和处理冲突。

这次是 v0.2.1，预编译包支持 Apple Silicon、macOS 14+。GitHub 和 GitLab 分别通过 gh、glab 登录；AI 功能可以不启用。安装包未经过 Apple 公证，首次打开可能需要在「隐私与安全性」里允许。

项目与下载：https://github.com/JamieFingalden/Grove

快速入门：https://github.com/JamieFingalden/Grove/blob/main/docs/getting-started.zh-CN.md

如果你也经常同时做功能和评审，欢迎试试。想听听工作树管理和评审切换中还有哪些不顺手的地方。

## 中文短帖

适用于允许作者分享作品的开发者社区或个人动态，按目标平台规则选取发布位置。

做了个原生 macOS 工具 Grove：把 Git worktree 和 GitHub PR / GitLab MR 放在一起。

功能写到一半来了个 PR，可以检出到独立工作树，在新目录里运行、修改，再切回原来的工作。也支持 diff、按行暂存、提交和冲突处理。

v0.2.1，Apple Silicon / macOS 14+；未经过 Apple 公证，首次打开需按系统提示允许。AI 是可选项。

项目、下载与入门：https://github.com/JamieFingalden/Grove

## 英文社区短帖

标题：Grove: a native macOS app for Git worktrees and PR/MR workflows

正文：

I built Grove for the moment when a review arrives while my current branch still has uncommitted work.

Grove connects Git worktrees with GitHub pull requests and GitLab merge requests. Check a request out into its own directory, run or edit the code there, then return to the worktree you were using. It also supports diffs, line-level staging, commits, pushes, and conflict resolution.

The v0.2.1 release targets Apple Silicon on macOS 14+. GitHub/GitLab access uses gh/glab, and AI features are optional. The UI currently includes Chinese labels. The app is not Apple-notarized, so first launch may require Open Anyway in Privacy & Security.

Project and downloads: https://github.com/JamieFingalden/Grove

English getting started: https://github.com/JamieFingalden/Grove/blob/main/docs/getting-started.md

I'd appreciate feedback on the worktree-to-review workflow, especially the steps that still send you back to the terminal.

## 渠道适配说明

- [Hacker News](https://news.ycombinator.com/newsguidelines.html) 当前规则要求作者亲自撰写内容，并明确不接受生成式文本和自动发帖。因此这里不提供可直接粘贴的 Show HN 帖子。若选择该渠道，请用自己的话讲个人开发动机，并链接可试用的项目；[Show HN](https://news.ycombinator.com/showhn.html) 面向可体验的作品，博客文章本身应作为普通投稿。
- [r/macapps 规则](https://www.reddit.com/r/macapps/about/rules.json) 对开发者推广、社区 karma、发帖资格和模板有专门限制。未确认账号资格时，优先按规则使用月度推广集中帖；上面的英文短帖只能作为按目标版规调整的素材。
- V2EX 正文保留作者身份和安装限制，不使用无法证实的性能数据、使用人数或“最佳”等结论。其他社区发布前检查其自荐规则。
