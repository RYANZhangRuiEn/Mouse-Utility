#!/bin/zsh
set -eu
PROMO_ROOT="${0:A:h}"
mkdir -p "$PROMO_ROOT/module-cache"
swiftc -O -swift-version 5 -framework AppKit -framework AVFoundation -framework VideoToolbox -framework CoreText -module-cache-path "$PROMO_ROOT/module-cache" "$PROMO_ROOT/Promo.swift" -o "$PROMO_ROOT/render"
"$PROMO_ROOT/render" "$PROMO_ROOT" "$PROMO_ROOT/film-silent.mp4"
"${PYTHON:-python3}" "$PROMO_ROOT/music.py"
swiftc -O -swift-version 5 -framework AVFoundation -framework ImageIO -module-cache-path "$PROMO_ROOT/module-cache" "$PROMO_ROOT/Finish.swift" -o "$PROMO_ROOT/finish"
"$PROMO_ROOT/finish" "$PROMO_ROOT" "$PROMO_ROOT/MouseRing-1.0-Preview-Promo-1080p60.mp4"
