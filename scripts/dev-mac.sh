#!/usr/bin/env bash
# Build, run, debug, or verify the local development app.
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
BUNDLE_ID="app.pulse.mac.dev"
CONFIGURATION="Debug"
APP_NAME="FFF"
RELEASE_BUILD=0

# Use a complete Xcode for project builds without changing the machine-wide
# xcode-select setting. CommandLineTools alone exposes xcodebuild but cannot run it.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  ACTIVE_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [[ ! -d "$ACTIVE_DEVELOPER_DIR/Platforms/MacOSX.platform" ]]; then
    for XCODE_DEVELOPER_DIR in \
      "/Applications/Xcode.app/Contents/Developer" \
      "/Applications/Xcode-beta.app/Contents/Developer"
    do
      if [[ -x "$XCODE_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
        break
      fi
    done
  fi
fi

case "$MODE" in
  --release|release|--release-verify|--release-sdk|release-sdk|--release-sdk-verify|--release-settings-persistence-selftest|--release-sdk-live-selftest|--release-sdk-watchlist-selftest|--release-sdk-stability-selftest)
    CONFIGURATION="Release"
    APP_NAME="FFF"
    BUNDLE_ID="app.pulse.mac"
    RELEASE_BUILD=1
    ;;
esac

APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

signing_arguments() {
  local available_identities local_identities identity_line identity identity_hash certificate_subject team_id

  # A development certificate gives Keychain a stable designated requirement across
  # rebuilds. Discover it locally so no developer identity or private key is committed.
  # Keep the local signer first even if an Apple certificate is installed later.
  # A self-signed certificate pins the default requirement to its certificate hash;
  # Keychain continuity does not require adding it to the machine's trusted roots.
  # Accept only the untrusted-root status, never an expired or otherwise invalid key.
  local_identities="$(security find-identity -p codesigning 2>/dev/null || true)"
  identity_line="$(printf '%s\n' "$local_identities" | sed -nE '/^[[:space:]]*[0-9]+\) [[:xdigit:]]{40} "Fight For Free Local Development"( \(CSSMERR_TP_NOT_TRUSTED\))?$/ { p; q; }')"
  available_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ -z "$identity_line" ]]; then
    identity_line="$(printf '%s\n' "$available_identities" | sed -n '/"Apple Development:/ { p; q; }')"
  fi
  if [[ -z "$identity_line" ]]; then
    identity_line="$(printf '%s\n' "$available_identities" | sed -n '/"Developer ID Application:/ { p; q; }')"
  fi
  if [[ -n "$identity_line" ]]; then
    identity="${identity_line#*\"}"
    identity="${identity%%\"*}"
    identity_hash="$(printf '%s\n' "$identity_line" | awk '{print $2}')"
    certificate_subject="$(security find-certificate -c "$identity" -p 2>/dev/null \
      | /usr/bin/openssl x509 -noout -subject 2>/dev/null || true)"
    team_id="$(printf '%s\n' "$certificate_subject" \
      | sed -nE 's/.*OU[ =]+([A-Z0-9]+).*/\1/p')"
    printf '%s\0' "CODE_SIGN_STYLE=Manual" "CODE_SIGN_IDENTITY=$identity_hash" "DEVELOPMENT_TEAM=$team_id"
    return
  fi

  if [[ "${PULSE_ALLOW_AD_HOC:-0}" == "1" ]]; then
    echo 'Warning: explicitly requested ad-hoc signing; use this build for isolated checks only.' >&2
    printf '%s\0' "CODE_SIGN_STYLE=Manual" "CODE_SIGN_IDENTITY=-"
    return
  fi
  echo 'No stable code-signing identity is available. Create an Apple Development certificate in Xcode, or a local code-signing certificate named Fight For Free Local Development.' >&2
  echo 'Refusing to silently use ad-hoc signing: it invalidates remembered Keychain approvals after rebuilds.' >&2
  return 1
}

# Process substitution hides a failed lookup, so capture its exit status first.
SIGNING_ARGUMENTS_FILE=$(mktemp -t fight-for-free-signing)
trap 'rm -f "$SIGNING_ARGUMENTS_FILE"' EXIT
signing_arguments > "$SIGNING_ARGUMENTS_FILE"
SIGNING_ARGS=()
while IFS= read -r -d '' argument; do
  SIGNING_ARGS+=("$argument")
done < "$SIGNING_ARGUMENTS_FILE"

if [[ "$MODE" == "--build" ]]; then
  : # Compile-only checks leave the installed daily app running.
elif [[ "$RELEASE_BUILD" == "1" ]]; then
  # Avoid simultaneous quote connections during an interactive release run.
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "Pulse" >/dev/null 2>&1 || true
  pkill -x "Pulse Dev" >/dev/null 2>&1 || true
  pkill -x "Fight For Free" >/dev/null 2>&1 || true
  pkill -x "Fight For Free Dev" >/dev/null 2>&1 || true
else
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "Fight For Free" >/dev/null 2>&1 || true
  pkill -x "Fight For Free Dev" >/dev/null 2>&1 || true
  pkill -x "Pulse Dev" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
xcodegen generate

XCODE_ARGS=(
  "ENABLE_USER_SCRIPT_SANDBOXING=NO"
)
if [[ "$RELEASE_BUILD" == "1" ]]; then
  XCODE_ARGS+=(
    "ENABLE_HARDENED_RUNTIME=YES"
  )
fi

xcodebuild \
  -project Pulse.xcodeproj \
  -scheme PulseMac \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  TELEMETRYDECK_APP_ID="${TELEMETRYDECK_APP_ID:-}" \
  "${SIGNING_ARGS[@]}" \
  "${XCODE_ARGS[@]}" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --build)
    ;;
  run)
    open_app
    ;;
  --release|release|--release-sdk|release-sdk)
    open_app
    ;;
  --release-verify|--release-sdk-verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --release-sdk-live-selftest)
    "$APP_BINARY" --longbridge-sdk-live-selftest
    ;;
  --release-sdk-watchlist-selftest)
    "$APP_BINARY" --longbridge-sdk-watchlist-selftest
    ;;
  --release-sdk-stability-selftest)
    "$APP_BINARY" --longbridge-sdk-stability-selftest
    ;;
  --release-settings-persistence-selftest)
    "$APP_BINARY" --settings-persistence-selftest
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --reorder-diagnostics-selftest)
    "$APP_BINARY" --reorder-diagnostics-selftest
    ;;
  --longbridge-plugin-state-selftest)
    "$APP_BINARY" --longbridge-plugin-state-selftest
    ;;
  --longbridge-plugin-selftest)
    "$APP_BINARY" --longbridge-plugin-selftest
    ;;
  --longbridge-sdk-live-selftest)
    "$APP_BINARY" --longbridge-sdk-live-selftest
    ;;
  --longbridge-sdk-watchlist-selftest)
    "$APP_BINARY" --longbridge-sdk-watchlist-selftest
    ;;
  --longbridge-sdk-stability-selftest)
    "$APP_BINARY" --longbridge-sdk-stability-selftest
    ;;
  --watchlist-archive-selftest)
    "$APP_BINARY" --watchlist-archive-selftest
    ;;
  --settings-persistence-selftest)
    "$APP_BINARY" --settings-persistence-selftest
    ;;
  --share-selftest)
    "$APP_BINARY" --share-selftest
    ;;
  --watchlist-sort-selftest)
    "$APP_BINARY" --watchlist-sort-selftest
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify|--reorder-diagnostics-selftest|--release|--release-verify|--share-selftest|--watchlist-sort-selftest|--settings-persistence-selftest|--watchlist-archive-selftest|--release-settings-persistence-selftest|--release-sdk-live-selftest|--release-sdk-watchlist-selftest|--release-sdk-stability-selftest|--longbridge-plugin-state-selftest|--longbridge-plugin-selftest|--longbridge-sdk-live-selftest|--longbridge-sdk-watchlist-selftest|--longbridge-sdk-stability-selftest]" >&2
    exit 2
    ;;
esac
