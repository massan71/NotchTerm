#!/bin/bash
# Compila NotchTerm.app con i soli Command Line Tools (niente Xcode).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/NotchTerm.app"

cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/NotchTerm"

# Il bundle si assembla e si firma fuori da ~/Documents: se la cartella è
# sincronizzata con iCloud, il sistema aggiunge attributi che codesign rifiuta.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
S="$STAGE/NotchTerm.app"
mkdir -p "$S/Contents/MacOS" "$S/Contents/Resources"
cp "$BIN" "$S/Contents/MacOS/NotchTerm"
cp "$ROOT/Resources/Info.plist" "$S/Contents/Info.plist"
xattr -cr "$S"
# Firma ad-hoc: serve a SMAppService ("Avvia al login") e a Gatekeeper in locale.
codesign --force --sign - "$S"

rm -rf "$APP"
mkdir -p "$ROOT/build"
ditto "$S" "$APP"
echo "✓ $APP"
