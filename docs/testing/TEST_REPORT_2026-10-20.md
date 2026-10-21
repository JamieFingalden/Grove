# Grove 3.0.0 真实软件验收测试报告（2026-10-20）

> 本文保留第一轮基础流程结果，不代表完整发布验收。冲突、恢复、异常输入及状态组合等专项结果见 [第二轮报告](DEEP_TEST_REPORT_2026-10-20.md)；2026-10-21 接力执行记录见 [续测报告](CONTINUATION_TEST_REPORT_2026-10-21.md)。后续新增问题集中更新 [问题详单](ISSUES.md)。

- 被测对象：Grove 3.0.0（build 9），基线提交 `8212f60405fd3f0d616c21b35e276ba9f52275ed`
- 安装包：`dist/Grove-3.0.0.dmg`，SHA-256 `740b5a56e3b1a7bb8bd80ca65bd16c9a8c2986d096b7e05d5729fda5054a61f5`（与 `dist/Grove-3.0.0.dmg.sha256` 一致，`shasum -c` 通过）；实际运行副本 `dist/qa/20261020/installed/Grove.app`
- 测试环境：macOS 27.0.1（26A434），arm64，Swift 6.4，git 2.54.0（Apple Git-157）
- 测试日期：2026-10-20（Asia/Shanghai）
- 证据目录：`dist/qa/20261020/evidence/`
- 单元测试回归：一次 `swift test` 共 462 项，跳过 22，失败 0（实际执行通过 440 项）。单元测试不替代真实 GUI 验收。

## 1. 执行者与署名

| 执行者 | 实际做的事 |
| --- | --- |
| 负责人（Codex computer-use） | 构建打包与安装链路（INST）、真实 GUI 首批用例（ui-01…ui-09、git-0x） |
| ZCode GLM（glm-5.3-flash，computer-use + CLI 判据） | 第二批真实 GUI 用例（glm-\*：REPO-002/003、CHG-002、WT 全组、HIST、TAG、推送、草稿、编辑器缺陷第二次复现） |
| 本轮 pi（rundong/glm-5.3-flash） | 仅证据审阅（含逐张核对编辑器缺陷前后两张 PNG）、GitHub Issue 登记、报告与文档；未操作 GUI |

统计口径：全部由证据逐条核对得出。ZCode 停止前自述「GUI 做了 18 项」不作为统计依据。

## 2. 结果总览

- 本地验收矩阵 27 项（TEST_CASES 24 条 + 补充用例 3 条），另有 5 项外部场景未执行且不计入该分母：BLK-PR-001、BLK-PR-002、BLK-SSH-001、BLK-AI-001、BLK-PUSH-001
- 通过：23（其中 INST-002 为变通执行：hdiutil + ditto 安装到测试目录，未做 Finder 拖装至 /Applications）
- 失败：1（SUP-EDITOR-001，确认缺陷，GitHub Issue #11）
- 未执行：3（RST-001、DAILY-001、WS-001，见矩阵备注）
- 外部平台/SSH/AI/真实推送（上列 5 项 BLK）：全部未执行，未测、未补测、不计阻塞（前提未评估，只记录事实）

## 3. 结果矩阵（与 TEST_CASES.md 的 ID 逐条对齐）

状态：✅ 通过／❌ 失败／⚪ 未执行。括号内为实际操作者。

### INST 安装与启动

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| INST-001 | ✅ 通过（负责人） | Release 构建退出 0；`plutil -lint` 退出 0；安装副本 Info.plist 实为 3.0.0 / 9；`lipo` 为 arm64；`codesign --verify --deep --strict` 在放行系统信任服务的环境退出 0。证据：package-checks.md、build.log。spctl rejected 是未公证的分发限制，单列 DIST-001，不影响本条 |
| INST-002 | ✅ 通过（变通执行，负责人） | DMG 经 `hdiutil verify` 且只读挂载成功（dmg-mount.log）；用 `ditto` 安装到 dist/qa/20261020/installed/，与 dist 二进制 `cmp` 一致。**如实说明：未执行 Finder 拖至 /Applications 的交互路径**，未触碰 /Applications/Grove.app |
| INST-003 | ✅ 通过（负责人） | computer-use 启动安装副本，窗口可用，进程 PID 3274 且命令路径指向安装副本（package-checks.md）；ZCode 轮再次确认界面可操作（glm-initial-ui.txt） |

### REPO 仓库管理

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| REPO-001 | ✅ 通过（负责人实测；ZCode 轮确认） | 侧栏出现「格罗夫 测试仓库」，主工作树显示分支 main 与改动计数；AX 抓取含完整变更列表。证据：ui-03-open-fixture-changes.txt/png |
| REPO-002 | ✅ 通过（ZCode GLM） | 重复「打开仓库」后侧栏仍只有一个该项目条目，无新建目录、无报错，提交草稿保留。证据：glm-repo-cases.md |
| REPO-003 | ✅ 通过（组合判据：负责人 GUI + ZCode doctor） | 第 1 判据：负责人在真非仓库目录 /private/tmp/grove-qa-nonrepo-20261020 GUI 实测出现「不是一个 git 仓库」详细错误（ui-01-nonrepo-error.txt/png）——有效。第 2 判据：本轮造数的真负例 doctor 输出「不是 git 仓库。」（/private/tmp/grove-qa-glm-20261020/artifacts/logs/）。**旧 testroot 内的「不是仓库」位于 Grove 工程内，被 git 向上解析到工程根，属无效负例，不得据此计通过**；本轮 GUI 重复执行因宿主键盘焦点/Spotlight/NSBrowser 限制标注环境受限未执行（glm-repo-cases.md） |

### CHG 变更与 diff

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| CHG-001 | ✅ 通过（负责人实测；ZCode 轮确认） | 变更页三类状态齐全：已暂存 README.md（M）、未暂存 src/main.txt（M）、未跟踪 notes/待办.txt（?）；中文与空格路径无乱码。证据：ui-03-open-fixture-changes.txt、git-04-staged.txt |
| CHG-002 | ✅ 通过（ZCode GLM） | 重命名提交以 R 呈现（R100 src/app.txt → src/main.txt，内容区「内容没有变化。」）；二进制提交 A、+0/−0，显示「二进制文件，无法按行比较。」无乱码。CLI 判据 `--name-status`/`--numstat` 一致。证据：glm-chg-002-rename-commit.png、glm-chg-002-binary-commit.png、glm-hist-verify.txt |

### STG 暂存与提交

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| STG-001 | ✅ 通过（负责人） | src/main.txt 暂存后移入「已暂存」栏（2 项），未跟踪待办.txt 不受影响。证据：ui-04-stage-file.txt/png、git-04-staged.txt |
| STG-002 | ✅ 通过（负责人） | 取消暂存后回到「未暂存」，diff 内容仍在。证据：ui-05-unstage-file.txt/png |
| STG-003 | ✅ 通过（负责人） | 提交成功：0d229c8「GUI 验收：提交测试」，作者 zhangsan@test.local（仓库本地测试身份，非全局身份）；已暂存栏清空。证据：ui-06-commit.txt/png、git-06-commit.txt |

### LSTG 分行暂存

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| LSTG-001 | ✅ 通过（负责人） | 勾选单行暂存后同一文件同时出现在已暂存（半实心圆图标）与未暂存列表，提交按钮变「提交 1 项」；git 判据：暂存区 patch 恰含选中行（+分行测试甲），工作区 patch 含其余行。证据：ui-09-partial-stage.txt/png、git-09-partial-index.patch、git-09-partial-worktree.patch |

### WT 工作树（ZCode GLM）

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| WT-001 | ✅ 通过 | 新建工作树 gui-wt-1：侧栏新条目；`worktree list --porcelain` 含兄弟目录路径与分支 refs/heads/gui-wt-1；目录存在；新工作树 status 干净。证据：glm-wt-001-start-ax.txt、glm-wt-001-result-ax.txt、glm-wt-001-verify.txt、glm-wt-dialog-start.png |
| WT-002 | ✅ 通过 | 锁定后条目与详情页出现锁形标识；porcelain 该段含 `locked`。证据：glm-wt-002-result.txt、glm-wt-002-locked.png |
| WT-003 | ✅ 通过 | 右键菜单「锁定」变「解锁」；解锁后的 WT-004 强制删除成功（锁定状态下 git 会拒绝删除），双判据一致。证据：glm-wt-002-result.txt、glm-wt-001-verify.txt |
| WT-004 | ✅ 通过 | 脏工作树删除保护：警示文案 + 非强制删除被 git 拒绝（退出码 128，错误面板展示），工作树与目录保留；勾强制删除后目录删除、分支按未勾选项保留。证据：glm-wt-004-result.txt、glm-wt-004-dirty-warning-dialog.png、glm-wt-004-delete-refused-error.png |

### HIST 历史筛选（ZCode GLM）

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| HIST-001 | ✅ 通过 | 筛选 foo(bar) 字面量命中且仅命中 1 条（aa6f664）；若按正则解析将 0 命中，字面量语义成立。证据：glm-hist-result.md、glm-hist-001-literal-filter.png、glm-hist-verify.txt |
| HIST-002 | ✅ 通过 | 指示条「已筛选：包含…」显示；「清除」后恢复全部 5 条，与 `rev-list --count HEAD` 一致。附 S4 观察 OBS-001（指示条先于实际过滤）。证据：glm-hist-result.md、glm-hist-verify.txt |

### TAG 标签（ZCode GLM）

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| TAG-001 | ✅ 通过 | 附注标签 qa-gui-annotated：objecttype=tag → aa6f664；`tag -n9` 显示说明；ls-remote origin 不含（未推送）。附 OBS-002/OBS-003。证据：glm-chg-tag-result.md、glm-tag-verify.txt |
| TAG-002 | ✅ 通过 | 轻量标签 qa-gui-lightweight：objecttype=commit → dfd36c8；未推送；取消「附注」后说明框消失符合轻量语义。证据：同上 |

### RST / PLAT / DAILY / WS

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| RST-001 | ⚪ 未执行 | 无任何重启恢复证据（无 ⌘Q 重启记录、无 defaults 读取记录），如实不判 |
| PLAT-001 | ✅ 通过（限定范围：负责人 AX + doctor 判据） | 本地 bare origin 下工具栏「提交评审」按钮禁用，Help 文案「无法识别 origin 的地址」（ui-03-open-fixture-changes.txt）；doctor 同套规则输出「origin 指向 未知主机…评审功能不可用」（本轮 summary.txt）。**验收范围仅限该不可用提示与 doctor 规则一致；未进入评审分栏本身验证，不代表评审分栏已验收** |
| DAILY-001 | ⚪ 未执行（仅有限观察） | 负责人只读核对旧合成仓库 `git log`：共 5 条提交，全部为 2026-10-20 16:02–16:05 +0800，作者张三 3 条 / 李四 2 条（各测试邮箱）——已有当日双作者合成提交，但未完成 Daily 身份匹配与作者筛选验证；Daily 界面 0 条的原因未核实，不能据此归因为造数失败。未执行结论保持 |
| WS-001 | ⚪ 未执行（仅只读观察） | Workspace 页观察到的是多个用户已有仓库的聚合展示（只读，未操作）；不能据此证明本项目无平台空态或单项目全隔离 |

### 补充用例（本轮新增，ZCode GLM 执行）

| ID | 名称 | 状态 | 关键事实与证据 |
| --- | --- | --- | --- |
| SUP-EDITOR-001 | 内置编辑器保存/完成后 diff 自动刷新 | ❌ 失败（确认缺陷） | 两次独立复现（负责人 ui-07/08 第 1 次；ZCode GLM 第 2 次）：保存并关闭编辑器后 diff 保持旧内容，手动刷新才更新。已登记 https://github.com/JamieFingalden/Grove/issues/11，本地详单见 ISSUES.md BUG-001。本轮 pi 已逐张核对前后两张 PNG 与文字证据一致 |
| SUP-DRAFT-001 | 提交草稿跨工作树操作保留 | ✅ 通过 | 主工作树提交框草稿在打开工作树对话框、创建/锁定/解锁/删除工作树、切换工作树后完整保留（AX 状态 textarea 含原文，提交按钮「提交 1 项」）。证据：glm-draft-keep-result.txt、glm-wt-dialog-start.png |
| SUP-PUSH-001 | 推送到两个本地 bare 远端 + tracking 保持 | ✅ 通过 | 推送 origin 后 ↑1 消失、历史挂双徽标，ls-remote 与 rev-parse 三方一致，branch.main.remote=origin；分离式菜单选 backup 推送成功且未劫持上游跟踪。本地 Git 行为验证，不含真实平台推送。证据：glm-push-result.md、glm-push-verify.txt |

### 外部依赖项（BLK-\*：一律未执行）

gh CLI 在本机已登录（`gh auth status` 事实），但真实 GitHub PR、GitLab MR、SSH 远程、AI 生成、真实平台推送本轮均未执行、未补测；前置未评估，不计「阻塞」也不计通过，仅记录事实。

## 4. 缺陷与观察汇总

- 确认缺陷 1 项：BUG-001（编辑器 stale diff，S3）→ Issue #11，详见 ISSUES.md。
- 观察/建议 4 项：OBS-001～OBS-004（S4，不立缺陷，详见 ISSUES.md）。
- 分发限制 1 项：DIST-001（未公证，非功能缺陷）。
- 环境记录 3 项：ENV-001～003（非产品缺陷）。

## 5. 结论

被测版本 3.0.0（9）在本轮基础流程覆盖范围内取得以下结果：安装/启动、仓库管理、变更与 diff（含重命名/二进制）、暂存/提交、分行暂存、工作树全组、历史字面量筛选、本地标签、双本地 bare 远端推送、草稿保留共 23 项通过；1 项确认缺陷（编辑器 stale diff，S3，已登记 Issue #11）；3 项未执行（重启恢复、Daily 作者筛选、Workspace 空态），需具备前提的下一轮补做。修复验收以 Issue #11 的验收条件为准。
