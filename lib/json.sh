#!/usr/bin/env bash

config_value() {
  python3 - "$CONFIG_FILE" "$PROFILE" "$1" <<'PY'
import configparser
import os
import sys

path, profile, key = sys.argv[1], sys.argv[2], sys.argv[3]
config = configparser.ConfigParser()
config.read(os.path.expanduser(path))
print(config.get(profile, key, fallback=""))
PY
}

json_first_id() {
  local json_file
  json_file="$(mktemp)"
  cat >"$json_file"

  python3 - "$json_file" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text().strip()
items = json.loads(raw).get("data", []) if raw else []
print(items[0].get("id", "") if items else "")
PY

  rm -f "$json_file"
}

json_lines() {
  local key="$1"
  local json_file
  json_file="$(mktemp)"
  cat >"$json_file"

  python3 - "$json_file" "$key" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text().strip()
key = sys.argv[2]
for item in (json.loads(raw).get("data", []) if raw else []):
    value = item.get(key)
    if value:
        print(value)
PY

  rm -f "$json_file"
}

json_existing_instance_id() {
  local json_file
  json_file="$(mktemp)"
  cat >"$json_file"

  python3 - "$json_file" "$INSTANCE_NAME" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text().strip()
target = sys.argv[2]
bad_states = {"TERMINATED", "TERMINATING"}
for item in (json.loads(raw).get("data", []) if raw else []):
    if item.get("display-name") == target and item.get("lifecycle-state") not in bad_states:
        print(item.get("id", ""))
        raise SystemExit
print("")
PY

  rm -f "$json_file"
}

json_capacity_result() {
  local json_file
  json_file="$(mktemp)"
  cat >"$json_file"

  python3 - "$json_file" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text().strip()
data = json.loads(raw).get("data", {}) if raw else {}
items = data.get("shape-availabilities") or data.get("shapeAvailabilities") or []

best_status = "UNKNOWN"
best_count = 0
for item in items:
    status = item.get("availability-status") or item.get("availabilityStatus") or "UNKNOWN"
    count = int(item.get("available-count") or item.get("availableCount") or 0)
    if status == "AVAILABLE" and count > 0:
        print(f"AVAILABLE|{count}")
        raise SystemExit
    if status != "UNKNOWN":
        best_status = status
        best_count = max(best_count, count)

print(f"{best_status}|{best_count}")
PY

  rm -f "$json_file"
}

shape_config_json() {
  local shape="$1"

  if [ "$shape" = "$A1_SHAPE" ]; then
    python3 - "$A1_OCPUS" "$A1_MEMORY_GBS" <<'PY'
import json
import sys

print(json.dumps({
    "ocpus": float(sys.argv[1]),
    "memoryInGBs": float(sys.argv[2]),
}, separators=(",", ":")))
PY
  fi
}

capacity_report_shape_json() {
  local shape="$1"
  local shape_config

  shape_config="$(shape_config_json "$shape")"
  python3 - "$shape" "$shape_config" <<'PY'
import json
import sys

item = {"instanceShape": sys.argv[1]}
if sys.argv[2]:
    item["instanceShapeConfig"] = json.loads(sys.argv[2])
print(json.dumps([item], separators=(",", ":")))
PY
}
