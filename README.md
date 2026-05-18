# yolo-sandboxed-claude

Run [Claude Code](https://claude.com/claude-code) with `--dangerously-skip-permissions` (a.k.a. YOLO mode) inside a macOS `sandbox-exec` jail, with a sandbox profile tuned for **Ruby on Rails** development — including **Capybara feature specs that launch real headless Chrome**.

## Why you might want this

`claude --dangerously-skip-permissions` lets the agent run any command without asking you first. That's productive, but the agent can also:

- delete or modify files outside your project,
- exfiltrate data to arbitrary network endpoints,
- talk to your Docker socket, SSH agent, or keychain,
- write to `~/.zshrc`, `~/.ssh/`, etc.

Wrapping it in `sandbox-exec` (macOS's built-in sandbox) confines the agent to your project directory and a small set of explicitly-allowed system resources. If it tries to `rm -rf ~/Documents`, the kernel denies it.

The catch: a stock locked-down profile is *too* strict for Rails. `bundle install`, `rspec`, and especially Capybara/Selenium feature specs fail with `Operation not permitted` on things like `/etc/resolv.conf` symlink resolution or Chrome's IPC handshake.

This repo's `agent.sb` is a Rails-aware profile that adds exactly the grants needed to make `bundle exec rspec spec/features/...` work, and nothing more. It ships with its own launcher (`run-sandboxed.sh`) so you don't need any other tools installed.

## Quick start

```bash
git clone https://github.com/dbackowski/yolo-sandboxed-claude.git
cd yolo-sandboxed-claude
./install.sh
```

Open a new shell, then `cd` into your Rails project and run:

```bash
yolo-sandboxed-claude
```

You're now in Claude Code, sandboxed.

## Prerequisites

- macOS (uses the built-in `sandbox-exec`).
- [Claude Code](https://claude.com/claude-code) installed — verify with `which claude`.
- `bash` and `git` (both present on any modern macOS).

## What `install.sh` does

- Writes the Rails-aware profile to `~/.config/yolo-sandboxed-claude/agent.sb` (backing up any existing file, with `__HOME_DIR__` templated to your real `$HOME`).
- Installs the launcher to `~/.config/yolo-sandboxed-claude/run-sandboxed.sh`.
- Appends a marker-delimited block to your `~/.zshrc` or `~/.bash_profile`:
  ```bash
  export YOLO_CLAUDE_DURABLE_PROFILE="$HOME/.config/yolo-sandboxed-claude/agent.sb"
  safe-run()    { "$HOME/.config/yolo-sandboxed-claude/run-sandboxed.sh" "$@"; }
  yolo-sandboxed-claude() { safe-run claude --dangerously-skip-permissions "$@"; }
  ```

`safe-run` is the generic wrapper — use it to sandbox any command (`safe-run codex`, `safe-run rspec`, etc.) without the `--dangerously-skip-permissions` flag. `yolo-sandboxed-claude` is the Claude-specific shortcut that adds the skip-permissions flag, since the sandbox already enforces the boundary.

It's idempotent — re-run any time you pull updates.

## What's in the profile

Two Rails-specific deltas on top of a baseline locked-down profile:

1. **Symlink target for `/etc/resolv.conf`** — some gems (e.g. `knapsack_pro` via `net/http`/`Resolv`) read it at `require` time, and a typical strict profile allows the symlink but not its target (`/private/var/run/resolv.conf`).
2. **Headless Chrome surface** — file reads under `/Applications/Google Chrome.app`, `~/.webdrivers/`, Chrome's user-profile directory, plus the `mach-lookup`/`mach-register`/`iokit-open` grants Chrome needs for its multi-process IPC. Without these, chromedriver hangs with `Net::ReadTimeout`.

See comments inside [`agent.sb`](agent.sb) for the line-by-line rationale.

## What the sandbox allows

The profile is `deny default` — everything is blocked unless explicitly granted. The grants fall into these buckets:

- **Your current working directory** — read/write to the project you ran `yolo-sandboxed-claude` from (emitted at launch by `run-sandboxed.sh`, plus sibling git worktrees if applicable).
- **System binaries and libraries** — read access to `/usr`, `/bin`, `/sbin`, `/opt`, `/System/Library`, `/Library/Frameworks`, fonts, CA bundles, timezone data.
- **Toolchains** — Apple Command Line Tools (`xcrun`, `clang`, `git`), Ruby (RVM, Bundler, gem caches), and asdf shims.
- **Network** — outbound network is fully open. (A stricter denylist variant is sketched in `agent.sb` comments if you want to tighten it.)
- **Git & SCM** — `~/.gitconfig`, XDG git config, `gh`/`glab` CLI state and tokens.
- **Keychain** — required by Claude Code / Codex / cursor-agent to store API credentials.
- **Headless Chrome** — Chrome.app, `~/.webdrivers/`, Chrome's user-profile directory, plus the Mach IPC and IOKit grants Selenium needs.
- **Launch Services** — enough to let `open <file>` resolve a handler.
- **`/tmp` and per-process temp dirs** — read/write.

Explicitly **blocked** (defense in depth, even though they'd be denied by default):

- **Docker / OrbStack / Podman sockets** — both filesystem path and `AF_UNIX` connect.
- **SSH agent socket** — `~/.ssh/agent` and the launchd-managed listener.

## What this does NOT protect against

The sandbox is not magic. Things still allowed:

- **Anything inside your project directory** — the agent can rewrite, delete, or commit your code. Use git.
- **Network egress to allowed hosts** — Claude's API, package registries, etc. The agent can still exfiltrate data to those.
- **Bypassing Claude's own permission prompts** — that's the point of `--dangerously-skip-permissions`. Re-enable them if you want belt-and-braces.

Treat this as a guardrail against accidents and low-effort mistakes, not a defense against a deliberately adversarial agent.

## Verify it works

From a Rails project that uses Capybara + headless Chrome:

```bash
yolo-sandboxed-claude
# inside the session:
bundle exec rspec spec/features/some_feature_spec.rb
```

## Knowing you're sandboxed

`run-sandboxed.sh` exports `YOLO_CLAUDE_SANDBOX=1` into the sandboxed process so anything inside can detect it. Plumb the env var into a tool that's always visible:

**Sandboxed shell prompt** (useful when you run `safe-run zsh` for an interactive sandboxed shell). In your `~/.zshrc`:

```zsh
[[ -n "$YOLO_CLAUDE_SANDBOX" ]] && PROMPT="%F{yellow}[sandboxed]%f $PROMPT"
```

bash equivalent in `~/.bash_profile`:

```bash
[[ -n "$YOLO_CLAUDE_SANDBOX" ]] && PS1="\[\033[33m\][sandboxed]\[\033[0m\] $PS1"
```

**Claude Code status line** — add a `statusLine` to `~/.claude/settings.json` that emits a tag when the env var is set. The command's stdout becomes the status line text (ANSI escapes are honored), and it returns nothing when you're outside the sandbox:

```json
{
  "statusLine": {
    "type": "command",
    "command": "[ -n \"$YOLO_CLAUDE_SANDBOX\" ] && printf '\\033[33m[sandboxed]\\033[0m'"
  }
}
```

If you already have a `statusLine` command, prepend the sandbox check to it instead of replacing — e.g. `[ -n "$YOLO_CLAUDE_SANDBOX" ] && printf '[sandboxed] '; your-existing-command`.

## Debugging new denials

If a gem or tool hits a denial this profile doesn't cover, watch the deny log:

```bash
/usr/bin/log stream --style compact \
  --predicate 'eventMessage CONTAINS "Sandbox:" AND eventMessage CONTAINS "deny("'
```

Reproduce the failure in another terminal, find the offending operation in the stream, and add a matching `(allow ...)` clause to `agent.sb`. Most fixes are one line. **Don't fix sandbox issues by editing project code** — the project is shared with your team and CI; the sandbox profile is yours.

## Uninstall

1. Remove the block between `# >>> yolo-sandboxed-claude >>>` and `# <<< yolo-sandboxed-claude <<<` from your shell rc.
2. Delete `~/.config/yolo-sandboxed-claude/` (or restore the newest `agent.sb.bak.*` in that directory if you want to keep a profile around).
3. Open a new shell.

## Compatibility

Tested on macOS 14/15 with recent Chrome stable. Chrome's IPC service names and IOKit user-client classes can change across major versions — if feature specs start hanging after a Chrome update, re-run the deny-log loop above.
