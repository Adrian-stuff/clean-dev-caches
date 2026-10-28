#!/usr/bin/env bash
# devclean — find and clear regenerable developer caches on macOS (and most of Linux).
#
#   devclean.sh scan [--deep]                      what can be freed, nothing deleted
#   devclean.sh clean [--deep] [--only a,b] [--yes] delete caches (dry run without --yes)
#   devclean.sh builds DIR... [--yes]              .next/.turbo/target/... under DIR (dry run without --yes)
#   devclean.sh worktrees REPO                     which git worktrees are safe to remove (report only)
#
# Everything this deletes is rebuilt or re-downloaded on demand. It never touches
# Docker images or volumes, emulators, simulators' data, browser profiles, or git work.
# Written for bash 3.2 (the macOS default): no associative arrays, no mapfile.

set -uo pipefail
# System tools first: a stray `head`, `du` or `sort` earlier on PATH (XAMPP ships a perl
# `head`, for one) silently breaks the parsing below.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

H="$HOME"
LC="$H/Library/Caches"
AS="$H/Library/Application Support"

# id|tier|label|path;path;...   (tier: safe = default, deep = opt-in with --deep)
TARGETS="
npm|safe|npm cache|$H/.npm/_cacache;$H/.npm/_npx;$H/.npm/_logs
bun|safe|Bun install cache|$H/.bun/install/cache;$LC/bun
yarn|safe|Yarn cache|$LC/Yarn;$H/.yarn/berry/cache;$H/.cache/yarn
pnpm|safe|pnpm store (prune removes only unreferenced packages)|$H/Library/pnpm/store;$H/.local/share/pnpm/store
brew|safe|Homebrew downloads and old versions|$LC/Homebrew;$H/.cache/Homebrew
pip|safe|pip cache|$LC/pip;$H/.cache/pip
uv|safe|uv cache|$H/.cache/uv;$LC/uv
go|safe|Go build cache|$LC/go-build;$H/.cache/go-build
gradle|safe|Gradle caches|$H/.gradle/caches
cocoapods|safe|CocoaPods cache|$LC/CocoaPods
xcode|safe|Xcode DerivedData and unavailable simulators|$H/Library/Developer/Xcode/DerivedData;$LC/com.apple.dt.Xcode
playwright|safe|Playwright browsers (older revisions only)|$LC/ms-playwright;$H/.cache/ms-playwright
puppeteer|safe|Puppeteer browsers (older versions only)|$H/.cache/puppeteer
nodegyp|safe|node-gyp headers|$LC/node-gyp;$H/.cache/node-gyp
tsc|safe|TypeScript server cache|$LC/typescript
electron|safe|Electron downloads|$LC/electron;$H/.cache/electron
deno|safe|Deno cache|$LC/deno;$H/.cache/deno
composer|safe|Composer cache|$LC/composer;$H/.cache/composer;$H/.composer/cache
cargo|safe|Cargo downloaded crate archives|$H/.cargo/registry/cache
vscode|safe|VS Code caches|$AS/Code/Cache;$AS/Code/CachedData;$AS/Code/CachedExtensionVSIXs;$H/.config/Code/Cache;$H/.config/Code/CachedData
jetbrains|safe|JetBrains IDE caches|$LC/JetBrains;$H/.cache/JetBrains
docker|safe|Docker build cache (never images or volumes)|
maven|deep|Maven local repository|$H/.m2/repository
gomod|deep|Go module cache|$H/go/pkg/mod
cargosrc|deep|Cargo extracted sources and git checkouts|$H/.cargo/registry/src;$H/.cargo/git/checkouts
nuget|deep|NuGet packages|$H/.nuget/packages
"

# Things worth knowing about that this script never deletes.
REPORT_ONLY="
Android emulators (AVDs)|$H/.android/avd
iOS DeviceSupport (old iOS versions)|$H/Library/Developer/Xcode/iOS DeviceSupport
Xcode Archives (shipped builds)|$H/Library/Developer/Xcode/Archives
Simulator devices|$H/Library/Developer/CoreSimulator/Devices
"

# ---------- helpers ----------

have() { command -v "$1" >/dev/null 2>&1; }

human() { # KiB -> 1.2G
  awk -v k="${1:-0}" 'BEGIN{ if(k>=1048576) printf "%.1fG",k/1048576; else if(k>=1024) printf "%.0fM",k/1024; else printf "%dK",k }'
}

size_k() { # total KiB of the given paths
  local t=0 s p
  for p in "$@"; do
    [ -e "$p" ] || continue
    s=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
    t=$((t + ${s:-0}))
  done
  echo "$t"
}

free_k() { df -k "$H" | awk 'NR==2{print $4}'; }

with_timeout() { # with_timeout SECONDS cmd... — macOS has no `timeout`
  local secs=$1; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local w=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

running() { pgrep -f "$1" >/dev/null 2>&1; }

field() { echo "$1" | cut -d'|' -f"$2"; }

target_line() { echo "$TARGETS" | grep "^$1|"; }

# Working directories and command lines of every process the user can see.
PROC_CWDS=""; PROC_CMDS=""
load_procs() {
  [ -n "$PROC_CWDS" ] || PROC_CWDS=$(lsof -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u)
  [ -n "$PROC_CMDS" ] || PROC_CMDS=$(ps -axo command= 2>/dev/null)
}

in_use() { # in_use DIR -> true when some process runs inside DIR or was started from a file in it
  load_procs
  printf '%s\n' "$PROC_CWDS" | awk -v d="$1" '$0==d || index($0, d"/")==1 {f=1} END{exit !f}' && return 0
  printf '%s\n' "$PROC_CMDS" | grep -qF -- "$1/"
}

# ---------- what each target would delete ----------

# Default: the listed paths that exist. Overridden where only part of a dir is stale.
candidates() {
  local id=$1 p
  if type "candidates_$id" >/dev/null 2>&1; then "candidates_$id"; return; fi
  local IFS=';'
  for p in $(field "$(target_line "$id")" 4); do [ -e "$p" ] && printf '%s\n' "$p"; done
}

# Playwright keeps one dir per browser revision (chromium-1208, chromium-1228...); keep the newest of each.
candidates_playwright() {
  local base d n prefix newest
  for base in "$LC/ms-playwright" "$H/.cache/ms-playwright"; do
    [ -d "$base" ] || continue
    for d in "$base"/*-[0-9]*; do
      [ -d "$d" ] || continue
      n=$(basename "$d"); prefix=${n%-*}
      newest=$(ls -d "$base/$prefix"-[0-9]* 2>/dev/null | sed 's/.*-//' | sort -n | tail -1)
      [ "${n##*-}" != "$newest" ] && printf '%s\n' "$d"
    done
  done
}

# Puppeteer: ~/.cache/puppeteer/<browser>/<platform>-<version>; keep the newest per browser.
candidates_puppeteer() {
  local b newest d
  for b in "$H/.cache/puppeteer"/*/; do
    [ -d "$b" ] || continue
    newest=$(ls -1 "$b" 2>/dev/null | sort -V | tail -1)
    for d in "$b"*; do [ -d "$d" ] && [ "$(basename "$d")" != "$newest" ] && printf '%s\n' "${d%/}"; done
  done
}

candidates_docker() { :; }

# ---------- reasons to skip a target right now ----------

busy() { # prints a reason and succeeds when the target should be skipped
  case $1 in
    npm) running 'npm (install|ci)' && echo "npm install is running" ;;
    bun) running 'bun (install|add|i )' && echo "bun install is running" ;;
    yarn) running 'yarn( install)?$' && echo "yarn is running" ;;
    pnpm) have pnpm || { echo "pnpm not installed (prune needs it)"; return 0; }
          running 'pnpm (install|add|i )' && echo "pnpm install is running" ;;
    gradle) running 'GradleDaemon|GradleWrapperMain' && echo "a Gradle daemon is running (gradle --stop)" ;;
    xcode) running '/Xcode.app/Contents/MacOS/Xcode' && echo "Xcode is open" ;;
    cocoapods) running '(^|/)pod ' && echo "pod is running" ;;
    vscode) running 'Visual Studio Code.app/Contents/MacOS|/usr/share/code/code' && echo "VS Code is open" ;;
    jetbrains) running 'IntelliJ|WebStorm|PyCharm|GoLand|PhpStorm|RubyMine|CLion|Rider|DataGrip|Android Studio' && echo "a JetBrains IDE is open" ;;
    docker) have docker || { echo "docker not installed"; return 0; }
            with_timeout 10 docker info >/dev/null 2>&1 && return 1
            echo "Docker is not running" ;;
    *) return 1 ;;
  esac
}

size_of() { # KiB a target would free
  local id=$1
  if [ "$id" = docker ]; then
    # docker system df reports "7.806GB" / "7.806GB (91%)"
    docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null |
      awk -F'|' '$1=="Build Cache"{v=$2; sub(/ .*/,"",v); n=v+0; u=v; gsub(/[0-9.]/,"",u);
        m=(u=="TB"?1073741824:u=="GB"?1048576:u=="MB"?1024:u=="kB"?1:0); printf "%d", n*m}'
    return
  fi
  local list=() p
  while IFS= read -r p; do [ -n "$p" ] && list+=("$p"); done < <(candidates "$id")
  [ ${#list[@]} -gt 0 ] && size_k "${list[@]}" || echo 0
}

# ---------- cleaning ----------

clean_target() {
  local id=$1 p
  case $id in
    bun) have bun && bun pm cache rm >/dev/null 2>&1 ;;
    brew) have brew && brew cleanup -s --prune=all >/dev/null 2>&1 ;;
    pnpm) pnpm store prune >/dev/null 2>&1; return ;;
    uv) have uv && uv cache clean >/dev/null 2>&1 ;;
    go) have go && go clean -cache >/dev/null 2>&1 ;;
    gomod) have go && go clean -modcache >/dev/null 2>&1; return ;; # files are read-only; rm -rf fails
    docker) docker builder prune -af >/dev/null 2>&1; return ;;
    xcode) have xcrun && xcrun simctl delete unavailable >/dev/null 2>&1 ;;
  esac
  while IFS= read -r p; do
    [ -n "$p" ] && [ -e "$p" ] && rm -rf "$p" 2>/dev/null
  done < <(candidates "$id")
}

selected_ids() { # selected_ids DEEP ONLY
  local deep=$1 only=$2 line id tier
  echo "$TARGETS" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=$(field "$line" 1); tier=$(field "$line" 2)
    if [ -n "$only" ]; then
      case ",$only," in *",$id,"*) echo "$id" ;; esac
    elif [ "$tier" = safe ] || [ "$deep" = 1 ]; then
      echo "$id"
    fi
  done
}

cmd_scan() {
  local deep=$1 only=$2 total=0 id line k why status
  printf '%-11s %8s  %-8s %s\n' ID SIZE STATUS WHAT
  for id in $(selected_ids "$deep" "$only"); do
    line=$(target_line "$id")
    k=$(size_of "$id"); k=${k:-0}
    if why=$(busy "$id"); then status=skip; else status=ready; why=""; fi
    [ "$k" -eq 0 ] && continue # nothing there
    [ "$status" = ready ] && total=$((total + k))
    printf '%-11s %8s  %-8s %s%s\n' "$id" "$(human "$k")" "$status" "$(field "$line" 3)" "${why:+  — $why}"
  done
  echo
  echo "Ready to free: about $(human "$total") (sizes from du; see the note below)."
  if [ "$deep" != 1 ] && [ -z "$only" ]; then
    local dk=0
    for id in $(echo "$TARGETS" | awk -F'|' '$2=="deep"{print $1}'); do dk=$((dk + $(size_of "$id"))); done
    [ "$dk" -gt 0 ] && echo "Deep caches (--deep; slow to re-download): another $(human "$dk")."
  fi
  echo
  echo "Not touched by this script — decide yourself:"
  echo "$REPORT_ONLY" | while IFS='|' read -r label p; do
    [ -n "$label" ] && [ -e "$p" ] && printf '  %8s  %s  (%s)\n' "$(human "$(size_k "$p")")" "$label" "$p"
  done
  if have docker && with_timeout 10 docker info >/dev/null 2>&1; then
    docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null |
      awk -F'|' '$1=="Images"{printf "  %8s  Docker images, %s unused (docker image prune -a)\n",$2,$3}
                 $1=="Local Volumes"{printf "  %8s  Docker volumes, %s unused — may hold databases (docker volume prune)\n",$2,$3}'
  fi
  echo
  echo "Note: on APFS, copies made by package managers share disk blocks (clones), so du can"
  echo "overstate what deleting frees. The real number is the change in free space after clean."
}

cmd_clean() {
  local deep=$1 only=$2 yes=$3 id why before after
  if [ "$yes" != 1 ]; then
    echo "Dry run — nothing deleted. Re-run with --yes to delete:"
    echo
    cmd_scan "$deep" "$only"
    return
  fi
  before=$(free_k)
  for id in $(selected_ids "$deep" "$only"); do
    if why=$(busy "$id"); then echo "skip  $id — $why"; continue; fi
    [ "$(size_of "$id")" -gt 0 ] || continue
    clean_target "$id"
    local left; left=$(size_of "$id")
    if [ "${left:-0}" -gt 1024 ] && [ "$id" != pnpm ]; then
      echo "part  $id — $(human "$left") left (permission denied or in use)"
    else
      echo "done  $id"
    fi
  done
  after=$(free_k)
  echo
  echo "Free space: $(human "$before") -> $(human "$after") (freed $(human $((after - before))))."
}

# ---------- project build outputs ----------

cmd_builds() {
  local yes=$1; shift
  local total=0 d k root
  [ $# -gt 0 ] || { echo "usage: devclean.sh builds DIR... [--yes]" >&2; return 2; }
  printf '%8s  %-6s %s\n' SIZE STATUS PATH
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    root=$(dirname "$d")
    # Rust's target/ only when it sits next to a Cargo.toml.
    [ "$(basename "$d")" = target ] && [ ! -f "$root/Cargo.toml" ] && continue
    k=$(size_k "$d")
    if in_use "$root"; then
      printf '%8s  %-6s %s  — a process is running in this project\n' "$(human "$k")" skip "$d"
      continue
    fi
    total=$((total + k))
    if [ "$yes" = 1 ]; then rm -rf "$d" 2>/dev/null; printf '%8s  %-6s %s\n' "$(human "$k")" deleted "$d"
    else printf '%8s  %-6s %s\n' "$(human "$k")" ready "$d"; fi
  done < <(find "$@" \( -name node_modules -o -name .git \) -prune -o -type d \
             \( -name .next -o -name .turbo -o -name .nuxt -o -name .svelte-kit -o -name .parcel-cache \
                -o -name .angular -o -name .expo -o -name target \) -print -prune 2>/dev/null)
  echo
  if [ "$yes" = 1 ]; then echo "Deleted about $(human "$total")."
  else echo "About $(human "$total") ready. Re-run with --yes to delete; the next dev/build recreates them."; fi
}

# ---------- git worktrees ----------

cmd_worktrees() {
  local repo=${1:-}
  [ -n "$repo" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "usage: devclean.sh worktrees REPO" >&2; return 2; }
  repo=$(cd "$repo" && git rev-parse --show-toplevel)
  git -C "$repo" fetch -q --all --prune 2>/dev/null
  local base; base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  echo "Compared against $base. Report only — remove with: git worktree remove --force <path> (branches are kept)."
  echo
  printf '%-8s %-30s %-34s %-10s %-5s %-8s %-9s %-10s %s\n' VERDICT WORKTREE BRANCH LAST MODS UNPUSHD UNMERGED PR WHY
  local wt branch last mods unpushed unmerged pr verdict why
  git -C "$repo" worktree list --porcelain | sed -n 's/^worktree //p' | tail -n +2 | while IFS= read -r wt; do
    [ -d "$wt" ] || { printf '%-8s %-30s %s\n' PRUNE "$(basename "$wt")" "folder is gone — git worktree prune"; continue; }
    branch=$(git -C "$wt" symbolic-ref -q --short HEAD || echo "(detached)")
    last=$(git -C "$wt" log -1 --format=%cs 2>/dev/null)
    mods=$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
    unpushed=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)
    unmerged=$(git -C "$wt" cherry "$base" HEAD 2>/dev/null | grep -c '^+')
    pr=-
    if have gh && [ "$branch" != "(detached)" ]; then
      pr=$(cd "$repo" && with_timeout 15 gh pr list --head "$branch" --state all --limit 1 \
             --json number,state --jq '.[] | "#\(.number) \(.state)"' 2>/dev/null)
      pr=${pr:--}
    fi
    if in_use "$wt"; then verdict=KEEP; why="a process (editor, shell, agent) is running in it"
    elif [ "$mods" -gt 0 ]; then verdict=REVIEW; why="uncommitted changes — check whether $base already has them"
    elif [ "$unmerged" -eq 0 ]; then verdict=SAFE; why="every commit is already in $base"
    elif [ "${pr#* }" = MERGED ] && [ "$unpushed" -eq 0 ]; then verdict=SAFE; why="PR merged (squash), all commits pushed"
    elif [ "${pr#* }" = OPEN ]; then verdict=KEEP; why="PR still open"
    elif [ "$unpushed" -gt 0 ]; then verdict=KEEP; why="$unpushed commit(s) exist only here"
    else verdict=REVIEW; why="$unmerged commit(s) not in $base, pushed, no merged PR"
    fi
    printf '%-8s %-30s %-34s %-10s %-5s %-8s %-9s %-10s %s\n' \
      "$verdict" "$(basename "$wt")" "$branch" "$last" "$mods" "$unpushed" "$unmerged" "$pr" "$why"
  done
  echo
  echo "Removing a worktree whose node_modules were cloned (APFS) frees far less than du reports."
}

# ---------- main ----------

main() {
  local cmd=${1:-scan}; [ $# -gt 0 ] && shift
  local deep=0 only="" yes=0 args=()
  while [ $# -gt 0 ]; do
    case $1 in
      --deep) deep=1 ;;
      --only) only=${2:-}; shift ;;
      --only=*) only=${1#--only=} ;;
      --yes|-y) yes=1 ;;
      -h|--help) cmd=help ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  local id
  for id in $(echo "$only" | tr ',' ' '); do
    target_line "$id" >/dev/null || echo "unknown id: $id (see: devclean.sh list)" >&2
  done
  case $cmd in
    scan) cmd_scan "$deep" "$only" ;;
    clean) cmd_clean "$deep" "$only" "$yes" ;;
    builds) cmd_builds "$yes" ${args[@]+"${args[@]}"} ;;
    worktrees) cmd_worktrees ${args[@]+"${args[@]}"} ;;
    list) echo "$TARGETS" | awk -F'|' 'NF>2{printf "%-11s %-5s %s\n",$1,$2,$3}' ;;
    help|*) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' ;;
  esac
}

main "$@"
