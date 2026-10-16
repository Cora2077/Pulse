#!/usr/bin/env bash
# Build/test/run only an iPhone simulator. Never installs on a physical device,
# signs with a paid account, or changes the daily Mac application.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---build}"
if [[ $# -gt 0 ]]; then shift; fi
DEMO=0
if [[ "${1:-}" == "--demo" ]]; then DEMO=1; shift; fi
if [[ $# -gt 0 ]]; then echo 'Usage: scripts/dev-ios.sh [--build|--run|--test] [--demo]' >&2; exit 2; fi
case "$MODE" in --build|--run|--test) ;; *) echo 'Unknown iOS development mode.' >&2; exit 2 ;; esac

if [[ -n "${DSH_PROGRESS_CLI:-}" && "${PULSE_IOS_PROGRESS_CHILD:-0}" != 1 ]]; then
  PROGRESS_ARGS=("$MODE")
  if [[ "$DEMO" == 1 ]]; then PROGRESS_ARGS+=(--demo); fi
  exec node "$DSH_PROGRESS_CLI" run --task iphone-dev -- env PULSE_IOS_PROGRESS_CHILD=1 "$ROOT_DIR/scripts/dev-ios.sh" "${PROGRESS_ARGS[@]}"
fi
if [[ -z "${DEVELOPER_DIR:-}" ]]; then export DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'; fi
[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || { echo 'A full Xcode installation is required.' >&2; exit 1; }
DERIVED_DATA="$ROOT_DIR/build/iOSDerivedData"
DEVICE_ID="${PULSE_IOS_SIMULATOR_UDID:-}"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); p=[x for a in d["devices"].values() for x in a if x.get("isAvailable") and x["name"].startswith("iPhone")]; print(next((x["udid"] for x in p if x["state"]=="Booted"),p[0]["udid"] if p else ""))')"
fi
[[ -n "$DEVICE_ID" ]] || { echo 'No available iPhone simulator runtime.' >&2; exit 1; }
PULSE_VALIDATION_DEVICE="$DEVICE_ID" xcrun simctl list devices available -j | PULSE_VALIDATION_DEVICE="$DEVICE_ID" python3 -c 'import json,os,sys; d=json.load(sys.stdin); assert any(x["udid"]==os.environ["PULSE_VALIDATION_DEVICE"] and x["name"].startswith("iPhone") for a in d["devices"].values() for x in a), "Expected an existing iPhone simulator id"'

cd "$ROOT_DIR"
xcodegen generate
ARGS=(-project Pulse.xcodeproj -scheme PulseIOS -configuration Debug -destination "platform=iOS Simulator,id=$DEVICE_ID" -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES)
if [[ "$MODE" == '--test' ]]; then
  exec xcodebuild "${ARGS[@]}" test
fi
xcodebuild "${ARGS[@]}" build
if [[ "$MODE" == '--run' ]]; then
  STATE="$(xcrun simctl list devices available -j | PULSE_VALIDATION_DEVICE="$DEVICE_ID" python3 -c 'import json,os,sys; d=json.load(sys.stdin); print(next(x["state"] for a in d["devices"].values() for x in a if x["udid"]==os.environ["PULSE_VALIDATION_DEVICE"]))')"
  if [[ "$STATE" != Booted ]]; then xcrun simctl boot "$DEVICE_ID"; fi
  xcrun simctl bootstatus "$DEVICE_ID" -b
  APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/FFFiPhone.app"
  [[ -d "$APP_BUNDLE" ]] || { echo 'The simulator build is missing.' >&2; exit 1; }
  xcrun simctl install "$DEVICE_ID" "$APP_BUNDLE"
  if [[ "$DEMO" == 1 ]]; then
    xcrun simctl launch --terminate-running-process "$DEVICE_ID" app.pulse.ios.dev --acceptance-demo
  else
    xcrun simctl launch --terminate-running-process "$DEVICE_ID" app.pulse.ios.dev
  fi
fi
