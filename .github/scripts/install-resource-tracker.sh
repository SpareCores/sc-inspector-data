#!/usr/bin/env bash
# Install the latest resource-tracker release binary for the current runner arch.
set -euo pipefail

ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"

curl_auth=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  curl_auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

RELEASE_JSON="$(curl -fsSL "${curl_auth[@]}" \
  https://api.github.com/repos/SpareCores/resource-tracker-rs/releases/latest)"

URL="$(echo "$RELEASE_JSON" | sed -n \
  "s#.*\"browser_download_url\": \"\\([^\"]*resource-tracker-[^\"]*-linux-${ARCH}.tar.gz\\)\".*#\\1#p" \
  | sed -n '1p')"
if [ -z "$URL" ]; then
  echo "install-resource-tracker: no linux-${ARCH} asset in latest release" >&2
  exit 1
fi

VERSION="$(echo "$URL" | sed -n 's#.*/resource-tracker-v\([^-]*\)-linux.*#\1#p')"
DEST="${RUNNER_TOOL_CACHE:-/tmp}/resource-tracker/${VERSION}-${ARCH}"
BIN="${DEST}/resource-tracker"

if [ -x "$BIN" ]; then
  echo "resource-tracker v${VERSION} (${ARCH}) cached at ${BIN}"
else
  mkdir -p "$DEST"
  echo "Downloading resource-tracker v${VERSION} for ${ARCH}"
  curl -fsSL "$URL" | tar -xzf - -C "$DEST" resource-tracker
  chmod +x "$BIN"
fi

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$DEST" >> "$GITHUB_PATH"
fi
echo "resource-tracker=${BIN}"
