#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for omarchy-migrate.
#
# This file is sourced. It must not have side effects at source time beyond
# defining functions and constants, so the test suite can source it freely.

OM_SCHEMA=1

# Resolved by the entry points before sourcing.
: "${OM_ROOT:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
OM_VERSION="$(tr -d '[:space:]' <"$OM_ROOT/VERSION" 2>/dev/null || echo 0.0.0)"

# Runtime directories. Overridable for tests.
: "${OM_RUN_DIR:=/run/omarchy-migrate}"
: "${OM_LOG:=/var/log/omarchy-migrate.log}"
: "${OM_STATE_MNT:=$OM_RUN_DIR/state-esp}"
: "${OM_SRC_ESP_MNT:=$OM_RUN_DIR/source-esp}"
: "${OM_SRC_TOP:=$OM_RUN_DIR/source-top}"
: "${OM_SRC_MNT:=$OM_RUN_DIR/source}"
: "${OM_TGT_TOP:=$OM_RUN_DIR/target-top}"
: "${OM_TGT_MNT:=$OM_RUN_DIR/target}"
: "${OM_LIVE:=0}"
: "${OM_DRY_RUN:=0}"
: "${OM_FORCE_STEP:=}"

# Populated by the entry point / step runner.
: "${LAST_ERROR:=}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_om_timestamp() { date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'; }

om_log_init() {
  local logdir
  logdir="$(dirname -- "$OM_LOG")"
  mkdir -p -- "$logdir" 2>/dev/null || true
  touch -- "$OM_LOG" 2>/dev/null || {
    OM_LOG="${TMPDIR:-/tmp}/omarchy-migrate.log"
    touch -- "$OM_LOG"
  }
  chmod 600 -- "$OM_LOG" 2>/dev/null || true
}

# Append one line to the log. Never writes to stdout: verbose output stays out
# of the Omarchy-style live UI.
om_log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(_om_timestamp)" "$level" "$*" >>"$OM_LOG"
}

om_debug() {
  [[ ${OM_DEBUG:-0} == 1 ]] || return 0
  om_log DEBUG "$*"
  printf '  %s\n' "$*" >&2
}

om_info() {
  om_log INFO "$*"
}

om_warn() {
  om_log WARN "$*"
  printf '\033[38;5;214m  ! %s\033[0m\n' "$*" >&2
}

om_error() {
  om_log ERROR "$*"
  LAST_ERROR="$*"
  printf '\033[38;5;203m  x %s\033[0m\n' "$*" >&2
}

om_say() {
  printf '%s\n' "$*"
}

om_die() {
  om_error "$*"
  exit 1
}

# Log a command and its output, preserving the exit code without aborting the
# caller. Used for every non-interactive destructive command.
om_run_logged() {
  om_log INFO "run: $*"
  "$@" >>"$OM_LOG" 2>&1
}

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------

om_init_runtime() {
  if [[ $EUID -ne 0 ]]; then
    : "${OM_LOG:=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-migrate/migrate.log}"
  fi
  mkdir -p -- "$OM_RUN_DIR"
  om_log_init
  om_log INFO "omarchy-migrate $OM_VERSION (root=$EUID live=$OM_LIVE)"
}

om_lock() {
  mkdir -p -- "$OM_RUN_DIR"
  exec 9>"$OM_RUN_DIR/lock"
  if ! flock -n 9; then
    om_die "Another omarchy-migrate instance is already running."
  fi
}

om_have() { command -v -- "$1" >/dev/null 2>&1; }

om_need() {
  local cmd
  for cmd in "$@"; do
    om_have "$cmd" || om_die "Required command not found: $cmd"
  done
}

om_is_uefi() { [[ -d /sys/firmware/efi ]]; }

om_is_live() {
  [[ $OM_LIVE == 1 || -d /run/archiso ]]
}

om_now() { _om_timestamp; }

om_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

om_human_bytes() {
  local bytes="${1:-0}"
  if om_have numfmt; then
    numfmt --to=iec-i --suffix=B --format='%.1f' "$bytes" 2>/dev/null || printf '%s B' "$bytes"
  else
    printf '%s B' "$bytes"
  fi
}

# /dev/nvme0n1 -> /dev/nvme0n1p1, /dev/sda -> /dev/sda1
om_part_path() {
  local disk="$1" num="$2"
  if [[ $disk =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$num"
  else
    printf '%s%s\n' "$disk" "$num"
  fi
}

om_trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

om_fingerprint() {
  local root="${1:-$OM_ROOT}"
  (
    cd -- "$root" || exit 1
    {
      printf '%s\n' "$(tr -d '[:space:]' <VERSION 2>/dev/null)"
      find bin lib live menu systemd -type f ! -name '*.swp' -print0 2>/dev/null |
        sort -z |
        xargs -0 -r sha256sum
    } | sha256sum | awk '{print $1}'
  )
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

declare -a OM_CLEANUP=()
_OM_CLEANUP_ARMED=0
_OM_CLEANUP_RUNNING=0

om_cleanup_add() {
  OM_CLEANUP+=("$1")
  if [[ $_OM_CLEANUP_ARMED == 0 ]]; then
    _OM_CLEANUP_ARMED=1
    trap om_cleanup EXIT INT TERM HUP
  fi
}

om_cleanup() {
  [[ $_OM_CLEANUP_RUNNING == 1 ]] && return 0
  _OM_CLEANUP_RUNNING=1
  trap - EXIT INT TERM HUP
  local cmd
  for ((i = ${#OM_CLEANUP[@]} - 1; i >= 0; i--)); do
    cmd="${OM_CLEANUP[i]}"
    om_log INFO "cleanup: $cmd"
    eval "$cmd" >>"$OM_LOG" 2>&1 || true
  done
  OM_CLEANUP=()
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

om_notify() {
  local title="$1" body="${2:-}"
  if om_have omarchy-notification-send; then
    omarchy-notification-send "$title" "$body" >>"$OM_LOG" 2>&1 || true
  elif om_have notify-send; then
    notify-send "$title" "$body" >>"$OM_LOG" 2>&1 || true
  else
    printf '\n%s\n%s\n' "$title" "$body"
  fi
}

# ---------------------------------------------------------------------------
# Device helpers shared by detection and migration
# ---------------------------------------------------------------------------

# Print the whole-disk device that contains a partition or mapper device.
# Walks up the lsblk parent chain (mapper -> partition -> disk).
om_parent_disk() {
  local cur="$1" parent type
  local -i guard=0
  while ((guard++ < 16)); do
    type="$(lsblk -dno TYPE -- "$cur" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    if [[ $type == disk ]]; then
      printf '%s\n' "$cur"
      return 0
    fi
    parent="$(lsblk -no PKNAME -- "$cur" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    [[ -n $parent ]] || return 1
    cur="/dev/$parent"
  done
  return 1
}

om_disk_field() {
  local disk="$1" field="$2"
  lsblk -dno "$field" -- "$disk" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

om_part_field() {
  local part="$1" field="$2"
  lsblk -no "$field" -- "$part" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

om_partitions() {
  local disk="$1"
  lsblk -nrpo NAME,TYPE -- "$disk" 2>/dev/null | awk '$2 == "part" { print $1 }'
}

om_mapper_path() {
  printf '/dev/mapper/%s\n' "$1"
}

om_require_root() {
  [[ $EUID -eq 0 ]] || om_die "This operation requires root. Run it through the Omarchy menu or with sudo."
}

# Re-exec the current script under sudo, preserving the lib root. Used by the
# host entry point so the Omarchy floating terminal can handle fingerprint or
# password prompts through PAM.
om_reexec_root() {
  [[ $EUID -eq 0 ]] && return 0
  om_have sudo || {
    printf 'sudo is required to prepare a migration USB.\n' >&2
    exit 1
  }
  exec sudo -E -- env OM_ROOT="$OM_ROOT" OM_LIVE="$OM_LIVE" "$0" "$@"
}
