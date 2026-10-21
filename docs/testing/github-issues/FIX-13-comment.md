2026-10-21 修复进展：本地已修复，定向回归及新构建 App 实机验收通过。源码尚未提交/推送，Issue 保持开放。

无上游且未显式选远端时，在共享推送入口补选 defaultRemote，让 Git 实际执行 push --set-upstream <remote> <branch>。已有上游时保持原配置。新 App 在单 origin、本地空 bare、push.autoSetupRemote=false 的专用仓库一次点击推送成功，建立 origin/main，bare main 与当时 HEAD 一致。新增真实 bare 回归还覆盖已有同名远端分支时补建跟踪、显式推送 backup 不改变 origin 上游。

本批 39 项相关自动回归全部通过（0 失败）；冲突保存补充断言定向重跑 2 项通过，属于前述 39 项，不重复计数。真实 Git 操作仅在新建专用合成测试项目执行。

本地详细记录：docs/testing/FIX_REPORT_2026-10-21.md；完整问题记录：docs/testing/ISSUES.md。截图、AX、Git 判据及日志在 dist/qa/20261021/fixes/evidence/。已测 Release 二进制 SHA-256：a945a6b18a8823173ba15e2277086edd537cde5b163d2fbcd847959255b61c9d。此评论只记录本地验证进度，未在 GitHub 发布修复代码或安装包。
