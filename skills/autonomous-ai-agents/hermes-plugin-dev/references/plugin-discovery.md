# Plugin Discovery Internals

## Sources

Plugins are discovered from four sources, in order:

1. Bundled plugins under `<repo>/plugins/<name>/`
2. User plugins under `~/.hermes/plugins/<name>/`
3. Project plugins under `./.hermes/plugins/<name>/`
4. Pip plugins via `hermes_agent.plugins` entry points

Later sources override earlier ones.

## Bundled vs User Platform Plugins

- Bundled platform plugins register lazily via deferred loaders.
- User/installed platform plugins are gated by `plugins.enabled`.
- Run `hermes plugins enable <name>` to activate a user platform plugin.

## Scoped Registry

User plugins often register under `_scoped_entries` keyed by the active
`HERMES_HOME`, not the global `_entries`. When checking registration,
inspect both maps.

## Common Failure Modes

- Missing `register()` in plugin package `__init__.py`
- Wrong lookup key in `plugins.enabled`; use manifest name, not directory name
- Missing `python_dependencies` declaration causes silent skip if dependencies are absent
- Secret source imports failing at plugin discovery time due unrelated plugins
