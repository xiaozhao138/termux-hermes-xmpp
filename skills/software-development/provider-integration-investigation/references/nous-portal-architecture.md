# Nous Portal Architecture

Investigation findings for Nous Portal provider integration in Hermes Agent.

## Provider Registration

**File:** `hermes_cli/auth.py:250-258`
```python
PROVIDER_REGISTRY["nous"] = {
    "auth_type": "oauth_device_code",
    "portal_base_url": "https://portal.nousresearch.com",
    "inference_base_url": "https://inference-api.nousresearch.com/v1",
    "client_id": "hermes-cli",
    "scope": "inference:invoke",
}
```

## Auth Flow

**File:** `hermes_cli/auth.py:8889-9027`
- Device code flow: POST `{portal}/api/oauth/device/code`
- User approves in browser
- Poll `{portal}/api/oauth/token` for access/refresh tokens
- Tokens stored in `~/.hermes/auth.json` under `providers.nous`

## Runtime Credential Resolution

**File:** `hermes_cli/auth.py:6288-6548`
- `resolve_nous_runtime_credentials()` ensures access_token is a valid inference JWT
- If expired or missing `inference:invoke` scope, refreshes via refresh_token
- Persists rotated tokens back to auth.json
- Supports shared state across profiles via `_write_shared_nous_state()`

## Free-Tier Detection

**File:** `hermes_cli/models.py:682-704`
```python
def is_nous_free_tier(account_info):
    paid_access = account_info.get("paid_service_access")
    if isinstance(paid_access, dict):
        allowed = paid_access.get("allowed")
        if isinstance(allowed, bool):
            return not allowed
    # Legacy fallback
    sub = account_info.get("subscription", {})
    charge = sub.get("monthly_charge")
    return float(charge) == 0 if charge is not None else False
```

**Cache:** `models.py:874-904` — 180s TTL in-memory cache

## Model List Generation

**File:** `hermes_cli/models.py:1843-1858`
```python
def get_curated_nous_model_ids():
    # Try remote catalog first
    remote = get_curated_nous_models()  # from model-catalog.json
    if remote:
        return list(remote)
    # Fallback to hardcoded list
    return list(_PROVIDER_MODELS.get("nous", []))
```

**Static curated list:** `hermes_cli/models.py:258-304`

## Dynamic Free Model Discovery

**File:** `hermes_cli/models.py:738-801`
- `union_with_portal_free_recommendations()` calls Portal `/api/nous/recommended-models`
- Extracts `freeRecommendedModels[]` and appends to curated list
- Synthesizes `$0` pricing for Portal-only free models

**Caching:** `models.py:927-989`
- In-memory: 600s TTL keyed by portal_base_url
- Disk: `~/.hermes/cache/nous_recommended_cache.json`
- On network failure, falls back to disk cache

## Runtime Free Model Check (NEW)

**File:** `hermes_cli/models.py:1136-1184`
```python
def get_current_nous_free_models(portal_base_url="", *, force_refresh=False):
    payload = fetch_nous_recommended_models(portal_base_url, force_refresh=force_refresh)
    free_block = payload.get("freeRecommendedModels")
    pricing = get_pricing_for_provider("nous", force_refresh=force_refresh)
    return [mid for mid in candidate_ids if _is_model_free(mid, pricing)]
```

## Rate Limit Handling

**File:** `agent/nous_rate_guard.py`
- `record_nous_rate_limit()` — writes to `~/.hermes/rate_limits/nous.json`
- `nous_rate_limit_remaining()` — checks cross-session breaker
- `is_genuine_nous_rate_limit()` — distinguishes account limit vs upstream capacity
- `clear_nous_rate_limit()` — clears on successful request

**Important:** Nous Portal multiplexes upstream providers (DeepSeek, Kimi, MiMo, Hermes). A 429 may be upstream capacity, not account limit.

## Fallback Behavior

**File:** `agent/conversation_loop.py:2629-2695`
- Top-of-loop Nous rate limit guard checks `nous_rate_limit_remaining()`
- If rate-limited, tries Nous free-tier rotation before fallback provider
- `agent/chat_completion_helpers.py:2409-2447` — `try_activate_fallback()` also checks free-tier rotation

**File:** `agent/agent_runtime_helpers.py:2508-2767`
- `switch_model()` snapshots all runtime fields before swap
- Rolls back on failure via `_restore_snapshot()`
- Updates `_primary_runtime` so change persists across turns

**File:** `agent/agent_runtime_helpers.py:1488-1720`
- `restore_primary_runtime()` restores `_primary_runtime` snapshot at turn start
- Resets `_fallback_index` if no fallback was activated
- Rebuilds client, credential pool, context compressor

## Key Insight

The Nous Portal uses a single OAuth token for all models. There is no credential pool rotation. Model switching within Nous is purely a runtime `agent.model` change — the same token works for all Nous models.
