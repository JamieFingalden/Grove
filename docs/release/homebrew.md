# Homebrew 自有 tap 维护

Grove 使用本仓库根目录的 [Casks/grove.rb](../../Casks/grove.rb) 作为 Cask。直接复用 Grove 仓库，无需另建 `homebrew-tap` 仓库，也无需跨仓库访问密钥。

## 用户安装入口

以下命令应在 `Casks/grove.rb` 已提交并推送到仓库默认分支后对外公布：

```sh
brew tap JamieFingalden/grove https://github.com/JamieFingalden/Grove.git
brew install --cask JamieFingalden/grove/grove
```

必须保留第一行的显式仓库 URL。省略 URL 的 `brew tap JamieFingalden/grove` 会寻找另一个名为 `homebrew-grove` 的仓库。

这是第三方 tap，没有申请 Homebrew 官方 Cask 收录。安装包保持临时签名和未公证状态，Cask 不执行移除隔离属性或修改系统安全设置的脚本。首次打开说明见[快速入门](../getting-started.zh-CN.md#首次打开)。

## 当前版本

初始 Cask 指向已经发布的 **v0.2.0**，SHA-256 已用实际下载的 DMG 和 Release 校验文件核对：

```text
52014710134f6c5237dfa143fac2787f6e7217344f8d673b6959b40fad136e83
```

本次待发布版本为 **v0.2.1**。在它的 DMG 成功发布前，不要把 Cask 改成 `0.2.1`，也不要填入本地另一份构建的校验值。

## 发布 v0.2.1 并更新 tap

1. 确认 `Support/Info.plist` 中应用版本为 `0.2.1`、构建号为 `10`。应用版本不带 `v`，Git 标签带 `v`。
2. 将版本修正、Cask 和 CI 修改提交到发布提交，推送并等待分支 CI 通过。
3. 将 `v0.2.1` 标签指向该发布提交后推送，等待标签 CI 成功（当前本地 `v0.2.1` 已指向版本为 `0.2.1` 的提交，尚未推送）。若某标签已经发布 Release，则使用新版本，不覆盖已有发行包。
4. 标签 CI 会生成 DMG、`.sha256` 和 `grove.rb` 三个文件，发布到同一个 GitHub Release。`grove.rb` 的版本和校验值来自这次构建。
5. 用发布附件中的 `grove.rb` 更新仓库里的 `Casks/grove.rb`，检查差异应只涉及版本和 SHA-256。可以先下载到独立目录：

```sh
mkdir -p dist/tap-0.2.1
gh release download v0.2.1 --repo JamieFingalden/Grove --dir dist/tap-0.2.1 --pattern grove.rb --pattern '*.sha256'
diff -u Casks/grove.rb dist/tap-0.2.1/grove.rb
```

确认它指向 `v0.2.1/Grove-0.2.1-arm64.dmg`、版本与 DMG 校验文件一致后，复制并提交到默认分支：

```sh
cp dist/tap-0.2.1/grove.rb Casks/grove.rb
```

6. 从干净的安装环境执行安装、启动和卸载检查，再公布 Homebrew 安装入口和发布文章。已有 Grove 的电脑可执行升级检查，避免覆盖日常使用中的应用。

```sh
brew update
brew upgrade --cask JamieFingalden/grove/grove
```

后续版本采用相同流程。无需修改 Cask 中的下载 URL 模板，也无需额外的自动提交机器人；main 分支的 CI 会在每次推送时校验 `Casks/grove.rb` 的版本与最新已发布 Release 一致，忘记第 5 步回写会在下一次 push 时被直接拦下（发布完成前的中间态不受影响——校验对象是已建成的 Release，不是标签）。

## 检查范围

- Cask 只声明实际支持的 Apple Silicon 和 macOS 14+。
- `gh`、`glab` 和 AI 都是可选项，不作为强制安装依赖。
- 使用固定版本 URL 和 SHA-256，不使用 `version :latest` 或 `sha256 :no_check`。
- 不配置 `zap`，避免卸载时主动删除用户数据。
- 官方仓库的 Gatekeeper 审核会拒绝未公证包；不要把未通过官方审核与自有 tap 的安装测试混为一谈。

参考：[第三方 tap](https://docs.brew.sh/Taps)、[Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)、[官方 Cask 接收条件](https://docs.brew.sh/Acceptable-Casks)。
