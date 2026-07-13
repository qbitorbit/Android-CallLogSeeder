#!/bin/bash
set -euo pipefail

PACKAGE_NAME="com.qa.calllogseeder"
ACTIVITY_NAME="$PACKAGE_NAME/$PACKAGE_NAME.MainActivity"
WORKSPACE="$(cd "$(dirname "$0")" && pwd)"

prompt_yes_no() {
  local message="$1"
  local default="${2:-y}"
  local suffix="[Y/n]"
  if [[ "$default" != "y" ]]; then
    suffix="[y/N]"
  fi
  while true; do
    read -r -p "$message $suffix " answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
  done
}

prompt_choice() {
  local message="$1"
  shift
  local options=("$@")
  local default_index=0
  echo "$message" >&2
  local i=1
  for option in "${options[@]}"; do
    echo "  $i. $option" >&2
    i=$((i + 1))
  done
  while true; do
    read -r -p "Choose 1-${#options[@]} [$((default_index + 1))] " raw >&2
    raw="${raw:-$((default_index + 1))}"
    if [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= 1 && raw <= ${#options[@]} )); then
      echo "${options[$((raw - 1))]}"
      return
    fi
  done
}

prompt_multi_choice() {
  local message="$1"
  shift
  local options=("$@")
  local default_indexes=(0)
  echo "$message" >&2
  local i=1
  for option in "${options[@]}"; do
    echo "  $i. $option" >&2
    i=$((i + 1))
  done
  while true; do
    read -r -p "Choose one or more (comma-separated) [1] " raw >&2
    raw="${raw:-1}"
    IFS=',' read -r -a parts <<< "$raw"
    local selected=()
    local valid=1
    for part in "${parts[@]}"; do
      part="${part// /}"
      if [[ ! "$part" =~ ^[0-9]+$ ]] || (( part < 1 || part > ${#options[@]} )); then
        valid=0
        break
      fi
      local item="${options[$((part - 1))]}"
      local seen=0
      for existing in "${selected[@]}"; do
        if [[ "$existing" == "$item" ]]; then
          seen=1
          break
        fi
      done
      if (( seen == 0 )); then
        selected+=("$item")
      fi
    done
    if (( valid == 1 && ${#selected[@]} > 0 )); then
      printf '%s\n' "${selected[@]}"
      return
    fi
    echo "Invalid selection. Use values like 1 or 1,2,3." >&2
  done
}

prompt_int() {
  local message="$1"
  local default="$2"
  local min="$3"
  while true; do
    read -r -p "$message [$default] " raw
    raw="${raw:-$default}"
    if [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= min )); then
      echo "$raw"
      return
    fi
  done
}

prompt_date_millis() {
  local message="$1"
  while true; do
    read -r -p "$message (YYYY-MM-DD HH:mm) " raw
    if millis=$(date -j -f "%Y-%m-%d %H:%M" "$raw" "+%s000" 2>/dev/null); then
      echo "$millis"
      return
    fi
    echo "Invalid date/time. Use exact format YYYY-MM-DD HH:mm, for example 2026-07-01 12:00." >&2
  done
}

get_apk_path() {
  local candidates=(
    "$WORKSPACE/output/CallLogSeeder.apk"
    "$WORKSPACE/app/build/outputs/apk/debug/app-debug.apk"
  )
  for path in "${candidates[@]}"; do
    if [[ -f "$path" ]]; then
      echo "$path"
      return
    fi
  done
  echo "APK not found." >&2
  exit 1
}

mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
if (( ${#DEVICES[@]} == 0 )); then
  echo "No connected Android devices found." >&2
  exit 1
fi

select_devices() {
  if (( ${#DEVICES[@]} == 1 )); then
    printf '%s\n' "${DEVICES[0]}"
    return
  fi
  echo "Connected devices:" >&2
  local i=1
  for device in "${DEVICES[@]}"; do
    echo "  $i. $device" >&2
    i=$((i + 1))
  done
  echo "  $i. All devices" >&2
  while true; do
    read -r -p "Choose target [1] " raw >&2
    raw="${raw:-1}"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      if (( raw >= 1 && raw <= ${#DEVICES[@]} )); then
        printf '%s\n' "${DEVICES[$((raw - 1))]}"
        return
      fi
      if (( raw == ${#DEVICES[@]} + 1 )); then
        printf '%s\n' "${DEVICES[@]}"
        return
      fi
    fi
  done
}

ensure_installed() {
  local serial="$1"
  local apk="$2"
  if ! adb -s "$serial" shell pm list packages "$PACKAGE_NAME" | grep -q "$PACKAGE_NAME"; then
    echo "[$serial] Installing APK..."
    adb -s "$serial" install -r "$apk"
  fi
}

grant_permissions() {
  local serial="$1"
  local permissions=(
    "android.permission.READ_CALL_LOG"
    "android.permission.WRITE_CALL_LOG"
    "android.permission.READ_CONTACTS"
    "android.permission.WRITE_CONTACTS"
  )
  for permission in "${permissions[@]}"; do
    adb -s "$serial" shell pm grant "$PACKAGE_NAME" "$permission" >/dev/null 2>&1 || true
  done
}

resolve_prefixes() {
  mapfile -t choices < <(prompt_multi_choice "Phone number prefixes:" \
    "Israel (+97255000)" \
    "UK (+447700)" \
    "Germany (+491510)" \
    "Custom prefix" \
    "Mixed presets (Israel + UK + Germany)")
  local prefixes=()
  for choice in "${choices[@]}"; do
    case "$choice" in
      "Israel (+97255000)") prefixes+=("+97255000") ;;
      "UK (+447700)") prefixes+=("+447700") ;;
      "Germany (+491510)") prefixes+=("+491510") ;;
      "Mixed presets (Israel + UK + Germany)")
        prefixes+=("+97255000" "+447700" "+491510")
        ;;
      "Custom prefix")
        read -r -p "Custom prefix " custom
        if [[ -n "${custom:-}" ]]; then
          prefixes+=("$custom")
        fi
        ;;
    esac
  done
  if (( ${#prefixes[@]} == 0 )); then
    prefixes=("+97255000")
  fi
  printf '%s\n' "${prefixes[@]}" | awk '!seen[$0]++'
}

declare -a EXTRA_ARGS=()

add_extra() {
  EXTRA_ARGS+=("$1" "$2" "$3")
}

resolve_dates() {
  while true; do
    mapfile -t choices < <(prompt_multi_choice "Random date window:" \
      "Last week" \
      "Last month" \
      "Last year" \
      "Mixed presets (week + month + year)" \
      "Custom range")
    local has_custom=0
    for choice in "${choices[@]}"; do
      [[ "$choice" == "Custom range" ]] && has_custom=1
    done
    if (( has_custom == 1 )); then
      if (( ${#choices[@]} > 1 )); then
        echo "Custom range cannot be combined with preset windows." >&2
        continue
      fi
      local start end
      start=$(prompt_date_millis "Start date/time")
      end=$(prompt_date_millis "End date/time")
      add_extra --es startTimeMillis "$start"
      add_extra --es endTimeMillis "$end"
      return
    fi
    local days=()
    for choice in "${choices[@]}"; do
      case "$choice" in
        "Last week") days+=(7) ;;
        "Last month") days+=(30) ;;
        "Last year") days+=(365) ;;
        "Mixed presets (week + month + year)") days+=(7 30 365) ;;
      esac
    done
    if (( ${#days[@]} == 0 )); then
      days=(7)
    fi
    mapfile -t unique_days < <(printf '%s\n' "${days[@]}" | awk '!seen[$0]++')
    add_extra --es daysBackOptions "$(IFS=,; echo "${unique_days[*]}")"
    return
  done
}

resolve_duration() {
  if prompt_yes_no "Use default duration range 0-3600 seconds?" y; then
    add_extra --ei durationMin 0
    add_extra --ei durationMax 3600
    return
  fi
  local min max
  min=$(prompt_int "Minimum duration seconds" 0 0)
  max=$(prompt_int "Maximum duration seconds" 3600 "$min")
  add_extra --ei durationMin "$min"
  add_extra --ei durationMax "$max"
}

build_seed_args() {
  EXTRA_ARGS=()
  mapfile -t prefixes < <(resolve_prefixes)
  add_extra --es prefixes "$(IFS=,; echo "${prefixes[*]}")"
  if prompt_yes_no "Create fake contacts too?" n; then
    add_extra --ez createFakeContacts true
  else
    add_extra --ez createFakeContacts false
  fi
  resolve_dates
  resolve_duration

  local mode
  mode=$(prompt_choice "Generation mode:" \
    "Mixed random mode (enter one total; call type, prefix, and preset date window are randomized)" \
    "Exact counts per call type")
  if [[ "$mode" == "Mixed random mode (enter one total; call type, prefix, and preset date window are randomized)" ]]; then
    local total
    total=$(prompt_int "How many total random call logs should be created?" 500 1)
    add_extra --ei mixedTotal "$total"
  else
    add_extra --ei incoming "$(prompt_int "Incoming count" 0 0)"
    add_extra --ei outgoing "$(prompt_int "Outgoing count" 0 0)"
    add_extra --ei missed "$(prompt_int "Missed count" 0 0)"
    add_extra --ei rejected "$(prompt_int "Rejected count" 0 0)"
    add_extra --ei blocked "$(prompt_int "Blocked count" 0 0)"
  fi
}

build_delete_args() {
  EXTRA_ARGS=()
  mapfile -t prefixes < <(resolve_prefixes)
  add_extra --es action delete
  add_extra --es prefixes "$(IFS=,; echo "${prefixes[*]}")"
  if prompt_yes_no "Also delete fake contacts with these prefixes?" n; then
    add_extra --ez deleteContacts true
  else
    add_extra --ez deleteContacts false
  fi
}

invoke_activity() {
  local serial="$1"
  adb -s "$serial" shell am start -S -n "$ACTIVITY_NAME" "${EXTRA_ARGS[@]}"
}

uninstall_app() {
  local serial="$1"
  echo "[$serial] Uninstalling $PACKAGE_NAME ..."
  adb -s "$serial" uninstall "$PACKAGE_NAME"
}

APK_PATH="$(get_apk_path)"
mapfile -t TARGETS < <(select_devices)
MODE=$(prompt_choice "What do you want to do?" "Seed call logs" "Delete generated data")

if [[ "$MODE" == "Seed call logs" ]]; then
  build_seed_args
else
  build_delete_args
fi

for serial in "${TARGETS[@]}"; do
  echo
  echo "Processing device: $serial"
  ensure_installed "$serial" "$APK_PATH"
  grant_permissions "$serial"
  invoke_activity "$serial"
done

if prompt_yes_no "Uninstall the app from the selected device(s) now?" n; then
  for serial in "${TARGETS[@]}"; do
    uninstall_app "$serial"
  done
fi

echo
echo "Done."
