cask "grove" do
  version "0.2.0"
  sha256 "52014710134f6c5237dfa143fac2787f6e7217344f8d673b6959b40fad136e83"

  url "https://github.com/JamieFingalden/Grove/releases/download/v#{version}/Grove-#{version}-arm64.dmg"
  name "Grove"
  desc "Native Git worktree and code review manager"
  homepage "https://github.com/JamieFingalden/Grove"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Grove.app"

  caveats <<~EOS
    Grove 使用临时签名，未经过 Apple 公证。
    首次打开被拦截时，请核对下载来源，再到「系统设置 → 隐私与安全性」选择「仍要打开」。
    GitHub PR 功能需要 gh，GitLab MR 功能需要 glab；本地 Git 功能只需要 git。
    快速入门：https://github.com/JamieFingalden/Grove/blob/main/docs/getting-started.zh-CN.md
  EOS
end
