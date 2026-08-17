---
name: provider-integration-investigation
description: Investigate provider auth before modifying runtime logic.
---

# Provider Integration Investigation

Systematic investigation of provider auth, model selection, fallback, and runtime behavior in large agent codebases. Use when you need to understand how a provider works end-to-end, or before modifying provider-related runtime logic.

## Trigger

- User asks to investigate how a provider works (auth, models, fallback, pricing)
- Before modifying provider-related runtime code (model switching, fallback, rate limiting)
- Need to trace full call chains across auth → model selection → runtime → fallback

## Phases

### 1. Map the entry points

Start with the provider registry and config:

```
hermes_cli/auth.py          → PROVIDER_REGISTRY, auth flows, token refresh
hermes_cli/providers.py     → Provider overlays, transport definitions
hermes_cli/models.py        → Curated model lists, pricing, free-tier detection
hermes_cli/provider_catalog.py → Remote catalog manifests
```

Key patterns to search:
- `PROVIDER_REGISTRY["<provider>"]` for auth config
- `_PROVIDER_MODELS["<provider>"]` for curated model lists
- `<provider>_free_tier` for free-tier detection
- `union_with_portal_*_recommendations` for dynamic model discovery

### 2. Trace the runtime call chain

Follow the actual execution path:

```
Agent init: agent_init.py
  → model setup: model_setup_flows.py
  → auth resolution: auth.py resolve_*_runtime_credentials()
  → model selection: models.py get_curated_*_model_ids()
  → pricing: models.py get_pricing_for_provider()
  → free-tier check: models.py check_*_free_tier()

Runtime loop: conversation_loop.py
  → rate limit guards
  → API call dispatch
  → error classification
  → fallback activation

Fallback helpers: agent_runtime_helpers.py, chat_completion_helpers.py
  → switch_model()
  → try_activate_fallback()
  → restore_primary_runtime()
```

### 3. Identify modification safe-zones

Before editing, confirm:

- [ ] The function does NOT call `save_config`, `_save_model_choice`, or write to `config.yaml`
- [ ] The function snapshots and restores state on failure (rollback safety)
- [ ] The function updates `_primary_runtime` if the change should persist across turns
- [ ] Error handling uses broad `except Exception` only around the new logic, not wrapping existing logic
- [ ] The modification is gated by a config flag for easy rollback

### 4. Verify no duplicate handling

Check that the same error condition isn't handled at multiple layers:

- `conversation_loop.py` top-of-loop guards
- `conversation_loop.py` error-classification fallback
- `chat_completion_helpers.py` `try_activate_fallback()`
- `agent_runtime_helpers.py` `switch_model()`

Each layer should have a clear, non-overlapping trigger condition.

**Concrete duplication pattern:** when you add a same-provider rotation check at two layers, layer 2 should guard against re-running if layer 1 already attempted it. The cheapest signal is `agent._fallback_index` or a local flag set in layer 1 before layer 2 runs — without it, a single failure may trigger the same Portal/Pricing query twice with no functional gain and extra latency.

### 5. Persistence audit

Determine if the change is temporary or permanent:

- `switch_model()` modifies `agent.model` in memory
- `_primary_runtime` is restored at the start of each new turn
- Only `_save_model_choice()` and `config.yaml` writes persist across sessions
- Runtime switches that don't call persistence functions are temporary

## Pitfalls

- **Don't modify auth.py** during runtime behavior changes — token refresh is sensitive
- **Don't assume `:free` suffix models exist** — verify against actual provider responses
- **Don't add new core tools** for provider-specific logic — use existing hooks and fallback chain
- **Beware of broad `except Exception`** — ensure they only wrap new logic, not swallow existing error paths
- **Rate limit handling is provider-specific** — Nous multiplexes upstream providers; a 429 may be upstream capacity, not account limit

## Verification

After modification:

1. `py_compile` all modified files
2. Trace the full call chain for success and failure paths
3. Confirm no duplicate handling across layers
4. Verify rollback via config flag works
5. Confirm no config persistence from runtime switches

## References

- `references/nous-portal-architecture.md` — Nous Portal auth, model selection, and fallback architecture
- `references/fallback-chain-mechanics.md` — How `_try_activate_fallback`, `_fallback_activated`, and `restore_primary_runtime` interact
