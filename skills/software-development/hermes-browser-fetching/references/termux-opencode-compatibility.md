# Termux/PRoot OpenCode Compatibility Notes

## Environment pattern
- Termux/PRoot Ubuntu environments can expose `opencode-ai` binaries.
- `process.platform` often reports `android` inside PRoot/Termux, even though the runtime is Ubuntu Linux.

## npm install failure mode
- `opencode-ai@1.18.18` optionalDependencies include `opencode-linux-arm64`, so Linux ARM64 is officially supported.
- `npm install -g opencode-ai` fails with:
  - `EBADPLATFORM`
  - `Unsupported platform for opencode-ai@1.18.18: wanted {"os":"darwin,linux,win32","cpu":"arm64,x64"} (current: {"os":"android","cpu":"arm64"})`

## Existing runtime fallback
- A preinstalled `/data/data/com.termux/files/usr/lib/opencode/runtime/opencode` binary may exist.
- Verify with `/data/data/com.termux/files/usr/lib/opencode/runtime/opencode --version`.
- Do not treat this as evidence that `npm install -g opencode-ai` works.

## Rule
- If `npm install -g opencode-ai` returns `EBADPLATFORM` because `process.platform` is `android`, stop and report the exact cause instead of retrying or substituting unrelated install methods.
