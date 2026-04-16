#!/bin/bash

# MeshMapper Build Script
# Builds Android APK, Android AAB, and iOS IPA with the same epoch timestamp

set -e  # Exit on any error

# Semver comparison: returns 0 (true) if $1 >= $2
version_gte() {
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<3; i++)); do
        if ((${ver1[i]:-0} > ${ver2[i]:-0})); then return 0; fi
        if ((${ver1[i]:-0} < ${ver2[i]:-0})); then return 1; fi
    done
    return 0
}

# API key - prompt if not set via environment variable
if [ -z "$MESHMAPPER_API_KEY" ]; then
    echo "Enter MeshMapper API key:"
    read -s MESHMAPPER_API_KEY
    if [ -z "$MESHMAPPER_API_KEY" ]; then
        echo "Error: API key is required."
        exit 1
    fi
    echo ""
fi

# Android signing - prompt for passwords if not set
if [ -z "$SIGNING_STORE_PASSWORD" ]; then
    echo "Enter keystore password:"
    read -s SIGNING_STORE_PASSWORD
    export SIGNING_STORE_PASSWORD
fi

if [ -z "$SIGNING_KEY_PASSWORD" ]; then
    echo "Enter key password (or press Enter if same as keystore):"
    read -s SIGNING_KEY_PASSWORD
    if [ -z "$SIGNING_KEY_PASSWORD" ]; then
        SIGNING_KEY_PASSWORD="$SIGNING_STORE_PASSWORD"
    fi
    export SIGNING_KEY_PASSWORD
fi

# Read last version from .build_version
VERSION_FILE="$(dirname "$0")/.build_version"
if [ -f "$VERSION_FILE" ]; then
    LAST_VERSION=$(cat "$VERSION_FILE")
    echo ""
    echo "Current version: $LAST_VERSION"
else
    LAST_VERSION="0.0.0"
    echo ""
    echo "No .build_version found, assuming $LAST_VERSION"
fi

# Generate single epoch for all builds (used as build-number regardless of release type)
EPOCH=$(date +%s)

# Release type prompt
echo ""
echo "Release type?"
echo "  1) Dev  (APP-<epoch>)"
echo "  2) Production  (APP-x.y.z)"
echo ""
read -p "Select [1]: " RELEASE_TYPE
RELEASE_TYPE=${RELEASE_TYPE:-1}

if [ "$RELEASE_TYPE" = "2" ]; then
    # Production build - prompt for version
    while true; do
        read -p "Enter version [$LAST_VERSION]: " VERSION_NUMBER
        VERSION_NUMBER=${VERSION_NUMBER:-$LAST_VERSION}

        # Validate semver format
        if ! [[ "$VERSION_NUMBER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Error: Version must be in X.Y.Z format (e.g. 1.0.0)"
            continue
        fi

        # Validate >= last version
        if ! version_gte "$VERSION_NUMBER" "$LAST_VERSION"; then
            echo "Error: Version must be >= $LAST_VERSION"
            continue
        fi

        break
    done

    # Update .build_version
    echo "$VERSION_NUMBER" > "$VERSION_FILE"

    APP_VERSION="APP-$VERSION_NUMBER"
    FILE_TAG="$VERSION_NUMBER"
else
    # Dev build - prompt for target version
    while true; do
        read -p "Enter target version [$LAST_VERSION]: " VERSION_NUMBER
        VERSION_NUMBER=${VERSION_NUMBER:-$LAST_VERSION}

        # Validate semver format
        if ! [[ "$VERSION_NUMBER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Error: Version must be in X.Y.Z format (e.g. 1.0.0)"
            continue
        fi

        # Validate >= last version
        if ! version_gte "$VERSION_NUMBER" "$LAST_VERSION"; then
            echo "Error: Version must be >= $LAST_VERSION"
            continue
        fi

        break
    done

    # Update .build_version
    echo "$VERSION_NUMBER" > "$VERSION_FILE"

    APP_VERSION="APP-$EPOCH"
    FILE_TAG="$EPOCH"
fi

# Output directories
ANDROID_DIR="$HOME/Documents/MeshMapper_Apps/Andriod"
IOS_DIR="$HOME/Documents/MeshMapper_Apps/IOS"

echo ""
echo "============================================"
echo "MeshMapper Build Script"
echo "Version: $APP_VERSION"
echo "Build number: $EPOCH"
echo "============================================"
echo ""

# Ensure output directories exist
mkdir -p "$ANDROID_DIR"
mkdir -p "$IOS_DIR"

# Build Android APK
echo "[1/3] Building Android APK..."
flutter build apk --release --build-name="$VERSION_NUMBER" --build-number="$EPOCH" --dart-define="APP_VERSION=$APP_VERSION" --dart-define="API_KEY=$MESHMAPPER_API_KEY"
cp build/app/outputs/flutter-apk/app-release.apk "$ANDROID_DIR/MeshMapper-$FILE_TAG.apk"
echo "✓ Built: MeshMapper-$FILE_TAG.apk"
echo ""

# Build Android AAB
echo "[2/3] Building Android AAB..."
flutter build appbundle --release --build-name="$VERSION_NUMBER" --build-number="$EPOCH" --dart-define="APP_VERSION=$APP_VERSION" --dart-define="API_KEY=$MESHMAPPER_API_KEY"
cp build/app/outputs/bundle/release/app-release.aab "$ANDROID_DIR/MeshMapper-$FILE_TAG.aab"
echo "✓ Built: MeshMapper-$FILE_TAG.aab"
echo ""

# Build iOS IPA
echo "[3/3] Building iOS IPA..."
(cd ios && pod install)
flutter build ipa --release --build-name="$VERSION_NUMBER" --build-number="$EPOCH" --dart-define="APP_VERSION=$APP_VERSION" --dart-define="API_KEY=$MESHMAPPER_API_KEY"
cp build/ios/ipa/mesh_mapper.ipa "$IOS_DIR/MeshMapper-$FILE_TAG.ipa"
echo "✓ Built: MeshMapper-$FILE_TAG.ipa"
echo ""

echo "============================================"
echo "Build Complete!"
echo "Version: $APP_VERSION"
echo "Build number: $EPOCH"
echo ""
echo "Outputs:"
echo "  APK: $ANDROID_DIR/MeshMapper-$FILE_TAG.apk"
echo "  AAB: $ANDROID_DIR/MeshMapper-$FILE_TAG.aab"
echo "  IPA: $IOS_DIR/MeshMapper-$FILE_TAG.ipa"
echo "============================================"
