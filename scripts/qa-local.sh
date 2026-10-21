#!/bin/zsh
# Grove 3.0.0 本地验收造数与诊断脚本（qa-local）
#
# 用途：
#   1. 在专用测试根目录下创建一套本地 Git 测试数据（中文/空格路径、不同提交人、
#      含 foo(bar) 字面量的历史、同文件两段相隔修改、未跟踪文件、重命名、确定性二进制、
#      本地 bare origin 与备用远端、一个真非仓库目录）。
#   2. 调用本次打包的 Grove.app 执行 --doctor 诊断，把完整输出、退出码和关键行落盘。
#
# 边界（务必遵守）：
#   - 只操作 --test-root 指定的目录；目录已存在则直接报错退出，绝不覆盖或清理。
#   - 测试根目录必须完全独立于任何既有 Git 仓库（含 Grove 工程自身），
#     否则「不是仓库」负例会解析到外层仓库——脚本在造数前检查并直接拒绝。
#   - 三个路径参数都必须是绝对路径，缺参或相对路径直接报错，不做路径拼接收尾。
#   - 旧一轮的 artifacts（logs/、summary.txt）一律拒绝覆盖，新一轮用新的 --artifacts。
#   - 测试身份只用仓库本地配置和 git -c，不碰全局配置。
#   - CLI 仅用于造数与判据，不作为 GUI 功能通过的依据；doctor 通过不等于 GUI 通过。
#   - 不重建工程、不跑全量单元测试、不访问真实托管平台、不触发 AI。
#   - 不删除任何旧证据。

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"

# 默认产物落在本轮目录；三个路径均为绝对路径可配置，供后续新一轮选用新位置。
APP="${PROJECT_DIR}/dist/Grove.app"
ARTIFACTS="${PROJECT_DIR}/dist/qa/20261020"
TEST_ROOT=""

usage() { print -u2 "qa-local：$1（可用：--app --artifacts --test-root，均接绝对路径）"; exit 64; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)       [[ $# -ge 2 && -n "$2" ]] || usage "--app 缺少参数";       APP="$2";       shift 2 ;;
        --artifacts) [[ $# -ge 2 && -n "$2" ]] || usage "--artifacts 缺少参数"; ARTIFACTS="$2"; shift 2 ;;
        --test-root) [[ $# -ge 2 && -n "$2" ]] || usage "--test-root 缺少参数"; TEST_ROOT="$2"; shift 2 ;;
        *) usage "未知参数：$1" ;;
    esac
done

# TEST_ROOT 未指定时默认落在 /private/tmp 下的独立时间戳目录：完全在工程与任何仓库之外，
# 「不是仓库」负例才有效；目录已存在会被下方检查拒绝，绝不覆盖。三个参数统一校验为绝对路径。
: "${TEST_ROOT:=/private/tmp/grove-qa-local/testroot-$(date +%Y%m%d-%H%M%S)}"
for key in APP ARTIFACTS TEST_ROOT; do
    val="${(P)key}"
    if [[ "$val" != /* ]]; then
        die_rel="参数 ${key} 必须是绝对路径，收到相对路径：$val"
        print -u2 "qa-local：$die_rel"
        exit 64
    fi
done

BIN="${APP}/Contents/MacOS/Grove"
LOG_DIR="${ARTIFACTS}/logs"

die() { print -u2 "qa-local：$1"; exit 1; }

[[ -x "$BIN" ]] || die "未找到可执行文件：$BIN（请先由负责人完成打包）"
command -v git >/dev/null || die "未找到 git"

# 旧一轮 artifacts 保护：logs/ 或 summary.txt 已存在即拒绝，绝不覆盖已有证据。
if [[ -e "$LOG_DIR" || -e "${ARTIFACTS}/summary.txt" ]]; then
    die "旧报告路径已存在（${LOG_DIR} 或 ${ARTIFACTS}/summary.txt），拒绝覆盖；新一轮请指定新的 --artifacts 绝对路径"
fi

# 测试根目录独立性检查：造数前其父目录必须不在任何 Git 仓库内。
# 否则「不是仓库」负例会被 git 解析到外层仓库，且有误扫真实项目的风险。
if [[ -e "$TEST_ROOT" ]]; then
    die "测试根目录已存在，拒绝覆盖：$TEST_ROOT（新一轮请用 --test-root 指定新路径）"
fi
# 向上找到最近的已存在祖先目录做仓库检查（测试根本身允许尚不存在）。
TEST_PARENT="${TEST_ROOT:h}"
PROBE="$TEST_PARENT"
while [[ ! -d "$PROBE" && "$PROBE" != "/" ]]; do
    PROBE="${PROBE:h}"
done
[[ -d "$PROBE" ]] || die "无法确定测试根目录的已存在父目录：$TEST_PARENT"
ENCLOSING="$(git -C "$PROBE" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$ENCLOSING" ]]; then
    die "测试根目录位于既有仓库 ${ENCLOSING} 内部，拒绝造数：非仓库负例会失效，且违反「只在专用合成仓库做 Git 测试」的边界。请选完全独立位置（例：/private/tmp/grove-qa-glm-20261020）"
fi

mkdir -p "$TEST_ROOT" "$LOG_DIR"

# 测试数据绝对路径。
ORIGIN="$TEST_ROOT/远端-origin.git"
BACKUP="$TEST_ROOT/远端-backup.git"
REPO="$TEST_ROOT/格罗夫 测试仓库"
NONREPO="$TEST_ROOT/不是仓库"

print "qa-local：测试根目录 $TEST_ROOT"
print "qa-local：被测程序  $BIN"

# ── 1. 本地 bare 远端 ────────────────────────────────────────────────
git init --bare -b main "$ORIGIN" >/dev/null
git init --bare -b main "$BACKUP" >/dev/null

# ── 2. 测试仓库（路径含中文和空格） ──────────────────────────────────
git init -b main "$REPO" >/dev/null
# 仓库本地配置设定测试身份「张三」，不动全局配置；「李四」用 git -c 逐次覆盖。
git -C "$REPO" config user.name  "张三"
git -C "$REPO" config user.email "zhangsan@test.local"

mkdir -p "$REPO/src" "$REPO/assets"
print "# Grove 验收测试仓库" > "$REPO/README.md"
{
    print "调用 foo(bar) 前先判空，这是历史 diff 的内容锚点。"
    # 填充行用于拉开未暂存两处改动的间距：unified diff 上下文 3 行，
    # 间隔不足会把两个 hunk 合并成一个，行级暂存用例需要真两个 hunk。
    print "填充行一（保持两 hunk 分隔用）"
    print "填充行二"
    print "填充行三"
    print "填充行四"
    print "填充行五"
    print "填充行六"
    print "填充行七"
} > "$REPO/src/app.txt"

# 提交一（张三）：创建 src/app.txt —— 同文件第一段修改。
git -C "$REPO" add -A
git -C "$REPO" commit -m "初始化仓库" >/dev/null

# 提交二（李四，git -c 身份）：在文件中段插入一行 —— 与提交一构成两段相隔的历史修改。
# 用 head/tail 重写而非只在末尾追加，保证后续工作区能做出两个独立 hunk。
{
    head -n 1 "$REPO/src/app.txt"
    print "调用 foo(bar) 后需要释放句柄，见第二段修改。"
    tail -n +2 "$REPO/src/app.txt"
} > "$REPO/src/app.txt.new" && mv "$REPO/src/app.txt.new" "$REPO/src/app.txt"
git -C "$REPO" add src/app.txt
git -C "$REPO" -c user.name="李四" -c user.email="lisi@test.local" \
    commit -m "修复 foo(bar) 解析崩溃" >/dev/null

# 提交三（张三）：纯重命名。
git -C "$REPO" mv src/app.txt src/main.txt
git -C "$REPO" commit -m "重命名 app.txt 为 main.txt" >/dev/null

# 提交四（李四）：二进制文件。确定性内容，必含 NUL 字节，不靠随机数碰运气。
printf 'GROVE-BIN-V1\x00\x01\x02LOGO\x00END' > "$REPO/assets/logo.bin"
git -C "$REPO" add assets/logo.bin
git -C "$REPO" -c user.name="李四" -c user.email="lisi@test.local" \
    commit -m "添加二进制图标资源" >/dev/null

# ── 3. 远端：origin（本地 bare）+ backup（备用，仅登记） ─────────────
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -u origin main >/dev/null
git -C "$REPO" remote add backup "$BACKUP"

# ── 4. 工作区状态：已暂存 / 未暂存（两个独立 hunk）/ 未跟踪 ───────────
print "## 第一段修改（GUI 验收用，已暂存）" >> "$REPO/README.md"
git -C "$REPO" add README.md
# 未暂存改动做成两个相隔 hunk：中段插入一行 + 末尾追加一行。
{
    head -n 1 "$REPO/src/main.txt"
    print "中段插入（GUI 验收用，未暂存，独立 hunk 甲）"
    tail -n +2 "$REPO/src/main.txt"
    print "末尾追加（GUI 验收用，未暂存，独立 hunk 乙）"
} > "$REPO/src/main.txt.new" && mv "$REPO/src/main.txt.new" "$REPO/src/main.txt"
mkdir -p "$REPO/notes"
print "GUI 验收待办：核对分行暂存。" > "$REPO/notes/待办.txt"

# 非仓库目录：供「打开非仓库报错」用例使用。测试根已确认不在任何仓库内，
# 因此这里是真正的非仓库负例。
mkdir -p "$NONREPO"

# ── 5. 最小检查：foo(bar) 字面量、二进制含 NUL、工作区恰好两个 hunk ───
if ! git -C "$REPO" log --format=%s | grep -Fq 'foo(bar)'; then
    die "最小检查失败：提交历史中未找到 foo(bar) 字面量"
fi
if ! od -An -c "$REPO/assets/logo.bin" | grep -q '\\0'; then
    die "最小检查失败：二进制 fixture 未含 NUL 字节"
fi
HUNK_COUNT="$(git -C "$REPO" diff -- src/main.txt | grep -c '^@@')"
if [[ "$HUNK_COUNT" -ne 2 ]]; then
    die "最小检查失败：src/main.txt 未暂存改动应为 2 个 hunk，实际 $HUNK_COUNT 个"
fi

# ── 6. 打包产物 --doctor 诊断（完整输出 + 退出码落盘） ────────────────
run_doctor() {
    local label="$1" target="$2"
    local log="$LOG_DIR/doctor-${label}.log"
    print "qa-local：运行 doctor（${label}）→ $log"
    {
        print "# 命令：$BIN --doctor $target"
        print "# 时间：$(date '+%Y-%m-%dT%H:%M:%S%z')"
    } > "$log"
    set +e
    "$BIN" --doctor "$target" >> "$log" 2>&1
    local rc=$?
    set -e
    print "# 退出码：$rc" >> "$log"
    print "$rc" > "${log}.exit"
    print "qa-local：doctor（${label}）退出码 $rc"
}

run_doctor "测试仓库" "$REPO"
run_doctor "不是仓库" "$NONREPO"

# ── 7. 机器事实与关键输出摘要 ────────────────────────────────────────
SUMMARY="$ARTIFACTS/summary.txt"
{
    print "# qa-local 摘要  $(date '+%Y-%m-%dT%H:%M:%S%z')"
    print "被测程序：$BIN"
    print "二进制 SHA-256：$(shasum -a 256 "$BIN" | cut -d' ' -f1)"
    print "系统：$(sw_vers -productName) $(sw_vers -productVersion)（$(sw_vers -buildVersion)），$(uname -m)"
    print "git：$(git --version)"
    print "测试根目录：$TEST_ROOT"
    print "测试仓库：$REPO"
    print "非仓库目录：$NONREPO"
    print "doctor（测试仓库）退出码：$(cat "$LOG_DIR/doctor-测试仓库.log.exit")"
    print "doctor（不是仓库）退出码：$(cat "$LOG_DIR/doctor-不是仓库.log.exit")"
    print ""
    print "── doctor 关键行（完整输出见 logs/）──"
    grep -hE "git 版本|仓库根目录|远端 origin|远端（|origin 主机|默认分支|工作树（|本地分支（|不是 git 仓库|认不出它属于哪个平台|工作区 diff（" \
        "$LOG_DIR/doctor-测试仓库.log" "$LOG_DIR/doctor-不是仓库.log" || true
} > "$SUMMARY"

print "qa-local：完成。摘要见 $SUMMARY"
print "qa-local：注意——doctor 结果只代表命令行链路可用，GUI 用例需具备真实电脑控制能力者执行。"
