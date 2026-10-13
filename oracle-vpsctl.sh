#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT_DIR/retry-oracle-vps.sh"
PID_FILE="${ORACLE_VPS_PID_FILE:-$ROOT_DIR/oracle-vps.pid}"
LOG_FILE="${ORACLE_VPS_LOG_FILE:-$ROOT_DIR/oracle-vps.log}"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/process_guard.sh"

usage() {
  cat <<EOF
Usage: ./oracle-vpsctl.sh <command>

Commands:
  status   Show running retry-oracle-vps.sh processes
  start    Start in background if not already running
  kill     Stop all running retry-oracle-vps.sh processes
  restart  Kill then start in background
  tail     Follow log file
EOF
}

running_pids() {
  running_retry_pids | live_retry_pids
}

status() {
  local pids
  pids="$(running_pids)"

  if [ -z "$pids" ]; then
    echo "Not running."
    return 1
  fi

  echo "Running:"
  ps -o pid,ppid,etime,command -p "$(echo "$pids" | paste -sd, -)"
}

start() {
  local pids
  pids="$(running_pids)"

  if [ -n "$pids" ]; then
    echo "Already running. Refusing to start another copy."
    status
    return 1
  fi

  nohup "$APP" >>"$LOG_FILE" 2>&1 &
  echo "$!" >"$PID_FILE"
  echo "Started PID $(cat "$PID_FILE")."
  echo "Log: $LOG_FILE"
}

kill_running() {
  local pids
  pids="$(running_pids)"

  if [ -z "$pids" ]; then
    echo "No retry-oracle-vps.sh process to kill."
    rm -f "$PID_FILE"
    return 0
  fi

  echo "Stopping:"
  ps -o pid,ppid,etime,command -p "$(echo "$pids" | paste -sd, -)"
  echo "$pids" | xargs kill
  sleep 1

  pids="$(running_pids)"
  if [ -n "$pids" ]; then
    echo "Force stopping:"
    ps -o pid,ppid,etime,command -p "$(echo "$pids" | paste -sd, -)"
    echo "$pids" | xargs kill -9
  fi

  rm -f "$PID_FILE"
  echo "Stopped."
}

tail_log() {
  touch "$LOG_FILE"
  tail -f "$LOG_FILE"
}

cmd="${1:-status}"
case "$cmd" in
  status) status ;;
  start) start ;;
  kill|stop) kill_running ;;
  restart)
    kill_running
    start
    ;;
  tail|logs) tail_log ;;
  -h|--help|help) usage ;;
  *)
    usage
    exit 2
    ;;
esac
