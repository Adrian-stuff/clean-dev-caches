#!/usr/bin/env bash
# devclean — find and clear regenerable developer caches on macOS (and most of Linux).
#
#   devclean scan [--deep]                      what can be freed, nothing deleted
#   devclean clean [--deep] [--only a,b] [--yes] delete caches (dry run without --yes)
#   devclean builds DIR... [--older-than DAYS] [--node-modules] [--yes]
#                                               .next/.turbo/target/... under DIR (dry run without --yes);
#                                               --node-modules adds deps of projects idle that long
#   devclean worktrees REPO                     which git worktrees are safe to remove (report only)
#   devclean suggest [DIR...]                   bigger wins beyond caches, with how to act (report only)
#   devclean tools [--older-than DAYS]          AI coding CLIs and other global tools you stopped using,
#                                               and data left behind by uninstalled ones (report only)
#   devclean list | --version | help
#
# Everything this deletes is rebuilt or re-downloaded on demand. It never touches
# Docker images or volumes, emulators, simulators' data, browser profiles, or git work.
# Written for bash 3.2 (the macOS default): no associative arrays, no mapfile.

set -uo pipefail
VERSION=1.2.0
# System tools first: a stray `head`, `du` or `sort` earlier on PATH (XAMPP ships a perl
# `head`, for one) silently breaks the parsing below.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# BSD and GNU stat disagree on flags; GNU `stat -f` means "filesystem" and prints garbage.
if [ "$(uname -s)" = Darwin ]; then STAT_M=(stat -f %m); STAT_A=(stat -f %a)
else STAT_M=(stat -c %Y); STAT_A=(stat -c %X); fi

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

mtime() { "${STAT_M[@]}" "$1" 2>/dev/null || echo 0; }

NOW=$(date +%s)

# Newest mtime (epoch) of anything under the given paths, to DEPTH levels (default: all).
newest_mtime() { # newest_mtime DEPTH PATH...
  local depth=$1; shift
  local args=(); [ "$depth" -gt 0 ] && args=(-maxdepth "$depth")
  find "$@" ${args[@]+"${args[@]}"} -print0 2>/dev/null | xargs -0 "${STAT_M[@]}" 2>/dev/null | sort -n | tail -1
}

# Days since anything near the top of DIR was written. A folder's own mtime only moves when
# its direct entries change, so a busy .next can look months old by that alone.
days_ago() {
  local newest; newest=$(newest_mtime 2 "$1")
  echo $(( (NOW - ${newest:-$(mtime "$1")}) / 86400 ))
}

# True when nothing in the project (outside dependency and build folders) changed in DAYS days.
idle_for() { # idle_for PROJECT DAYS
  [ -z "$(find "$1" -maxdepth 3 \( -name node_modules -o -name .git -o -name .next -o -name .turbo \
          -o -name target -o -name dist -o -name build \) -prune -o -type f -mtime "-$2" -print -quit 2>/dev/null)" ]
}

build_dirs() { # build_dirs WITH_NODE_MODULES DIR...
  local nm=$1; shift
  if [ "$nm" = 1 ]; then
    find "$@" -name .git -prune -o -type d \( -name node_modules -o -name .next -o -name .turbo -o -name .nuxt \
      -o -name .svelte-kit -o -name .parcel-cache -o -name .angular -o -name .expo -o -name target \) -print -prune 2>/dev/null
  else
    find "$@" \( -name node_modules -o -name .git \) -prune -o -type d \( -name .next -o -name .turbo -o -name .nuxt \
      -o -name .svelte-kit -o -name .parcel-cache -o -name .angular -o -name .expo -o -name target \) -print -prune 2>/dev/null
  fi
}

cmd_builds() {
  local yes=$1 older=$2 nm=$3; shift 3
  local total=0 d k root age name
  [ $# -gt 0 ] || { echo "usage: devclean builds DIR... [--older-than DAYS] [--node-modules] [--yes]" >&2; return 2; }
  if [ "$nm" = 1 ] && [ "$older" -eq 0 ]; then
    echo "--node-modules needs --older-than DAYS, so active projects keep their dependencies." >&2; return 2
  fi
  printf '%8s  %-7s %-9s %s\n' SIZE STATUS BUILT PATH
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    root=$(dirname "$d"); name=$(basename "$d")
    # Rust's target/ only when it sits next to a Cargo.toml.
    [ "$name" = target ] && [ ! -f "$root/Cargo.toml" ] && continue
    age="$(days_ago "$d")d ago"
    if [ "$older" -gt 0 ]; then
      # Build outputs: judged by when they were last written. node_modules: by when the project last changed.
      if [ "$name" = node_modules ]; then idle_for "$root" "$older" || continue
      elif [ "$(days_ago "$d")" -lt "$older" ]; then continue; fi
    fi
    k=$(size_k "$d")
    if in_use "$root"; then
      printf '%8s  %-7s %-9s %s  — a process is running in this project\n' "$(human "$k")" skip "$age" "$d"
      continue
    fi
    total=$((total + k))
    if [ "$yes" = 1 ]; then rm -rf "$d" 2>/dev/null; printf '%8s  %-7s %-9s %s\n' "$(human "$k")" deleted "$age" "$d"
    else printf '%8s  %-7s %-9s %s\n' "$(human "$k")" ready "$age" "$d"; fi
  done < <(build_dirs "$nm" "$@")
  echo
  if [ "$yes" = 1 ]; then echo "Deleted about $(human "$total")."
  else echo "About $(human "$total") ready. Re-run with --yes to delete; the next install/build recreates them."; fi
}

# ---------- suggestions beyond caches (report only) ----------

SUG=""
suggest() { # suggest KiB WHAT HOW
  [ "${1:-0}" -ge 102400 ] || return 0 # under 100 MB isn't worth a line
  SUG="${SUG}$1	$2	$3
"
}

cmd_suggest() {
  local roots=("$@") p k n
  if [ ${#roots[@]} -eq 0 ]; then
    for p in "$H/projects" "$H/code" "$H/dev" "$H/src" "$H/Developer" "$H/workspace" "$H/repos" "$H/git"; do
      [ -d "$p" ] && roots+=("$p")
    done
  fi
  echo "Looking for space beyond caches (nothing is deleted)..." >&2

  # Trash and Downloads
  [ -r "$H/.Trash" ] && suggest "$(size_k "$H/.Trash")" "Trash" "Empty it in Finder"
  if [ -d "$H/Downloads" ]; then
    k=0; n=0
    while IFS= read -r p; do k=$((k + $(size_k "$p"))); n=$((n + 1)); done < <(find "$H/Downloads" -maxdepth 2 -type f \
      \( -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.iso' -o -iname '*.xip' -o -iname '*.zip' -o -iname '*.tar.gz' \) 2>/dev/null)
    suggest "$k" "Downloads: $n installers and archives (.dmg .pkg .iso .xip .zip)" "Delete the ones already installed or extracted"
    k=0; n=0
    while IFS= read -r p; do k=$((k + $(size_k "$p"))); n=$((n + 1)); done < <(find "$H/Downloads" -type f -size +200M -mtime +90 2>/dev/null)
    suggest "$k" "Downloads: $n files over 200 MB untouched for 90+ days" "find ~/Downloads -type f -size +200M -mtime +90"
  fi

  # Projects: idle dependencies and build outputs
  if [ ${#roots[@]} -gt 0 ]; then
    k=0; n=0
    while IFS= read -r p; do
      [ "$(basename "$p")" = node_modules ] || continue
      idle_for "$(dirname "$p")" 90 || continue
      in_use "$(dirname "$p")" && continue
      k=$((k + $(size_k "$p"))); n=$((n + 1))
    done < <(build_dirs 1 "${roots[@]}")
    suggest "$k" "node_modules in $n projects idle for 90+ days (du overstates on APFS)" \
      "devclean builds ${roots[*]} --older-than 90 --node-modules --yes"
    k=0; n=0
    while IFS= read -r p; do
      [ "$(basename "$p")" = node_modules ] && continue
      [ "$(basename "$p")" = target ] && [ ! -f "$(dirname "$p")/Cargo.toml" ] && continue
      [ "$(days_ago "$p")" -ge 30 ] || continue
      in_use "$(dirname "$p")" && continue
      k=$((k + $(size_k "$p"))); n=$((n + 1))
    done < <(build_dirs 0 "${roots[@]}")
    suggest "$k" "$n build outputs (.next, .turbo, target...) not rebuilt for 30+ days" \
      "devclean builds ${roots[*]} --older-than 30 --yes"
  fi

  # Docker
  if have docker && with_timeout 10 docker info >/dev/null 2>&1; then
    k=$(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null | awk -F'|' '$1=="Images"{v=$2; sub(/ .*/,"",v); n=v+0; u=v; gsub(/[0-9.]/,"",u);
        m=(u=="TB"?1073741824:u=="GB"?1048576:u=="MB"?1024:u=="kB"?1:0); printf "%d", n*m}')
    suggest "${k:-0}" "Docker images no container uses" "docker image ls, then docker image rm <id> (or docker image prune -a)"
  fi

  # Virtual machines (their disks hold containers and images, so never "just a large file")
  local dd="$H/Library/Containers/com.docker.docker/Data" vm
  if [ -d "$H/.colima" ]; then
    how="colima prune clears its download cache; colima delete removes the VM with every container and image in it"
    [ -d "$dd" ] && how="You also have Docker Desktop — keep one runtime. $how"
    suggest "$(size_k "$H/.colima")" "Colima VM" "$how"
  fi
  [ -d "$H/.orbstack" ] && suggest "$(size_k "$H/.orbstack")" "OrbStack data" "Remove unused machines and images in OrbStack"
  for vm in "$H/Parallels" "$H/VirtualBox VMs" "$H/Library/Containers/com.utmapp.UTM/Data/Documents"; do
    [ -d "$vm" ] && suggest "$(size_k "$vm")" "Virtual machines in ${vm#$H/}" "Delete VMs you no longer boot, from inside the VM app"
  done

  # Local AI models
  [ -d "$H/.ollama/models" ] && suggest "$(size_k "$H/.ollama/models")" "Ollama models" "ollama list, then ollama rm <model> for ones you no longer run"
  [ -d "$H/.cache/huggingface" ] && suggest "$(size_k "$H/.cache/huggingface")" "Hugging Face model cache" "huggingface-cli delete-cache (pick models interactively)"
  [ -d "$H/.lmstudio/models" ] && suggest "$(size_k "$H/.lmstudio/models")" "LM Studio models" "Remove unused models in LM Studio > My Models"

  # Mobile
  local avd
  for avd in "$H/.android/avd"/*.avd; do
    [ -d "$avd" ] && suggest "$(size_k "$avd")" "Android emulator $(basename "$avd" .avd)" "Delete it in Android Studio > Device Manager if unused"
  done
  for p in "$H/Library/Android/sdk/system-images" "$H/Android/Sdk/system-images"; do
    [ -d "$p" ] && suggest "$(size_k "$p")" "Android SDK system images" "Uninstall unused ones in Android Studio > SDK Manager"
  done
  p="$H/Library/Developer/Xcode/iOS DeviceSupport"
  if [ -d "$p" ] && [ "$(ls -1 "$p" | wc -l)" -gt 1 ]; then
    k=$(ls -1 "$p" | sort -V | sed '$d' | while IFS= read -r v; do size_k "$p/$v"; done | awk '{s+=$1} END{print s+0}')
    suggest "$k" "iOS DeviceSupport for older iOS versions" "Delete all but the newest folder in $p"
  fi
  [ -d "$H/Library/Developer/Xcode/Archives" ] && suggest "$(size_k "$H/Library/Developer/Xcode/Archives")" "Xcode Archives" "Keep the ones you may need to symbolicate; delete in Xcode > Organizer"
  if have xcrun && xcrun simctl help >/dev/null 2>&1; then
    suggest "$(size_k "$H/Library/Developer/CoreSimulator/Devices")" "Simulator devices" "xcrun simctl delete unavailable; remove unused runtimes in Xcode > Settings > Platforms"
  fi
  n=$(ls -d /Applications/Xcode*.app 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 1 ] && suggest "$(size_k /Applications/Xcode*.app)" "$n Xcode versions installed" "Keep the one you build with"
  p="$H/Library/Application Support/MobileSync/Backup"
  [ -r "$p" ] && suggest "$(size_k "$p")" "iPhone/iPad backups on this Mac" "Finder > your device > Manage Backups"

  # Language toolchains with several versions
  local dir label how
  for spec in "$H/.nvm/versions/node|Node versions (nvm)|nvm ls, then nvm uninstall <version>" \
              "$H/.local/share/fnm/node-versions|Node versions (fnm)|fnm list, then fnm uninstall <version>" \
              "$H/.volta/tools/image/node|Node versions (Volta)|volta list all; remove old ones from ~/.volta/tools/image/node" \
              "$H/.rustup/toolchains|Rust toolchains|rustup toolchain list, then rustup toolchain uninstall <name>" \
              "$H/.pyenv/versions|Python versions (pyenv)|pyenv versions, then pyenv uninstall <version>" \
              "$H/.sdkman/candidates/java|Java versions (SDKMAN)|sdk list java, then sdk uninstall java <version>"; do
    dir=${spec%%|*}; label=${spec#*|}; how=${label#*|}; label=${label%%|*}
    [ -d "$dir" ] || continue
    n=$(ls -1 "$dir" 2>/dev/null | grep -vc '^current$')
    [ "$n" -gt 1 ] && suggest "$(size_k "$dir")" "$n $label" "$how"
  done
  for p in "$H/miniconda3/pkgs" "$H/anaconda3/pkgs" "$H/miniforge3/pkgs" "$H/opt/anaconda3/pkgs"; do
    [ -d "$p" ] && suggest "$(size_k "$p")" "Conda package cache" "conda clean --all"
  done

  # Homebrew packages nothing depends on
  if have brew; then
    n=$(brew autoremove --dry-run 2>/dev/null | grep -cv '^==>')
    [ "$n" -gt 0 ] && suggest 102400 "$n Homebrew packages nothing depends on any more (size not measured)" "brew autoremove"
  fi

  # Big app caches that aren't developer tools
  while IFS= read -r line; do
    k=${line%%	*}; p=${line#*	}
    case $(basename "$p") in Homebrew|pip|bun|Yarn|CocoaPods|ms-playwright*|go-build|node-gyp|typescript|electron|JetBrains|deno|composer|uv|com.apple.dt.Xcode) continue ;; esac
    [ "$k" -ge 512000 ] && suggest "$k" "App cache: $(basename "$p")" "Clear it from inside the app (or quit the app and delete $p)"
  done < <(du -sk "$LC"/* 2>/dev/null | sort -rn | head -8)

  # Large files anywhere else in your home folder
  echo "Scanning your home folder for files over 1 GB (takes a minute)..." >&2
  while IFS= read -r p; do
    suggest "$(size_k "$p")" "Large file: ${p#$H/}" "Delete or move to external storage if you don't need it"
  done < <(find "$H" \( -path "$H/Library" -o -path "$H/.Trash" -o -path "$H/Downloads" -o -path "$H/.android" \
             -o -path "$H/.ollama" -o -path "$H/.cache" -o -path "$H/.lmstudio" -o -path "$H/.docker" -o -path "$H/.colima" \
             -o -path "$H/.orbstack" -o -path "$H/Parallels" -o -path "$H/VirtualBox VMs" -o -name node_modules \
             -o -name .git \) -prune -o -type f -size +1G -print 2>/dev/null | head -15)

  # Time Machine local snapshots
  n=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine')
  [ "${n:-0}" -gt 0 ] && suggest 102400 "$n Time Machine local snapshots (size not measured)" "They're deleted automatically when space runs low; tmutil thinlocalsnapshots / to force it"

  if [ -z "$SUG" ]; then echo "Nothing over 100 MB found."; return; fi
  echo
  printf '%8s  %s\n' SIZE "WHAT  →  HOW"
  printf '%s' "$SUG" | sort -t'	' -k1,1 -rn | while IFS='	' read -r k what how; do
    printf '%8s  %s\n          →  %s\n' "$(human "$k")" "$what" "$how"
  done
  echo
  echo "Sizes come from du and may overstate on APFS. Nothing here is deleted by this script."
}

# ---------- git worktrees ----------

cmd_worktrees() {
  local repo=${1:-}
  [ -n "$repo" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "usage: devclean worktrees REPO" >&2; return 2; }
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

# ---------- unused tools (report only) ----------

# AI coding harnesses and local-model runners.
# id|name|commands|data paths (a leading - excludes a path another tool owns)|app bundle|note for leftovers
HARNESSES="
claude|Claude Code|claude|$H/.claude;$H/.local/share/claude;$H/.cache/claude||
opencode|OpenCode|opencode|$H/.local/share/opencode;$H/.config/opencode;$H/.cache/opencode;$H/.opencode||
codex|Codex CLI|codex|$H/.codex;$H/.cache/codex-runtimes|/Applications/Codex.app|
gemini|Gemini CLI|gemini|$H/.gemini;-$H/.gemini/antigravity||Gemini Code Assist in an editor can use ~/.gemini too
qwen|Qwen Code|qwen|$H/.qwen||
kilo|Kilo Code CLI|kilo,kilocode|$H/.kilocode;$H/.cache/kilo;$H/.local/share/kilo;$H/.config/kilo||
aider|Aider|aider|$H/.aider;$H/.cache/aider||
goose|Goose|goose|$H/.config/goose;$H/.local/share/goose;$H/.local/state/goose|/Applications/Goose.app|
amp|Amp|amp|$H/.amp;$H/.config/amp;$H/.cache/amp;$H/.local/share/amp||
crush|Crush|crush|$H/.local/share/crush;$H/.config/crush;$H/.cache/crush||
cursor|Cursor|cursor-agent,cursor|$H/.cursor;$H/.local/share/cursor-agent|/Applications/Cursor.app|
windsurf|Windsurf|windsurf|$H/.windsurf;$H/.codeium;$AS/Windsurf|/Applications/Windsurf.app|
droid|Factory Droid|droid|$H/.factory||
copilot|GitHub Copilot CLI|copilot|$H/.copilot||
cline|Cline CLI|cline|$H/.cline||
auggie|Augment (auggie)|auggie|$H/.augment||
continue|Continue CLI|cn|$H/.continue||the Continue editor extension also uses ~/.continue
kiro|Kiro|kiro-cli,kiro|$H/.kiro|/Applications/Kiro.app|
openhands|OpenHands|openhands|$H/.openhands||
plandex|Plandex|plandex|$H/.plandex-home||
antigravity|Antigravity|agy,antigravity|$H/.gemini/antigravity;$AS/Antigravity;$H/.antigravity;$H/.cache/antigravity;$LC/com.google.antigravity;$LC/com.google.antigravity.ShipIt;$LC/antigravity-updater|/Applications/Antigravity.app|
ollama|Ollama|ollama|$H/.ollama|/Applications/Ollama.app|
lmstudio|LM Studio|lms|$H/.lmstudio;$H/.cache/lm-studio|/Applications/LM Studio.app|
"

if [ "$(uname -s)" = Darwin ]; then STAT_I=(stat -f %i); else STAT_I=(stat -c %i); fi

tilde() { # ~/path for display; quoted after the ~/ when it has spaces, so it still pastes
  local p=${1/#$H/\~}
  case $p in *" "*) case $p in "~/"*) p="~/\"${p#\~/}\"" ;; *) p="\"$p\"" ;; esac ;; esac
  printf '%s' "$p"
}

# How a command was installed, from where its link resolves: prints "how to uninstall".
uninstall_hint() { # uninstall_hint RESOLVED_PATH COMMAND
  local t=$1 rest pkg
  case $t in
    */Caskroom/*) rest=${t#*/Caskroom/}; echo "brew uninstall --cask ${rest%%/*}" ;;
    */Cellar/*) rest=${t#*/Cellar/}; echo "brew uninstall ${rest%%/*}" ;;
    */.bun/install/global/node_modules/*|*/lib/node_modules/*|*/pnpm/global/*/node_modules/*)
      rest=${t##*/node_modules/}; pkg=${rest%%/*}
      [ "${pkg#@}" != "$pkg" ] && pkg="$pkg/$(echo "${rest#*/}" | cut -d/ -f1)"
      case $t in
        */.bun/*) echo "bun remove -g $pkg" ;;
        */pnpm/*) echo "pnpm remove -g $pkg" ;;
        *) echo "npm uninstall -g $pkg" ;;
      esac ;;
    */pipx/venvs/*) rest=${t#*/pipx/venvs/}; echo "pipx uninstall ${rest%%/*}" ;;
    */uv/tools/*) rest=${t#*/uv/tools/}; echo "uv tool uninstall ${rest%%/*}" ;;
    */.cargo/bin/*) echo "cargo uninstall $2" ;;
    */Applications/*.app/*) rest=${t%%.app/*}; echo "move $(tilde "$rest.app") to the Trash" ;;
    *) echo "rm $(tilde "$(command -v "$2")")" ;;
  esac
}

# Package root a resolved command lives in, so its install size can be measured.
install_root() { # install_root RESOLVED_PATH
  local t=$1 rest pkg
  case $t in
    */Caskroom/*) rest=${t#*/Caskroom/}; echo "${t%%/Caskroom/*}/Caskroom/${rest%%/*}" ;;
    */Cellar/*) rest=${t#*/Cellar/}; echo "${t%%/Cellar/*}/Cellar/${rest%%/*}" ;;
    */node_modules/*)
      rest=${t##*/node_modules/}; pkg=${rest%%/*}
      [ "${pkg#@}" != "$pkg" ] && pkg="$pkg/$(echo "${rest#*/}" | cut -d/ -f1)"
      echo "${t%"$rest"}$pkg" ;;
    */pipx/venvs/*) rest=${t#*/pipx/venvs/}; echo "${t%%/pipx/venvs/*}/pipx/venvs/${rest%%/*}" ;;
    */uv/tools/*) rest=${t#*/uv/tools/}; echo "${t%%/uv/tools/*}/uv/tools/${rest%%/*}" ;;
    */Applications/*.app/*) echo "${t%%.app/*}.app" ;;
    *) echo "$t" ;;
  esac
}

# Newest file mtime under PATHS, skipping excluded ones. Arguments: data spec "a;b;-c".
data_newest() {
  local spec=$1 p paths=() skip=() IFS=';'
  for p in $spec; do
    case $p in -*) skip+=(-path "${p#-}" -o) ;; *) [ -e "$p" ] && paths+=("$p") ;; esac
  done
  unset IFS
  [ ${#paths[@]} -gt 0 ] || return 0
  if [ ${#skip[@]} -gt 0 ]; then
    unset 'skip[${#skip[@]}-1]' # trailing -o
    find "${paths[@]}" \( "${skip[@]}" \) -prune -o -type f -print0 2>/dev/null
  else
    find "${paths[@]}" -type f -print0 2>/dev/null
  fi | xargs -0 "${STAT_M[@]}" 2>/dev/null | sort -n | tail -1
}

data_size() { # data_size "a;b;-c" -> KiB of a+b minus c
  local spec=$1 p t=0 IFS=';'
  for p in $spec; do
    case $p in -*) t=$((t - $(size_k "${p#-}"))) ;; *) t=$((t + $(size_k "$p"))) ;; esac
  done
  [ "$t" -lt 0 ] && t=0
  echo "$t"
}

data_rm_hint() { # how to delete a tool's data, respecting excluded paths
  local spec=$1 p keep="" dirs="" IFS=';'
  for p in $spec; do
    case $p in -*) keep="$keep $(tilde "${p#-}")" ;; *) [ -e "$p" ] && dirs="$dirs $(tilde "$p")" ;; esac
  done
  [ -n "$dirs" ] || return 0
  if [ -n "$keep" ]; then echo "delete what's in${dirs} except${keep}"
  else echo "rm -rf${dirs}"; fi
}

days_since() { [ "${1:-0}" -gt 0 ] && echo $(( (NOW - $1) / 86400 )) || echo -; }

cmd_tools() {
  local older=${1:-0}; [ "$older" -gt 0 ] || older=60
  local line id name cmds spec app note c p t last a bin_t data_k inst_k inst_root running verdict how rm_data d
  echo "Last used = the later of when its command last ran (file access time) and when it last"
  echo "wrote its sessions, logs or settings. Report only: nothing is deleted."
  echo
  echo "AI coding tools and model runners"
  printf '%-9s %-20s %-10s %8s %8s  %s\n' VERDICT TOOL "LAST USED" INSTALL DATA "HOW TO REMOVE"
  local harness_cmds="" harness_roots=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS='|' read -r id name cmds spec app note <<EOF
$line
EOF
    harness_cmds="$harness_cmds,$cmds"
    last=0; bin_t=""; running=0
    for c in $(echo "$cmds" | tr ',' ' '); do
      p=$(command -v "$c" 2>/dev/null) || continue
      case $p in /*) ;; *) continue ;; esac # skip shell functions and aliases
      t=$(realpath "$p" 2>/dev/null || echo "$p")
      [ -n "$bin_t" ] || bin_t=$t
      a=$("${STAT_A[@]}" "$t" 2>/dev/null || echo 0); [ "$a" -gt "$last" ] && last=$a
      pgrep -x "$c" >/dev/null 2>&1 && running=1
    done
    if [ -n "$app" ] && [ -d "$app" ]; then
      [ -n "$bin_t" ] || bin_t="$app/Contents/MacOS/x"
      for p in "$app"/Contents/MacOS/*; do
        a=$("${STAT_A[@]}" "$p" 2>/dev/null || echo 0); [ "$a" -gt "$last" ] && last=$a
      done
      pgrep -f "$app/Contents/MacOS/" >/dev/null 2>&1 && running=1
    fi
    data_k=$(data_size "$spec")
    [ -z "$bin_t" ] && [ "$data_k" -lt 1024 ] && continue # not installed, nothing left behind
    d=$(data_newest "$spec"); [ "${d:-0}" -gt "$last" ] && last=$d
    rm_data=$(data_rm_hint "$spec")
    if [ -n "$bin_t" ]; then
      inst_root=$(install_root "$bin_t")
      # A native install that lives inside its own data folder is already counted under DATA.
      inst_k=$(size_k "$inst_root")
      while IFS= read -r p; do
        case $inst_root in "$p"|"$p"/*) inst_k=0 ;; esac
      done < <(echo "$spec" | tr ';' '\n' | grep -v '^-')
      harness_roots="$harness_roots|$inst_root|"
      # An app bundle is the real install; its CLI link goes with it.
      if [ -n "$app" ] && [ -d "$app" ]; then how="move $(tilde "$app") to the Trash"
      else how=$(uninstall_hint "$bin_t" "${cmds%%,*}"); fi
      [ -n "$rm_data" ] && how="$how; then $rm_data"
    else
      inst_k=0; how="$rm_data${note:+  ($note)}"
    fi
    if [ "$running" = 1 ]; then verdict="IN USE"
    elif [ -z "$bin_t" ]; then verdict=LEFTOVER
    elif [ "$(days_since "$last")" != - ] && [ "$(days_since "$last")" -ge "$older" ]; then verdict=UNUSED
    else verdict=USED; fi
    local lu; lu=$(days_since "$last"); [ "$lu" != - ] && lu="${lu}d ago"
    printf '%-9s %-20s %-10s %8s %8s  %s\n' "$verdict" "$name" "$lu" \
      "$([ "$inst_k" -gt 0 ] && human "$inst_k" || echo -)" "$(human "$data_k")" "$how"
  done <<EOF
$HARNESSES
EOF

  echo
  echo "Other global command-line tools not used in ${older}+ days"
  local rows="" bindir marker
  # Package-manager installs, found through the links in each manager's bin folder.
  {
    have brew && for bindir in "$(brew --prefix 2>/dev/null)/bin"; do link_owners "$bindir"; done
    have npm && link_owners "$(npm prefix -g 2>/dev/null)/bin"
    [ -d "$H/.bun/bin" ] && link_owners "$H/.bun/bin"
    have pnpm && link_owners "$(pnpm bin -g 2>/dev/null)"
    [ -d "$H/.local/bin" ] && link_owners "$H/.local/bin"
    standalone_bins "$H/.cargo/bin" cargo
    standalone_bins "$H/go/bin" go
  } > "${TMPDIR:-/tmp}/devclean-tools.$$" 2>/dev/null
  local leaves=""; have brew && leaves=" $(brew leaves --installed-on-request 2>/dev/null | tr '\n' ' ') "
  rows=$(tool_rows "$harness_cmds" "$leaves" "$harness_roots" < "${TMPDIR:-/tmp}/devclean-tools.$$" |
         sort -t'|' -k1,1 -k2,2nr | awk -F'|' '!seen[$1]++')
  rm -f "${TMPDIR:-/tmp}/devclean-tools.$$"
  local out="" root k days
  while IFS='|' read -r root a c t; do
    [ -n "$root" ] || continue
    days=$(days_since "$a"); [ "$days" = - ] && continue
    [ "$days" -ge "$older" ] || continue
    k=$(size_k "$root")
    out="$out$k|${days}d ago|$c|$(uninstall_hint "$t" "$c")
"
  done <<EOF
$rows
EOF
  if [ -z "$out" ]; then echo "  none"; else
    printf '%8s  %-10s %-26s %s\n' SIZE "LAST RUN" COMMAND "HOW TO REMOVE"
    printf '%s' "$out" | sort -t'|' -k1,1 -rn | while IFS='|' read -r k lu c how; do
      printf '%8s  %-10s %-26s %s\n' "$(human "$k")" "$lu" "$c" "$how"
    done
  fi
  echo
  echo "Data folders hold sessions, settings and logins — keep them if you might reinstall."
  echo "Running a command (even --version) resets its last-used date; this report never does."
}

# stdin "cmd|resolved|atime" -> "package root|atime|cmd|resolved", minus harnesses, package
# managers themselves, and Homebrew formulae that were only pulled in as dependencies.
# (A function, not inline: bash 3.2 can't parse `case` inside $(...).)
tool_rows() { # tool_rows HARNESS_CMDS BREW_LEAVES HARNESS_ROOTS
  local c t a f
  while IFS='|' read -r c t a; do
    [ -n "$t" ] || continue
    case ",$1," in *",$c,"*) continue ;; esac
    case "$3" in *"|$(install_root "$t")|"*) continue ;; esac # another command of a harness above
    case $c in npm|npx|corepack|pnpm|pnpx|yarn|yarnpkg|bun|bunx|node|brew|pipx|uv|uvx|cargo|rustup|go) continue ;; esac
    case $t in
      */Cellar/*) f=${t#*/Cellar/}; f=${f%%/*}
        case "$2" in *" $f "*) ;; *) continue ;; esac ;;
    esac
    printf '%s|%s|%s|%s\n' "$(install_root "$t")" "$a" "$c" "$t"
  done
}

# Commands in BINDIR that are links into a package manager's folder: prints "cmd|resolved|atime".
link_owners() {
  local bin=$1 l t
  [ -d "$bin" ] || return 0
  for l in "$bin"/*; do
    [ -L "$l" ] || continue
    t=$(realpath "$l" 2>/dev/null) || continue
    case $t in */Cellar/*|*/Caskroom/*|*/node_modules/*|*/pipx/venvs/*|*/uv/tools/*) ;; *) continue ;; esac
    printf '%s|%s|%s\n' "$(basename "$l")" "$t" "$("${STAT_A[@]}" "$t" 2>/dev/null || echo 0)"
  done
}

# Self-contained binaries (cargo install, go install). Skips rustup's proxies (same inode as rustup).
standalone_bins() { # standalone_bins DIR KIND
  local dir=$1 f ri=""
  [ -d "$dir" ] || return 0
  [ -e "$dir/rustup" ] && ri=$("${STAT_I[@]}" "$dir/rustup" 2>/dev/null)
  for f in "$dir"/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ -n "$ri" ] && [ "$("${STAT_I[@]}" "$f" 2>/dev/null)" = "$ri" ] && continue
    printf '%s|%s|%s\n' "$(basename "$f")" "$f" "$("${STAT_A[@]}" "$f" 2>/dev/null || echo 0)"
  done
}

# ---------- main ----------

main() {
  local cmd=${1:-scan}; [ $# -gt 0 ] && shift
  local deep=0 only="" yes=0 older=0 nm=0 args=()
  while [ $# -gt 0 ]; do
    case $1 in
      --deep) deep=1 ;;
      --older-than) older=${2:-0}; shift ;;
      --older-than=*) older=${1#--older-than=} ;;
      --node-modules) nm=1 ;;
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
    target_line "$id" >/dev/null || echo "unknown id: $id (see: devclean list)" >&2
  done
  case $cmd in
    scan) cmd_scan "$deep" "$only" ;;
    clean) cmd_clean "$deep" "$only" "$yes" ;;
    builds) cmd_builds "$yes" "$older" "$nm" ${args[@]+"${args[@]}"} ;;
    suggest) cmd_suggest ${args[@]+"${args[@]}"} ;;
    tools) cmd_tools "$older" ;;
    version|--version|-v) echo "devclean $VERSION" ;;
    worktrees) cmd_worktrees ${args[@]+"${args[@]}"} ;;
    list) echo "$TARGETS" | awk -F'|' 'NF>2{printf "%-11s %-5s %s\n",$1,$2,$3}' ;;
    help|*) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
  esac
}

main "$@"
