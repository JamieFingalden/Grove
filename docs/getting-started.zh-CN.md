# Grove 快速入门

[English](getting-started.md) · [返回首页](../README.zh-CN.md)

本指南面向 v0.2.1：从安装开始，完成创建工作树、提交修改，以及把 PR/MR 检出到独立目录。若 Releases 尚未提供 v0.2.1，可以先使用已发布的 v0.2.0，部分界面位置可能不同。

## 1. 安装

发布的 DMG 支持 Apple Silicon（M 系列芯片）和 macOS 14 或更高版本。Intel Mac 暂无预编译安装包。

### Homebrew

已安装 [Homebrew](https://brew.sh) 的用户可以运行：

```sh
brew tap JamieFingalden/grove https://github.com/JamieFingalden/Grove.git
brew install --cask JamieFingalden/grove/grove
```

这是项目维护的第三方 tap。Homebrew 会从 Grove 的 GitHub Release 下载对应版本的 DMG 并校验 SHA-256。

### 直接下载

1. 打开 [Grove Releases](https://github.com/JamieFingalden/Grove/releases)。
2. 下载对应版本的 `Grove-<版本号>-arm64.dmg`。
3. 打开 DMG，把 `Grove.app` 拖到 Applications（应用程序）。

如需校验安装包，同时下载同名 `.dmg.sha256` 文件，在下载目录运行：

```sh
shasum -a 256 -c Grove-0.2.1-arm64.dmg.sha256
```

使用其他版本时，将文件名替换为实际下载的版本。结果应为 `OK`。

### 首次打开

当前发布包使用临时签名，未经过 Apple 公证。

1. 从 Applications 打开 Grove 一次。
2. 如果 macOS 提示无法验证开发者或无法检查恶意软件，先确认安装包来自上面的项目 Release，且校验结果正确。
3. 打开「系统设置 → 隐私与安全性」，找到 Grove 的拦截提示，选择「仍要打开」，再确认打开。

这只为 Grove 添加例外，无需关闭系统的 Gatekeeper。若提示文件损坏、会损害电脑，或没有「仍要打开」选项，请保留提示并[反馈问题](https://github.com/JamieFingalden/Grove/issues)，不要忽略这类警告。详见 [Apple 的首次打开说明](https://support.apple.com/zh-cn/102445)。

## 2. 准备 Git 和平台登录

先在终端检查：

```sh
git --version
```

如果提示缺少开发者工具，运行 `xcode-select --install`，安装完成后重新检查。使用本地 Git 功能不需要登录 GitHub、GitLab，也不需要配置 AI。

需要 GitHub PR 时：

```sh
brew install gh
gh auth login
gh auth status
```

需要 GitLab MR 时：

```sh
brew install glab
glab auth login
glab auth status
```

按自己使用的平台安装即可。登录完成后重新打开 Grove。GitHub / GitLab 的登录信息由对应 CLI 管理，Grove 不另存一份平台凭据。

## 3. 打开已有仓库

1. 点击「打开仓库…」，或按 `⌘O`。
2. 选择已有的本地 Git 仓库根目录。如果还没克隆仓库，先用平时的 `git clone` 命令克隆。
3. 在侧边栏选中工作树，查看当前分支、变更和历史。

第一次体验建议选择已有至少一次提交的仓库。Grove 直接操作这个仓库，终端和编辑器也可以继续使用它。

## 4. 创建第一个工作树

1. 选中仓库，点击「新建工作树」。
2. 选择「新建分支」，输入尚未使用的分支名，例如 `feature/grove-demo`。
3. 起点选择需要的分支；留空使用界面提示的默认分支或当前 HEAD。
4. 使用建议目录，例如仓库 `/Projects/demo` 对应的 `/Projects/demo-worktrees/feature-grove-demo`。
5. 点击「创建」，打开新目录进行开发。

新工作树有自己的文件和未提交修改，原工作树里的改动保留在原处。它们共享 Git 历史与分支；同一个分支不能同时检出到两个工作树。创建工作树不会复制另一个工作树尚未提交的内容。

## 5. 暂存并提交修改

1. 在新工作树目录中用编辑器修改一个文件。
2. 回到 Grove，选中新工作树，查看「未暂存」中的文件和 diff。必要时按 `⌘R` 刷新。
3. 点击文件的「暂存」，或在 diff 中选择需要的行再暂存。
4. 确认「已暂存」中的内容，填写提交信息，点击「提交」。
5. 需要同步到远端时，检查目标地址后点击「推送」。首次推送或使用多远端时，按界面提示确认远端。

如果 Git 提示未配置身份，在该仓库目录设置 `git config user.name` 和 `git config user.email`，再重试。AI 提交信息是可选功能，不影响手动提交。

## 6. 不打断当前工作，检出一个 PR/MR

1. 完成相应平台 CLI 登录，打开配置了该平台 `origin` 的仓库。
2. 打开仓库的评审请求页面，选中一个 PR/MR。
3. 在请求操作中选择检出为新工作树；也可以从列表右键菜单进入。
4. 在独立目录中阅读、运行或修改代码，原工作树保持原状。
5. 切回侧边栏中的原工作树，继续手头的开发。

同仓库请求可在权限允许时推回原分支。来自 fork 的请求使用本地评审分支，检出不代表你拥有向对方仓库推送的权限。

评审完成、修改已提交或另行保存后，可以从工作树菜单移除不再需要的工作树；删除分支是单独的选项。不要直接删除仍有未保存工作的目录。

## 7. 可选：AI 功能

在 Grove 设置中启用 AI，选择已登录的 Codex CLI，或配置 Chat Completions 兼容 API 的地址、模型和密钥。API 密钥保存在 macOS 钥匙串。

启用后，使用相应功能会把待生成或评审的代码上下文交给所配置的服务处理，可能产生该服务的费用。可以先完成上面的纯 Git 工作流，再决定是否启用。

## 更新、卸载与常见问题

通过 Homebrew 安装的用户：

```sh
brew update
brew upgrade --cask JamieFingalden/grove/grove
```

卸载应用：

```sh
brew uninstall --cask JamieFingalden/grove/grove
```

Cask 不包含删除用户数据的 `zap` 操作，卸载不会主动删除你的 Git 仓库和工作树。直接下载的用户可从 Release 下载新版并替换 Applications 中的应用。

| 问题 | 先检查 |
| --- | --- |
| 找不到 PR/MR | `gh auth status` / `glab auth status`，以及 `git remote -v` 中的 `origin`。Grove 按 `origin` 判断平台。 |
| CLI 已登录，Grove 仍不可用 | 退出并重新打开 Grove，确认 CLI 安装在常规 Homebrew 路径；仍失败时附上自查输出。 |
| 没有可用的远端分支 | 先抓取远端；本地仓库没有远端时也可以创建本地工作树。 |
| 分支已被占用 | 在侧边栏打开已有的工作树，或为新工作树使用另一个分支名。 |
| tap 安装提示找不到 Cask | 确认 tap 包含发布后的 `Casks/grove.rb`，运行 `brew update`，使用完整的 `JamieFingalden/grove/grove` 名称。 |

需要更多诊断信息时，在终端运行：

```sh
/Applications/Grove.app/Contents/MacOS/Grove --doctor /你的仓库绝对路径
```

向 [Issues](https://github.com/JamieFingalden/Grove/issues) 反馈时，附上 Grove 版本、macOS 版本、操作步骤和错误提示。自查输出可能包含仓库路径和远端地址，分享前先检查并隐去私密信息。
