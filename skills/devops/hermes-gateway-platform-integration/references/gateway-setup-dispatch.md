# Gateway Setup Dispatch

File: `hermes_cli/gateway.py`

Key functions:
- `_all_platforms()` around line 5872: discovers plugins, merges built-ins, filters by OS
- `_configure_platform(platform)` around line 6823: dispatches setup_fn / builtin / standard / env hint
- `gateway_setup()` around line 6867: top-level interactive wizard

Dispatch order in `_configure_platform`:
1. Plugin `entry.setup_fn()` if present
2. Built-in `_builtin_setup_fn(platform["key"])`
3. `_setup_standard_platform(platform)` if `platform.get("vars")` exists
4. Env-var hint fallback

Plugin visibility gate:
- `discover_plugins()` is called inside `_all_platforms()`
- Only `enabled` plugins register into `platform_registry`
- `platform_registry.all_entries()` feeds the menu
