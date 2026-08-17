"""
XMPP Platform Adapter for Hermes Agent.

Minimal plugin-based gateway adapter for XMPP/Jabber. Uses slixmpp when
available, otherwise falls back to aioxmpp. If neither dependency is
present, the platform stays disabled until one is installed.

Configuration via environment variables (preferred) or config.yaml::

    gateway:
      platforms:
        xmpp:
          enabled: true
          extra:
            jid: hermes@sky.959011.xyz
            password: secret
            server: sky.959011.xyz
            port: 5222
            use_tls: true
            allowed_jids: []
            max_message_length: 0

Env vars:
    XMPP_JID, XMPP_PASSWORD, XMPP_SERVER, XMPP_PORT, XMPP_USE_TLS,
    XMPP_ALLOWED_JIDS, XMPP_ALLOW_ALL_JIDS, XMPP_HOME_CHANNEL
"""

from __future__ import annotations

import asyncio
import logging
import os
import random
import re
import time
from typing import Any, Dict, List, Optional

from agent.secret_scope import UnscopedSecretError as _UnscopedSecretError
from agent.secret_scope import get_secret as _scoped_get_secret

logger = logging.getLogger(__name__)


def _get_scoped_secret(name: str, default: Optional[str] = None) -> Optional[str]:
    try:
        val = _scoped_get_secret(name, default)
    except _UnscopedSecretError:
        val = os.getenv(name)
    return val if val is not None else default


def _resolve_backend():
    try:
        import slixmpp  # noqa: F401
        return "slixmpp"
    except ImportError:
        pass
    try:
        import aioxmpp  # noqa: F401
        return "aioxmpp"
    except ImportError:
        pass
    return None


def _normalize_jid(jid: str) -> str:
    if jid is None:
        return ""
    if hasattr(jid, "bare"):
        return jid.bare
    jid = str(jid).strip()
    if not jid:
        return jid
    if "/" in jid:
        jid = jid.split("/", 1)[0]
    if jid.startswith("@"):
        jid = jid[1:]
    return jid


def _parse_jid_parts(jid: str) -> tuple[str, str]:
    jid = _normalize_jid(jid)
    if "@" in jid:
        node, _, domain = jid.partition("@")
        return node, domain
    return "", jid


# ---------------------------------------------------------------------------
# Lazy backend imports
# ---------------------------------------------------------------------------

if _resolve_backend() == "slixmpp":
    try:
        from slixmpp import ClientXMPP
        from slixmpp.exceptions import IqError, IqTimeout
        _SLIXMPP_AVAILABLE = True
    except Exception:  # pragma: no cover
        _SLIXMPP_AVAILABLE = False
else:
    _SLIXMPP_AVAILABLE = False

if _resolve_backend() == "aioxmpp":
    try:
        import aioxmpp  # noqa: F401
        import aioxmpp.roster  # noqa: F401
        _AIXXMPP_AVAILABLE = True
    except Exception:  # pragma: no cover
        _AIXXMPP_AVAILABLE = False
else:
    _AIXXMPP_AVAILABLE = False

# ---------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------

from gateway.platforms.base import (  # noqa: E402
    BasePlatformAdapter,
    MessageEvent,
    MessageType,
    SendResult,
)
from gateway.config import Platform  # noqa: E402


class XMPPAdapter(BasePlatformAdapter):
    def __init__(self, config, **kwargs):
        platform = Platform("xmpp")
        super().__init__(config=config, platform=platform)

        extra = getattr(config, "extra", {}) or {}

        self.jid = os.getenv("XMPP_JID") or extra.get("jid", "")
        self.password = _get_scoped_secret("XMPP_PASSWORD") or extra.get("password", "")
        self.server = os.getenv("XMPP_SERVER") or extra.get("server", "")
        try:
            self.port = int(os.getenv("XMPP_PORT") or extra.get("port", 5222))
        except (TypeError, ValueError):
            self.port = 5222
        self.use_tls = (
            os.getenv("XMPP_USE_TLS", "").lower() in {"1", "true", "yes"}
            if os.getenv("XMPP_USE_TLS")
            else bool(extra.get("use_tls", True))
        )

        allowed = os.getenv("XMPP_ALLOWED_JIDS") or extra.get("allowed_jids", "")
        if isinstance(allowed, list):
            self.allowed_jids = { _normalize_jid(x) for x in allowed if isinstance(x, str)}
        else:
            self.allowed_jids = { _normalize_jid(x.strip()) for x in str(allowed).split(",") if x.strip()}
        self.allow_all = (
            os.getenv("XMPP_ALLOW_ALL_JIDS", "").lower() in {"1", "true", "yes"}
            if os.getenv("XMPP_ALLOW_ALL_JIDS")
            else bool(extra.get("allow_all", False))
        )

        self._own_bare_jid = _normalize_jid(self.jid)
        self._backend = _resolve_backend()
        self._client = None
        self._running = False
        self._connect_task: Optional[asyncio.Task] = None
        self._recv_task: Optional[asyncio.Task] = None
        self._stop_event = asyncio.Event()
        self._connected_event = asyncio.Event()

    @property
    def name(self) -> str:
        return "XMPP"

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        if not self.jid or not self.password:
            logger.error("XMPP: jid/password missing")
            self._set_fatal_error("config_missing", "XMPP_JID and XMPP_PASSWORD must be set", retryable=False)
            return False

        if not self._backend:
            logger.error("XMPP: no backend available. Install slixmpp or aioxmpp.")
            self._set_fatal_error("missing_backend", "Install slixmpp or aioxmpp", retryable=False)
            return False

        if self._backend == "slixmpp" and not _SLIXMPP_AVAILABLE:
            self._set_fatal_error("missing_backend", "slixmpp is not installed", retryable=False)
            return False
        if self._backend == "aioxmpp" and not _AIXXMPP_AVAILABLE:
            self._set_fatal_error("missing_backend", "aioxmpp is not installed", retryable=False)
            return False

        if self._connect_task and not self._connect_task.done():
            return False

        self._connect_task = asyncio.create_task(self._connect_loop())
        return True

    async def _connect_loop(self) -> None:
        attempt = 0
        while not self._stop_event.is_set():
            try:
                ok = await self._connect_once()
                if ok:
                    self._connected_event.set()
                    return
            except Exception as exc:
                logger.warning("XMPP: connect attempt %s failed: %s", attempt, exc)

            attempt += 1
            backoff = min(60.0, (2 ** attempt) + random.uniform(0, 1.0))
            if self._stop_event.is_set():
                break
            try:
                await asyncio.wait_for(self._stop_event.wait(), timeout=backoff)
            except asyncio.TimeoutError:
                continue

        self._connected_event.clear()

    async def _connect_once(self) -> bool:
        if self._backend == "slixmpp":
            return await self._connect_slixmpp()
        return await self._connect_aioxmpp()

    async def _connect_slixmpp(self) -> bool:
        from slixmpp import ClientXMPP

        jid = self.jid if "@" in self.jid else f"{self.jid}@{self._guess_server()}"
        self._client = ClientXMPP(jid, self.password)

        self._client.add_event_handler("session_start", self._on_slix_session_start)
        self._client.add_event_handler("message", self._on_slix_message)
        self._client.add_event_handler("disconnected", self._on_slix_disconnected)

        host = self.server or self._guess_server()
        port = self.port
        connect_future = self._client.connect(host=host, port=port)
        try:
            await asyncio.wait_for(connect_future, timeout=30.0)
        except asyncio.TimeoutError:
            logger.error("XMPP: connect timeout to %s:%s", host, port)
            self._set_fatal_error("connect_timeout", "connect timeout", retryable=True)
            return False

        # slixmpp 1.17+: run the XML/filter loop so stream features, auth,
        # bind, and session_start can actually process. The connect() future
        # only covers TCP/socket bring-up.
        self._filter_task = asyncio.create_task(self._client.run_filters())

        # Wait until either session_start marks us online, or the transport
        # disconnects, or we time out.
        session_done = asyncio.Event()

        def _on_start(_event):
            session_done.set()

        def _on_disconnect(_event):
            session_done.set()

        self._client.add_event_handler("session_start", _on_start)
        self._client.add_event_handler("disconnected", _on_disconnect)
        try:
            await asyncio.wait_for(session_done.wait(), timeout=30.0)
        except asyncio.TimeoutError:
            logger.error("XMPP: session_start timeout to %s:%s", host, port)
            self._set_fatal_error("session_timeout", "session_start timeout", retryable=True)
            return False
        finally:
            self._client.del_event_handler("session_start", _on_start)
            self._client.del_event_handler("disconnected", _on_disconnect)

        if not getattr(self._client, "authenticated", False):
            logger.error("XMPP: auth failed for %s", jid)
            self._set_fatal_error("auth_failed", "auth failed", retryable=True)
            return False

        self._mark_connected()
        logger.info("XMPP: connected as %s", jid)
        self._filter_task = asyncio.create_task(self._client.run_filters())
        return True

    def _on_slix_session_start(self, _event):
        try:
            self._client.send_presence()
            self._client.get_roster()
        except Exception as exc:
            logger.debug("XMPP: session start probe failed: %s", exc)

    def _on_slix_disconnected(self, _event):
        if self.is_connected:
            logger.warning("XMPP: disconnected")
            self._set_fatal_error("disconnected", "xmpp disconnected", retryable=True)
            asyncio.create_task(self._notify_fatal_error())

    def _on_slix_message(self, msg):
        if msg["type"] in ("chat", "normal"):
            from_jid = _normalize_jid(msg["from"])
            body = msg["body"]
            if not body:
                return
            if from_jid == self._own_bare_jid:
                return
            if not self._authorized(from_jid):
                logger.debug("XMPP: ignoring unauthorized %s", from_jid)
                return
            chat_id = from_jid
            asyncio.create_task(self._dispatch(text=body, chat_id=chat_id, user_id=from_jid, user_name=from_jid))

    async def _connect_aioxmpp(self) -> bool:
        logger.error("XMPP: aioxmpp backend is not implemented in this plugin yet.")
        self._set_fatal_error("unsupported_backend", "aioxmpp backend missing", retryable=False)
        return False

    async def disconnect(self) -> None:
        self._stop_event.set()
        self._connected_event.clear()
        self._mark_disconnected()
        client = getattr(self, "_client", None)
        if client is not None:
            try:
                if hasattr(client, "disconnect"):
                    client.disconnect()
            except Exception:
                pass
        if self._connect_task and not self._connect_task.done():
            self._connect_task.cancel()
            try:
                await self._connect_task
            except asyncio.CancelledError:
                pass
        filter_task = getattr(self, "_filter_task", None)
        if filter_task is not None and not filter_task.done():
            filter_task.cancel()
            try:
                await filter_task
            except asyncio.CancelledError:
                pass
        self._client = None

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        if not self.is_connected or self._client is None:
            return SendResult(success=False, error="Not connected")

        chat_id = _normalize_jid(chat_id)
        if self._backend != "slixmpp":
            return SendResult(success=False, error="send not supported for current backend")

        try:
            self._client.send_message(
                mto=chat_id,
                mbody=content,
                mtype="chat",
            )
        except Exception as exc:
            logger.error("XMPP: send failed: %s", exc)
            return SendResult(success=False, error=str(exc))

        return SendResult(success=True, message_id=str(int(time.time() * 1000)))

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        return None

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        jid = _normalize_jid(chat_id)
        return {"name": jid, "type": "dm"}

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _guess_server(self) -> str:
        if self.server:
            return self.server
        _, domain = _parse_jid_parts(self.jid)
        return domain

    def _authorized(self, bare_jid: str) -> bool:
        if self.allow_all:
            return True
        if not self.allowed_jids:
            return True
        return bare_jid in self.allowed_jids

    async def _dispatch(self, *, text: str, chat_id: str, user_id: str, user_name: str) -> None:
        if not self._message_handler:
            return
        source = self.build_source(
            chat_id=chat_id,
            chat_name=chat_id,
            chat_type="dm",
            user_id=user_id,
            user_name=user_name,
        )
        event = MessageEvent(
            text=text,
            message_type=MessageType.TEXT,
            source=source,
            message_id=str(int(time.time() * 1000)),
        )
        await self.handle_message(event)


# ---------------------------------------------------------------------------
# Plugin registration
# ---------------------------------------------------------------------------

def check_requirements() -> bool:
    return _resolve_backend() is not None


def validate_config(config) -> bool:
    extra = getattr(config, "extra", {}) or {}
    jid = os.getenv("XMPP_JID") or extra.get("jid", "")
    password = _get_scoped_secret("XMPP_PASSWORD") or extra.get("password", "")
    return bool(jid and password)


def interactive_setup() -> None:
    from hermes_cli.setup import (
        prompt,
        prompt_yes_no,
        save_env_value,
        get_env_value,
        print_header,
        print_info,
        print_warning,
        print_success,
    )

    print_header("XMPP/Jabber")
    existing_jid = get_env_value("XMPP_JID")
    if existing_jid:
        print_info(f"XMPP: already configured (jid: {existing_jid})")
        if not prompt_yes_no("Reconfigure XMPP?", False):
            return

    print_info("Connect Hermes to an XMPP/Jabber account.")
    print()

    jid = prompt("XMPP JID (e.g. hermes@sky.959011.xyz)", default=existing_jid or "")
    if not jid:
        print_warning("JID is required — skipping XMPP setup")
        return
    save_env_value("XMPP_JID", jid.strip())

    password = prompt("XMPP password", password=True)
    if password:
        save_env_value("XMPP_PASSWORD", password)
    else:
        print_warning("Password is required for XMPP login")
        return

    node, domain = _parse_jid_parts(jid)
    server_default = domain
    server = prompt("XMPP server host", default=get_env_value("XMPP_SERVER") or server_default)
    if server:
        save_env_value("XMPP_SERVER", server.strip())

    port_default = get_env_value("XMPP_PORT") or "5222"
    port = prompt("XMPP port", default=port_default)
    if port:
        try:
            save_env_value("XMPP_PORT", str(int(port)))
        except ValueError:
            print_warning(f"Invalid port — using {port_default}")
            save_env_value("XMPP_PORT", port_default)

    use_tls = prompt_yes_no("Use TLS?", True)
    save_env_value("XMPP_USE_TLS", "true" if use_tls else "false")

    print_info("Access control: restrict who can message the bot")
    allow_all = prompt_yes_no("Allow anyone to talk to the bot?", False)
    if allow_all:
        save_env_value("XMPP_ALLOW_ALL_JIDS", "true")
        save_env_value("XMPP_ALLOWED_JIDS", "")
        print_warning("Open access — any JID can command the bot.")
    else:
        save_env_value("XMPP_ALLOW_ALL_JIDS", "false")
        allowed = prompt("Allowed JIDs (comma-separated, leave empty to deny everyone)", default=get_env_value("XMPP_ALLOWED_JIDS") or "")
        if allowed:
            save_env_value("XMPP_ALLOWED_JIDS", allowed.replace(" ", ""))
            print_success("Allowlist configured")
        else:
            save_env_value("XMPP_ALLOWED_JIDS", "")
            print_info("No JIDs allowed — the bot will ignore all messages until you add JIDs.")

    print()
    print_success("XMPP configuration saved to ~/.hermes/.env")
    print_info("Install dependency: pip install slixmpp")
    print_info("Restart the gateway: hermes gateway restart")


def is_connected(config) -> bool:
    extra = getattr(config, "extra", {}) or {}
    jid = os.getenv("XMPP_JID") or extra.get("jid", "")
    password = _get_scoped_secret("XMPP_PASSWORD") or extra.get("password", "")
    return bool(jid and password)


def _env_enablement() -> dict | None:
    jid = os.getenv("XMPP_JID", "").strip()
    password = _get_scoped_secret("XMPP_PASSWORD")
    if not jid or not password:
        return None

    seed: dict = {"jid": jid}
    server = os.getenv("XMPP_SERVER", "").strip()
    if not server:
        _, domain = _parse_jid_parts(jid)
        if domain:
            server = domain
    if server:
        seed["server"] = server
    port = os.getenv("XMPP_PORT", "").strip()
    if port:
        try:
            seed["port"] = int(port)
        except ValueError:
            pass
    use_tls = os.getenv("XMPP_USE_TLS", "").strip().lower()
    if use_tls:
        seed["use_tls"] = use_tls in {"1", "true", "yes"}
    if _get_scoped_secret("XMPP_PASSWORD"):
        seed["password"] = _get_scoped_secret("XMPP_PASSWORD")
    allowed = os.getenv("XMPP_ALLOWED_JIDS", "").strip()
    if allowed:
        seed["allowed_jids"] = [part.strip() for part in allowed.split(",") if part.strip()]
    allow_all = os.getenv("XMPP_ALLOW_ALL_JIDS", "").strip().lower()
    if allow_all:
        seed["allow_all"] = allow_all in {"1", "true", "yes"}
    home = os.getenv("XMPP_HOME_CHANNEL", "").strip() or jid
    if home:
        seed["home_channel"] = {"chat_id": home, "name": os.getenv("XMPP_HOME_CHANNEL_NAME", home)}
    return seed


def register(ctx):
    ctx.register_platform(
        name="xmpp",
        label="XMPP",
        adapter_factory=lambda cfg: XMPPAdapter(cfg),
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=["XMPP_JID", "XMPP_PASSWORD"],
        install_hint="pip install slixmpp",
        setup_fn=interactive_setup,
        env_enablement_fn=_env_enablement,
        cron_deliver_env_var="XMPP_HOME_CHANNEL",
        standalone_sender_fn=None,
        allowed_users_env="XMPP_ALLOWED_JIDS",
        allow_all_env="XMPP_ALLOW_ALL_JIDS",
        max_message_length=0,
        emoji="💬",
        pii_safe=True,
        allow_update_command=True,
        platform_hint=(
            "You are chatting via XMPP/Jabber. "
            "Keep responses concise. "
            "Plain text is safest across clients; if formatting helps, "
            "use minimal markdown that the user's client may render."
        ),
    )
