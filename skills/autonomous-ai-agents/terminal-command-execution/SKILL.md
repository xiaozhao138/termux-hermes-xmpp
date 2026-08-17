---
name: terminal-command-execution
description: "Monitor terminal commands; avoid blind waiting loops."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
---

# Terminal Command Execution

Class-level skill for running, monitoring, and managing commands via the `terminal` tool. Emphasizes state-aware execution over blind sleep loops.

## User Preferences (Hard Rules)

1. **Never blindly sleep for long-running commands.** After any wait, immediately check process state and actual output before deciding next steps.
2. **Commands >60s must use state checks.** Use `background=true` + `notify_on_complete=true`, or inspect with `process(action="poll")` / follow-up `terminal` commands that read actual progress.
3. **Check current state before installing.** Before any install, verify whether the target already exists: `which <cmd>`, `dpkg -l | grep <pkg>`, `ls <path>`, or `command -v <tool>`.
4. **Do not reinstall existing dependencies.** If a package/binary/tool is already present, skip the install step and move on.

## Execution Patterns

### Foreground vs Background
- Foreground default timeout: 180s; hard max: 600s.
- For anything that might exceed 600s: use `background=true` + `notify_on_complete=true`.
- For interactive PTY CLIs (prompt_toolkit, tmux): use `pty=true` instead of background.

### Monitoring Background Processes
- After starting a background process, check state with:
  - `process(action="poll")` — running status and new output
  - `process(action="log")` — full output with pagination
  - Follow-up `terminal` commands inspecting files/processes created so far
- Do **not** sleep for arbitrary durations between checks.

### Installer Workflows
- Official installers may fail or time out in restricted environments (Termux, proot-distro, containers).
- Fallback manual installation pattern:
  1. Clone repo or download source
  2. Create venv with correct Python version (`python3.X -m venv venv`)
  3. Install deps (`pip install -e ".[all]"` or `pip install -r requirements.txt`)
  4. Symlink binary to `/usr/local/bin/` or another PATH dir
  5. Verify with `which <cmd>` and `<cmd> --version`
- Always verify Python version compatibility (`>=3.11,<3.14` etc.) before creating the venv.

### Proot-Distro Specifics
- `proot-distro login <name> -- bash -lc '<cmd>'` runs one-shot inside the container.
- To spawn background work inside the container, run the install script via `terminal(background=true, command="proot-distro login <name> -- bash -lc '<script>'")`.
- `NON_INTERACTIVE=true` env var forces non-interactive behavior in many bash installers.

## Pitfalls

- `set -e` + `command || true` combos can mask real failures; check exit codes when debugging.
- `pip install -e ".[all]"` inside a venv whose Python version doesn't satisfy the project's `requires-python` will fail before installing anything.
- `which <cmd>` from inside a proot-distro container may return the Termux host path if the host bind-mount is active; verify with `ls -la $(which <cmd>)` if suspicious.
- Background `npm install` in proot-distro can hang on native module builds; prefer `pip` installs or prebuilt wheels when available.
