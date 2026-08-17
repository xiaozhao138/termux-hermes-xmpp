# XMPP Plugin Setup Flow

## Verified CLI Path
- `hermes plugins setup xmpp-platform` returns exit 2 with `invalid choice: 'setup'`.
- The actual setup entrypoint is `hermes gateway setup`.
- In `_all_platforms()` (`hermes_cli/gateway.py:5872`), plugin platforms are appended only after `discover_plugins()`.
- User-installed plugins under `~/.hermes/plugins/` must be explicitly enabled before appearing in the setup menu:
  ```bash
  hermes plugins enable xmpp-platform
  ```

## Why Enablement Is Required
- `hermes plugins list` shows `xmpp-platform` as `not enabled` until enabled.
- `_all_platforms()` does not include disabled plugins in the setup menu.
- Enabling is a separate step from plugin file creation or registry registration.

## Setup Menu Selection
- After enablement, `hermes gateway setup` shows `XMPP` in the platform list.
- Selection dispatches to `entry.setup_fn()` if the `PlatformEntry` defines one.
- Our `adapter.py` registers `setup_fn=interactive_setup`.

## Security Note
- Password input in `interactive_setup()` uses `prompt(..., password=True)`.
- `save_env_value()` writes to Hermes secret storage, not plain `.env`.
