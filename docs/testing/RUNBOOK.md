# Grove 验收测试执行手册（RUNBOOK，可复用标准流程）

标准链：本手册 → 校验 → `qa-local.sh` 独立造数与诊断 → 真实 GUI → Git 判据 →
缺陷复现 → Issues → 报告/验收。第一节主路径代码块可直接复制；其余含尖括号占位的示例须替换参数后使用。

## 0. 角色提醒

- GUI 操作（点击、打开安装包、保存截图）由**具备真实电脑控制能力（computer-use）的执行者**执行，
  可以是 Claude Code、pi、ZCode 等代理或人工测试者；不同执行者可分批接力，产物分别署名。
- 没有电脑控制能力的执行者只执行 CLI（造数、doctor、判据核对命令）并审阅证据，
  **不得假装执行 GUI**。
- 产物署名遵循 `TEST_PLAN.md` 第 2 节。

## 1. 前置确认与校验（CLI 执行者）

主路径：**对已有包开启新轮次**（不重新构建；以下整块可直接复制执行）：

```sh
# 对已有包开启新测试轮次（不覆盖任何已有数据/校验）；验证或测试失败即停止，不影响外层 shell
(
set -e
set -o pipefail
QA_RUN_ROOT="$(mktemp -d /private/tmp/grove-qa.XXXXXX)"
QA_ARTIFACTS="$QA_RUN_ROOT/artifacts"
mkdir -p "$QA_ARTIFACTS/evidence"
cd /Users/jamie/Documents/code/tools/Grove
# 版本事实（后续报告引用）
plutil -lint dist/Grove.app/Contents/Info.plist
QA_VERSION="$(plutil -extract CFBundleShortVersionString raw dist/Grove.app/Contents/Info.plist)"
QA_BUILD="$(plutil -extract CFBundleVersion raw dist/Grove.app/Contents/Info.plist)"
print "版本 $QA_VERSION（build $QA_BUILD）"
# 验证已有 DMG 校验文件（必须在 dist 内执行：shasum -c 需要校验文件里的相对文件名）
( cd dist && shasum -a 256 -c "Grove-${QA_VERSION}.dmg.sha256" )
# 安装包签名事实
lipo -archs dist/Grove.app/Contents/MacOS/Grove
codesign --verify --deep --strict --verbose=2 dist/Grove.app
# 仅新构建或已有基线失效时显式设置 QA_RUN_UNIT_TESTS=1，复用同一包时默认不重复全量单测
if [ "${QA_RUN_UNIT_TESTS:-0}" = 1 ]; then
    swift test 2>&1 | tee "$QA_ARTIFACTS/evidence/swift-test.log"
fi
# 独立造数与诊断（详见第 2 节）
zsh scripts/qa-local.sh \
    --test-root "$QA_RUN_ROOT/testroot" \
    --artifacts "$QA_ARTIFACTS" \
    --app "$PWD/dist/Grove.app"
print "本轮 QA_RUN_ROOT=$QA_RUN_ROOT"
print "本轮 QA_ARTIFACTS=$QA_ARTIFACTS（后续 GUI 证据、判据与报告据此定位）"
)
```

以上事实记入该轮 `artifacts/evidence/package-checks.md`。校验失败或版本不符则停下，不使用旧包；
`spctl` rejected 表示 Gatekeeper 评估未通过；单凭该退出码不能确定原因，须结合签名、
公证与隔离属性证据解释，不等同签名无效。本轮未公证包的分发限制见报告。

### 仅需要重新构建时（独立步骤，非主路径）

同版本 DMG 已存在时 `make-dmg.sh` 会拒绝，属预期保护。先把同版本旧 DMG **和对应 sha256**
一起归档到同一个新建唯一目录（保留历史，不删除、不覆盖），再构建生成新包与新校验；
新生成的校验文件必须在 `dist` 目录内执行命令产生（校验文件内才是可供 `shasum -c`
使用的相对文件名）。本块自读版本，不依赖第一节的变量：

```sh
(
set -e
cd /Users/jamie/Documents/code/tools/Grove
QA_VERSION="$(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
QA_ARCHIVE="dist/archive/$(date +%Y%m%d%H%M%S)-${QA_VERSION}"
mkdir -p "$QA_ARCHIVE"
mv "dist/Grove-${QA_VERSION}.dmg" "dist/Grove-${QA_VERSION}.dmg.sha256" "$QA_ARCHIVE/"
zsh scripts/build.sh && zsh scripts/make-dmg.sh
( cd dist && shasum -a 256 "Grove-${QA_VERSION}.dmg" > "Grove-${QA_VERSION}.dmg.sha256" )
print "旧包与旧校验已归档到 $QA_ARCHIVE"
)
```

## 2. 独立造数与诊断（CLI 执行者）

**主路径（第 1 节代码块）已完整执行本节内容（含 qa-local.sh），不要重复运行**——
重复执行会撞到脚本的防覆盖检查（目录已存在即报错退出，属预期保护）。本节仅作参数与产物说明：

- 造数命令即第 1 节中的 `zsh scripts/qa-local.sh --test-root "$QA_RUN_ROOT/testroot" --artifacts "$QA_ARTIFACTS" --app "$PWD/dist/Grove.app"`，轮次路径以主路径末尾打印的 `QA_RUN_ROOT` / `QA_ARTIFACTS` 为准。

- 未指定 `--test-root` 时默认落在 `/private/tmp/grove-qa-local/testroot-<时间戳>`
  （工程与任何仓库之外，保证非仓库负例有效）；目录已存在即报错退出，绝不覆盖。
- 脚本行为约束：只操作 `--test-root` 指定目录；测试根必须在任何仓库之外；
  测试身份用仓库本地配置 / `git -c`（张三/李四 `@test.local`），不动全局配置；
  不重建、不跑全量单元测试、不访问真实平台、不触发 AI。
- 产物：`logs/doctor-测试仓库.log`、`logs/doctor-不是仓库.log`、各 `.exit` 退出码、`summary.txt`
  （在 `--artifacts` 下）。

**doctor 结果的解释边界**：doctor 通过只证明打包产物的命令行自查链路可用
（git 定位、仓库解析、工作树/状态/diff 输出、无托管平台提示文案），
不构成任何 GUI 用例的通过依据。

## 3. 真实 GUI（需 computer-use 的执行者）

按 `TEST_CASES.md` 的 ID 顺序执行。每条用例：

1. 在本轮 artifacts 的 `evidence/` 下保存（文件名前缀用执行者标识，便于分别署名）：
   - 操作序列 AX 文本（`*-start.txt` / `*-result.txt` 或等效 AX 抓取）；
   - 至少一张截图 `*.png`（含可辨识的窗口标题或路径）。
2. 遇到与预期不符：原样记录（截图 + AX 文本），不修复、不重试超过一次，标记待审。
   若表单关闭或保留但 Git 状态未变，先核对前置是否本来无需操作、输入是否生效，
   再查最近错误；不能直接归因于电脑控制工具。只有明确的工具错误才记工具阻塞，原因未定则记待核实。
3. 未执行项（BLK-*）：只记录环境事实，不尝试登录任何平台；前提未评估时记「未执行」，不称阻塞。

## 4. Git 判据核对（CLI 执行者）

GUI 证据回传后，对每条用例执行 `TEST_CASES.md` 中「Git/文件系统判据」列的命令，
输出保存为 `evidence/<用例ID>-verify.txt`，并在开头注明：

```
判据执行人：<执行者>（CLI）
执行时间：<ISO8601>
命令与输出：<逐条粘贴>
结论：与 GUI 证据一致 / 不一致（说明）
```

一致且界面证据齐全 → PASS；任一不符 → FAIL（进缺陷流程）。

## 5. 缺陷复现与 Issue 登记

1. 待审缺陷先核对真实输入、界面结果与 Git/文件判据，再在重建的合成前置上定向复现一次；
   同一执行者可以复现，条件允许时由另一执行者复核。高风险数据损坏若已有充分证据应立即登记，
   不能因没有第二名执行者而降为建议。无法复现且判据不足的现象单列待核实，不自动定为 S4。
   报告只写实际验证到的后果：进入暂存区不等于已提交，命令报错不等于已有数据丢失。
2. 确认缺陷：先查重 `gh issue list --repo <仓库> --state all`，再把正文写入
   `docs/testing/github-issues/<编号>-<slug>.md`（正文不含本机用户名、隐私、其他项目路径与截图，
   用通用合成仓库描述复现步骤），执行：
   ```sh
   gh issue create --repo <仓库> --title "<中文标题>" --body-file <正文文件>
   ```
   返回的 URL 回填 `docs/testing/ISSUES.md`；不得预写未创建的 URL。

## 6. 报告与收尾

1. 汇总所有用例状态，写 `docs/testing/TEST_REPORT_<日期>.md`：逐条对齐 TEST_CASES 的 ID
   并列补充用例，状态分通过/失败/未执行，每项可追证据；重新计算合计，
   不引用任何执行者自述的未核对计数。
2. 编码自检（Node 标准库，无新依赖；ASCII 是合法 UTF-8，不用 `file | grep` 误报）：
   ```sh
   find <本轮产物目录> -type f \( -name '*.md' -o -name '*.txt' -o -name '*.log' \) -print0 \
     | xargs -0 node -e '
         const fs = require("fs");
         let bad = 0;
         for (const p of process.argv.slice(1)) {
           const b = fs.readFileSync(p);
           if (b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf) { console.log("BOM:", p); bad++; }
           try { new TextDecoder("utf-8", { fatal: true }).decode(b); }
           catch { console.log("非UTF-8:", p); bad++; continue; }
           const s = b.toString("utf8");
           if (s.includes("\uFFFD")) { console.log("U+FFFD:", p); bad++; }
           if (s.includes("?".repeat(3))) { console.log("连续三问号:", p); bad++; }
         }
         process.exit(bad ? 1 : 0);
       ' \
     && echo "编码检查通过" || echo "发现编码问题（见上）"
   ```
3. 不提交 Git。报告、截图、关键日志和 Git 判据归档后，必须清理本轮合成仓库、工作树、bare 远端和重复测试 App；同时从 Grove 侧边栏移除测试项目，核对真实项目仍保留。不可把清理工作留给用户。
4. 用户试用阶段只维护 `dist/Grove.app`；除非用户明确要求，不生成 DMG、不复制到 Applications，也不保留多份相同 App。
5. 临时测试目录使用系统临时路径，自动检查用 `defer` / `trap` 收尾。实机测试只在确有必要时暂时加入侧边栏，结束即移除。保留轻量的清理清单，不保留整套重复 worker 会话和产物。

## 7. 快速参考：常用判据命令

```sh
REPO="<独立测试根>/格罗夫 测试仓库"

git -C "$REPO" status --porcelain              # 变更判据
git -C "$REPO" log --format='%h %ae %s'        # 作者与主题（字面量核对用 grep -F）
git -C "$REPO" worktree list --porcelain       # 工作树/锁定判据
git -C "$REPO" tag -n9                          # 标签判据
git -C "$REPO" remote -v                        # 双远端判据
```

## 8. 发布构建的 PR 加载回归

PR 列表的并发结果标识曾只在 Release 优化配置下出错。修改加载路径后必须运行 `swift test -c release --filter PullRequestLoadStateTests`，并在最终 `dist/Grove.app` 中只读验证“开放 → 全部 → 已合并/已关闭”。不能仅凭 Debug 通过宣称发布包通过；无需为此新增持久测试项目或再做一轮全量测试。
