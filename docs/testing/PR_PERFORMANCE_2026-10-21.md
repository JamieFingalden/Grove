# PR 列表加载修复与实机回归

- 日期：2026-10-21，macOS 27.0.1 arm64。
- GitHub Issue：[加载问题 #16](https://github.com/JamieFingalden/Grove/issues/16)，本地修复已提交，未推送，保持开放。
- 用户发现：开放列表较快，全部 PR 极慢；负责人实机确认实际会永久停在加载态。
- 当前交付：`dist/Grove.app`，3.0.0（9），直接运行，未安装到 Applications，未生成新 DMG；本地修复已提交，未推送，见 [分次提交记录](COMMITS_2026-10-21.md)。
- 二进制 SHA-256：`81f3018f1c00a4b8a9c1134f17e935290ea6825e57c9a68dde1d7df9c80898cf`；Release 构建与签名校验通过。

## 复现与根因证据

在 Grove 仓库项目页，“开放”正常返回空列表，点击“查看全部”后持续显示加载中。查询子进程已经退出，界面仍没有结果；手动刷新也重复发生。

同仓库直接运行原有 CLI 查询，“全部”约 3.953 秒返回 10 条，“开放”约 2.120 秒返回 0 条。另一次删减重字段的定位对比约 2.334 秒，但本轮修复保持现有列表字段和检查徽章。

临时 Release 状态追踪显示：请求状态为 `all`，两个并发结果却均带 `open` 标识；请求编号、origin 和当前筛选匹配都为 true，且未取消。结束时条数为 0，`hasLoadedPullRequests=false`，因此界面持续显示加载而不报错。这是发布优化路径下可复现的结果归类异常，不能归因为网络超时。

## 改动

`RepositoryModel.loadPullRequests` 的任务闭包显式捕获筛选值，先 await 获取请求列表，再组装带筛选标识的结果。继续保持历史列表与侧栏开放数量独立发布，历史列表不等待侧栏补查。

复用已有回归检查，增加发布配置运行要求。两个既有评审入口测试的手工模型夹具补上 `hasOrigin=true`，使“已配置解析成功的 origin”与上一批远端分类修复的状态约定一致。

临时状态日志代码已从最终源码和 App 移除；原始状态追踪保留作证据。

## 定向自动回归

运行：

```sh
swift test -c release --filter PullRequestLoadStateTests
```

- 修复前：6 项测试，7 个失败断言。其中 5 个断言确认列表加载/缓存不能完成，另外 2 个是手工夹具缺少 hasOrigin 状态。
- 修复后：6 项全部通过，0 失败、0 跳过。覆盖慢开放计数、并发共享、历史列表提前发布、失败重试/切换筛选、慢侧栏历史、评审入口。
- 本轮没有重复全量测试。定向测试只用自动清理的临时目录，没有新增持久测试项目。
- 发布测试当时保留了临时追踪；随后仅移除追踪代码、加入中文说明，重新构建最终 App，并完成下述真实界面验收。

## 最终 App 的实机验收

使用真实 Grove 仓库作只读网络查询，不暂存、提交、切分支、推送或修改任何 PR。

| 路径 | 实际结果 |
| --- | --- |
| 开放 | 正常显示没有开放 PR |
| 开放 → 查看全部 | 显示 10 条历史 PR，不再永久加载 |
| 全部 → 已合并 | 显示 8 条已合并 PR |
| 已合并 → 已关闭 | 完成加载并显示列表 |
| 再切回全部 | 正常显示 10 条，列表保留检查徽章 |
| 侧边栏 | 本轮 8 个测试项目均已移除，未再次添加 |

这里的实机验收确认了结果能够正常展示，不把工具操作延时当作纯网络耗时，也不承诺网络请求瞬时完成。

## 证据与清理

证据目录：`dist/qa/20261021/pr-performance/`。

- `all-before-ax.txt/png`、`all-with-no-gh-child-ax.txt`：旧版永久加载。
- `timings.json`：只读 CLI 对比。
- `request-trace.txt`：Release 结果归类异常。
- `release-before-tests.log`、`release-after-tests.log`：发布配置定向测试前后结果。
- `final-build.log`：最终构建。
- `all-final-ax.txt/png`、`merged-final-ax.txt`、`closed-final-ax.txt`：最终 App 验收。
- `bookmark-cleanup.json`、`cleanup.json`：清理明细。

测试项目、工作树、bare、重复 App、本轮 DMG 和重复 worker 数据已清理，回收约 90.9 MiB。保留当前 `dist/Grove.app`、问题文档和必要证据，详见 [清理记录](CLEANUP_2026-10-21.md)。RUNBOOK 已改为归档后必须收尾清理，并明确用户试用阶段只维护 App。

编码检查结果：本次源码、测试和文档为 UTF-8 无 BOM，无新增替换字符或明显乱码；`git diff --check` 通过。
