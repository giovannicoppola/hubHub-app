#!/usr/bin/env bash
# Archive HubHub for the App Store and export a signed .ipa.
#
#   ./scripts/archive.sh            # archive + export to build/export/HubHub.ipa
#   ./scripts/archive.sh --upload   # …then upload to App Store Connect
#
# Upload needs an App Store Connect API key in the environment:
#   ASC_KEY_ID, ASC_ISSUER_ID  (and the .p8 in ~/.appstoreconnect/private_keys/)
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHIVE="build/HubHub.xcarchive"
EXPORT_DIR="build/export"

echo "==> Archiving (Release, Any iOS Device)"
xcodebuild -project HubHub.xcodeproj -scheme HubHub \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  archive

echo "==> Exporting for App Store Connect"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

IPA="$(find "$EXPORT_DIR" -name '*.ipa' -maxdepth 1 | head -1)"
echo "==> Exported: $IPA"

if [[ "${1:-}" == "--upload" ]]; then
  : "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
  # altool exits 0 even when validation or upload fails, so its output is
  # the only reliable signal — without this the script announced "Uploaded"
  # over a 409 rejection.
  altool() {
    local log
    log="$(mktemp)"
    xcrun altool "$@" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tee "$log"
    if grep -qE "FAILED|ERROR:" "$log"; then
      rm -f "$log"
      echo "==> altool reported a failure; stopping." >&2
      exit 1
    fi
    rm -f "$log"
  }
  echo "==> Validating"
  altool --validate-app -f "$IPA" -t ios
  echo "==> Uploading"
  altool --upload-app -f "$IPA" -t ios
  echo "==> Uploaded. Processing takes ~5-15 min before the build shows in TestFlight."
fi
