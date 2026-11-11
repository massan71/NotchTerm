#!/bin/bash
# Rigenera l'icona: disegna il PNG 1024×1024 e ne ricava Resources/AppIcon.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SET="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$SET")"' EXIT
mkdir -p "$SET"
swift "$ROOT/scripts/make-icon.swift" "$ROOT/Resources/AppIcon.png"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/Resources/AppIcon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ROOT/Resources/AppIcon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "✓ Resources/AppIcon.icns"
