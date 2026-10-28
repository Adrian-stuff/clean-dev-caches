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

## Install the `devclean` command

With Homebrew:

```bash
brew tap Adrian-stuff/clean-dev-caches https://github.com/Adrian-stuff/clean-dev-caches
brew trust adrian-stuff/clean-dev-caches   # recent Homebrew asks before loading a third-party tap
brew install devclean
```

Or with the install script, which puts it in `~/.local/bin` (`PREFIX=/usr/local` changes that):

```bash
curl -fsSL https://raw.githubusercontent.com/Adrian-stuff/clean-dev-caches/main/install.sh | bash
# also install the Claude Code skill:
curl -fsSL https://raw.githubusercontent.com/Adrian-stuff/clean-dev-caches/main/install.sh | bash -s -- --skill
```

It's a single bash script with no dependencies, so you can also just download it and run it.

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

## Use it from the terminal

No Claude needed. It's bash 3.2 compatible, so it runs on stock macOS. With `devclean`
installed, replace `bash $S` below with `devclean`.

```bash
S=skills/clean-dev-caches/scripts/devclean.sh
bash $S scan                     # what can be freed (deletes nothing)
bash $S clean                    # dry run
bash $S clean --yes              # delete every "ready" cache
bash $S clean --only npm,gradle --yes
bash $S scan --deep              # include Maven, Go modules, Cargo sources, NuGet
bash $S builds ~/projects --older-than 30   # .next/.turbo/... not rebuilt in 30 days (add --yes)
bash $S builds ~/projects --older-than 90 --node-modules   # + node_modules of idle projects
bash $S worktrees ~/code/my-repo # SAFE / KEEP / REVIEW for each git worktree
bash $S suggest                  # bigger wins beyond caches (report only)
bash $S tools                    # AI coding CLIs and global tools you stopped using (report only)
bash $S list                     # every cache id
```

### `suggest`: where the rest of your disk went

Caches are only part of the story. `suggest` deletes nothing. It lists the other usual
suspects, biggest first, each with how to deal with it:

```
    SIZE  WHAT  →  HOW
   12.8G  Downloads: 65 installers and archives (.dmg .pkg .iso .xip .zip)
          →  Delete the ones already installed or extracted
    9.3G  Ollama models
          →  ollama list, then ollama rm <model> for ones you no longer run
    7.8G  Colima VM
          →  You also have Docker Desktop — keep one runtime. colima prune clears its download cache; ...
    5.8G  Android emulator payroll_test
          →  Delete it in Android Studio > Device Manager if unused
    5.0G  Docker images no container uses
          →  docker image ls, then docker image rm <id> (or docker image prune -a)
    1.0G  node_modules in 3 projects idle for 90+ days (du overstates on APFS)
          →  devclean.sh builds ~/projects --older-than 90 --node-modules --yes
```

It looks at:
- Downloads
- idle `node_modules` and build outputs
- unused Docker images
- Colima, OrbStack, Parallels, VirtualBox and UTM VMs
- Ollama, Hugging Face and LM Studio models
- Android emulators and system images
- iOS DeviceSupport, Xcode Archives, simulators and extra Xcode versions
- iPhone backups
- extra Node, Rust, Python and Java versions (nvm, fnm, Volta, rustup, pyenv, SDKMAN)
- Conda packages and orphaned Homebrew packages
- big app caches, files over 1 GB, and Time Machine local snapshots

### `tools`: AI coding CLIs and other tools you stopped using

Coding harnesses pile up quickly, and each one keeps gigabytes of sessions, runtimes and
caches. `tools` finds them, reports when each was last used, and says how to remove it the
way it was installed. It deletes nothing.

```
AI coding tools and model runners
VERDICT   TOOL                 LAST USED   INSTALL     DATA  HOW TO REMOVE
IN USE    Claude Code          0d ago            -     1.6G  rm ~/.local/bin/claude; then rm -rf ~/.claude ...
USED      Codex CLI            14d ago           -     2.4G  rm ~/.local/bin/codex; then rm -rf ~/.codex ~/.cache/codex-runtimes
LEFTOVER  Aider                -                 -      12M  rm -rf ~/.aider ~/.cache/aider
UNUSED    Kilo Code CLI        79d ago         28K      65M  bun remove -g @kilocode/cli; then rm -rf ~/.cache/kilo ...
UNUSED    Goose                79d ago        301M       6M  brew uninstall block-goose-cli; then rm -rf ~/.config/goose ...

Other global command-line tools not used in 60+ days
    SIZE  LAST RUN   COMMAND                    HOW TO REMOVE
    2.9G  79d ago    omniroute                  npm uninstall -g omniroute
    296M  65d ago    mysqld                     brew uninstall mysql
      9M  113d ago   fast                       rm ~/go/bin/fast
```

- **What it knows:** Claude Code, OpenCode, Codex, Gemini CLI, Qwen Code, Kilo Code, Aider,
  Goose, Amp, Crush, Cursor, Windsurf, Factory Droid, GitHub Copilot CLI, Cline, Augment,
  Continue, Kiro, OpenHands, Plandex, Antigravity, Ollama and LM Studio.
- **Other tools:** Homebrew formulae you installed yourself (not their dependencies), plus
  global npm, Bun and pnpm packages, pipx and uv tools, and `cargo install` and
  `go install` binaries.
- **How "last used" works:** it's the later of when the command last ran (the file's access
  time) and when the tool last wrote its sessions or logs. `--older-than DAYS` (default 60)
  sets the idle threshold. Running a tool, even with `--version`, makes it look used again,
  so the report never does.

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
