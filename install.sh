#!/usr/bin/env bash
# Render this repo's templated agent.sb to the user's actual HOME and install
# it to ~/.config/sandbox-exec/agent.sb (or $SAFEHOUSE_DURABLE_PROFILE if set).
# Also append a shell-function block to the user's rc (zsh or bash) that
# defines `safe-run` and `safe-claude` on top of agent-safehouse's
# run-sandboxed.sh launcher.
#
# Re-running is safe: the destination is overwritten in place (with a timestamped
# backup), and the shell-function block is only appended once (detected via marker).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SRC="$SCRIPT_DIR/agent.sb"
DEST="${SAFEHOUSE_DURABLE_PROFILE:-$HOME/.config/sandbox-exec/agent.sb}"

if [[ ! -f "$SRC" ]]; then
  echo "install.sh: source agent.sb not found at $SRC" >&2
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

# --- Install shell functions -------------------------------------------------
# Writes three lines to the user's rc:
#   1. exports SAFEHOUSE_DURABLE_PROFILE so run-sandboxed.sh picks up THIS repo's
#      Rails-aware profile (without the export, agent-safehouse falls back to
#      its stock profile and the Rails grants this repo provides are ignored);
#   2. defines `safe-run` wrapping ~/.config/sandbox-exec/run-sandboxed.sh;
#   3. defines `safe-claude` = `safe-run claude --dangerously-skip-permissions`
#      (Claude Code's own permission layer is redundant once inside sandbox-exec).
BLOCK_MARKER="# >>> safe-claude-via-agent-safehouse >>>"
BLOCK_END_MARKER="# <<< safe-claude-via-agent-safehouse <<<"

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
    echo "  export SAFEHOUSE_DURABLE_PROFILE=\"$DEST\"" >&2
    echo "  safe-run()    { \"\$HOME/.config/sandbox-exec/run-sandboxed.sh\" \"\$@\"; }" >&2
    echo "  safe-claude() { safe-run claude --dangerously-skip-permissions \"\$@\"; }" >&2
    exit 0
    ;;
esac

OLD_ALIAS_MARKER="# >>> safe-claude-via-agent-safehouse alias >>>"

touch "$RC"
if grep -qF "$OLD_ALIAS_MARKER" "$RC"; then
  echo "install.sh: found a stale alias block in $RC from a previous install." >&2
  echo "install.sh: remove the lines between '$OLD_ALIAS_MARKER' and its closing marker, then re-run." >&2
  exit 1
fi
if grep -qF "$BLOCK_MARKER" "$RC"; then
  echo "install.sh: shell-function block already present in $RC"
else
  {
    printf '\n%s\n' "$BLOCK_MARKER"
    printf 'export SAFEHOUSE_DURABLE_PROFILE="%s"\n' "$DEST"
    printf 'safe-run()    { "$HOME/.config/sandbox-exec/run-sandboxed.sh" "$@"; }\n'
    printf 'safe-claude() { safe-run claude --dangerously-skip-permissions "$@"; }\n'
    printf '%s\n' "$BLOCK_END_MARKER"
  } >> "$RC"
  echo "install.sh: appended safe-run / safe-claude shell functions to $RC"
  echo "install.sh: open a new shell or run 'source $RC' to activate them"
fi
