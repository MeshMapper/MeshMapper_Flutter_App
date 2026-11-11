#!/usr/bin/env bash
# Capture the Play Store phone screenshots from an Android emulator.
#
# Usage: tool/store_screenshots/capture_android.sh --version X.Y.Z [--out DIR]
#
# Writes android-phone/ under DIR (default
# ~/Documents/MeshMapper_Apps/store-screenshots/X.Y.Z), then contact_sheet.html.
# Exits non-zero if any image is missing or has the wrong size.
#
# Needs the Android command-line tools with the emulator and the
# system-images;android-36;google_apis;arm64-v8a image, and Homebrew openjdk@21.
# The meshmapper_store_api36 AVD (Pixel 2, 1080x1920) is created if it is
# missing. Secrets come from ~/.meshmapper_release.env and are never printed.
#
# For iterating (not used by the release flow):
#   SKIP_BUILD=1          reuse build/app/outputs/flutter-apk/app-debug.apk
#   EMULATOR_GPU=mode     pass -gpu <mode> to the emulator (e.g. swiftshader_indirect)
#   ANDROID_TAIL_START=N  which of the 6 tail points the drive starts from
#
# The emulator is headless, runs on its own port and is addressed by serial, so
# real phones that are plugged in are never touched. It is killed, SystemUI demo
# mode is left, and the capture file is deleted when the script ends, also when
# it fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---------------------------------------------------------------- constants
BUNDLE_ID="net.meshmapper.app"
ACTIVITY="$BUNDLE_ID/.MainActivity"
CAPTURE_FILE_NAME="store_capture.json"
ROUTE_FILE="$REPO_ROOT/lib/debug/store_capture_route.dart"
APK_PATH="$REPO_ROOT/build/app/outputs/flutter-apk/app-debug.apk"

SDK="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
AVD_NAME="meshmapper_store_api36"
AVD_IMAGE="system-images;android-36;google_apis;arm64-v8a"
AVD_DEVICE="pixel_2"
# An even port keeps clear of the 5554 that the other emulators use by default.
EMU_PORT="${EMU_PORT:-5584}"
SERIAL="emulator-$EMU_PORT"

# maplibre_gl 0.27.1 needs JDK 21 to compile (same as Build.sh).
JDK21_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"

PHONE_SIZE="1080x1920"
PHONE_SCREENS="map log history"
OUT_SET="android-phone"

# Seconds. The map follows the GPS once it has a fix, so the app gets
# LAUNCH_WAIT to load the sample drive, then the fixes are fed in FIX_INTERVAL
# apart and the picture settles for SETTLE_WAIT before the shot.
LAUNCH_WAIT="${LAUNCH_WAIT:-14}"
FIX_INTERVAL="${FIX_INTERVAL:-3}"
SETTLE_WAIT="${SETTLE_WAIT:-8}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"

# Which of the 6 tail points the drive starts from. The map does not follow the
# GPS, so the camera stays centred on the first fix and the arrow ends up
# (distance from that point) away from the centre. Starting at point 0 puts it
# 175 m out, which on a narrow phone lands the arrow under the map-controls
# rail; starting later keeps it clear of the rail.
ANDROID_TAIL_START="${ANDROID_TAIL_START:-2}"

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

# Use the adb that is already on PATH: a different adb version restarts the
# server and drops the adb-over-wifi devices that may be connected.
if command -v adb >/dev/null 2>&1; then
    ADB="$(command -v adb)"
else
    ADB="$SDK/platform-tools/adb"
fi
[ -x "$ADB" ] || die "adb not found"
EMULATOR="$SDK/emulator/emulator"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"
[ -x "$EMULATOR" ] || die "no emulator at $EMULATOR"

# Every call goes to the emulator by serial, never to another attached device.
adb_() { "$ADB" -s "$SERIAL" "$@"; }

# ---------------------------------------------------------------- cleanup
EMU_PID=""
EMU_LOG=""
EMU_UP=0

# Best-effort cleanup, run on every exit. Never fails the script by itself.
cleanup() {
    local status=$?
    set +e
    trap - EXIT INT TERM
    if [ "$EMU_UP" = "1" ]; then
        adb_ shell run-as "$BUNDLE_ID" rm -f "app_flutter/$CAPTURE_FILE_NAME" >/dev/null 2>&1
        adb_ shell am broadcast -a com.android.systemui.demo -e command exit >/dev/null 2>&1
        adb_ shell settings put global sysui_demo_allowed 0 >/dev/null 2>&1
        adb_ shell svc data enable >/dev/null 2>&1
        # The settings provider writes lazily; without this the AVD keeps the
        # values from before the cleanup.
        sleep 2
        adb_ shell sync >/dev/null 2>&1
        adb_ emu kill >/dev/null 2>&1
    fi
    if [ -n "$EMU_PID" ]; then
        local waited=0
        while kill -0 "$EMU_PID" 2>/dev/null && [ "$waited" -lt 15 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        kill "$EMU_PID" >/dev/null 2>&1
        sleep 1
        kill -9 "$EMU_PID" >/dev/null 2>&1
        wait "$EMU_PID" >/dev/null 2>&1
    fi
    if [ "$status" -eq 0 ] && [ -n "$EMU_LOG" ]; then
        rm -f "$EMU_LOG"
    elif [ -n "$EMU_LOG" ]; then
        log "emulator log kept at $EMU_LOG"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- preflight
[ -d "$JDK21_HOME" ] || die "JDK 21 not found at $JDK21_HOME (brew install openjdk@21)"
export JAVA_HOME="$JDK21_HOME"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_SDK_ROOT="$SDK"
export ANDROID_HOME="$SDK"

# The last 6 points of the sample drive; the GPS arrow sits on the final one.
TAIL=()
while IFS= read -r point; do
    TAIL+=("$point")
done < <(grep -oE '\(4[0-9.]+, -7[0-9.]+\)' "$ROUTE_FILE" | tail -6 | tr -d '() ' )
[ "${#TAIL[@]}" -eq 6 ] || die "expected 6 route points in $ROUTE_FILE, found ${#TAIL[@]}"
log "drive tail: ${TAIL[*]}"
case "$ANDROID_TAIL_START" in
    [0-4]) ;;
    *) die "ANDROID_TAIL_START must be 0-4, got '$ANDROID_TAIL_START'" ;;
esac
DRIVE=("${TAIL[@]:$ANDROID_TAIL_START}")

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
    log "SKIP_BUILD=1: reusing $APK_PATH"
else
    log "building the debug APK"
    flutter build apk --debug --target-platform android-arm64 \
        --dart-define="API_KEY=$MESHMAPPER_API_KEY" \
        --dart-define="APP_VERSION=APP-$VERSION" >&2
fi
[ -f "$APK_PATH" ] || die "no APK at $APK_PATH"

# ---------------------------------------------------------------- emulator
if ! "$EMULATOR" -list-avds | grep -qx "$AVD_NAME"; then
    [ -x "$AVDMANAGER" ] || die "no avdmanager at $AVDMANAGER"
    log "creating the $AVD_NAME AVD"
    # "no" declines the custom hardware profile prompt.
    echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$AVD_IMAGE" -d "$AVD_DEVICE" >&2
fi

if "$ADB" devices | grep -q "^$SERIAL"; then
    die "$SERIAL is already running; stop it or set EMU_PORT"
fi

EMU_LOG="$(mktemp -t meshmapper_emulator)"
EMU_ARGS=(-avd "$AVD_NAME" -port "$EMU_PORT" -no-window -no-audio -no-snapshot-save -no-boot-anim)
if [ -n "${EMULATOR_GPU:-}" ]; then
    EMU_ARGS+=(-gpu "$EMULATOR_GPU")
fi
log "starting the emulator ($AVD_NAME on $SERIAL${EMULATOR_GPU:+, gpu $EMULATOR_GPU})"
"$EMULATOR" "${EMU_ARGS[@]}" >"$EMU_LOG" 2>&1 &
EMU_PID=$!
EMU_UP=1

log "waiting for the emulator to boot"
adb_ wait-for-device
boot_start=$SECONDS
until [ "$(adb_ shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
    kill -0 "$EMU_PID" 2>/dev/null || die "the emulator exited while booting"
    [ $((SECONDS - boot_start)) -lt "$BOOT_TIMEOUT" ] || die "the emulator did not boot within ${BOOT_TIMEOUT}s"
    sleep 3
done
log "booted after $((SECONDS - boot_start))s"
sleep 5
# Keep the screen lit and unlocked for the whole run.
adb_ shell svc power stayon true >/dev/null
adb_ shell input keyevent 82 >/dev/null
adb_ shell wm dismiss-keyguard >/dev/null 2>&1 || true

# ---------------------------------------------------------------- location
# Google Play Services asks for "Location Accuracy" the first time the app asks
# for a position, and its dialog sits over the map. The answer lives in the AVD,
# so this only taps anything on a fresh emulator. The switch is read from the
# UI because assisted_gps_enabled can be set without changing it.
location_accuracy_state() { # prints true or false, nothing if the switch is not found
    adb_ shell uiautomator dump /data/local/tmp/store_ui.xml >/dev/null 2>&1 || return 0
    adb_ exec-out cat /data/local/tmp/store_ui.xml \
        | grep -o 'resource-id="android:id/switch_widget"[^>]*' \
        | grep -o 'checked="[a-z]*"' | head -1 | cut -d'"' -f2 || true
}

ensure_location_accuracy() {
    local state
    adb_ shell am start -a com.google.android.gms.location.settings.LOCATION_ACCURACY >/dev/null 2>&1
    sleep 3
    state="$(location_accuracy_state)"
    case "$state" in
        true) ;;
        false)
            log "turning on Google Location Accuracy"
            adb_ shell input tap 540 676
            sleep 2
            [ "$(location_accuracy_state)" = "true" ] || die "could not turn on Google Location Accuracy"
            ;;
        *) die "could not read the Google Location Accuracy switch" ;;
    esac
    adb_ shell input keyevent KEYCODE_HOME
    sleep 1
}
ensure_location_accuracy

# ---------------------------------------------------------------- app
# Fresh install so no earlier run can leak into the shots.
adb_ uninstall "$BUNDLE_ID" >/dev/null 2>&1 || true
adb_ install -r "$APK_PATH" >/dev/null
# Without these the OS permission prompts cover the map. BLUETOOTH_SCAN and
# BLUETOOTH_CONNECT are the "nearby devices" prompt the app raises at launch.
for perm in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION \
        POST_NOTIFICATIONS BLUETOOTH_SCAN BLUETOOTH_CONNECT; do
    adb_ shell pm grant "$BUNDLE_ID" "android.permission.$perm" >&2 \
        || die "could not grant $perm"
done

# ---------------------------------------------------------------- status bar
# Mobile data off drops the "3G" label next to the signal bars (the demo
# datatype extra does not hide it); the console call sets the bars to full.
adb_ shell svc data disable
adb_ emu gsm signal-profile 4 >/dev/null
demo() { # command [extras...]
    adb_ shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null
}
adb_ shell settings put global sysui_demo_allowed 1
demo enter
demo clock -e hhmm 0941
demo battery -e level 100 -e plugged false
demo network -e mobile show -e level 4 -e wifi show -e level 4 -e fully true -e datatype none -e sims 1
demo notifications -e visible false

# ---------------------------------------------------------------- shots
# The console wants longitude first. Without an altitude the accuracy chip on
# the map reads "0m"; downtown Ottawa is about 70 m up.
geo_fix() { # "lat,lon"
    local point="$1"
    adb_ emu geo fix "${point#*,}" "${point%,*}" 70 >/dev/null
}

write_capture_file() { # screen
    printf '{"screen":"%s"}' "$1" \
        | adb_ shell "run-as $BUNDLE_ID sh -c 'mkdir -p app_flutter && cat > app_flutter/$CAPTURE_FILE_NAME'"
}

DIR="$OUT/$OUT_SET"
mkdir -p "$DIR"
n=0
for screen in $PHONE_SCREENS; do
    n=$((n + 1))
    log "phone: $screen"
    write_capture_file "$screen"
    geo_fix "${DRIVE[0]}"
    adb_ shell am force-stop "$BUNDLE_ID"
    adb_ shell am start -n "$ACTIVITY" >/dev/null
    sleep "$LAUNCH_WAIT"
    for point in "${DRIVE[@]}"; do
        geo_fix "$point"
        sleep "$FIX_INTERVAL"
    done
    sleep "$SETTLE_WAIT"
    adb_ exec-out screencap -p > "$DIR/0${n}_${screen}.png"
done

adb_ shell am force-stop "$BUNDLE_ID"
# The trap removes the capture file, leaves demo mode and kills the emulator.

# ---------------------------------------------------------------- size check
BAD=0
check_size() { # file WxH
    local file="$1" want="$2" got
    if [ ! -s "$file" ]; then
        log "MISSING $file"
        BAD=1
        return
    fi
    got="$(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null \
        | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}')"
    if [ "$got" = "$want" ]; then
        log "ok $got  ${file#"$OUT"/}"
    else
        log "WRONG SIZE $got (want $want)  $file"
        BAD=1
    fi
}

for f in 01_map 02_log 03_history; do check_size "$DIR/$f.png" "$PHONE_SIZE"; done

/usr/bin/python3 "$SCRIPT_DIR/contact_sheet.py" "$OUT"

if [ "$BAD" -ne 0 ]; then
    die "one or more screenshots are missing or have the wrong size"
fi
log "done"
