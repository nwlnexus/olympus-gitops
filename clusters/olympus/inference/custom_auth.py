"""Per-client keys for the cluster LiteLLM (olympus-sdk#569, absorbs #490).

No database: each client's key is one file in LITELLM_CLIENT_KEYS_DIR (Secret litellm-client-keys,
file name = client name), and LITELLM_CLIENT_SCOPES (JSON, client -> list of aliases) says which
aliases that client may call. Files are re-read when they change, so a rotated key (ESO refresh)
takes effect without a restart. A key that matches no file is refused (401); an alias outside the
client's scope is refused (403).
"""
import hmac
import json
import os
import pathlib

from fastapi import HTTPException, Request
from litellm.proxy._types import UserAPIKeyAuth, hash_token
from litellm.proxy.common_utils.http_parsing_utils import _read_request_body

_KEYS_DIR = pathlib.Path(os.environ.get("LITELLM_CLIENT_KEYS_DIR", "/etc/litellm/client-keys"))
_SCOPES = {c: list(a) for c, a in json.loads(os.environ.get("LITELLM_CLIENT_SCOPES", "{}")).items()}
_cache: dict = {"stamp": None, "keys": {}}
# Routes a client key may call: inference and the model list. Everything else (admin, UI, key
# management) is refused; this proxy has no database and no admin clients.
_ROUTES = ("/v1/chat/completions", "/chat/completions", "/v1/completions", "/completions", "/v1/models", "/models")


def _keys() -> dict:
    files = sorted(p for p in _KEYS_DIR.glob("*") if p.is_file() and not p.name.startswith("."))
    stamp = tuple((p.name, p.stat().st_mtime_ns) for p in files)
    if stamp != _cache["stamp"]:
        keys = {}
        for p in files:
            value = p.read_text().strip()
            if value and p.name in _SCOPES:
                keys[p.name] = value
        _cache.update(stamp=stamp, keys=keys)
    return _cache["keys"]


async def user_api_key_auth(request: Request, api_key: str) -> UserAPIKeyAuth:
    presented = (api_key or "").removeprefix("Bearer ").strip()
    client = next(
        (c for c, k in _keys().items() if presented and hmac.compare_digest(presented.encode(), k.encode())),
        None,
    )
    if client is None:
        raise HTTPException(status_code=401, detail="invalid api key")
    if request.url.path.rstrip("/") not in _ROUTES:
        raise HTTPException(status_code=403, detail=f"route {request.url.path} is not available")
    allowed = _SCOPES[client]
    if request.method == "POST":
        model = (await _read_request_body(request=request)).get("model")
        if model is not None and model not in allowed:
            raise HTTPException(status_code=403, detail=f"client {client} may not use {model}")
    # api_key is a hash: LiteLLM puts it in metric labels (hashed_api_key) and logs.
    return UserAPIKeyAuth(api_key=hash_token(presented), key_alias=client, user_id=client, models=allowed)
