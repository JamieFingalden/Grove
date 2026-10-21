# Grove 五项缺陷修复与回归报告

- 日期：2026-10-21，Asia/Shanghai。
- 基线：`8212f60405fd3f0d616c21b35e276ba9f52275ed`，修复验收时未提交；现已按问题分别提交到本地，未推送或创建 PR。对应关系见 [分次提交记录](COMMITS_2026-10-21.md)。
- 范围：GitHub #11～#15 的五项已确认缺陷；原始复现与历史证据保留在 [ISSUES.md](ISSUES.md)。
- 执行：Codex 实现、审查及实机回归；GPT-6-luna 子代理实现 BUG-005，并只读审查本批修改。
- 实机环境：macOS 27.0.1，arm64；Release App 3.0.0（9）。版本号保持基线，文件名和二进制哈希区分本地修复验证包，不作为正式发布。
- 所有 Git 变更均只在新建合成仓库中执行：`/private/tmp/grove-fix-20261021.jfosuwn6/`。没有用真实项目测试暂存、提交、推送或合并。应用启动恢复可能只读显示原有项目。

## 结果

| 问题 | 修复行为 | 定向自动回归 | 新包实机回归 |
| --- | --- | --- | --- |
| [#11](https://github.com/JamieFingalden/Grove/issues/11) 编辑后 diff 过期 | 保存后刷新变更、重载所选文件 diff 与冲突文本 | 通过 | 保存、完成后未点刷新，直接出现新增行 |
| [#12](https://github.com/JamieFingalden/Grove/issues/12) 冲突快捷入口漏警告 | 所有界面入口共用确认，模型在暂存前重新读盘检查完整冲突块 | 通过 | 过期无标记视图仍弹警告；取消保留 UU 和三阶段索引；清除标记后可完成真实合并 |
| [#13](https://github.com/JamieFingalden/Grove/issues/13) 首次推送失败 | 无上游时明确指定默认远端和当前分支建立跟踪 | 通过 | 单 origin、空 bare、未设上游，一次点击推送成功 |
| [#14](https://github.com/JamieFingalden/Grove/issues/14) 作者缓存过期 | 完整刷新重新读取作者和计数，拒绝迟到的旧刷新覆盖 | 通过 | 不重启，刷新后出现新作者；计数 2/1；选中新作者只显示其提交 |
| [#15](https://github.com/JamieFingalden/Grove/issues/15) 远端状态误报 | 区分没有远端、没有 origin、origin 无法解析 | 通过 | 有效本地 origin 的评审页显示“无法识别 origin 的地址。” |

当前五项均为“本地已提交、回归通过、未推送”。GitHub Issues 保持开放，修复进展用评论记录；源码尚未提交到 GitHub。

## 实现与验证细节

### BUG-001 / #11

根因是编辑器保存后只调用 `refreshStatus()`，文件仍被选中时不会重新加载 diff。现在 `WorktreeModel.writeEditorFile` 在写入成功后调用已有的 `refreshChanges()`，其所选文件加载路径也会重读冲突内容；删除视图中重复的刷新代码。

新增 `GitFileOperationTests.testEditorSaveReloadsAlreadySelectedDiff`：真实初始化仓库、加载旧 diff，调用编辑器写入路径后等候新 diff，核对磁盘和新增行。实机从“初始内容 + 保存前内容”追加 `QA-saved-diff`，点击保存、完成，不点工具栏刷新，看到 `@@ -1 +1,3 @@` 和新增行；CLI `git diff` 一致。

旁路检查也通过：内置编辑器将冲突文本改为无标记内容，保存、完成后自动进入“文件里没有冲突标记”视图。审查提出该路径可能漏重载，追踪 `refreshChanges → loadDiff → loadConflictContent` 后补加模型断言并实机确认，无需增加第二次读盘。

证据：`editor-before-ax.txt`、`editor-after-save-ax.txt`、`editor-after-save.png`、`conflict-no-marker-before-external-ax.txt`、`conflict-save-check.log`。

### BUG-002 / #12

原先上栏和文件列表自行做确认，底部无标记快捷按钮直接暂存，编辑器另有一套基于内存文本的判断。现在模型 `markConflictResolved(_:confirmingMarkers:)` 必须先重新读取磁盘；所有界面入口调用同一个 `confirmMarkConflictResolved`。取消返回失败，编辑器不关闭；只有暂存成功才返回成功。继续沿用完整冲突块解析规则，不扩大为禁止普通文本中出现单独标记行，也保留用户明确选择“仍然标记为已解决”的现有能力。

新增 `ConflictEditorModelTests.testMarkResolvedChecksDiskAfterNoMarkerContentWasLoaded`：先加载无标记内容，再外部写入完整冲突块；取消确认后仍然冲突且文本不变；真正清除标记后可以正常暂存。补加保存后冲突内容自动重载断言。

实机流程：在 `conflict-guard` 的真实 merge 中，通过编辑器保存无标记内容但不暂存；随后 CLI 外部追加完整块，不刷新界面，点下方快捷按钮，出现“文件里还有 1 处冲突标记”。取消后 `git status --porcelain` 为 `UU test.txt`，索引仍为 1/2/3 阶段，MERGE_HEAD 存在，没有 stage 0。外部清除标记后再次点快捷按钮，正常解决，再点“继续”，得到双父合并提交 `4ee942e8c813adede7f43a66116d8899d3a861c0`；工作区干净，提交文件为 `QA-resolved-final`，`git diff --check HEAD^1 HEAD` 返回 0。

证据：`conflict-stale-no-marker-ax.txt`、`conflict-shortcut-warning-ax.txt`、`conflict-shortcut-warning.png`、`conflict-after-cancel-ax.txt`、`conflict-resolved-ax.txt`、`conflict-merge-complete-ax.txt`、`git-oracles.txt`。

### BUG-003 / #13

`git push --set-upstream` 缺少远端、分支时仍会失败。修复放在共享模型推送入口：仅在没有上游且未显式指定远端时选 `defaultRemote`，复用已有 GitClient 的 `push --set-upstream <remote> <branch>`；已有上游时仍遵循原 Git 推送配置，显式推往备份远端不改 tracking。

新增 `PushTrackingTests.testModelPublishesWithoutUpstreamAndPreservesExistingTracking`，真实本地 bare 验证首次发布空远端、远端已有同名分支时补建上游、显式备份推送后 origin 跟踪不变。既有实际远端分支映射、安全强推检查也通过。

实机 `regression` 仅有一个本地 origin，设置 `push.autoSetupRemote=false`，没有分支上游。点击唯一推送按钮后显示“推送完成”与 `origin/main`；bare main 和本地当时 HEAD 均为 `93b6a56680949b9e7689ce3406d3fdc0e332ed5c`。编辑器未提交的修改仍保留。

证据：`push-before-ax.txt`、`push-after-ax.txt`、`push-after.png`、`git-oracles.txt`。

### BUG-004 / #14

根因是 `refresh()` 仅在 `knownAuthors` 为空时读取作者。现在完整刷新重新读取有采样上限的作者列表，并用请求 ID 拦截迟到结果；侧边栏状态刷新、普通暂存仍不扫描历史。

新增 `GitFileOperationTests.testRefreshUpdatesCachedAuthorsAndTheirCounts`：缓存旧作者后外部增加新作者提交和原作者提交，刷新后核对完整计数并选择新作者验证过滤。既有“暂存不重载历史”检查继续通过。

实机保持同一进程、同一历史页，外部提交后点击一次工具栏刷新，菜单显示原作者 2、新增作者 1；选择新增作者后只有 `109616e` 的“刷新后新作者提交”，没有原作者提交。

证据：`authors-before-ax.txt`、`authors-after-refresh.png`、`authors-filter-new-ax.txt`、`authors-filter-new.png`、`git-oracles.txt`。作者菜单浮层不完整暴露 AX，菜单项目与计数以截图和 CLI 对照为准。

### BUG-005 / #15

本地路径是合法 Git origin，但 `GitRemote.parse` 得到 nil；此前传入平台 setup 判定后误走“无远端”，并遮住原有的不可用原因。现在有远端但无法解析 origin 时使用不可用原因；同时区分已配置别名远端但没有 origin 的情形。

新增 `AppModelProjectTests.testLocalOriginThatCannotBeParsedIsNotReportedAsMissingRemote`，实际建立本地仓库和 bare：有本地 origin → 无法识别；将 origin 改名 backup → 没有 origin；删除 backup 并刷新 → 没有远端。实机项目评审页显示“评审请求不可用 / 无法识别 origin 的地址。”，与工作树工具提示一致。

证据：`platform-local-origin-ax.txt`、`platform-local-origin.png`。

## 可重复执行的回归

在 Grove 目录运行：

```sh
swift test --filter 'GitFileOperationTests|ConflictResolutionTests|ConflictEditorModelTests|PushTrackingTests|SafeForcePushTests|AppModelProjectTests|HistorySelectionTests'
```

39 项全部通过、0 失败、0 跳过。随后为审查指出的冲突保存路径补加断言，仅重新运行 `ConflictEditorModelTests`，2 项全部通过；这 2 项属于上述 39 项，不能相加成 41 项。本轮未重复全部 462 项历史基线，也没有扩大到与五项修复无关的功能。

测试开发期间修正了旧方法签名、Swift actor 隔离和临时目录 `/var`/`/private/var` 的模型路径匹配；最终日志是成功的定向运行。构建与最终实机使用的产品源码一致，补加的冲突保存断言只修改测试文件。

## 2026-10-21 清理说明

按用户要求，临时测试项目、重复 QA App 和本轮 DMG 已清理；下列交付路径是当时验收记录。当前仅维护 `dist/Grove.app` 供直接试用，报告与证据保留。详见 [清理记录](CLEANUP_2026-10-21.md)。

## 交付与证据

- 修复版 App：`dist/qa/20261021/fixes/installed/Grove.app`。
- 安装包：`dist/qa/20261021/fixes/Grove-3.0.0-fixes-20261021.dmg`。
- DMG SHA-256：`a54412a314b30326b93500f5fa30b92b764b51365104fad9b1126c58f846f18c`。
- 已测二进制 SHA-256：`a945a6b18a8823173ba15e2277086edd537cde5b163d2fbcd847959255b61c9d`。
- 只读挂载 DMG 核对二进制一致、签名校验通过，已卸载；旧版 DMG、旧版 QA App 均保留，没有替换 `/Applications/Grove.app`。
- Release 构建通过，Apple Development 签名；仍未公证，沿用原测试报告的分发限制，不声称正式发布。
- 原始证据：`dist/qa/20261021/fixes/evidence/`，含成功测试日志、Release 构建日志、界面截图/AX、Git 判据、fixture 路径、源码与测试补丁。补丁 SHA-256：`212df0570ed8ff7e1b3c7349b98fa1c180aecc69d96819a792e1ec55c45da316`。
- 编码检查结果：本次修改源码、测试及文档均为 UTF-8 无 BOM，无新增替换字符、连续三个问号或明显乱码；`git diff --check` 通过。

## GitHub 进展评论

[# 11 的修复回归记录](https://github.com/JamieFingalden/Grove/issues/11#issuecomment-6310848420)、[# 12 的修复回归记录](https://github.com/JamieFingalden/Grove/issues/12#issuecomment-6310854516)、[# 13 的修复回归记录](https://github.com/JamieFingalden/Grove/issues/13#issuecomment-6310856095)、[# 14 的修复回归记录](https://github.com/JamieFingalden/Grove/issues/14#issuecomment-6310857707)、[# 15 的修复回归记录](https://github.com/JamieFingalden/Grove/issues/15#issuecomment-6310859241)。五项均已同步评论，未关闭 Issue。
