#!/bin/bash

# MeshMapper Build Script
# Builds Android APK, Android AAB, and iOS IPA with the same epoch timestamp

set -e  # Exit on any error

# CLI flags for scripted use: ./Build.sh [--type dev|prod] [--version X.Y.Z] [--dry-run]
# With no flags the script behaves exactly as before (interactive prompts).
CLI_TYPE=""
CLI_VERSION=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --type)    CLI_TYPE="$2"; shift 2 ;;
        --version) CLI_VERSION="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *)
            echo "Error: Unknown argument: $1"
            echo "Usage: ./Build.sh [--type dev|prod] [--version X.Y.Z] [--dry-run]"
            exit 1
            ;;
    esac
done
if [ -n "$CLI_TYPE" ] && [ "$CLI_TYPE" != "dev" ] && [ "$CLI_TYPE" != "prod" ]; then
    echo "Error: --type must be 'dev' or 'prod'"
    exit 1
fi
if [ "$DRY_RUN" = "1" ] && { [ -z "$CLI_TYPE" ] || [ -z "$CLI_VERSION" ]; }; then
    echo "Error: --dry-run requires --type and --version"
    exit 1
fi
# Both flags given -> never prompt; missing secrets are an error instead
NONINTERACTIVE=0
if [ -n "$CLI_TYPE" ] && [ -n "$CLI_VERSION" ]; then
    NONINTERACTIVE=1
fi

# maplibre_gl 0.25.0 plugin requires JDK 21 to compile.
# Force the build to use Homebrew openjdk@21, regardless of the user's shell JAVA_HOME.
JDK21_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
if [ ! -d "$JDK21_HOME" ]; then
    echo "Error: JDK 21 not found at $JDK21_HOME"
    echo "Install with: brew install openjdk@21"
    exit 1
fi
export JAVA_HOME="$JDK21_HOME"
export PATH="$JAVA_HOME/bin:$PATH"

# Local release secrets (optional, never committed; lives outside the repo)
RELEASE_ENV="$HOME/.meshmapper_release.env"
if [ -f "$RELEASE_ENV" ]; then
    # set -a exports everything the file assigns. Gradle reads the signing
    # passwords with System.getenv, so a plain "NAME=value" in the file has to
    # be exported here or the release build fails on a null store password.
    set -a
    source "$RELEASE_ENV"
    set +a
fi

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

# Validate a --version value; exits instead of re-prompting (scripted use)
require_valid_version() {
    if ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Error: Version must be in X.Y.Z format (e.g. 1.0.0)"
        exit 1
    fi
    if ! version_gte "$1" "$LAST_VERSION"; then
        echo "Error: Version must be >= $LAST_VERSION"
        exit 1
    fi
}

if [ "$NONINTERACTIVE" = "1" ]; then
    # Scripted run - secrets must already be set (env or $RELEASE_ENV), never prompt
    MISSING=""
    [ -z "$MESHMAPPER_API_KEY" ] && MISSING="$MISSING MESHMAPPER_API_KEY"
    [ -z "$SIGNING_STORE_PASSWORD" ] && MISSING="$MISSING SIGNING_STORE_PASSWORD"
    if [ -n "$MISSING" ]; then
        echo "Error: Missing required secrets:$MISSING"
        echo "Set them in $RELEASE_ENV or the environment."
        exit 1
    fi
    if [ -z "$SIGNING_KEY_PASSWORD" ]; then
        SIGNING_KEY_PASSWORD="$SIGNING_STORE_PASSWORD"
    fi
    export SIGNING_STORE_PASSWORD SIGNING_KEY_PASSWORD
else
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

# Release type - from --type flag, or prompt
if [ -n "$CLI_TYPE" ]; then
    if [ "$CLI_TYPE" = "prod" ]; then RELEASE_TYPE="2"; else RELEASE_TYPE="1"; fi
else
    echo ""
    echo "Release type?"
    echo "  1) Dev  (APP-<epoch>)"
    echo "  2) Production  (APP-x.y.z)"
    echo ""
    read -p "Select [1]: " RELEASE_TYPE
    RELEASE_TYPE=${RELEASE_TYPE:-1}
fi

if [ "$RELEASE_TYPE" = "2" ]; then
    # Production build - version from --version flag, or prompt
    if [ -n "$CLI_VERSION" ]; then
        VERSION_NUMBER="$CLI_VERSION"
        require_valid_version "$VERSION_NUMBER"
    else
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
    fi

    # Update .build_version (skipped on dry run)
    if [ "$DRY_RUN" != "1" ]; then
        echo "$VERSION_NUMBER" > "$VERSION_FILE"
    fi

    APP_VERSION="APP-$VERSION_NUMBER"
    FILE_TAG="$VERSION_NUMBER"
else
    # Dev build - target version from --version flag, or prompt
    if [ -n "$CLI_VERSION" ]; then
        VERSION_NUMBER="$CLI_VERSION"
        require_valid_version "$VERSION_NUMBER"
    else
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
    fi

    # Update .build_version (skipped on dry run)
    if [ "$DRY_RUN" != "1" ]; then
        echo "$VERSION_NUMBER" > "$VERSION_FILE"
    fi

    APP_VERSION="APP-$EPOCH"
    FILE_TAG="$EPOCH"
fi

# Output directories
ANDROID_DIR="$HOME/Documents/MeshMapper_Apps/Andriod"
IOS_DIR="$HOME/Documents/MeshMapper_Apps/IOS"

# Dry run: everything is resolved and validated - print the plan and stop
if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "============================================"
    echo "DRY RUN - nothing will be built"
    echo "Release type: $([ "$RELEASE_TYPE" = "2" ] && echo Production || echo Dev)"
    echo "Version: $APP_VERSION"
    echo "Build name: $VERSION_NUMBER"
    echo "Build number: $EPOCH"
    echo "Secrets: present (API key + signing passwords)"
    echo ""
    echo "Would produce:"
    echo "  APK: $ANDROID_DIR/MeshMapper-$FILE_TAG.apk"
    echo "  AAB: $ANDROID_DIR/MeshMapper-$FILE_TAG.aab"
    echo "  IPA: $IOS_DIR/MeshMapper-$FILE_TAG.ipa"
    echo ""
    echo ".build_version and .last_build not modified"
    echo "============================================"
    exit 0
fi

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
flutter build ipa --release --build-name="$VERSION_NUMBER" --build-number="$EPOCH" --dart-define="APP_VERSION=$APP_VERSION" --dart-define="API_KEY=$MESHMAPPER_API_KEY" --export-options-plist=ios/ExportOptions.plist
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

# Record build metadata for the release flow (gitignored; only written on full success)
LAST_BUILD_FILE="$(dirname "$0")/.last_build"
{
    echo "RELEASE_TYPE=$([ "$RELEASE_TYPE" = "2" ] && echo prod || echo dev)"
    echo "VERSION_NUMBER=$VERSION_NUMBER"
    echo "EPOCH=$EPOCH"
    echo "APP_VERSION=$APP_VERSION"
    echo "FILE_TAG=$FILE_TAG"
    echo "APK_PATH=$ANDROID_DIR/MeshMapper-$FILE_TAG.apk"
    echo "AAB_PATH=$ANDROID_DIR/MeshMapper-$FILE_TAG.aab"
    echo "IPA_PATH=$IOS_DIR/MeshMapper-$FILE_TAG.ipa"
    echo "ARCHIVE_PATH=$(pwd)/build/ios/archive/Runner.xcarchive"
    echo "GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$LAST_BUILD_FILE"
