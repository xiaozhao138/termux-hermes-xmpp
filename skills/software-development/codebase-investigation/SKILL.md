---
name: codebase-investigation
description: "Investigate codebases with file/line evidence."
---

# Codebase Investigation

## Trigger
Use when asked to analyze a codebase, locate definitions/auth/config paths, or determine whether something is static or dynamic with evidence.

## Methodology

### 1. Orient
- Identify project root and entry points: README, pyproject.toml, package.json, setup.py, cli.py, run_agent.py
- Note languages, frameworks, build system, and scale
- Check contributor/architecture docs for intended structure

### 2. Search before reading
- Run `search_files` with targeted patterns first; do not read large files blindly
- Prefer `files_only` to narrow candidates, then `content` mode for exact line numbers
- Batch independent searches in parallel (config, auth, models, endpoints)
- Treat god-files (>10k lines) as search targets, not read targets

### 3. Trace by concern
For "where is X configured / authenticated / defined":
- **Registry**: constants dict, dataclass registry, ProviderConfig, HermesOverlay
- **Implementation**: functions, classes, methods performing the action
- **Runtime resolver**: how credentials/values are loaded and refreshed
- **Adapter/plugin**: boundary object wiring internals to external services

For auth flows, expect: `PROVIDER_REGISTRY -> login/device_code/refresh -> resolve_*_runtime_credentials -> UpstreamAdapter`

### 4. Distinguish static vs dynamic
- **Static**: hardcoded lists, constants, literals in source files
- **Dynamic**: network fetch, disk cache, computed from other state
- Check both production code and tests; test fixtures often contain example values that mimic production
- Look for cache files, API URLs, and endpoint paths to confirm dynamic sources
- Trace the runtime path: is the value used directly, or fetched/transformed first?

### 5. Report with evidence
- Every claim must include a file path and approximate line number
- Include a brief code quote when it adds clarity
- Distinguish "Defined in", "Fetched from", "Referenced in/called by", "Only found in tests"
- If a search returns nothing, say so explicitly; do not guess

### 6. Respect investigation constraints
- If user says "do not modify files", do not write to the project
- Avoid side-effect commands (git checkout, delete, overwrite)
- Save findings to a report file only if explicitly asked
- Prefer read-only tools: `search_files`, `read_file`, read-only `terminal` commands

## Pitfalls
- Large single-file modules often contain multiple subsystems; search within them rather than reading whole
- Auth implementations frequently span 4+ locations: constants, login flow, token refresh, runtime resolver, proxy adapter
- "Free tier" or catalog features often live in API response shapes, not static code
- Provider aliases and canonical slugs may differ from underlying provider IDs; trace normalization chain
- Disk caches and background refresh threads can mask whether a feature is truly static or dynamic
- Test fixtures frequently contain example model IDs or strings that mimic production but do not exist in live code paths; always verify production paths separately
- When assessing "can we implement automatic behavior X on failure/rate-limit", first map the existing retry/fallback/refresh infrastructure — the missing piece is often just the runtime query + same-provider switch, not the entire mechanism
- For feasibility + implementation requests, produce a change plan with file paths, line numbers, impact analysis, backup/rollback strategy, and a feature flag before making any modifications
