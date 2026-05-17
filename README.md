# safe-claude-via-agent-safehouse

Run [Claude Code](https://claude.com/claude-code) with `--dangerously-skip-permissions` inside a macOS `sandbox-exec` jail, with a sandbox profile tuned for **Ruby on Rails** development — including **Capybara feature specs that launch real headless Chrome**.

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
git clone https://github.com/dbackowski/safe-claude-via-agent-safehouse.git
cd safe-claude-via-agent-safehouse
./install.sh
```

Open a new shell, then `cd` into your Rails project and run:

```bash
safe-claude
```

You're now in Claude Code, sandboxed.

## Prerequisites

- macOS (uses the built-in `sandbox-exec`).
- [Claude Code](https://claude.com/claude-code) installed — verify with `which claude`.
- `bash` and `git` (both present on any modern macOS).

## What `install.sh` does

- Writes the Rails-aware profile to `~/.config/sandbox-exec/agent.sb` (backing up any existing file, with `__HOME_DIR__` templated to your real `$HOME`).
- Installs the launcher to `~/.config/sandbox-exec/run-sandboxed.sh`.
- Appends a marker-delimited block to your `~/.zshrc` or `~/.bash_profile`:
  ```bash
  export SAFEHOUSE_DURABLE_PROFILE="$HOME/.config/sandbox-exec/agent.sb"
  safe-run()    { "$HOME/.config/sandbox-exec/run-sandboxed.sh" "$@"; }
  safe-claude() { safe-run claude --dangerously-skip-permissions "$@"; }
  ```

It's idempotent — re-run any time you pull updates.

## What's in the profile

Two Rails-specific deltas on top of a baseline locked-down profile:

1. **Symlink target for `/etc/resolv.conf`** — some gems (e.g. `knapsack_pro` via `net/http`/`Resolv`) read it at `require` time, and a typical strict profile allows the symlink but not its target (`/private/var/run/resolv.conf`).
2. **Headless Chrome surface** — file reads under `/Applications/Google Chrome.app`, `~/.webdrivers/`, Chrome's user-profile directory, plus the `mach-lookup`/`mach-register`/`iokit-open` grants Chrome needs for its multi-process IPC. Without these, chromedriver hangs with `Net::ReadTimeout`.

See comments inside [`agent.sb`](agent.sb) for the line-by-line rationale.

## What this does NOT protect against

The sandbox is not magic. Things still allowed:

- **Anything inside your project directory** — the agent can rewrite, delete, or commit your code. Use git.
- **Network egress to allowed hosts** — Claude's API, package registries, etc. The agent can still exfiltrate data to those.
- **Bypassing Claude's own permission prompts** — that's the point of `--dangerously-skip-permissions`. Re-enable them if you want belt-and-braces.

Treat this as a guardrail against accidents and low-effort mistakes, not a defense against a deliberately adversarial agent.

## Verify it works

From a Rails project that uses Capybara + headless Chrome:

```bash
safe-claude
# inside the session:
bundle exec rspec spec/features/some_feature_spec.rb
```

## Debugging new denials

If a gem or tool hits a denial this profile doesn't cover, watch the deny log:

```bash
/usr/bin/log stream --style compact \
  --predicate 'eventMessage CONTAINS "Sandbox:" AND eventMessage CONTAINS "deny("'
```

Reproduce the failure in another terminal, find the offending operation in the stream, and add a matching `(allow ...)` clause to `agent.sb`. Most fixes are one line. **Don't fix sandbox issues by editing project code** — the project is shared with your team and CI; the sandbox profile is yours.

## Uninstall

1. Remove the block between `# >>> safe-claude-via-agent-safehouse >>>` and `# <<< safe-claude-via-agent-safehouse <<<` from your shell rc.
2. Restore the newest `~/.config/sandbox-exec/agent.sb.bak.*` over `agent.sb`, or delete it if you don't need a profile there.
3. Open a new shell.

## Compatibility

Tested on macOS 14/15 with recent Chrome stable. Chrome's IPC service names and IOKit user-client classes can change across major versions — if feature specs start hanging after a Chrome update, re-run the deny-log loop above.
