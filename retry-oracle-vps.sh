#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional local overrides. Keep secrets in this file or environment variables.
ENV_FILE="${ORACLE_VPS_ENV_FILE:-$ROOT_DIR/oracle-vps.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/util.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/json.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/notify.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/oci.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/scheduler.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/process_guard.sh"

main() {
  # A managed worker owns one process; minimal containers may not include ps.
  if [ "${ORACLE_VPS_MANAGED:-0}" != "1" ]; then
    confirm_kill_existing_or_exit
  fi
  print_config_summary
  preflight
  exit_if_instance_exists
  resolve_targets
  resolve_images
  run_scheduler
}

main "$@"
