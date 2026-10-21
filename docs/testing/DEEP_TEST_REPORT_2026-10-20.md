# Grove 第二轮风险探索测试报告（2026-10-20）

- 被测对象：Grove 3.0.0（build 9），安装副本 `dist/qa/20261020/installed/Grove.app`，基线 `8212f60405fd3f0d616c21b35e276ba9f52275ed`
- 执行者：ZCode GLM5.3Flash（2026-10-20 起，额度耗尽后停止）；Codex 于 2026-10-21 接手复核，GPT-6-luna 子代理续测。均以真实 computer-use ＋ CLI 判据验收
- 本轮专用临时根：`/private/tmp/grove-deep.R2SGP6`（所有 Git 变更仅在此根下）
- 本轮证据目录：`dist/qa/20261020/deep/`（第一轮 `dist/qa/20261020/evidence/` 只读）
- 关联文档：计划 `DEEP_TEST_PLAN_2026-10-20.md`；第一轮报告 `TEST_REPORT_2026-10-20.md`（保留不覆盖）；缺陷详单 `ISSUES.md`（追加）
- 统计口径：只有实际 GUI 操作＋CLI 判据齐全才计「通过」；代码阅读推断不算通过，也不能单独确认缺陷。确认缺陷做一次定向复现即记录，高风险数据丢失证据充分时不受第二次复现限制
- 最终状态：本轮可隔离范围已收尾；接力记录见 [续测报告](CONTINUATION_TEST_REPORT_2026-10-21.md)。完整矩阵27项（原25＋补充2），22通过、4失败、1未执行。4个失败对应4个本轮确认问题，另有第一轮已知#11。各轮用例覆盖有重叠，不合并当作独立功能总数

## 状态图例

✅ 通过 ／ ❌ 失败（确认缺陷）／ ⚪ 未执行 ／ 🔧 工具阻塞（非产品缺陷）

## 最终结果矩阵

### A 分行操作与数据完整性 ✅ 全部通过

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| A1 | ✅ 通过 | repo-a `src/feature.txt` 两个相隔 hunk（hunk1 行2 替换；hunk2 内替换+删除+新增混合）。GUI 勾选 hunk1 替换对 2 行→「暂存选中行」：CLI 判据 `git diff --cached` 恰为 alpha-02 替换对；同 hunk 内再只选「+inserted-甲」暂存：索引第二段恰为 `+inserted-甲` 单行，未选的 alpha-10 对/alpha-12 删除/inserted-乙 全部留在工作区；文件字节 SHA 与操作前基线一致。同一文件同时出现在已暂存（半实心圆）与未暂存列表。证据：`deep/A/a1-01-feature-diff-before.png`、`a1-02-partial-staged-split.png`、`a-judgments.txt` |
| A2 | ✅ 通过 | 在「暂存区」diff 中只选「+inserted-甲」→「取消暂存选中行」：索引回到仅 alpha-02 对，inserted-甲 回到工作区补丁；字节不变，status 为 `MM src/feature.txt`。证据：`deep/A/a-judgments.txt` |
| A3 | ✅ 通过 | discard-target.txt 选 bravo-2 替换对→「丢弃选中行…」确认框（文案「丢弃选中的 2 行改动？这个操作无法撤销。」）→点「取消」：SHA 与 diff 完全不变（保护有效）；重新选择并确认丢弃：仅 bravo-2 对恢复原样，bravo-7-丢弃候选乙 保留。证据：`deep/A/a3-02-discard-confirm-dialog.png`、`a3-01-discard-confirm-dialog-ax.txt`、`a-judgments.txt`。附观察 OBS-D-001（确认框默认按钮为破坏性「丢弃」） |
| A4 | ✅ 通过 | 边界选无末尾换行文件 notes/no-eol.txt（delta-3→delta-3-已修改，保持无 \n）。分行暂存替换对后：索引补丁双侧 `\ No newline at end of file` 标记正确；`git cat-file blob :notes/no-eol.txt` 末字节为「改」无换行；工作区字节不变。证据：`deep/A/a-judgments.txt` |

### B 冲突解决与操作恢复

前置说明：Grove 3.0.0(9) 的 GUI 无分支检出/合并入口（更多菜单/侧栏右键/提交右键/分支指示均无），合并冲突状态由 CLI `git merge` 造出作为前置（任务允许），冲突解决、「标记为已解决」、「继续」全部经 Grove GUI 完成与验收。

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| B1 | ✅ 通过 | repo-b1 UU 冲突：Grove 进入「合并中」界面，图例「当前更改：feature（当前分支）／传入的更改：main（正在合入）」与 git 实态一致；「采用当前更改」即时落盘（文件含 feature-改行三、无标记）；「保留双方」两行保留且当前在前；提交区「请先解决所有冲突再提交」保护存在；「继续」后合并提交 dc3748c 双亲为 feature/main 原提交、内容为所选侧、无标记、工作区干净。证据：`deep/B/b1-01-conflict-ui-overview.png`、`b1-01-conflict-ui-ax.txt`、`b-judgments.txt` |
| B2 | ✅ 通过 | 「恢复冲突标记…」撤销块级选择：确认框明确警告「做的所有选择和手工修改都会丢失」，确认后状态回到「1/1 未处理」，磁盘标记恢复（标签变为 ours/theirs，git checkout -m 语义，记 OBS-B-001）。证据：`deep/B/b2-01-restore-markers-dialog.png`、`b-judgments.txt` |
| B3 | ❌ 失败（新前置确认 BUG-002 / #12） | 正常顶部入口对完整冲突块会警告，已截图并取消；GUI刷新到「文件里没有冲突标记」后，外部再写完整块且不刷新，点击下方快捷标记按钮无警告暂存。GUI继续后双亲合并提交 f3b337ad 含完整块，git diff --check HEAD^1 HEAD报告3个残留标记。原GLM孤立行结论仍撤回，Issue按新前置收窄重开。一次完整GUI复现＋正常入口对照，不夸称两次。证据：deep/codex-20261021/b3-valid-marker-warning.*、b3-no-marker-shortcut-before.*、b3-full-block-shortcut-staged.*、parent-oracles.txt |
| B4 | ✅ 通过 | 复用已打开的 repo-b1 以新分支合成第二场冲突（Grove 打开面板后台选择受限，ENV-D-001）：删除/修改冲突呈现为「U base3.txt 当前侧已删除」，提供「删除文件、采用当前更改：feature 删掉了它／保留文件、采用传入的更改：留下 conflict2 修改后的版本」两个明确选项；二进制冲突（含 NUL 真二进制）提示「没法按块合并，只能整个文件选一边」，整文件二选一。选「保留文件(传入)」＋「二进制采用传入」→「继续」：合并提交 863a4c4，base3.txt 保留为 conflict2 版、binary.bin 恰为所选传入版字节（od 核对）、工作区干净。证据：`deep/B/b4-02-conflict-ui-ax.txt`、`b-judgments.txt` |

### C Rebase 与未提交改动保护（索引恢复有原生语义限制）

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| C1 | ✅ 通过 | repo-c topic（T1/T2）GUI 变基对话框：目标 main 预填、☑「自动暂存未提交的改动（--autostash）」默认勾选、明确预告 SHA 全变/冲突时给「跳过/继续/中止」。带**已跟踪**未提交修改（file-b.txt，SHA 2cb5c303…）+ 未跟踪 uncommitted.txt 发起：冲突停在 T1 重放，变基中 CLI 判据 file-b.txt 已回到已提交版（修改被暂存）、rebase-merge 存在、HEAD 停在 c3；「继续」完成后 file-b.txt **字节级恢复（SHA256 一致）**、uncommitted.txt 原样、topic 重放为新 SHA（8445f42/83225f6，父=c3）。注意：恢复不走可见 git stash（stash list 全程为空），记 OBS-C-001。证据：`deep/C/c1-01-rebase-dialog-ax.txt`、`c1-03-second-rebase-conflict-ax.txt`、`c-judgments.txt` |
| C2 | ✅ 通过（内容/refs 恢复；索引限制已核实） | 原 GLM 中止场景缺已跟踪脏改动，接力在 c2gap-topic=cf4c49e 重建真实分叉，file-b 同时有已暂存甲/未暂存乙（MM），另有未跟踪文件。GUI 变基冲突后中止：HEAD/分支恢复原 SHA、冲突状态清除、两个文件 SHA256 与操作前一致。索引边界未保持，两段均成为未暂存。父 Codex 在独立控制 clone 用原生 git rebase --autostash/--abort、同文件 SHA 与分叉复现完全相同行为；因此修正原「索引必须原样恢复」的测试预期，记录 OBS-C-003，不列 Grove 特有缺陷。证据：`deep/codex-20261021/c2gap-aborted-ax.txt`、`c2gap-aborted.png`、`cli-judgments.txt`、`native-autostash-control.txt` |
| C3 | ✅ 通过 | 冲突解决走完整「继续」流程（见 C1）：变基图例语义正确——「当前更改：main（变基目标，HEAD 停在这里）／传入的更改：正在重放的提交 6e7a26b T1 topic 改行三（来自 topic）」，未沿用合并语义的 ours/theirs；「采用传入的更改」后重放提交内容恰为 topic 侧（file-a 行3=topic-改行三）。「跳过」未实测（任务允许二选一）。证据：`deep/C/c3-02-rebase-conflict-detail-ax.txt` |

### D 编辑器与并发修改 ✅ 全部通过

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| D1 | ✅ 通过 | repo-d editor.txt 在 GUI 编辑器打开期间被 CLI 外部追加后点保存：Grove 弹出「文件在磁盘上被修改过」警告（文案明确两侧代价：「覆盖会丢掉那边的新改动;重新加载会丢掉你在这里改的内容」），按钮 覆盖保存（默认）／放弃我的修改，重新加载／取消——**无静默覆盖**。实测「覆盖保存」：磁盘=缓冲区内容（外部行按明示选择丢弃，GUI 行写入）；再次外部修改后选「放弃我的修改，重新加载」：磁盘外部行保留、GUI 未保存行未落盘，编辑器重载为磁盘态（12 行 · 141 字符）。证据：`deep/D/d1-03-external-change-warning.png`、`d1-01/d1-02 AX`、`d-judgments.txt` |
| D2 | ✅ 通过 | 有未保存修改时点「完成」→警告 sheet「继续编辑／不保存并关闭」：继续编辑保留内容（13 行 · 165 字符、横幅保持）；不保存并关闭后磁盘无该行（charlie-14=0）。有未保存修改时点「重新加载」→警告「放弃修改并重新加载／取消」：取消后未保存态保留、磁盘 SHA 不变（5210ef33…全程一致）。与 Issue #11 无重叠（#11 是保存后 diff 刷新，本轮未再复测该旧路径，编辑器保存本身工作正常）。证据：`deep/D/d2-01/d2-03 AX`、`d-judgments.txt` |

### E 工作树与输入边界

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| E1 | ✅ 通过（GPT-6-luna，2026-10-21） | 正常选择已被占用的 wt-occupied-branch，表单明确提示已在 e-wt-occupied 检出并禁用创建；CLI 核对无新增工作树或分支。证据：`deep/codex-20261021/e1-occupied-branch-ax.txt`、`cli-judgments.txt` |
| E2 | ✅ 通过（GPT-6-luna，2026-10-21） | 真实键盘输入 ../bad 并提交，表单保留输入；最近错误面板显示该临时仓库的目标路径及退出码255、`'../bad' is not a valid branch name`。CLI 核对无新增分支、工作树或 ..-bad 目录；操作失败保留表单并非工具阻塞。证据：`deep/codex-20261021/e2-invalid-input-before-create.png`、`e2-invalid-branch-error.png`、同名 `-ax.txt`、`cli-judgments.txt` |
| E3 | ✅ 通过（Codex，2026-10-21） | 正常点击位置框、全选粘贴完整 occupied-dir 路径、Tab 后，界面提示「这个目录已经存在，git 不会在里面创建工作树。」且「创建」禁用。占位文件 SHA256 仍为 fbfb95df…1951b，无 codex-e3-existing 分支/工作树。此前 GLM「静默替换位置」候选属于未生效的自动化输入，排除。截图亦明确起点说明「留空则从 main 开始」，并非无说明。证据：`deep/codex-20261021/e3-existing-dir-protected.png`、同名 `-ax.txt`、`takeover-review.md` |
| E4 | ✅ 通过（GLM 首段＋GPT-6-luna 接力） | GLM 已验证锁定态删除被拒与取消不删目录；接力对脏 wt-e4 取消删除，dirty.txt SHA 与状态不变，再移除该合成脏文件后经 GUI 删除干净工作树。目录/工作树登记消失，默认未勾同时删分支，wt-e4-branch 保留原 SHA。证据：`deep/E/e4-01-delete-dialog-ax.txt`、`deep/codex-20261021/e4-dirty-delete-dialog.png`、`e4-delete-cancelled.png`、`e4-clean-delete-dialog.png`、`cli-judgments.txt` |

### F 标签与推送失败

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| F1 | ✅ 通过（子代理＋父 Codex） | 非HEAD历史标签指向正确，重名禁用；父代理补测非法 bad..tag 报128且无标签写入，合法轻量 qa-cancel-only 取消后未创建。空白等其他格式未外推。证据：deep/codex-20261021/cli-judgments.txt、f1-*、parent-oracles.txt |
| F2 | ✅ 通过（最终父 Codex GUI） | 用新鲜完整AX定位子菜单后，GUI删除repo-f本地v1.0成功，CLI本地tag列表为空，本地bare origin仍保留d857135标签。前面的菜单失效已恢复，不再计阻塞；未用CLI删除替代GUI。证据：deep/codex-20261021/f2-local-tag-deleted.*、parent-oracles.txt |
| F3 | ✅ 通过（父 Codex GUI） | 预置已有origin/main上游，origin改为专用根不存在路径，GUI明确报远端不是仓库；HEAD及上游不变。恢复有效bare路径后同按钮推送完成。另发现无上游的单远端首次推送失败，单列SUP-PUSH-002。证据：deep/codex-20261021/f3-missing-remote-error.*、f3-push-recovered-ax.txt、parent-oracles.txt |

### G 多仓库/页面状态串扰

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| G1 | ✅ 通过（父 Codex GUI，本会话） | repo-a/repo-d同名README内容不同，甲MM、乙仅未暂存；切项目、历史/变更、另一测试工作树后返回，diff、计数、按钮、QA-A/QA-D草稿未串。重启后的草稿另记限制，不混为本项。证据：deep/codex-20261021/g1-*、parent-oracles.txt |
| G2 | ✅ 通过（父 Codex GUI） | 外部追加A-external-refresh，刷新后diff匹配CLI；重选文件、切历史再回均显示新行，索引仍仅A-staged。不能据此宣称保存自动刷新#11已修复。证据：deep/codex-20261021/g2-*、parent-oracles.txt |

### H 遗漏项与体验边界

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| H1 | ✅ 通过（限定仓库/工作树页面恢复） | ⌘Q正常退出，进程查询确认原测试进程结束；完整安装路径重开后恢复repo-f工作树页面、测试仓库列表。历史子标签/筛选/内存草稿未恢复，不声称完整编辑状态恢复，详见OBS-H-001。证据：deep/codex-20261021/h1-* |
| H2 | ❌ 失败（BUG-004 / #14），部分子项通过 | 刷新提交图会显示新作者，但作者菜单缓存不更新；重启恢复，再加作者丙再次复现。已加载作者甲＋foo(bar)正确命中2条，清除恢复5条；为复现再加丙后共6条。45行长说明能展开滚动。路径筛选只有禁用占位入口，未做三条件组合。证据：deep/codex-20261021/h2-*、parent-oracles.txt |
| H3 | ⚪ 未执行（隔离约束） | Daily/Workspace所在配置包含用户真实项目，未重置配置或读取真实项目内容来补测聚合功能；不将未测项记通过。原Daily身份匹配与Workspace空态仍需独立隔离环境 |

### 补充用例（实测中发现）

| ID | 状态 | 关键事实与证据 |
| --- | --- | --- |
| SUP-PUSH-002 | ❌ 失败（BUG-003 / #13） | 唯一有效bare origin、分支无上游时，按钮承诺建立上游却失败；错误要求从不存在的菜单选远端。两次GUI复现，建立上游的成功对照与原生dry-run判据齐全。证据：deep/codex-20261021/push-valid-origin-*、parent-oracles.txt |
| SUP-PLAT-002 | ❌ 失败（BUG-005 / #15） | 同仓库配有有效bare origin且工作树知道地址无法识别，项目评审页却两次误提示没有配置远端。证据：deep/codex-20261021/platform-local-origin-*、remote -v判据 |

## 缺陷与疑点汇总

- 本轮确认4项：BUG-002 / #12（外部写回完整块后的下方快捷入口绕过警告，S3）；BUG-003 / #13（单远端无上游首次推送受阻，S2）；BUG-004 / #14（作者菜单刷新缓存，S3）；BUG-005 / #15（项目页误报无远端，S3）。原#12孤立行误报和撤回仍留档，当前基于新有效前置收窄重开，不把旧用例当有效复现
- 关联旧缺陷：D 组验证保存保护与未保存确认，未重测 Issue #11 的 diff 刷新路径，不新增同根因问题
- 未复现疑点：SUS-001（1 次）——repo-b1 处于外部 CLI 造出的 DU+二进制冲突时，已打开的工作树页卡死在「正在读取工作树…」（Grove 进程 0% CPU，点刷新/切页/重进条目均无效，仅应用重启恢复；重启后同状态正常载入并显示「合并中，有 2 个文件冲突」）。同配方定向复现（重启后会话内再次外部造 DU+二进制冲突→刷新）未复现，刷新立即识别。判定证据不足，不立缺陷，待核实。证据：`deep/B/b4-01-conflict-list.png`（卡死时截图）、`b4-03-repro-refresh-ax.txt`（复现尝试未触发）
- 工具故障记录：ENV-D-001（打开面板后台 NSBrowser 选择/AXOpen/前往快捷键失效，同第一轮 ENV-002/003 类环境限制；repo-b2 放弃新开，复用已打开仓库，非产品缺陷）
- 观察（不立缺陷）：OBS-D-001（丢弃确认框默认按钮为破坏性动作）、OBS-B-001（恢复冲突标记的 ours/theirs 标签）、OBS-C-001（变基 autostash 不产生可见 git stash 条目，stash list 全程为空，仅凭 stash list 为空无法判断恢复实现；已验证「继续」路径字节级恢复，「带跟踪修改时中止」已由接力 C2 补测，索引限制另见 OBS-C-003）、OBS-C-002（变基对话框预告「未提交改动会被自动暂存并在结束后还原」对未跟踪文件不精确——git --autostash 不处理未跟踪文件，实测未跟踪文件原地未动，无数据风险）

## 结论

第二轮可隔离范围已完成并交付。27项中22通过、4失败、1未执行；修复验收分别见#12～#15。合并完整冲突标记的快捷入口和首次推送受阻应优先处理；新作者筛选及项目空态提示也已登记。累计开放确认问题5项（含第一轮#11），没有修改产品源码或提交工程Git。

Daily/Workspace隔离验收、三条件路径组合、真实PR/MR、SSH、AI和真实平台推送不在已通过范围。路径入口为禁用占位；重启恢复只覆盖仓库/工作树页面，内存草稿等子状态另记录。测试交付完成不代表完整发布认证。

编码检查结果：最终新增/修改测试文档均按UTF-8无BOM核对，无替换字符或连续三个问号；原始AX输出保留原样。
