#!/bin/zsh
# Feature screenshots on a transparent background → shots/<scenario>.png
#   Tools/capture.sh                 all scenarios
#   Tools/capture.sh gpu confirm     just these
# Options via env: SHADOW=0 (no drop shadow), ICON=0 (panel only),
# ICON_BLACK=1 (flame in black, for light backgrounds; default is white as on
# a dark menu bar).
# Needs build/HeatWatch.app (./build.sh) and Screen Recording permission for
# the terminal running this.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/HeatWatch.app/Contents/MacOS/HeatWatch
[[ -x $APP ]] || { echo "build first: ./build.sh"; exit 1; }
mkdir -p shots .build
swiftc -O Tools/shoot.swift -o .build/shoot 2>&1 | grep -v warning || true

SCENARIOS=("$@")
(( ${#SCENARIOS[@]} )) || SCENARIOS=(cpu memory gpu expanded confirm)
FLAGS=()
[[ "${SHADOW:-1}" == 0 ]] && FLAGS+=(--no-shadow)
[[ "${ICON:-1}" == 0 ]] && FLAGS+=(--no-icon)
[[ "${ICON_BLACK:-0}" == 1 ]] && FLAGS+=(--icon-black)

WAS_RUNNING=$(pgrep -x HeatWatch || true)
for s in "${SCENARIOS[@]}"; do
  pkill -x HeatWatch 2>/dev/null || true
  sleep 0.6
  HEATWATCH_CAPTURE=$s "$APP" >/dev/null 2>&1 &
  sleep 4.5                       # 1 s baseline + first sample + scene applied
  .build/shoot "shots/$s.png" "${FLAGS[@]}"
  pkill -x HeatWatch 2>/dev/null || true
done
sleep 0.6
[[ -n "$WAS_RUNNING" ]] && open build/HeatWatch.app
echo "done → shots/"
