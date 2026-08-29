# Grove

[中文说明](README.zh-CN.md)

Grove is a native macOS app for working with git worktrees and code review requests — GitHub pull requests and GitLab merge requests — in one place.

Worktrees let you keep several branches checked out at once, in separate directories, sharing a single clone. That is exactly what you want when a review lands while you are mid-feature — but the command line makes you juggle paths, and every other git GUI treats worktrees as an afterthought. Grove puts them front and center: the sidebar is a list of worktrees, each showing its branch, its uncommitted changes, and the state of its pull request.

The workflow it is built around: see a PR, check it out as a new worktree with one click, review or fix it without touching what you were doing, then delete the worktree and its branch when it merges.

## Requirements

- macOS 14 or later
- `git` — already present on macOS once Xcode Command Line Tools are installed
- `gh` ([GitHub CLI](https://cli.github.com)) — optional; required for GitHub pull requests
- `glab` ([GitLab CLI](https://gitlab.com/gitlab-org/cli)) — optional; required for GitLab merge requests

For a self-hosted GitLab on a non-standard port: `glab auth login --hostname 10.0.0.1 --api-host 10.0.0.1:8929 --api-protocol http`. Grove decides which platform a repository belongs to from `origin` alone, so a repo with an internal GitLab origin and a GitHub backup remote will never show the backup repo's pull requests.

Grove never stores credentials. All GitHub access goes through `gh`, which you authenticate once with `gh auth login`. Without `gh`, everything except the PR features works normally.

## Build

```sh
zsh scripts/build.sh
```

This produces `dist/Grove.app`. The script generates the icon, compiles a release build, assembles the bundle, and code-signs it (with your Apple Development certificate if you have one, ad-hoc otherwise).

## What it does

**Worktrees.** Create one from a new branch, an existing local branch, or a remote branch. Grove suggests a path next to the repository (`<repo>-worktrees/<branch>`) so worktrees never show up inside each other's `git status`. Lock, unlock, prune, and delete — with a check for uncommitted work before deleting, and an option to remove the branch at the same time.

**Push.** One click when there is a single remote. With several remotes configured (say an internal GitLab as origin and a GitHub backup), the push button becomes a split button: the main area pushes to the branch's own upstream — exactly what `git push` does in a terminal — and the chevron opens a list of the other remotes, each labelled with its destination. Pushing to a non-upstream remote never silently retargets the branch's tracking.

**Changes.** Per-worktree file list split into staged and unstaged, with a diff viewer that handles renames, binary files, mode-only changes, and merge-conflict combined diffs. Stage, unstage, discard, and commit. Draft commit messages survive switching between worktrees.

**Line-level staging.** Changed two lines but only want to commit one? Tick individual lines in the diff (or the hunk header to take the whole block), then stage, unstage, or discard just those. It works by carving a patch containing only the selected lines out of git's own diff and feeding it to `git apply` — see `Sources/Grove/Git/PatchBuilder.swift`, where the forward and reverse rules (which use opposite base sides) are spelled out.

**Rebase.** From a worktree's "⋯" menu: pick a target branch (remote or local) and Grove runs `git rebase --autostash <target>`. Before starting it spells out what will happen — how many commits get replayed, that their SHAs all change, and whether the branch is already pushed. If it stops on a conflict, a banner appears with Continue / Skip / Abort; without that, a conflict would strand you in the terminal.

**History filtering.** Search commit messages, filter by author (the dropdown is ordered by commit count), limit to a path, and toggle between the current branch and all branches. Search terms are matched literally, not as regexes — searching for `foo(bar)` finds that string. An active filter is spelled out under the bar so a filtered view is never mistaken for missing commits.

**Pull requests.** Browse open PRs with their check results and review state. Check one out as a new worktree — same-repo PRs get a tracking branch you can push back to, fork PRs get a local `pr-<number>` branch fetched via `pull/<number>/head`. Create a PR from the current worktree (Grove pushes the branch first). Merge with squash, merge commit, or rebase.

**Linkage.** Every worktree shows the PR for its branch, and every PR shows whether it is already checked out. This is the point of the app.

## Diagnostics

```sh
dist/Grove.app/Contents/MacOS/Grove --doctor [path]
```

Prints where `git` and `gh` were found, the PATH handed to child processes, whether `gh` is authenticated, then the repository's worktrees, their status, their linked PRs, and the open PR list. Most reports of "Grove can't see my repository" come down to something this makes obvious in one screen.

## Design notes

**Grove shells out to `git` rather than linking libgit2.** Worktrees are the whole point of this app, and libgit2's support for them has never been complete — `git worktree add` alone has a lot of semantics that would need reimplementing. Shelling out means the behavior matches what the user gets in their terminal, and the porcelain formats have a backward-compatibility guarantee.

**PR access goes through `gh` rather than the GitHub API.** Talking to the API directly would mean implementing OAuth device flow, storing a token in the Keychain, and handling refresh — reinventing what `gh` already does well. As a bonus, Grove holds no credentials at all, so there is nothing to leak.

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
