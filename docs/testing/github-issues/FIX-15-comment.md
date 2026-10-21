2026-10-21 修复进展：本地已修复，定向回归及新构建 App 实机验收通过。源码尚未提交/推送，Issue 保持开放。

有 Git 远端但 origin 无法解析时，不再误走无远端的平台 setup；区分没有远端、没有 origin、无法识别 origin。新 App 实机有效本地 origin 的评审页显示“评审请求不可用 / 无法识别 origin 的地址。”。新增真实 bare 测试覆盖本地 origin、将 origin 改名 backup、删除全部远端三个状态。

本批 39 项相关自动回归全部通过（0 失败）；冲突保存补充断言定向重跑 2 项通过，属于前述 39 项，不重复计数。真实 Git 操作仅在新建专用合成测试项目执行。

本地详细记录：docs/testing/FIX_REPORT_2026-10-21.md；完整问题记录：docs/testing/ISSUES.md。截图、AX、Git 判据及日志在 dist/qa/20261021/fixes/evidence/。已测 Release 二进制 SHA-256：a945a6b18a8823173ba15e2277086edd537cde5b163d2fbcd847959255b61c9d。此评论只记录本地验证进度，未在 GitHub 发布修复代码或安装包。
