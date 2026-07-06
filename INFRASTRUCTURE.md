# Hermes iOS Channel Infrastructure

This document describes how the iOS app, channel server, local storage, and
Hermes runtime work together in `v0.1 Beta`.

## System Map

```text
                          User's iPhone
       +-----------------------------------------------------+
       | Hermes iOS app                                      |
       |                                                     |
       |  SwiftUI views                                      |
       |      |                                              |
       |      v                                              |
       |  ChatStore      SettingsStore      VoiceCoordinator |
       |      |              |                    |          |
       |      |              |                    +- Apple TTS|
       |      |              |                    +- Kokoro   |
       |      |              |                    +- Whisper  |
       |      |              |                               |
       |      +--------------+----------+                    |
       |                                 v                    |
       |                         HermesClient                |
       |                                 |                    |
       |  Device-local storage           |                    |
       |  - UserDefaults                 |                    |
       |                                 |                    |
       +---------------------------------+--------------------+
                                         | HTTP/SSE
                                         | Authorization: Bearer
                                         v
                    LAN / VPN / Tailscale / HTTPS
                                         |
                                         v
       +-----------------------------------------------------+
       | Hermes iOS Channel Server                           |
       | FastAPI, usually :3001                              |
       |                                                     |
       |  /api/chats, /api/projects, /api/chats/*/messages   |
       |      |                                              |
       |      v                                              |
       |  Channel SQLite DB                                  |
       |  HERMES_INTERFACE_DB or data/chats.db               |
       |                                                     |
       |  /api/ui-settings -------> data/ui-settings.json    |
       |  /api/memory ------------> ~/.hermes/memories       |
       |  /api/tools -------------> ~/.hermes/config.yaml    |
       |  /api/hermes-file/* -----> ~/.hermes/cache/files    |
       |  /api/hermes-img/* ------> ~/.hermes/cache/images   |
       |                                                     |
       |  /api/models, /api/channel-capabilities             |
       |  /api/tts, /api/transcribe                          |
       |  /api/v1/* proxy                                    |
       +---------------------------------+-------------------+
                                         | HTTP/SSE
                                         v
       +-----------------------------------------------------+
       | Existing Hermes API server                          |
       | HERMES_API_URL, usually http://127.0.0.1:8642       |
       |                                                     |
       |  /v1/models                                         |
       |  /v1/capabilities                                   |
       |  /v1/runs                                           |
       |  /v1/runs/{id}/events                               |
       |                                                     |
       |  Hermes owns:                                       |
       |  - provider keys                                    |
       |  - brain/chat model routing                         |
       |  - TTS/STT/image capability                         |
       |  - tools and tool execution                         |
       |  - canonical session state                          |
       +-----------------------------------------------------+
```

## Ownership Boundaries

```text
+---------------------+----------------------------------------------+
| Component           | Owns                                         |
+---------------------+----------------------------------------------+
| iOS app             | UI state in memory, connection settings,      |
|                     | device-local voice/tool preferences           |
+---------------------+----------------------------------------------+
| Channel server      | iOS chat/project metadata, iOS-rendered       |
|                     | message snapshots, share snapshots, UI prefs  |
+---------------------+----------------------------------------------+
| Hermes API/server   | model providers, model defaults, tools,       |
|                     | memory, canonical runs, canonical sessions    |
+---------------------+----------------------------------------------+
| Hermes filesystem   | ~/.hermes/state.db, ~/.hermes/config.yaml,    |
|                     | ~/.hermes/memories, ~/.hermes/cache/*         |
+---------------------+----------------------------------------------+
```

The iOS app does not embed a local chat database. It keeps chat lists and
messages in memory while running, then loads/saves them through the channel
server.

## Storage

### iOS Device

```text
iOS UserDefaults
+- hermes.serverURL
+- hermes.apiKey
+- hermes.ttsEngine
+- hermes.sttEngine
+- hermes.onDeviceVoiceId
+- hermes.kokoroVoice
+- hermes.enabledTools
+- hermes.chatToolsetOverride
+- hermes.chatBargeInPreference

iOS memory only
+- ChatStore.chats
+- ChatStore.projects
+- ChatStore.messages
+- active draft chats
+- active streaming/run state
```

Device-local settings stay on the phone because they depend on that device:
server URL, channel API key, Apple voice, on-device voice engine choice,
microphone gate, per-chat voice preference, and local tool toggles.

### Channel Server

```text
server/.env
+- HERMES_API_URL
+- HERMES_API_KEY
+- HERMES_INTERFACE_HOST
+- HERMES_INTERFACE_PORT
+- HERMES_INTERFACE_KEY
+- HERMES_INTERFACE_DB
+- HERMES_STATE_DB
+- HERMES_MEMORIES_PATH
+- HERMES_CONFIG_PATH

HERMES_INTERFACE_DB, default data/chats.db
+- ui_projects
+- ui_chats
+- ui_messages
+- ui_shares

data/ui-settings.json
+- synced UI settings used by the iOS app
```

The server is the durable store for iOS chat/project metadata and iOS-rendered
message snapshots. It also reads Hermes `state.db` and appends missing canonical
conversation tail messages, so conversations created by other Hermes clients can
surface in the iOS app.

### Existing Hermes Install

```text
~/.hermes/
+- state.db              canonical Hermes sessions and run history
+- config.yaml           toolset/platform configuration
+- memories/
|  +- USER.md
|  +- MEMORY.md
+- cache/
   +- files/
   +- images/
```

Hermes remains the source of truth for provider keys, model routing, runtime
tools, memories, and canonical run/session history.

## Main Data Flows

### 1. First Launch And Connection

```text
iOS user enters server URL + channel key
        |
        v
SettingsStore writes UserDefaults
        |
        v
HermesClient GET /api/chats
        |
        v
Channel server verifies HERMES_INTERFACE_KEY
        |
        v
Connection marked connected
```

The channel key protects the channel server. It is separate from any Hermes API
key used by the channel server when it calls Hermes.

### 2. Chat List Load

```text
iOS ChatStore.loadAll()
        |
        +- GET /api/chats
        |      |
        |      +- read ui_chats from channel SQLite
        |      +- read Hermes state.db sessions
        |      +- merge/sort chats for iOS sidebar
        |
        +- GET /api/projects
               |
               +- read ui_projects from channel SQLite
```

The merged chat list can include:

- chats created from iOS and stored in `ui_chats`;
- existing Hermes sessions synthesized from `state.db`;
- iOS metadata overlays for Hermes sessions that were later pinned, renamed, or
  archived in the app.

### 3. New Chat And First Message

```text
Tap New Chat
        |
        v
ChatStore creates a local in-memory draft
        |
        +- if abandoned empty: discard locally
        |
        +- if first message is sent:
              |
              v
          POST /api/chats
              |
              v
          insert ui_chats row
              |
              v
          POST /api/v1/runs
              |
              v
          proxy to Hermes /v1/runs
```

Empty draft chats are never persisted. The server receives a chat only after the
first real message.

### 4. Run Streaming

```text
iOS app
  POST /api/v1/runs
        |
        v
Channel server
  forwards request to HERMES_API_URL/v1/runs
        |
        v
Hermes API server
  creates run/session and starts model/tool work
        |
        v
iOS app
  GET /api/v1/runs/{run_id}/events
        |
        v
Channel server streams upstream SSE bytes
        |
        v
Hermes API server /v1/runs/{run_id}/events
```

During streaming, the iOS app:

- adds the user message locally;
- adds a streaming assistant message locally;
- coalesces token deltas to reduce UI churn;
- renders tool events, approvals, source cards, and sent-file cards from SSE;
- finalizes the message when the run completes;
- saves the stable message list back to the channel server.

### 5. Message Persistence

```text
Run completes
        |
        v
ChatStore.persistMessages()
        |
        v
POST /api/chats/{chat_id}/messages
        |
        v
Server INSERT OR REPLACE ui_messages rows
        |
        v
GET /api/chats/{chat_id}/messages later
        |
        +- load ui_messages from channel SQLite
        +- resolve Hermes session id
        +- read Hermes state.db rows
        +- append missing canonical tail
```

The channel DB stores the iOS-rendered message shape, including UI attachments
such as source cards and file cards. Hermes `state.db` stores the canonical
conversation/run transcript.

### 6. Models And Capabilities

```text
iOS Settings
   |
   +- GET /api/models
   |      +- Channel server calls Hermes /v1/models
   |
   +- GET /api/channel-capabilities
          +- Channel server calls Hermes /v1/models
          +- Channel server calls Hermes /v1/capabilities
```

Brain/chat model availability is required. Hermes TTS/STT/image capability is
detected from Hermes. If Hermes TTS is not advertised, the iOS app can use
Apple/on-device TTS. If Hermes STT is not advertised, the iOS app can use its
on-device Whisper path.

### 7. Voice Paths

```text
Speech input
+- iOS on-device STT
|    microphone -> WhisperService -> text -> normal run flow
|
+- Hermes STT
     microphone -> WAV bytes -> POST /api/transcribe
       -> Hermes advertised STT endpoint -> transcript -> normal run flow

Speech output
+- Apple TTS
|    assistant text -> AVSpeechSynthesizer
|
+- iOS Kokoro TTS
|    assistant text -> KokoroService/MLXAudio -> audio samples
|
+- Hermes TTS
     assistant text -> POST /api/tts
       -> Hermes advertised TTS endpoint -> audio bytes -> playback
```

Voice engine selection is device-local. Hermes voice remains preferred when
Hermes advertises TTS; local iOS speech is the fallback.

### 8. Tools

```text
iOS Tools screen
        |
        +- GET /api/tools
        |      +- import Hermes tool inventory
        |      +- read platform_toolsets.api_server from config.yaml
        |
        +- PUT /api/tools
               +- write platform_toolsets.api_server to config.yaml

Per-chat override
        |
        v
StartRunRequest.tools + enabled_toolsets
        |
        v
Hermes gateway injects only selected tool schemas
```

The optional `toolset-override` plugin lets Hermes honor per-request
`enabled_toolsets`. Without it, Hermes falls back to the global/default tool
configuration.

### 9. Memory

```text
iOS Memory settings
        |
        +- GET /api/memory
        |      +- read USER.md
        |      +- read MEMORY.md
        |
        +- PUT /api/memory
               +- validate length limits
               +- write USER.md
               +- write MEMORY.md
```

The channel edits the existing Hermes memory files. It does not maintain a
separate iOS-only memory store.

### 10. Files, Images, Links, And Shares

```text
PDF extraction
  iOS PDF bytes -> /api/extract-pdf -> temporary server file -> extracted text

Link preview
  iOS URL -> /api/link-preview -> SSRF-guarded metadata fetch -> cached result

Hermes sent file
  SSE file event -> iOS card -> /api/hermes-file/{id} -> ~/.hermes/cache/files

Hermes image file
  iOS markdown/image URL -> /api/hermes-img/{file} -> ~/.hermes/cache/images

Share link
  POST /api/chats/{chat_id}/share
       -> snapshot ui_messages into ui_shares
       -> GET /share/{token} renders static HTML
```

Image generation is currently optional. The channel returns unavailable unless
Hermes exposes image generation as a capability.

## Authentication And Network Boundary

```text
iOS app
  Authorization: Bearer HERMES_INTERFACE_KEY
        |
        v
Channel server
  validates channel key for /api/* routes
        |
        +- uses HERMES_API_KEY if configured
        +- otherwise forwards cleaned client bearer to Hermes
        |
        v
Hermes API server
```

The channel server can bind to `0.0.0.0` so an iPhone can reach it over LAN, VPN,
Tailscale, or HTTPS. Anyone with network access to the server and the interface
key can use the channel API.

## Failure And Fallback Behavior

```text
Hermes API unavailable
+- /api/v1/* proxy returns 503 or 504

Hermes state.db unavailable
+- chat history falls back to channel SQLite only

Hermes TTS unavailable
+- iOS can use Apple or on-device Kokoro TTS

Hermes STT unavailable
+- iOS can use on-device Whisper STT

Hermes image unavailable
+- image endpoint returns 503; text chat still works

View disappears during message load
+- ChatStore-owned load task continues independently of SwiftUI view lifecycle
```

## Public Repo Package

The public `v0.1 Beta` export contains only:

```text
.
+- README.md
+- INFRASTRUCTURE.md
+- LICENSE
+- SECURITY.md
+- PRIVACY.md
+- install-server.sh
+- hermes-ios/
+- server/
```

It intentionally excludes private Alpha web/mac apps, local `.env` files,
runtime data, local deployment notes, and large model weights.
