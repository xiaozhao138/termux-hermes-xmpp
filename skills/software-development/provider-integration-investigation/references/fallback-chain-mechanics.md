# Fallback Chain Mechanics

How `_try_activate_fallback`, `_fallback_activated`, and `restore_primary_runtime` interact in Hermes Agent.

## The Three Key Functions

### `try_activate_fallback(agent, reason)` 
**File:** `agent/chat_completion_helpers.py:2392+`

Switches to the next fallback model/provider in the chain.

**Key behaviors:**
- Increments `agent._fallback_index`
- Sets `agent._fallback_activated = True` when activating a fallback
- For rate_limit/billing/upstream_rate_limit: arms exponential backoff cooldown
- Returns `False` when chain exhausted
- Calls `agent.switch_model()` to perform the actual swap

**State changes:**
```python
agent._fallback_index += 1
agent._fallback_activated = True
agent.model = fb_model
agent.provider = fb_provider
agent.base_url = fb_base_url
```

### `restore_primary_runtime(agent)`
**File:** `agent/agent_runtime_helpers.py:1488-1720`

Restores the primary runtime at the start of a new turn.

**Key behaviors:**
- If `not agent._fallback_activated`: resets `_fallback_index = 0` and returns `False`
- If `_rate_limited_until > now`: stays on fallback, returns `False`
- Checks credential pool `next_available_at` to avoid guaranteed-failed restores
- Restores `_primary_runtime` snapshot: model, provider, base_url, api_key, client
- Rebuilds client, context compressor, and credential pool
- Returns `True` if primary was restored

**Critical insight:** `restore_primary_runtime()` restores from `_primary_runtime`, which is updated by `switch_model()`. If a runtime model switch happened (like our free-tier rotation), the new model becomes the "primary" in `_primary_runtime`.

### `switch_model(agent, new_model, new_provider, ...)`
**File:** `agent/agent_runtime_helpers.py:2508-2767`

Swaps model/provider in-place for a live agent.

**Key behaviors:**
- Snapshots all mutable fields before swap
- Rolls back via `_restore_snapshot()` on failure
- Updates `_primary_runtime` at the end so change persists across turns
- Does NOT call `save_config` or `_save_model_choice` (no config persistence)
- Rebuilds client, credential pool, context compressor

**State changes:**
```python
agent.model = new_model
agent.provider = new_provider
agent.base_url = base_url
agent.api_mode = api_mode
agent._primary_runtime = { ... }  # updated with new state
```

## The Turn Lifecycle

```
New turn starts
  ↓
restore_primary_runtime()
  ├─ if fallback was activated this turn → stay on fallback
  ├─ if primary is rate-limited → stay on fallback
  └─ otherwise → restore primary from _primary_runtime
  ↓
API call
  ├─ success → continue
  └─ failure → error classification
      ↓
      if should_fallback:
        try_activate_fallback()
          ├─ try free-tier rotation (NEW)
          ├─ if rotated → return True (skip fallback chain)
          └─ if not rotated → walk fallback chain
      ↓
      if chain exhausted or no fallback:
        surface error to user
```

## Key Invariants

1. **`_fallback_activated` is ONLY set by `try_activate_fallback()`**, not by `switch_model()` directly
2. **`_primary_runtime` is updated by `switch_model()`**, so runtime switches become the new "primary"
3. **`restore_primary_runtime()` checks `_fallback_activated` first**, before checking `_rate_limited_until`
4. **Fallback is turn-scoped**: if `restore_primary_runtime()` succeeds, the next turn starts fresh with `_fallback_index = 0`

## Implications for Dynamic Model Rotation

When we rotate Nous free-tier models via `switch_model()`:
- `_fallback_activated` stays `False` (we didn't go through `try_activate_fallback()`)
- `_primary_runtime` gets updated to the new model
- On next turn, `restore_primary_runtime()` sees `_fallback_activated = False` and... 
  - Resets `_fallback_index = 0` (good)
  - Then restores `_primary_runtime` (which has the NEW model)
- Result: **the rotated model persists across turns within the same session**

This is actually the desired behavior — if we rotated because the old model is broken, we want to keep trying the new model.

## Common Pitfalls

- **Don't set `_fallback_activated = True` for intra-provider model rotation** — that would make `restore_primary_runtime()` think a fallback is active and skip restoration
- **Don't call `_try_activate_fallback()` after a successful rotation** — the rotation IS the fallback handling; calling both causes duplicate work
- **Don't persist the rotated model to config** — `switch_model()` doesn't write config, which is correct; only `_save_model_choice()` persists
- **Do update `_primary_runtime`** — otherwise `restore_primary_runtime()` would revert to the broken model on next turn
