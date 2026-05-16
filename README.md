# safe-claude-via-agent-safehouse

A `sandbox-exec` durable profile + launcher that lets [Claude Code](https://claude.com/claude-code) run a normal **Ruby on Rails development loop** — including `bundle install`, `bundle exec rspec`, and **Capybara/Selenium feature specs with headless Chrome** — inside macOS's `sandbox-exec` jail (via `safe-claude`, a thin wrapper around this repo's `run-sandboxed.sh`).

The structure of this profile and launcher is derived from [agent-safehouse](https://agent-safehouse.dev/) (see Attribution below). Out of the box, the agent-safehouse-style profile is locked down enough that several things a Rails project does on `require` time fail with `Operation not permitted`. This repo's `agent.sb` is a Rails-aware variant with the additional grants needed for Bundler, RSpec, and Capybara to work end-to-end.

## Who this is for

Ruby on Rails developers who:

- Use [Claude Code](https://claude.com/claude-code) for day-to-day work on a Rails app.
- Run it through agent-safehouse (i.e. invoke `safe-claude` rather than plain `claude`) for the security benefits of sandbox-exec — no surprise writes outside the project, no Docker socket access, no SSH agent, network egress denylists, etc.
- Want their Rails workflow — including **feature specs that launch a real headless Chrome** — to "just work" inside that sandbox.

If you don't need feature specs, the rest of the Rails workflow (unit/request specs, RuboCop, Rails console, asset builds, etc.) works on the stock agent-safehouse profile too — this repo is most valuable when you want the full test pyramid under sandbox.

## What's different from a stock agent-safehouse profile

This profile starts from the structure agent-safehouse emits, then adds the grants you need for Rails. The diff falls into two buckets:

### 1. Ruby / Rails loader path

Some Ruby gems read `/etc/resolv.conf` at `require` time — e.g. `knapsack_pro` (transitively, via `net/http` → `Resolv`). The stock profile allows `/private/etc/resolv.conf` but not the symlink chain it dereferences to (`/private/var/run/resolv.conf`), so the very first `require 'knapsack_pro'` in your `spec_helper.rb` raises `Errno::EPERM @ rb_sysopen - /etc/resolv.conf`.

This profile grants the canonical symlink target so `require`-time DNS / network init works.

### 2. Headless Chrome (Capybara/Selenium feature specs)

Running a Capybara `:selenium_chrome` feature spec inside sandbox-exec is non-trivial — Chrome touches a *lot* of macOS surface area on launch. This profile adds the union of everything needed, including:

- **Read access** to `/Applications/Google Chrome.app`, `~/.webdrivers/` (chromedriver cache), `~/Library/Preferences/*.plist` (Accessibility, CoreGraphics, Dock, Keystone…), `~/Library/Application Support/Google/*`, `/Library/Google/*`, `/Library/Managed Preferences`, `~/Applications/Chrome Apps.localized`, and Spotlight metadata.
- **Read/write** to `~/Library/Application Support/Google/Chrome` (Chrome's user profile + Crashpad reports).
- **`file-link`** on `/private/var/folders` and `/tmp` so Chrome's per-launch code-sign clone (a hardlink of itself into a temp dir) doesn't die. *(Note: these denials are non-fatal — Chrome logs and continues — but granting them eliminates noise in the deny log.)*
- **`mach-lookup` + `mach-register`** for ~30 system services Chrome touches (`tccd`, `windowserver.active`, `pasteboard.1`, `CARenderServer`, `bsd.dirhelper`, `opendirectoryd.api/membership`, etc.) **and** the dynamic Chrome IPC patterns (`com.google.Chrome.MachPortRendezvousServer.<pid>`, `org.chromium.crashpad.child_port_handshake.<pid>.<n>.<nonce>`, `com.google.Chrome.apps.<hash>`). **Both register *and* lookup are required** — Chrome's parent registers per-pid rendezvous ports and its subprocesses look them up; granting only register causes Chrome IPC to stall and chromedriver to time out with `Net::ReadTimeout`, which is the most confusing symptom in this whole stack.
- **`iokit-open`** for `AGXDeviceUserClient`, `AppleUSBHostDeviceUserClient`, `IOHIDParamUserClient`, `IOSurfaceRootUserClient`, `RootDomainUserClient`.
- **`user-preference-read`** for `com.apple.hitoolbox` (input method prefs).

End result: `bundle exec rspec spec/features/...` works inside `safe-claude`.

## Install

### Prerequisites

**[Claude Code](https://claude.com/claude-code)** — the agent you're sandboxing. Follow Anthropic's install instructions; verify with `which claude`.

macOS's `sandbox-exec` (built in to the OS) and a recent `bash` are the only other runtime requirements. Both the launcher (`run-sandboxed.sh`) and the Rails-aware profile (`agent.sb`) ship in this repo and are deployed by `install.sh`.

### This repo

```bash
git clone https://github.com/<your-user>/safe-claude-via-agent-safehouse.git
cd safe-claude-via-agent-safehouse
./install.sh
```

`install.sh`:

- backs up your existing `~/.config/sandbox-exec/agent.sb` (if any) to `agent.sb.bak.<timestamp>`,
- renders `__HOME_DIR__` in the templated `agent.sb` to your actual `$HOME`,
- writes the result to `~/.config/sandbox-exec/agent.sb` (or `$SAFEHOUSE_DURABLE_PROFILE` if set),
- backs up any existing `~/.config/sandbox-exec/run-sandboxed.sh` and installs this repo's launcher to that path (mode `0755`),
- appends a three-line block to your shell rc (`~/.zshrc` or `~/.bash_profile`, detected from `$SHELL`):
  - `export SAFEHOUSE_DURABLE_PROFILE=...` pinning `run-sandboxed.sh` to the exact profile path this install wrote to (matters if `$SAFEHOUSE_DURABLE_PROFILE` was set during install),
  - a `safe-run` shell function that wraps `~/.config/sandbox-exec/run-sandboxed.sh`,
  - a `safe-claude` shell function that runs `safe-run claude --dangerously-skip-permissions` (Claude Code's own permission layer is redundant once you're already inside sandbox-exec).

It's idempotent — re-run it any time you pull updates. The agent.sb write is skipped when the rendered content already matches what's on disk, and the rc block is guarded by a marker comment so it's only appended once. Open a new shell (or `source` the rc) to pick up the new functions.

## Verify

From a Rails project that uses Capybara + headless Chrome:

```bash
safe-claude
# inside the session, run any feature spec:
bundle exec rspec spec/features/some_feature_spec.rb
```

The first time you do this from a fresh `~/Library/Application Support/Google/Chrome` profile dir, Chrome will write its initial state there; subsequent runs reuse it.

## How to debug new denials

If a different gem or workflow hits a denial that this profile doesn't cover, follow the loop the file's header documents:

```bash
/usr/bin/log stream --style compact \
  --predicate 'eventMessage CONTAINS "Sandbox:" AND eventMessage CONTAINS "deny("'
```

Run that in one terminal, reproduce the failure in another (`safe-claude` ➜ your command), then grep the stream for the offending operation and add a matching `(allow ...)` clause. Most fixes are one line in `agent.sb`. **Don't fix sandbox issues by editing project code** — the project is shared with your team and CI; the sandbox profile is yours.

## Attribution & licence

The base structure and the original integration snippets come from [eugene1g/agent-safehouse](https://github.com/eugene1g/agent-safehouse). This repo only adds the Rails-specific deltas described above. Before publishing or distributing, check agent-safehouse's licence and make sure your downstream notices comply.
