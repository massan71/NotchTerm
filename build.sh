#!/bin/bash
# Compila NotchTerm.app con i soli Command Line Tools (niente Xcode).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/build/NotchTerm.app"

# ARCH=universal (default) compila arm64 + x86_64; ARCH=arm64 o ARCH=x86_64 una sola.
ARCH="${ARCH:-universal}"
if [ "$ARCH" = "universal" ]; then SLICES=(arm64 x86_64); else SLICES=("$ARCH"); fi

cd "$ROOT"
OBJ="$(mktemp -d)"
for slice in "${SLICES[@]}"; do
    echo "→ $slice"
    TRIPLE="${slice}-apple-macosx13.0"
    swift build -c release --triple "$TRIPLE"
    # Le architetture condividono la cartella di output: si copia subito.
    cp "$(swift build -c release --triple "$TRIPLE" --show-bin-path)/NotchTerm" "$OBJ/NotchTerm-$slice"
done
BIN="$OBJ/NotchTerm"
lipo -create "$OBJ"/NotchTerm-* -output "$BIN"

# Il bundle si assembla e si firma fuori da ~/Documents: se la cartella è
# sincronizzata con iCloud, il sistema aggiunge attributi che codesign rifiuta.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$OBJ"' EXIT
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
