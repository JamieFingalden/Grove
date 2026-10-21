# Grove 第二轮续测报告（2026-10-21）

本轮接力完成了剩余可隔离的实机测试。第二轮完整矩阵见 [专项总报告](DEEP_TEST_REPORT_2026-10-20.md)，所有问题详见 [ISSUES.md](ISSUES.md)。

- 被测：Grove 3.0.0（9），固定安装副本 `dist/qa/20261020/installed/Grove.app`，源提交 `8212f60405fd3f0d616c21b35e276ba9f52275ed`。
- 执行者：GPT-6-luna 子代理先接力 E/C/F 部分 GUI，父 Codex 复核并完成其余 GUI；原生 Git 对照由父 Codex CLI 执行。GLM 原始证据单独署名保留。
- 所有 Git 变更仅在 `/private/tmp/grove-deep.R2SGP6` 的合成项目内；实际界面操作前确认完整路径。没有修改产品源码、全局 Git 配置，也未提交或推送 Grove 工程。
- 证据目录：`dist/qa/20261020/deep/codex-20261021/`。本轮不重建、不重复运行全量单测，沿用同包原基线。
- 统计：本接力矩阵16项，11通过、4失败、1未执行。它是第二轮完整矩阵的子集，不能重复相加。

## 接力结果矩阵

| ID | 执行者 | 最终状态 | 实际结果与证据 |
| --- | --- | --- | --- |
| E1 | GPT-6-luna GUI | 通过 | 已被其他工作树占用的分支明确提示占用位置并禁用创建；CLI无新增分支/工作树。e1-occupied-branch-ax.txt、cli-judgments.txt |
| E2 | GPT-6-luna GUI | 通过 | 正常键盘输入 ../bad，错误面板显示非法分支名与退出码255；无新分支、工作树或越界目录。e2-invalid-branch-error.*、cli-judgments.txt |
| E3 | 父 Codex GUI | 通过 | 已有且含文件的目录明确提示、创建禁用；占位文件 SHA不变。原“位置被忽略”是未生效的自动化输入，已排除。e3-existing-dir-protected.*、takeover-review.md |
| E4 | GLM首段＋GPT-6-luna GUI | 通过 | 锁定保护、脏树取消保持字节；清除该合成脏文件后GUI删除，默认保留分支。e4-*、cli-judgments.txt |
| C2 | GPT-6-luna GUI＋父 Codex CLI 对照 | 通过（有语义限制） | 真分叉、同文件MM与未跟踪文件，GUI变基冲突后中止，HEAD/ref/文件SHA全部恢复。索引分界不保持，与独立原生git --autostash/--abort对照一致；作为OBS-C-003，不认定Grove特有缺陷。c2gap-*、native-autostash-control.txt |
| B3 | 父 Codex GUI | 失败：BUG-002 / #12新前置 | 正常顶部入口对完整块明确警告；下方“文件里没有冲突标记”快捷入口在外部重新写入完整块后不刷新、不复查、无警告暂存。GUI继续后双亲合并提交f3b337ad含完整标记。原GLM孤立行结论仍撤回，本项以新实机证据收窄确认。b3-valid-marker-warning.*、b3-no-marker-shortcut-before.*、b3-full-block-shortcut-staged.*、parent-oracles.txt |
| F1 | GPT-6-luna＋父 Codex GUI | 通过 | 非HEAD历史提交建标签指向正确；重名被禁用；非法bad..tag提交被Git拒绝且明确报错；有效轻量标签qa-cancel-only取消后未创建。子代理cli-judgments.txt，父f1-*、parent-oracles.txt。空白标签另未覆盖，不外推为全部格式验证通过 |
| F2 | GPT-6-luna局部＋父 Codex GUI最终 | 通过 | 最终以新鲜完整AX定位删除子菜单，GUI删除repo-f本地v1.0；CLI本地tag列表为空，bare origin仍有同SHA标签。此前工具失效不再作为未完成状态。f2-local-tag-deleted.*、parent-oracles.txt |
| F3 | 父 Codex GUI | 通过 | 有上游前置下，origin指向本轮不存在目录，GUI明确报远端不是仓库；上游、HEAD不变。恢复有效bare路径后GUI“推送完成”，按钮可恢复。f3-missing-remote-error.*、f3-push-recovered-ax.txt、parent-oracles.txt |
| G1 | 父 Codex GUI | 通过（本会话） | repo-a与repo-d同名README内容不同：甲为MM、乙仅未暂存；切项目、历史/变更、另一测试工作树后返回，diff、计数、暂存按钮与QA-A/QA-D草稿不串。g1-*、parent-oracles.txt |
| G2 | 父 Codex GUI | 通过 | 外部追加A-external-refresh，手动刷新、重选文件、历史/变更往返都保留新diff；索引仍仅A-staged。此项不代表已知编辑器自动刷新#11已修复。g2-*、parent-oracles.txt |
| H1 | 父 Codex GUI | 通过（仓库/工作树页面恢复） | ⌘Q正常退出，进程查询确认旧测试进程结束；通过完整安装路径重开，恢复repo-f工作树页面与测试仓库列表。历史子标签、筛选条件与内存提交草稿未恢复，单列OBS-H-001，不声称完整编辑状态恢复。h1-before-quit-ax.txt、h1-after-relaunch.*、h1-restarted-repo-a-draft-ax.txt |
| H2 | 父 Codex GUI | 失败：BUG-004 / #14 | 新提交出现在历史，但作者菜单不刷新，重启后恢复；再新增另一作者再次复现。重启后已载入作者的“作者甲＋foo(bar)”组合正确命中2条，清除恢复5条（随后为复现再加丙1条，共6）；长正文45行可展开滚动。路径入口仅有禁用的“限定路径/src/app.swift”，未做三条件组合，不记通过。h2-*、parent-oracles.txt |
| H3 | — | 未执行（隔离约束） | Daily/Workspace为现有用户项目聚合环境，没有重置设置或创建新用户来隔离，不以查看真实项目数据补足该功能验收；原第一轮缺口保持 |
| SUP-PUSH-002 | 父 Codex GUI | 失败：BUG-003 / #13 | 唯一有效bare远端、分支无上游，推送按钮承诺建立上游却失败，错误建议的菜单又不存在。两次有效远端下GUI复现；建立上游的成功对照与原生dry-run判据齐全。push-valid-origin-*、parent-oracles.txt |
| SUP-PLAT-002 | 父 Codex GUI | 失败：BUG-005 / #15 | 配有有效本地bare origin，工作树知道是无法识别的origin，项目评审页却两次误提示“没有配置远端”。platform-local-origin-*、remote -v判据 |

## 原报告更正与限制

- 原Issue #12曾因GLM仅追加孤立标记行、且将暂存外推为最终提交而撤回。接力先验证正常入口确有警告，再发现不同的快捷入口绕过，并取得完整双亲提交证据；当前问题按这个狭窄前置重新确认。前两版正文和原证据保留，不能将旧孤立行用例算作有效复现。
- C2早先对已变基到main的分支重复操作属于正常无需重放，不是电脑控制阻塞。随后在真实分叉和MM前置上重测，已覆盖冲突与中止。
- 操作菜单期间曾发生AX失效和读取超时。切换到访达后重新读取Grove恢复；3秒sample主线程主要在事件循环，未据此认定产品挂死。最终F2也已通过真实GUI完成，没有用CLI删除冒充。
- 真实PR/MR、SSH写操作、AI与真实平台推送仍未测；全部推送/标签操作只针对合成仓库的本地bare远端。
- 没有为凑缺陷数将原生Git语义、未实现的路径入口或未证实的现象定为功能缺陷。

## 证据与编码

CLI明细分为子代理的 `cli-judgments.txt`、父代理的 `parent-oracles.txt`，原生自动暂存对照为 `native-autostash-control.txt`。图片只保存Grove窗口，未上传包含其他项目名称的截图到GitHub。

编码检查结果：最终收尾核对所有测试Markdown为UTF-8无BOM，无替换字符或连续三个问号；原始工具输出保留原样，与文档检查范围区分。
