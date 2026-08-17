# Bundled vs User Platform Plugins

## Bundled Platform Plugins

Live under `hermes-agent/plugins/platforms/<name>/`. They are discovered automatically and registered lazily. No `hermes plugins enable` step is needed.

Examples: `irc-platform`, `discord-platform`, `telegram-platform`.

## User Platform Plugins

Live under `~/.hermes/plugins/<name>/`. They are discovered, but **not loaded** unless they appear in `plugins.enabled`.

Activation:

```bash
hermes plugins enable <manifest-name>
```

Manifest name is the `name:` field in `plugin.yaml`, usually `<platform>-platform`.

## Diagnostic Difference

After discovery:

```python
from hermes_cli.plugins import get_plugin_manager
mgr = get_plugin_manager()
loaded = mgr._plugins.get("<manifest-name>")
print("enabled:", loaded.enabled)
```

Bundled platforms show `enabled=True` automatically. User platforms show `enabled=False` until explicitly enabled.
