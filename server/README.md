# Hermes iOS Channel Server

FastAPI bridge used by the native iOS app.

This server expects an existing Hermes install. Hermes remains the source of
truth for provider keys, brain model, voice model, tools, memory, and run
execution. The channel server adds iOS-friendly storage and proxy routes.

This server does not configure alternate or backup providers. If Hermes does
not advertise TTS, the iOS app should use Apple/on-device speech.

## Local Run

From the repository root, the recommended installer is:

```bash
./install-server.sh
```

It copies the server to `~/.hermes-ios-channel` by default, writes `.env`,
generates the iOS channel API key, installs Python dependencies, and can
optionally register a user service.

For a normal same-user Hermes install, the installer reads `~/.hermes/.env`,
offers to enable the Hermes API server, generates `API_SERVER_KEY` if needed,
and verifies `/v1/models` before writing the channel server `.env`. It asks
before changing Hermes config, backs up an existing Hermes `.env`, and can start
`hermes gateway` after asking permission. For non-standard Hermes paths, it asks
you to start your custom Hermes gateway yourself before it retries the model
check, so it does not accidentally start the wrong instance. Manual Hermes
URL/token entry remains available for custom deployments.

For non-standard Hermes layouts, set these before running the installer:

```bash
HERMES_AGENT_ENV_FILE=/path/to/.env
HERMES_AGENT_CONFIG_PATH=/path/to/config.yaml
HERMES_AGENT_STATE_DB=/path/to/state.db
HERMES_AGENT_MEMORIES_PATH=/path/to/memories
```

Manual setup:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python server.py
```

Required configuration:

```env
HERMES_API_URL=http://127.0.0.1:8642
HERMES_INTERFACE_HOST=0.0.0.0
HERMES_INTERFACE_KEY=<generate-a-long-random-token>
```

Set `HERMES_API_KEY` only if the local Hermes API server requires bearer auth.

## Optional Voice Picker Metadata

Hermes owns the active TTS provider and provider credentials. When the iOS app
requests Hermes voices, the channel server reads current Hermes configuration
and dynamically builds the picker response. Some Hermes TTS providers do not
publish a selectable voice list, though. In those cases, the server can also
read optional fallback metadata from its own file without modifying Hermes:

```env
HERMES_VOICE_INVENTORY_PATH=~/.hermes-ios-channel/data/voice-inventory.json
```

The file may contain static voices:

```json
{
  "providers": {
    "pocket": {
      "voice_env": "POCKET_VOICE",
      "voices": [
        { "id": "example-voice", "name": "Example Voice" }
      ]
    }
  }
}
```

or point to a provider/voice-server helper:

```json
{
  "providers": {
    "edge": {
      "voices_url": "http://127.0.0.1:8766/voices"
    }
  }
}
```

Helper responses can be either `["voice-id"]`,
`[{"id":"voice-id","name":"Voice Name"}]`, or `{"voices":[...]}`.
Command providers that need an environment variable override must set
`voice_env`, unless the variable can be inferred from the command. For example,
`POCKET_VOICE=paul ...` lets the channel infer `POCKET_VOICE`.

The installer creates an empty fallback file and points the server at it. No
separate voice setup is required.

## Health Check

```bash
curl http://127.0.0.1:3001/api/health
```

For remote iOS access, include the interface key:

```bash
curl -H "Authorization: Bearer $HERMES_INTERFACE_KEY" \
  http://your-server:3001/api/chats
```

## Readiness Check

With the channel server running:

```bash
python readiness_check.py
```

This checks the channel health, Hermes-backed model discovery, and channel
capabilities. It fails if Hermes does not report at least one brain/chat model.
Hermes TTS is preferred when advertised; otherwise the report expects the iOS
app to use Apple/on-device voice fallback.

To send one tiny prompt through Hermes, opt in explicitly:

```bash
python readiness_check.py --run-smoke
```

## Optional Hermes Plugin

`hermes-plugins/toolset-override/` can be copied into the Hermes plugin
directory when per-request toolset overrides are needed. Without it, Hermes
falls back to its global/default tool settings.
