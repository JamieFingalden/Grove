# Getting Started with Grove

[中文](getting-started.zh-CN.md) · [Back to README](../README.md)

This guide covers v0.2.1: install Grove, create a worktree, commit a change, and check out a PR/MR without interrupting your current work. If v0.2.1 is not yet listed in Releases, you can use the published v0.2.0; some controls may be in different places.

## 1. Install

Release DMGs support Apple Silicon (M-series Macs) and macOS 14 or later. A prebuilt Intel package is not currently available.

### Homebrew

With [Homebrew](https://brew.sh) installed:

```sh
brew tap JamieFingalden/grove https://github.com/JamieFingalden/Grove.git
brew install --cask JamieFingalden/grove/grove
```

This is a project-maintained third-party tap. Homebrew downloads the versioned DMG from Grove's GitHub Release and verifies its SHA-256 checksum.

### Download a DMG

1. Open [Grove Releases](https://github.com/JamieFingalden/Grove/releases).
2. Download `Grove-<version>-arm64.dmg`.
3. Open the DMG and drag `Grove.app` to Applications.

To verify the download, also download the matching `.dmg.sha256` file and run this in your download directory:

```sh
shasum -a 256 -c Grove-0.2.1-arm64.dmg.sha256
```

Replace the version if necessary. The result should be `OK`.

### First launch

Current release builds use ad-hoc signing and are not Apple-notarized.

1. Open Grove from Applications once.
2. If macOS cannot verify the developer or check the app for malware, confirm that you downloaded it from the project's Release and that the checksum matches.
3. Go to **System Settings → Privacy & Security**, find the blocked Grove launch, click **Open Anyway**, and confirm.

This adds an exception for Grove; you do not need to disable Gatekeeper. If macOS reports damage or malware, or does not offer Open Anyway, keep the alert and [report the issue](https://github.com/JamieFingalden/Grove/issues). See [Apple's instructions](https://support.apple.com/en-us/102445).

## 2. Prepare Git and platform access

Check Git in Terminal:

```sh
git --version
```

If developer tools are missing, run `xcode-select --install`, finish installation, and try again. Local Git features do not require a GitHub/GitLab login or AI configuration.

For GitHub PRs:

```sh
brew install gh
gh auth login
gh auth status
```

For GitLab MRs:

```sh
brew install glab
glab auth login
glab auth status
```

Install only the CLI for the platform you use. Reopen Grove after authentication. The platform CLIs manage your credentials; Grove does not keep a separate copy of those credentials.

## 3. Open a repository

1. Click **打开仓库…** (Open Repository), or press `⌘O`.
2. Select the root directory of an existing local Git repository. Clone it with your usual `git clone` command first if necessary.
3. Select a worktree in the sidebar to see its branch, changes, and history.

The UI currently includes Chinese labels; this guide includes the labels needed for the walkthrough. Start with a repository that already has at least one commit. Grove operates on the same repository used by your terminal and editor.

## 4. Create a worktree

1. Select the repository and click **新建工作树** (New Worktree).
2. Choose **新建分支** (New Branch) and enter an unused name, such as `feature/grove-demo`.
3. Choose the starting branch, or leave the field empty to use the default branch or HEAD shown in the sheet.
4. Keep the suggested sibling directory. For `/Projects/demo`, an example is `/Projects/demo-worktrees/feature-grove-demo`.
5. Click **创建** (Create), then open that new directory in your editor.

Each worktree has its own files and uncommitted changes. Your original work stays where it was. Worktrees share Git history and branches, and Git prevents checking out the same branch in two worktrees at once. Uncommitted files from another worktree are not copied into the new one.

## 5. Stage and commit

1. Edit a file in the new worktree directory.
2. Select that worktree in Grove and inspect its diff under **未暂存** (Unstaged). Press `⌘R` to refresh if needed.
3. Stage the file with **暂存** (Stage), or select individual changed lines in the diff and stage those.
4. Check **已暂存** (Staged), enter a commit message, and click **提交** (Commit).
5. When ready to publish your branch, check the destination and click **推送** (Push). Follow the remote selection prompt for a first push or a repository with multiple remotes.

If Git reports a missing identity, set `git config user.name` and `git config user.email` in that repository and retry. AI-generated messages are optional; manual commits work without AI.

## 6. Check out a PR/MR without switching away

1. Authenticate the platform CLI and open a repository whose `origin` points to that platform.
2. Open the repository's review-request page and select a PR/MR.
3. Choose the action to check it out as a new worktree, also available in the list's context menu.
4. Read, run, or edit its code in the separate directory. Your original worktree stays in place.
5. Select your original worktree in the sidebar to continue your feature.

For a same-repository request, you can push back to its branch when your permissions allow it. Fork requests use a local review branch; checking one out does not grant permission to push to the fork.

After review, commit or otherwise save anything you need before removing the worktree through its menu. Removing the branch is a separate option. Avoid deleting a directory that still contains work you need.

## 7. Optional AI features

In Grove settings, enable AI and choose a signed-in Codex CLI or configure a Chat Completions-compatible API URL, model, and key. API keys are stored in macOS Keychain.

Using these features sends the relevant code context to your configured service and may incur service charges. You can complete the entire local Git walkthrough before enabling AI.

## Updates, uninstalling, and troubleshooting

For a Homebrew installation:

```sh
brew update
brew upgrade --cask JamieFingalden/grove/grove
```

To uninstall:

```sh
brew uninstall --cask JamieFingalden/grove/grove
```

The cask has no `zap` action that deletes user data. Uninstalling does not actively remove your Git repositories or worktrees. For a DMG installation, download a new Release and replace the app in Applications.

| Problem | Check first |
| --- | --- |
| Missing PRs/MRs | Run `gh auth status` / `glab auth status` and check `origin` with `git remote -v`. Grove detects the platform from `origin`. |
| CLI works but Grove does not | Quit and reopen Grove. Confirm the CLI is in a standard Homebrew location; attach diagnostic output if it still fails. |
| No remote branches | Fetch first. A repository without a remote can still have local worktrees. |
| Branch already checked out | Open its existing worktree, or use another branch for the new worktree. |
| Homebrew cannot find the cask | Confirm the published tap contains `Casks/grove.rb`, run `brew update`, and use the full `JamieFingalden/grove/grove` name. |

For diagnostics:

```sh
/Applications/Grove.app/Contents/MacOS/Grove --doctor /absolute/path/to/your/repository
```

When opening an [issue](https://github.com/JamieFingalden/Grove/issues), include the Grove version, macOS version, steps, and error message. Diagnostics may contain repository paths and remote URLs; redact private details before sharing.
