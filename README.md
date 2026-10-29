# Grove

[中文说明](README.zh-CN.md)

Grove is a native macOS app for working with git worktrees and code review requests — GitHub pull requests and GitLab merge requests — in one place.

Worktrees let you keep several branches checked out at once, in separate directories, sharing a single clone. That is exactly what you want when a review lands while you are mid-feature — but the command line makes you juggle paths, and every other git GUI treats worktrees as an afterthought. Grove puts them front and center: the sidebar groups worktrees by project, each showing its branch, its uncommitted changes, and the state of its review request.

The workflow it is built around: see a PR, check it out as a new worktree with one click, review or fix it without touching what you were doing, then delete the worktree and its branch when it merges.

## Getting Started

Download a DMG from [Releases](https://github.com/JamieFingalden/Grove/releases), or install through the project's Homebrew tap:

```sh
brew tap JamieFingalden/grove https://github.com/JamieFingalden/Grove.git
brew install --cask JamieFingalden/grove/grove
```

Release binaries require **Apple Silicon and macOS 14+**. They are not Apple-notarized; if macOS blocks the first launch, follow the [first-launch instructions](docs/getting-started.md#first-launch).

Follow the [Getting Started guide](docs/getting-started.md) to open a repository, create a worktree, and review a PR/MR. See [Homebrew maintenance](docs/release/homebrew.md) for tap publication and updates.

## Requirements

- macOS 14 or later
- `git` — already present on macOS once Xcode Command Line Tools are installed
- `gh` ([GitHub CLI](https://cli.github.com)) — optional; required for GitHub pull requests
- `glab` ([GitLab CLI](https://gitlab.com/gitlab-org/cli)) — optional; required for GitLab merge requests

AI generation is optional. In Grove settings, choose either a signed-in Codex CLI or an OpenAI Chat Completions-compatible API. The API option accepts a base URL, model name, and API key, so it can be used with OpenAI or compatible providers without a ChatGPT subscription. Grove stores the API key only in the macOS Keychain.

GitHub and GitLab credentials are managed by their respective CLIs; Grove does not store a separate copy. Authenticate once with `gh auth login` or `glab auth login`. Without a platform's CLI, its review and CI/CD features are unavailable; local Git features still work.

For a self-hosted or internal GitLab, including HTTP and non-standard ports:

```sh
glab auth login --hostname 10.0.0.1 --api-host 10.0.0.1:8929 --api-protocol http
```

Grove decides which platform a repository belongs to from `origin` alone, so a repo with an internal GitLab origin and a GitHub backup remote will never show the backup repo's pull requests.

## Build

```sh
zsh scripts/build.sh
```

This produces `dist/Grove.app`. The script generates the icon, compiles a release build, assembles the bundle, and code-signs it (with your Apple Development certificate if you have one, ad-hoc otherwise).

### GitHub Actions

[CI](.github/workflows/ci.yml) runs on pushes to `main`, version tags (`v*`), pull requests, and manual dispatches. It runs `swift test`, builds and verifies the app, and packages an Apple Silicon (`arm64`) DMG using macOS 15 with Xcode 26.3. Download the DMG and its SHA-256 checksum from the run's artifact, retained for 14 days. Live API tests and visual render tests remain opt-in.

To publish a release, update `CFBundleShortVersionString` (three numeric components) and increment `CFBundleVersion` in `Support/Info.plist`, commit and push the changes, and wait for the `main` CI to pass. Then push a matching tag on the commit containing the version update, for example:

```sh
git tag -a v0.2.1 -m "Grove v0.2.1"
git push origin v0.2.1
```

The tag must match the plist version exactly (`v<version>`). The arm64 build must pass before CI creates a GitHub Release with generated notes, the DMG, and its checksum. An existing release is not overwritten; publish fixes under a new version. Manual runs only produce artifacts, even when a tag is selected.

No custom secrets are needed: publishing uses the built-in `GITHUB_TOKEN`. CI packages use ad-hoc signing and are not Apple-notarized, so macOS Gatekeeper may require explicit approval to open them.

CI also generates a `grove.rb` release asset using the DMG's actual checksum. After publishing, update `Casks/grove.rb` from that asset to make the new version available through the tap; see [Homebrew maintenance](docs/release/homebrew.md).

## What it does

**Project navigation.** Each project has a home page with separate review-request and CI/CD tabs, and a collapsible worktree list in the sidebar. Local and SSH copies of the same project are grouped by `origin`, with each worktree labelled by location. Review-request icons distinguish open, draft, merged, and closed requests, including historical requests linked to a branch.

**Worktrees.** Create one from a new branch, an existing local branch, or a remote branch. Grove suggests a path next to the repository (`<repo>-worktrees/<branch>`) so worktrees never show up inside each other's `git status`. Lock, unlock, prune, and delete — with a check for uncommitted work before deleting, and an option to remove the branch at the same time.

**Push.** One click when there is a single remote. With several remotes configured (say an internal GitLab as origin and a GitHub backup), the push button becomes a split button: the main area pushes to the branch's own upstream — exactly what `git push` does in a terminal — and the chevron opens a list of the other remotes, each labelled with its destination. Pushing to a non-upstream remote never silently retargets the branch's tracking.

**Tags.** Create a tag from the toolbar, a commit's context menu, or the commit header — annotated by default (with a message), or a lightweight pointer. The sheet suggests the next version number and offers to push right after creating. AI can generate an annotation from the selected commit's committed changes, excluding suspected credential-file contents and uncommitted work. Existing tags are pushed — picking the remote when there are several — or deleted from the same context menu; deletion only touches the local copy, since removing a remote tag requires an explicit push Grove won't do behind your back.

**Changes.** Per-worktree file list split into staged and unstaged, with a diff viewer that handles renames, binary files, mode-only changes, and merge-conflict combined diffs. Stage, unstage, discard, and commit. Draft commit messages survive switching between worktrees.

**Line-level staging.** Changed two lines but only want to commit one? Tick individual lines in the diff (or the hunk header to take the whole block), then stage, unstage, or discard just those. It works by carving a patch containing only the selected lines out of git's own diff and feeding it to `git apply` — see `Sources/Grove/Git/PatchBuilder.swift`, where the forward and reverse rules (which use opposite base sides) are spelled out.

**Rebase.** From a worktree's "⋯" menu: pick a target branch (remote or local) and Grove runs `git rebase --autostash <target>`. Before starting it spells out what will happen — how many commits get replayed, that their SHAs all change, and whether the branch is already pushed. If it stops on a conflict, a banner appears with Continue / Skip / Abort; without that, a conflict would strand you in the terminal.

**Conflict resolution.** When a merge, rebase, cherry-pick, or revert stops on conflicts, a banner offers Continue / Skip / Abort and a "Conflicts" section appears at the top of the change list. Open a conflicted file and the right pane shows it split into `<<<<<<<` blocks: each block can take the current change, the incoming change, or both; every choice is written to disk immediately and can be undone. Once every block is decided, "Mark as resolved" runs `git add`. Files with nothing to merge — deleted on one side, binary — get just "keep" / "delete". The pane spells out which branch "current" and "incoming" actually are, because during a rebase git's ours/theirs are inverted (HEAD sits on the rebase target, so "current" is the other branch) and nobody gets that right from memory. Marking a file resolved first counts the markers still left in it, and each write checks the file on disk against what Grove last saw so it never clobbers edits made in an external editor at the same time.

**History filtering.** Search commit messages, filter by author (the dropdown is ordered by commit count), limit to a path, and toggle between the current branch and all branches. Search terms are matched literally, not as regexes — searching for `foo(bar)` finds that string. An active filter is spelled out under the bar so a filtered view is never mistaken for missing commits. Long branch names do not crowd out the search field, and long commit bodies can be collapsed or scrolled independently of the file list and diff.

**Review requests (PR / MR).** Browse requests with check results, review state, merge conflicts, and cached AI review verdicts. Read discussions with code excerpts, jump to the relevant diff line, start a line comment, reply, request changes, approve, and merge. Filter discussions by all, unresolved, or resolved; resolved discussions collapse by default and outdated comments are marked. The detail page separates conversation from status and discussion navigation, with collapsible navigation in narrow windows. Labels follow the platform: GitLab uses merge requests and `!123`. Check a PR out as a new worktree — same-repo PRs get a tracking branch you can push back to, fork PRs get a local `pr-<number>` branch fetched via `pull/<number>/head`. Create a request from the current worktree (Grove pushes the branch first). Merge with squash, merge commit, or rebase, and resolve or reopen discussions where the platform and your permissions allow it.

**AI Review.** Configure project review instructions and choose review areas, with temporary overrides for an individual review. Large diffs are grouped by related files and their results combined; omitted or truncated content is reported, and suspected credential-file contents are excluded from review prompts. Risk findings can be published to GitHub / GitLab discussions, with line locations matched to the diff — but publishing is never silent: manual reviews are never auto-published (publish findings one by one from the review page), and per-project automatic review only generates results and notifies you; posting findings to discussions is a separate per-project opt-in that is off by default. Re-review considers existing discussions, replies, and resolution state to verify whether reported problems remain. With AI configured and enabled, automatic review can be controlled per project: while Grove is running, it checks every minute and reviews new PRs / MRs; later pushes trigger a notification so you decide whether to re-review. Settings show the last three days of AI calls, including model, trigger, duration, result, and token usage returned by the service, without storing keys, prompts, or source bodies in the log.

**CI/CD.** View pipelines, jobs, and logs from the project home page. After a push, Grove tracks the pipeline and reports its result through a system notification.

**SSH repositories.** Add a remote server and manage its Git projects directly, including commits, synchronization, worktrees, conflict resolution, and file editing. Remote worktrees appear alongside local copies of the same project.

**Linkage.** Every worktree shows the PR for its branch, and every PR shows whether it is already checked out. This is the point of the app.

## Diagnostics

```sh
dist/Grove.app/Contents/MacOS/Grove --doctor [path]
```

Prints where `git` and `gh` were found, the PATH handed to child processes, whether `gh` is authenticated, then the repository's worktrees, their status, their linked PRs, and the open PR list. Most reports of "Grove can't see my repository" come down to something this makes obvious in one screen.

## Design notes

**Grove shells out to `git` rather than linking libgit2.** Worktrees are the whole point of this app, and libgit2's support for them has never been complete — `git worktree add` alone has a lot of semantics that would need reimplementing. Shelling out means the behavior matches what the user gets in their terminal, and the porcelain formats have a backward-compatibility guarantee.

**Review access goes through the platform CLIs (`gh` / `glab`) rather than authenticating with the APIs directly.** Direct authentication would mean implementing OAuth device flow, storing tokens in the Keychain, and handling refresh — reinventing what the CLIs already do, including self-hosted authentication. Grove does not store separate GitHub or GitLab credentials. Platform differences — pull requests vs. merge requests, `#` vs. `!`, approval models, pipelines vs. checks — are handled by the two `ForgeClient` implementations, while the UI uses a shared model.

**Running commands from a GUI is where the real bugs are.** `Sources/Grove/Git/ProcessRunner.swift` documents four that this app hit or would have: pipe-buffer deadlock on large output, git blocking on a credential prompt nobody can answer, commands that never terminate, and background grandchildren (`git gc --auto`) holding the stdout pipe open long after git itself exited. `Sources/Grove/Git/ToolLocator.swift` covers a fifth: apps launched from Finder inherit a PATH that does not contain Homebrew.

## Tests

```sh
swift test
```

The parsers (worktree list, status porcelain v2, for-each-ref, log, unified diff, `gh` JSON) are pure functions covered by unit tests. `ProcessRunner` is covered by tests that fork real processes, because pipe deadlocks and thread-affinity hangs only reproduce against real kernel behavior.

Layout has a separate offscreen render harness that renders the real views to PNGs for visual inspection:

```sh
GROVE_RENDER=1 swift test --filter LayoutRenderHarness   # writes /tmp/grove-render-*.png
```

SwiftUI layout bugs — a view that fails to fill its container, content clipped, elements pushed outside the visible area — are invisible to the compiler and to assertions. You have to look. Skipped by default so it does not slow down normal test runs.
