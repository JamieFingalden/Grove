2026-10-21 修复进展：本地已修复，定向回归及新构建 App 实机验收通过。源码尚未提交/推送，Issue 保持开放。

保存成功后在 WorktreeModel.writeEditorFile 复用 refreshChanges，所选 diff 与冲突文本自动重载，移除视图里重复刷新。实机保存并完成后，未手动刷新就出现 QA-saved-diff 新行；CLI git diff 与界面一致。新增真实仓库回归 testEditorSaveReloadsAlreadySelectedDiff。

本批 39 项相关自动回归全部通过（0 失败）；冲突保存补充断言定向重跑 2 项通过，属于前述 39 项，不重复计数。真实 Git 操作仅在新建专用合成测试项目执行。

本地详细记录：docs/testing/FIX_REPORT_2026-10-21.md；完整问题记录：docs/testing/ISSUES.md。截图、AX、Git 判据及日志在 dist/qa/20261021/fixes/evidence/。已测 Release 二进制 SHA-256：a945a6b18a8823173ba15e2277086edd537cde5b163d2fbcd847959255b61c9d。此评论只记录本地验证进度，未在 GitHub 发布修复代码或安装包。
