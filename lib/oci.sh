#!/usr/bin/env bash

TENANCY_OCID=""
USER_OCID=""
KEY_FILE=""
CONFIG_REGION=""
AD_LIST=()
VCN_OCID=""
SUBNET_OCID=""
A1_IMAGE_ID=""
E2_IMAGE_ID=""

oci_json_or_die() {
  local desc="$1"
  shift

  local err_file output status
  err_file="$(mktemp)"

  set +e
  output="$("$@" 2>"$err_file")"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    echo
    echo "OCI command failed: $desc"
    cat "$err_file"
    rm -f "$err_file"
    exit 1
  fi

  rm -f "$err_file"
  printf '%s' "$output"
}

preflight() {
  require_cmd oci
  require_cmd python3

  [ -f "$CONFIG_FILE" ] || die "OCI config not found: $CONFIG_FILE"
  [ -f "$SSH_PUBKEY_FILE" ] || die "SSH public key not found: $SSH_PUBKEY_FILE"

  TENANCY_OCID="$(config_value tenancy)"
  USER_OCID="$(config_value user)"
  KEY_FILE="$(config_value key_file)"
  CONFIG_REGION="$(config_value region)"

  [ -n "$TENANCY_OCID" ] || die "OCI config missing tenancy."
  [ -n "$USER_OCID" ] || die "OCI config missing user."
  [ -n "$KEY_FILE" ] || die "OCI config missing key_file."
  [ -f "$KEY_FILE" ] || die "OCI private key_file not found: $KEY_FILE"

  if [ -z "$COMPARTMENT_OCID" ]; then
    COMPARTMENT_OCID="$TENANCY_OCID"
  fi

  log_start "Testing OCI authentication"
  if ! oci os ns get --profile "$PROFILE" --region "$REGION" >/dev/null 2>/dev/null; then
    die "OCI authentication failed. Check user, tenancy, key_file, fingerprint and region in $CONFIG_FILE."
  fi
  log_success "OCI authentication OK"
}

exit_if_instance_exists() {
  log_start "Checking existing instance | name=$INSTANCE_NAME"

  local existing_json instance_id public_ip
  existing_json="$(
    oci_json_or_die "list existing instances" \
      oci compute instance list \
        --profile "$PROFILE" \
        --compartment-id "$COMPARTMENT_OCID" \
        --region "$REGION" \
        --all \
        --output json
  )"
  instance_id="$(printf '%s' "$existing_json" | json_existing_instance_id)"

  if [ -z "$instance_id" ]; then
    return 0
  fi

  log_success "Instance already exists | id=$instance_id"
  public_ip="$(public_ip_for_instance "$instance_id")"
  if [ -n "$public_ip" ] && [ "$public_ip" != "null" ]; then
    log_success "Public IP | $public_ip"
    log_success "SSH | ssh -i ~/.ssh/oracle-vps ubuntu@$public_ip"
  fi
  exit 0
}

resolve_targets() {
  log_start "Resolving availability domains, VCN and subnet"

  local ad_json vcn_json subnet_json
  ad_json="$(
    oci_json_or_die "list availability domains" \
      oci iam availability-domain list \
        --profile "$PROFILE" \
        --compartment-id "$TENANCY_OCID" \
        --region "$REGION" \
        --output json
  )"

  AD_LIST=()
  while IFS= read -r ad_name; do
    [ -n "$ad_name" ] && AD_LIST+=("$ad_name")
  done < <(printf '%s' "$ad_json" | json_lines name)

  vcn_json="$(
    oci_json_or_die "list VCNs" \
      oci network vcn list \
        --profile "$PROFILE" \
        --compartment-id "$COMPARTMENT_OCID" \
        --display-name "$VCN_NAME" \
        --region "$REGION" \
        --output json
  )"
  VCN_OCID="$(printf '%s' "$vcn_json" | json_first_id)"
  [ -n "$VCN_OCID" ] || die "VCN not found: $VCN_NAME"

  subnet_json="$(
    oci_json_or_die "list subnets" \
      oci network subnet list \
        --profile "$PROFILE" \
        --compartment-id "$COMPARTMENT_OCID" \
        --vcn-id "$VCN_OCID" \
        --display-name "$SUBNET_NAME" \
        --region "$REGION" \
        --output json
  )"
  SUBNET_OCID="$(printf '%s' "$subnet_json" | json_first_id)"

  [ "${#AD_LIST[@]}" -gt 0 ] || die "No availability domains found."
  [ -n "$SUBNET_OCID" ] || die "Subnet not found: $SUBNET_NAME"

  log_info "ADs: ${AD_LIST[*]}"
  log_info "VCN: $VCN_OCID"
  log_info "Subnet: $SUBNET_OCID"
}

resolve_images() {
  log_start "Resolving latest compatible images"
  A1_IMAGE_ID="$(latest_image_id "$A1_SHAPE")"
  E2_IMAGE_ID="$(latest_image_id "$E2_SHAPE")"

  [ -n "$A1_IMAGE_ID" ] && log_info "A1 image: $A1_IMAGE_ID" || log_warn "A1 image not found"
  [ -n "$E2_IMAGE_ID" ] && log_info "E2 image: $E2_IMAGE_ID" || log_warn "E2 image not found"
}

latest_image_id() {
  local shape="$1"

  oci_json_or_die "resolve image for $shape" \
    oci compute image list \
      --profile "$PROFILE" \
      --compartment-id "$COMPARTMENT_OCID" \
      --operating-system "$OS_NAME" \
      --operating-system-version "$OS_VERSION" \
      --shape "$shape" \
      --sort-by TIMECREATED \
      --sort-order DESC \
      --region "$REGION" \
      --all \
      --output json \
    | json_first_id
}

check_capacity() {
  local shape="$1"
  local ad_name="$2"
  local request output status kind err_file error_output

  request="$(capacity_report_shape_json "$shape")"
  err_file="$(mktemp)"

  set +e
  output="$(
    oci compute compute-capacity-report create \
      --profile "$PROFILE" \
      --availability-domain "$ad_name" \
      --compartment-id "$TENANCY_OCID" \
      --shape-availabilities "$request" \
      --region "$REGION" \
      --output json 2>"$err_file"
  )"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    error_output="$(cat "$err_file")"
    rm -f "$err_file"
    kind="$(classify_error "$error_output")"
    echo "$kind|0|$error_output"
    return 0
  fi

  rm -f "$err_file"
  printf '%s' "$output" | json_capacity_result
}

launch_instance() {
  local shape="$1"
  local ad_name="$2"
  local shape_config retry_token err_file output status error_output
  local cmd=()

  shape_config="$(shape_config_json "$shape")"
  retry_token="$(uuid_token)"

  cmd=(
    oci compute instance launch
    --profile "$PROFILE"
    --availability-domain "$ad_name"
    --compartment-id "$COMPARTMENT_OCID"
    --display-name "$INSTANCE_NAME"
    --hostname-label "$HOSTNAME_LABEL"
    --shape "$shape"
    --image-id "$(image_for_shape "$shape")"
    --subnet-id "$SUBNET_OCID"
    --assign-public-ip true
    --assign-private-dns-record true
    --ssh-authorized-keys-file "$SSH_PUBKEY_FILE"
    --instance-options '{"areLegacyImdsEndpointsDisabled":true}'
    --is-pv-encryption-in-transit-enabled true
    --opc-retry-token "$retry_token"
    --region "$REGION"
    --query 'data.id'
    --raw-output
  )

  if [ -n "$shape_config" ]; then
    cmd+=(--shape-config "$shape_config")
  fi

  err_file="$(mktemp)"
  set +e
  output="$("${cmd[@]}" 2>"$err_file")"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    error_output="$(cat "$err_file")"
    rm -f "$err_file"
    printf '%s' "$error_output"
    return "$status"
  fi

  rm -f "$err_file"
  printf '%s' "$output"
}

image_for_shape() {
  case "$1" in
    "$A1_SHAPE") echo "$A1_IMAGE_ID" ;;
    "$E2_SHAPE") echo "$E2_IMAGE_ID" ;;
    *) echo "" ;;
  esac
}

wait_instance_running() {
  local instance_id="$1"

  oci compute instance get \
    --profile "$PROFILE" \
    --instance-id "$instance_id" \
    --region "$REGION" \
    --wait-for-state RUNNING \
    --wait-interval-seconds 30 \
    --max-wait-seconds 900 >/dev/null
}

public_ip_for_instance() {
  local instance_id="$1"

  oci compute instance list-vnics \
    --profile "$PROFILE" \
    --instance-id "$instance_id" \
    --region "$REGION" \
    --query 'data[0]."public-ip"' \
    --raw-output 2>/dev/null || true
}
