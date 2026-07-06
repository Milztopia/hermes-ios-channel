<p align="center">
  <img src="hermes-ios/HermesApp/Resources/Assets.xcassets/AppLogo.imageset/AppLogo-1024.png" alt="Hermes Mobile logo" width="220">
</p>

<h1 align="center">Hermes Mobile — iOS Channel for Hermes</h1>

<p align="center">
  Talk to your own Hermes agent from your iPhone — by text or by voice.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/platform-iOS%2018%2B-lightgrey.svg" alt="iOS 18+">
  <img src="https://img.shields.io/badge/status-v0.1%20Beta-orange.svg" alt="v0.1 Beta">
</p>

---

Hermes Mobile is a new communication channel for the
[Hermes Agent](https://hermes-agent.nousresearch.com) ecosystem: a native
SwiftUI iPhone app plus a lightweight FastAPI channel server that connects to
your existing Hermes installation. Your models, tools, memory, and provider
keys stay in Hermes — the app adapts to whatever your Hermes install exposes,
whether that's cloud-based or local models.

```text
iPhone app  ->  Hermes iOS Channel Server  ->  your existing Hermes API server
```

## Features

- **Native iOS chat** — SwiftUI app with streaming responses, Markdown
  rendering, syntax-highlighted code blocks, image attachments, and a tool-use
  timeline for watching the agent work.
- **Hands-free voice mode** — on-device speech-to-text (Whisper), spoken
  replies through Hermes TTS, on-device Kokoro, or Apple voices, with live
  word-level karaoke highlighting.
- **Your models, your rules** — the model picker is derived from what your
  Hermes install advertises. Cloud or local, it's whatever you configured in
  Hermes. Nothing is hardcoded to any provider.
- **Shared sessions** — chats live in the same Hermes session store used by
  your other Hermes channels, so conversations stay consistent across surfaces.
- **Self-hosted and private** — no third-party telemetry, analytics, or hosted
  middleman. The channel server runs on your machine next to Hermes.

## Screenshots

Screenshots are coming with the next release. (They will live in
`docs/screenshots/` — chat, voice mode, model picker, and settings.)

## How It Works

The iOS app talks to the channel server over HTTP/SSE. The channel server
stores iOS chat/project UI state, proxies runs to the existing Hermes API
server, and reads Hermes configuration, memory, tools, and state from the
installed Hermes environment.

For a typical local install, you configure only:

- the server URL shown to the iOS app;
- the generated interface API key;
- the local Hermes API URL, usually `http://127.0.0.1:8642`.

Hermes provider keys, brain model, voice model, tools, and runtime routing stay
in Hermes. This channel does not configure alternate or backup providers.

See [INFRASTRUCTURE.md](INFRASTRUCTURE.md) for the full data-flow and storage
map.

## Requirements

- A working Hermes API server.
- At least one Hermes brain/chat model. This is required.
- Voice is preferred through Hermes TTS when Hermes advertises it. If Hermes
  voice is unavailable, the iOS app can use Apple/on-device speech instead.
- Image generation is optional and disabled unless Hermes exposes it.
- To build the iOS app: a Mac with Xcode 16+ and an Apple Developer account.

## Server Setup

Recommended:

```bash
curl -fsSL https://raw.githubusercontent.com/Milztopia/hermes-ios-channel/current/install.sh | bash
```

This downloads the `current` public release, then runs the server installer.

If you cloned the repository instead, run:

```bash
./install-server.sh
```

The installer supports macOS and Linux. It checks dependencies, asks before
changing anything, and offers a full rollback if the install fails or is
abandoned. It copies the channel server to `~/.hermes-ios-channel` by default,
keeps a local source copy in `~/.hermes-ios-channel/source`, creates a Python
virtual environment, generates `HERMES_INTERFACE_KEY`, and can optionally
install a user service (`launchd` on macOS, `systemd --user` on Linux).

For a normal local Hermes install, the installer detects `~/.hermes/.env`,
enables the Hermes API server if needed, generates a Hermes API key if needed,
and checks that Hermes reports at least one brain/chat model. It asks before
changing Hermes config and creates a timestamped backup before editing an
existing Hermes `.env` file. If Hermes is configured but not running, the
installer can start `hermes gateway` after asking permission. For non-standard
Hermes paths, it asks you to start your custom Hermes gateway yourself before it
retries the model check, so it does not accidentally start the wrong instance.

Advanced users can decline auto-detection and enter a custom Hermes API URL and
token manually. Non-standard Hermes installs can also set:

```bash
HERMES_AGENT_ENV_FILE=/path/to/.env
HERMES_AGENT_CONFIG_PATH=/path/to/config.yaml
HERMES_AGENT_STATE_DB=/path/to/state.db
HERMES_AGENT_MEMORIES_PATH=/path/to/memories
```

Manual setup is also supported:

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python server.py
```

Edit `.env` before running in production. At minimum, set:

```env
HERMES_API_URL=http://127.0.0.1:8642
HERMES_INTERFACE_HOST=0.0.0.0
HERMES_INTERFACE_KEY=<generate-a-long-random-token>
```

The server defaults to port `3001`. Check it with:

```bash
curl http://127.0.0.1:3001/api/health
```

## Connecting Your iPhone

For iPhone access, bind the channel server to `0.0.0.0` and connect using a
secure path to your machine. **[Tailscale](https://tailscale.com) (or another
VPN/HTTPS tunnel) is the preferred approach** — it gives your phone a stable,
encrypted route to the server from anywhere without exposing a port to the
internet. Plain LAN addresses (e.g. `http://192.168.1.10:3001`) work at home.
Avoid forwarding the port directly to the public internet.

The installer prints the generated interface API key for the iOS app.

## iOS App

After the server install completes, the installer asks how you want to use the
iOS app:

- download it from the Apple App Store, when available;
- build it locally with Xcode and an Apple Developer account;
- skip iOS setup for now.

To build locally:

1. Fetch the on-device speech model (~147 MB, one time):

   ```bash
   ./hermes-ios/fetch-models.sh
   ```

2. Open `hermes-ios/HermesApp.xcodeproj` in Xcode.
3. Select your own team under Signing & Capabilities, then build and run on
   your device. Apple signing, provisioning, and device deployment follow
   Apple's standard developer workflow.

On first launch, enter:

- **Server URL** — the URL of your channel server, for example your Tailscale
  address (`http://your-machine.tailnet-name.ts.net:3001`) or a LAN address.
- **API key** — the value of `HERMES_INTERFACE_KEY`.

The app stores these connection settings on-device.

The App Store link is configured at release time. If the release does not have
an App Store build yet, choose the local build or skip option.

## Status

This is a Beta intended for developers comfortable running Hermes locally. App
Store distribution and complete iOS capability-driven UI polish are still in
progress.

## Connect

- **Bugs and feature requests** — open a
  [GitHub Issue](https://github.com/Milztopia/hermes-ios-channel/issues).
- **Questions and ideas** —
  [GitHub Discussions](https://github.com/Milztopia/hermes-ios-channel/discussions).
- **Security reports** — see [SECURITY.md](SECURITY.md).
- **Privacy** — see [PRIVACY.md](PRIVACY.md).

## Credits

- [Hermes Agent](https://hermes-agent.nousresearch.com) by Nous Research — the
  agent runtime this channel connects to.
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT) with the
  `openai/whisper-base` CoreML conversion from
  [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml).
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui),
  [Highlightr](https://github.com/raspu/Highlightr),
  [mlx-swift](https://github.com/ml-explore/mlx-swift), and
  [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift).
- The bundled "thinking" audio loop
  (`Tek_xmg_OPEN-CHANNEL_short_1.m4r`) is of unknown origin; we were unable to
  trace its author. If you are the rights holder, open an issue and it will be
  credited or removed immediately.

## License

[MIT](LICENSE) — the whole repository, except where the Credits section notes
otherwise.
