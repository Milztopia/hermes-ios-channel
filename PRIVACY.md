# Privacy

Hermes iOS Channel is designed to connect your iPhone to an existing Hermes
installation that you control.

The iOS channel server stores iOS-visible chat and project metadata locally in
its configured SQLite database. It also reads Hermes state, memory, and config
paths that you provide during setup so the iOS app can show the same Hermes
context as your existing installation.

The channel server does not add third-party model providers, telemetry, hosted
analytics, or backup AI services. Provider keys, brain model routing, voice
configuration, tools, and memory remain managed by Hermes.

When using the app over LAN, VPN, Tailscale, or HTTPS, protect the generated
`HERMES_INTERFACE_KEY`. Anyone with network access to the channel server and
that key can use the iOS channel API.
