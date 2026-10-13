#!/usr/bin/env bash

die() {
  log_fail "$*" >&2
  exit 1
}

now_ts() {
  date +%s
}

date_iso() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

ts_iso() {
  python3 - "$1" <<'PY'
from datetime import datetime
import sys

print(datetime.fromtimestamp(int(sys.argv[1])).astimezone().strftime("%Y-%m-%dT%H:%M:%S%z"))
PY
}

log() {
  log_info "$*"
}

color_enabled() {
  [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]
}

icon_enabled() {
  [ "${LOG_ICONS:-1}" != "0" ] && [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *UTF-8* ]]
}

log_icon() {
  case "$1" in
    START) echo "🚀" ;;
    WAIT) echo "⏳" ;;
    RESULT) echo "📊" ;;
    SUCCESS) echo "✅" ;;
    FAIL) echo "❌" ;;
    WARN) echo "⚠️" ;;
    *) echo "•" ;;
  esac
}

color_code() {
  case "$1" in
    blue) echo "34" ;;
    cyan) echo "36" ;;
    green) echo "32" ;;
    red) echo "31" ;;
    yellow) echo "33" ;;
    magenta) echo "35" ;;
    bold) echo "1" ;;
    *) echo "0" ;;
  esac
}

paint() {
  local color="$1"
  local text="$2"

  if color_enabled; then
    printf '\033[%sm%s\033[0m' "$(color_code "$color")" "$text"
  else
    printf '%s' "$text"
  fi
}

log_event() {
  local level="$1"
  local color="$2"
  local message="$3"
  local icon label marker

  label="$(printf '%-7s' "$level")"
  case "$level" in
    START) marker=">>>" ;;
    WAIT) marker="..." ;;
    RESULT) marker="=>" ;;
    SUCCESS) marker="OK" ;;
    FAIL) marker="ERR" ;;
    WARN) marker="!" ;;
    *) marker="-" ;;
  esac

  if icon_enabled; then
    icon="$(log_icon "$level")"
  else
    icon=""
  fi

  printf '%s %s %-2s %-3s %s\n' "[$(date_iso)]" "$(paint "$color" "[$label]")" "$icon" "$marker" "$message"
}

log_info() {
  log_event "INFO" "cyan" "$*"
}

log_start() {
  log_event "START" "blue" "$*"
}

log_wait() {
  log_event "WAIT" "yellow" "$*"
}

log_result() {
  log_event "RESULT" "magenta" "$*"
}

log_success() {
  log_event "SUCCESS" "green" "$*"
}

log_warn() {
  log_event "WARN" "yellow" "$*"
}

log_fail() {
  log_event "FAIL" "red" "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

seconds_to_human() {
  local total="$1"
  local hours=$((total / 3600))
  local minutes=$(((total % 3600) / 60))
  local seconds=$((total % 60))

  if [ "$hours" -gt 0 ]; then
    echo "${hours}h ${minutes}m ${seconds}s"
  elif [ "$minutes" -gt 0 ]; then
    echo "${minutes}m ${seconds}s"
  else
    echo "${seconds}s"
  fi
}

jittered_seconds() {
  python3 - "$1" "$2" <<'PY'
import random
import sys

base = int(float(sys.argv[1]))
jitter = int(float(sys.argv[2]))
print(max(1, base + random.randint(-jitter, jitter)))
PY
}

chance() {
  python3 - "$1" <<'PY'
import random
import sys

raise SystemExit(0 if random.random() < float(sys.argv[1]) else 1)
PY
}

uuid_token() {
  python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

classify_error() {
  local output="$1"

  if echo "$output" | grep -qi "TooManyRequests"; then
    echo "THROTTLE"
  elif echo "$output" | grep -qiE "Out of capacity|host capacity|InsufficientHostCapacity"; then
    echo "CAPACITY"
  elif echo "$output" | grep -qiE "LimitExceeded|QuotaExceeded|ServiceLimit"; then
    echo "LIMIT"
  elif echo "$output" | grep -qiE "NotAuthorized|NotAuthenticated|InvalidParameter|Invalid shape|InvalidShape|Subnet|VCN|ImageNotFound|CannotParseRequest"; then
    echo "FATAL"
  else
    echo "UNKNOWN"
  fi
}
