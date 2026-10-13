#!/usr/bin/env bash

notify_success() {
  local shape="$1"
  local ad_name="$2"
  local instance_id="$3"
  local public_ip="$4"

  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log_warn "Telegram skipped: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID is empty"
    return 0
  fi

  if TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
    NOTIFY_SHAPE="$shape" NOTIFY_AD="$ad_name" NOTIFY_ID="$instance_id" \
    NOTIFY_IP="$public_ip" python3 - <<'PYTHON'
import json
import os
import sys
import urllib.request

message = (
    "Oracle VPS created\n\n"
    f"Shape: {os.environ['NOTIFY_SHAPE']}\n"
    f"AD: {os.environ['NOTIFY_AD']}\n"
    f"Public IP: {os.environ['NOTIFY_IP']}\n"
    f"Instance OCID: {os.environ['NOTIFY_ID']}\n\n"
    f"SSH: ssh -i ~/.ssh/oracle-vps ubuntu@{os.environ['NOTIFY_IP']}"
)
request = urllib.request.Request(
    "https://api.telegram.org/bot" + os.environ["TELEGRAM_BOT_TOKEN"] + "/sendMessage",
    data=json.dumps({"chat_id": os.environ["TELEGRAM_CHAT_ID"], "text": message}).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        if not json.load(response).get("ok"):
            raise ValueError("Telegram rejected the message")
except Exception:
    # Exception strings can contain the request URL and its bot token.
    print("Telegram API request failed", file=sys.stderr)
    sys.exit(1)
PYTHON
  then
    log_success "Telegram notification sent"
  else
    log_warn "Telegram notification failed"
  fi
  return 0
}
