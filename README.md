# clean-dev-caches

A [Claude Code](https://claude.com/claude-code) skill, and a standalone bash script, that
frees disk space on a developer machine without breaking anything you're using.

It clears caches that rebuild on their own: package managers, build tools, browser
binaries for test runners, IDE caches and Docker's build cache. It also finds stale project
build outputs (`.next`, `.turbo`, `target`, ...) and git worktrees whose work is already
merged. It always dry-runs first and skips anything that's in use. It reports what was
actually freed from the change in free space, not an estimate.

On one MacBook the first run took free space from 57 GB to 95 GB.

## What it cleans

| Default (`scan` / `clean`) | Opt-in (`--deep`, slow to re-download) |
|---|---|
| npm, Bun, Yarn, pnpm (prune) | Maven `~/.m2/repository` |
| Homebrew downloads and old versions | Go module cache |
| pip, uv | Cargo extracted sources and git checkouts |
| Go build cache, Gradle caches, CocoaPods | NuGet packages |
| Xcode DerivedData and unavailable simulators | |
| Playwright and Puppeteer browsers (**older versions only**; the newest is kept) | |
| node-gyp, TypeScript, Electron, Deno, Composer, Cargo crate archives | |
| VS Code and JetBrains caches | |
| Docker **build cache** (`docker builder prune`) | |

**Skipped automatically while in use:** Gradle while a daemon runs, Xcode, VS Code and
JetBrains while open, package-manager caches during an install, Docker when the daemon is
down, and any project or worktree with a running process inside it (dev servers,
terminals, other agents).

**Never deleted, only reported:** Docker images and volumes, Android emulators, iOS
DeviceSupport, Xcode Archives, simulator devices, browser profiles, `node_modules`, and
`~/Library/Caches` as a whole.

## Install as a Claude Code skill

As a plugin:

```
/plugin marketplace add Adrian-stuff/clean-dev-caches
/plugin install clean-dev-caches@clean-dev-caches
```

Or copy the skill folder:

```bash
git clone https://github.com/Adrian-stuff/clean-dev-caches.git
cp -R clean-dev-caches/skills/clean-dev-caches ~/.claude/skills/
```

Then ask Claude something like *"my disk is almost full, clear my dev caches"*. Claude
measures first, shows you the table, cleans what you agree to, and reports the real
amount freed.

## Use the script directly

No Claude needed. It's bash 3.2 compatible, so it runs on stock macOS.

```bash
S=skills/clean-dev-caches/scripts/devclean.sh
bash $S scan                     # what can be freed (deletes nothing)
bash $S clean                    # dry run
bash $S clean --yes              # delete every "ready" cache
bash $S clean --only npm,gradle --yes
bash $S scan --deep              # include Maven, Go modules, Cargo sources, NuGet
bash $S builds ~/projects        # stale .next/.turbo/... (add --yes to delete)
bash $S worktrees ~/code/my-repo # SAFE / KEEP / REVIEW for each git worktree
bash $S list                     # every cache id
```

Example `scan`:

```
ID              SIZE  STATUS   WHAT
npm              10G  ready    npm cache
bun             7.5G  ready    Bun install cache
gradle          9.0G  skip     Gradle caches  — a Gradle daemon is running (gradle --stop)
docker          8.5G  ready    Docker build cache (never images or volumes)

Ready to free: about 26G (sizes from du; see the note below).
```

## A note on the numbers

On APFS, package managers and copied worktrees share disk blocks (clones), so `du` counts
the same bytes many times. A worktree that `du` calls 1.7 GB may free 50 MB when removed.
The script reports the change in free space (`df`) after cleaning, and that's the number
to trust.

## License

MIT
