"""Per-request toolset overrides for the API-server platform.

Lets ``POST /v1/runs`` carry an ``enabled_toolsets`` list that overrides the
universal ``platform_toolsets.api_server`` config for that one run. When the
field is absent, runs use Hermes' universal config unchanged.

This plugin intentionally does not override model providers. Hermes remains the
source of truth for provider keys, default brain model, and runtime routing.
"""
import contextvars
import functools
import logging

logger = logging.getLogger("hermes.plugin.toolset_override")

_override_var = contextvars.ContextVar("api_server_toolset_override", default=None)


def _patch_get_platform_tools() -> None:
    from hermes_cli import tools_config
    if getattr(tools_config, "_toolset_override_installed", False):
        return
    _orig = tools_config._get_platform_tools

    @functools.wraps(_orig)
    def _patched(config, platform, *args, **kwargs):
        override = _override_var.get()
        if platform == "api_server" and isinstance(override, list):
            result = {str(t) for t in override}
            logger.debug("toolset_override: api_server run using per-request toolsets %s", sorted(result))
            return result
        return _orig(config, platform, *args, **kwargs)

    tools_config._get_platform_tools = _patched
    tools_config._toolset_override_installed = True


def _patch_run_handler() -> None:
    from gateway.platforms import api_server
    adapter = api_server.APIServerAdapter
    if getattr(adapter, "_toolset_override_installed", False):
        return
    _orig = adapter._handle_runs

    @functools.wraps(_orig)
    async def _patched(self, request):
        try:
            body = await request.json()
            ts = body.get("enabled_toolsets")
            _override_var.set(ts if isinstance(ts, list) else None)
        except Exception:
            _override_var.set(None)
        return await _orig(self, request)

    adapter._handle_runs = _patched
    adapter._toolset_override_installed = True


def register(ctx) -> None:
    try:
        _patch_get_platform_tools()
        _patch_run_handler()
        print(
            "[toolset_override] installed: per-request toolset overrides active for api_server runs",
            flush=True,
        )
    except Exception as exc:
        logger.warning(
            "toolset_override: install failed (%s); api_server will use global toolsets",
            exc,
        )
