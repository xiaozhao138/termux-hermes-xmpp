---
name: hermes-gateway-integration
description: Add a messaging platform to Hermes Gateway.
triggers:
  - add platform to Hermes
  - integrate messaging platform
  - XMPP adapter Hermes
  - Hermes gateway platform
  - send_message routing
  - cron delivery platform
---

# Hermes Gateway Platform Integration

## Minimal Core Changes for a New Platform

To integrate a new platform P into Hermes Gateway, make these localized
core edits only. Do not refactor existing platforms.

1. `gateway/config.py`: Add `P = "p"` to the `Platform` enum.
2. `gateway/config.py`: In `_load()`, when env vars for P are present,
   create a config via `_enable_from_env(Platform.P)` and populate
   `extra` with connection fields. This also establishes the home channel
   if `P_HOME_CHANNEL` is set.
3. `gateway/authz_mixin.py`: Add `Platform.P` to:
   - `platform_env_map` → `P_ALLOWED_USERS` (or JIDs)
   - `platform_allow_all_map` → `P_ALLOW_ALL_USERS`
4. `tools/send_message_tool.py`: Route `Platform.P` in `_send_to_platform`
   through the live adapter (`_send_via_adapter`) or the plugin's
   `standalone_sender_fn`. Smart-chunking and max length come from
   `_MAX_LENGTHS` or the registry fallback.
5. `cron/scheduler.py`: `_deliver_result` already uses `_send_to_platform`,
   so once `send_message_tool` routes P, cron delivery works.
6. `gateway/run.py`: `_create_adapter` checks `platform_registry` first,
   then built-in elif chain. Register the platform in the registry via
   a plugin; no built-in elif is required for plugin platforms.

## Plugin Registration Pattern

Third-party adapters live in `~/.hermes/plugins/<platform>/`.

- `plugin.yaml`: declare `name`, `kind=platform`, `requires_env`,
   `setup` hints, and optional `home_channel_env`.
- `__init__.py`: `from .adapter import register`
- `adapter.py`:
  - Inherit `BasePlatformAdapter`.
  - Implement `connect()`, `disconnect()`, `send(chat_id, content, metadata)`.
  - Expose a `register(ctx)` function that calls `ctx.register_platform(...)`
    with a `PlatformEntry` containing at least:
    - `label`
    - `adapter_factory`
    - `check_fn`
    - `validate_config`
    - `allowed_users_env`
    - `allow_all_env`
    - `home_channel_env`
    - `standalone_sender_fn` (critical for cron delivery outside gateway)
  - Set `adapter.gateway_runner = self` in `_create_adapter` for
    cross-platform admin alerts and profile routing.

## slixmpp 1.8+ Connection Notes

slixmpp 1.17.0 changed `ClientXMPP.connect()`:
- Signature is `connect(host=None, port=None)`, returning a future.
- Do NOT pass `use_tls=`, `tls_verify=`, or `server=` as kwargs.
- TLS is automatic via `tls_services = {'xmpps-client'}` and
  `starttls_services = {'xmpp-client'}`.
- After `connect()`, **run `asyncio.create_task(client.run_filters())`** so
  stream features, auth, bind, and `session_start` actually process.
  `connect()` only covers TCP bring-up; without `run_filters()`,
  `bound`/`authenticated` never change and `wait_until_bound()` is not
  available in 1.17.0.
- For direct-TLS C2S on port 5222, set `enable_direct_tls` if needed.

## Pitfalls

- **Respect user stop signals immediately.** If the user says "stop",
  "不要继续", or equivalent, halt all background testing and reasoning
  loops. Do not continue blind retries or additional probes.
- **Verify server-side config before client testing.** Confirm the
  server's XMPP service is actually running and listening on the
  expected port before writing client connection logic. Ask the user
  for the server config or service name if unsure.
- **Do not hardcode ports.** Use `XMPP_PORT` env var; default to the
  server's standard port. If the user says "public entry is 443", treat
  that as authoritative until they confirm otherwise.
- **Cron delivery needs `standalone_sender_fn`.** Without it, cron jobs
  deliver only while the gateway is in-process. Register it on the
  `PlatformEntry`.
- **Don't modify other platform behaviors.** Keep changes localized to
  the new platform's branches and maps.

## Server-Side XMPP Checks

Before testing a new XMPP account:
1. Confirm service: Prosody / ejabberd / Openfire / other.
2. Confirm listener: `netstat -tlnp | grep :5222` or equivalent.
3. Confirm TLS mode: STARTTLS vs direct TLS vs WebSocket.
4. Confirm if 443 is reverse-proxied to 5222 or served as XMPP WebSocket.
5. Test with a known-good client (Gajim, Dino, Conversations) before
   blaming the Hermes adapter.
