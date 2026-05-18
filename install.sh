#!/usr/bin/env bash
# Install this repo's two artefacts:
#   - run-sandboxed.sh   -> ~/.config/yolo-sandboxed-claude/run-sandboxed.sh
#   - agent.sb (templated) -> ~/.config/yolo-sandboxed-claude/agent.sb
#     (or $YOLO_CLAUDE_DURABLE_PROFILE if set)
# Also append a shell-function block to the user's rc (zsh or bash) that
# defines `safe-run` and `yolo-sandboxed-claude` on top of the installed launcher.
#
# Re-running is safe: destinations are overwritten in place (with a timestamped
# backup), and the shell-function block is only appended once (detected via marker).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$SCRIPT_DIR/agent.sb"
DEST="${YOLO_CLAUDE_DURABLE_PROFILE:-$HOME/.config/yolo-sandboxed-claude/agent.sb}"
LAUNCHER_SRC="$SCRIPT_DIR/run-sandboxed.sh"
LAUNCHER_DEST="$HOME/.config/yolo-sandboxed-claude/run-sandboxed.sh"

if [[ ! -f "$SRC" ]]; then
  echo "install.sh: source agent.sb not found at $SRC" >&2
  exit 1
fi

if [[ ! -f "$LAUNCHER_SRC" ]]; then
  echo "install.sh: source run-sandboxed.sh not found at $LAUNCHER_SRC" >&2
  exit 1
fi

if [[ -z "${HOME:-}" ]]; then
  echo "install.sh: \$HOME is not set" >&2
  exit 1
fi

# --- Install agent.sb ---------------------------------------------------------
mkdir -p "$(dirname "$DEST")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "s|__HOME_DIR__|${HOME}|g" "$SRC" > "$tmp"

if [[ -f "$DEST" ]] && cmp -s "$tmp" "$DEST"; then
  echo "install.sh: $DEST already up to date"
else
  if [[ -f "$DEST" ]]; then
    backup="$DEST.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$DEST" "$backup"
    echo "install.sh: backed up existing profile to $backup"
  fi
  mv "$tmp" "$DEST"
  echo "install.sh: wrote $DEST (HOME_DIR templated to $HOME)"
fi

# --- Install run-sandboxed.sh ------------------------------------------------
mkdir -p "$(dirname "$LAUNCHER_DEST")"

if [[ -f "$LAUNCHER_DEST" ]] && cmp -s "$LAUNCHER_SRC" "$LAUNCHER_DEST"; then
  echo "install.sh: $LAUNCHER_DEST already up to date"
else
  if [[ -f "$LAUNCHER_DEST" ]]; then
    backup="$LAUNCHER_DEST.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$LAUNCHER_DEST" "$backup"
    echo "install.sh: backed up existing launcher to $backup"
  fi
  install -m 0755 "$LAUNCHER_SRC" "$LAUNCHER_DEST"
  echo "install.sh: wrote $LAUNCHER_DEST"
fi

# --- Install shell functions -------------------------------------------------
# Writes four lines to the user's rc:
#   1. exports YOLO_CLAUDE_DURABLE_PROFILE pinning run-sandboxed.sh to the exact
#      profile path this install wrote to (matters when $DEST is non-default,
#      e.g. when YOLO_CLAUDE_DURABLE_PROFILE was set during install);
#   2. defines `safe-run` wrapping ~/.config/yolo-sandboxed-claude/run-sandboxed.sh;
#   3. defines `yolo-sandboxed-claude` = `safe-run claude --dangerously-skip-permissions`
#      (Claude Code's own permission layer is redundant once inside sandbox-exec).
BLOCK_MARKER="# >>> yolo-sandboxed-claude >>>"
BLOCK_END_MARKER="# <<< yolo-sandboxed-claude <<<"

case "${SHELL:-}" in
  */zsh)  RC="$HOME/.zshrc" ;;
  */bash) RC="$HOME/.bash_profile" ;;
  "")
    echo "install.sh: \$SHELL is not set; skipping shell-function install." >&2
    exit 0
    ;;
  *)
    echo "install.sh: unrecognized shell '$SHELL'; skipping shell-function install." >&2
    echo "install.sh: add these lines manually to your shell rc:" >&2
    echo "  export YOLO_CLAUDE_DURABLE_PROFILE=\"$DEST\"" >&2
    echo "  safe-run()    { \"\$HOME/.config/yolo-sandboxed-claude/run-sandboxed.sh\" \"\$@\"; }" >&2
    echo "  yolo-sandboxed-claude() { safe-run claude --dangerously-skip-permissions \"\$@\"; }" >&2
    exit 0
    ;;
esac

LEGACY_BLOCK_MARKER="# >>> safe-claude-via-agent-safehouse >>>"

touch "$RC"
if grep -qF "$LEGACY_BLOCK_MARKER" "$RC"; then
  echo "install.sh: found a stale block in $RC from a previous install (pre-rename to yolo-sandboxed-claude)." >&2
  echo "install.sh: remove the lines between '$LEGACY_BLOCK_MARKER' and its closing marker, then re-run." >&2
  exit 1
fi
if grep -qF "$BLOCK_MARKER" "$RC"; then
  echo "install.sh: shell-function block already present in $RC"
else
  {
    printf '\n%s\n' "$BLOCK_MARKER"
    printf 'export YOLO_CLAUDE_DURABLE_PROFILE="%s"\n' "$DEST"
    printf 'safe-run()    { "$HOME/.config/yolo-sandboxed-claude/run-sandboxed.sh" "$@"; }\n'
    printf 'yolo-sandboxed-claude() { safe-run claude --dangerously-skip-permissions "$@"; }\n'
    printf '%s\n' "$BLOCK_END_MARKER"
  } >> "$RC"
  echo "install.sh: appended safe-run / yolo-sandboxed-claude shell functions to $RC"
  echo "install.sh: open a new shell or run 'source $RC' to activate them"
fi
