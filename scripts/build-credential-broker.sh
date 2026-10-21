#!/bin/bash
# Keep the local-development credential reader's Keychain identity stable.
set -euo pipefail
[[ "$PRODUCT_BUNDLE_IDENTIFIER" == "app.pulse.mac.dev" ]] || exit 0
[[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "$EXPANDED_CODE_SIGN_IDENTITY" != "-" ]] || { echo 'error: credential broker requires the persistent local signer' >&2; exit 1; }
SOURCE="$SRCROOT/scripts/credential-broker/main.swift"
ENTITLEMENTS="$SRCROOT/scripts/credential-broker/entitlements.plist"
SOURCE_HASH="$(cat "$SOURCE" "$ENTITLEMENTS" | shasum -a 256 | awk '{print $1}')"
CACHE="$SRCROOT/.build/credential-broker/$SOURCE_HASH-$EXPANDED_CODE_SIGN_IDENTITY-${ARCHS// /_}"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$CACHE" "$DEST"
# Reuse the installed, sealed helper after a clean build too. The stamp is sealed
# by the enclosing app; also verify the helper's signature against our signer.
INSTALLED="$HOME/Applications/FFF.app"
valid_helper() {
  [[ -f "$1" ]] && lipo -verify_arch $ARCHS "$1" >/dev/null 2>&1 && \
    codesign --verify --strict "$1" >/dev/null 2>&1 && \
    codesign --verify -R="certificate leaf = H\"$EXPANDED_CODE_SIGN_IDENTITY\"" "$1" >/dev/null 2>&1
}
if ! valid_helper "$CACHE/FFFCredentialBroker"; then
  if [[ -f "$INSTALLED/Contents/Resources/credential-broker-source" && "$(cat "$INSTALLED/Contents/Resources/credential-broker-source")" == "$SOURCE_HASH" ]] && \
     codesign --verify --deep --strict "$INSTALLED" >/dev/null 2>&1 && valid_helper "$INSTALLED/Contents/Helpers/FFFCredentialBroker"; then
    cp "$INSTALLED/Contents/Helpers/FFFCredentialBroker" "$CACHE/FFFCredentialBroker"
  else
    PARTS=()
    for ARCH in $ARCHS; do
      xcrun swiftc -O -target "$ARCH-apple-macos14.0" -sdk "$SDKROOT" "$SOURCE" -o "$CACHE/broker-$ARCH"
      PARTS+=("$CACHE/broker-$ARCH")
    done
    lipo -create "${PARTS[@]}" -output "$CACHE/FFFCredentialBroker"
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --identifier app.pulse.credentials.local --entitlements "$ENTITLEMENTS" --timestamp=none "$CACHE/FFFCredentialBroker"
  fi
fi
cp "$CACHE/FFFCredentialBroker" "$DEST/FFFCredentialBroker"
mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
rm -f "$DEST/credential-broker-source"
printf '%s\n' "$SOURCE_HASH" > "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/credential-broker-source"
echo 'Stable local credential broker embedded.'
