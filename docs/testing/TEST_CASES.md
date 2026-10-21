# Grove 3.0.0 验收测试用例

所有用例当前状态均为**待执行（GUI）**，由**具备真实电脑控制能力（computer-use）的执行者**
实际操作界面产生结果，可以是 Claude Code、pi、ZCode 等代理或人工测试者；没有电脑控制能力
的执行者只做造数、诊断与事后证据审阅，不得假装执行 GUI。不同执行者可以分批接力，
产物分别署名（`<执行者前缀>-<用例ID>-…`）。本文件不含 GUI 结果，最终 PASS/FAIL 在证据核对后
写入 `TEST_REPORT_<日期>.md`。

测试数据统一由 `scripts/qa-local.sh` 生成。测试根目录默认在 `/private/tmp/grove-qa-local/` 下
按时间戳独立成轮（工程与任何仓库之外，保证非仓库负例有效）；新一轮测试用绝对路径指定：

- 测试根目录：`--test-root <绝对路径>`（下称「测试根」）
- 测试仓库：`…/testroot/格罗夫 测试仓库`（下称「测试仓库」）
- 非仓库目录：`…/testroot/不是仓库`（必须在独立测试根内，任何仓库之外）
- 证据目录：`<artifacts>/evidence/`（命令行指定，与旧轮次隔离）

每条用例的证据 = GUI 执行者保存的 AX 文本（`steps.txt` / `result.txt` 或等效 AX 抓取）+ 截图（`*.png`），
再由 CLI 执行者附上判据命令的真实输出（`verify.txt`）。

---

## INST 安装与启动

### INST-001 打包产物签名与本机事实核对
- 优先级：P0
- 前置条件：`/tmp/grove-repackage-20261020.log` 含「App 构建完成」；本轮二进制已就位。
- UI 操作：GUI 执行者在 Finder 显示 `dist/Grove-3.0.0.dmg` 与 `dist/Grove.app`，打开「显示简介」核对版本。
- 预期行为：版本显示 3.0.0（build 9）；无 Gatekeeper 拦截弹窗（本机 Apple Development 签名）。
- Git/文件系统判据：`codesign -dv dist/Grove.app` 有 Signature；`plutil -p dist/Grove.app/Contents/Info.plist | grep -E 'ShortVersion|BundleVersion'` 输出 3.0.0 / 9；二进制 mtime 为本轮。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `INST-001-`）
- 状态：待执行（GUI）

### INST-002 DMG 挂载与拖装（允许 `hdiutil` + `ditto` 变通安装到测试目录，但必须如实注明未做 Finder 拖装）
- 优先级：P0
- 前置条件：INST-001 通过。
- UI 操作：双击 `dist/Grove-3.0.0.dmg` 挂载，将 Grove.app 拖入 Applications（或按窗口提示）。
- 预期行为：挂载成功，复制完成无报错；弹出的窗口含 Grove.app 与目标目录。
- Git/文件系统判据：`hdiutil info` 列出该 DMG；`/Applications/Grove.app` 存在（若GUI 执行者选择安装到 /Applications）。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `INST-002-`）
- 状态：待执行（GUI）

### INST-003 首次启动
- 优先级：P0
- 前置条件：INST-002 完成。
- UI 操作：由 GUI 执行者从 Finder / 启动台打开 Grove.app。
- 预期行为：主窗口出现，无崩溃、无持续报错弹窗；侧边栏出现 Daily / Workspace / Repositories 导航。
- Git/文件系统判据：`pgrep -x Grove` 有进程；崩溃日志目录 `~/Library/Logs/DiagnosticReports/` 本轮无 Grove 新报告。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `INST-003-`）
- 状态：待执行（GUI）

## REPO 仓库管理

### REPO-001 打开测试仓库
- 优先级：P0
- 前置条件：INST-003 通过；`qa-local.sh` 已执行，测试仓库存在。
- UI 操作：通过界面「添加/打开仓库」选择 `/Users/jamie/Documents/code/tools/Grove/dist/qa/20261020/testroot/格罗夫 测试仓库`。
- 预期行为：项目出现在侧边栏；主工作树显示分支 `main` 与未提交改动计数（≥3 处）。
- Git/文件系统判据：`git -C "测试仓库" status --porcelain` 恰好 3 行（1 行已暂存 `M `、1 行未暂存 ` M`、1 行 `??`）；`git -C "测试仓库" remote` 输出 `origin`、`backup`。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `REPO-001-`）
- 状态：待执行（GUI）

### REPO-002 重复打开同一仓库
- 优先级：P1
- 前置条件：REPO-001 通过。
- UI 操作：再次通过界面打开同一测试仓库路径。
- 预期行为：不出现重复项目条目；已有条目状态保持，无报错。
- Git/文件系统判据：测试根目录内文件列表与打开前一致（无新建目录）；侧栏仅一个该项目。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `REPO-002-`）
- 状态：待执行（GUI）

### REPO-003 打开非仓库目录报错
- 优先级：P0
- 前置条件：`…/testroot/不是仓库` 目录存在（空目录，非 git）。
- UI 操作：通过界面尝试打开该目录。
- 预期行为：界面给出明确的「不是 git 仓库」类错误提示，不崩溃、不添加项目。
- Git/文件系统判据：该目录内无 `.git`（`test -d "…/不是仓库/.git" && echo FAIL` 不输出 FAIL）。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `REPO-003-`）
- 状态：待执行（GUI；CLI 参照：本轮 `logs/doctor-不是仓库.log` 已含「不是 git 仓库。」；
  注意负例必须位于独立测试根内，否则会被 git 向上解析到外层仓库而失效）

## CHG 变更与 diff

### CHG-001 变更列表五类状态齐全
- 优先级：P0
- 前置条件：REPO-001 通过。
- UI 操作：进入测试仓库的「变更」页，逐个点开文件查看 diff。
- 预期行为：列表含「已暂存」`README.md`、「未暂存」`src/main.txt`、未跟踪 `notes/待办.txt`；中文与空格路径显示无乱码；二进制 `assets/logo.bin`（已在历史提交中，见 CHG-002 注）不按文本 diff 渲染。
- Git/文件系统判据：与 `git -C "测试仓库" status --porcelain` 逐行对齐；`git -C "测试仓库" diff --name-only` 仅 `src/main.txt`；`git -C "测试仓库" diff --cached --name-only` 仅 `README.md`。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `CHG-001-`）
- 状态：待执行（GUI）

### CHG-002 diff 正确处理重命名与二进制历史
- 优先级：P1
- 前置条件：REPO-001 通过。
- UI 操作：打开历史中「重命名 app.txt 为 main.txt」与「添加二进制图标资源」两个提交的 diff。
- 预期行为：重命名提交显示为 rename（`src/app.txt → src/main.txt`）而非删除+新增；二进制提交不渲染乱码文本，显示二进制标识。
- Git/文件系统判据：`git -C "测试仓库" show --name-status --format= 重命名提交SHA` 首列为 `R`；`git -C "测试仓库" show --numstat --format= 二进制提交SHA` 对 `assets/logo.bin` 显示 `- -`。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `CHG-002-`）
- 状态：待执行（GUI）

## STG 暂存与提交

### STG-001 暂存
- 优先级：P0
- 前置条件：CHG-001 通过。
- UI 操作：对未暂存的 `src/main.txt` 执行「暂存」。
- 预期行为：该文件移入「已暂存」栏；未跟踪文件不受影响。
- Git/文件系统判据：`git -C "测试仓库" status --porcelain` 中 `src/main.txt` 变为已暂存状态；`git diff --name-only` 为空。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `STG-001-`）
- 状态：待执行（GUI）

### STG-002 取消暂存
- 优先级：P0
- 前置条件：STG-001 通过。
- UI 操作：对已暂存的 `src/main.txt` 执行「取消暂存」。
- 预期行为：回到「未暂存」栏，改动内容不丢失（diff 内容与 STG-001 前一致）。
- Git/文件系统判据：`git status --porcelain` 中该文件回到未暂存；文件内容仍含第二段修改文本（`grep -F "第二段修改" src/main.txt` 命中）。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `STG-002-`）
- 状态：待执行（GUI）

### STG-003 提交
- 优先级：P0
- 前置条件：STG-002 通过；界面测试身份可用。
- UI 操作：暂存 `README.md`（或界面内重新暂存），填写提交信息「GUI 验收：提交测试」，执行提交。
- 预期行为：提交成功，已暂存栏清空，历史出现新提交；写一半的提交信息切换工作树不丢失（顺带观察）。
- Git/文件系统判据：`git -C "测试仓库" log -1 --format='%s|%an|%ae'` 与界面输入一致；作者邮箱为测试身份 `zhangsan@test.local`（仓库本地配置），**不是**用户全局身份；提交后 `git status` 不再含 `README.md`。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `STG-003-`）
- 状态：待执行（GUI）

## LSTG 分行暂存

### LSTG-001 行级勾选暂存
- 优先级：P1
- 前置条件：STG-003 通过；工作区有含 ≥2 行改动的未暂存文件。
- UI 操作：造数补充——在 `src/main.txt` 追加三行不同文本（由 GUI 执行者在界面编辑，或由 CLI 执行者事先备好）；在 diff 中只勾选其中一行，执行「暂存选中行」。
- 预期行为：仅选中行进入暂存区；diff 查看器中同一文件同时出现在已暂存（1 行）与未暂存（其余行）。
- Git/文件系统判据：`git -C "测试仓库" diff --cached` 恰含选中那一行（`grep -c '^+' ` 为 1，且不含未选行文本）；`git diff` 含其余行。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `LSTG-001-`）
- 状态：待执行（GUI）

## WT 工作树

### WT-001 创建工作树
- 优先级：P0
- 前置条件：REPO-001 通过。
- UI 操作：通过工作树「新建」入口，从新分支（如 `gui-wt-1`）创建工作树。
- 预期行为：默认落在兄弟目录 `…/testroot/格罗夫 测试仓库-worktrees/gui-wt-1`（含空格路径）；侧栏新条目显示分支名。
- Git/文件系统判据：`git -C "测试仓库" worktree list` 含该路径与分支；`test -d "…-worktrees/gui-wt-1"` 成立。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `WT-001-`）
- 状态：待执行（GUI）

### WT-002 锁定工作树
- 优先级：P1
- 前置条件：WT-001 通过。
- UI 操作：对 `gui-wt-1` 执行「锁定」。
- 预期行为：条目出现锁定标识；删除入口被禁止或给出提示。
- Git/文件系统判据：`git -C "测试仓库" worktree list --porcelain` 该工作树段含 `locked`。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `WT-002-`）
- 状态：待执行（GUI）

### WT-003 解锁工作树
- 优先级：P1
- 前置条件：WT-002 通过。
- UI 操作：对 `gui-wt-1` 执行「解锁」。
- 预期行为：锁定标识消失，可删除。
- Git/文件系统判据：porcelain 输出不再含该工作树的 `locked`。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `WT-003-`）
- 状态：待执行（GUI）

### WT-004 脏工作树删除保护
- 优先级：P0
- 前置条件：WT-003 通过。
- UI 操作：在 `gui-wt-1` 内制造未提交改动（界面编辑文件），随后尝试删除该工作树。
- 预期行为：Grove 阻止直接删除并提示存在未提交改动；确认删除后目录消失、分支按选择处理。
- Git/文件系统判据：删除被拦截时 `git worktree list` 仍含该工作树；确认删除后列表不含且磁盘目录不存在。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `WT-004-`）
- 状态：待执行（GUI）

## HIST 历史筛选

### HIST-001 字面量搜索 foo(bar)
- 优先级：P1
- 前置条件：REPO-001 通过；历史含两条带 `foo(bar)` 的提交（造数保证）。
- UI 操作：在历史页搜索框输入 `foo(bar)`。
- 预期行为：按**字面量**匹配，命中且仅命中一条主题含该字符串的提交（`修复 foo(bar) 解析崩溃`）；不被当作正则解析（若按正则，`foo(bar)` 意为 `foobar`，将匹配不到任何提交）。
- Git/文件系统判据：`git -C "测试仓库" log --format=%s | grep -cF 'foo(bar)'` 输出 `1`，与界面命中数一致。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `HIST-001-`）
- 状态：待执行（GUI）

### HIST-002 筛选生效提示
- 优先级：P2
- 前置条件：HIST-001 执行过。
- UI 操作：保持 `foo(bar)` 筛选，观察历史列表底部/栏下的提示文案；再清空筛选。
- 预期行为：筛选期间显示「筛掉了多少提交」类提示；清空后恢复全部提交且提示消失。
- Git/文件系统判据：`git -C "测试仓库" rev-list --count HEAD` 与清空后的提交总数一致。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `HIST-002-`）
- 状态：待执行（GUI）

## TAG 标签

### TAG-001 创建附注标签
- 优先级：P1
- 前置条件：REPO-001 通过。
- UI 操作：在某个历史提交（选「修复 foo(bar) 解析崩溃」）右键 → 创建标签；填写标签名（输入框默认为空，
  仅当仓库已有语义版本标签时才可能预填，无则属合理），选附注标签，**不勾选推送**，填写说明后创建。
- 预期行为：创建成功，提交详情/历史显示标签。
- Git/文件系统判据：`git -C "测试仓库" tag -n9` 列出该标签及说明；`git for-each-ref refs/tags/<标签>` 的 `objecttype` 为 `tag`（附注对象）；`git ls-remote origin` **不含**该标签（未推送）。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `TAG-001-`）
- 状态：待执行（GUI）

### TAG-002 创建轻量标签
- 优先级：P2
- 前置条件：TAG-001 通过。
- UI 操作：在另一提交创建轻量标签（取消附注选项），不推送。
- 预期行为：创建成功。
- Git/文件系统判据：`git for-each-ref refs/tags/<标签> --format='%(objecttype)'` 输出 `commit`。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `TAG-002-`）
- 状态：待执行（GUI）

## RST 重启恢复

### RST-001 重启后恢复页面与仓库
- 优先级：P1
- 前置条件：REPO-001 通过；当前停留在某个页面（建议 Workspace 或测试仓库页）。
- UI 操作：完全退出 Grove（⌘Q），重新启动。
- 预期行为：回到上次访问页面（默认启动偏好为「上次访问页面」），测试仓库仍在列表中，无重新配置要求。
- Git/文件系统判据：`defaults read | grep grove.navigation` 能看到 `grove.navigation.lastPage` 与启动偏好键；测试根目录内容在重启前后不变。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `RST-001-`）
- 状态：待执行（GUI）

## PLAT 无托管平台提示

### PLAT-001 本地 origin 的评审不可用提示
- 优先级：P1
- 前置条件：REPO-001 通过（origin 指向本地 bare 仓库，非 GitHub/GitLab 主机）。
- UI 操作：进入测试仓库的评审请求（PR/MR）分栏。
- 预期行为：界面明确提示无法识别托管平台 / 评审功能不可用（与 `--doctor` 输出同一套规则），不出现空白卡死、不报错崩溃。
- Git/文件系统判据：`logs/doctor-测试仓库.log` 含「认不出它属于哪个平台」；`git -C "测试仓库" remote get-url origin` 为本地路径。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `PLAT-001-`）
- 状态：待执行（GUI）

## DAILY / WORKSPACE

### DAILY-001 Daily 页今日提交与作者筛选
- 优先级：P1
- 前置条件：REPO-001 通过；测试仓库今日有 ≥4 个提交、两个作者（张三/李四，造数保证）。
- UI 操作：打开 Daily 页，查看今日提交列表；按作者邮箱筛选只看其中一个作者。
- 预期行为：提交按仓库/分支聚合显示，含提交主题；筛选后仅剩所选作者的提交；分支区显示 `main`（或其上游状态文案）。
- Git/文件系统判据：`git -C "测试仓库" log --since=midnight --format='%ae' | sort | uniq -c` 的作者集合与界面筛选选项一致。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `DAILY-001-`）
- 状态：待执行（GUI）

### WS-001 Workspace 页无平台空态
- 优先级：P1
- 前置条件：REPO-001 通过；本项目无托管平台（同 PLAT-001）。
- UI 操作：打开 Workspace 页。
- 预期行为：无 PR/流水线数据时显示空态或明确提示，不崩溃、不长时间假加载；未登录平台的说明可见（如有）。
- Git/文件系统判据：`logs/doctor-测试仓库.log` 显示本地 origin 不属于任何平台（同 PLAT-001 判据）。
- 证据路径：`<artifacts>/evidence/`（文件名前缀 `WS-001-`）
- 状态：待执行（GUI）

## BLK 未执行项（前提未评估前不称阻塞，一律不判通过）

| ID | 项 | 前提 | 记录动作 |
| --- | --- | --- | --- |
| BLK-PR-001 | GitHub PR 浏览/检出/评论/合并 | 需真实 GitHub 仓库与权限（`gh` 已登录不代表前提已评估） | 记录 `gh --version`、登录状态事实；本轮未执行、未补测 |
| BLK-PR-002 | GitLab MR 同上 | 需 `glab` 登录真实 GitLab | 同上 |
| BLK-SSH-001 | SSH 远程仓库管理 | 需真实 SSH 服务器 | 未执行，仅记录 |
| BLK-AI-001 | AI 提交信息 / 标签说明 / AI Review | 需 AI 服务与密钥，禁用范围 | 不执行，仅记录设置页可见性 |
| BLK-PUSH-001 | 推送到真实托管平台（分支/标签） | 外部依赖 | 未执行；本地 bare 推送入口的 UI 表现可观察，但不算真实推送通过 |

> 说明：推送到本地 bare origin 属于本地 Git 行为，GUI 执行者可观察推送按钮的可用性与分离式远端
> 选择（应列出 `origin` 与 `backup` 两个远端及目标地址），但「推送成功」不计入真实平台推送范围。
