#!/usr/bin/env bash

current_process_tree_pids() {
  local exclude pid

  exclude=" $$ "
  pid="${PPID:-}"

  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    exclude="${exclude}${pid} "
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  done

  echo "$exclude"
}

running_retry_pids_for_current_tree() {
  local exclude

  exclude="$(current_process_tree_pids)"
  running_retry_pids_excluding "$exclude"
}

running_retry_pids_excluding() {
  local exclude="$1"

  ps -axo pid=,command= | awk -v exclude="$exclude" '
    index(exclude, " " $1 " ") {
      next
    }
    index($0, "retry-oracle-vps.sh") && !index($0, "oracle-vpsctl.sh") {
      print $1
    }
  '
}

running_retry_pids() {
  running_retry_pids_for_current_tree
}

live_retry_pids() {
  local pid command

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue

    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [ -n "$command" ] || continue

    case "$command" in
      *retry-oracle-vps.sh*)
        case "$command" in
          *oracle-vpsctl.sh*) ;;
          *) echo "$pid" ;;
        esac
        ;;
    esac
  done
}

retry_pids_csv() {
  paste -sd, -
}

kill_retry_pids() {
  local pids="$1"

  echo "$pids" | xargs kill 2>/dev/null || true
  sleep 1

  pids="$(running_retry_pids | live_retry_pids)"
  if [ -n "$pids" ]; then
    echo "$pids" | xargs kill -9 2>/dev/null || true
  fi
}

confirm_kill_existing_or_exit() {
  local pids pid_csv answer

  pids="$(running_retry_pids | live_retry_pids)"
  [ -n "$pids" ] || return 0

  pid_csv="$(echo "$pids" | retry_pids_csv)"
  [ -n "$pid_csv" ] || return 0

  log_warn "Found existing retry-oracle-vps.sh process(es)"
  ps -o pid,ppid,etime,command -p "$pid_csv" || true
  echo

  if ! read -r -p "Kill existing process(es) and continue? [Y/N] " answer; then
    log_warn "No interactive input. Existing process kept running"
    exit 1
  fi

  case "$answer" in
    Y|y) kill_retry_pids "$pids" ;;
    *)
      log_warn "Exit. Existing process kept running"
      exit 1
      ;;
  esac
}
