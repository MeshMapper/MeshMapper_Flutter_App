#!/bin/bash

# MeshMapper Build Script
# Builds Android APK, Android AAB, and iOS IPA with the same epoch timestamp

set -e  # Exit on any error

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

# Generate single epoch for all builds
EPOCH=$(date +%s)

# Output directories
ANDROID_DIR="/Users/schnobbc/Documents/MeshMapper_Apps/Andriod"
IOS_DIR="/Users/schnobbc/Documents/MeshMapper_Apps/IOS"

echo "============================================"
echo "MeshMapper Build Script"
echo "Epoch: $EPOCH"
echo "============================================"
echo ""

# Ensure output directories exist
mkdir -p "$ANDROID_DIR"
mkdir -p "$IOS_DIR"

# Build Android APK
echo "[1/3] Building Android APK..."
flutter build apk --release --dart-define=APP_VERSION=APP-$EPOCH --dart-define=API_KEY=$MESHMAPPER_API_KEY
cp build/app/outputs/flutter-apk/app-release.apk "$ANDROID_DIR/MeshMapper-$EPOCH.apk"
echo "✓ Built: MeshMapper-$EPOCH.apk"
echo ""

# Build Android AAB
echo "[2/3] Building Android AAB..."
flutter build appbundle --release --build-number=$EPOCH --dart-define=APP_VERSION=APP-$EPOCH --dart-define=API_KEY=$MESHMAPPER_API_KEY
cp build/app/outputs/bundle/release/app-release.aab "$ANDROID_DIR/MeshMapper-$EPOCH.aab"
echo "✓ Built: MeshMapper-$EPOCH.aab"
echo ""

# Build iOS IPA
echo "[3/3] Building iOS IPA..."
flutter build ipa --release --build-number=$EPOCH --dart-define=APP_VERSION=APP-$EPOCH --dart-define=API_KEY=$MESHMAPPER_API_KEY
cp build/ios/ipa/mesh_mapper.ipa "$IOS_DIR/MeshMapper-$EPOCH.ipa"
echo "✓ Built: MeshMapper-$EPOCH.ipa"
echo ""

echo "============================================"
echo "Build Complete!"
echo "Epoch: $EPOCH"
echo ""
echo "Outputs:"
echo "  APK: $ANDROID_DIR/MeshMapper-$EPOCH.apk"
echo "  AAB: $ANDROID_DIR/MeshMapper-$EPOCH.aab"
echo "  IPA: $IOS_DIR/MeshMapper-$EPOCH.ipa"
echo "============================================"
