---
name: clean-dev-caches
description: Free disk space on a developer machine by clearing regenerable caches (npm, Bun, Yarn, pnpm, Homebrew, pip, uv, Go, Gradle, CocoaPods, Xcode DerivedData, old Playwright/Puppeteer browsers, VS Code and JetBrains caches, Docker build cache), stale project build outputs (.next, .turbo, .nuxt, Rust target), and git worktrees whose work is already merged. Use when the user says their disk is full, asks to free up space, clear dev caches, clean build artifacts, or prune old worktrees. macOS first; most paths also work on Linux.
---

# Clean dev caches

Everything here is about deleting files, so the job is mostly judgment: delete only what
rebuilds itself, skip anything in use, and report what actually got freed.

The bundled script does the measuring and deleting. Run it with `bash`, not as a zsh snippet:
`scripts/devclean.sh` (relative to this skill's folder).

```bash
bash scripts/devclean.sh scan              # what can be freed; deletes nothing
bash scripts/devclean.sh clean --yes       # delete every "ready" cache in the default tier
bash scripts/devclean.sh clean --only npm,gradle --yes
bash scripts/devclean.sh scan --deep       # also Maven, Go modules, Cargo sources, NuGet
bash scripts/devclean.sh builds ~/projects # .next/.turbo/... under a folder (add --yes to delete)
bash scripts/devclean.sh worktrees ~/projects/my-repo   # report only
bash scripts/devclean.sh list              # every cache id
```

`clean` and `builds` are dry runs until `--yes` is passed.

## Workflow

1. **Measure.** Run `df -h ~` for the starting free space, then `devclean.sh scan`. Show the
   user the table: each row is a cache, its size, and `ready` or `skip` with the reason.
2. **Agree on scope.** If the user already asked you to clean, go ahead with the default
   tier. Otherwise list the big rows and ask. Always ask before `--deep` (those take a long
   time to download again) and before anything in the "Not touched" section.
3. **Clean.** `devclean.sh clean --yes`, or `--only id,id` to clean less. Rows marked `skip`
   are skipped on their own. Don't work around them by deleting the path yourself.
4. **Build outputs (optional).** Ask which folder holds their projects (common ones:
   `~/projects`, `~/code`, `~/dev`, `~/src`, `~/Developer`). Run `builds DIR`, show it, and
   only then use `builds DIR --yes`. A project with any running process inside it is
   skipped. That covers dev servers, editors' terminals and other agents.
5. **Worktrees (optional).** `worktrees REPO` labels each linked worktree:
   - `SAFE`: no uncommitted changes, and every commit is in the default branch (or its PR
     was merged and every commit is pushed).
   - `KEEP`: open PR, commits that exist only locally, or a process running in it.
   - `REVIEW`: uncommitted changes or unmerged commits. Look before you suggest anything.
     For uncommitted changes, check whether the default branch already has the same lines.

   Show the table and remove only what the user approves. Right before removing, re-check
   that nothing is running in that worktree, because agents and terminals start up all the
   time. Use `git worktree remove --force <path>` and keep the branches.
6. **Report.** Run `df -h ~` again and give the change in free space as the result. Also
   list what was skipped and why, plus the "Not touched" items with the commands the user
   could run themselves.

## Things to know

- **`du` overstates what deleting frees on APFS.** Package managers (Bun, pnpm, npm via
  clonefile) and copied worktrees share disk blocks. Removing a 1.7 GB worktree can free
  50 MB. Never promise a number from `du` alone. The `df` change after cleaning is the truth.
- **Never delete these without an explicit request for that item:** Docker images or
  volumes (volumes often hold local databases), Android AVDs, iOS DeviceSupport, Xcode
  Archives (shipped builds), simulator devices, browser profiles, `node_modules`, the
  Trash, or `~/Library/Caches` as a whole. Spotify and browser caches aren't dev caches.
- **Check that nothing uses it first.** The script skips Gradle while a daemon runs, Xcode,
  VS Code and JetBrains caches while those apps are open, package-manager caches during an
  install, and Docker when the daemon is down. If the user wants a skipped one cleaned,
  ask them to quit the app (or run `gradle --stop`) and scan again.
- **Shell traps the script avoids** (keep this in mind when running your own commands):
  zsh aborts the whole command on an unmatched glob such as `AndroidStudio*`. zsh expands a
  bare `=word` (`echo ====` fails). Some machines put a non-coreutils `head`/`du` early on
  PATH (XAMPP ships a perl `head`). Use `/usr/bin/head` or run under `bash`.
- After a big cache clean, the next `npm install`, `bun install`, Gradle build or Docker
  build is slower while it downloads again. Mention that once.
