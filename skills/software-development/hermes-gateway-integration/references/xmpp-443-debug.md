# XMPP 443 Endpoint Debug Notes

## Observed Behavior
- `sky.959011.xyz:443` accepts TCP and TLS handshake.
- Plain HTTP probes get Cloudflare `400 The plain HTTP request was sent to HTTPS port`.
- Common WebSocket upgrade paths fail with `did not receive a valid HTTP response` or Cloudflare `400`.
- Raw XMPP stream open after TLS returns `invalid-namespace` unless a proper XML stream header is used.
- Proper `<stream:stream ...>` XML header over TLS returns normal `stream:features` including `SCRAM-SHA-1`, `PLAIN`, etc.

## Verified Paths
- Successful: direct TLS C2S on 443 with raw `<stream:stream>` open after TLS.
- Failed: WebSocket upgrade paths on `/ws`, `/websocket`, `/xmpp`, `/ws/xmpp`, `/ws-xmpp`, `/xmpp-websocket` with `xmpp`/`xmpp-websocket` subprotocols.

## Session-Specific
- Tested on Termux Android with Python 3.13 + `websockets` and `slixmpp 1.17.0`.
- Server appears behind Cloudflare on 443, but allows direct XMPP stream framing after TLS.
