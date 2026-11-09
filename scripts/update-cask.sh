#!/bin/bash
# Aggiorna versione e sha256 del cask nel tap massan71/homebrew-notchterm.
# Uso: TAP_TOKEN=... scripts/update-cask.sh 0.3.0 <sha256>
# Senza TAP_TOKEN usa le credenziali git già configurate (es. in locale con gh).
set -euo pipefail
VERSION="$1"
SHA256="$2"
TAP="massan71/homebrew-notchterm"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -n "${TAP_TOKEN:-}" ]; then
    URL="https://x-access-token:${TAP_TOKEN}@github.com/${TAP}.git"
else
    URL="https://github.com/${TAP}.git"
fi
git clone --quiet --depth 1 "$URL" "$WORK/tap"
CASK="$WORK/tap/Casks/notchterm.rb"

sed -i '' -E "s/^  version \".*\"/  version \"${VERSION}\"/; s/^  sha256 \".*\"/  sha256 \"${SHA256}\"/" "$CASK"

cd "$WORK/tap"
if git diff --quiet; then
    echo "Cask già aggiornato alla $VERSION"
    exit 0
fi
git -c user.name="NotchTerm CI" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -am "notchterm $VERSION"
git push --quiet origin HEAD
echo "✓ Cask aggiornato a $VERSION"
