#!/bin/bash

# MeshMapper TestFlight "What to Test" script
# Sets the per-build "What to Test" text on a TestFlight build through the
# App Store Connect API (betaBuildLocalizations).
#
# This cannot be done at upload time: the text is not part of the IPA, the
# archive, or the export. There is no -exportOptionsPlist key for it and altool
# has no flag for it. It has to be set after the upload, once App Store Connect
# has registered the build (usually a couple of minutes).
#
# Auth: the same credentials upload_ios.sh uses. ASC_KEY_ID and ASC_ISSUER_ID in
# the environment or ~/.meshmapper_release.env, with the .p8 at
# ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 unless ASC_KEY_PATH says
# otherwise. Set ASC_APP_ID in that file to skip the bundle-id lookup.
#
# Usage:
#   ./set_whats_new.sh --notes-file notes.txt              # build number from .last_build
#   ./set_whats_new.sh --notes-file notes.txt --build-number 1787524245
#   echo "Fixed the map freezing on reconnect" | ./set_whats_new.sh
#   ./set_whats_new.sh --notes-file notes.txt --dry-run    # look it up, send nothing
#
# The text is always shown for confirmation before anything is sent. Pass --yes
# to skip that prompt (the release flow approves the draft before calling this).

set -e

cd "$(dirname "$0")"

# ASC_API_BASE only exists so the flow can be exercised against a stub server
API_BASE="${ASC_API_BASE:-https://api.appstoreconnect.apple.com}"
BUNDLE_ID="${ASC_BUNDLE_ID:-net.meshmapper.app}"
MAX_WHATS_NEW=4000

NOTES_FILE=""
BUILD_NUMBER=""
LOCALE=""
ASSUME_YES=0
DRY_RUN=0
TIMEOUT=900
POLL_INTERVAL=15

usage() {
    echo "Usage: ./set_whats_new.sh [--notes-file PATH|-] [--build-number N] [--locale L]"
    echo "                          [--yes] [--dry-run] [--timeout SECONDS]"
    echo ""
    echo "  --notes-file    File holding the What to Test text ('-' reads stdin)."
    echo "                  Defaults to stdin when piped, else WhatToTest.txt."
    echo "  --build-number  TestFlight build number. Defaults to EPOCH from .last_build."
    echo "  --locale        App Store Connect locale. Defaults to the app's own"
    echo "                  primary locale, which is what TestFlight falls back to."
    echo "  --yes           Skip the confirmation prompt."
    echo "  --dry-run       Resolve the app and build, print the text, send nothing."
    echo "  --timeout       How long to wait for the build to register. Default 900s."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --notes-file)   NOTES_FILE="$2"; shift 2 ;;
        --build-number) BUILD_NUMBER="$2"; shift 2 ;;
        --locale)       LOCALE="$2"; shift 2 ;;
        --timeout)      TIMEOUT="$2"; shift 2 ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)
            echo "Error: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Local release secrets (optional, never committed; lives outside the repo)
RELEASE_ENV="$HOME/.meshmapper_release.env"
if [ -f "$RELEASE_ENV" ]; then
    source "$RELEASE_ENV"
fi

if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ]; then
    echo "Error: ASC_KEY_ID and ASC_ISSUER_ID must be set (env or $RELEASE_ENV)."
    exit 1
fi

ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
if [ ! -f "$ASC_KEY_PATH" ]; then
    echo "Error: API key file not found: $ASC_KEY_PATH"
    exit 1
fi

for tool in curl jq python3 openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: $tool is required but not installed."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Resolve the text
# ---------------------------------------------------------------------------

has_content() {
    printf '%s' "$1" | grep -q '[^[:space:]]'
}

WHATS_NEW=""
if [ -n "$NOTES_FILE" ]; then
    if [ "$NOTES_FILE" = "-" ]; then
        WHATS_NEW=$(cat)
    else
        if [ ! -f "$NOTES_FILE" ]; then
            echo "Error: Notes file not found: $NOTES_FILE"
            exit 1
        fi
        WHATS_NEW=$(cat "$NOTES_FILE")
    fi
else
    # Piped input wins, but an empty pipe (a run with stdin on /dev/null) falls
    # through to WhatToTest.txt rather than looking like an empty note.
    if [ ! -t 0 ]; then
        WHATS_NEW=$(cat)
    fi
    if ! has_content "$WHATS_NEW" && [ -f WhatToTest.txt ]; then
        WHATS_NEW=$(cat WhatToTest.txt)
    fi
fi

if ! has_content "$WHATS_NEW"; then
    echo "Error: No What to Test text. Pass --notes-file PATH, pipe it in, or create WhatToTest.txt."
    exit 1
fi

# Drop blank and whitespace-only lines from the top and bottom
WHATS_NEW=$(printf '%s\n' "$WHATS_NEW" | awk '
    { lines[NR] = $0 }
    END {
        start = 1
        end = NR
        while (start <= end && lines[start] ~ /^[[:space:]]*$/) start++
        while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
        for (i = start; i <= end; i++) print lines[i]
    }')

# Count characters, not bytes: App Store Connect counts characters and release
# notes routinely carry non-ASCII
CHAR_COUNT=$(printf '%s' "$WHATS_NEW" | python3 -c 'import sys; sys.stdout.write(str(len(sys.stdin.read())))')
if [ "$CHAR_COUNT" -gt "$MAX_WHATS_NEW" ]; then
    echo "Error: What to Test is $CHAR_COUNT characters. App Store Connect caps it at $MAX_WHATS_NEW."
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the build number
# ---------------------------------------------------------------------------

if [ -z "$BUILD_NUMBER" ] && [ -f .last_build ]; then
    BUILD_NUMBER=$(grep '^EPOCH=' .last_build | cut -d= -f2-)
fi
if [ -z "$BUILD_NUMBER" ]; then
    echo "Error: No build number. Pass --build-number, or run ./Build.sh so .last_build exists."
    exit 1
fi

# ---------------------------------------------------------------------------
# App Store Connect API
# ---------------------------------------------------------------------------

# Mints a fresh ES256 JWT. Called per request so a long build-poll can never
# outlive the token (App Store Connect caps token lifetime at 20 minutes).
mint_jwt() {
    python3 - "$ASC_KEY_PATH" "$ASC_KEY_ID" "$ASC_ISSUER_ID" <<'PY'
import base64
import json
import subprocess
import sys
import time

key_path, key_id, issuer_id = sys.argv[1], sys.argv[2], sys.argv[3]


def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b'=').decode('ascii')


def compact(obj):
    return json.dumps(obj, separators=(',', ':')).encode('utf-8')


now = int(time.time())
header = {'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}
payload = {'iss': issuer_id, 'iat': now, 'exp': now + 900, 'aud': 'appstoreconnect-v1'}
signing_input = (b64(compact(header)) + '.' + b64(compact(payload))).encode('ascii')

result = subprocess.run(
    ['openssl', 'dgst', '-sha256', '-sign', key_path],
    input=signing_input,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
if result.returncode != 0:
    sys.stderr.write('openssl could not sign with the API key:\n')
    sys.stderr.write(result.stderr.decode('utf-8', 'replace'))
    sys.exit(1)

# openssl emits the ECDSA signature as DER (SEQUENCE of two INTEGERs).
# JWS ES256 wants the raw pair, each padded to the 32-byte P-256 field size.
der = result.stdout
if not der or der[0] != 0x30:
    sys.stderr.write('Unexpected signature encoding from openssl.\n')
    sys.exit(1)

idx = 1
length_byte = der[idx]
idx += 1
if length_byte & 0x80:
    idx += length_byte & 0x7F

parts = []
for _ in range(2):
    if der[idx] != 0x02:
        sys.stderr.write('Unexpected signature encoding from openssl.\n')
        sys.exit(1)
    idx += 1
    int_len = der[idx]
    idx += 1
    parts.append(int.from_bytes(der[idx:idx + int_len], 'big'))
    idx += int_len

signature = parts[0].to_bytes(32, 'big') + parts[1].to_bytes(32, 'big')
sys.stdout.write(signing_input.decode('ascii') + '.' + b64(signature))
PY
}

HTTP_STATUS=""
HTTP_BODY=""

# asc_request METHOD PATH [BODY_FILE] - fills HTTP_STATUS and HTTP_BODY
asc_request() {
    local method="$1"
    local path="$2"
    local body_file="${3:-}"
    local token
    local response

    if ! token=$(mint_jwt); then
        echo "Error: Could not mint an App Store Connect token."
        exit 1
    fi

    # -g keeps curl from treating the filter[...] brackets as a glob range
    if [ -n "$body_file" ]; then
        response=$(curl -sS -g -X "$method" \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            --data-binary "@$body_file" \
            -w $'\n%{http_code}' \
            "${API_BASE}${path}") || return 1
    else
        response=$(curl -sS -g -X "$method" \
            -H "Authorization: Bearer $token" \
            -w $'\n%{http_code}' \
            "${API_BASE}${path}") || return 1
    fi

    HTTP_STATUS="${response##*$'\n'}"
    HTTP_BODY="${response%$'\n'*}"
    return 0
}

api_error() {
    local detail
    detail=$(printf '%s' "$HTTP_BODY" | jq -r '.errors[]? | "  [\(.status)] \(.code): \(.title) \(.detail // "")"' 2>/dev/null || true)
    if [ -n "$detail" ]; then
        printf '%s\n' "$detail"
    else
        printf '  %s\n' "$HTTP_BODY"
    fi
}

# --- App id ---------------------------------------------------------------

APP_ID="$ASC_APP_ID"
if [ -z "$APP_ID" ]; then
    echo "Looking up $BUNDLE_ID..."
    if ! asc_request GET "/v1/apps?filter[bundleId]=${BUNDLE_ID}&limit=1"; then
        echo "Error: Could not reach App Store Connect."
        exit 1
    fi
    if [ "$HTTP_STATUS" != "200" ]; then
        echo "Error: App lookup failed (HTTP $HTTP_STATUS)."
        api_error
        exit 1
    fi
    APP_ID=$(printf '%s' "$HTTP_BODY" | jq -r '.data[0].id // empty')
    if [ -z "$APP_ID" ]; then
        echo "Error: No app found for bundle id $BUNDLE_ID."
        exit 1
    fi
    echo "  app id $APP_ID (set ASC_APP_ID=$APP_ID in $RELEASE_ENV to skip this lookup)"
fi

# --- Locale ---------------------------------------------------------------
# Default to the app's own primary locale. App Store Connect pre-creates a
# localization in that locale on every build and TestFlight falls back to it, so
# writing only en-US on an en-CA app leaves most testers reading an empty What to
# Test while the text sits in a row they never see.

if [ -z "$LOCALE" ]; then
    if ! asc_request GET "/v1/apps/${APP_ID}"; then
        echo "Error: Could not reach App Store Connect."
        exit 1
    fi
    if [ "$HTTP_STATUS" != "200" ]; then
        echo "Error: Could not read the app's primary locale (HTTP $HTTP_STATUS)."
        api_error
        exit 1
    fi
    LOCALE=$(printf '%s' "$HTTP_BODY" | jq -r '.data.attributes.primaryLocale // empty')
    if [ -z "$LOCALE" ]; then
        LOCALE="en-US"
        echo "  no primary locale reported, falling back to $LOCALE"
    else
        echo "  app primary locale: $LOCALE"
    fi
fi

# ---------------------------------------------------------------------------
# Confirmation gate (everything below this point writes)
# ---------------------------------------------------------------------------

echo ""
echo "============================================"
echo "TestFlight What to Test"
echo "App:     $BUNDLE_ID"
echo "Build:   $BUILD_NUMBER"
echo "Locale:  $LOCALE"
echo "Length:  $CHAR_COUNT / $MAX_WHATS_NEW characters"
echo "--------------------------------------------"
printf '%s\n' "$WHATS_NEW"
echo "============================================"
echo ""

if [ "$ASSUME_YES" != "1" ] && [ "$DRY_RUN" != "1" ]; then
    # Read the answer from the terminal, not stdin: stdin may have carried the note
    if ! { exec 3< /dev/tty; } 2>/dev/null; then
        echo "Error: No terminal to confirm on. Re-run with --yes to send without a prompt."
        exit 1
    fi
    printf "Send this to TestFlight? [y/N] "
    read -r REPLY <&3
    exec 3<&-
    case "$REPLY" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted. Nothing was sent."; exit 1 ;;
    esac
    echo ""
fi

# --- Build ----------------------------------------------------------------
# filter[version] on /v1/builds is the build number (CFBundleVersion), which is
# the epoch Build.sh stamps in. The build shows up here a minute or two after the
# upload, well before processing finishes.

BUILD_ID=""
ELAPSED=0
echo "Finding build $BUILD_NUMBER..."
while true; do
    if ! asc_request GET "/v1/builds?filter[app]=${APP_ID}&filter[version]=${BUILD_NUMBER}&sort=-uploadedDate&limit=1"; then
        echo "Error: Could not reach App Store Connect."
        exit 1
    fi
    if [ "$HTTP_STATUS" != "200" ]; then
        echo "Error: Build lookup failed (HTTP $HTTP_STATUS)."
        api_error
        exit 1
    fi

    BUILD_ID=$(printf '%s' "$HTTP_BODY" | jq -r '.data[0].id // empty')
    if [ -n "$BUILD_ID" ]; then
        BUILD_STATE=$(printf '%s' "$HTTP_BODY" | jq -r '.data[0].attributes.processingState // "UNKNOWN"')
        echo "  found build $BUILD_ID (processing state: $BUILD_STATE)"
        break
    fi

    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo ""
        echo "Error: Build $BUILD_NUMBER has not appeared in App Store Connect after ${TIMEOUT}s."
        echo "The upload may still be in flight. Re-run this script once it lands:"
        echo "  ./set_whats_new.sh --notes-file <file> --build-number $BUILD_NUMBER"
        exit 1
    fi

    echo "  not registered yet, waiting (${ELAPSED}s elapsed)..."
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# --- Existing localization ------------------------------------------------
# POSTing a locale that already exists returns 409, so an existing row is
# PATCHed instead. Xcode itself never creates one, but a re-run of this script
# does.

if ! asc_request GET "/v1/builds/${BUILD_ID}/betaBuildLocalizations?limit=200"; then
    echo "Error: Could not reach App Store Connect."
    exit 1
fi
if [ "$HTTP_STATUS" != "200" ]; then
    echo "Error: Localization lookup failed (HTTP $HTTP_STATUS)."
    api_error
    exit 1
fi
LOCALIZATION_ID=$(printf '%s' "$HTTP_BODY" | jq -r --arg locale "$LOCALE" '.data[]? | select(.attributes.locale == $locale) | .id' | head -1)

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "============================================"
    echo "DRY RUN - nothing was sent"
    echo "App id:   $APP_ID"
    echo "Build id: $BUILD_ID (build number $BUILD_NUMBER)"
    if [ -n "$LOCALIZATION_ID" ]; then
        echo "Would PATCH existing $LOCALE localization $LOCALIZATION_ID"
    else
        echo "Would POST a new $LOCALE localization"
    fi
    echo "============================================"
    exit 0
fi

# --- Write ----------------------------------------------------------------

BODY_FILE=$(mktemp -t meshmapper_whatsnew)
trap 'rm -f "$BODY_FILE"' EXIT

if [ -n "$LOCALIZATION_ID" ]; then
    echo "Updating the existing $LOCALE What to Test..."
    jq -n --arg id "$LOCALIZATION_ID" --arg whatsNew "$WHATS_NEW" \
        '{data: {id: $id, type: "betaBuildLocalizations", attributes: {whatsNew: $whatsNew}}}' > "$BODY_FILE"
    if ! asc_request PATCH "/v1/betaBuildLocalizations/${LOCALIZATION_ID}" "$BODY_FILE"; then
        echo "Error: Could not reach App Store Connect."
        exit 1
    fi
    EXPECTED_STATUS="200"
else
    echo "Setting the $LOCALE What to Test..."
    jq -n --arg locale "$LOCALE" --arg whatsNew "$WHATS_NEW" --arg build "$BUILD_ID" \
        '{data: {type: "betaBuildLocalizations", attributes: {locale: $locale, whatsNew: $whatsNew}, relationships: {build: {data: {type: "builds", id: $build}}}}}' > "$BODY_FILE"
    if ! asc_request POST "/v1/betaBuildLocalizations" "$BODY_FILE"; then
        echo "Error: Could not reach App Store Connect."
        exit 1
    fi
    EXPECTED_STATUS="201"
fi

if [ "$HTTP_STATUS" != "$EXPECTED_STATUS" ]; then
    echo "Error: App Store Connect rejected the What to Test text (HTTP $HTTP_STATUS)."
    api_error
    exit 1
fi

echo ""
echo "What to Test set on build $BUILD_NUMBER ($LOCALE)."
echo "Testers see it in TestFlight once the build finishes processing."
