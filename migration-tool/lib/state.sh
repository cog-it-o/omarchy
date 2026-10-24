#!/usr/bin/env bash
# shellcheck shell=bash
#
# Authoritative migration state.
#
# The state file is the resume contract. It lives on the source machine, not on
# the throwaway USB:
#
#   host / live, source has an ESP   <source ESP>/omarchy-migration/state.json
#   host, no separate ESP            /var/lib/omarchy-migration/state.json
#   live, no source ESP              source root /var/lib/omarchy-migration/
#   target, after copying            /var/lib/omarchy-migration/state.json
#
# A copy is mirrored to the target at the end so the first boot of the new
# drive can finish boot-order cleanup and tell the user what happened.

: "${STATE_FILE:=}"

state_use_file() {
  STATE_FILE="$1"
}

state_exists() {
  [[ -n $STATE_FILE && -f $STATE_FILE ]]
}

state_require() {
  state_exists || om_die "No migration state found${STATE_FILE:+ at $STATE_FILE}."
}

state_validate() {
  state_exists || return 1
  jq -e '.schema == 1 and (.steps | type == "object")' "$STATE_FILE" >/dev/null 2>&1
}

state_load() {
  state_require
  state_validate || om_die "Migration state at $STATE_FILE is unreadable or from an incompatible version."
}

state_get() {
  state_require
  jq -er "$1" "$STATE_FILE"
}

state_get_or() {
  local filter="$1" fallback="${2:-}"
  if [[ -f $STATE_FILE ]]; then
    jq -er "$filter" "$STATE_FILE" 2>/dev/null || printf '%s\n' "$fallback"
  else
    printf '%s\n' "$fallback"
  fi
}

# Apply a jq filter atomically and refresh updated_at.
#
# Callers pass jq options first and the filter last, e.g.
#   state_jq --arg s "$step" '.steps[$s].status = "done"'
state_jq() {
  state_exists || om_die "Cannot update state: no state file."
  (($#)) || om_die "state_jq requires a filter."
  local filter="${!#}"
  local -a jq_args=("${@:1:$(($# - 1))}")
  local tmp
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")" || om_die "Cannot create a temporary state file next to $STATE_FILE"
  if ! jq -S --arg now "$(om_now)" "${jq_args[@]}" "($filter) | .updated_at = \$now" "$STATE_FILE" >"$tmp"; then
    rm -f -- "$tmp"
    om_die "Failed to update migration state (jq filter: $filter)"
  fi
  sync -- "$tmp" 2>/dev/null || sync
  mv -f -- "$tmp" "$STATE_FILE" || om_die "Failed to replace migration state."
}

state_save() {
  state_jq '.'
}

state_init() {
  local source_json="$1" target_json="$2" plan_json="$3" phase="${4:-prepared}" options_json="${5:-{}}"
  local dir run
  dir="$(dirname -- "$STATE_FILE")"
  mkdir -p -- "$dir"
  run="$(om_uuid)"

  local tmp="${STATE_FILE}.new.$$"
  jq -n \
    --arg now "$(om_now)" \
    --arg run "$run" \
    --arg version "$OM_VERSION" \
    --arg fingerprint "$(om_fingerprint)" \
    --arg phase "$phase" \
    --argjson source "$source_json" \
    --argjson target "$target_json" \
    --argjson plan "$plan_json" \
    --argjson options "$options_json" \
    '{
      schema: 1,
      run_id: $run,
      tool_version: $version,
      tool_fingerprint: $fingerprint,
      phase: $phase,
      created_at: $now,
      updated_at: $now,
      source: $source,
      target: $target,
      plan: $plan,
      options: $options,
      usb: {},
      step_order: [],
      steps: {},
      current_step: null,
      failed_step: null,
      error: null,
      pending_finalize: false,
      history: []
    }' >"$tmp" || om_die "Failed to initialise migration state."

  sync -- "$tmp" 2>/dev/null || sync
  mv -f -- "$tmp" "$STATE_FILE"
  om_log INFO "state initialised at $STATE_FILE (phase=$phase run=$run)"
}

state_set_phase() {
  state_jq --arg p "$1" '.phase = $p'
}

state_register_steps() {
  (($#)) || return 0
  local order_json
  order_json="$(printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0))')"
  state_jq --argjson order "$order_json" '
    .step_order = $order
    | reduce $order[] as $s (.; .steps[$s] //= {status: "pending", attempts: 0})
  '
}

state_steps() {
  state_get '.step_order[]' 2>/dev/null
}

state_step_status() {
  state_get_or ".steps[\"$1\"].status" "pending"
}

state_should_run() {
  local step="$1" status
  status="$(state_step_status "$step")"
  case "$status" in
    done | skipped)
      [[ $OM_FORCE_STEP == all || $OM_FORCE_STEP == "$step" ]]
      ;;
    *) return 0 ;;
  esac
}

state_step_begin() {
  local step="$1"
  state_jq --arg s "$step" '.steps[$s] = ((.steps[$s] // {}) + {
      status: "running",
      attempts: (((.steps[$s].attempts // 0) + 1)),
      started_at: $now,
      error: null
    })
    | .current_step = $s
    | .failed_step = null
    | .error = null
    | .phase = "migrating"'
}

state_step_done() {
  local step="$1"
  state_jq --arg s "$step" '
    .steps[$s] = ((.steps[$s] // {}) + {status: "done", completed_at: $now, error: null})
    | .current_step = null
    | .failed_step = null
    | .error = null
    | .phase = (if .phase == "complete" then "complete" else "migrating" end)
    | .history += [{step: $s, status: "done", at: $now}]
  '
}

state_step_skip() {
  local step="$1" reason="${2:-already done}"
  state_jq --arg s "$step" --arg r "$reason" '
    .steps[$s] = ((.steps[$s] // {}) + {status: "skipped", reason: $r, completed_at: $now})
    | .history += [{step: $s, status: "skipped", reason: $r, at: $now}]
  '
}

state_step_fail() {
  local step="$1" message="$2"
  state_jq --arg s "$step" --arg m "$message" '
    .steps[$s] = ((.steps[$s] // {}) + {status: "failed", error: $m, completed_at: $now})
    | .current_step = null
    | .failed_step = $s
    | .error = $m
    | .phase = "failed"
    | .history += [{step: $s, status: "failed", error: $m, at: $now}]
  '
}

state_set_str() {
  local path="$1" value="$2"
  state_jq --arg v "$value" "$path = \$v"
}

state_set_raw() {
  local path="$1" json="$2"
  state_jq --argjson v "$json" "$path = \$v"
}

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------

# Where a state file is written while the source system is running.
state_host_file() {
  if [[ -n ${OM_STATE_FILE:-} ]]; then
    printf '%s\n' "$OM_STATE_FILE"
    return
  fi
  if findmnt -rn -M /boot >/dev/null 2>&1 && [[ -w /boot ]]; then
    printf '/boot/omarchy-migration/state.json\n'
  else
    printf '/var/lib/omarchy-migration/state.json\n'
  fi
}

state_host_prepare() {
  STATE_FILE="$(state_host_file)"
  mkdir -p -- "$(dirname -- "$STATE_FILE")"
}

# First existing state candidate, preferring the target copy when it describes
# the currently running disk (first boot after migration).
state_find_any() {
  local candidate
  for candidate in \
    "${OM_STATE_FILE:-}" \
    /var/lib/omarchy-migration/state.json \
    /boot/omarchy-migration/state.json; do
    [[ -n $candidate && -f $candidate ]] && {
      printf '%s\n' "$candidate"
      return 0
    }
  done
  return 1
}

state_copy_to() {
  local target_root="$1" dest
  state_exists || return 1
  dest="$target_root/var/lib/omarchy-migration/state.json"
  mkdir -p -- "$(dirname -- "$dest")"
  jq -S . "$STATE_FILE" >"$dest.tmp"
  sync -- "$dest.tmp" 2>/dev/null || sync
  mv -f -- "$dest.tmp" "$dest"
  chmod 600 -- "$dest" 2>/dev/null || true
}

# Human-readable status used by `omarchy-migrate-drive status`.
state_summary() {
  state_require
  local phase run source_disk target_disk failed pending step status
  phase="$(state_get '.phase')"
  run="$(state_get '.run_id')"
  source_disk="$(state_get '.source.disk // "?"')"
  target_disk="$(state_get '.target.disk // "?"')"
  failed="$(state_get '.failed_step // ""')"
  pending="$(state_get '.pending_finalize // false')"

  printf 'Run       %s\n' "$run"
  printf 'Phase     %s\n' "$phase"
  printf 'Source    %s\n' "$source_disk"
  printf 'Target    %s\n' "$target_disk"
  [[ -n $failed ]] && printf 'Failed at %s\n' "$failed"
  [[ $pending == true ]] && printf 'Finish    pending on first boot of the new drive\n'
  printf '\nSteps:\n'
  for step in $(state_steps 2>/dev/null); do
    status="$(state_step_status "$step")"
    printf '  %-28s %s\n' "$step" "$status"
  done
}
