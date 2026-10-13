#!/usr/bin/env bash

A1_NEXT_TS=0
E2_NEXT_TS=0
E2_PENDING=0
A1_AD_INDEX=0
E2_AD_INDEX=0
THROTTLE_LEVEL=0
THROTTLE_UNTIL=0
LAST_REQUEST_TS=0
LAST_ATTEMPT_RESULT="NONE"

run_scheduler() {
  local loop=0

  while true; do
    loop=$((loop + 1))
    if [ "$MAX_LOOPS" -gt 0 ] && [ "$loop" -gt "$MAX_LOOPS" ]; then
      die "Reached MAX_LOOPS=$MAX_LOOPS."
    fi

    run_next_due_attempt
  done
}

run_next_due_attempt() {
  local now kind

  wait_until_due
  wait_for_request_gap

  now="$(now_ts)"
  kind="$(next_due_kind "$now")"

  case "$kind" in
    A1) attempt_a1 ;;
    E2) attempt_e2 ;;
    *) sleep 5 ;;
  esac
}

next_due_kind() {
  local now="$1"

  if [ "$A1_NEXT_TS" -le "$now" ]; then
    echo "A1"
    return
  fi

  if [ "$E2_PENDING" -eq 1 ] && [ "$E2_NEXT_TS" -le "$now" ]; then
    echo "E2"
    return
  fi

  echo ""
}

wait_until_due() {
  local now target sleep_seconds

  while true; do
    now="$(now_ts)"
    target="$(next_due_ts)"

    if [ "$target" -lt "$THROTTLE_UNTIL" ]; then
      target="$THROTTLE_UNTIL"
    fi

    [ "$target" -le "$now" ] && return 0

    sleep_seconds=$((target - now))
    log_wait "Next check in $(seconds_to_human "$sleep_seconds")"
    sleep "$sleep_seconds"
  done
}

next_due_ts() {
  local target="$A1_NEXT_TS"

  if [ "$E2_PENDING" -eq 1 ] && [ "$E2_NEXT_TS" -lt "$target" ]; then
    target="$E2_NEXT_TS"
  fi

  echo "$target"
}

wait_for_request_gap() {
  local now elapsed wait_seconds

  [ "$LAST_REQUEST_TS" -gt 0 ] || return 0

  now="$(now_ts)"
  elapsed=$((now - LAST_REQUEST_TS))
  [ "$elapsed" -ge "$MIN_REQUEST_GAP_SECONDS" ] && return 0

  wait_seconds=$((MIN_REQUEST_GAP_SECONDS - elapsed))
  log_wait "Request gap cooldown: $(seconds_to_human "$wait_seconds")"
  sleep "$wait_seconds"
}

attempt_a1() {
  log_start "A1 request window opened"
  attempt_shape "$A1_SHAPE" "$(next_a1_ad)"
  if [ "$LAST_ATTEMPT_RESULT" = "THROTTLE" ]; then
    return 0
  fi

  schedule_next_a1
  maybe_schedule_e2
}

attempt_e2() {
  local ad_name

  log_start "E2 request window opened"
  ad_name="${E2_AD_NAME:-$(next_e2_ad)}"
  attempt_shape "$E2_SHAPE" "$ad_name"
  E2_PENDING=0
  E2_NEXT_TS=0
}

attempt_shape() {
  local shape="$1"
  local ad_name="$2"
  local image_id result status count output code error_kind instance_id public_ip

  LAST_ATTEMPT_RESULT="UNKNOWN"

  image_id="$(image_for_shape "$shape")"
  if [ -z "$image_id" ]; then
    log_warn "$shape skipped: no compatible image"
    LAST_ATTEMPT_RESULT="SKIPPED"
    return 0
  fi

  log_start "Capacity check | shape=$shape | AD=$ad_name"
  LAST_REQUEST_TS="$(now_ts)"
  result="$(check_capacity "$shape" "$ad_name")"
  status="${result%%|*}"
  count="$(echo "$result" | cut -d'|' -f2)"

  case "$status" in
    AVAILABLE)
      reset_throttle
      log_result "AVAILABLE | shape=$shape | AD=$ad_name | count=$count"
      log_start "Launching instance once | shape=$shape | AD=$ad_name"
      set +e
      output="$(launch_instance "$shape" "$ad_name")"
      code=$?
      set -e

      if [ "$code" -ne 0 ]; then
        error_kind="$(classify_error "$output")"
        handle_launch_error "$shape" "$error_kind" "$output"
        return 0
      fi

      instance_id="$output"
      log_success "Instance created | id=$instance_id"
      wait_instance_running "$instance_id"
      public_ip="$(public_ip_for_instance "$instance_id")"

      echo
      log_success "DONE | shape=$shape | AD=$ad_name | public_ip=$public_ip"
      log_success "SSH | ssh -i ~/.ssh/oracle-vps ubuntu@$public_ip"

      notify_success "$shape" "$ad_name" "$instance_id" "$public_ip"
      exit 0
      ;;
    OUT_OF_HOST_CAPACITY|HARDWARE_NOT_SUPPORTED)
      reset_throttle
      LAST_ATTEMPT_RESULT="CAPACITY"
      log_result "NOT_AVAILABLE | shape=$shape | AD=$ad_name | reason=$status"
      ;;
    THROTTLE)
      schedule_throttle
      LAST_ATTEMPT_RESULT="THROTTLE"
      log_warn "THROTTLED | backoff_until=$(ts_iso "$THROTTLE_UNTIL")"
      ;;
    LIMIT|FATAL)
      output="$(echo "$result" | cut -d'|' -f3-)"
      echo "$output"
      die "$shape stopped due to $status."
      ;;
    *)
      LAST_ATTEMPT_RESULT="$status"
      log_result "UNKNOWN_RESULT | shape=$shape | AD=$ad_name | status=$status"
      ;;
  esac
}

handle_launch_error() {
  local shape="$1"
  local kind="$2"
  local output="$3"

  echo "$output"

  case "$kind" in
    THROTTLE)
      schedule_throttle
      LAST_ATTEMPT_RESULT="THROTTLE"
      ;;
    CAPACITY)
      reset_throttle
      LAST_ATTEMPT_RESULT="CAPACITY"
      log_warn "Capacity disappeared between report and launch | shape=$shape"
      ;;
    LIMIT|FATAL)
      die "$shape launch failed with $kind."
      ;;
    *)
      LAST_ATTEMPT_RESULT="UNKNOWN"
      log_fail "Launch failed with UNKNOWN | shape=$shape"
      ;;
  esac
}

schedule_next_a1() {
  local wait_seconds

  wait_seconds="$(jittered_seconds "$A1_INTERVAL_SECONDS" "$A1_JITTER_SECONDS")"
  A1_NEXT_TS=$(($(now_ts) + wait_seconds))
  log_wait "Next A1 in $(seconds_to_human "$wait_seconds") | at=$(ts_iso "$A1_NEXT_TS")"
}

maybe_schedule_e2() {
  local wait_seconds

  if [ "$E2_PENDING" -eq 1 ]; then
    return 0
  fi

  if ! chance "$E2_PROBABILITY"; then
    log_result "E2_SKIPPED | probability_gate=$E2_PROBABILITY"
    return 0
  fi

  wait_seconds="$(jittered_seconds "$E2_DELAY_AFTER_A1_SECONDS" "$E2_JITTER_SECONDS")"
  E2_NEXT_TS=$(($(now_ts) + wait_seconds))
  E2_PENDING=1
  log_wait "E2 scheduled in $(seconds_to_human "$wait_seconds") | at=$(ts_iso "$E2_NEXT_TS")"
}

schedule_throttle() {
  local wait_seconds now

  THROTTLE_LEVEL=$((THROTTLE_LEVEL + 1))
  wait_seconds=$((THROTTLE_BASE_SECONDS * THROTTLE_LEVEL))
  if [ "$wait_seconds" -gt "$THROTTLE_CAP_SECONDS" ]; then
    wait_seconds="$THROTTLE_CAP_SECONDS"
  fi
  wait_seconds="$(jittered_seconds "$wait_seconds" "$THROTTLE_JITTER_SECONDS")"

  now="$(now_ts)"
  THROTTLE_UNTIL=$((now + wait_seconds))
  log_warn "Throttle level $THROTTLE_LEVEL | backoff=$(seconds_to_human "$wait_seconds")"
}

reset_throttle() {
  THROTTLE_LEVEL=0
  THROTTLE_UNTIL=0
}

next_a1_ad() {
  local idx=$((A1_AD_INDEX % ${#AD_LIST[@]}))
  A1_AD_INDEX=$((A1_AD_INDEX + 1))
  echo "${AD_LIST[$idx]}"
}

next_e2_ad() {
  local idx=$((E2_AD_INDEX % ${#AD_LIST[@]}))
  E2_AD_INDEX=$((E2_AD_INDEX + 1))
  echo "${AD_LIST[$idx]}"
}
