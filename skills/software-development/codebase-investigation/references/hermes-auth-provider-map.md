# Hermes Agent Auth/Provider Investigation Reference

Collected from a real investigation of NousResearch/Hermes-Agent.

## Provider Config Entry Points
- `hermes_cli/auth.py` `PROVIDER_REGISTRY`: auth_type, portal_base_url, inference_base_url, client_id, scope
- `hermes_cli/providers.py` `HERMES_OVERLAYS`: transport, auth_type, base_url_override, base_url_env_var
- `hermes_cli/models.py` `CANONICAL_PROVIDERS`: display slug, label, tui_desc
- `hermes_cli/provider_catalog.py` `provider_catalog()`: merges all three sources into one descriptor per provider

## Auth Flow Locations
- Nous Portal: `hermes_cli/auth.py:8889-9027` device code login; `:6288-6500+` runtime resolver
- xAI OAuth: `hermes_cli/auth.py:5064-5156` resolver; `:4923-5018` token refresh; `:4511-4546` state read; proxy adapter in `hermes_cli/proxy/adapters/xai.py`
- Qwen OAuth: `hermes_cli/auth.py:2642-2830` reads/writes `~/.qwen/oauth_creds.json`; does NOT launch OAuth itself

## Key Distinctions
- Nous: full device-code flow, Hermes-managed tokens, billing scope step-up support
- xAI: device-code + refresh_token, discovery-based token endpoint, multi-profile write-through
- Qwen: external credential reuse from Qwen CLI, no Hermes-side OAuth flow

## Dynamic Free Model Sources
- Nous Portal free models: `fetch_nous_recommended_models()` hits `{portal}/api/nous/recommended-models`
- `union_with_portal_free_recommendations()` appends Portal `freeRecommendedModels` to curated list
- Cache: in-process 10-min TTL + disk at `~/.hermes/cache/nous_recommended_cache.json`
- StepFun: no Portal integration; `stepfun/step-3.7-flash` is static in `_PROVIDER_MODELS`; `:free` variant only in tests/comments

## Implementation: Dynamic Free-Model Rotation
- New helper: `hermes_cli/models.py` `get_current_nous_free_models(portal_base_url, force_refresh)` — returns model IDs that are both Portal-recommended AND priced at $0
- New config: `hermes_cli/config_defaults.py` `dynamic_free_model_rotation: True` — feature flag
- `switch_model()` (`agent/agent_runtime_helpers.py`): when target is nous + free-tier, verify model is still free; rotate to first free model if not
- `conversation_loop.py`: before Nous rate-limit fallback to another provider, try Nous-internal free-model rotation first
- `chat_completion_helpers.py` `try_activate_fallback()`: when provider is nous and current model is no longer free, rotate to a free model before walking fallback chain
- Backup location for rollback: `.backup_dynamic_free_models/` in repo root

## Platform Adapter Discovery Caveat
- Authoritative evidence for "Hermes supports platform X" comes from:
  - `gateway/platforms/*.py`
  - `plugins/platforms/<x>/*`
  - `gateway/platform_registry.py` registrations / built-in `Platform` enum/home_channel handling in `gateway/config.py`
  - official docs mentioning platform setup
- A hit only in `tools/send_message_tool.py` is NOT proof of a full adapter; it can be a lightweight target-format compatibility shim.
- Authoritative negative result: no matches for `xmpp/XMPP/Jabber` in the above adapter sources, including platform docs, means there is no first-party XMPP platform support.
