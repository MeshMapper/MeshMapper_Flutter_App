#!/bin/bash

# MeshMapper iOS upload script
# Uploads the Xcode archive produced by Build.sh (flutter build ipa) to
# App Store Connect using an ASC API key, via xcodebuild -exportArchive
# with ios/ExportOptionsUpload.plist (destination: upload).
#
# Auth: expects ASC_KEY_ID and ASC_ISSUER_ID (optionally ASC_KEY_PATH) in the
# environment or ~/.meshmapper_release.env. The .p8 key lives at
# ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 by default.
#
# Fallback if a future Xcode breaks this path (altool is deprecated but still ships):
#   xcrun altool --upload-app -f <ipa> -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
#
# Usage: ./upload_ios.sh [path/to/Runner.xcarchive]

set -e

cd "$(dirname "$0")"

# Local release secrets (optional, never committed; lives outside the repo)
RELEASE_ENV="$HOME/.meshmapper_release.env"
if [ -f "$RELEASE_ENV" ]; then
    source "$RELEASE_ENV"
fi

if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ]; then
    echo "Error: ASC_KEY_ID and ASC_ISSUER_ID must be set (env or $RELEASE_ENV)."
    echo "Create an App Store Connect API key under Users and Access > Integrations."
    exit 1
fi

ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
if [ ! -f "$ASC_KEY_PATH" ]; then
    echo "Error: API key file not found: $ASC_KEY_PATH"
    echo "Download the .p8 from App Store Connect and place it there (chmod 600)."
    exit 1
fi

# Archive path: argument > .last_build metadata > default flutter output location
ARCHIVE_PATH="$1"
if [ -z "$ARCHIVE_PATH" ] && [ -f .last_build ]; then
    ARCHIVE_PATH=$(grep '^ARCHIVE_PATH=' .last_build | cut -d= -f2-)
fi
ARCHIVE_PATH="${ARCHIVE_PATH:-build/ios/archive/Runner.xcarchive}"
if [ ! -d "$ARCHIVE_PATH" ]; then
    echo "Error: No archive at $ARCHIVE_PATH - run ./Build.sh first."
    exit 1
fi

echo "Uploading $ARCHIVE_PATH to App Store Connect..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist ios/ExportOptionsUpload.plist \
    -exportPath build/ios/upload \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo ""
echo "Upload accepted. The build appears in TestFlight after Apple-side processing (~5-15 min)."
