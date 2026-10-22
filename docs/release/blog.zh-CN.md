# Grove：用独立工作树接住临时来的代码评审

写功能到一半，同事发来一个 PR，请你帮忙看一下。

只在网页上看看 diff 很方便，但要运行项目、验证问题，或者顺手改几行，就需要把分支拉到本地。当前目录里还有没提交的代码，这时又要考虑先提交、stash，还是再克隆一份仓库。

Git 的 worktree 已经能解决这个问题：一个仓库可以同时把不同分支检出到不同目录。原来的功能继续留在原目录，评审在另一个目录进行，共享同一份 Git 历史。

我做的 Grove，就是把工作树和代码评审放进同一个原生 macOS 应用里。这次准备发布的是 v0.2.1。

## 从一个 PR 到一个独立目录

Grove 的核心工作流很短：打开仓库，找到要看的 PR 或 MR，检出成一个新工作树。

你可以在新目录里打开编辑器、运行测试、修改代码；原来的工作树留在原处。看完以后切回原来的工作树，继续之前的功能。评审结束，不再需要的工作树也可以从应用里移除。

这让“现在有哪些分支正在做、哪个分支对应哪个评审请求”更容易看清楚，不必一直在终端输出和目录之间对应。

工作树是 Git 自己的工作树。你仍然可以使用平时的终端、编辑器和 Git 命令。

## 日常修改也能在这里完成

Grove 可以查看工作树的变更和提交历史，暂存文件、按行暂存、提交和推送。一次改动里混了两件事时，可以先选出需要的行，分成两个提交。

合并或变基遇到冲突时，应用会展示冲突内容和继续、中止等操作。历史提交支持创建标签，便于把日常开发接到版本发布。

代码评审支持 GitHub PR 和 GitLab MR，对应平台分别通过 `gh` 和 `glab` 登录。已有的 CLI 登录可以继续使用，本地 Git 功能也可以单独使用。

还有可选的 AI 提交信息和代码评审：可以接入已登录的 Codex CLI，或配置兼容 API。它们需要单独启用，使用时相关代码上下文会交给所配置的服务处理。先只把 Grove 当工作树管理工具也完全可以。

## 安装和第一次使用

当前预编译安装包支持 **Apple Silicon、macOS 14 或更高版本**。

可以从 [GitHub Releases](https://github.com/JamieFingalden/Grove/releases) 下载 DMG，把 Grove 拖到 Applications。项目也提供自有 Homebrew tap：

```sh
brew tap JamieFingalden/grove https://github.com/JamieFingalden/Grove.git
brew install --cask JamieFingalden/grove/grove
```

安装包使用临时签名，未经过 Apple 公证。首次打开如果被 macOS 拦截，核对来源后，到「系统设置 → 隐私与安全性」选择「仍要打开」。具体步骤、平台登录和第一个工作树的创建过程，都放在[快速入门](https://github.com/JamieFingalden/Grove/blob/main/docs/getting-started.zh-CN.md)里。

## 想听听实际使用中的反馈

如果你经常需要同时处理功能开发和代码评审，欢迎拿一个熟悉的仓库试试：保留当前工作树，再为另一条分支或一个 PR 新建工作树，看看这种方式是否适合自己的习惯。

比较想知道的是：工作树和评审请求的关联是否清楚，检出后能不能顺畅地进入编辑器，以及哪一步还需要反复回终端。

[项目地址](https://github.com/JamieFingalden/Grove) · [下载安装包](https://github.com/JamieFingalden/Grove/releases) · [问题反馈](https://github.com/JamieFingalden/Grove/issues)
