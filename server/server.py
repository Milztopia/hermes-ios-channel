"""
Hermes iOS Channel Server
- Manages chat metadata in SQLite
- Proxies API calls to the local Hermes API server
- Exposes the HTTP/SSE routes used by the native iOS app
"""
import sqlite3
import os
import json
import uuid
import time
import asyncio
import logging
import httpx
import hmac
import tempfile
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse, FileResponse

logger = logging.getLogger("hermes-ios-interface")


def _load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


_load_env_file(Path(__file__).with_name(".env"))

# Config
API_SERVER_URL = os.getenv("HERMES_API_URL", "http://127.0.0.1:8642")
API_SERVER_KEY = os.getenv("HERMES_API_KEY", os.getenv("API_SERVER_KEY", "")).strip()
INTERFACE_KEY = os.getenv(
    "HERMES_INTERFACE_KEY",
    os.getenv("HERMES_WEB_UI_KEY", API_SERVER_KEY),
).strip()
_default_db = str(Path(__file__).parent.parent / "data" / "chats.db")
DB_PATH = os.getenv("HERMES_INTERFACE_DB", os.getenv("HERMES_WEB_DB", _default_db))
# Canonical conversation store shared with the Hermes gateway and the official
# desktop app. The interface server reads it (via hermes_state.SessionDB) so the
# iOS app shows the same live transcript any client produced — including
# turns added in the official app. See _session_db()/get_messages()/list_chats().
STATE_DB_PATH = os.getenv("HERMES_STATE_DB", str(Path.home() / ".hermes" / "state.db"))
# Session sources to surface in the chat list. Empty = all (mirror the official
# app). Set e.g. HERMES_INTERFACE_SOURCES="api_server" to hide telegram/cron/cli.
_sources_env = os.getenv("HERMES_INTERFACE_SOURCES", os.getenv("HERMES_WEB_SOURCES", ""))
_INTERFACE_SOURCES = {s.strip() for s in _sources_env.split(",") if s.strip()}
# This public channel does not configure alternate model/media providers.
# Hermes owns provider keys, model routing, TTS, tools, and image capability.

MAX_TTS_JSON_BYTES = 128 * 1024
MAX_TRANSCRIBE_BYTES = 25 * 1024 * 1024
MAX_PDF_BYTES = 25 * 1024 * 1024
MAX_IMAGE_JSON_BYTES = 12 * 1024 * 1024
MAX_PROXY_BODY_BYTES = 50 * 1024 * 1024

GENERATED_IMAGES_DIR = Path(__file__).parent.parent / "data" / "generated-images"

os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)


_INTERNAL_MESSAGE_MARKERS = ("[VOICE_MODE]", "[WEB_SEARCH_REQUIRED]")


def _strip_internal_message_markers(text) -> str:
    cleaned = str(text or "").strip()
    stripped = True
    while stripped:
        stripped = False
        for marker in _INTERNAL_MESSAGE_MARKERS:
            if cleaned.startswith(marker):
                cleaned = cleaned[len(marker):].strip()
                stripped = True
                break
    return cleaned


def _is_placeholder_chat_title(title: str) -> bool:
    cleaned = _strip_internal_message_markers(title).strip().lower()
    return cleaned in ("", "new chat", "deleted chat", "untitled chat")


# ── Link-preview (source cards) ──────────────────────────────────────────
# GET /api/link-preview?url=… fetches a page and returns OG metadata so the
# client can render source cards under web-search answers. Because this makes
# the server fetch a client-supplied URL, it is an SSRF sink — and this host
# also runs Firecrawl, the gateway, and SearXNG on localhost. So every hop is
# validated: http/https only, and the resolved IP must be globally routable
# (rejects loopback / private / link-local / reserved). Redirects are followed
# manually, re-validating each Location.
import re as _re
import socket as _socket
import ipaddress as _ipaddress
from urllib.parse import urlparse as _urlparse, urlunparse as _urlunparse, parse_qsl as _parse_qsl, urlencode as _urlencode

_LINK_PREVIEW_TTL = 60 * 60 * 24          # 24h
_LINK_PREVIEW_MAX_BYTES = 512 * 1024      # only need <head>; cap the read
_LINK_PREVIEW_MAX_REDIRECTS = 4
_LINK_PREVIEW_CACHE: dict = {}            # normalized_url -> (expires_at, payload)
_TRACKING_PARAMS = ("utm_", "fbclid", "gclid", "mc_eid", "mc_cid", "igshid", "ref_")


def _normalize_url(raw: str) -> str:
    """Canonicalize for cache keying: drop fragment + tracking params, lowercase
    host, strip a bare trailing slash. Best-effort — returns input on parse fail."""
    try:
        p = _urlparse(raw)
        host = (p.hostname or "").lower()
        netloc = host
        if p.port:
            netloc = f"{host}:{p.port}"
        query = [(k, v) for k, v in _parse_qsl(p.query, keep_blank_values=True)
                 if not any(k.lower().startswith(t) for t in _TRACKING_PARAMS)]
        path = p.path
        if path.endswith("/") and path != "/":
            path = path.rstrip("/")
        return _urlunparse((p.scheme.lower(), netloc, path, "", _urlencode(query), ""))
    except Exception:
        return raw


async def _resolve_is_public(host: str) -> bool:
    """True only if every resolved address for *host* is globally routable.
    Blocks loopback/private/link-local/reserved (SSRF guard)."""
    if not host:
        return False
    # A literal IP still has to clear the same bar.
    try:
        return _ipaddress.ip_address(host).is_global
    except ValueError:
        pass
    try:
        infos = await asyncio.get_running_loop().getaddrinfo(
            host, None, proto=_socket.IPPROTO_TCP
        )
    except (_socket.gaierror, UnicodeError, OSError):
        return False
    if not infos:
        return False
    for info in infos:
        ip = info[4][0]
        try:
            if not _ipaddress.ip_address(ip).is_global:
                return False
        except ValueError:
            return False
    return True


_META_RE = _re.compile(rb"<meta\b[^>]*>", _re.IGNORECASE)
_LINK_RE = _re.compile(rb"<link\b[^>]*>", _re.IGNORECASE)
_TITLE_RE = _re.compile(rb"<title[^>]*>(.*?)</title>", _re.IGNORECASE | _re.DOTALL)


def _parse_og_tags(html_bytes: bytes) -> dict:
    """Pull OG/Twitter/title metadata out of raw HTML head. Regex-based to avoid
    a parser dependency — OG meta tags are flat and well-behaved."""
    import html as _html
    head = html_bytes.split(b"</head>", 1)[0]

    def _attr(tag: bytes, name: str) -> str:
        m = _re.search(
            rb'%s\s*=\s*(["\'])(.*?)\1' % _re.escape(name.encode()),
            tag, _re.IGNORECASE | _re.DOTALL,
        )
        return m.group(2).decode("utf-8", "replace").strip() if m else ""

    props: dict = {}
    for tag in _META_RE.findall(head):
        key = (_attr(tag, "property") or _attr(tag, "name")).lower()
        if not key:
            continue
        content = _attr(tag, "content")
        if content and key not in props:
            props[key] = _html.unescape(content)

    def pick(*keys):
        for k in keys:
            if props.get(k):
                return props[k]
        return ""

    title = pick("og:title", "twitter:title")
    if not title:
        tm = _TITLE_RE.search(head)
        if tm:
            title = _html.unescape(tm.group(1).decode("utf-8", "replace").strip())

    # Favicon: first <link rel="...icon..."> href, preferring apple-touch (larger).
    favicon = ""
    apple_icon = ""
    for tag in _LINK_RE.findall(head):
        rel = _attr(tag, "rel").lower()
        if "icon" not in rel:
            continue
        href = _attr(tag, "href")
        if not href:
            continue
        if "apple-touch" in rel and not apple_icon:
            apple_icon = _html.unescape(href)
        elif not favicon:
            favicon = _html.unescape(href)

    return {
        "title": title,
        "image": pick("og:image", "og:image:url", "twitter:image", "twitter:image:src"),
        "siteName": pick("og:site_name", "application-name"),
        "date": pick("article:published_time", "article:modified_time", "og:updated_time"),
        "description": pick("og:description", "twitter:description", "description"),
        "favicon": apple_icon or favicon,
    }

# ── Canonical session store (state.db) bridge ────────────────────────────────
# The interface server runs in the hermes-agent venv, so it can reuse SessionDB —
# the exact reader the official desktop app uses. One lazily-created singleton
# (SessionDB is thread-safe: one writer, many readers). If the import/open ever
# fails, every helper degrades to chats.db-only behavior
# before, so the apps never break — they just stop seeing externally-added turns.
_session_db_singleton = None
_session_db_unavailable = False


def _session_db():
    global _session_db_singleton, _session_db_unavailable
    if _session_db_unavailable:
        return None
    if _session_db_singleton is not None:
        return _session_db_singleton
    try:
        from hermes_state import SessionDB
        _session_db_singleton = SessionDB(Path(STATE_DB_PATH))
        return _session_db_singleton
    except Exception as e:
        _session_db_unavailable = True
        logger.warning("state.db unavailable (%s); chat history limited to chats.db", e)
        return None


def _iso(ts) -> str:
    """Epoch seconds (float) -> ISO8601 with milliseconds + Z, matching the
    timestamps clients already persist (e.g. 2026-05-23T11:42:35.480Z)."""
    if not ts:
        return ""
    dt = datetime.fromtimestamp(float(ts), tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def _statedb_msg_to_ui(m: dict):
    """Convert one state.db message row (from SessionDB.get_messages) into the
    client ChatMessage shape the iOS app renders. Returns None for rows that have no
    user-visible rendering (empty assistant tool-call shells, system rows)."""
    role = m.get("role")
    mid = f"st-{m.get('id')}"
    created = _iso(m.get("timestamp"))
    content = m.get("content")
    if isinstance(content, list):  # multimodal parts — keep text only
        content = "\n".join(
            str(p.get("text", "")) for p in content
            if isinstance(p, dict) and p.get("type") == "text"
        ).strip()
    if role == "user":
        if not content:
            return None
        return {"id": mid, "type": "user", "content": content, "createdAt": created}
    if role == "assistant":
        if content and content.strip():
            return {"id": mid, "type": "assistant", "content": content,
                    "createdAt": created, "status": "completed"}
        return None  # assistant message that only carried tool_calls
    if role == "tool":
        name = m.get("tool_name") or "tool"
        return {"id": mid, "type": "tool_event", "createdAt": created,
                "tool": {"tool": name, "preview": (content or "")[:80], "completed": True}}
    return None


def _message_text(m: dict) -> str:
    content = m.get("content")
    if isinstance(content, list):
        content = "\n".join(
            str(p.get("text", "")) for p in content
            if isinstance(p, dict) and p.get("type") == "text"
        ).strip()
    return _strip_internal_message_markers(content)


def _first_visible_session_text(db, session_id: str) -> str:
    try:
        for msg in db.get_messages(session_id):
            if msg.get("role") in ("user", "assistant"):
                text = _message_text(msg)
                if text:
                    return text
    except Exception as e:
        logger.warning("failed to derive session preview for %s: %s", session_id, e)
    return ""


def _append_external_tail(ui_messages: list, canonical_rows: list) -> list:
    """Return the chats.db messages, plus any conversation tail that exists in
    state.db but not yet in chats.db (turns added by the official app / another
    client). The client-rendered chats.db messages are preserved as-is (they keep
    image/source/file cards); only the missing tail is appended from state.db.

    The conversation is linear and append-only, so we align on the count of
    user/assistant messages: skip the canonical rows the chats.db copy already
    covers, then append the rest. When chats.db already covers everything (or
    leads, e.g. an optimistic local save), nothing is appended.
    """
    ui_ua = sum(1 for d in ui_messages if d.get("type") in ("user", "assistant"))
    seen = 0
    start = len(canonical_rows)
    for i, m in enumerate(canonical_rows):
        if m.get("role") in ("user", "assistant"):
            seen += 1
            if seen == ui_ua + 1:
                start = i
                break
    tail = (_statedb_msg_to_ui(m) for m in canonical_rows[start:])
    return ui_messages + [c for c in tail if c]


def _synth_chat_from_session(s: dict) -> dict:
    """Build a chat-list entry for a state.db session that has no ui_chats row
    (e.g. a conversation started in the official Hermes app / CLI). Shaped like
    a ui_chats row so the clients decode it identically."""
    sid = s["id"]
    preview = _strip_internal_message_markers(s.get("preview"))
    title = (_strip_internal_message_markers(s.get("title")) or preview[:48] or "Untitled chat")
    started = _iso(s.get("started_at"))
    updated = _iso(s.get("last_active") or s.get("started_at"))
    return {
        "id": sid,
        "hermes_session_id": sid,
        "hermes_session_key": f"ios:{sid}",
        "title": title,
        "pinned": 0,
        "archived": 1 if s.get("archived") else 0,
        "created_at": started,
        "updated_at": updated,
        "last_message_preview": preview[:100],
        "project_id": None,
        "model_provider": None,
        "model_id": None,
    }


def _trash_row_to_chat(row: dict) -> dict:
    title = _strip_internal_message_markers(row.get("title"))
    preview = _strip_internal_message_markers(row.get("last_message_preview"))
    if _is_placeholder_chat_title(title):
        seed = _session_chat_seed(row.get("hermes_session_id") or row.get("chat_id"))
        if seed:
            seed_title = _strip_internal_message_markers(seed.get("title"))
            seed_preview = _strip_internal_message_markers(seed.get("last_message_preview"))
            if not _is_placeholder_chat_title(seed_title):
                title = seed_title
            if not preview and seed_preview:
                preview = seed_preview
    if _is_placeholder_chat_title(title) and preview:
        title = preview[:48]
    return {
        "id": row.get("chat_id"),
        "hermes_session_id": row.get("hermes_session_id"),
        "hermes_session_key": f"ios:{row.get('chat_id')}",
        "title": title or "Deleted chat",
        "pinned": 0,
        "archived": 0,
        "created_at": row.get("created_at") or row.get("deleted_at") or "",
        "updated_at": row.get("updated_at") or row.get("deleted_at") or "",
        "last_message_preview": preview or "",
        "project_id": None,
        "model_provider": None,
        "model_id": None,
        "deleted_at": row.get("deleted_at") or "",
    }


def _session_chat_seed(chat_id: str) -> dict | None:
    db = _session_db()
    if db is None:
        return None
    try:
        sid = db.resolve_session_id(chat_id)
        sess = db.get_session(sid) if sid else None
        if not sess:
            return None
        sess["id"] = sid
        seed = _synth_chat_from_session(sess)
        if _is_placeholder_chat_title(seed.get("title")) or not seed.get("last_message_preview"):
            text = _first_visible_session_text(db, sid)
            if text:
                if _is_placeholder_chat_title(seed.get("title")):
                    seed["title"] = text[:48]
                if not seed.get("last_message_preview"):
                    seed["last_message_preview"] = text[:100]
        return seed
    except Exception as e:
        logger.warning("failed to seed chat %s from state.db: %s", chat_id, e)
        return None


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS ui_projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            color TEXT NOT NULL DEFAULT 'blue',
            created_at TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS ui_chats (
            id TEXT PRIMARY KEY,
            hermes_session_id TEXT,
            hermes_session_key TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            archived INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            last_message_preview TEXT NOT NULL DEFAULT '',
            project_id TEXT REFERENCES ui_projects(id) ON DELETE SET NULL,
            model_provider TEXT,
            model_id TEXT
        )
    """)
    cols = [r[1] for r in conn.execute("PRAGMA table_info(ui_chats)").fetchall()]
    if 'project_id' not in cols:
        conn.execute("ALTER TABLE ui_chats ADD COLUMN project_id TEXT REFERENCES ui_projects(id) ON DELETE SET NULL")
    if 'model_provider' not in cols:
        conn.execute("ALTER TABLE ui_chats ADD COLUMN model_provider TEXT")
    if 'model_id' not in cols:
        conn.execute("ALTER TABLE ui_chats ADD COLUMN model_id TEXT")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS ui_messages (
            id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL,
            type TEXT NOT NULL,
            created_at TEXT NOT NULL,
            data TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS ui_deleted_chats (
            chat_id TEXT PRIMARY KEY,
            hermes_session_id TEXT,
            title TEXT NOT NULL DEFAULT 'Deleted chat',
            created_at TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL DEFAULT '',
            last_message_preview TEXT NOT NULL DEFAULT '',
            deleted_at TEXT NOT NULL
        )
    """)
    deleted_cols = [r[1] for r in conn.execute("PRAGMA table_info(ui_deleted_chats)").fetchall()]
    if 'title' not in deleted_cols:
        conn.execute("ALTER TABLE ui_deleted_chats ADD COLUMN title TEXT NOT NULL DEFAULT 'Deleted chat'")
    if 'created_at' not in deleted_cols:
        conn.execute("ALTER TABLE ui_deleted_chats ADD COLUMN created_at TEXT NOT NULL DEFAULT ''")
    if 'updated_at' not in deleted_cols:
        conn.execute("ALTER TABLE ui_deleted_chats ADD COLUMN updated_at TEXT NOT NULL DEFAULT ''")
    if 'last_message_preview' not in deleted_cols:
        conn.execute("ALTER TABLE ui_deleted_chats ADD COLUMN last_message_preview TEXT NOT NULL DEFAULT ''")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS ui_shares (
            token TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL,
            title TEXT NOT NULL,
            messages TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
    """)
    conn.commit()
    return conn


def init_db():
    conn = get_db()
    conn.close()


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield


app = FastAPI(lifespan=lifespan)


def _client_is_loopback(request: Request) -> bool:
    host = request.client.host if request.client else ""
    try:
        return _ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host in ("localhost", "")


def _bearer_token(request: Request) -> str:
    auth = request.headers.get("authorization", "")
    scheme, _, token = auth.partition(" ")
    if scheme.lower() != "bearer":
        return ""
    return token.strip()


def _hermes_headers(client_bearer: str = "") -> dict:
    token = (API_SERVER_KEY or client_bearer or "").strip()
    return {"Authorization": f"Bearer {token}"} if token else {}


def _authorized(request: Request) -> bool:
    if not INTERFACE_KEY:
        return _client_is_loopback(request)
    return hmac.compare_digest(_bearer_token(request), INTERFACE_KEY)


@app.middleware("http")
async def require_api_auth(request: Request, call_next):
    path = request.url.path
    if path in ("/health", "/api/health") or request.method == "OPTIONS":
        return await call_next(request)
    if path.startswith("/api/") and not _authorized(request):
        if not INTERFACE_KEY:
            return JSONResponse(
                {"detail": "HERMES_INTERFACE_KEY required for remote API access"},
                status_code=503,
            )
        return JSONResponse({"detail": "Unauthorized"}, status_code=401)
    return await call_next(request)


async def read_limited_body(request: Request, max_bytes: int) -> bytes:
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            if int(content_length) > max_bytes:
                raise HTTPException(status_code=413, detail="Request body too large")
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid Content-Length")
    chunks = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > max_bytes:
            raise HTTPException(status_code=413, detail="Request body too large")
        chunks.append(chunk)
    return b"".join(chunks)


async def read_limited_json_value(request: Request, max_bytes: int):
    raw = await read_limited_body(request, max_bytes)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Invalid JSON body")


async def read_limited_json(request: Request, max_bytes: int) -> dict:
    parsed = await read_limited_json_value(request, max_bytes)
    if parsed is None:
        return {}
    if not isinstance(parsed, dict):
        raise HTTPException(status_code=400, detail="Expected JSON object")
    return parsed


@app.get("/health")
@app.get("/api/health")
async def health():
    return {"status": "ok", "platform": "hermes-ios-interface"}


_HERMES_LOG_DIR = os.getenv("HERMES_LOG_DIR", "")
_HERMES_CONFIG_PATH = os.getenv("HERMES_CONFIG_PATH", str(Path.home() / ".hermes" / "config.yaml"))
_HERMES_ENV_PATH = os.getenv("HERMES_ENV_PATH", str(Path.home() / ".hermes" / ".env"))
_HERMES_GATEWAY_SERVICE = os.getenv("HERMES_GATEWAY_SERVICE", "")
_default_voice_inventory_path = str(Path(__file__).parent.parent / "data" / "voice-inventory.json")
_VOICE_INVENTORY_PATH = os.getenv("HERMES_VOICE_INVENTORY_PATH", _default_voice_inventory_path)
MAX_TTS_OUTPUT_BYTES = 25 * 1024 * 1024


@app.get("/api/debug/logs")
async def debug_logs(n: int = 300):
    import glob
    from fastapi.responses import PlainTextResponse
    if not _HERMES_LOG_DIR:
        raise HTTPException(status_code=404, detail="HERMES_LOG_DIR not configured")
    log_dir = Path(_HERMES_LOG_DIR)
    logs = sorted(glob.glob(str(log_dir / "*.log")), reverse=True)
    if not logs:
        return PlainTextResponse("No log files found")
    with open(logs[0]) as f:
        lines = f.readlines()
    return PlainTextResponse("".join(lines[-n:]))


@app.get("/api/debug/hermes-config")
async def get_hermes_config():
    return _load_hermes_config()


def _load_hermes_env_keys(keys: set[str]) -> dict[str, str]:
    env_path = Path(_HERMES_ENV_PATH).expanduser()
    found = {key: os.getenv(key, "") for key in keys if os.getenv(key)}
    if not env_path.exists():
        return found
    for raw in env_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key in keys and key not in found:
            found[key] = value.strip().strip('"').strip("'")
    return found


_MODEL_PROVIDER_ID_PREFIX = "hermes-provider://"


def _encode_inventory_model(provider: str, model: str) -> str:
    from urllib.parse import quote

    return f"{_MODEL_PROVIDER_ID_PREFIX}{quote(provider, safe='')}/{quote(model, safe='')}"


def _decode_inventory_model(model_id: str) -> tuple[str, str] | None:
    from urllib.parse import unquote

    raw = str(model_id or "").strip()
    if not raw.startswith(_MODEL_PROVIDER_ID_PREFIX):
        return None
    rest = raw[len(_MODEL_PROVIDER_ID_PREFIX):]
    if "/" not in rest:
        return None
    provider, model = rest.split("/", 1)
    provider = unquote(provider).strip()
    model = unquote(model).strip()
    if not provider or not model:
        return None
    return provider, model


def _provider_spec(config: dict, provider: str) -> dict:
    providers = config.get("providers") if isinstance(config.get("providers"), dict) else {}
    spec = providers.get(provider) if isinstance(providers, dict) else None
    return spec if isinstance(spec, dict) else {}


def _model_ref_from_selection(config: dict, provider: str = "", model_id: str = "") -> dict:
    provider = str(provider or "").strip()
    model_id = str(model_id or "").strip()
    decoded = _decode_inventory_model(model_id)
    if decoded:
        provider, model_id = decoded
    else:
        model_config = config.get("model") if isinstance(config.get("model"), dict) else {}
        alias_spec = _alias_spec_for_model(config, model_id)
        if isinstance(alias_spec, dict):
            provider = str(provider or alias_spec.get("provider") or model_config.get("provider") or "").strip()
            model_id = str(alias_spec.get("model") or model_id).strip()
        elif model_id == str(model_config.get("default") or "").strip():
            provider = str(provider or model_config.get("provider") or "").strip()
    spec = _provider_spec(config, provider)
    base_url = str(spec.get("api") or spec.get("base_url") or "").strip()
    api_mode = str(spec.get("transport") or spec.get("api_mode") or "").strip()
    return {
        "provider": provider,
        "model": model_id,
        "base_url": base_url,
        "api_mode": api_mode,
    }


def _normalize_run_model_body(raw: bytes, content_type: str) -> bytes:
    if "application/json" not in content_type.lower():
        return raw
    try:
        body = json.loads(raw.decode("utf-8"))
    except Exception:
        return raw
    if not isinstance(body, dict):
        return raw
    try:
        config = _load_hermes_config(required=True)
    except Exception:
        return raw
    selected_provider = str(body.get("provider") or body.get("model_provider") or "").strip()
    selected_model = str(body.get("model") or "").strip()
    ref = _model_ref_from_selection(config, selected_provider, selected_model)
    if not ref.get("model"):
        return raw
    body["model"] = ref["model"]
    if ref.get("provider"):
        body["provider"] = ref["provider"]
    if ref.get("base_url"):
        body["base_url"] = ref["base_url"]
    if ref.get("api_mode"):
        body["api_mode"] = ref["api_mode"]
    return json.dumps(body, separators=(",", ":")).encode("utf-8")


def _hermes_models_from_config(config: dict) -> dict:
    model_config = config.get("model") if isinstance(config.get("model"), dict) else {}
    aliases = config.get("model_aliases") if isinstance(config.get("model_aliases"), dict) else {}
    default_model = str(model_config.get("default") or "").strip()
    models: list[dict] = []
    seen: set[str] = set()

    def add_model(model_id: str, name: str | None = None):
        mid = str(model_id or "").strip()
        if not mid or mid in seen or any(kw in mid.lower() for kw in _MODEL_SKIP_KEYWORDS):
            return
        seen.add(mid)
        models.append({"id": mid, "name": name or mid})

    add_model(default_model, f"Default ({default_model})" if default_model else None)
    for alias, spec in aliases.items():
        if not isinstance(spec, dict):
            continue
        target = str(spec.get("model") or "").strip()
        label = f"{alias} ({target})" if target and target != alias else str(alias)
        add_model(str(alias), label)
    default_id = default_model or (models[0]["id"] if models else "")
    provider = str(model_config.get("provider") or "").strip()
    providers = []
    if models:
        providers.append({
            "id": provider or "hermes",
            "name": provider or "Hermes",
            "models": models,
            "defaultModel": default_id,
            "authenticated": True,
        })
    return {
        "models": models,
        "default": default_id,
        "defaultProvider": provider,
        "providers": providers,
    }


def _alias_spec_for_model(config: dict, model_id: str) -> dict | None:
    aliases = config.get("model_aliases") if isinstance(config.get("model_aliases"), dict) else {}
    if not isinstance(aliases, dict):
        return None
    direct = aliases.get(model_id)
    if isinstance(direct, dict):
        return direct
    wanted = str(model_id or "").strip()
    for spec in aliases.values():
        if isinstance(spec, dict) and str(spec.get("model") or "").strip() == wanted:
            return spec
    return None


def _save_configured_model_assignment(provider: str, model: str, base_url: str = "") -> dict:
    import yaml

    config = _load_hermes_config(required=True)
    model_cfg = config.get("model") if isinstance(config.get("model"), dict) else {}
    model_cfg = dict(model_cfg)
    provider_spec = {}
    providers = config.get("providers") if isinstance(config.get("providers"), dict) else {}
    if isinstance(providers, dict):
        provider_spec = providers.get(provider) if isinstance(providers.get(provider), dict) else {}

    model_cfg["provider"] = provider
    model_cfg["default"] = model
    resolved_base_url = str(base_url or provider_spec.get("api") or "").strip()
    if resolved_base_url:
        model_cfg["base_url"] = resolved_base_url
    else:
        model_cfg.pop("base_url", None)
    model_cfg.pop("context_length", None)
    config["model"] = model_cfg

    cfg_path = _hermes_config_path()
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    with open(cfg_path, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    return {
        "ok": True,
        "scope": "main",
        "provider": provider,
        "model": model,
        "base_url": model_cfg.get("base_url", ""),
    }


def _hermes_models_from_inventory(config: dict) -> dict:
    """Return Hermes' authenticated brain inventory for the iOS picker.

    The official desktop picker is backed by hermes_cli.inventory rather than
    the narrower config.yaml model_aliases list. The iOS channel keeps its old
    alias entries, then adds provider-scoped inventory IDs that /api/model/activate
    can translate back into Hermes' normal model assignment.
    """
    from hermes_cli.inventory import build_models_payload, load_picker_context

    response = _hermes_models_from_config(config)
    models = list(response.get("models", []))
    seen = {str(m.get("id") or "") for m in models if isinstance(m, dict)}
    current_provider = ""
    current_model = str(response.get("default") or "").strip()
    model_config = config.get("model") if isinstance(config.get("model"), dict) else {}
    if isinstance(model_config, dict):
        current_provider = str(model_config.get("provider") or "").strip()
        current_model = str(model_config.get("default") or current_model).strip()
    alias_targets: dict[str, str] = {}
    aliases = config.get("model_aliases") if isinstance(config.get("model_aliases"), dict) else {}
    if isinstance(aliases, dict):
        for spec in aliases.values():
            if not isinstance(spec, dict):
                continue
            target = str(spec.get("model") or "").strip()
            provider = str(spec.get("provider") or "").strip()
            if target and provider:
                alias_targets[target] = provider

    payload = build_models_payload(
        load_picker_context(),
        include_unconfigured=False,
        picker_hints=True,
        canonical_order=True,
        pricing=False,
        capabilities=True,
        refresh=False,
    )

    default_id = response.get("default", "")
    default_provider = response.get("defaultProvider", "")
    grouped: list[dict] = []
    existing_by_provider: dict[str, dict] = {}
    for provider_entry in response.get("providers", []):
        if isinstance(provider_entry, dict):
            pid = str(provider_entry.get("id") or "").strip()
            if pid:
                copied = dict(provider_entry)
                copied["models"] = list(provider_entry.get("models") or [])
                grouped.append(copied)
                existing_by_provider[pid] = copied
    providers = payload.get("providers") if isinstance(payload, dict) else []
    if not isinstance(providers, list):
        return response

    for provider_info in providers:
        if not isinstance(provider_info, dict):
            continue
        if provider_info.get("authenticated") is False:
            continue
        provider = str(provider_info.get("slug") or "").strip()
        provider_name = str(provider_info.get("name") or provider).strip()
        provider_models = provider_info.get("models")
        if not provider or not isinstance(provider_models, list):
            continue
        group = existing_by_provider.get(provider)
        if group is None:
            group = {
                "id": provider,
                "name": provider_name or provider,
                "models": [],
                "authenticated": bool(provider_info.get("authenticated", True)),
                "defaultModel": "",
            }
            grouped.append(group)
            existing_by_provider[provider] = group
        for model in provider_models:
            model_name = str(model or "").strip()
            if not model_name or any(kw in model_name.lower() for kw in _MODEL_SKIP_KEYWORDS):
                continue
            alias_provider = alias_targets.get(model_name)
            if alias_provider and alias_provider != provider:
                continue
            model_id = _encode_inventory_model(provider, model_name)
            if model_id in seen:
                continue
            seen.add(model_id)
            label = f"{provider_name}: {model_name}" if provider_name else model_name
            flat_entry = {"id": model_id, "name": label, "provider": provider}
            models.append(flat_entry)
            group["models"].append({"id": model_id, "name": model_name})
            if provider == current_provider and model_name == current_model:
                default_id = model_id
                default_provider = provider
                group["defaultModel"] = model_id

    for group in grouped:
        if not group.get("defaultModel") and group.get("models"):
            group["defaultModel"] = group["models"][0]["id"]

    return {
        "models": models,
        "default": default_id or (models[0]["id"] if models else ""),
        "defaultProvider": default_provider,
        "providers": grouped,
    }


def _pretty_voice_id(voice_id: str) -> str:
    return voice_id.replace("-", " ").replace("_", " ").title()


def _infer_voice_env(command: str) -> str:
    matches = _re.findall(r"(?:^|\s)([A-Za-z_][A-Za-z0-9_]*VOICE[A-Za-z0-9_]*)=", command or "")
    return matches[0] if matches else ""


def _command_voice_from_spec(spec: dict | None) -> str:
    if not isinstance(spec, dict):
        return ""
    explicit = str(spec.get("default_voice") or spec.get("voice") or spec.get("voice_id") or "").strip()
    if explicit:
        return explicit
    voice_env = str(spec.get("voice_env") or "").strip()
    command = str(spec.get("command") or "")
    if not voice_env:
        voice_env = _infer_voice_env(command)
    if not voice_env:
        return ""
    match = _re.search(rf"(?:^|\s){_re.escape(voice_env)}=([A-Za-z0-9_-]+)", command)
    return match.group(1) if match else ""


def _provider_display_name(provider_id: str, spec: dict | None) -> str:
    if isinstance(spec, dict):
        configured = str(spec.get("name") or spec.get("label") or "").strip()
        if configured:
            return configured
    return provider_id.replace("-", " ").replace("_", " ").title()


def _voice_name(provider_id: str, spec: dict | None) -> str:
    display_name = _provider_display_name(provider_id, spec)
    default_voice = _command_voice_from_spec(spec)
    if default_voice:
        return f"{display_name} Default ({_pretty_voice_id(default_voice)})"
    if provider_id == "edge":
        voice = (spec or {}).get("voice") if isinstance(spec, dict) else ""
        return f"Edge TTS ({voice})" if voice else "Edge TTS"
    if provider_id == "elevenlabs":
        voice_id = (spec or {}).get("voice_id") if isinstance(spec, dict) else ""
        return f"ElevenLabs ({voice_id})" if voice_id else "ElevenLabs"
    return display_name


def _configured_voice_entries(spec: dict | None) -> list[dict]:
    if not isinstance(spec, dict):
        return []
    raw = (
        spec.get("voices")
        or spec.get("ios_voices")
        or spec.get("voice_options")
        or spec.get("voice_ids")
    )
    entries: list[dict] = []
    if isinstance(raw, dict):
        iterable = [{"id": key, "name": value} for key, value in raw.items()]
    elif isinstance(raw, list):
        iterable = raw
    else:
        iterable = []
    for item in iterable:
        if isinstance(item, str):
            voice_id = item.strip()
            name = _pretty_voice_id(voice_id)
        elif isinstance(item, dict):
            voice_id = str(
                item.get("id")
                or item.get("voice")
                or item.get("voice_id")
                or item.get("value")
                or ""
            ).strip()
            name = str(item.get("name") or item.get("label") or _pretty_voice_id(voice_id)).strip()
        else:
            continue
        if voice_id:
            entries.append({"id": voice_id, "name": name or _pretty_voice_id(voice_id)})
    return entries


_VOICE_METADATA_KEYS = {
    "name",
    "label",
    "voice_env",
    "voices",
    "ios_voices",
    "voice_options",
    "voice_ids",
    "voices_url",
    "voices_command",
    "voices_timeout",
}


def _load_channel_voice_inventory() -> dict:
    path = Path(_VOICE_INVENTORY_PATH).expanduser()
    if not path.exists():
        return {}
    try:
        raw = path.read_text(encoding="utf-8")
        if path.suffix.lower() in {".yaml", ".yml"}:
            import yaml
            data = yaml.safe_load(raw)
        else:
            data = json.loads(raw)
    except Exception as e:
        logger.warning("Channel voice inventory failed to load: %s", e)
        return {}
    if not isinstance(data, dict):
        return {}
    providers = data.get("providers", data)
    return providers if isinstance(providers, dict) else {}


def _voice_metadata_spec(provider_id: str, spec: dict | None) -> dict:
    base = dict(spec or {}) if isinstance(spec, dict) else {}
    overlay = _load_channel_voice_inventory().get(str(provider_id))
    if not isinstance(overlay, dict):
        return base
    for key in _VOICE_METADATA_KEYS:
        if key in overlay:
            base[key] = overlay[key]
    return base


def _parse_voice_inventory_payload(payload) -> list[dict]:
    if isinstance(payload, dict):
        payload = payload.get("voices") or payload.get("voice_options") or payload.get("voice_ids") or []
    if not isinstance(payload, list):
        return []
    return _configured_voice_entries({"voices": payload})


def _helper_voice_entries(spec: dict | None) -> list[dict]:
    if not isinstance(spec, dict):
        return []
    timeout = min(max(float(spec.get("voices_timeout") or 3), 0.5), 10.0)
    voices_url = str(spec.get("voices_url") or "").strip()
    if voices_url:
        try:
            response = httpx.get(voices_url, timeout=timeout)
            response.raise_for_status()
            return _parse_voice_inventory_payload(response.json())
        except Exception as e:
            logger.warning("TTS voices_url failed: %s", e)
            return []

    voices_command = str(spec.get("voices_command") or "").strip()
    if voices_command:
        try:
            proc = subprocess.run(
                voices_command,
                shell=True,
                check=True,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            return _parse_voice_inventory_payload(json.loads(proc.stdout or "[]"))
        except Exception as e:
            logger.warning("TTS voices_command failed: %s", e)
            return []
    return []


def _provider_voice_entries(spec: dict | None) -> list[dict]:
    entries: list[dict] = []
    seen: set[str] = set()
    for voice in _configured_voice_entries(spec) + _helper_voice_entries(spec):
        voice_id = voice["id"]
        if voice_id in seen:
            continue
        seen.add(voice_id)
        entries.append(voice)
    return entries


def _hermes_voices_from_config(config: dict) -> dict:
    tts = config.get("tts") if isinstance(config.get("tts"), dict) else {}
    default_voice = str(tts.get("provider") or "").strip()
    provider_specs = tts.get("providers") if isinstance(tts.get("providers"), dict) else {}
    env_keys = _load_hermes_env_keys({"ELEVENLABS_API_KEY"})
    voices: list[dict] = []
    seen: set[str] = set()

    def add_voice(
        provider_id: str,
        spec: dict | None,
        supported: bool,
        reason: str = "",
        name: str | None = None,
        provider: str | None = None,
        voice_id: str | None = None,
    ):
        vid = str(provider_id or "").strip()
        if not vid or vid in seen:
            return
        seen.add(vid)
        entry = {
            "id": vid,
            "name": name or _voice_name(vid, spec),
            "supported": supported,
        }
        if provider:
            entry["provider"] = provider
        if voice_id:
            entry["voiceId"] = voice_id
        if reason:
            entry["reason"] = reason
        voices.append(entry)

    for provider_id, spec in provider_specs.items():
        provider = spec if isinstance(spec, dict) else {}
        voice_meta = _voice_metadata_spec(str(provider_id), provider)
        command = str(provider.get("command") or "").strip()
        supported = str(provider.get("type") or "").strip() == "command" and bool(command)
        add_voice(
            str(provider_id),
            voice_meta,
            supported,
            "" if supported else "not currently supported by this app",
            provider=str(provider_id),
        )
        if supported:
            display_name = _provider_display_name(str(provider_id), voice_meta)
            voice_env = str(voice_meta.get("voice_env") or "").strip() or _infer_voice_env(command)
            for configured_voice in _provider_voice_entries(voice_meta):
                voice_id = configured_voice["id"]
                supports_variant = bool(voice_env)
                add_voice(
                    f"{provider_id}:{voice_id}",
                    voice_meta,
                    supports_variant,
                    "" if supports_variant else "provider does not expose a voice override",
                    name=f"{display_name}: {configured_voice['name']}",
                    provider=str(provider_id),
                    voice_id=voice_id,
                )

    if isinstance(tts.get("edge"), dict):
        edge = _voice_metadata_spec("edge", tts.get("edge"))
        add_voice("edge", edge, True, provider="edge")
        for configured_voice in _provider_voice_entries(edge):
            voice_id = configured_voice["id"]
            add_voice(
                f"edge:{voice_id}",
                edge,
                True,
                name=f"Edge TTS: {configured_voice['name']}",
                provider="edge",
                voice_id=voice_id,
            )
    if isinstance(tts.get("elevenlabs"), dict):
        eleven = _voice_metadata_spec("elevenlabs", tts.get("elevenlabs"))
        has_key = bool(env_keys.get("ELEVENLABS_API_KEY"))
        has_voice = bool(str(eleven.get("voice_id") or "").strip()) if isinstance(eleven, dict) else False
        add_voice(
            "elevenlabs",
            eleven,
            has_key and has_voice,
            "" if has_key and has_voice else ("no API key configured" if not has_key else "no voice_id configured"),
            provider="elevenlabs",
        )
        for configured_voice in _provider_voice_entries(eleven):
            voice_id = configured_voice["id"]
            add_voice(
                f"elevenlabs:{voice_id}",
                eleven,
                has_key,
                "" if has_key else "no API key configured",
                name=f"ElevenLabs: {configured_voice['name']}",
                provider="elevenlabs",
                voice_id=voice_id,
            )

    if default_voice and default_voice not in seen:
        add_voice(default_voice, None, False, "not currently supported by this app")

    return {"default": default_voice, "voices": voices}


@app.patch("/api/debug/hermes-config")
async def patch_hermes_config(request: Request):
    import yaml, subprocess
    if not _HERMES_CONFIG_PATH:
        raise HTTPException(status_code=404, detail="HERMES_CONFIG_PATH not configured")
    body = await read_limited_json(request, MAX_TTS_JSON_BYTES)
    config_path = Path(_HERMES_CONFIG_PATH)
    if not config_path.exists():
        raise HTTPException(status_code=404, detail="Config file not found")
    with open(config_path) as f:
        config = yaml.safe_load(f)
    def deep_merge(base, override):
        for k, v in override.items():
            if isinstance(v, dict) and isinstance(base.get(k), dict):
                deep_merge(base[k], v)
            else:
                base[k] = v
    deep_merge(config, body)
    with open(config_path, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
    if _HERMES_GATEWAY_SERVICE:
        subprocess.Popen(
            ["bash", "-c", f"sleep 2 && systemctl --user restart {_HERMES_GATEWAY_SERVICE}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True
        )
    return {"updated": body, "restart": "scheduled" if _HERMES_GATEWAY_SERVICE else "skipped"}


# --- Chat metadata endpoints ---

@app.get("/api/chats")
async def list_chats(request: Request):
    include_archived = request.query_params.get("include_archived", "false") == "true"
    updated_within_days = request.query_params.get("updated_within_days")
    conn = get_db()
    try:
        ui_rows = [dict(r) for r in conn.execute("SELECT * FROM ui_chats").fetchall()]
        deleted_rows = [dict(r) for r in conn.execute("SELECT * FROM ui_deleted_chats").fetchall()]
    finally:
        conn.close()
    deleted_chat_ids = {r["chat_id"] for r in deleted_rows if r.get("chat_id")}
    deleted_session_ids = {r["hermes_session_id"] for r in deleted_rows if r.get("hermes_session_id")}

    # Start from every ui_chats row (preserve iOS chats + their metadata).
    by_id = {
        r["id"]: r
        for r in ui_rows
        if r["id"] not in deleted_chat_ids and r.get("hermes_session_id") not in deleted_session_ids
    }
    sid_to_id = {
        r["hermes_session_id"]: r["id"]
        for r in ui_rows
        if r.get("hermes_session_id")
        and r["id"] not in deleted_chat_ids
        and r["hermes_session_id"] not in deleted_session_ids
    }

    # Merge in sessions from state.db so conversations from the official app /
    # other clients appear too, and existing iOS chats get their latest activity.
    db = _session_db()
    if db is not None:
        try:
            sessions = db.list_sessions_rich(
                limit=5000, min_message_count=1,
                include_archived=include_archived,
                order_by_last_active=True,
            )
        except Exception as e:
            logger.warning("list_sessions_rich failed: %s", e)
            sessions = []
        for s in sessions:
            if _INTERFACE_SOURCES and s.get("source") not in _INTERFACE_SOURCES:
                continue
            if s["id"] in deleted_session_ids or s["id"] in deleted_chat_ids:
                continue
            chat_id = sid_to_id.get(s["id"])
            if chat_id:  # existing iOS chat: refresh activity/preview from state.db
                c = by_id[chat_id]
                c["updated_at"] = _iso(s.get("last_active") or s.get("started_at")) or c.get("updated_at", "")
                if not c.get("last_message_preview"):
                    c["last_message_preview"] = (s.get("preview") or "")[:100]
            else:  # official-app / CLI / other-origin conversation
                by_id[s["id"]] = _synth_chat_from_session(s)

    rows = list(by_id.values())
    if not include_archived:
        rows = [c for c in rows if not c.get("archived")]
    for c in rows:
        c["title"] = _strip_internal_message_markers(c.get("title"))
        c["last_message_preview"] = _strip_internal_message_markers(c.get("last_message_preview"))
    if updated_within_days:
        try:
            days = max(0, int(updated_within_days))
            cutoff = datetime.now(timezone.utc) - timedelta(days=days)
            cutoff_iso = cutoff.strftime("%Y-%m-%dT%H:%M:%S.") + f"{cutoff.microsecond // 1000:03d}Z"
            rows = [c for c in rows if (c.get("updated_at") or "") >= cutoff_iso]
        except ValueError:
            raise HTTPException(status_code=400, detail="updated_within_days must be an integer")
    rows.sort(key=lambda c: (int(c.get("pinned") or 0), c.get("updated_at") or ""), reverse=True)
    return rows


@app.post("/api/chats")
async def create_chat(request: Request):
    body = await read_limited_json(request, MAX_TTS_JSON_BYTES)
    chat_id = body.get("id") or f"chat_{int(time.time()*1000)}_{uuid.uuid4().hex[:8]}"
    session_key = body.get("hermesSessionKey") or f"ios:{chat_id}"
    model_provider = str(body.get("model_provider") or body.get("modelProvider") or "").strip()
    model_id = str(body.get("model_id") or body.get("modelId") or "").strip()
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    conn = get_db()
    try:
        conn.execute("DELETE FROM ui_deleted_chats WHERE chat_id = ?", (chat_id,))
        conn.execute(
            "INSERT OR IGNORE INTO ui_chats (id, hermes_session_key, title, created_at, updated_at, model_provider, model_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (chat_id, session_key, "New chat", now, now, model_provider or None, model_id or None),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM ui_chats WHERE id = ?", (chat_id,)).fetchone()
        return dict(row)
    finally:
        conn.close()


@app.get("/api/trash")
async def list_trash():
    conn = get_db()
    try:
        rows = [dict(r) for r in conn.execute(
            "SELECT * FROM ui_deleted_chats ORDER BY deleted_at DESC"
        ).fetchall()]
        return [_trash_row_to_chat(r) for r in rows]
    finally:
        conn.close()


@app.post("/api/chats/{chat_id}/restore")
async def restore_chat(chat_id: str):
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT * FROM ui_deleted_chats WHERE chat_id = ?", (chat_id,)
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Chat is not in Trash")

        trash = dict(row)
        hermes_session_id = trash.get("hermes_session_id") or chat_id
        seed = _session_chat_seed(hermes_session_id) or _trash_row_to_chat(trash)
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        conn.execute("DELETE FROM ui_deleted_chats WHERE chat_id = ?", (chat_id,))
        conn.execute(
            """
            INSERT OR IGNORE INTO ui_chats
            (id, hermes_session_id, hermes_session_key, title, created_at, updated_at, last_message_preview)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                chat_id,
                hermes_session_id,
                f"ios:{chat_id}",
                seed.get("title") or "Restored chat",
                seed.get("created_at") or now,
                seed.get("updated_at") or now,
                seed.get("last_message_preview") or "",
            ),
        )
        conn.commit()
        restored = conn.execute("SELECT * FROM ui_chats WHERE id = ?", (chat_id,)).fetchone()
        return dict(restored) if restored is not None else seed
    finally:
        conn.close()


@app.delete("/api/trash")
async def empty_trash():
    conn = get_db()
    try:
        rows = [dict(r) for r in conn.execute("SELECT * FROM ui_deleted_chats").fetchall()]
        db = _session_db()
        hermes_deleted = 0
        for row in rows:
            chat_id = row.get("chat_id")
            hermes_session_id = row.get("hermes_session_id")
            if chat_id:
                conn.execute("DELETE FROM ui_chats WHERE id = ?", (chat_id,))
                conn.execute("DELETE FROM ui_messages WHERE chat_id = ?", (chat_id,))
            if db is not None and hermes_session_id:
                try:
                    if db.delete_session(hermes_session_id):
                        hermes_deleted += 1
                except Exception as e:
                    logger.warning("failed to permanently delete Hermes session %s: %s", hermes_session_id, e)
        conn.execute("DELETE FROM ui_deleted_chats")
        conn.commit()
        return {"deleted": len(rows), "hermes_deleted": hermes_deleted}
    finally:
        conn.close()


@app.patch("/api/chats/{chat_id}")
async def update_chat(chat_id: str, request: Request):
    body = await read_limited_json(request, MAX_TTS_JSON_BYTES)
    fields = []
    values = []
    if "title" in body:
        fields.append("title = ?")
        values.append(body["title"])
    if "pinned" in body:
        fields.append("pinned = ?")
        values.append(1 if body["pinned"] else 0)
    if "archived" in body:
        fields.append("archived = ?")
        values.append(1 if body["archived"] else 0)
    if "hermes_session_id" in body:
        fields.append("hermes_session_id = ?")
        values.append(body["hermes_session_id"])
    if "project_id" in body:
        fields.append("project_id = ?")
        values.append(body["project_id"])
    if "model_provider" in body or "modelProvider" in body:
        fields.append("model_provider = ?")
        values.append((body.get("model_provider") if "model_provider" in body else body.get("modelProvider")) or None)
    if "model_id" in body or "modelId" in body:
        fields.append("model_id = ?")
        values.append((body.get("model_id") if "model_id" in body else body.get("modelId")) or None)
    if not fields:
        return {"error": "No fields to update"}
    conn = get_db()
    try:
        # A chat surfaced from state.db (official-app / CLI origin) has no
        # ui_chats row until the user first pins/renames/archives it. Materialize
        # an overlay row seeded from its session so the edit has somewhere to land.
        if conn.execute("SELECT 1 FROM ui_chats WHERE id = ?", (chat_id,)).fetchone() is None:
            db = _session_db()
            seed_title = "New chat"
            if db is not None:
                try:
                    sid = db.resolve_session_id(chat_id)
                    sess = db.get_session(sid) if sid else None
                    if sess and sess.get("title"):
                        seed_title = sess["title"]
                except Exception:
                    pass
            now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            conn.execute(
                "INSERT OR IGNORE INTO ui_chats (id, hermes_session_id, hermes_session_key, title, created_at, updated_at, model_provider, model_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (chat_id, chat_id, f"ios:{chat_id}", seed_title, now, now, None, None),
            )
        conn.execute(f"UPDATE ui_chats SET {', '.join(fields)}, updated_at = ? WHERE id = ?",
                     values + [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), chat_id])
        conn.commit()
        row = conn.execute("SELECT * FROM ui_chats WHERE id = ?", (chat_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Chat not found")
        return dict(row)
    finally:
        conn.close()


@app.delete("/api/chats/{chat_id}")
async def delete_chat(chat_id: str):
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT * FROM ui_chats WHERE id = ?", (chat_id,)
        ).fetchone()
        chat = dict(row) if row else (_session_chat_seed(chat_id) or {})
        hermes_session_id = chat.get("hermes_session_id") or chat_id
        seed = _session_chat_seed(hermes_session_id) or {}
        title = _strip_internal_message_markers(chat.get("title"))
        preview = _strip_internal_message_markers(chat.get("last_message_preview"))
        if _is_placeholder_chat_title(title):
            seed_title = _strip_internal_message_markers(seed.get("title"))
            if not _is_placeholder_chat_title(seed_title):
                title = seed_title
        if not preview:
            preview = _strip_internal_message_markers(seed.get("last_message_preview"))
        if _is_placeholder_chat_title(title) and preview:
            title = preview[:48]
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        conn.execute("DELETE FROM ui_chats WHERE id = ?", (chat_id,))
        conn.execute("DELETE FROM ui_messages WHERE chat_id = ?", (chat_id,))
        conn.execute(
            """
            INSERT OR REPLACE INTO ui_deleted_chats
            (chat_id, hermes_session_id, title, created_at, updated_at, last_message_preview, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                chat_id,
                hermes_session_id,
                title or "Deleted chat",
                chat.get("created_at") or seed.get("created_at") or now,
                chat.get("updated_at") or seed.get("updated_at") or now,
                preview or "",
                now,
            ),
        )
        conn.commit()
        return {"deleted": True, "trashed": True}
    finally:
        conn.close()


# --- Project endpoints ---

@app.get("/api/projects")
async def list_projects():
    conn = get_db()
    try:
        rows = conn.execute("SELECT * FROM ui_projects ORDER BY name ASC").fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


@app.post("/api/projects")
async def create_project(request: Request):
    body = await read_limited_json(request, MAX_TTS_JSON_BYTES)
    project_id = f"proj_{int(time.time()*1000)}_{uuid.uuid4().hex[:8]}"
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    name = body.get("name", "New project").strip() or "New project"
    color = body.get("color", "blue")
    conn = get_db()
    try:
        conn.execute(
            "INSERT INTO ui_projects (id, name, color, created_at) VALUES (?, ?, ?, ?)",
            (project_id, name, color, now),
        )
        conn.commit()
        row = conn.execute("SELECT * FROM ui_projects WHERE id = ?", (project_id,)).fetchone()
        return dict(row)
    finally:
        conn.close()


@app.patch("/api/projects/{project_id}")
async def update_project(project_id: str, request: Request):
    body = await read_limited_json(request, MAX_TTS_JSON_BYTES)
    fields = []
    values = []
    if "name" in body:
        fields.append("name = ?")
        values.append(body["name"])
    if "color" in body:
        fields.append("color = ?")
        values.append(body["color"])
    if not fields:
        return {"error": "No fields to update"}
    conn = get_db()
    try:
        conn.execute(f"UPDATE ui_projects SET {', '.join(fields)} WHERE id = ?", values + [project_id])
        conn.commit()
        row = conn.execute("SELECT * FROM ui_projects WHERE id = ?", (project_id,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Project not found")
        return dict(row)
    finally:
        conn.close()


@app.delete("/api/projects/{project_id}")
async def delete_project(project_id: str):
    conn = get_db()
    try:
        conn.execute("DELETE FROM ui_projects WHERE id = ?", (project_id,))
        conn.commit()
        return {"deleted": True}
    finally:
        conn.close()


@app.get("/api/chats/{chat_id}/messages")
async def get_messages(chat_id: str):
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT hermes_session_id FROM ui_chats WHERE id = ?", (chat_id,)
        ).fetchone()
        rows = conn.execute(
            "SELECT data FROM ui_messages WHERE chat_id = ? ORDER BY created_at ASC, rowid ASC",
            (chat_id,)
        ).fetchall()
        ui_messages = [json.loads(r["data"]) for r in rows]
    finally:
        conn.close()

    # Overlay the canonical transcript from state.db so turns added by the
    # official app (or any other client) show up. For a synthesized official-app
    # chat there's no ui_chats row, so the chat_id IS the session id.
    session_id = (row["hermes_session_id"] if row else None) or chat_id
    db = _session_db()
    if db is not None and session_id:
        try:
            sid = db.resolve_session_id(session_id)
            if sid:
                return _append_external_tail(ui_messages, db.get_messages(sid))
        except Exception as e:
            logger.warning("state.db read failed for %s: %s", session_id, e)
    return ui_messages


@app.post("/api/chats/{chat_id}/messages")
async def save_messages(chat_id: str, request: Request):
    messages = await read_limited_json_value(request, MAX_PROXY_BODY_BYTES)
    if not isinstance(messages, list):
        raise HTTPException(status_code=400, detail="Expected message list")
    conn = get_db()
    try:
        for msg in messages:
            conn.execute(
                "INSERT OR REPLACE INTO ui_messages (id, chat_id, type, created_at, data) VALUES (?, ?, ?, ?, ?)",
                (msg["id"], chat_id, msg["type"], msg.get("createdAt", ""), json.dumps(msg))
            )
        conn.commit()
        return {"saved": len(messages)}
    finally:
        conn.close()


# --- Voice endpoints ---

async def _hermes_capabilities() -> dict:
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(
                f"{API_SERVER_URL.rstrip('/')}/v1/capabilities",
                headers=_hermes_headers(),
            )
            if resp.status_code == 200:
                return resp.json()
    except Exception:
        pass
    return {}


async def _hermes_capability_path(keywords: tuple[str, ...], method: str = "GET") -> str:
    caps = await _hermes_capabilities()
    endpoints = caps.get("endpoints") if isinstance(caps, dict) else None
    if not isinstance(endpoints, dict):
        return ""
    wanted_method = method.upper()
    for name, spec in endpoints.items():
        if not isinstance(spec, dict):
            continue
        path = str(spec.get("path") or "")
        endpoint_method = str(spec.get("method") or "").upper()
        haystack = f"{name} {path}".lower()
        if endpoint_method == wanted_method and any(k in haystack for k in keywords):
            return path if path.startswith("/") else f"/{path}"
    return ""


@app.get("/api/channel-capabilities")
async def channel_capabilities():
    models_response = await list_models()
    models = models_response.get("models", []) if isinstance(models_response, dict) else []
    default_model = models_response.get("default", "") if isinstance(models_response, dict) else ""
    default_provider = models_response.get("defaultProvider", "") if isinstance(models_response, dict) else ""
    providers = models_response.get("providers", []) if isinstance(models_response, dict) else []
    try:
        voices_response = _hermes_voices_from_config(_load_hermes_config(required=True))
    except HTTPException as e:
        logger.warning("Hermes config voice discovery failed: %s", e.detail)
        voices_response = {"default": "", "voices": []}
    voices = voices_response.get("voices", []) if isinstance(voices_response, dict) else []
    supported_voices = [v for v in voices if isinstance(v, dict) and v.get("supported")]
    stt_path = await _hermes_capability_path(("transcribe", "transcription", "stt"), method="POST")
    image_path = await _hermes_capability_path(("image",), method="POST")
    return {
        "brain": {
            "available": bool(models),
            "defaultModel": default_model,
            "defaultProvider": default_provider,
            "models": models,
            "providers": providers,
            "required": True,
        },
        "voice": {
            "hermesTtsAvailable": bool(supported_voices),
            "hermesSttAvailable": bool(stt_path),
            "iosLocalFallback": True,
            "defaultVoice": voices_response.get("default", ""),
            "voices": voices,
        },
        "image": {
            "available": bool(image_path),
            "required": False,
        },
    }


@app.get("/api/voices")
async def list_voices():
    return _hermes_voices_from_config(_load_hermes_config(required=True))


def _media_type_for_audio_format(output_format: str) -> str:
    fmt = output_format.lower()
    if fmt == "wav":
        return "audio/wav"
    if fmt == "mp3":
        return "audio/mpeg"
    if fmt in {"ogg", "opus"}:
        return "audio/ogg"
    return f"audio/{fmt}"


def _command_with_env_override(command: str, key: str, value: str) -> str:
    if not _re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise HTTPException(status_code=400, detail=f"Invalid TTS voice {value}")
    pattern = rf"(^|\s){_re.escape(key)}=[^\s]+"
    replacement = rf"\1{key}={value}"
    if _re.search(pattern, command):
        return _re.sub(pattern, replacement, command, count=1)
    return f"{key}={value} {command}"


def _resolve_command_voice_selection(requested_voice: str, providers: dict) -> tuple[str, str]:
    requested_voice = str(requested_voice or "").strip()
    if not requested_voice:
        return "", ""
    if ":" in requested_voice:
        provider_id, voice_variant = requested_voice.split(":", 1)
        return provider_id.strip(), voice_variant.strip()
    if isinstance(providers.get(requested_voice), dict):
        return requested_voice, ""

    matches: list[tuple[str, str]] = []
    for provider_id, spec in providers.items():
        if not isinstance(spec, dict):
            continue
        for voice in _provider_voice_entries(_voice_metadata_spec(str(provider_id), spec)):
            if voice["id"] == requested_voice:
                matches.append((str(provider_id), requested_voice))
    if len(matches) == 1:
        return matches[0]
    return requested_voice, ""


async def _run_command_tts(provider_id: str, provider: dict, text: str, voice_variant: str = ""):
    from fastapi.responses import Response as RawResponse
    # The iOS client currently treats server-TTS chunks as WAV for playback,
    # normalization, and karaoke timing. Hermes providers may advertise an
    # `output_format` such as ogg for other channels; keep this channel on WAV
    # unless an iOS-specific override is deliberately configured.
    output_format = str(provider.get("ios_output_format") or "wav").strip().lstrip(".") or "wav"
    command_template = str(provider.get("command") or "").strip()
    if not command_template:
        raise HTTPException(status_code=503, detail=f"Hermes TTS provider {provider_id} has no command")
    if voice_variant:
        voice_meta = _voice_metadata_spec(provider_id, provider)
        configured_voice_ids = {v["id"] for v in _provider_voice_entries(voice_meta)}
        if configured_voice_ids and voice_variant not in configured_voice_ids:
            raise HTTPException(status_code=400, detail=f"Unsupported {provider_id} voice {voice_variant}")
        voice_env = str(voice_meta.get("voice_env") or "").strip() or _infer_voice_env(command_template)
        if not voice_env:
            raise HTTPException(status_code=400, detail=f"Hermes TTS provider {provider_id} does not expose a voice override")
        command_template = _command_with_env_override(command_template, voice_env, voice_variant)
    timeout = int(provider.get("timeout") or 90)
    timeout = min(max(timeout, 1), 300)
    with tempfile.TemporaryDirectory(prefix="hermes-ios-tts-") as tmp:
        tmp_dir = Path(tmp)
        input_path = tmp_dir / "input.txt"
        output_path = tmp_dir / f"output.{output_format}"
        input_path.write_text(text, encoding="utf-8")
        command = (
            command_template
            .replace("{input_path}", str(input_path))
            .replace("{output_path}", str(output_path))
            .replace("{format}", output_format)
        )
        started = time.monotonic()
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.communicate()
            raise HTTPException(status_code=503, detail=f"Hermes TTS provider {provider_id} timed out")
        if proc.returncode != 0:
            detail = stderr.decode("utf-8", errors="replace").strip() or stdout.decode("utf-8", errors="replace").strip()
            raise HTTPException(status_code=503, detail=f"Hermes TTS provider {provider_id} failed: {detail[:300]}")
        if not output_path.exists():
            raise HTTPException(status_code=503, detail=f"Hermes TTS provider {provider_id} produced no audio")
        output_size = output_path.stat().st_size
        if output_size <= 0:
            raise HTTPException(status_code=503, detail=f"Hermes TTS provider {provider_id} produced empty audio")
        if output_size > MAX_TTS_OUTPUT_BYTES:
            raise HTTPException(status_code=503, detail=f"Hermes TTS provider {provider_id} produced too much audio")
        audio = output_path.read_bytes()
        logger.info(
            "tts provider=%s voice=%s format=%s chars=%d bytes=%d took=%.3fs",
            provider_id,
            voice_variant or "(default)",
            output_format,
            len(text),
            len(audio),
            time.monotonic() - started,
        )
        media_type = _media_type_for_audio_format(output_format)
        return RawResponse(content=audio, media_type=media_type)


async def _run_edge_tts(spec: dict, text: str, voice_variant: str = ""):
    from fastapi.responses import Response as RawResponse
    try:
        import edge_tts
    except ImportError:
        raise HTTPException(status_code=503, detail="Hermes Edge TTS unavailable: edge-tts is not installed")

    voice = str(voice_variant or spec.get("voice") or "").strip()
    if not voice:
        raise HTTPException(status_code=503, detail="Hermes Edge TTS provider has no voice configured")
    rate = str(spec.get("rate") or "+0%").strip()
    volume = str(spec.get("volume") or "+0%").strip()
    pitch = str(spec.get("pitch") or "+0Hz").strip()
    with tempfile.TemporaryDirectory(prefix="hermes-ios-edge-tts-") as tmp:
        output_path = Path(tmp) / "output.mp3"
        started = time.monotonic()
        try:
            communicate = edge_tts.Communicate(text, voice=voice, rate=rate, volume=volume, pitch=pitch)
            await asyncio.wait_for(communicate.save(str(output_path)), timeout=90)
        except asyncio.TimeoutError:
            raise HTTPException(status_code=503, detail="Hermes Edge TTS provider timed out")
        except Exception as e:
            raise HTTPException(status_code=503, detail=f"Hermes Edge TTS provider failed: {str(e)[:300]}")
        if not output_path.exists():
            raise HTTPException(status_code=503, detail="Hermes Edge TTS provider produced no audio")
        output_size = output_path.stat().st_size
        if output_size <= 0:
            raise HTTPException(status_code=503, detail="Hermes Edge TTS provider produced empty audio")
        if output_size > MAX_TTS_OUTPUT_BYTES:
            raise HTTPException(status_code=503, detail="Hermes Edge TTS provider produced too much audio")
        audio = output_path.read_bytes()
        logger.info("tts provider=edge voice=%s chars=%d bytes=%d took=%.3fs", voice, len(text), len(audio), time.monotonic() - started)
        return RawResponse(content=audio, media_type="audio/mpeg")


async def _run_elevenlabs_tts(spec: dict, text: str, voice_variant: str = ""):
    from fastapi.responses import Response as RawResponse
    keys = _load_hermes_env_keys({"ELEVENLABS_API_KEY"})
    api_key = keys.get("ELEVENLABS_API_KEY", "").strip()
    if not api_key:
        raise HTTPException(status_code=503, detail="Hermes ElevenLabs TTS provider has no API key configured")
    voice_id = str(voice_variant or spec.get("voice_id") or "").strip()
    if not voice_id:
        raise HTTPException(status_code=503, detail="Hermes ElevenLabs TTS provider has no voice_id configured")
    model_id = str(spec.get("model_id") or "eleven_multilingual_v2").strip()
    output_format = str(spec.get("output_format") or "mp3_44100_128").strip()
    payload = {"text": text, "model_id": model_id}
    voice_settings = spec.get("voice_settings")
    if isinstance(voice_settings, dict):
        payload["voice_settings"] = voice_settings
    started = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=90.0) as client:
            resp = await client.post(
                f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}",
                params={"output_format": output_format},
                headers={
                    "xi-api-key": api_key,
                    "Content-Type": "application/json",
                    "Accept": "audio/mpeg",
                },
                json=payload,
            )
            resp.raise_for_status()
    except httpx.HTTPStatusError as e:
        detail = e.response.text[:300] if e.response is not None else str(e)
        raise HTTPException(status_code=503, detail=f"Hermes ElevenLabs TTS provider failed: {detail}")
    except httpx.RequestError as e:
        raise HTTPException(status_code=503, detail=f"Hermes ElevenLabs TTS provider unavailable: {e}")
    if not resp.content:
        raise HTTPException(status_code=503, detail="Hermes ElevenLabs TTS provider produced empty audio")
    if len(resp.content) > MAX_TTS_OUTPUT_BYTES:
        raise HTTPException(status_code=503, detail="Hermes ElevenLabs TTS provider produced too much audio")
    logger.info("tts provider=elevenlabs voice=%s chars=%d bytes=%d took=%.3fs", voice_id, len(text), len(resp.content), time.monotonic() - started)
    media_type = resp.headers.get("content-type", "audio/mpeg")
    return RawResponse(content=resp.content, media_type=media_type)


@app.post("/api/tts")
async def text_to_speech(request: Request):
    body = await read_limited_json(request, MAX_TTS_JSON_BYTES)
    text = body.get("text", "").strip()
    voice = str(body.get("voice", "") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text required")

    config = _load_hermes_config(required=True)
    tts = config.get("tts") if isinstance(config.get("tts"), dict) else {}
    providers = tts.get("providers") if isinstance(tts.get("providers"), dict) else {}
    provider_id, voice_variant = _resolve_command_voice_selection(voice, providers)
    if not provider_id:
        provider_id = str(tts.get("provider") or "").strip()
    provider = providers.get(provider_id) if isinstance(providers.get(provider_id), dict) else None
    if provider and str(provider.get("type") or "").strip() == "command":
        return await _run_command_tts(provider_id, provider, text, voice_variant=voice_variant)
    if provider_id == "edge" and isinstance(tts.get("edge"), dict):
        return await _run_edge_tts(tts.get("edge"), text, voice_variant=voice_variant)
    if provider_id == "elevenlabs" and isinstance(tts.get("elevenlabs"), dict):
        return await _run_elevenlabs_tts(tts.get("elevenlabs"), text, voice_variant=voice_variant)

    voices = _hermes_voices_from_config(config).get("voices", [])
    supported_ids = [v.get("id") for v in voices if isinstance(v, dict) and v.get("supported")]
    if supported_ids:
        raise HTTPException(
            status_code=400,
            detail=f"Hermes TTS voice {provider_id or '(default)'} is not supported by this channel server",
        )
    else:
        raise HTTPException(
            status_code=503,
            detail="Hermes TTS unavailable; configure a supported Hermes command TTS provider or use iOS on-device TTS",
        )


@app.post("/api/transcribe")
async def speech_to_text(request: Request):
    audio_bytes = await read_limited_body(request, MAX_TRANSCRIBE_BYTES)
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="No audio data")

    stt_path = await _hermes_capability_path(("transcribe", "transcription", "stt"), method="POST")
    if not stt_path:
        raise HTTPException(
            status_code=503,
            detail="Hermes STT unavailable; use iOS on-device transcription or enable STT in Hermes",
        )

    content_type = request.headers.get("content-type", "audio/webm")
    async with httpx.AsyncClient(timeout=120.0) as client:
        try:
            resp = await client.post(
                f"{API_SERVER_URL.rstrip('/')}{stt_path}",
                headers={**_hermes_headers(_bearer_token(request)), "Content-Type": content_type},
                content=audio_bytes,
            )
            resp.raise_for_status()
        except (httpx.RequestError, httpx.HTTPStatusError) as e:
            raise HTTPException(status_code=503, detail=f"Hermes STT unavailable: {e}")

    if "application/json" in resp.headers.get("content-type", ""):
        data = resp.json()
        transcript = data.get("transcript") or data.get("text") or ""
        return {"transcript": transcript}
    return {"transcript": resp.text.strip()}


# --- UI settings endpoints ---

UI_SETTINGS_PATH = Path(__file__).parent.parent / "data" / "ui-settings.json"

@app.get("/api/ui-settings")
async def get_ui_settings():
    if UI_SETTINGS_PATH.exists():
        try:
            return json.loads(UI_SETTINGS_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}

@app.put("/api/ui-settings")
async def save_ui_settings(request: Request):
    body = await read_limited_json(request, MAX_TTS_JSON_BYTES)
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="settings payload must be an object")
    existing = {}
    if UI_SETTINGS_PATH.exists():
        try:
            existing = json.loads(UI_SETTINGS_PATH.read_text(encoding="utf-8"))
        except Exception:
            existing = {}
    if (
        isinstance(existing, dict)
        and existing.get("systemPrompt")
        and isinstance(body.get("systemPrompt"), str)
        and not body["systemPrompt"].strip()
    ):
        body["systemPrompt"] = existing["systemPrompt"]
    if isinstance(existing, dict):
        body = {**existing, **body}
    selected_model = str(body.get("selectedModel") or "").strip()
    if selected_model and not str(body.get("selectedProvider") or "").strip():
        try:
            config = _load_hermes_config(required=False)
            ref = _model_ref_from_selection(config, "", selected_model)
            if ref.get("provider"):
                body["selectedProvider"] = ref["provider"]
                body["selectedModel"] = ref["model"]
        except Exception:
            pass
    UI_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    UI_SETTINGS_PATH.write_text(json.dumps(body, indent=2), encoding="utf-8")
    return {"saved": True}


# --- Server config endpoints ---

@app.get("/api/server-config")
async def get_server_config():
    return {
        "mode": "hermes",
        "hermes_api_url": API_SERVER_URL,
        "brain_required": True,
        "voice_source": "hermes-or-ios-local",
    }

@app.patch("/api/server-config")
async def patch_server_config(request: Request):
    await read_limited_json(request, MAX_TTS_JSON_BYTES)
    raise HTTPException(
        status_code=410,
        detail="Provider/media services are configured in Hermes, not in this iOS channel",
    )


# --- PDF extraction endpoint ---

@app.get("/api/link-preview")
async def link_preview(url: str):
    """Fetch OG metadata for a single URL so the client can render a source card.
    SSRF-guarded (see helpers above): http/https only, every hop must resolve to
    a public IP, redirects followed manually, response size capped. Cached 24h."""
    raw = (url or "").strip()
    if not raw:
        raise HTTPException(status_code=400, detail="url required")

    cache_key = _normalize_url(raw)
    now = time.time()
    hit = _LINK_PREVIEW_CACHE.get(cache_key)
    if hit and hit[0] > now:
        return hit[1]

    current = raw
    headers = {
        "User-Agent": "Mozilla/5.0 (compatible; HermesLinkPreview/1.0)",
        "Accept": "text/html,application/xhtml+xml",
    }
    try:
        async with httpx.AsyncClient(timeout=10.0, follow_redirects=False) as client:
            for _ in range(_LINK_PREVIEW_MAX_REDIRECTS + 1):
                parsed = _urlparse(current)
                if parsed.scheme not in ("http", "https"):
                    raise HTTPException(status_code=400, detail="Only http/https URLs are allowed")
                if not await _resolve_is_public(parsed.hostname or ""):
                    raise HTTPException(status_code=403, detail="URL resolves to a non-public address")

                resp = await client.get(current, headers=headers)

                if resp.is_redirect and "location" in resp.headers:
                    current = str(httpx.URL(current).join(resp.headers["location"]))
                    await resp.aclose()
                    continue

                # Final response — read at most the head, capped.
                chunks, total = [], 0
                async for chunk in resp.aiter_bytes():
                    chunks.append(chunk)
                    total += len(chunk)
                    if total >= _LINK_PREVIEW_MAX_BYTES or b"</head>" in b"".join(chunks[-2:]):
                        break
                await resp.aclose()
                body = b"".join(chunks)[:_LINK_PREVIEW_MAX_BYTES]

                meta = _parse_og_tags(body)
                meta["url"] = current
                # Resolve favicon to an absolute URL; fall back to /favicon.ico.
                fav = meta.get("favicon") or ""
                final = _urlparse(current)
                if fav:
                    meta["favicon"] = str(httpx.URL(current).join(fav))
                elif final.scheme and final.hostname:
                    meta["favicon"] = f"{final.scheme}://{final.netloc}/favicon.ico"
                # Resolve a relative og:image too (some sites use a root-relative path).
                img = meta.get("image") or ""
                if img and not _urlparse(img).scheme:
                    meta["image"] = str(httpx.URL(current).join(img))
                _LINK_PREVIEW_CACHE[cache_key] = (now + _LINK_PREVIEW_TTL, meta)
                return meta

        raise HTTPException(status_code=400, detail="Too many redirects")
    except HTTPException:
        raise
    except (httpx.HTTPError, httpx.InvalidURL) as e:
        raise HTTPException(status_code=502, detail=f"Could not fetch URL: {type(e).__name__}")


@app.post("/api/extract-pdf")
async def extract_pdf(request: Request):
    try:
        import pdfplumber
    except ImportError:
        raise HTTPException(
            status_code=503,
            detail="PDF extraction unavailable — install pdfplumber on hermes-host: pip install pdfplumber",
        )
    import tempfile, os as _os
    content = await read_limited_body(request, MAX_PDF_BYTES)
    if not content:
        raise HTTPException(status_code=400, detail="No file content")
    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as f:
        f.write(content)
        tmp = f.name
    try:
        parts = []
        with pdfplumber.open(tmp) as pdf:
            page_count = len(pdf.pages)
            for page in pdf.pages:
                text = page.extract_text()
                if text:
                    parts.append(text.strip())
        return {"text": "\n\n".join(parts), "pages": page_count}
    except Exception as e:
        raise HTTPException(status_code=422, detail=f"PDF extraction failed: {e}")
    finally:
        try:
            _os.unlink(tmp)
        except Exception:
            pass


# --- Image generation endpoint ---

@app.post("/api/generate-image")
async def generate_image(request: Request):
    body = await read_limited_json(request, MAX_IMAGE_JSON_BYTES)
    prompt = (body.get("prompt") or "").strip()
    if not prompt:
        raise HTTPException(status_code=400, detail="prompt required")
    raise HTTPException(
        status_code=503,
        detail="Image generation is optional and must be exposed by Hermes before this channel can use it",
    )


@app.post("/api/image")
async def generate_image_alias(request: Request):
    return await generate_image(request)


@app.get("/api/img/{image_id}")
async def serve_generated_image(image_id: str):
    import re
    if not re.match(r'^[0-9a-f]{32}$', image_id):
        raise HTTPException(status_code=404, detail="not found")
    for ext in ("jpg", "png", "webp"):
        path = GENERATED_IMAGES_DIR / f"{image_id}.{ext}"
        if path.exists():
            return FileResponse(str(path), media_type=f"image/{ext}")
    raise HTTPException(status_code=404, detail="not found")


HERMES_CACHE_IMAGES = Path.home() / ".hermes" / "cache" / "images"

@app.get("/api/hermes-img/{filename}")
async def serve_hermes_cache_image(filename: str):
    import re
    if not re.match(r'^[\w\-]+\.(jpg|jpeg|png|webp|gif)$', filename, re.IGNORECASE):
        raise HTTPException(status_code=404, detail="not found")
    path = HERMES_CACHE_IMAGES / filename
    if not path.exists():
        raise HTTPException(status_code=404, detail="not found")
    ext = path.suffix.lstrip(".").lower()
    if ext == "jpg":
        ext = "jpeg"
    return FileResponse(str(path), media_type=f"image/{ext}")


# Files that the agent sends to the user (send_file tool drops them here under an
# opaque id). Served for download/preview in the chat. Same host as the gateway, so
# this dir is shared with ~/.hermes on hermes-host.
HERMES_CACHE_FILES = Path.home() / ".hermes" / "cache" / "files"

@app.get("/api/hermes-file/{file_id}")
async def serve_hermes_file(file_id: str):
    import re, mimetypes
    # Opaque id is "<hex>.<ext>" (or just "<hex>"). No slashes/dots-dots, so no
    # path traversal; resolve() + containment check is belt-and-suspenders.
    if not re.match(r'^[\w\-]+(\.[A-Za-z0-9]+)?$', file_id):
        raise HTTPException(status_code=404, detail="not found")
    base = HERMES_CACHE_FILES.resolve()
    path = (HERMES_CACHE_FILES / file_id).resolve()
    if path != base and base not in path.parents:
        raise HTTPException(status_code=404, detail="not found")
    if not path.is_file():
        raise HTTPException(status_code=404, detail="not found")
    mime = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
    # filename= sets Content-Disposition so a browser/Files download keeps the name;
    # the iOS client fetches the bytes and previews/shares regardless.
    return FileResponse(str(path), media_type=mime, filename=path.name)


# --- Tools / toolsets endpoints ---
# Hermes loads tools into model context by *toolset* (a named group of tools).
# The set enabled for the API-server platform lives in config.yaml under
# platform_toolsets.api_server, and the gateway re-reads it on every run — so
# changes here take effect on the next message with no restart.

def _hermes_config_path() -> Path:
    return Path(_HERMES_CONFIG_PATH).expanduser() if _HERMES_CONFIG_PATH else (Path.home() / ".hermes" / "config.yaml")


def _load_hermes_config(required: bool = False) -> dict:
    import yaml
    p = _hermes_config_path()
    if not p.exists():
        if required:
            raise HTTPException(status_code=404, detail="Hermes config file not found")
        return {}
    with open(p, encoding="utf-8") as f:
        loaded = yaml.safe_load(f) or {}
    if not isinstance(loaded, dict):
        if required:
            raise HTTPException(status_code=500, detail="Hermes config is not a mapping")
        return {}
    return loaded


def _api_server_toolsets(config: dict) -> list:
    pt = config.get("platform_toolsets") or {}
    val = pt.get("api_server")
    return [str(t) for t in val] if isinstance(val, list) else []


@app.get("/api/tools")
async def list_tools():
    """Return the toolset catalog with availability + current api_server enablement.

    Runs in the agent's venv, so the catalog is pulled live from the Hermes
    inventory. Returns [] if the agent modules can't be imported (the app then
    shows an empty state rather than erroring)."""
    try:
        from hermes_cli.tools_config import CONFIGURABLE_TOOLSETS
        from model_tools import get_available_toolsets
        try:
            from toolsets import TOOLSETS
        except Exception:
            TOOLSETS = {}
    except Exception:
        return []

    avail = {}
    try:
        avail = get_available_toolsets() or {}
    except Exception:
        avail = {}

    enabled = set(_api_server_toolsets(_load_hermes_config()))

    # Catalog from CONFIGURABLE_TOOLSETS, plus any currently enabled toolset
    # that isn't in the curated list (e.g. "search"). Return alphabetically for
    # predictable settings UI scanning instead of Hermes' internal grouping.
    seen = set()
    out = []

    def entry(key: str, label: str, hint: str):
        info = avail.get(key, {})
        ts = TOOLSETS.get(key, {})
        requirements = info.get("requirements", ts.get("requirements", []))
        return {
            "name": key,
            "label": label,
            "description": hint or ts.get("description", ""),
            "tools": info.get("tools", ts.get("tools", [])),
            "requirements": requirements if isinstance(requirements, list) else [],
            "available": bool(info.get("available", True)),
            "required": False,
            "enabled": key in enabled,
        }

    for key, label, hint in CONFIGURABLE_TOOLSETS:
        out.append(entry(key, label, hint))
        seen.add(key)

    for key in sorted(enabled - seen):
        ts = TOOLSETS.get(key, {})
        out.append(entry(key, ts.get("description", key), ts.get("description", "")))
        seen.add(key)

    def sort_key(tool: dict):
        label = str(tool.get("label") or tool.get("name") or "")
        cleaned = "".join(ch for ch in label if ch.isalnum() or ch.isspace() or ch in "_-")
        return (cleaned.strip().lower(), str(tool.get("name") or ""))

    out.sort(key=sort_key)
    return out


@app.put("/api/tools")
async def set_tools(request: Request):
    """Write the universal api_server toolset selection to config.yaml.
    Body: {"enabled": ["web", "terminal", ...]}. Takes effect next run."""
    import yaml
    body = await read_limited_json(request, MAX_TTS_JSON_BYTES)
    enabled = body.get("enabled")
    if not isinstance(enabled, list):
        raise HTTPException(status_code=400, detail="expected {\"enabled\": [toolset keys]}")
    cfg_path = _hermes_config_path()
    config = _load_hermes_config()
    pt = config.setdefault("platform_toolsets", {})
    pt["api_server"] = [str(t) for t in enabled]
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    with open(cfg_path, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    return {"saved": pt["api_server"]}


# --- Share endpoints ---

def _share_page_html(title: str, messages: list) -> str:
    import html as h
    rows = []
    for m in messages:
        if m.get("type") not in ("user", "assistant"):
            continue
        role = "You" if m["type"] == "user" else "Hermes"
        color = "#1a73e8" if m["type"] == "user" else "#188038"
        content = h.escape(m.get("content") or "")
        rows.append(f'<div class="msg"><span class="role" style="color:{color}">{role}</span><div class="body">{content}</div></div>')
    body_html = "\n".join(rows) or "<p style='color:#888'>No messages.</p>"
    safe_title = h.escape(title)
    return f"""<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{safe_title} — Hermes</title>
<style>
  body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:760px;margin:40px auto;padding:0 20px;background:#fff;color:#111;line-height:1.6}}
  h1{{font-size:20px;font-weight:700;margin-bottom:24px;color:#111}}
  .msg{{margin-bottom:18px}}
  .role{{font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;display:block;margin-bottom:4px}}
  .body{{white-space:pre-wrap;font-size:15px;color:#222}}
  .footer{{margin-top:48px;font-size:12px;color:#999;border-top:1px solid #eee;padding-top:16px}}
  @media(prefers-color-scheme:dark){{body{{background:#111;color:#eee}}.body{{color:#ddd}}.footer{{color:#666;border-color:#333}}}}
</style>
</head>
<body>
<h1>{safe_title}</h1>
{body_html}
<div class="footer">Shared via Hermes</div>
</body></html>"""


@app.post("/api/chats/{chat_id}/share")
async def create_share(chat_id: str, request: Request):
    from fastapi.responses import Response as RawResponse
    conn = get_db()
    try:
        row = conn.execute("SELECT title FROM ui_chats WHERE id = ?", (chat_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Chat not found")
        title = row["title"]
        msgs = conn.execute(
            "SELECT data FROM ui_messages WHERE chat_id = ? ORDER BY created_at ASC, rowid ASC",
            (chat_id,)
        ).fetchall()
        messages = [json.loads(r["data"]) for r in msgs]

        token = uuid.uuid4().hex
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        conn.execute(
            "INSERT INTO ui_shares (token, chat_id, title, messages, created_at) VALUES (?, ?, ?, ?, ?)",
            (token, chat_id, title, json.dumps(messages), now),
        )
        conn.commit()
        base = str(request.base_url).rstrip("/")
        return {"token": token, "url": f"{base}/share/{token}"}
    finally:
        conn.close()


@app.get("/share/{token}")
async def view_share(token: str):
    from fastapi.responses import HTMLResponse
    conn = get_db()
    try:
        row = conn.execute("SELECT title, messages FROM ui_shares WHERE token = ?", (token,)).fetchone()
        if not row:
            return HTMLResponse("<h1>Share link not found or expired.</h1>", status_code=404)
        messages = json.loads(row["messages"])
        html = _share_page_html(row["title"], messages)
        return HTMLResponse(html)
    finally:
        conn.close()


# --- Models list ---

# Models to hide from the selector (embeddings, TTS, etc.)
_MODEL_SKIP_KEYWORDS = ("embedding", "nomic", "chatterbox", "tts", "rerank", "whisper")

@app.get("/api/models")
async def list_models():
    """Return available chat models from Hermes.

    Hermes owns provider configuration and model availability. This endpoint is
    only a compatibility facade for the native app's existing model picker.
    """
    try:
        config = _load_hermes_config(required=True)
        try:
            return _hermes_models_from_inventory(config)
        except Exception:
            logger.exception("Hermes inventory model discovery failed; falling back to config aliases")
            return _hermes_models_from_config(config)
    except HTTPException as e:
        logger.warning("Hermes config model discovery failed: %s", e.detail)

    models = []
    default_model = ""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.get(
                f"{API_SERVER_URL.rstrip('/')}/v1/models",
                headers=_hermes_headers(),
            )
            if r.status_code == 200:
                data = r.json()
                items = data.get("data", []) if isinstance(data, dict) else []
                for m in items:
                    mid = str(m.get("id", "")).strip()
                    if any(kw in mid.lower() for kw in _MODEL_SKIP_KEYWORDS):
                        continue
                    models.append({"id": mid, "name": mid})
                default_model = str(data.get("default") or data.get("model") or "").strip()
                if not default_model and models:
                    default_model = models[0]["id"]
    except Exception:
        pass
    return {
        "models": models,
        "default": default_model,
        "defaultProvider": "",
        "providers": [{"id": "hermes", "name": "Hermes", "models": models, "defaultModel": default_model, "authenticated": True}] if models else [],
    }


@app.post("/api/model/activate")
async def activate_model(request: Request):
    """Legacy compatibility endpoint.

    iOS model selection is channel/chat scoped and must not mutate Hermes'
    global model.default/model.provider. New clients should save settings and
    send provider/model on each run instead of calling this endpoint.
    """
    body = await read_limited_json(request, MAX_TTS_JSON_BYTES)
    model_id = (body.get("model") or "").strip()
    if not model_id:
        raise HTTPException(status_code=400, detail="model required")

    config = _load_hermes_config(required=True)
    ref = _model_ref_from_selection(config, str(body.get("provider") or ""), model_id)
    if not ref.get("provider") or not ref.get("model"):
        raise HTTPException(status_code=400, detail="model is not assignable by Hermes")
    return {
        "ok": True,
        "status": "channel-scoped",
        "provider": ref["provider"],
        "model": ref["model"],
        "model_id": model_id,
    }


# --- Proxy to Hermes API ---

@app.post("/api/debug/timing")
async def debug_timing(request: Request):
    """Receives timing events from iOS app and prints them to server stdout."""
    body = await read_limited_json(request, MAX_TTS_JSON_BYTES)
    label = body.get("label", "?")
    elapsed = body.get("elapsed", 0)
    detail = body.get("detail", "")
    print(f"[iOS⏱] {label:20s}  +{elapsed:.3f}s  {detail}", flush=True)
    return {"ok": True}


@app.api_route("/api/v1/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
async def proxy_api(path: str, request: Request):
    target_url = f"{API_SERVER_URL}/v1/{path}"
    # Copy client headers, dropping hop-by-hop AND every Authorization variant.
    # dict(request.headers) lowercases keys, so setting headers["Authorization"]
    # would NOT replace the client's lowercase "authorization" — both would be
    # forwarded, and a trailing space in a pasted key reaches httpx as an illegal
    # header value (LocalProtocolError → 500). Strip all auth, then set one clean.
    hop_by_hop = {
        "host",
        "content-length",
        "transfer-encoding",
        "connection",
        "keep-alive",
        "upgrade",
        "authorization",
    }
    headers = {k: v for k, v in request.headers.items() if k.lower() not in hop_by_hop}
    token = (API_SERVER_KEY or "").strip()
    if not token:
        # No server key configured — fall back to the client's bearer, cleaned.
        token = request.headers.get("authorization", "").replace("Bearer", "").strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"

    body = None
    content_type = headers.get("content-type", "")
    if request.method in ("POST", "PUT", "PATCH") and content_type:
        raw = await read_limited_body(request, MAX_PROXY_BODY_BYTES)
        if raw:
            if request.method == "POST" and path == "runs":
                raw = _normalize_run_model_body(raw, content_type)
            body = raw

    # Strip headers that must not be forwarded to upstream
    response_hop_by_hop = {"content-length", "transfer-encoding", "connection", "keep-alive", "upgrade"}

    is_sse = path.endswith("/events") and request.method == "GET"

    if is_sse:
        # Use streaming client for SSE so we don't buffer the whole response
        async def sse_stream():
            async with httpx.AsyncClient(timeout=300.0) as stream_client:
                try:
                    async with stream_client.stream(
                        method=request.method,
                        url=target_url,
                        headers=headers,
                        content=body,
                        follow_redirects=False,
                    ) as response:
                        async for chunk in response.aiter_bytes():
                            yield chunk
                except (httpx.ReadTimeout, httpx.RemoteProtocolError):
                    return

        from fastapi.responses import StreamingResponse
        return StreamingResponse(
            sse_stream(),
            status_code=200,
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    async with httpx.AsyncClient(timeout=300.0) as client:
        try:
            response = await client.request(
                method=request.method,
                url=target_url,
                headers=headers,
                content=body,
                follow_redirects=False,
            )
            # Strip hop-by-hop headers from upstream response
            fwd_headers = {k: v for k, v in response.headers.items() if k.lower() not in response_hop_by_hop}
            # For SSE streams, switch to streaming response
            if "text/event-stream" in response.headers.get("content-type", ""):
                from fastapi.responses import StreamingResponse
                async def stream():
                    async for chunk in response.aiter_bytes():
                        yield chunk
                fwd_headers["Cache-Control"] = "no-cache"
                fwd_headers["X-Accel-Buffering"] = "no"
                return StreamingResponse(stream(), status_code=response.status_code, media_type="text/event-stream", headers=fwd_headers)
            if "application/json" in response.headers.get("content-type", ""):
                return JSONResponse(content=response.json(), status_code=response.status_code, headers=fwd_headers)
            # Raw passthrough for other content types
            from fastapi.responses import Response as RawResponse
            return RawResponse(content=response.content, status_code=response.status_code, headers=fwd_headers)
        except httpx.ConnectError:
            raise HTTPException(status_code=503, detail="API server unavailable")
        except httpx.ReadTimeout:
            raise HTTPException(status_code=504, detail="API server timeout")
        except httpx.HTTPError as exc:
            # Any other httpx-level failure (e.g. a malformed forwarded header)
            # should surface as a clean error, not a masked AttributeError 500.
            raise HTTPException(status_code=502, detail=f"Upstream request failed: {type(exc).__name__}")


@app.get("/")
async def server_root():
    return {
        "name": "Hermes iOS Channel Server",
        "version": "0.1-beta",
        "health": "/api/health",
        "ios": "Configure the iOS app with this server URL and your interface API key.",
    }


@app.get("/{full_path:path}")
async def not_found(full_path: str):
    raise HTTPException(status_code=404, detail="not found")


if __name__ == "__main__":
    import uvicorn
    host = os.getenv("HERMES_INTERFACE_HOST", "0.0.0.0")
    port = int(os.getenv("HERMES_INTERFACE_PORT", os.getenv("WEB_PORT", "3001")))
    print(f"Starting Hermes iOS Interface Server on {host}:{port}")
    print(f"API server: {API_SERVER_URL}")
    uvicorn.run(app, host=host, port=port)
