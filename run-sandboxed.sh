#!/usr/bin/env bash
# Launch a command under sandbox-exec using the durable agent.sb profile,
# with workdir + linked-worktree access rules emitted at launch time.
#
# Usage:
#   run-sandboxed.sh [--workdir=/abs/path] COMMAND [ARGS...]
#
# Env:
#   SAFEHOUSE_DURABLE_PROFILE  override path to durable profile
#                              (default: ~/.config/sandbox-exec/agent.sb)
#   SAFEHOUSE_DEBUG=1          keep the generated policy file on disk and
#                              print its path (skips cleanup)

set -euo pipefail

DURABLE_PROFILE="${SAFEHOUSE_DURABLE_PROFILE:-$HOME/.config/sandbox-exec/agent.sb}"

if [[ ! -f "$DURABLE_PROFILE" ]]; then
  echo "run-sandboxed: durable profile not found: $DURABLE_PROFILE" >&2
  exit 70
fi

workdir=""
cmd_args=()
for arg in "$@"; do
  case "$arg" in
    --workdir=*) workdir="${arg#*=}" ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) cmd_args+=("$arg") ;;
  esac
done

if [[ "${#cmd_args[@]}" -eq 0 ]]; then
  echo "run-sandboxed: missing command" >&2
  echo "usage: $(basename "$0") [--workdir=/abs/path] COMMAND [ARGS...]" >&2
  exit 64
fi

if [[ -z "$workdir" ]]; then
  workdir="$(pwd -P)"
fi
if [[ ! -d "$workdir" ]]; then
  echo "run-sandboxed: workdir does not exist: $workdir" >&2
  exit 66
fi
workdir="$(cd "$workdir" && pwd -P)"

policy_file="$(mktemp -t agent-sandbox-policy.XXXXXX)"
if [[ "${SAFEHOUSE_DEBUG:-0}" != "1" ]]; then
  trap 'rm -f "$policy_file"' EXIT INT TERM HUP
else
  echo "run-sandboxed: SAFEHOUSE_DEBUG=1 — keeping policy file: $policy_file" >&2
fi

# Start from the durable profile.
cat "$DURABLE_PROFILE" > "$policy_file"

# Helper: emit ancestor (literal ...) read grants for a path.
# Mirrors Safehouse's policy_render_emit_path_ancestor_literals(): readdir() on
# every ancestor needs file-read* on the directory entry itself; literal (not
# subpath) keeps it from cascading recursive read access.
emit_ancestor_literals() {
  local path="$1" label="$2"
  {
    printf ';; ---------------------------------------------------------------------------\n'
    printf ';; Runtime: ancestor literals for %s: %s\n' "$label" "$path"
    printf ';; ---------------------------------------------------------------------------\n'
    printf '(allow file-read*\n'
    printf '    (literal "/")\n'
  } >> "$policy_file"

  local prev="" part
  local trimmed="${path#/}"
  local IFS='/'
  # shellcheck disable=SC2206
  local parts=( $trimmed )
  unset IFS
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    prev="${prev}/${part}"
    # Escape embedded double-quotes (rare in paths but be defensive).
    local escaped="${prev//\"/\\\"}"
    printf '    (literal "%s")\n' "$escaped" >> "$policy_file"
  done

  printf ')\n\n' >> "$policy_file"
}

emit_rw_subpath() {
  local path="$1" label="$2"
  local escaped="${path//\"/\\\"}"
  {
    printf ';; Runtime: read/write access to %s.\n' "$label"
    printf '(allow file-read* file-write* (subpath "%s"))\n\n' "$escaped"
  } >> "$policy_file"
}

emit_ro_subpath() {
  local path="$1" label="$2"
  local escaped="${path//\"/\\\"}"
  {
    printf ';; Runtime: read-only access to %s.\n' "$label"
    printf '(allow file-read* (subpath "%s"))\n\n' "$escaped"
  } >> "$policy_file"
}

# --- Workdir grant -----------------------------------------------------------
emit_ancestor_literals "$workdir" "selected workdir"
emit_rw_subpath "$workdir" "selected workdir"

# --- Git worktree handling ---------------------------------------------------
if git_top="$(cd "$workdir" && git rev-parse --show-toplevel 2>/dev/null)"; then
  git_top_real="$(cd "$git_top" && pwd -P)"

  if [[ "$git_top_real" == "$workdir" ]]; then
    git_common_dir="$(cd "$workdir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    git_dir="$(cd "$workdir" && git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"

    # Linked worktree: common dir lives outside the selected workdir.
    if [[ -n "$git_common_dir" && -n "$git_dir" && "$git_common_dir" != "$git_dir" ]]; then
      common_dir_real="$(cd "$git_common_dir" 2>/dev/null && pwd -P || true)"
      if [[ -n "$common_dir_real" && "$common_dir_real" != "$workdir"* ]]; then
        emit_ancestor_literals "$common_dir_real" "git common dir (linked worktree)"
        emit_rw_subpath "$common_dir_real" "shared git common dir"
      fi
    fi

    # Sibling worktrees: snapshot read-only.
    while IFS= read -r wt_line; do
      [[ "$wt_line" != worktree* ]] && continue
      wt_path="${wt_line#worktree }"
      [[ -z "$wt_path" || ! -d "$wt_path" ]] && continue
      wt_real="$(cd "$wt_path" && pwd -P)"
      [[ "$wt_real" == "$workdir" ]] && continue
      emit_ancestor_literals "$wt_real" "linked worktree (sibling)"
      emit_ro_subpath "$wt_real" "sibling worktree snapshot"
    done < <(cd "$workdir" && git worktree list --porcelain 2>/dev/null || true)
  fi
fi

# --- Launch ------------------------------------------------------------------
exec /usr/bin/sandbox-exec -f "$policy_file" "${cmd_args[@]}"
