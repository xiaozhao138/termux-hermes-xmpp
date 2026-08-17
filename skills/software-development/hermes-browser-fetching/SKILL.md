---
name: hermes-browser-fetching
description: Browser-first live page fetching for Hermes.
---

# Hermes Browser Fetching

Use this skill whenever the task involves opening a live webpage and reading its rendered content.

## Default rule

- For any task that requires accessing, reading, or fetching webpage content, **default to `~/bin/web-browser "<URL>"`**.
- Do not substitute RSS feeds, `curl`, or `wget` for browser-based page retrieval unless the user explicitly asks for those alternatives.
- If `~/bin/web-browser` fails, report the failure and its reason; do not silently switch to another method.

## Site-specific URL rules
- 华尔街日报中文网: use `https://cn.wsj.com/` only. Do not use `https://www.wsj.com/zh-Hans` or alternate homepage URLs unless the user explicitly requests a different path.

## Preferred workflow

1. Confirm the exact target URL the user wants.
2. Run `~/bin/web-browser "<URL>"`.
3. From the output, use:
   - `TITLE`
   - `URL`
   - `HTTP`
   - body text via `page.locator("body").inner_text(...)`
4. Summarize or extract the page content the user asked for.
5. If the page is blocked or returns an unexpected error, report the HTTP status and final URL instead of silently switching to another fetch method.

## When NOT to use this skill

- The user explicitly requests RSS, `curl`, `wget`, or a non-browser path.
- The page is known to be machine-readable API/JSON content without a browser requirement.

## Pitfalls

- Don't silently downgrade from browser to non-browser fetchers.
- Don't guess alternate homepage URLs when the user specified one; ask first.
- Report access failures honestly instead of retrying with forbidden methods.

## Verification

- `~/bin/web-browser` is the validated browser path in this environment.
- Treat its output as authoritative page state for the user's request.

## Notes

- When a site fails, report the exact HTTP status and final URL before considering next steps.
- Keep the URL choice aligned with the user's stated preference; do not switch to alternate homepage URLs silently.
