#!/usr/bin/env bash
# Capture the App Store screenshots from the iOS simulators.
#
# Usage: tool/store_screenshots/capture_ios.sh --version X.Y.Z [--out DIR]
#
# Writes ios-iphone-69/, ios-ipad-13/ and watch-46/ under DIR (default
# ~/Documents/MeshMapper_Apps/store-screenshots/X.Y.Z), then contact_sheet.html.
# Exits non-zero if any image is missing or has the wrong size.
#
# Needs Xcode 26.x and the iOS 26.5 / watchOS 26.5 simulators. Xcode 27 builds
# crash at launch on iOS 27, so the iOS 27 simulators are never used here.
# Secrets come from ~/.meshmapper_release.env and are never printed.
#
# For iterating on one set (not used by the release flow):
#   CAPTURE_SETS="ipad"   which sets to capture: iphone ipad watch (default: all)
#   SKIP_BUILD=1          reuse build/ios/iphonesimulator/Runner.app as it is
#
# Every simulator is shut down and the capture file is deleted when the script
# ends, also when it fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---------------------------------------------------------------- constants
BUNDLE_ID="net.meshmapper.app"
CAPTURE_FILE_NAME="store_capture.json"
ROUTE_FILE="$REPO_ROOT/lib/debug/store_capture_route.dart"
APP_PATH="$REPO_ROOT/build/ios/iphonesimulator/Runner.app"
WATCH_APP_PATH="$APP_PATH/Watch/MeshMapperWatch.app"

IOS_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
IPHONE_NAME="iPhone 17 Pro Max"
IPAD_NAME="iPad Pro 13-inch (M5)"
WATCH_NAME="Apple Watch Series 11 (46mm)"

IPHONE_SIZE="1320x2868"
IPAD_SIZE="2064x2752"
WATCH_SIZE="416x496"

# Seconds. The map follows the GPS once it has a fix, so the app gets
# LAUNCH_WAIT to load the sample drive, then the simulated drive runs for
# DRIVE_WAIT before the shot.
LAUNCH_WAIT="${LAUNCH_WAIT:-14}"
DRIVE_WAIT="${DRIVE_WAIT:-22}"
WATCH_WAIT="${WATCH_WAIT:-12}"

PHONE_SCREENS="map log history"

# Which of the 6 tail points the drive starts from. The map does not follow the
# GPS, so the camera stays centred on the first fix and the arrow ends up
# (distance from that point) away from the centre. Starting at point 0 puts it
# 175 m out: fine on the iPad, but on the narrow iPhone the arrow lands under
# the map-controls rail. Starting at point 2 (105 m) keeps it clear of the rail.
IPHONE_TAIL_START="${IPHONE_TAIL_START:-2}"
IPAD_TAIL_START="${IPAD_TAIL_START:-0}"
CAPTURE_SETS="${CAPTURE_SETS:-iphone ipad watch}"

# ---------------------------------------------------------------- helpers
log() { printf '[capture] %s\n' "$*" >&2; }
die() { printf '[capture] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    echo "Usage: $0 --version X.Y.Z [--out DIR]" >&2
    exit 2
}

VERSION=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) [ $# -ge 2 ] || usage; VERSION="$2"; shift 2 ;;
        --out)     [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)         usage ;;
    esac
done
[ -n "$VERSION" ] || usage
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "--version must look like X.Y.Z, got '$VERSION'" ;;
esac
[ -n "$OUT" ] || OUT="$HOME/Documents/MeshMapper_Apps/store-screenshots/$VERSION"

wants() { case " $CAPTURE_SETS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- simulators
IPHONE=""
IPAD=""
WATCH=""

resolve_device() { # name -> udid on the pinned iOS runtime
    xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
for dev in json.load(sys.stdin)["devices"].get(runtime, []):
    if dev["name"] == name:
        print(dev["udid"])
        break
' "$1" "$IOS_RUNTIME"
}

resolve_watch() { # phone udid, watch name -> udid of the watch paired with it
    xcrun simctl list pairs -j | /usr/bin/python3 -c '
import json, sys
phone, name = sys.argv[1], sys.argv[2]
for pair in json.load(sys.stdin)["pairs"].values():
    if pair["phone"]["udid"] == phone and pair["watch"]["name"] == name:
        print(pair["watch"]["udid"])
        break
' "$1" "$2"
}

# Best-effort cleanup, run on every exit. Never fails the script by itself.
cleanup() {
    local status=$?
    set +e
    trap - EXIT INT TERM
    local dev container
    for dev in "$IPHONE" "$IPAD" "$WATCH"; do
        [ -n "$dev" ] || continue
        container="$(xcrun simctl get_app_container "$dev" "$BUNDLE_ID" data 2>/dev/null)"
        [ -z "$container" ] || rm -f "$container/Documents/$CAPTURE_FILE_NAME"
        # simctl cannot look up a container once the device is shut down, so
        # also sweep the files on disk.
        rm -f "$HOME/Library/Developer/CoreSimulator/Devices/$dev/data/Containers/Data/Application"/*/Documents/"$CAPTURE_FILE_NAME"
        xcrun simctl location "$dev" clear >/dev/null 2>&1
        xcrun simctl status_bar "$dev" clear >/dev/null 2>&1
        xcrun simctl shutdown "$dev" >/dev/null 2>&1
    done
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

boot_device() {
    local out
    if ! out="$(xcrun simctl boot "$1" 2>&1)"; then
        case "$out" in
            *"current state: Booted"*) ;;
            *) die "could not boot $1: $out" ;;
        esac
    fi
    xcrun simctl bootstatus "$1" -b >/dev/null
}

# ---------------------------------------------------------------- preflight
XCODE_VERSION="$(xcodebuild -version | sed -n '1p')"
case "$XCODE_VERSION" in
    "Xcode 26."*) ;;
    *) die "the active Xcode must be 26.x (found: $XCODE_VERSION); run xcode-select" ;;
esac

IPHONE="$(resolve_device "$IPHONE_NAME")"
[ -n "$IPHONE" ] || die "no '$IPHONE_NAME' simulator on $IOS_RUNTIME"
IPAD="$(resolve_device "$IPAD_NAME")"
[ -n "$IPAD" ] || die "no '$IPAD_NAME' simulator on $IOS_RUNTIME"
WATCH="$(resolve_watch "$IPHONE" "$WATCH_NAME")"
[ -n "$WATCH" ] || die "'$WATCH_NAME' is not paired with the '$IPHONE_NAME' simulator"
log "iPhone $IPHONE, iPad $IPAD, Watch $WATCH"

# The last 6 points of the sample drive; the GPS arrow sits on the final one.
TAIL=()
while IFS= read -r point; do
    TAIL+=("$point")
done < <(grep -oE '\(4[0-9.]+, -7[0-9.]+\)' "$ROUTE_FILE" | tail -6 | tr -d '() ' )
[ "${#TAIL[@]}" -eq 6 ] || die "expected 6 route points in $ROUTE_FILE, found ${#TAIL[@]}"
log "drive tail: ${TAIL[*]}"

# Secrets: loaded into the environment, never echoed.
[ -f "$HOME/.meshmapper_release.env" ] || die "missing ~/.meshmapper_release.env"
set -a
# shellcheck disable=SC1091
source "$HOME/.meshmapper_release.env"
set +a
: "${MESHMAPPER_API_KEY:?MESHMAPPER_API_KEY is not set in ~/.meshmapper_release.env}"

# ---------------------------------------------------------------- build
cd "$REPO_ROOT"
if [ "${SKIP_BUILD:-0}" = "1" ]; then
    log "SKIP_BUILD=1: reusing $APP_PATH"
else
    log "building the simulator app (debug, $XCODE_VERSION)"
    flutter build ios --simulator --debug -d "$IPHONE" \
        --dart-define="API_KEY=$MESHMAPPER_API_KEY" \
        --dart-define="APP_VERSION=APP-$VERSION"
fi
[ -d "$APP_PATH" ] || die "no simulator app at $APP_PATH"

# ---------------------------------------------------------------- phone shots
capture_phone() { # label udid outdir tail-start-index
    local label="$1" dev="$2" dir="$3" start="$4" container capture_file screen n=0
    local drive=("${TAIL[@]:$start}")
    log "$label: boot"
    mkdir -p "$dir"
    boot_device "$dev"
    xcrun simctl status_bar "$dev" override --time 9:41 --dataNetwork wifi \
        --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
        --batteryState charged --batteryLevel 100

    # Fresh install so no earlier run can leak into the shots.
    xcrun simctl uninstall "$dev" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$dev" "$APP_PATH"
    # Without these the OS location prompt covers the map.
    xcrun simctl privacy "$dev" grant location-always "$BUNDLE_ID"
    xcrun simctl privacy "$dev" grant location "$BUNDLE_ID"

    container="$(xcrun simctl get_app_container "$dev" "$BUNDLE_ID" data)"
    mkdir -p "$container/Documents"
    capture_file="$container/Documents/$CAPTURE_FILE_NAME"

    for screen in $PHONE_SCREENS; do
        n=$((n + 1))
        log "$label: $screen"
        printf '{"screen":"%s"}' "$screen" > "$capture_file"
        xcrun simctl location "$dev" set "${drive[0]}"
        xcrun simctl terminate "$dev" "$BUNDLE_ID" >/dev/null 2>&1 || true
        xcrun simctl launch "$dev" "$BUNDLE_ID" >/dev/null
        sleep "$LAUNCH_WAIT"
        xcrun simctl location "$dev" start --speed=12 --interval=1 "${drive[@]}"
        sleep "$DRIVE_WAIT"
        xcrun simctl io "$dev" screenshot --type=png "$dir/0${n}_${screen}.png" >/dev/null 2>&1
    done

    xcrun simctl terminate "$dev" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl location "$dev" clear
    rm -f "$capture_file"
    xcrun simctl status_bar "$dev" clear
    xcrun simctl shutdown "$dev"
}

# ---------------------------------------------------------------- watch shots
capture_watch() { # outdir
    local dir="$1" watch_bundle
    log "watch: boot"
    mkdir -p "$dir"
    [ -d "$WATCH_APP_PATH" ] || die "no Watch app at $WATCH_APP_PATH"
    watch_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WATCH_APP_PATH/Info.plist")"
    boot_device "$WATCH"
    # status_bar override is not supported on the watch; the clock stays real.
    xcrun simctl status_bar "$WATCH" override --time 9:41 >/dev/null 2>&1 || true

    xcrun simctl uninstall "$WATCH" "$watch_bundle" >/dev/null 2>&1 || true
    xcrun simctl install "$WATCH" "$WATCH_APP_PATH"

    watch_shot "$WATCH" "$watch_bundle" "$dir/01_map.png" \
        -MeshMapperSampleData YES -MeshMapperInitialPage 0
    watch_shot "$WATCH" "$watch_bundle" "$dir/02_readout.png" \
        -MeshMapperSampleData YES -MeshMapperInitialPage 0 -layout.mainPageContent readout
    watch_shot "$WATCH" "$watch_bundle" "$dir/03_heard.png" \
        -MeshMapperSampleData YES -MeshMapperInitialPage 2

    xcrun simctl terminate "$WATCH" "$watch_bundle" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$WATCH"
}

watch_shot() { # dev bundle file launch-args...
    local dev="$1" bundle="$2" file="$3"
    shift 3
    log "watch: $(basename "$file")"
    xcrun simctl terminate "$dev" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl launch "$dev" "$bundle" "$@" >/dev/null
    sleep "$WATCH_WAIT"
    xcrun simctl io "$dev" screenshot --type=png "$file" >/dev/null 2>&1
}

if wants iphone; then capture_phone "iphone" "$IPHONE" "$OUT/ios-iphone-69" "$IPHONE_TAIL_START"; fi
if wants ipad; then capture_phone "ipad" "$IPAD" "$OUT/ios-ipad-13" "$IPAD_TAIL_START"; fi
if wants watch; then capture_watch "$OUT/watch-46"; fi

# ---------------------------------------------------------------- size check
BAD=0
check_size() { # file WxH
    local file="$1" want="$2" got
    if [ ! -f "$file" ]; then
        log "MISSING $file"
        BAD=1
        return
    fi
    got="$(sips -g pixelWidth -g pixelHeight "$file" \
        | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}')"
    if [ "$got" = "$want" ]; then
        log "ok $got  ${file#"$OUT"/}"
    else
        log "WRONG SIZE $got (want $want)  $file"
        BAD=1
    fi
}

if wants iphone; then
    for f in 01_map 02_log 03_history; do check_size "$OUT/ios-iphone-69/$f.png" "$IPHONE_SIZE"; done
fi
if wants ipad; then
    for f in 01_map 02_log 03_history; do check_size "$OUT/ios-ipad-13/$f.png" "$IPAD_SIZE"; done
fi
if wants watch; then
    for f in 01_map 02_readout 03_heard; do check_size "$OUT/watch-46/$f.png" "$WATCH_SIZE"; done
fi

/usr/bin/python3 "$SCRIPT_DIR/contact_sheet.py" "$OUT"

if [ "$BAD" -ne 0 ]; then
    die "one or more screenshots are missing or have the wrong size"
fi
log "done"
