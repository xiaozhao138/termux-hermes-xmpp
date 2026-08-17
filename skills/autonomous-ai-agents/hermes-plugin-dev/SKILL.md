---
name: hermes-plugin-dev
description: "Build and debug Hermes Agent plugins and platform adapters."
version: 1.0.0
author: Hermes Agent
---

# Hermes Plugin Development

Covers plugin discovery, platform adapter registration, runtime diagnosis,
and common gotchas for third-party Hermes plugins.

## Quick Start

A platform plugin needs three files under `~/.hermes/plugins/<name>/`:

- `plugin.yaml`
- `adapter.py`
- `__init__.py` exporting `register`

Enable with:

```bash
hermes plugins enable <plugin-name-from-manifest>
```

## Plugin Skeleton

```text
~/.hermes/plugins/xmpp/
  plugin.yaml
  adapter.py
  __init__.py
```

`__init__.py`:

```python
from .adapter import register

__all__ = ["register"]
```

`adapter.py` must define `register(ctx)` and call `ctx.register_platform(...)`.

## Registration API

Call exactly this from `register(ctx)`:

```python
def register(ctx):
    ctx.register_platform(
        name="xmpp",
        label="XMPP",
        adapter_factory=lambda cfg: XMPPAdapter(cfg),
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=["XMPP_JID", "XMPP_PASSWORD"],
        install_hint="pip install slixmpp",
        setup_fn=interactive_setup,
        env_enablement_fn=_env_enablement,
        cron_deliver_env_var="XMPP_HOME_CHANNEL",
        standalone_sender_fn=None,
        allowed_users_env="XMPP_ALLOWED_JIDS",
        allow_all_env="XMPP_ALLOW_ALL_JIDS",
        max_message_length=0,
        emoji="💬",
        pii_safe=True,
        allow_update_command=True,
        platform_hint="You are chatting via XMPP/Jabber. ...",
    )
```

## Discovery Diagnosis

After `hermes plugins enable <name>` or `discover_plugins(force=True)`:

```python
from hermes_cli.plugins import discover_plugins, get_plugin_manager
from gateway.platform_registry import platform_registry

discover_plugins(force=True)
mgr = get_plugin_manager()
loaded = mgr._plugins.get("<plugin-name>")
print("enabled:", loaded.enabled)
print("module:", loaded.module)
print("error:", loaded.error)

# Platform entries may be scoped by HERMES_HOME
print("scoped entries:")
for scope, entries in platform_registry._scoped_entries.items():
    for name, entry in entries.items():
        print(scope, name, entry.label)
```

Do not assume a missing `platform_registry._entries` means the plugin failed;
user plugins often register under `_scoped_entries`.

## Import / Venv Gotcha (Termux, custom installs)

`python3` on Termux may not see packages installed into the Hermes venv.

Reliable checks:

```bash
~/.hermes/hermes-agent/venv/bin/python -c "import slixmpp; print(slixmpp.__version__)"
```

Reliable imports from ad-hoc scripts:

```python
import sys
sys.path.insert(0, "/data/data/com.termux/files/home/.hermes/hermes-agent")
sys.path.insert(0, "/data/data/com.termux/files/home/.hermes/plugins/xmpp")
```

## Core Enum Limitation

`Platform("<name>")` only succeeds for enum members already defined in
`gateway/config.py`. Third-party plugins can register `PlatformEntry`
objects, but gateway dispatch, `send_message`, cron delivery, auth maps,
slash commands, and channel directory still rely on core-level enum
members and hardcoded branches.

If `Platform("xmpp")` raises `ValueError`, the plugin cannot be
instantiated by the gateway runner until the enum is extended in core.

## Minimal Adapter Requirements

To integrate cleanly with `BasePlatformAdapter`:

- `__init__(self, config, **kwargs)` — call `super().__init__(config, Platform("<name>"))`
- `connect()` — establish transport, return `True` on success
- `disconnect()` — tear down listeners, cancel tasks, close transports
- `send(chat_id, content, reply_to, metadata)` — return `SendResult`
- `send_typing(chat_id, metadata)` — no-op if unsupported
- `get_chat_info(chat_id)` — return `{"name": ..., "type": ...}`

Use `self.build_source(...)` and `await self.handle_message(event)` for
inbound dispatch.

## Self-Message / Loop Prevention

Drop messages where `from_jid == self._own_bare_jid` or
`sender_nick.lower() == self._current_nick.lower()` before dispatch.

## Reconnection Pattern

Use exponential backoff with jitter around a central stop event:

```python
attempt = 0
while not self._stop_event.is_set():
    try:
        ok = await self._connect_once()
        if ok:
            return
    except Exception as exc:
        logger.warning("connect attempt %s failed: %s", attempt, exc)
    attempt += 1
    backoff = min(60.0, (2 ** attempt) + random.uniform(0, 1.0))
    try:
        await asyncio.wait_for(self._stop_event.wait(), timeout=backoff)
    except asyncio.TimeoutError:
        continue
```

## References

- `references/plugin-discovery.md` — discovery internals and scoped registry behavior
- `references/termux-venv-imports.md` — Termux/Hermes venv import pitfalls
- `references/bundled-vs-user-platform-plugins.md` — bundled vs user platform plugin loading rules
