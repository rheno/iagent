#!/bin/zsh
# Builds a release binary signed with the hardened runtime.
#   scripts/build-release.sh                          # ad-hoc signature (local use)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-release.sh   # distributable; then notarize:
#   xcrun notarytool submit dist/iagent.zip --keychain-profile <profile> --wait
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
mkdir -p dist
cp .build/release/iagent dist/iagent

identity="${SIGN_IDENTITY:--}"
codesign --force --options runtime --timestamp=none \
  --identifier dev.iagent.cli \
  --entitlements iAgent.entitlements \
  --sign "$identity" dist/iagent
if [[ "$identity" != "-" ]]; then
  codesign --force --options runtime --timestamp --identifier dev.iagent.cli \
    --entitlements iAgent.entitlements --sign "$identity" dist/iagent
  ditto -c -k --keepParent dist/iagent dist/iagent.zip
fi

codesign --verify --strict --verbose=2 dist/iagent
codesign -d --entitlements - --verbose=2 dist/iagent 2>&1 | grep -E "flags|Identifier|automation|personal"
shasum -a 256 dist/iagent
