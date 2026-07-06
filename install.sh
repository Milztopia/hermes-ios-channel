#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO="Milztopia/hermes-ios-channel"
DEFAULT_REF="current"

usage() {
  cat <<'USAGE'
Usage:
  curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/current/install.sh | bash

Environment overrides:
  HERMES_IOS_CHANNEL_REPO  GitHub repository, default: Milztopia/hermes-ios-channel
  HERMES_IOS_CHANNEL_REF   Git ref/tag to install, default: current

Downloads the selected repository archive, then runs install-server.sh from it.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

say() {
  printf '%s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    say "Missing required command: $1"
    exit 1
  fi
}

require_cmd curl
require_cmd tar
require_cmd mktemp

repo="${HERMES_IOS_CHANNEL_REPO:-$DEFAULT_REPO}"
ref="${HERMES_IOS_CHANNEL_REF:-$DEFAULT_REF}"
archive_url="https://github.com/$repo/archive/refs/tags/$ref.tar.gz"
tmp_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

say "Downloading Hermes iOS Channel from $repo@$ref..."
curl -fsSL "$archive_url" | tar -xz -C "$tmp_dir"

repo_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
if [[ -z "$repo_dir" || ! -f "$repo_dir/install-server.sh" ]]; then
  say "Downloaded archive did not contain install-server.sh."
  exit 1
fi

# When this script is piped into bash (curl ... | bash), stdin is the exhausted
# script pipe, so the installer's interactive prompts would hit EOF. Reattach
# stdin to the terminal for the interactive installer.
if [[ -t 0 ]]; then
  bash "$repo_dir/install-server.sh" "$@"
elif [[ -r /dev/tty ]]; then
  bash "$repo_dir/install-server.sh" "$@" < /dev/tty
else
  say "No terminal available for interactive prompts."
  say "Download the repository and run ./install-server.sh from a terminal instead."
  exit 1
fi
