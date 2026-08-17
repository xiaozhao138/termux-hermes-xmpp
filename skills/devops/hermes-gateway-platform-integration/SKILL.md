---
name: hermes-gateway-platform-integration
description: "Use when wiring a Hermes gateway platform adapter."
trigger: "Hermes gateway platform integration, plugin setup menu missing"
---

# Hermes Gateway Platform Integration

## Overview

Hermes gateway discovers messaging platforms through two paths:
1. Built-in `_PLATFORMS` list in `hermes_cli/gateway.py`
2. Plugin-registered entries in `gateway/platform_registry.py`

New adapters should register via `platform_registry.register_platform(...)` and
implement `interactive_setup()` for `hermes gateway setup` integration.

## Minimum Integration Checklist

- [ ] `Platform.<NAME>` exists in `gateway/config.py` (or plugin adapter works without it)
- [ ] Plugin `register()` calls `ctx.register_platform(...)` with:
  - `name`, `label`, `adapter_factory`
  - `check_fn`, `validate_config`, `is_connected`
  - `setup_fn=interactive_setup`  ← required for gateway setup menu
  - `required_env`, `allowed_users_env`, `allow_all_env`
- [ ] Plugin is **enabled**: `hermes plugins enable <plugin-name>`
- [ ] Authz mixin updated if platform uses allowlists (`gateway/authz_mixin.py`)
- [ ] `send_message` routing updated if platform needs a send path
- [ ] Core files backed up before modification

## Setup Menu Dispatch

`hermes gateway setup` builds its platform list via `_all_platforms()`:
1. Calls `discover_plugins()` to load plugin registry entries
2. Merges built-in `_PLATFORMS` with plugin entries
3. Filters by host OS (e.g., Matrix hidden on Windows)

When user selects a platform, `_configure_platform()` dispatches in order:
1. Plugin `entry.setup_fn()` if present
2. Built-in `_builtin_setup_fn(platform["key"])`
3. `_setup_standard_platform(platform)` if `platform.get("vars")` exists
4. Env-var hint fallback

## Critical Distinctions

| Command | Purpose | Notes |
|---------|---------|-------|
| `hermes gateway setup` | Configure messaging platforms | This is where `interactive_setup()` runs |
| `hermes plugins enable <name>` | Enable a user-installed plugin | Required before platform appears in setup menu |
| `hermes plugins setup ...` | **Does not exist** | Will exit with error; do not attempt |

## Pitfalls

- **Plugin disabled**: A newly installed plugin shows `not enabled` in `hermes plugins list`. It will NOT appear in `hermes gateway setup` until enabled.
- **Missing `setup_fn`**: If `register_platform()` omits `setup_fn`, the platform falls through to env-var hint text instead of interactive setup.
- **Core enum missing**: Some core paths key on `Platform.<NAME>`. If absent, add it to `gateway/config.py` with `_missing_` support for lowercase strings.
- **Authz not wired**: Without `allowed_users_env` and `allow_all_env` in registry plus mixin branches, the platform will load but reject all users.
- **Port configuration**: Never hardcode ports. Read `XMPP_PORT` / equivalent from env with a sensible default; allow both 443 and 5222 style endpoints.
- **Password storage**: Use Hermes setup prompts (`password=True`) or secret-scoped env storage. Never write passwords to plaintext plugin files.
- **Don't mock interactive setup**: Do not script `input()` or `getpass` to bypass setup flows. Use the real `hermes gateway setup` command.

## Verification Sequence

```bash
# 1. Confirm plugin enabled
hermes plugins list | grep <name>

# 2. Confirm platform in setup menu
hermes gateway setup   # look for platform label

# 3. Run interactive setup via real command
hermes gateway setup   # select platform, enter values

# 4. Verify config loaded
hermes gateway status

# 5. Start gateway
hermes gateway run
```

## References

- `references/gateway-setup-dispatch.md` — line-accurate dispatch flow in `hermes_cli/gateway.py`
- `references/plugin-registration.md` — `register_platform()` contract and fields
- `references/xmpp-integration.md` — session notes for XMPP adapter on Termux with slixmpp 1.17
