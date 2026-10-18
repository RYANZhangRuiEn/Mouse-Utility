#!/bin/zsh
set -eu
ROOT="${0:A:h}"
mkdir -p "$ROOT/build/module-cache" "$ROOT/build/previews"
SOURCES=("$ROOT"/Sources/*.swift)
SOURCES=("${(@)SOURCES:#*/main.swift}")
for suite in SmoothChecks MouseChecks RecorderChecks UpgradeChecks Preview; do
  xcrun swiftc -swift-version 5 -O -whole-module-optimization -module-cache-path "$ROOT/build/module-cache" -framework IOKit -framework AppKit -framework Carbon -framework CoreAudio -framework AudioToolbox -framework ApplicationServices "${SOURCES[@]}" "$ROOT/$suite/main.swift" -o "$ROOT/build/$suite"
  if [[ "$suite" = Preview ]]; then "$ROOT/build/$suite" "$ROOT/build/previews" --preview; else "$ROOT/build/$suite"; fi
done
