#!/usr/bin/env python3
"""Readiness checks for the Hermes iOS Channel server.

Default mode is read-only and checks the running channel server. Use
``--run-smoke`` to send one tiny prompt through Hermes.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_SERVER_URL = "http://127.0.0.1:3001"


@dataclass
class Check:
    name: str
    status: str
    detail: str


def load_env_file(path: Path) -> None:
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


def normalize_url(url: str) -> str:
    return url.rstrip("/")


def request_json(
    method: str,
    url: str,
    token: str = "",
    body: dict[str, Any] | None = None,
    extra_headers: dict[str, str] | None = None,
    timeout: float = 10.0,
) -> tuple[int, Any, str]:
    data = None
    headers = dict(extra_headers or {})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            content_type = resp.headers.get("content-type", "")
            if "application/json" in content_type:
                return resp.status, json.loads(raw or "{}"), raw
            try:
                return resp.status, json.loads(raw or "{}"), raw
            except json.JSONDecodeError:
                return resp.status, {}, raw
    except HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            payload: Any = json.loads(raw)
        except json.JSONDecodeError:
            payload = {}
        return exc.code, payload, raw
    except URLError as exc:
        raise RuntimeError(str(exc.reason)) from exc
    except (TimeoutError, socket.timeout) as exc:
        raise RuntimeError("request timed out") from exc


def check_health(server_url: str, token: str) -> Check:
    try:
        status, payload, raw = request_json("GET", f"{server_url}/api/health", token)
    except RuntimeError as exc:
        return Check("channel health", "fail", str(exc))
    if status == 200:
        platform = payload.get("platform") if isinstance(payload, dict) else ""
        return Check("channel health", "pass", f"HTTP 200 {platform}".strip())
    return Check("channel health", "fail", f"HTTP {status}: {raw[:200]}")


def check_models(server_url: str, token: str) -> tuple[Check, list[dict[str, Any]], str]:
    try:
        status, payload, raw = request_json("GET", f"{server_url}/api/models", token)
    except RuntimeError as exc:
        return Check("brain models", "fail", str(exc)), [], ""
    if status != 200:
        return Check("brain models", "fail", f"HTTP {status}: {raw[:200]}"), [], ""
    models = payload.get("models", []) if isinstance(payload, dict) else []
    default_model = payload.get("default", "") if isinstance(payload, dict) else ""
    if not isinstance(models, list) or not models:
        return Check("brain models", "fail", "Hermes returned no chat models"), [], default_model
    detail = f"{len(models)} model(s)"
    if default_model:
        detail += f", default={default_model}"
    return Check("brain models", "pass", detail), models, default_model


def check_capabilities(server_url: str, token: str) -> tuple[Check, dict[str, Any]]:
    try:
        status, payload, raw = request_json("GET", f"{server_url}/api/channel-capabilities", token)
    except RuntimeError as exc:
        return Check("channel capabilities", "fail", str(exc)), {}
    if status != 200:
        return Check("channel capabilities", "fail", f"HTTP {status}: {raw[:200]}"), {}
    brain = payload.get("brain", {}) if isinstance(payload, dict) else {}
    voice = payload.get("voice", {}) if isinstance(payload, dict) else {}
    image = payload.get("image", {}) if isinstance(payload, dict) else {}
    brain_ok = bool(brain.get("available"))
    tts = bool(voice.get("hermesTtsAvailable"))
    stt = bool(voice.get("hermesSttAvailable"))
    image_ok = bool(image.get("available"))
    if not brain_ok:
        return Check("channel capabilities", "fail", "brain unavailable"), payload
    voice_detail = "Hermes TTS" if tts else "iOS local TTS fallback"
    if stt:
        voice_detail += ", Hermes STT"
    else:
        voice_detail += ", iOS local STT fallback"
    image_detail = "image available" if image_ok else "image optional/unavailable"
    return Check("channel capabilities", "pass", f"{voice_detail}; {image_detail}"), payload


def check_direct_hermes(hermes_url: str, hermes_key: str) -> list[Check]:
    if not hermes_url:
        return []
    base = normalize_url(hermes_url)
    checks: list[Check] = []
    for name, path in (("Hermes models", "/v1/models"), ("Hermes capabilities", "/v1/capabilities")):
        try:
            status, payload, raw = request_json("GET", f"{base}{path}", hermes_key)
        except RuntimeError as exc:
            checks.append(Check(name, "fail", str(exc)))
            continue
        if status != 200:
            checks.append(Check(name, "fail", f"HTTP {status}: {raw[:200]}"))
            continue
        if path == "/v1/models":
            items = payload.get("data", []) if isinstance(payload, dict) else []
            if items:
                checks.append(Check(name, "pass", f"{len(items)} model(s)"))
            else:
                checks.append(Check(name, "fail", "no models returned"))
        else:
            endpoints = payload.get("endpoints", {}) if isinstance(payload, dict) else {}
            checks.append(Check(name, "pass", f"{len(endpoints)} endpoint(s) advertised"))
    return checks


def run_smoke(server_url: str, token: str, model: str, prompt: str, timeout: float) -> Check:
    body: dict[str, Any] = {"input": prompt, "stream": False}
    if model:
        body["model"] = model
    headers = {"X-Hermes-Session-Key": f"readiness:{uuid.uuid4().hex}"}
    try:
        status, payload, raw = request_json(
            "POST",
            f"{server_url}/api/v1/runs",
            token,
            body=body,
            extra_headers=headers,
            timeout=timeout,
        )
    except RuntimeError as exc:
        return Check("run smoke", "fail", str(exc))
    if status >= 400:
        return Check("run smoke", "fail", f"HTTP {status}: {raw[:300]}")
    if isinstance(payload, dict) and payload.get("output"):
        return Check("run smoke", "pass", "run returned output")
    run_id = payload.get("run_id") if isinstance(payload, dict) else ""
    if not run_id:
        return Check("run smoke", "warn", f"started but no run_id/output: {raw[:200]}")

    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(1.0)
        try:
            status, payload, raw = request_json("GET", f"{server_url}/api/v1/runs/{run_id}", token, timeout=10)
        except RuntimeError as exc:
            return Check("run smoke", "fail", str(exc))
        if status >= 400:
            return Check("run smoke", "fail", f"status HTTP {status}: {raw[:300]}")
        run_status = payload.get("status") if isinstance(payload, dict) else ""
        if run_status in {"completed", "failed", "cancelled"}:
            if run_status == "completed":
                return Check("run smoke", "pass", f"completed run_id={run_id}")
            return Check("run smoke", "fail", f"{run_status}: {payload.get('error', '')}")
    return Check("run smoke", "warn", f"started run_id={run_id}, still running after {int(timeout)}s")


def print_report(checks: list[Check]) -> None:
    print("Hermes iOS Channel readiness")
    print()
    for check in checks:
        marker = {"pass": "PASS", "warn": "WARN", "fail": "FAIL"}.get(check.status, check.status.upper())
        print(f"[{marker}] {check.name}: {check.detail}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check Hermes iOS Channel readiness.")
    parser.add_argument("--server-url")
    parser.add_argument("--interface-key")
    parser.add_argument("--hermes-url")
    parser.add_argument("--hermes-key")
    parser.add_argument("--env-file", default=str(Path(__file__).with_name(".env")))
    parser.add_argument("--run-smoke", action="store_true", help="Send one tiny prompt through Hermes.")
    parser.add_argument("--smoke-prompt", default="Reply with exactly: ready")
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args()

    load_env_file(Path(args.env_file))
    server_url = normalize_url(args.server_url or os.getenv("HERMES_INTERFACE_URL", DEFAULT_SERVER_URL))
    interface_key = args.interface_key or os.getenv("HERMES_INTERFACE_KEY", "")
    hermes_url = args.hermes_url or os.getenv("HERMES_API_URL", "")
    hermes_key = args.hermes_key or os.getenv("HERMES_API_KEY", os.getenv("API_SERVER_KEY", ""))

    checks: list[Check] = []
    checks.append(check_health(server_url, interface_key))
    models_check, _models, default_model = check_models(server_url, interface_key)
    checks.append(models_check)
    capabilities_check, _capabilities = check_capabilities(server_url, interface_key)
    checks.append(capabilities_check)
    checks.extend(check_direct_hermes(hermes_url, hermes_key))
    if args.run_smoke:
        checks.append(run_smoke(server_url, interface_key, default_model, args.smoke_prompt, args.timeout))

    print_report(checks)
    print()
    if any(check.status == "fail" for check in checks):
        print("Result: not ready")
        return 1
    if any(check.status == "warn" for check in checks):
        print("Result: ready with warnings")
        return 0
    print("Result: ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
