#!/usr/bin/env bash

: "${REGION:=ap-singapore-1}"
: "${COMPARTMENT_OCID:=}"

: "${INSTANCE_NAME:=oracle-vps}"
: "${HOSTNAME_LABEL:=oracle-vps}"
: "${VCN_NAME:=main-vcn}"
: "${SUBNET_NAME:=public-subnet}"

: "${OS_NAME:=Canonical Ubuntu}"
: "${OS_VERSION:=24.04}"
: "${SSH_PUBKEY_FILE:=$HOME/.ssh/oracle-vps.pub}"

: "${CONFIG_FILE:=${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}}"
: "${PROFILE:=${OCI_CLI_PROFILE:-DEFAULT}}"

: "${A1_SHAPE:=VM.Standard.A1.Flex}"
: "${A1_OCPUS:=1}"
: "${A1_MEMORY_GBS:=6}"
: "${A1_INTERVAL_SECONDS:=3000}" # 50 minutes
: "${A1_JITTER_SECONDS:=300}"    # +/- 5 minutes

: "${E2_SHAPE:=VM.Standard.E2.1.Micro}"
: "${E2_AD_NAME:=}"                  # Optional: pin E2 to a known supported AD.
: "${E2_PROBABILITY:=0.30}"          # Expected 3 E2 attempts per 10 A1 attempts.
: "${E2_DELAY_AFTER_A1_SECONDS:=1200}" # 20 minutes after an A1 attempt.
: "${E2_JITTER_SECONDS:=300}"        # +/- 5 minutes

: "${MIN_REQUEST_GAP_SECONDS:=1200}" # Avoid back-to-back capacity checks after throttling.
: "${THROTTLE_BASE_SECONDS:=3600}"
: "${THROTTLE_CAP_SECONDS:=43200}"
: "${THROTTLE_JITTER_SECONDS:=600}"
: "${MAX_LOOPS:=0}"

: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"

print_config_summary() {
  log_info "Runtime configuration"
  cat <<EOF
Region: $REGION
Profile: $PROFILE
Config: $CONFIG_FILE
Compartment: ${COMPARTMENT_OCID:-<root tenancy>}
Instance: $INSTANCE_NAME
Image: $OS_NAME $OS_VERSION

Policy:
- A1: every $(seconds_to_human "$A1_INTERVAL_SECONDS") +/- $(seconds_to_human "$A1_JITTER_SECONDS")
- E2: probability $E2_PROBABILITY after A1, delayed $(seconds_to_human "$E2_DELAY_AFTER_A1_SECONDS") +/- $(seconds_to_human "$E2_JITTER_SECONDS")
- Minimum request gap: $(seconds_to_human "$MIN_REQUEST_GAP_SECONDS")
EOF
}
