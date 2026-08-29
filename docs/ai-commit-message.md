# AI 生成提交信息 —— 设计说明（交给 codex 实现）

这份文档是实现说明，不是需求描述。写清楚**为什么这么设计**，以便实现时遇到没写到的情况能推断出一致的处理方式。

Grove 现有的架构约定见 `README.zh-CN.md` 的「设计取舍」一节：所有外部能力都通过命令行工具接入，Grove 自己不持有任何凭据。这个功能沿用同一条路子 —— 调 `codex` CLI，不碰 API key。

---

## 1. 目标与非目标

**目标。** 用户暂存好改动之后，点一个按钮，得到一条**符合本仓库既有风格**的提交信息草稿，可以直接改、直接用。

**非目标。**

- 不做自动提交。生成的永远是草稿，落在输入框里等用户过目。提交信息是要进历史、要被别人读的东西，不能由模型直接落库。
- 不做多轮对话式改写。第一版只做「生成一次」和「重新生成」。
- 不做行内代码解释、不做 PR 描述生成。那些是另外的功能，别顺手做进来。

---

## 2. 隐私边界 —— 这条最重要，先读完再写代码

**`codex exec` 会把提示词发到外部服务。** 而 Grove 的使用场景里包含**公司内网自建 GitLab 上的私有项目**。把内网代码的 diff 发出去，可能直接违反公司规定。

因此：

1. **默认关闭，按仓库单独开启。** 不是全局开关。用户在 A 仓库开了，B 仓库仍然是关的。存储见第 6 节。
2. **首次开启时必须让用户看到会发生什么** —— 一个确认面板，明确写出：会把**已暂存的 diff**和**最近 20 条提交标题**发给 `codex`；并显示这次大约会发送多少字节。不要用「可能会上传部分数据」这种含糊说法。
3. **只发已暂存的内容。** 不发未暂存改动、不发未跟踪文件、不发完整文件内容、不发仓库地址、不发分支名。用户暂存了什么就发什么 —— 这条边界用户能自己控制，也容易解释。
4. **按钮在未开启时保持可见但禁用**，提示写明「这个仓库还没开启 AI 提交信息」并给出开启入口。参照 `ForgeSetupView` 的做法：不可用的功能不要藏起来，把原因和下一步说清楚。

> 这条规则在这个项目里已经踩过三次（提 PR 按钮、评审入口、托管商接入提示都因为「静默隐藏」被用户反馈过）。不要再犯。

---

## 3. 用户交互

**入口。** `CommitBox`（`Sources/Grove/Views/ChangesView.swift`）里，提交信息输入框右上角一个小按钮，图标 `sparkles`，提示语「用 AI 生成提交信息」。

**状态机。**

| 状态 | 界面 |
|---|---|
| 未开启 | 按钮可见但禁用，tooltip 说明原因 + 「在仓库菜单里开启」 |
| 可用、空闲 | 按钮可点 |
| 生成中 | 按钮换成转圈 + 「取消」；输入框不锁定，用户可以继续自己写 |
| 生成完毕 | 结果填入输入框；按钮变成「重新生成」 |
| 失败 | 错误走现有的 `AppModel.report(title:detail:)` 横幅 |

**不能覆盖用户已经写的东西。** 输入框非空时点生成，要先弹确认（「已有内容会被替换」），或者把结果追加在下面让用户自己取舍 —— 二选一，实现时挑一个并在代码注释里写明理由。写了半屏的提交信息被一键冲掉是不可接受的。

**可取消。** 生成任务要能中断（`Task` 取消 + 杀掉子进程）。`ProcessRunner.run` 已经支持取消时 `terminate()`。

---

## 4. 提示词构造

**这一层必须是纯函数，因为它是唯一需要单元测试的部分。**

放在 `Sources/Grove/AI/CommitPromptBuilder.swift`：

```swift
enum CommitPromptBuilder {
    struct Input {
        var stagedDiff: String
        var recentSubjects: [String]   // 最近的提交标题，用来学风格
        var fileSummary: String        // git diff --cached --stat 的输出
        var maxDiffBytes: Int          // 默认见下
    }
    static func prompt(_ input: Input) -> String
}
```

**风格学习。** 取 `git log -n 20 --format=%s`（**只取标题，不要正文**）。实际调研过的三个仓库风格各不相同：

- 仓库 A：`fix(backend): 兼容IPC控制响应关闭` —— Conventional Commits 带 scope，中文描述
- 仓库 B：`feat: 完善基线版本与环境凭据管理` —— Conventional Commits 不带 scope，中文描述
- 仓库 C：以 GitLab 合并提交为主

所以**不要在提示词里写死任何格式要求**（别写「请使用 Conventional Commits」「请用英文」）。让模型照着样例推断：格式、语言、动词习惯、要不要 scope，全都从样例里学。合并提交（`Merge branch ...`）要在取样时过滤掉，它们不代表人写的风格。

**diff 截断。** 已暂存的 diff 可能非常大。规则：

1. 先算字节数。不超过 `maxDiffBytes`（建议 **32 KB**）就整个带上。
2. 超了就降级：带上完整的 `--stat` 摘要 + 按文件截取的 diff 片段，并在提示词里**明确写出「diff 已被截断」**，让模型知道自己看到的不是全部，不要编造没看到的改动。
3. 无论如何都要保证提示词有上界。不要把一个 200 MB 的 diff 喂进去。

**输出约束。** 提示词里要求：只输出提交信息本身，不要解释、不要代码块包裹、不要「这是你的提交信息：」这类开场白。

更稳的做法是用 `codex exec --output-schema <file>` 要求结构化输出：

```json
{ "type": "object",
  "properties": { "subject": {"type": "string"}, "body": {"type": "string"} },
  "required": ["subject"] }
```

推荐走这条，省掉一堆清洗逻辑。若最终选择纯文本，则必须做清洗：剥掉 ``` 围栏、剥掉首尾空行、把 CRLF 归一。

---

## 5. 调用 codex

放在 `Sources/Grove/AI/CodexCommitGenerator.swift`。参照 `GitLabClient` 的结构（`ToolLocator` 定位、`ProcessRunner` 执行）。

```
codex exec
  --cd <工作树路径>
  --sandbox read-only          # 绝不允许它改文件
  --ephemeral                  # 不落会话记录
  --output-last-message <临时文件>
  --output-schema <临时文件>    # 若采用结构化输出
  -                            # 提示词从 stdin 进
```

要点：

- **`--sandbox read-only` 不能省。** 这个功能只需要它读一段文本、吐一段文本。给写权限没有任何好处，而风险是它去改仓库里的文件。
- **提示词走 stdin**，不要拼进命令行参数。diff 里什么字符都可能有，几十 KB 的参数也会撞上 `ARG_MAX`。`ProcessRunner.run` 已经支持 `standardInput:`（分行提交那个功能加的）。
- **超时**用 `ProcessRunner.networkTimeout`（180 秒）。模型调用属于网络操作。
- **结果从 `--output-last-message` 指定的文件读**，不要去解析 stdout —— stdout 里混着进度信息。临时文件用完删掉。
- `codex` 找不到时，返回一个能照做的提示（安装命令 + 登录命令），交互参照 `ForgeSetupView`。

**用 `ToolLocator.shared.locate("codex")`。** 不要假设它在 `/usr/local/bin`——从 Finder 启动的 app 继承的 PATH 里没有那些目录，这个坑 `ToolLocator.swift` 顶部有详细说明。

---

## 6. 设置的存储

按仓库存，键用仓库的规范化根路径。沿用 `RepositoryBookmarks` 的做法（`UserDefaults`，见 `AppModel.swift` 末尾）：

```swift
struct AICommitSettings {
    func isEnabled(for root: URL) -> Bool
    func setEnabled(_ enabled: Bool, for root: URL)
}
```

路径要用 `URL.groveResolved` 归一化。macOS 上 `/tmp` 是 `/private/tmp` 的符号链接，不归一化的话同一个仓库会被当成两个（`URL+Normalization.swift` 里有说明）。

开关放在侧边栏仓库标题的「⋯」菜单里，跟「清理已合并分支…」并列。

---

## 7. 错误处理

每种失败都要给出**用户下一步能做什么**，不要只报一句「生成失败」。

| 情况 | 处理 |
|---|---|
| 没暂存任何改动 | 按钮禁用，提示「先暂存一些改动」。不要发一个空 diff 出去 |
| `codex` 没安装 | 给安装命令，参照 `ForgeSetupView` |
| `codex` 未登录 / 认证失败 | 原样透出 codex 的报错（它比我们更清楚缺什么），并给出登录命令 |
| 超时 | 「模型没在 180 秒内返回」+ 重试按钮。不要静默失败 |
| 返回空或只有空白 | 当作失败处理，不要把空字符串填进输入框 |
| 用户取消 | 不报错，静默回到空闲状态 |
| diff 超大被截断 | 正常生成，但在结果上方标一句「diff 较大，只分析了一部分」 |

---

## 8. 测试要求

沿用现有约定：**纯函数走单元测试，跟外部工具的交互走真实进程测试**（见 `Tests/GroveTests/` 里 `ProcessRunnerTests`、`PartialStagingTests` 的写法）。

必测：

1. `CommitPromptBuilder` —— 小 diff 不截断；超限 diff 会截断**且提示词里出现截断声明**；合并提交被排除在风格样例之外；没有历史提交时不崩。
2. 输出清洗 —— ``` 围栏、前后空行、CRLF、模型加的开场白，都要能剥干净。**用真实模型输出做样例**，别自己编，编出来的样例测不到真正的脏数据。
3. 设置存储 —— 路径归一化（`/tmp` 与 `/private/tmp` 视为同一个仓库）；默认值必须是**关闭**。
4. 一个联网实测，参照 `GitHubLiveTests` 用 `GROVE_LIVE=1` 门控，默认跳过：在临时仓库里真跑一次 `codex exec`，断言拿到了非空结果。

---

## 9. 明确不要做的

- **不要把 API key 存进 Grove。** 认证全部交给 `codex` 自己，跟 `gh`/`glab` 一致。这是这个项目的既定取舍，README 里写明了。
- **不要默认开启。** 见第 2 节。
- **不要自动提交、不要自动暂存。**
- **不要在生成时锁住输入框。** 用户可能想自己先写着。
- **不要把未暂存的改动或未跟踪文件发出去。**
- **不要因为功能不可用就隐藏按钮。** 留在原位、禁用、说清楚原因。
