#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly WORKSPACE="$REPO_ROOT/ShadowLibrary.xcworkspace"
readonly SCHEME="Catalog"
readonly BUNDLE_ID="com.shadowlibrary.catalog"
readonly DERIVED_DATA="$REPO_ROOT/scratch-pad/derived-data"
readonly LOG_DIR="$DERIVED_DATA/logs"
readonly SIM_APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Catalog.app"
readonly MAC_APP="$DERIVED_DATA/Build/Products/Debug/Catalog.app"
readonly SIM_RUNTIME="${CATALOG_SIM_RUNTIME:-iOS 26.5}"
readonly IPHONE_NAME="${CATALOG_IPHONE:-iPhone 17 Pro}"
readonly IPAD_NAME="${CATALOG_IPAD:-iPad Pro 13-inch (M5)}"
readonly MAC_TIMEOUT=30
readonly SIM_SETTLE=0.6
readonly SIM_POLL=0.3
readonly SIM_MAX_POLLS=10

platforms="all"
components="all"
appearances="both"
scrolls="0"
out_dir="$REPO_ROOT/scratch-pad/shots/latest"
skip_build=false
keep_booted=false

iphone_udid=""
ipad_udid=""
booted_by_us=()
job_pids=()
run_dir=""

usage() {
  cat <<EOF
Capture Catalog pages as PNGs for visual verification.

Usage: mise run screenshots -- [options]
       Scripts/catalog-screenshots.sh [options]

Options:
  --platform iphone|ipad|macos|all     Platforms to capture, comma-separated (default: all)
  --component <id>[,<id>...]|all       Page ids, case-insensitive (default: all). Ids come from the app: Catalog -list-components
  --appearance light|dark|both         Appearances to capture (default: both)
  --scroll <f>[,<f>...]                Scroll positions from 0 (top) to 1 (bottom) for scrolling pages (default: 0).
                                       Full-bleed pages ignore it. Example: --scroll 0,0.5,1
  --out <dir>                          Output directory (default: scratch-pad/shots/latest)
  --skip-build                         Reuse the last build in scratch-pad/derived-data
  --keep-booted                        Leave the simulators booted (faster reruns); otherwise those booted here are shut down
  -h, --help                           Show this help

Output: <out>/<platform>/<id>-<appearance>.png, plus <id>-<appearance>-s<percent>.png for each non-zero --scroll position

How each platform is captured:
  iphone  $IPHONE_NAME ($SIM_RUNTIME), portrait, via simctl io screenshot.
  ipad    $IPAD_NAME ($SIM_RUNTIME), portrait: iPadOS 26 ignores app orientation requests and simctl cannot rotate.
          The grey arc at the bottom-right is the iPadOS window-resize grabber (system UI, also shown over Settings).
  macos   The app captures its own 1280x820 window (-snapshot <png>) with CGWindowListCreateImage, which needs no Screen
          Recording permission. The window is placed on the highest-resolution display, away from the pointer, and
          briefly takes focus so it renders in its active state.

Every shot is retaken until two consecutive frames match, so pages are captured once they have settled.
Simulators get a 9:41 status bar, full battery and wifi, default text size and the shot's appearance.

Environment overrides: CATALOG_SIM_RUNTIME, CATALOG_IPHONE, CATALOG_IPAD.
simctl, xcodebuild and the Mac capture need the window server and CoreSimulator: run outside any command sandbox.
EOF
}

log() { printf '%s\n' "$*"; }
fail() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
elapsed() { perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$1" "$(now)"; }
lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
regex_escape() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }

parse_arguments() {
  while (($# > 0)); do
    case "$1" in
      --platform) platforms="${2:?--platform needs a value}"; shift 2 ;;
      --component) components="${2:?--component needs a value}"; shift 2 ;;
      --appearance) appearances="${2:?--appearance needs a value}"; shift 2 ;;
      --scroll) scrolls="${2:?--scroll needs a value}"; shift 2 ;;
      --out) out_dir="${2:?--out needs a value}"; shift 2 ;;
      --skip-build) skip_build=true; shift ;;
      --keep-booted) keep_booted=true; shift ;;
      -h | --help) usage; exit 0 ;;
      --) shift ;;
      *) fail "unknown option '$1' (see --help)" ;;
    esac
  done

  local selected=() platform
  [[ "$platforms" == "all" ]] && platforms="iphone,ipad,macos"
  for platform in iphone ipad macos; do
    [[ ",$platforms," == *",$platform,"* ]] && selected+=("$platform")
  done
  for platform in ${platforms//,/ }; do
    case "$platform" in iphone | ipad | macos) ;; *) fail "unknown platform '$platform'" ;; esac
  done
  platforms="${selected[*]}"

  case "$appearances" in
    both) appearances="light dark" ;;
    light | dark) ;;
    *) fail "unknown appearance '$appearances'" ;;
  esac

  local fraction
  scrolls="${scrolls//,/ }"
  [[ -n "${scrolls// /}" ]] || fail "--scroll needs at least one position"
  for fraction in $scrolls; do
    [[ "$fraction" =~ ^(0|1|0?\.[0-9]+|1\.0+|0\.0+)$ ]] || fail "invalid --scroll position '$fraction' (expected a number from 0 to 1)"
  done

  mkdir -p "$out_dir"
  out_dir="$(cd "$out_dir" && pwd)"
}

wants() { [[ " $platforms " == *" $1 "* ]]; }
wants_simulator() { wants iphone || wants ipad; }

run_tuist() {
  if command -v tuist >/dev/null; then tuist "$@"; else mise exec -- tuist "$@"; fi
}

build() {
  mkdir -p "$LOG_DIR"
  local started
  started="$(now)"
  [[ -d "$WORKSPACE" ]] || run_tuist install >"$LOG_DIR/tuist-install.log" 2>&1 || fail "tuist install failed, see $LOG_DIR/tuist-install.log"
  run_tuist generate --no-open >"$LOG_DIR/tuist-generate.log" 2>&1 || fail "tuist generate failed, see $LOG_DIR/tuist-generate.log"
  if wants_simulator; then build_for "generic/platform=iOS Simulator" ios; fi
  if wants macos; then build_for "generic/platform=macOS" macos; fi
  log "Built in $(elapsed "$started")s"
}

build_for() {
  local destination="$1" name="$2" log_file="$LOG_DIR/build-$2.log"
  log "Building $SCHEME for $name..."
  if ! xcodebuild -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Debug -destination "$destination" \
    -derivedDataPath "$DERIVED_DATA" build >"$log_file" 2>&1; then
    grep -E "error:" "$log_file" | head -20 >&2 || true
    fail "build for $name failed, see $log_file"
  fi
}

device_udid() {
  xcrun simctl list devices available | awk -v runtime="-- $SIM_RUNTIME --" -v name="$1" '
    /^-- / { in_runtime = ($0 == runtime); next }
    in_runtime {
      line = $0
      sub(/^ +/, "", line)
      if (index(line, name " (") == 1 && match(line, /\([0-9A-F-]{36}\)/)) { print substr(line, RSTART + 1, RLENGTH - 2); exit }
    }'
}

is_booted() { xcrun simctl list devices | grep -F "($1)" | grep -q "(Booted)"; }

prepare_device() {
  local name="$1" udid="$2"
  if ! is_booted "$udid"; then
    log "Booting $name..."
    xcrun simctl boot "$udid"
  fi
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState discharging --batteryLevel 100 \
    --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --operatorName "" >/dev/null
  xcrun simctl ui "$udid" content_size large
  xcrun simctl ui "$udid" increase_contrast disabled
  xcrun simctl install "$udid" "$SIM_APP"
}

simulator_page_ids() {
  xcrun simctl launch --console-pty --terminate-running-process "$1" "$BUNDLE_ID" -list-components | tr -d '\r' | grep -v "^$BUNDLE_ID:" || true
}

mac_page_ids() {
  [[ -x "$MAC_APP/Contents/MacOS/Catalog" ]] || fail "no macOS build at $MAC_APP; run without --skip-build"
  "$MAC_APP/Contents/MacOS/Catalog" -list-components || true
}

resolve_page_ids() {
  local available="$1" requested id match resolved=()
  if [[ "$components" == "all" ]]; then
    page_ids="$(printf '%s' "$available" | tr '\n' ' ')"
    return
  fi
  for requested in ${components//,/ }; do
    match=""
    for id in $available; do
      if [[ "$(lowercase "$id")" == "$(lowercase "$requested")" ]]; then match="$id"; fi
    done
    [[ -n "$match" ]] || fail "unknown component '$requested'. Known ids: $(printf '%s' "$available" | tr '\n' ' ')"
    resolved+=("$match")
  done
  page_ids="${resolved[*]}"
}

shot_count() {
  local ids modes positions
  read -ra ids <<<"$page_ids"
  read -ra modes <<<"$appearances"
  read -ra positions <<<"$scrolls"
  printf '%s' $((${#ids[@]} * ${#modes[@]} * ${#positions[@]}))
}

scroll_suffix() {
  local percent
  percent="$(perl -e 'printf "%d", $ARGV[0] * 100 + 0.5' "$1")"
  ((percent == 0)) || printf -- '-s%d' "$percent"
}

capture_simulator() {
  local udid="$1" id="$2" appearance="$3" file="$4" scroll="$5"
  local previous="$file.previous.png" current="$file.current.png" poll
  rm -f "$file" "$previous" "$current"
  xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" -component "$id" -appearance "$appearance" -scroll "$scroll" >/dev/null || return 1
  sleep "$SIM_SETTLE"
  if ! xcrun simctl io "$udid" screenshot "$previous" >/dev/null 2>&1; then
    rm -f "$previous"
    return 1
  fi
  for ((poll = 0; poll < SIM_MAX_POLLS; poll++)); do
    sleep "$SIM_POLL"
    if ! xcrun simctl io "$udid" screenshot "$current" >/dev/null 2>&1; then
      rm -f "$previous" "$current"
      return 1
    fi
    if cmp -s "$previous" "$current"; then
      mv "$current" "$file"
      rm -f "$previous"
      return 0
    fi
    mv "$current" "$previous"
  done
  mv "$previous" "$file"
  printf '  warning: %s did not settle after %d polls; kept the last frame\n' "$id" "$SIM_MAX_POLLS"
}

capture_mac() {
  local id="$1" appearance="$2" file="$3" scroll="$4" errors="$3.stderr" waited=0 pid
  rm -f "$file" "$errors"
  open -n -W --stderr "$errors" -a "$MAC_APP" --args \
    -component "$id" -appearance "$appearance" -scroll "$scroll" -snapshot "$file" -ApplePersistenceIgnoreState YES &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((waited >= MAC_TIMEOUT * 5)); then
      kill "$pid" 2>/dev/null || true
      pkill -f -- "-snapshot $(regex_escape "$file")" || true
      printf '  timed out after %ds\n' "$MAC_TIMEOUT"
      break
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || true
  if [[ -f "$errors" ]]; then
    grep "catalog-snapshot:" "$errors" | sed 's/^/  /' || true
    rm -f "$errors"
  fi
  [[ -s "$file" ]]
}

capture() {
  if [[ -n "$1" ]]; then capture_simulator "$@"; else capture_mac "${@:2}"; fi
}

run_platform() {
  local platform="$1" udid="${2:-}" platform_dir="$out_dir/$1" total index=0 appearance id file started shot_started seconds
  total="$(shot_count)"
  mkdir -p "$platform_dir"
  started="$(now)"
  for appearance in $appearances; do
    if [[ -n "$udid" ]]; then xcrun simctl ui "$udid" appearance "$appearance"; fi
    for id in $page_ids; do
      for scroll in $scrolls; do
        index=$((index + 1))
        name="$id-$appearance$(scroll_suffix "$scroll")"
        file="$platform_dir/$name.png"
        shot_started="$(now)"
        if capture "$udid" "$id" "$appearance" "$file" "$scroll"; then
          log "[$platform $index/$total] $name $(elapsed "$shot_started")s"
        else
          log "[$platform $index/$total] $name FAILED"
          printf '%s\n' "$platform/$name" >>"$run_dir/failures"
        fi
      done
    done
  done
  seconds="$(elapsed "$started")"
  printf '%s: %d shots in %ss (%ss per shot)\n' "$platform" "$total" "$seconds" "$(perl -e 'printf "%.1f", $ARGV[0] / $ARGV[1]' "$seconds" "$total")" \
    >>"$run_dir/summary"
}

run_in_parallel() {
  local job_command="$1" pids=() names=() name index failed=0
  shift
  for name in "$@"; do
    $job_command "$name" &
    pids+=("$!")
    names+=("$name")
  done
  job_pids=("${pids[@]}")
  for index in "${!pids[@]}"; do
    if ! wait "${pids[$index]}"; then
      printf 'error: %s failed\n' "${names[$index]}" >&2
      failed=1
    fi
  done
  job_pids=()
  return "$failed"
}

udid_for() {
  case "$1" in
    iphone) printf '%s' "$iphone_udid" ;;
    ipad) printf '%s' "$ipad_udid" ;;
    *) ;;
  esac
}

device_name_for() {
  case "$1" in
    iphone) printf '%s' "$IPHONE_NAME" ;;
    ipad) printf '%s' "$IPAD_NAME" ;;
    *) ;;
  esac
}

prepare_platform() { prepare_device "$(device_name_for "$1")" "$(udid_for "$1")"; }
capture_platform() { run_platform "$1" "$(udid_for "$1")"; }

kill_tree() {
  local pid="$1" child
  kill -STOP "$pid" 2>/dev/null || return 0
  for child in $(pgrep -P "$pid"); do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
  kill -CONT "$pid" 2>/dev/null || true
}

cleanup() {
  local udid pid
  for pid in "${job_pids[@]+"${job_pids[@]}"}"; do kill_tree "$pid"; done
  for pid in "${job_pids[@]+"${job_pids[@]}"}"; do wait "$pid" 2>/dev/null || true; done
  pkill -f -- "-snapshot $(regex_escape "$out_dir/macos/")" 2>/dev/null || true
  [[ -d "$out_dir" ]] && find "$out_dir" \( -name '*.previous.png' -o -name '*.current.png' -o -name '*.png.stderr' \) -delete
  [[ -n "$run_dir" ]] && rm -rf "$run_dir"
  [[ "$keep_booted" == true ]] && return
  for udid in "${booted_by_us[@]+"${booted_by_us[@]}"}"; do
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  done
}

main() {
  parse_arguments "$@"
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  local run_started simulators=() platform udid available
  run_started="$(now)"
  run_dir="$(mktemp -d "${TMPDIR:-/tmp}/catalog-screenshots.XXXXXX")"
  [[ "$skip_build" == true ]] || build

  wants iphone && iphone_udid="$(device_udid "$IPHONE_NAME")" && simulators+=(iphone)
  wants ipad && ipad_udid="$(device_udid "$IPAD_NAME")" && simulators+=(ipad)
  for platform in "${simulators[@]+"${simulators[@]}"}"; do
    udid="$(udid_for "$platform")"
    [[ -n "$udid" ]] || fail "no available '$(device_name_for "$platform")' simulator on $SIM_RUNTIME"
    is_booted "$udid" || booted_by_us+=("$udid")
  done
  if ((${#simulators[@]} > 0)); then
    [[ -d "$SIM_APP" ]] || fail "no simulator build at $SIM_APP; run without --skip-build"
    run_in_parallel prepare_platform "${simulators[@]}" || fail "could not prepare the simulators"
  fi

  if wants macos; then available="$(mac_page_ids)"; else available="$(simulator_page_ids "$(udid_for "${simulators[0]}")")"; fi
  [[ -n "$available" ]] || fail "the app listed no pages"
  resolve_page_ids "$available"
  log "Capturing $(shot_count) shots per platform ($platforms) into $out_dir"

  local capture_failed=0
  # shellcheck disable=SC2086
  run_in_parallel capture_platform $platforms || capture_failed=1

  log ""
  [[ -f "$run_dir/summary" ]] && cat "$run_dir/summary"
  log "Total: $(elapsed "$run_started")s"
  if [[ -s "$run_dir/failures" ]]; then
    printf 'Failed shots (%d): %s\n' "$(wc -l <"$run_dir/failures" | tr -d ' ')" "$(tr '\n' ' ' <"$run_dir/failures")" >&2
    exit 1
  fi
  return "$capture_failed"
}

main "$@"
