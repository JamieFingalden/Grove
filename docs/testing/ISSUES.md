# Grove 测试问题详细记录

本文件集中记录本轮发现的全部问题，GitHub Issues 保存对外跟踪条目，本地保存完整复现过程和原始证据索引。

- 测试日期：2026-10-20～2026-10-21（Asia/Shanghai）
- 被测版本：3.0.0（9），提交 `8212f60405fd3f0d616c21b35e276ba9f52275ed`
- 测试环境：macOS 27.0.1（26A434），arm64
- GitHub 仓库：https://github.com/JamieFingalden/Grove
- 证据目录：第一轮 `dist/qa/20261020/evidence/`；专项 `dist/qa/20261020/deep/`；接力 `dist/qa/20261020/deep/codex-20261021/`
- 执行者：负责人（Codex computer-use）、ZCode GLM（glm-5.3-flash，computer-use + CLI 判据）、本轮 pi（仅证据审阅，未操作 GUI）
- 范围约束：所有 Git 变更操作只在专用合成测试仓库内执行；未对用户真实项目执行 Git 变更操作（启动恢复/聚合页有只读观察）。
- 接力执行者：2026-10-21 GLM 额度耗尽后由 Codex 审阅、GPT-6-luna 继续真实 GUI；每项署名与覆盖范围见对应报告。

## 2026-10-21 修复进展

五项已确认缺陷均已在本地修复，并通过定向测试和新构建 App 的实机回归。六项修复现已分别提交到本地，尚未推送；GitHub Issues 保持开放。提交对应关系见 [分次提交记录](COMMITS_2026-10-21.md)。详细根因、改动、验收与证据见 [五项缺陷修复与回归报告](FIX_REPORT_2026-10-21.md)。下方原始复现记录保留为历史依据。

## 问题索引

| 本地编号 | 标题 | 类型 | 严重程度 | 状态 | GitHub Issue |
| --- | --- | --- | --- | --- | --- |
| BUG-001 | 内置编辑器保存并完成后 diff 不自动刷新，需手动刷新 | 功能缺陷（确认） | S3 | 本地已提交，未推送 | https://github.com/JamieFingalden/Grove/issues/11 |
| BUG-002 | 已刷新后外部写入完整冲突块，下方快捷入口未复查并无警告地提交 | 功能缺陷（窄范围确认） | S3 | 本地已提交，未推送 | https://github.com/JamieFingalden/Grove/issues/12 |
| BUG-003 | 单远端且分支未设上游时，一键推送失败且没有可选择远端的菜单 | 功能缺陷（确认） | S2 | 本地已提交，未推送 | https://github.com/JamieFingalden/Grove/issues/13 |
| BUG-004 | 历史页刷新后作者筛选列表不更新，需重启应用才能看到新作者 | 功能缺陷（确认） | S3 | 本地已提交，未推送 | https://github.com/JamieFingalden/Grove/issues/14 |
| BUG-005 | 已配置 origin 但无法识别平台时，评审页误报没有远端 | 功能缺陷（确认） | S3 | 本地已提交，未推送 | https://github.com/JamieFingalden/Grove/issues/15 |
| BUG-006 | Release 构建切换全部 PR 后持续加载，结果被归到开放状态 | 功能缺陷（用户发现并确认） | S2 | 本地已提交，未推送 | https://github.com/JamieFingalden/Grove/issues/16 |
| OBS-001 | 历史筛选指示条先于实际过滤出现 | 观察/建议 | S4 | 记录，不立缺陷 | — |
| OBS-002 | 「创建后推送到远端」默认勾选，偏激进 | 观察/建议 | S4 | 记录，不立缺陷 | — |
| OBS-003 | 创建标签对话框不预填版本号 | 观察/待澄清 | S4 | 记录，不立缺陷 | — |
| OBS-004 | 自动 AI Review 触发路径的存在被意外暴露 | 观察 | S4 | 记录，不立缺陷 | — |
| OBS-D-001 | 丢弃选中行确认框的默认按钮为破坏性「丢弃」（回车即执行不可撤销操作） | 观察/建议（第二轮） | S4 | 记录，不立缺陷 | — |
| OBS-B-001 | 「恢复冲突标记」再生成的标记标签为 ours/theirs（git checkout -m 语义），非原 HEAD/main 标签 | 观察（第二轮） | S4 | 记录，不立缺陷 | — |
| OBS-C-003 | 自动暂存的变基中止后，原暂存/未暂存边界不保留；与原生 Git 一致 | 行为限制（第二轮接力） | — | 已核实，不立 Grove 缺陷 | — |
| OBS-H-001 | 正常重启恢复工作树页面，但历史子页、筛选与内存提交草稿未恢复 | 观察/待确认约定 | S4 | 记录，不作为已确认缺陷 | — |
| OBS-H-002 | 路径筛选菜单只有禁用的示例占位，无法执行三条件组合 | 当前功能边界 | — | 未完成该子项，不计通过 | — |
| SUS-001 | 外部造出删除/二进制冲突后曾停在读取工作树，定向复现未再发生 | 待核实 | 未定 | 证据不足，不立缺陷 | — |
| DIST-001 | 开发者签名安装包未公证 | 已知分发限制 | — | 记录 | — |

---

## BUG-001：内置编辑器保存并完成后 diff 不自动刷新（确认缺陷）

- GitHub Issue：https://github.com/JamieFingalden/Grove/issues/11
- 正文存档：`docs/testing/github-issues/BUG-001-editor-stale-diff.md`
- 类型与严重程度：功能缺陷，S3（不丢数据，但显示内容有误导性，可导致错误的暂存/提交决策）。
- 影响范围：已在未暂存普通文本文件追加内容的场景两次复现；其他文件类型和操作范围尚未验证。
- 独立复现次数：2，两名独立执行者。

### 环境
macOS 27.0.1（26A434），arm64；Grove 3.0.0（9）；本地合成仓库（含中文与空格路径），`src/main.txt` 未暂存。

### 前置
文件选中后 diff 显示与 `git diff` 一致（基线：磁盘 5 行，hunk 头 `@@ -1,3 +1,5 @@`）。

### 逐步复现
1. 点 diff 区「编辑」打开内置编辑器（显示行数/字符计数，保存禁用）。
2. 末尾追加一行 → 出现「有未保存的修改」横幅，计数更新，保存启用。
3. 点「保存」→ 横幅消失，保存回到禁用（写入成功）。
4. 点「完成」关闭编辑器，不刷新，立即观察 diff。
5. 点工具栏「刷新」，再观察。

### 预期 / 实际
- 预期：保存后（最迟关闭编辑器时）diff 自动重算，与 `git diff` 一致。
- 实际（第 4 步）：diff 仍为旧 hunk 头与旧行内容，不含新增行；同刻 CLI 核实磁盘与 `git diff` 均已含新增行（真实 hunk 头已变）。第 5 步点刷新后 diff 立即更新为真实内容。

### 两次复现证据
| 次序 | 执行者 | 刷新前 | 刷新后 |
| --- | --- | --- | --- |
| 第 1 次 | 负责人（ui-07/ui-08） | `@@ -1,2 +1,3 @@`，缺「分行测试甲/乙」两行 | `@@ -1,2 +1,5 @@`，两行出现 |
| 第 2 次 | ZCode GLM（glm-editor-repro 系列） | `@@ -1,3 +1,5 @@`，缺「分行测试丙」行；CLI 同刻真实 hunk 为 `@@ -1,3 +1,6 @@` | `@@ -1,3 +1,6 @@`，丙行出现 |

证据文件：
- 第 1 次：`ui-07-editor-stale-diff-before-refresh.txt`、`ui-08-editor-diff-after-refresh.txt`、`ui-07-editor-stale-diff-before-refresh.png`、`ui-08-editor-diff-after-refresh.png`、`git-07-editor-diff.txt`（git 实态）。
- 第 2 次：`glm-editor-repro.md`、`glm-editor-repro-verify.txt`、`glm-editor-repro-1-stale-diff.png`、`glm-editor-repro-2-after-refresh.png`（本轮 pi 已逐张核对图片内容与文字证据一致）。

### 修复验收条件
1. 保存成功返回后，该文件工作区 diff 自动更新，与 `git diff` 的 hunk 头和行内容一致；
2. 不依赖用户手动刷新；
3. 回归步骤同上（追加一行 → 保存 → 完成 → 立即读 diff 即含新增行）。

---

## OBS-001：历史筛选指示条先于实际过滤出现（观察/建议，S4）

- 现象：历史页搜索框键入过程中，「已筛选：包含「foo(bar)」」指示条先行出现，而列表需按回车才实际过滤，二者状态短暂不一致。
- 归属：ZCode GLM 轮观察（`glm-hist-result.md` 附注）。仅单次现象，未独立复现，不抬为确认缺陷。
- 建议：指示条与列表实际过滤状态同步，或改为输入即过滤。

## OBS-002：「创建后推送到远端」默认勾选（观察/建议，S4）

- 现象：创建标签对话框中「创建后推送到远端」默认勾选，本地测试场景需手动取消；对有远端的真实仓库存在误推风险。
- 归属：ZCode GLM 轮观察（`glm-chg-tag-result.md` 附注）。建议项，不立缺陷。

## OBS-003：创建标签对话框不预填版本号（观察/待澄清，S4）

- 现象：标签名输入框为空；旧用例预期「自动预填下一个版本号」。
- 判断：可能与测试仓库无语义版本标签有关，未核实实现与产品约定，暂不定性；不单凭旧用例预期创建缺陷。
- 归属：ZCode GLM 轮观察（`glm-chg-tag-result.md` 附注）。

## OBS-004：自动 AI Review 触发路径被意外暴露（观察，S4）

- 现象：工作树删除失败错误处理期间，顶部出现「自动 AI Review 检查失败」通知横幅，说明存在自动触发 AI Review 的路径。
- 归属：ZCode GLM 轮记录（`glm-wt-004-result.txt` 附注）。本轮不操作 AI 功能，仅记录；是否为预期行为待产品确认。

---

## DIST-001：开发者签名安装包未公证（已知分发限制，非功能缺陷）

- 复现：`spctl --assess --type execute --verbose=2 dist/Grove.app` → 退出码 3，`rejected`。
- 对照：可访问系统信任服务的执行环境中 `codesign --verify --deep --strict --verbose=2` 退出 0（valid on disk、satisfies its Designated Requirement）。
- 结论：签名完整可验证；spctl 拒绝是未公证的分发限制，不等同签名无效，也不等同本机不能运行（本机 GUI 启动正常）。未做干净 Mac 下载隔离属性场景验收。证据：`package-checks.md`、`build.log`。

## 环境记录（非产品缺陷）

- ENV-001：沙箱内 `codesign` 返回 `CSSMERR_TP_NOT_TRUSTED`，放行系统信任服务后通过——执行环境限制。
- ENV-002：自动化向「前往文件夹」弹窗发送 `Return` 不稳定，`KP_Enter` 可用——UI 自动化工具适配记录。
- ENV-003：REPO-003 本轮 GUI 重复执行受限于宿主键盘焦点、Spotlight 不索引 `/private/tmp`、NSBrowser 不支持 AXPress——已用组合判据（负责人真非仓库 GUI + 本轮 doctor 负例）完成判定，详见报告矩阵。

## 后续每个确认问题须包含

本地编号、GitHub 链接、类型与严重程度、影响范围、前置数据、逐步复现、预期结果、实际结果、独立复现次数、原始证据、修复验收条件及当前状态。仅代码阅读推断和未执行用例不能记为确认缺陷。

---

## BUG-002：已刷新后外部写入完整冲突块，下方快捷入口未复查（S3，确认缺陷）

> 复核历史：早先的孤立 `<<<<<<<`／`>>>>>>>` 行测试不构成完整冲突块，且只证明标记进入暂存区、没有证明其完成合并提交。该普遍性缺陷判定已撤回，Issue #12 曾关闭。本节保留该误报历史；最新窄范围缺陷由完整冲突块、正常入口警告对照及真实双亲合并提交证据支持，故已更正文案并重开原 Issue #12。没有修改产品源码。

- GitHub Issue：https://github.com/JamieFingalden/Grove/issues/12
- 正文存档：`docs/testing/github-issues/BUG-002-conflict-marker-resolved-bypass.md`
- 类型与严重程度：功能缺陷，S3。已刷新并进入无标记快捷视图后，外部再次写入完整冲突块时，下方快捷入口不重查磁盘，能无警告地暂存并提交含标记的合并内容。
- 影响范围：仅验证了外部修改发生在 Grove 刷新之后、且使用无标记状态下方快捷「标记为已解决」入口的路径。顶部常规入口对完整冲突块会警告；不外推为所有入口失效。
- 实机复现次数：1 次完整定向 GUI 复现，另有顶部正常入口保护对照。未重复破坏性提交。

### 前置与复现

在合成 repo-b1 分支 `qa-marker-guard` 上，从 `55993c6decde3743ffa4c760956361b35fb08dfc` 合并 `main`（`2a9266b449597e8a9acdf1e8994499bfa6e85b85`），`base.txt` 为 UU 且 `MERGE_HEAD` 存在。初始完整冲突块经顶部常规冲突标记入口时弹出“文件里还有 1 处冲突标记”警告；取消后保持冲突状态。GUI 点「采用当前更改」，CLI 追加普通「外部解决补充行」，再于 Grove 冲突文件视图点击「刷新」。界面进入“文件里没有冲突标记”状态并显示下方快捷入口。

随后从外部向磁盘文件追加完整块（`<<<<<<< external-full-block`、当前内容、`=======`、传入内容、`>>>>>>> external-full-block`），不刷新 Grove。`git diff --check` 报告三处 leftover conflict marker。点击**下方快捷**「标记为已解决」（不是顶部常规入口）后没有警告，横幅提示冲突已解决并将含块文件暂存；点击「继续」完成双亲合并提交。

### 预期与实际

- 预期：所有标记为已解决入口都重新读取磁盘并使用一致保护；发现完整冲突块时提示警告，只有用户明确确认仍保留标记才可继续。正常解决路径仍可完成合并。
- 实际：下方快捷入口未读取外部新写入的完整块，无警告地标记解决；合并提交 `f3b337ad71cb2403086a4f8324319292e98df211` 的 parents 为 `55993c6decde3743ffa4c760956361b35fb08dfc` 与 `2a9266b449597e8a9acdf1e8994499bfa6e85b85`。`git show HEAD:base.txt` 保留完整块；`git diff --check HEAD^1 HEAD` 报告三处 leftover conflict marker。
- 正常入口对照：顶部常规入口显示包含“现在标记为已解决，这些标记会原样进入提交”的警告；选择取消后 UU 状态保持。

### 证据

- `dist/qa/20261020/deep/codex-20261021/b3-valid-marker-warning.png`、`b3-valid-marker-warning-ax.txt`：顶部常规入口的完整块警告。
- `dist/qa/20261020/deep/codex-20261021/b3-no-marker-shortcut-before.png`、`b3-no-marker-shortcut-before-ax.txt`：刷新后无标记视图及下方快捷入口。
- `dist/qa/20261020/deep/codex-20261021/b3-full-block-shortcut-staged.png`、`b3-full-block-shortcut-staged-ax.txt`：下方快捷入口无警告标记解决，GUI diff 同屏保留完整块。
- `dist/qa/20261020/deep/codex-20261021/parent-oracles.txt`：UU、`MERGE_HEAD`、外部标记检测、真实提交 SHA/parents、提交文件内容及提交后 diff-check 的 CLI 判据。
- `dist/qa/20261020/deep/codex-20261021/issue12-withdrawn-body-before-narrow-repro.md`：本轮收窄前 Issue 正文副本，保留误报撤回记录。
- 原始孤立标记误报证据仍保留：`dist/qa/20261020/deep/B/b3-01-mark-resolved-with-markers-ax.txt`、`b3-02-second-repro.png`、`b3-02-second-repro-ax.txt`、`b-judgments.txt`；这些不作为新缺陷的复现证据。

### 修复验收

1. 上方常规入口与无标记状态下方快捷入口统一重新读取文件，并对完整冲突标记执行一致的警告保护。
2. 刷新后由外部写入完整块再点下方快捷入口，应有警告而非静默暂存；只有明确确认后才允许按产品定义继续。
3. 正常采用一侧或编辑删除标记后仍能正常标记解决并完成双亲合并。

## 第二轮观察补充

- OBS-D-001：A3 丢弃确认框默认按钮（高亮/回车触发）为破坏性「丢弃」，文案「这个操作无法撤销。」已明示，但默认动作建议为「取消」。证据：`dist/qa/20261020/deep/A/a3-02-discard-confirm-dialog.png`。
- OBS-B-001：「恢复冲突标记…」后磁盘标记标签变为 `<<<<<<< ours`／`>>>>>>> theirs`（`git checkout -m` 再生成语义），与首次合并的 `HEAD`／`main` 标签不同；界面图例仍正确显示当前/传入分支，不影响解决，仅记录。

## 接力审阅：已排除的缺陷候选（2026-10-21）

- 「工作树创建位置被静默替换」：原 GLM 自动化设置字段后，新路径未进入实际编辑状态。Codex 用正常键盘全选、粘贴完整现有目录路径并 Tab 后，界面明确提示目录已存在并禁用创建；占位文件 SHA 不变、无新分支或工作树。因此排除该候选，不发布 Issue。原 E3 候选证据保留；复核证据：`deep/codex-20261021/e3-existing-dir-protected.png`、`takeover-review.md`。
- 「起点留空却无说明地采用 main」：同一截图实际明确显示「留空则从 main 开始。可填分支名、标签或提交 SHA。」，属于 AX 未展示的可见说明，不是已确认产品缺陷。

## OBS-C-003：变基自动暂存后暂存边界不保留（原生行为限制）

- 前置：repo-c 的独立合成分叉，原 HEAD 为 cf4c49e、变基目标 main 为 746b3cc；同一已跟踪文件一行已暂存、一行未暂存（MM），还有一个未跟踪文件。
- GUI 路径：默认勾选 --autostash 开始变基，确实进入同行冲突，再点击「中止」。
- 实际：原分支与 HEAD 恢复，变基状态清除；已跟踪文件、未跟踪文件的 SHA256 全部恢复。原先两段都落入未暂存区，cached diff 为空。
- 对照：Codex 在专用根下另外建立独立 clone，用同样的分叉和文件内容执行原生 git rebase --autostash，再 git rebase --abort；前置 MM 与 SHA 一致，结束同样变为 M（仅未暂存），文件内容没有丢失。
- 判定：不能把「暂存边界未保持」单独归为 Grove 的恢复缺陷；原测试计划中的索引必须原样恢复预期过强，现明确改为内容/refs 恢复验收、索引语义单列记录。使用者若依赖原暂存分组，应在操作后重新检查暂存区。
- 证据：`dist/qa/20261020/deep/codex-20261021/cli-judgments.txt`、`c2gap-aborted.png`、`native-autostash-control.txt`（原生对照完整命令、输出与 SHA256）。

## BUG-003：单远端且分支未设上游时，一键推送失败且没有可选择远端的菜单（确认缺陷）

- GitHub Issue：https://github.com/JamieFingalden/Grove/issues/13
- 正文存档：`docs/testing/github-issues/BUG-003-single-remote-first-push.md`
- 类型与严重程度：功能缺陷，S2（单远端仓库的首次推送主流程被阻断；可用显式 CLI 命令绕过）。
- 被测版本：Grove 3.0.0（9），macOS 27.0.1（26A434），arm64；构建源码 HEAD `8212f60405fd3f0d616c21b35e276ba9f52275ed`。
- 独立定向复现：2 次 GUI 失败；另有建立上游后的 GUI 成功对照。
- 测试数据全部在 `/private/tmp/grove-deep.R2SGP6`，远端是本地 bare 仓库；不涉及网络、账户或真实项目。

### 前置

repo-f 的本地 `main` 有提交 `eb2affa878c8cbfac444bf22ca69ec12c1d7f474`。唯一远端 `origin` 指向 `/private/tmp/grove-deep.R2SGP6/remotes/repo-f-origin.git`，该 bare 仓库已有同 SHA 的 `refs/heads/main`。本地未配置 `branch.main.remote` 或 `branch.main.merge`，Grove 刷新后显示“未设上游”，按钮帮助文字为“推送并建立上游跟踪”。`push.autoSetupRemote` 未启用。

### 逐步复现

1. 在 Grove 打开合成 repo-f 主工作树，确认唯一有效 bare `origin`、分支 `main` 无上游。
2. 点工具栏唯一的「推送」按钮。
3. 查看最近错误，并用 CLI 核对本地分支、上游配置与 bare 远端引用。
4. 重置到同一无上游前置后，由第二次 GUI 操作复现。
5. 作为成功对照，在合成仓库暂时建立 `main` 到 `origin/main` 的上游后点同一按钮，GUI 显示推送完成；删除 `branch.main.remote` 与 `branch.main.merge` 并刷新，再点按钮复现失败。

### 预期 / 实际

- 预期：唯一远端明确且远端已有同名分支时，按钮应向该远端推送当前分支并设置上游；若不能自动选取，界面应提供真实可用的远端选择入口。
- 实际：两次均显示“推送失败”及 Git 128 错误 `The current branch main has no upstream branch.`。Grove 提示用户从推送按钮菜单选择目标远端并指出首次推送会自动建立关联，但单远端状态下界面只有普通按钮、没有该菜单；失败后上游仍未设置，本地 HEAD 与 bare `origin/main` SHA 均未变化。
- 成功对照：仅将合成 `main` 配置为跟踪 `origin/main` 后，Grove 同一按钮推送完成。移除该上游配置、刷新后再次失败，说明 bare 远端有效，故障跟无上游首次推送路径相关，而非远端路径无效。

### CLI 对照与证据

在相同的有效 bare origin、无 `branch.main.remote` / `branch.main.merge` 前置下，原生 `git push --dry-run --set-upstream` 也退出 128，并给出显式命令建议 `git push --set-upstream origin main`。本地 HEAD 与 bare `refs/heads/main` 均为 `eb2affa878c8cbfac444bf22ca69ec12c1d7f474`，状态干净，未发生远端更新。此判据说明当前 Git 环境下单独传 `--set-upstream` 仍不足以推送；预期修复需明确指定远端和分支，或为单 remote 的按钮提供可选目标。

源码定位仅用于解释界面路径：`Sources/Grove/Views/WorktreeDetailView.swift` 的 `pushControl` 只在远端数量大于一时显示选择菜单；单远端按钮调用 `model.push()`，未显式传 remote。实际 GUI 与原生 Git 对照是确认依据。

| 证据 | 内容 |
| --- | --- |
| `dist/qa/20261020/deep/codex-20261021/push-valid-origin-no-upstream-ax.txt`、`push-valid-origin-no-upstream.png` | 第一次有效 bare origin、无上游的 GUI 前置与按钮状态 |
| `dist/qa/20261020/deep/codex-20261021/push-valid-origin-no-upstream-error-ax.txt`、`push-valid-origin-no-upstream-error.png` | 第一次推送错误与无远端菜单状态 |
| `dist/qa/20261020/deep/codex-20261021/push-valid-origin-repro2-error-ax.txt`、`push-valid-origin-repro2-error.png` | 第二次 GUI 定向复现 |
| `dist/qa/20261020/deep/codex-20261021/f3-push-recovered-ax.txt` | 建立上游后的 GUI 成功对照 |
| `dist/qa/20261020/deep/codex-20261021/parent-oracles.txt` | 两次复现的 remote、branch 配置、HEAD、bare SHA、原生 dry-run 及恢复对照原始输出 |

### 修复验收

1. 唯一远端、当前分支无上游、同名远端分支已存在时，GUI 推送成功并正确设置上游。
2. 同时覆盖远端尚无该分支的首次发布，不要求用户先修改全局 Git 配置。
3. 已有上游与多个远端时维持正确目标，不意外更改现有跟踪关系。
4. 错误提示不再引导用户寻找界面没有提供的远端菜单。

## BUG-004：历史页刷新后作者筛选列表不更新（确认缺陷）

- GitHub Issue：https://github.com/JamieFingalden/Grove/issues/14
- 正文存档：`docs/testing/github-issues/BUG-004-history-author-cache.md`
- 类型与严重程度：功能缺陷，S3（提交图已刷新但筛选项仍是旧缓存；不修改 Git 数据，重启应用可恢复）。
- 被测版本：Grove 3.0.0（9），macOS 27.0.1（26A434），arm64；固定安装副本、合成测试仓库。
- 定向复现：2 次外部新增作者后 GUI 刷新；首次另有退出并重新打开后的恢复对照。

### 现象与判据

第一次测试中，仓库原有作者「测试者」2 条。外部新增作者甲 2 条、作者乙 1 条后，在 Grove 历史页点击工具栏「刷新」：提交图已显示这 3 条新提交，但展开的作者菜单仍只有「测试者」2 条。正常退出并重新打开 Grove 后，作者菜单才更新。

第二次重启后，作者菜单已有甲 2 条、测试者 2 条、乙 1 条。外部 CLI 新增作者丙的提交 `066b0555240dd8fa3aab80e55c5f05a1f0d63514`，再次点击「刷新」后，AX 和截图均显示提交图出现「作者缓存复现丙」，但作者菜单仍只有甲、测试者和乙。CLI `git shortlog -sne HEAD` 显示四位作者、共六条提交。两次均表明刷新提交图没有同步刷新作者筛选数据；重启能恢复。

### 证据

- `dist/qa/20261020/deep/codex-20261021/h2-authors-after-manual-refresh.png`：第一次刷新后的提交列表与仍过期的作者菜单。
- `dist/qa/20261020/deep/codex-20261021/h2-author-c-visible-in-history.png`、`h2-author-c-missing-menu.png`：第二次刷新后丙的提交出现在历史图中，但展开菜单未列出丙。
- `dist/qa/20261020/deep/codex-20261021/h2-new-author-c-commits-ax.txt`：AX 确认历史列表包含 `066b055`。
- `dist/qa/20261020/deep/codex-20261021/parent-oracles.txt`：作者、邮箱、提交数及完整 SHA 的 CLI 判据。

### 修复验收

在历史页打开期间从外部新增不同作者的提交并点击工具栏刷新，作者菜单应立即更新作者及计数；选择新作者应正确筛出其提交，且不需要重启 Grove。

## BUG-005：已配置 origin 但平台未识别时，评审页误报没有远端（确认缺陷）

- GitHub Issue：https://github.com/JamieFingalden/Grove/issues/15
- 正文存档：`docs/testing/github-issues/BUG-005-local-origin-empty-state.md`
- 类型与严重程度：功能缺陷，S3（Git 远端已存在，但项目页把平台无法识别误报为未配置远端，可能诱导用户重复添加）。
- 被测版本：Grove 3.0.0（9），macOS 27.0.1（26A434），arm64；专用合成仓库 repo-f。
- 定向复核：两次项目页读取/刷新；只读 `git remote -v` 确认有效本地 bare `origin`。

### 现象与判据

在已配置 `origin`、地址指向有效本地 bare remote 的 repo-f 中，工作树页推送按钮帮助显示“无法识别 origin 的地址”。打开「评审请求」页却显示“还没接入这个平台 / 这个仓库没有配置远端。”工具栏刷新以及重新进入项目页后结果一致。只读 `git remote -v` 确认 fetch 与 push URL 均存在且指向该本地 bare remote。因此问题是平台识别状态被描述成远端缺失，而不是 Git 仓库未配置远端。

### 证据

- `dist/qa/20261020/deep/codex-20261021/platform-local-origin-project.png`：项目页错误空状态文案。
- `dist/qa/20261020/deep/codex-20261021/platform-local-origin-project-ax.txt`、`platform-local-origin-project-repro2-ax.txt`：两轮刷新/重入项目页后的 AX 文案。
- `dist/qa/20261020/deep/codex-20261021/platform-local-origin-worktree-ax.txt`：工作树页同一仓库识别到 origin 配置但无法识别其平台地址。
- `dist/qa/20261020/deep/codex-20261021/parent-oracles.txt`：专用仓库 remote 配置的 CLI 原始判据。

### 修复验收

对于存在 Git 远端但托管平台无法识别的仓库，项目页应明确显示远端已配置、平台未识别或不受支持；只有 remote 为空时才显示“没有配置远端”。刷新和重新进入项目页后仍应正确区分两种状态。

## OBS-H-001：正常重启后的状态恢复范围

- 2026-10-21 父 Codex GUI 在 repo-f 历史页使用作者/字面量筛选后，正常 ⌘Q 退出并重开固定安装副本；测试仓库列表与 repo-f 工作树选择恢复，默认显示变更页，历史子标签和筛选没有恢复。
- 重开 repo-a 时，先前本会话的 QA-A-DRAFT 提交草稿为空；该草稿在重启前跨项目与工作树切换时确实保留。测试文件和暂存内容未因此丢失，提交草稿与文件编辑内容必须区分。
- 尚未确认产品是否承诺跨启动持久化这些子状态，故作为观察，不将它误写成完整状态恢复通过，也不直接当数据丢失缺陷登记。
- 证据：`deep/codex-20261021/h1-before-quit-ax.txt`、`h1-after-relaunch-ax.txt`、`h1-after-relaunch.png`、`h1-restarted-repo-a-draft-ax.txt`、重启前 `g1-repo-a-after-worktree-ax.txt`。

## OBS-H-002：路径筛选子项无法执行

- 父 Codex GUI 在 repo-f 历史页叠加已载入的作者甲与字面量 foo(bar)，结果2条，与合成数据一致；点过滤菜单后只有禁用的「限定路径」与「src/app.swift」示例项，没有可输入本轮 filter.txt 的入口。
- 因此只验证作者＋字面量，不声称作者＋路径＋字面量三条件组合通过。没有将产品未提供的入口自动列为功能缺陷。
- 证据：`deep/codex-20261021/h2-path-filter-unavailable.png`、`h2-author-and-literal-ax.txt`、`parent-oracles.txt` 中该组合本应命中1条的 CLI 判据。

## SUS-001 与其他专项观察

- SUS-001：GLM 初次在已打开 repo-b1 外部合成删除/修改与二进制冲突后，页面曾停在「正在读取工作树」，刷新、切页和重进条目未恢复；正常重启后同状态可以加载。之后按相同配方在会话内重造冲突再刷新，没有复现。保留待核实，不定为卡死缺陷。证据：`deep/B/b4-01-conflict-list.png`、`b4-01-conflict-list-ax.txt`、`b4-03-repro-refresh-ax.txt`。
- OBS-C-001：自动暂存期间 stash list 为空，不能仅据此判断恢复实现；继续与中止后的文件内容已用 SHA 核对，索引语义见 OBS-C-003。
- OBS-C-002：变基提示笼统描述未提交改动被暂存；实测未跟踪文件保持原地且字节不变。只是提示的边界说明，不等同丢失未跟踪文件。
- 工具记录：菜单 AX 索引失效与读取超时曾影响接力；父 Codex 切换到访达后重读 Grove 恢复，并最终用新鲜完整 AX 定位子菜单完成本地标签删除。不能把早先未成功触发的点击计作删除成功，也不能仅从工具超时推断 Grove 崩溃。诊断 sample 保存在 `deep/codex-20261021/grove-ui-timeout-sample.txt`；该次主线程主要处于事件循环，未证实产品挂死。

---

## BUG-006：Release 构建切换全部 PR 后持续显示加载中

- 用户发现日期：2026-10-21。
- GitHub Issue：https://github.com/JamieFingalden/Grove/issues/16。
- 严重程度：S2，历史列表无法完成展示；开放列表能正常展示。
- 环境：macOS 27.0.1 arm64，签名 Release 3.0.0（9），实际 Grove 仓库项目页，全部查询应返回 10 条历史 PR。
- 复现：进入开放空列表 → 点击“查看全部”或选择全部 → 子进程结束后仍显示加载中；点击刷新仍重复。
- 判据：相同 CLI 查询约 3.953 秒返回 10 条。App 的请求为 all，但两个并发结果都标记为 open，请求编号/地址/筛选校验均通过、未取消，最终 hasLoadedPullRequests=false。
- 修复：异步任务显式捕获筛选值，先完成查询，再组装带筛选标识的返回值，修正发布构建中的结果归类路径。
- 回归：6 项 Release 定向测试全部通过；移除临时追踪后重建的最终 App 实机验证开放、全部（10 条）、已合并（8 条）、已关闭均完成加载。
- 当前 App：`dist/Grove.app`；SHA-256 `81f3018f1c00a4b8a9c1134f17e935290ea6825e57c9a68dde1d7df9c80898cf`。本地已提交，未推送；Issue 保持开放。
- 详细修复及证据：[PR 加载修复报告](PR_PERFORMANCE_2026-10-21.md)；原始日志与界面证据 `dist/qa/20261021/pr-performance/`。

## 测试项目清理进展

本轮已从侧边栏移除 8 个测试项目，并删除对应合成仓库、工作树、bare、重复 App、本轮 DMG 和重复 worker 产物，回收约 90.9 MiB；真实项目保留。报告和必要证据已归档，后续只维护 `dist/Grove.app`。详见 [清理记录](CLEANUP_2026-10-21.md)。
