#!/usr/bin/env bash
# Install the devclean command (and optionally the Claude Code skill).
#
#   curl -fsSL https://raw.githubusercontent.com/Adrian-stuff/clean-dev-caches/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --skill     # also install the Claude Code skill
#
# PREFIX (default ~/.local) picks where bin/devclean goes; DEVCLEAN_REF picks a tag or branch.

set -euo pipefail
REPO=Adrian-stuff/clean-dev-caches
REF=${DEVCLEAN_REF:-main}
DEST=${PREFIX:-$HOME/.local}/bin
SKILL_DIR=${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/clean-dev-caches
RAW="https://raw.githubusercontent.com/$REPO/$REF"

with_skill=0
for a in "$@"; do [ "$a" = --skill ] && with_skill=1; done

# Run from a clone: copy local files. Piped through curl: download them.
src=""
here=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)
[ -n "$here" ] && [ -f "$here/skills/clean-dev-caches/scripts/devclean.sh" ] && src="$here"

fetch() { # fetch REPO_PATH DEST_FILE
  if [ -n "$src" ]; then cp "$src/$1" "$2"; else curl -fsSL "$RAW/$1" -o "$2"; fi
}

mkdir -p "$DEST"
fetch skills/clean-dev-caches/scripts/devclean.sh "$DEST/devclean"
chmod +x "$DEST/devclean"
echo "Installed $("$DEST/devclean" --version) to $DEST/devclean"

if [ "$with_skill" = 1 ]; then
  mkdir -p "$SKILL_DIR/scripts"
  fetch skills/clean-dev-caches/SKILL.md "$SKILL_DIR/SKILL.md"
  fetch skills/clean-dev-caches/scripts/devclean.sh "$SKILL_DIR/scripts/devclean.sh"
  chmod +x "$SKILL_DIR/scripts/devclean.sh"
  echo "Installed the Claude Code skill to $SKILL_DIR"
fi

case ":$PATH:" in
  *":$DEST:"*) echo "Try: devclean scan" ;;
  *) echo "$DEST is not on your PATH. Add this to your shell profile:"
     echo "  export PATH=\"$DEST:\$PATH\"" ;;
esac
