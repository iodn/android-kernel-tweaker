#!/system/bin/sh

ensure_util_loaded() {
  local d0
  if [ -n "${LOG_FILE:-}" ] && [ -n "${BASELINE_DB:-}" ] && [ -n "${STATE_DIR:-}" ]; then
    return 0
  fi

  if [ -n "${AKTUNE_MODDIR:-}" ] && [ -f "$AKTUNE_MODDIR/common/util.sh" ]; then
    . "$AKTUNE_MODDIR/common/util.sh"
  else
    d0="${0%/*}"
    [ -f "$d0/util.sh" ] && . "$d0/util.sh"
    [ -f "$d0/../common/util.sh" ] && . "$d0/../common/util.sh"
  fi

  AKTUNE_DATA_DIR="${AKTUNE_DATA_DIR:-/data/adb/aktune}"
  STATE_DIR="${STATE_DIR:-$AKTUNE_DATA_DIR/state}"
  LOG_DIR="${LOG_DIR:-$AKTUNE_DATA_DIR/logs}"
  BASELINE_DB="${BASELINE_DB:-$STATE_DIR/baseline.tsv}"
  BLOCKED_DB="${BLOCKED_DB:-$STATE_DIR/blocked.tsv}"
  LOG_FILE="${LOG_FILE:-$LOG_DIR/aktune.log}"

  mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null
  [ -f "$BASELINE_DB" ] || : > "$BASELINE_DB"
  [ -f "$BLOCKED_DB" ] || : > "$BLOCKED_DB"
  [ -f "$LOG_FILE" ] || : > "$LOG_FILE"
}

_extract_bracket_active() {
  local s t
  # For scheduler/comp_algorithm: "none [mq-deadline] kyber"
  s="$1"
  case "$s" in
    *"["*"]"*)
      t="${s#*[}"
      t="${t%%]*}"
      echo "$t"
      ;;
    *) echo "" ;;
  esac
}

_normalize_baseline_value() {
  local path val picked
  path="$1"
  val="$2"
  case "$path" in
    */scheduler|*/comp_algorithm)
      picked="$(_extract_bracket_active "$val")"
      [ -n "$picked" ] && val="$picked"
      ;;
  esac
  echo "$val"
}

_verify_effective() {
  local path wanted got
  path="$1"
  wanted="$2"
  got="$3"

  case "$path" in
    */scheduler|*/comp_algorithm)
      case "$got" in *"[$wanted]"*) return 0 ;; esac
      ;;
  esac

  case "$path" in
    */cpu.uclamp.min|*/cpu.uclamp.max)
      # cgroup v2 reads percentages with two decimal places.
      [ "$got" = "$wanted.00" ] && return 0
      ;;
  esac

  [ "$wanted" = "$got" ]
}

read_node() {
  local path
  ensure_util_loaded
  path="$1"
  [ -e "$path" ] || return 1

  # Prefer pure-sh reader
  if command -v cat >/dev/null 2>&1; then
    cat "$path" 2>/dev/null
    return $?
  fi

  akt_read_file "$path" 2>/dev/null
}

blocked_has() {
  local p bp reason
  ensure_util_loaded
  p="$1"
  [ -n "$p" ] || return 1
  [ -f "$BLOCKED_DB" ] || return 1
  while IFS="$(printf '\t')" read -r bp reason; do
    bp="${bp%"$AKTUNE_CR"}"
    [ -n "$bp" ] || continue
    [ "$bp" = "$p" ] && return 0
  done < "$BLOCKED_DB"
  return 1
}

blocked_add() {
  local p reason
  ensure_util_loaded
  p="$1"
  reason="$2"
  [ -n "$p" ] || return 0
  blocked_has "$p" && return 0
  printf "%s\t%s\n" "$p" "${reason:-blocked}" >> "$BLOCKED_DB" 2>/dev/null
}

save_baseline_once() {
  local path cur bp bv cur_clean
  ensure_util_loaded
  path="$1"
  cur="$2"
  [ -n "$path" ] || return 1
  [ -f "$BASELINE_DB" ] || : > "$BASELINE_DB"

  while IFS="$(printf '\t')" read -r bp bv; do
    bp="${bp%"$AKTUNE_CR"}"
    [ -n "$bp" ] || continue
    [ "$bp" = "$path" ] && return 0
  done < "$BASELINE_DB"

  cur_clean="$(akt_trim_ws "$cur")"
  cur_clean="$(_normalize_baseline_value "$path" "$cur_clean")"
  cur_clean="$(akt_trim_ws "$cur_clean")"
  printf "%s\t%s\n" "$path" "$cur_clean" >> "$BASELINE_DB" 2>/dev/null
}

baseline_get() {
  local path bp bv
  ensure_util_loaded
  path="$1"
  [ -n "$path" ] || return 1
  [ -f "$BASELINE_DB" ] || return 1
  while IFS="$(printf '\t')" read -r bp bv; do
    bp="${bp%"$AKTUNE_CR"}"
    [ -n "$bp" ] || continue
    if [ "$bp" = "$path" ]; then
      bv="${bv%"$AKTUNE_CR"}"
      echo "$bv"
      return 0
    fi
  done < "$BASELINE_DB"
  return 1
}

baseline_restore_node() {
  local path v
  ensure_util_loaded
  path="$1"
  [ -n "$path" ] || return 1
  v="$(baseline_get "$path")"
  [ -n "$v" ] || return 1
  [ -e "$path" ] || return 0
  write_node "$path" "$v" restore
}

write_node() {
  local path value old old_trim value_trim new new_trim
  ensure_util_loaded
  path="$1"
  value="$2"
  [ -n "$path" ] || return 1
  [ -e "$path" ] || return 2
  if [ "${3:-}" != "restore" ]; then
    blocked_has "$path" && return 2
  fi

  old="$(read_node "$path")" || return 1
  old_trim="$(akt_trim_ws "$old")"
  value_trim="$(akt_trim_ws "$value")"
  [ -n "$old_trim" ] && [ -n "$value_trim" ] || return 1
  _verify_effective "$path" "$value_trim" "$old_trim" && return 0

  save_baseline_once "$path" "$old_trim" || return 1
  log_i "Try: $path = $value_trim (was $old_trim)"

  if { printf "%s\n" "$value_trim" > "$path"; } 2>/dev/null; then
    new="$(read_node "$path")"
    new_trim="$(akt_trim_ws "$new")"

    if _verify_effective "$path" "$value_trim" "$new_trim"; then
      log_i "Set: $path = $value_trim"
      return 0
    fi
    log_w "Write verify mismatch: $path wanted '$value_trim' got '$new_trim'"
    blocked_add "$path" "verify_mismatch"
    return 1
  fi

  log_w "Failed to write: $path = $value_trim"
  blocked_add "$path" "write_failed"
  return 1
}

write_node_if_exists() {
  [ -e "$1" ] || return 0
  write_node "$1" "$2"
}

restore_baseline_all() {
  local path value
  ensure_util_loaded
  [ -f "$BASELINE_DB" ] || { log_w "No baseline DB found"; return 0; }

  while IFS="$(printf '\t')" read -r path value; do
    path="$(akt_strip_cr "$path")"
    value="$(akt_strip_cr "$value")"
    [ -n "$path" ] || continue
    [ -e "$path" ] || continue
    { printf "%s\n" "$value" > "$path"; } 2>/dev/null && log_i "Restored baseline: $path = $value"
  done < "$BASELINE_DB"
}
