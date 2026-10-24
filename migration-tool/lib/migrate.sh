#!/usr/bin/env bash
# shellcheck shell=bash
#
# Core migration engine.
#
# The host side only *plans* the migration. All destructive work happens in the
# live image with the source mounted read-only. Each step is recorded in the
# state file before and after it runs, so a failed run resumes at the failed
# step instead of starting over.

: "${SRC_DISK:=}"
: "${SRC_LUKS_PARTUUID:=}"
: "${SRC_MAPPER:=omarchy-source}"
: "${SRC_DEV:=}"
: "${SRC_TOP:=}"
: "${SRC_ROOT:=}"
: "${SRC_ESP_PART:=}"
: "${SRC_ESP_PARTUUID:=}"
: "${SRC_ESP_MNT:=$OM_SRC_ESP_MNT}"
: "${ROOT_SUBVOL:=}"

: "${TGT_DISK:=}"
: "${TGT_ESP_PART:=}"
: "${TGT_LUKS_PART:=}"
: "${TGT_ESP_NUM:=1}"
: "${TGT_MAPPER:=omarchy-target}"
: "${TGT_DEV:=}"
: "${TGT_TOP:=$OM_TGT_TOP}"
: "${TGT_ROOT:=$OM_TGT_MNT}"

: "${PLAN_SOURCE_ROOT:=/}"
: "${STATE_ON_ESP:=0}"
: "${MIGRATION_TARGET_KIND:=live}"

readonly MIB=1048576
readonly GIB=1073741824
readonly LUKS_OVERHEAD_BYTES=67108864

# ---------------------------------------------------------------------------
# Planning (host and live)
# ---------------------------------------------------------------------------

_plan_recalculate() {
  local plan_json="$1"
  jq -c '
    .required_bytes = (((.source_used_bytes - (.excluded_bytes // 0)) * 110 / 100) | ceil)
    | .fit = (
        if .available_bytes >= (.required_bytes * 120 / 100) then "full"
        elif .available_bytes >= .required_bytes then "tight"
        else "too_small"
        end
      )
  ' <<<"$plan_json"
}

# Build the plan from a source analysis JSON and a target disk.
plan_compute() {
  local source_json="$1" target_disk="$2"
  local used target_size esp_size available required fit swapfile subvolumes now
  used="$(jq -r '.used_bytes // 0' <<<"$source_json")"
  target_size="$(detect_size_bytes "$target_disk")"
  esp_size="$(jq -r '.esp.size // 0' <<<"$source_json")"

  ((esp_size < GIB)) && esp_size=$GIB
  ((esp_size > 4 * GIB)) && esp_size=$((4 * GIB))
  esp_size=$((((esp_size + MIB - 1) / MIB) * MIB))

  available=$((target_size - esp_size - LUKS_OVERHEAD_BYTES))
  ((available < 0)) && available=0
  required=$(((used * 110 + 99) / 100))

  if ((available >= required * 120 / 100)); then
    fit="full"
  elif ((available >= required)); then
    fit="tight"
  else
    fit="too_small"
  fi

  swapfile="$(jq -c '.swapfile // {enabled:false}' <<<"$source_json")"
  subvolumes="$(jq -c '.subvolumes // []' <<<"$source_json")"
  now="$(om_now)"

  jq -n \
    --argjson used "$used" \
    --argjson target_size "$target_size" \
    --argjson esp_size "$esp_size" \
    --argjson available "$available" \
    --argjson required "$required" \
    --argjson overhead "$LUKS_OVERHEAD_BYTES" \
    --arg fit "$fit" \
    --arg now "$now" \
    --argjson swapfile "$swapfile" \
    --argjson subvolumes "$subvolumes" \
    '{
      source_used_bytes: $used,
      excluded_bytes: 0,
      target_size_bytes: $target_size,
      esp_size_bytes: $esp_size,
      luks_overhead_bytes: $overhead,
      available_bytes: $available,
      required_bytes: $required,
      fit: $fit,
      excludes: [],
      swapfile: $swapfile,
      subvolumes: $subvolumes,
      created_at: $now
    }'
}

_plan_pattern_exists() {
  local root="$1" pattern="$2"
  if [[ $pattern == *[\*\?\[]* ]]; then
    compgen -G "$root$pattern" >/dev/null 2>&1
  else
    [[ -e "$root$pattern" ]]
  fi
}

_plan_pattern_bytes() {
  local root="$1" pattern="$2" match total=0 size
  if [[ $pattern == *[\*\?\[]* ]]; then
    while IFS= read -r match; do
      [[ -n $match ]] || continue
      size="$(du -sb -- "$match" 2>/dev/null | awk '{print $1}')"
      total=$((total + ${size:-0}))
    done < <(compgen -G "$root$pattern" 2>/dev/null || true)
  else
    if [[ -e "$root$pattern" ]]; then
      size="$(du -sb -- "$root$pattern" 2>/dev/null | awk '{print $1}')"
      total=$((total + ${size:-0}))
    fi
  fi
  printf '%s\n' "$total"
}

# Offer common space hogs as exclusions. Writes the updated plan to stdout.
plan_choose_excludes() {
  local plan_json="$1" root="${PLAN_SOURCE_ROOT:-/}"
  local -a labels=() patterns=() selected=()
  local label pattern

  _offer() {
    local label="$1" pattern="$2"
    _plan_pattern_exists "$root" "$pattern" || return 0
    labels+=("$label")
    patterns+=("$pattern")
  }
  _offer "Browser and application caches (/home/*/.cache)" "/home/*/.cache"
  _offer "Steam games (/home/*/.local/share/Steam/steamapps)" "/home/*/.local/share/Steam/steamapps"
  _offer "Trash (/home/*/.local/share/Trash)" "/home/*/.local/share/Trash"
  _offer "Downloads (/home/*/Downloads)" "/home/*/Downloads"
  _offer "Container images (/home/*/.local/share/containers)" "/home/*/.local/share/containers"
  _offer "System logs (/var/log)" "/var/log"
  _offer "System caches (/var/cache)" "/var/cache"
  _offer "Temporary files (/var/tmp/*)" "/var/tmp/*"

  ((${#labels[@]})) || return 1

  {
    printf '\n  The target is too small for everything. Choose data that may be left behind\n'
    printf '  on the old drive. Everything else is copied exactly as it is.\n'
  } >&2

  local choice
  choice="$(ui_choose_multi "Exclude from the copy (space separated)" "${labels[@]}")" || return 1
  [[ -n $choice ]] || return 1

  local i excluded=0 bytes
  local -a new_excludes=()
  while IFS= read -r label; do
    [[ -n $label ]] || continue
    for i in "${!labels[@]}"; do
      if [[ ${labels[i]} == "$label" ]]; then
        pattern="${patterns[i]}"
        new_excludes+=("$pattern")
        bytes="$(_plan_pattern_bytes "$root" "$pattern")"
        excluded=$((excluded + bytes))
        printf '  %s  %s\n' "$(om_human_bytes "$bytes")" "$pattern" >&2
        break
      fi
    done
  done <<<"$choice"

  ((${#new_excludes[@]})) || return 1

  local excludes_json
  excludes_json="$(printf '%s\n' "${new_excludes[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')"
  plan_json="$(jq -c --argjson add "$excludes_json" --argjson bytes "$excluded" '
    .excludes = (((.excludes // []) + $add) | unique)
    | .excluded_bytes = ((.excluded_bytes // 0) + $bytes)
  ' <<<"$plan_json")"
  _plan_recalculate "$plan_json"
}

# Print the plan after checking it fits. Returns 1 when the target is unusable.
plan_confirm_fit() {
  local plan_json="$1" fit used target_size esp available required excluded
  fit="$(jq -r '.fit' <<<"$plan_json")"
  used="$(jq -r '.source_used_bytes' <<<"$plan_json")"
  excluded="$(jq -r '.excluded_bytes // 0' <<<"$plan_json")"
  target_size="$(jq -r '.target_size_bytes' <<<"$plan_json")"
  esp="$(jq -r '.esp_size_bytes' <<<"$plan_json")"
  available="$(jq -r '.available_bytes' <<<"$plan_json")"
  required="$(jq -r '.required_bytes' <<<"$plan_json")"

  {
    printf '\n'
    printf '  %-22s %s\n' "Source data:" "$(om_human_bytes "$used")"
    ((excluded > 0)) && printf '  %-22s %s\n' "Excluded:" "$(om_human_bytes "$excluded")"
    printf '  %-22s %s\n' "Target drive:" "$(om_human_bytes "$target_size")"
    printf '  %-22s %s\n' "EFI system partition:" "$(om_human_bytes "$esp")"
    printf '  %-22s %s\n' "Usable for data:" "$(om_human_bytes "$available")"
    case "$fit" in
      full) printf '  %-22s %s\n' "Result:" "fits comfortably" ;;
      tight) printf '  %-22s %s\n' "Result:" "fits, with little free space" ;;
      too_small) printf '  %-22s %s\n' "Result:" "too small" ;;
    esac
  } >&2

  if [[ $fit == too_small ]]; then
    if ! plan_json="$(plan_choose_excludes "$plan_json")"; then
      printf '  The target cannot hold this installation even with exclusions.\n' >&2
      return 1
    fi
    fit="$(jq -r '.fit' <<<"$plan_json")"
    if [[ $fit == too_small ]]; then
      printf '  Still too small after exclusions. Choose a larger drive.\n' >&2
      return 1
    fi
  fi

  if [[ $fit == tight ]] && ! ui_confirm "The target is tight. Continue anyway?" no; then
    return 1
  fi

  printf '%s\n' "$plan_json"
}

host_select_target() {
  local source_json="$1"
  local -a candidates=() descriptions=()
  local disk selected

  mapfile -t candidates < <(detect_target_candidates)
  if ((${#candidates[@]} == 0)); then
    ui_warn "No target drive found. Plug in the new drive and try again." >&2
    return 1
  fi

  for disk in "${candidates[@]}"; do
    descriptions+=("$(detect_disk_description "$disk")")
  done

  selected="$(ui_choose "Select the new drive for Omarchy" "${descriptions[@]}")" || return 1
  disk="${selected%%[[:space:]]*}"
  [[ -b $disk ]] || return 1
  printf '%s\n' "$disk"
}

# ---------------------------------------------------------------------------
# State discovery and attachment (live)
# ---------------------------------------------------------------------------

_migrate_state_seed_file() {
  printf '/usr/local/share/omarchy-migrate/seed-plan.json\n'
}

# Sets STATE_FILE and STATE_ON_ESP. Returns 0 when a state (real or seeded) is
# available, 1 when there is nothing to resume.
migrate_discover_state() {
  local esps_json count selected part
  esps_json="$(detect_state_esps | jq -s '.')"
  count="$(jq 'length' <<<"$esps_json")"

  if ((count > 0)); then
    if ((count == 1)); then
      selected="0"
    else
      local -a descriptions=() choices=()
      local i
      for ((i = 0; i < count; i++)); do
        descriptions+=("$(jq -r '.['"$i"'] | "\(.state.source.disk // "?")  \(.state.phase // "?")  run \(.state.run_id // "?")"' <<<"$esps_json")")
        choices+=("$i")
      done
      local chosen
      chosen="$(ui_choose "More than one migration state was found. Which one?" "${descriptions[@]}")" || return 1
      for i in "${!descriptions[@]}"; do
        [[ ${descriptions[i]} == "$chosen" ]] && selected="$i"
      done
      [[ -n $selected ]] || return 1
    fi
    part="$(jq -r ".[$selected].part" <<<"$esps_json")"
    SOURCE_ESP_PART="$part"
    state_use_file "$OM_STATE_MNT/omarchy-migration/state.json"
    mkdir -p -- "$OM_STATE_MNT"
    if ! mountpoint -q "$OM_STATE_MNT"; then
      mount -o rw "$part" "$OM_STATE_MNT" >>"$OM_LOG" 2>&1 || return 1
      om_cleanup_add "mountpoint -q '$OM_STATE_MNT' && umount '$OM_STATE_MNT'"
    fi
    mkdir -p -- "$(dirname -- "$STATE_FILE")"
    state_load || return 1
    STATE_ON_ESP=1
    return 0
  fi

  local seed
  seed="$(_migrate_state_seed_file)"
  if [[ -r $seed ]]; then
    STATE_FILE="$OM_RUN_DIR/seed-state.json"
    jq -S --arg now "$(om_now)" '
      . + {
        schema: 1,
        phase: (.phase // "prepared"),
        usb: (.usb // {}),
        steps: (.steps // {}),
        step_order: (.step_order // []),
        current_step: (.current_step // null),
        failed_step: (.failed_step // null),
        error: (.error // null),
        pending_finalize: (.pending_finalize // false),
        history: (.history // []),
        created_at: (.created_at // $now),
        updated_at: $now
      }
    ' "$seed" >"$STATE_FILE" || return 1
    state_load || return 1
    STATE_ON_ESP=0
    om_log INFO "loaded seeded plan from $seed"
    return 0
  fi

  return 1
}

_migrate_resolve_part_by_partuuid() {
  local partuuid="$1"
  [[ -n $partuuid ]] || return 1
  blkid -t "PARTUUID=$partuuid" -o device 2>/dev/null | head -n1
}

# Persist the state on the source drive once it is unlocked and mounted.
migrate_persist_state_to_source() {
  local source_disk="$1" esp partuuid state_path

  [[ $STATE_ON_ESP == 1 ]] && return 0

  partuuid="$(state_get_or '.source.esp.partuuid' '')"
  partuuid="${partuuid:-$SRC_ESP_PARTUUID}"
  esp=""
  [[ -n $partuuid ]] && esp="$(_migrate_resolve_part_by_partuuid "$partuuid" || true)"
  if [[ -z $esp ]]; then
    esp="$(detect_esp_partitions "$source_disk" | head -n1)"
  fi

  if [[ -n $esp && -b $esp ]]; then
    mkdir -p -- "$OM_STATE_MNT"
    if ! mountpoint -q "$OM_STATE_MNT"; then
      mount -o rw "$esp" "$OM_STATE_MNT" >>"$OM_LOG" 2>&1 || om_die "Could not mount the source ESP read/write."
      om_cleanup_add "mountpoint -q '$OM_STATE_MNT' && umount '$OM_STATE_MNT'"
    fi
    state_path="$OM_STATE_MNT/omarchy-migration/state.json"
    mkdir -p -- "$(dirname -- "$state_path")"
    if [[ -f $state_path ]]; then
      # A real state file wins over the seeded plan: it may contain progress.
      om_log INFO "using existing source state at $state_path"
      state_use_file "$state_path"
      state_load || om_die "The existing migration state is unreadable."
    else
      cp -- "$STATE_FILE" "$state_path"
      sync
      state_use_file "$state_path"
      state_load
    fi
    SOURCE_ESP_PART="$esp"
    SRC_ESP_PART="$esp"
    STATE_ON_ESP=1
    om_log INFO "state persisted to source ESP $esp"
    return 0
  fi

  # No ESP anywhere: keep the state on the source root filesystem.
  if ! mountpoint -q "$OM_STATE_MNT"; then
    if ! mountpoint -q "$SRC_TOP"; then
      om_die "Source is not mounted; cannot persist state."
    fi
    mount -o remount,rw "$SRC_TOP" >>"$OM_LOG" 2>&1 || om_die "Could not remount the source read/write for state."
    om_cleanup_add "mount -o remount,ro '$SRC_TOP' 2>/dev/null || true"
  fi
  state_path="$SRC_TOP/$ROOT_SUBVOL/var/lib/omarchy-migration/state.json"
  mkdir -p -- "$(dirname -- "$state_path")"
  cp -- "$STATE_FILE" "$state_path"
  sync
  state_use_file "$state_path"
  state_load
  STATE_ON_ESP=0
  om_log INFO "state persisted to source root $state_path"
}

# ---------------------------------------------------------------------------
# Source resolution / unlock / mount
# ---------------------------------------------------------------------------

migrate_resolve_source_disk() {
  local serial model size disk
  serial="$(state_get_or '.source.serial' '')"
  model="$(state_get_or '.source.model' '')"
  size="$(state_get_or '.source.size' '0')"

  if disk="$(detect_resolve_disk "$serial" "$model" "$size" "")"; then
    printf '%s\n' "$disk"
    return 0
  fi
  return 1
}

migrate_choose_source() {
  local -a candidates=() descriptions=()
  local disk selected
  mapfile -t candidates < <(detect_source_like_disks)
  if ((${#candidates[@]} == 0)); then
    ui_warn "No installed Omarchy drive found. Is the source drive connected?" >&2
    mapfile -t candidates < <(detect_target_candidates)
    for disk in "${candidates[@]}"; do
      descriptions+=("$(detect_disk_description "$disk")")
    done
    ((${#descriptions[@]})) || return 1
    selected="$(ui_choose "Select the drive that currently holds Omarchy" "${descriptions[@]}")" || return 1
    printf '%s\n' "${selected%%[[:space:]]*}"
    return 0
  fi
  if ((${#candidates[@]} == 1)); then
    printf '%s\n' "${candidates[0]}"
    return 0
  fi
  for disk in "${candidates[@]}"; do
    descriptions+=("$(detect_disk_description "$disk")")
  done
  selected="$(ui_choose "Select the drive that currently holds Omarchy" "${descriptions[@]}")" || return 1
  printf '%s\n' "${selected%%[[:space:]]*}"
}

migrate_choose_target() {
  local source_disk="$1"
  local -a candidates=() descriptions=()
  local disk selected
  while IFS= read -r disk; do
    [[ -n $disk ]] || continue
    [[ $disk == "$source_disk" ]] && continue
    candidates+=("$disk")
    descriptions+=("$(detect_disk_description "$disk")")
  done < <(detect_target_candidates)

  if ((${#candidates[@]} == 0)); then
    ui_warn "No target drive found. Plug in the new drive and try again." >&2
    return 1
  fi
  selected="$(ui_choose "Select the new drive for Omarchy" "${descriptions[@]}")" || return 1
  disk="${selected%%[[:space:]]*}"
  [[ -b $disk ]] || return 1
  printf '%s\n' "$disk"
}

migrate_resolve_target_from_state() {
  local serial model size
  serial="$(state_get_or '.target.serial' '')"
  model="$(state_get_or '.target.model' '')"
  size="$(state_get_or '.target.size' '0')"
  detect_resolve_disk "$serial" "$model" "$size" ""
}

migrate_unlock_source() {
  local partuuid part
  partuuid="$(state_get_or '.source.luks.partuuid' '')"
  SRC_LUKS_PARTUUID="$partuuid"

  if [[ -z $partuuid ]]; then
    om_error "This version migrates LUKS-encrypted Omarchy installations only."
    om_error "The running source was not detected as LUKS2."
    return 1
  fi

  part="$(_migrate_resolve_part_by_partuuid "$partuuid" || true)"
  if [[ -z $part ]]; then
    part="$(state_get_or '.source.luks.part' '')"
  fi
  [[ -b $part ]] || {
    om_error "Could not find the source LUKS partition (PARTUUID $partuuid)."
    return 1
  }

  SRC_MAPPER="$(state_get_or '.source.luks.mapper' 'omarchy-source')"
  SRC_MAPPER="${SRC_MAPPER:-omarchy-source}"
  SRC_LUKS_PART="$part"
  if [[ ! -e /dev/mapper/$SRC_MAPPER ]]; then
    printf '\n  Unlock the source drive. This is only read from.\n'
    if ! cryptsetup open "$part" "$SRC_MAPPER"; then
      om_error "Could not unlock $part."
      return 1
    fi
    om_cleanup_add "cryptsetup status '$SRC_MAPPER' >/dev/null 2>&1 && cryptsetup close '$SRC_MAPPER'"
  fi
  SRC_DEV="/dev/mapper/$SRC_MAPPER"
  om_log INFO "source unlocked as $SRC_DEV"
}

migrate_mount_source() {
  local root_subvol fstab_root esp
  mkdir -p -- "$SRC_TOP"
  if ! mountpoint -q "$SRC_TOP"; then
    mount -o ro,subvolid=5 "$SRC_DEV" "$SRC_TOP" >>"$OM_LOG" 2>&1 || {
      om_error "Could not mount the source btrfs filesystem."
      return 1
    }
    om_cleanup_add "mountpoint -q '$SRC_TOP' && umount '$SRC_TOP'"
  fi

  root_subvol="$(state_get_or '.source.root.subvol' '')"
  if [[ -z $root_subvol || $root_subvol == __DEFAULT__ ]]; then
    if [[ -d $SRC_TOP/@ ]]; then
      root_subvol="@"
    else
      while IFS= read -r fstab_root; do
        [[ -n $fstab_root ]] || continue
        if [[ -f "$SRC_TOP/$fstab_root/etc/fstab" && -f "$SRC_TOP/$fstab_root/etc/os-release" ]]; then
          root_subvol="$fstab_root"
          break
        fi
      done < <(find "$SRC_TOP" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null)
    fi
  fi

  if [[ -z $root_subvol || $root_subvol == __TOPLEVEL__ || $root_subvol == __DEFAULT__ ]]; then
    om_error "Could not determine the source root subvolume."
    return 1
  fi
  if [[ ! -f "$SRC_TOP/$root_subvol/etc/fstab" ]]; then
    om_error "Root subvolume '$root_subvol' does not look like an Omarchy root."
    return 1
  fi

  ROOT_SUBVOL="$root_subvol"
  mkdir -p -- "$SRC_ROOT"
  if ! mountpoint -q "$SRC_ROOT"; then
    mount -o "ro,subvol=$root_subvol" "$SRC_DEV" "$SRC_ROOT" >>"$OM_LOG" 2>&1 || {
      om_error "Could not mount the source root subvolume."
      return 1
    }
    om_cleanup_add "mountpoint -q '$SRC_ROOT' && umount '$SRC_ROOT'"
  fi

  # Source ESP: reuse the state mount when it is the same partition.
  SRC_ESP_PARTUUID="$(state_get_or '.source.esp.partuuid' '')"
  esp="$(_migrate_resolve_part_by_partuuid "$SRC_ESP_PARTUUID" || true)"
  [[ -z $esp ]] && esp="$(detect_esp_partitions "$SRC_DISK" | head -n1)"
  if [[ -z $esp || ! -b $esp ]]; then
    om_error "No EFI system partition found on the source drive."
    return 1
  fi
  SRC_ESP_PART="$esp"

  if [[ $STATE_ON_ESP == 1 && $SOURCE_ESP_PART == "$esp" ]]; then
    SRC_ESP_MNT="$OM_STATE_MNT"
  else
    mkdir -p -- "$SRC_ESP_MNT"
    if ! mountpoint -q "$SRC_ESP_MNT"; then
      mount -o ro "$esp" "$SRC_ESP_MNT" >>"$OM_LOG" 2>&1 || {
        om_error "Could not mount the source ESP."
        return 1
      }
      om_cleanup_add "mountpoint -q '$SRC_ESP_MNT' && umount '$SRC_ESP_MNT'"
    fi
  fi

  om_log INFO "source mounted: top=$SRC_TOP root=$SRC_ROOT ($ROOT_SUBVOL) esp=$esp"
}

# Fill in analysis that the host could not know (or that a seed plan omitted).
migrate_ensure_source_analysis() {
  local subvol_count analysis
  subvol_count="$(state_get_or '.source.subvolumes | length' '0')"

  if ((subvol_count == 0)); then
    analysis="$(detect_source_analysis_mounted "$SRC_TOP" "$ROOT_SUBVOL")" || {
      om_error "Could not analyse the mounted source."
      return 1
    }
    state_jq --argjson a "$analysis" '
      .source.root = ($a.root // .source.root)
      | .source.subvolumes = (if (($a.subvolumes // []) | length) > 0 then $a.subvolumes else .source.subvolumes end)
      | .source.swapfile = ($a.swapfile // .source.swapfile)
      | .source.boot = ($a.boot // .source.boot)
      | .source.used_bytes = ($a.used_bytes // .source.used_bytes)
      | .source.machine_id = ($a.machine_id // .source.machine_id)
      | .source.os_name = ($a.os_name // .source.os_name)
    '
  fi

  # Normalise the root subvolume and make sure the fstab list is usable.
  state_jq --arg root "$ROOT_SUBVOL" '.source.root.subvol = $root'

  subvol_count="$(state_get '.source.subvolumes | length')"
  ((subvol_count > 0)) || {
    om_error "No btrfs subvolumes were found in the source /etc/fstab."
    return 1
  }

  local name
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    case "$name" in
      __TOPLEVEL__ | __DEFAULT__)
        om_error "Subvolume '$name' is not supported. This Omarchy layout is unusual."
        return 1
        ;;
    esac
    [[ -d "$SRC_TOP/$name" ]] || {
      om_error "Subvolume '$name' from /etc/fstab does not exist on the source."
      return 1
    }
  done < <(state_get '.source.subvolumes[].name')
}

# ---------------------------------------------------------------------------
# Target paths and plan confirmation
# ---------------------------------------------------------------------------

migrate_prepare_target_paths() {
  local esp_pu luks_pu
  esp_pu="$(state_get_or '.target.esp.partuuid' '')"
  luks_pu="$(state_get_or '.target.luks.partuuid' '')"

  TGT_ESP_PART="$(state_get_or '.target.esp.part' '')"
  TGT_LUKS_PART="$(state_get_or '.target.luks.part' '')"

  # Device names are not stable across reboots. Trust the current block device
  # only if it still exists; otherwise look the partition up by PARTUUID.
  if [[ ! -b $TGT_ESP_PART && -n $esp_pu ]]; then
    TGT_ESP_PART="$(_migrate_resolve_part_by_partuuid "$esp_pu" || true)"
  fi
  if [[ ! -b $TGT_LUKS_PART && -n $luks_pu ]]; then
    TGT_LUKS_PART="$(_migrate_resolve_part_by_partuuid "$luks_pu" || true)"
  fi
  [[ -n $TGT_ESP_PART ]] || TGT_ESP_PART="$(om_part_path "$TGT_DISK" 1)"
  [[ -n $TGT_LUKS_PART ]] || TGT_LUKS_PART="$(om_part_path "$TGT_DISK" 2)"

  TGT_ESP_NUM="$(om_part_field "$TGT_ESP_PART" PARTN 2>/dev/null || echo 1)"
  TGT_ESP_NUM="${TGT_ESP_NUM:-1}"
  TGT_DEV="/dev/mapper/$TGT_MAPPER"
}

migrate_confirm_erase() {
  local disk="$1" answer
  ui_section "Destructive action"
  printf '  The following drive will be repartitioned and completely erased:\n\n'
  printf '    %s\n\n' "$(detect_disk_description "$disk")"
  printf '  The old drive is left untouched.\n\n'
  if [[ ${OM_ASSUME_YES:-0} == 1 ]]; then
    return 0
  fi
  printf '  Type %s to continue: ' "$(_c "1;$UI_ERR" "ERASE")"
  IFS= read -r answer || return 1
  [[ $answer == ERASE ]]
}

# ---------------------------------------------------------------------------
# Step registration and runner
# ---------------------------------------------------------------------------

migrate_register_steps() {
  local -a steps=(preflight backup partition luks filesystems)
  local name
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    steps+=("copy:$name")
  done < <(state_get '.source.subvolumes[].name')
  steps+=(copy:esp configure swap initramfs bootloader verify finalize-target)
  state_register_steps "${steps[@]}"
}

migrate_step_label() {
  local step="$1"
  case "$step" in
    preflight) printf 'Checking the source and target' ;;
    backup) printf 'Backing up the boot configuration and LUKS header' ;;
    partition) printf 'Partitioning the new drive' ;;
    luks) printf 'Creating the encrypted container' ;;
    filesystems) printf 'Creating btrfs subvolumes and filesystems' ;;
    copy:esp) printf 'Copying the EFI system partition' ;;
    copy:*) printf 'Copying subvolume %s' "${step#copy:}" ;;
    configure) printf 'Writing the new system configuration' ;;
    swap) printf 'Recreating the hibernation swapfile' ;;
    initramfs) printf 'Generating the initramfs and unified kernel images' ;;
    bootloader) printf 'Installing and registering the bootloader' ;;
    verify) printf 'Verifying the new system' ;;
    finalize-target) printf 'Saving completion state on the new drive' ;;
    *) printf '%s' "$step" ;;
  esac
}

migrate_dispatch_step() {
  local step="$1"
  case "$step" in
    copy:*) step_copy "${step#copy:}" ;;
    finalize-target) step_finalize_target ;;
    *) "step_${step//-/_}" ;;
  esac
}

migrate_run_steps() {
  local -a steps=()
  local i total step label message
  mapfile -t steps < <(state_steps)
  total=${#steps[@]}
  ((total > 0)) || {
    om_error "The migration plan has no steps."
    return 1
  }

  for ((i = 0; i < total; i++)); do
    step="${steps[i]}"
    label="$(migrate_step_label "$step")"
    if ! state_should_run "$step"; then
      ui_step_skip "$label"
      continue
    fi

    ui_step_begin "$((i + 1))" "$total" "$label"
    state_step_begin "$step"
    if migrate_dispatch_step "$step"; then
      state_step_done "$step"
      ui_step_ok
    else
      message="${LAST_ERROR:-The step failed.}"
      state_step_fail "$step" "$message"
      ui_error_panel "Migration failed while $label" "$message" "$OM_LOG"
      ui_note "Completed steps are saved. The migration will resume from '$step'."
      ui_note "Source state: $STATE_FILE"
      if [[ -t 0 ]] && ui_confirm "Open a root shell for debugging?" no; then
        exec bash -l
      fi
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

step_preflight() {
  local target_size required esp overhead disk_mib mounted
  om_need parted cryptsetup mkfs.btrfs mkfs.fat rsync jq blkid lsblk findmnt genfstab

  [[ -n $SRC_ROOT && -f "$SRC_ROOT/etc/fstab" ]] || {
    om_error "The source root is not mounted correctly."
    return 1
  }
  [[ -f "$SRC_ROOT/etc/kernel/cmdline" ]] || {
    om_error "Source has no /etc/kernel/cmdline; this is not an Omarchy UKI system."
    return 1
  }
  [[ -x "$SRC_ROOT/usr/bin/limine-install" || -x "$SRC_ROOT/usr/bin/limine" ]] || {
    om_error "limine-install was not found in the source system."
    return 1
  }
  [[ -f "$SRC_ROOT/etc/default/limine" ]] || {
    om_error "Source has no /etc/default/limine; this is not an Omarchy Limine system."
    return 1
  }
  [[ -n $SRC_ESP_PART && -b $SRC_ESP_PART ]] || {
    om_error "Source EFI system partition was not found."
    return 1
  }

  [[ -b $TGT_DISK ]] || {
    om_error "Target drive $TGT_DISK is not present."
    return 1
  }
  [[ $(realpath "$TGT_DISK") != "$(realpath "$SRC_DISK")" ]] || {
    om_error "The source and target are the same drive."
    return 1
  }

  if detect_disk_is_mounted "$TGT_DISK"; then
    mounted="$(detect_mounted_nodes_of_disk "$TGT_DISK" | awk '{print $1}' | paste -sd' ' -)"
    om_error "The target drive is in use (mounted at: ${mounted:-unknown}). Unmount it first."
    return 1
  fi

  target_size="$(detect_size_bytes "$TGT_DISK")"
  required="$(state_get '.plan.required_bytes // 0')"
  esp="$(state_get '.plan.esp_size_bytes // 0')"
  overhead="$(state_get '.plan.luks_overhead_bytes // 0')"
  disk_mib=$((target_size / MIB))
  ((disk_mib > 0)) || {
    om_error "Target drive reports no usable size."
    return 1
  }
  ((target_size >= required + esp + overhead)) || {
    om_error "The target is too small for this plan."
    return 1
  }

  [[ "$(state_get_or '.source.boot.loader' '')" == limine ]] || {
    om_error "The source does not use Limine; this version of the tool supports Omarchy Limine systems only."
    return 1
  }

  if ! om_is_uefi; then
    om_warn "This machine booted in legacy BIOS mode. The new drive will be made bootable, but the firmware boot order must be set manually."
  fi

  om_log INFO "preflight ok: source=$SRC_DISK target=$TGT_DISK root=$ROOT_SUBVOL"
  return 0
}

# A small, source-side safety net written before the target is touched. The
# source drive is never modified, but a LUKS header backup and a copy of the
# boot configuration are worth having anyway: a bad header is unrecoverable.
step_backup() {
  local root dir header_error=0
  if [[ $STATE_ON_ESP == 1 ]]; then
    root="$OM_STATE_MNT/omarchy-migration/backup"
  else
    # No source ESP (unusual for Omarchy). Keep the backup on the source root.
    if ! mountpoint -q "$SRC_TOP"; then
      om_warn "Source is not mounted; skipping the backup."
      return 0
    fi
    mount -o remount,rw "$SRC_TOP" >>"$OM_LOG" 2>&1 || {
      om_warn "Could not remount the source read/write; skipping the backup."
      return 0
    }
    om_cleanup_add "mount -o remount,ro '$SRC_TOP' 2>/dev/null || true"
    root="$SRC_TOP/$ROOT_SUBVOL/var/lib/omarchy-migration/backup"
  fi

  dir="$root"
  mkdir -p -- "$dir"
  chmod 700 -- "$dir" 2>/dev/null || true

  om_log INFO "backing up source boot metadata to $dir"

  # Partition table: sgdisk's binary backup is restorable; sfdisk text is a
  # readable fallback.
  if om_have sgdisk; then
    sgdisk --backup="$dir/source-gpt.bin" "$SRC_DISK" >>"$OM_LOG" 2>&1 ||
      om_warn "Could not back up the GPT with sgdisk."
  fi
  if om_have sfdisk; then
    sfdisk -d "$SRC_DISK" >"$dir/source-gpt.txt" 2>>"$OM_LOG" ||
      om_warn "Could not dump the partition table with sfdisk."
  fi

  # The LUKS header is the one thing that cannot be rebuilt from the copy.
  rm -f -- "$dir/source-luks-header.img"
  if ! cryptsetup luksHeaderBackup "$SRC_LUKS_PART" \
    --header-backup-file "$dir/source-luks-header.img" >>"$OM_LOG" 2>&1; then
    om_warn "Could not back up the LUKS header. Continuing without it."
    header_error=1
    rm -f -- "$dir/source-luks-header.img"
  fi
  chmod 600 -- "$dir/source-luks-header.img" 2>/dev/null || true

  tar -C "$SRC_ROOT" --ignore-failed-read -czf "$dir/source-boot-config.tar.gz" \
    etc/fstab etc/crypttab etc/kernel etc/default/limine \
    etc/mkinitcpio.conf etc/mkinitcpio.conf.d etc/limine-entry-tool.d \
    2>>"$OM_LOG" ||
    om_warn "Could not archive the complete boot configuration."

  if [[ -d $SRC_ESP_MNT ]]; then
    tar -C "$SRC_ESP_MNT" --ignore-failed-read -czf "$dir/source-esp-boot.tar.gz" \
      EFI/Linux EFI/limine EFI/BOOT limine.conf loader 2>>"$OM_LOG" ||
      om_warn "Could not archive the source ESP boot files."
  fi

  if om_have sha256sum; then
    (cd -- "$dir" && sha256sum ./* >SHA256SUMS 2>/dev/null) || true
  fi
  sync

  state_jq --arg dir "$dir" --argjson header_ok "$([[ $header_error == 0 ]] && echo true || echo false)" '
    .backup = {
      enabled: true,
      dir: $dir,
      luks_header: $header_ok,
      created_at: $now
    }
  '
  om_log INFO "backup complete in $dir (luks header: $([[ $header_error == 0 ]] && echo yes || echo no))"
  return 0
}

step_partition() {
  local esp_bytes esp_mib disk_mib end_mib esp_json luks_json i

  esp_bytes="$(state_get '.plan.esp_size_bytes')"
  esp_mib=$(((esp_bytes + MIB - 1) / MIB))
  ((esp_mib < 512)) && esp_mib=512
  disk_mib="$(($(detect_size_bytes "$TGT_DISK") / MIB))"
  end_mib=$((1 + esp_mib))
  ((end_mib + 1024 < disk_mib)) || {
    om_error "Not enough room on $TGT_DISK for the EFI partition and a root partition."
    return 1
  }

  om_log INFO "wiping $TGT_DISK"
  wipefs -a -- "$TGT_DISK" >>"$OM_LOG" 2>&1 || true

  om_log INFO "parted: gpt + ESP ${esp_mib}MiB + root"
  parted -s "$TGT_DISK" mklabel gpt >>"$OM_LOG" 2>&1 || {
    om_error "Could not write a new GPT label to $TGT_DISK."
    return 1
  }
  parted -s "$TGT_DISK" unit MiB mkpart ESP fat32 1 "$end_mib" >>"$OM_LOG" 2>&1 || {
    om_error "Could not create the EFI partition."
    return 1
  }
  parted -s "$TGT_DISK" set 1 esp on >>"$OM_LOG" 2>&1 || true
  parted -s "$TGT_DISK" unit MiB mkpart root "$end_mib" 100% >>"$OM_LOG" 2>&1 || {
    om_error "Could not create the root partition."
    return 1
  }

  partprobe "$TGT_DISK" >>"$OM_LOG" 2>&1 || true
  udevadm settle --timeout=30 >>"$OM_LOG" 2>&1 || true

  for ((i = 0; i < 40; i++)); do
    [[ -b $TGT_ESP_PART && -b $TGT_LUKS_PART ]] && break
    sleep 0.5
    partprobe "$TGT_DISK" >>"$OM_LOG" 2>&1 || true
    udevadm settle --timeout=5 >>"$OM_LOG" 2>&1 || true
  done
  [[ -b $TGT_ESP_PART && -b $TGT_LUKS_PART ]] || {
    om_error "The new partitions did not appear (expected $TGT_ESP_PART and $TGT_LUKS_PART)."
    return 1
  }

  om_log INFO "mkfs.fat on $TGT_ESP_PART"
  mkfs.fat -F32 -n OMARCHY "$TGT_ESP_PART" >>"$OM_LOG" 2>&1 || {
    om_error "Could not format the EFI partition."
    return 1
  }

  # Remove any old signatures from the root partition before luksFormat.
  wipefs -a -- "$TGT_LUKS_PART" >>"$OM_LOG" 2>&1 || true

  esp_json="$(detect_part_json "$TGT_ESP_PART")"
  luks_json="$(detect_part_json "$TGT_LUKS_PART")"
  state_jq --argjson e "$esp_json" --argjson l "$luks_json" \
    '.target.esp = $e | .target.luks = $l'
  local partnum
  partnum="$(om_part_field "$TGT_ESP_PART" PARTN 2>/dev/null || true)"
  TGT_ESP_NUM="${partnum:-1}"
  sync
  om_log INFO "partitions ready: esp=$TGT_ESP_PART root=$TGT_LUKS_PART"
  return 0
}

step_luks() {
  local pass pass2 uuid partuuid
  if cryptsetup status "$TGT_MAPPER" >/dev/null 2>&1; then
    cryptsetup close "$TGT_MAPPER" >>"$OM_LOG" 2>&1 || true
  fi

  ui_section "Encryption passphrase"
  printf '  Choose the passphrase for the new drive. It will be required at every boot.\n'
  pass="$(ui_password "Passphrase:")" || return 1
  pass2="$(ui_password "Repeat passphrase:")" || return 1
  if [[ -z $pass ]]; then
    om_error "The passphrase cannot be empty."
    return 1
  fi
  if ((${#pass} < 8)); then
    om_error "Use at least 8 characters. The source LUKS header uses a real KDF; short passphrases are weak."
    return 1
  fi
  if [[ $pass != "$pass2" ]]; then
    om_error "The passphrases do not match."
    return 1
  fi

  om_log INFO "luksFormat on $TGT_LUKS_PART"
  if ! printf '%s' "$pass" | cryptsetup luksFormat --batch-mode --type luks2 \
    --pbkdf argon2id --label root --key-file - "$TGT_LUKS_PART" >>"$OM_LOG" 2>&1; then
    unset pass pass2
    om_error "Could not create the LUKS container on $TGT_LUKS_PART."
    return 1
  fi

  om_log INFO "cryptsetup open $TGT_LUKS_PART as $TGT_MAPPER"
  if ! printf '%s' "$pass" | cryptsetup open --key-file - "$TGT_LUKS_PART" "$TGT_MAPPER" >>"$OM_LOG" 2>&1; then
    unset pass pass2
    om_error "Could not open the newly created LUKS container."
    return 1
  fi
  unset pass pass2

  TGT_DEV="/dev/mapper/$TGT_MAPPER"
  [[ -b $TGT_DEV ]] || {
    om_error "LUKS mapper $TGT_DEV did not appear."
    return 1
  }
  om_cleanup_add "cryptsetup status '$TGT_MAPPER' >/dev/null 2>&1 && cryptsetup close '$TGT_MAPPER'"

  uuid="$(cryptsetup luksUUID "$TGT_LUKS_PART")"
  partuuid="$(om_part_field "$TGT_LUKS_PART" PARTUUID)"
  state_jq --arg uuid "$uuid" --arg partuuid "$partuuid" --arg part "$TGT_LUKS_PART" --arg mapper "$TGT_MAPPER" '
    .target.luks.uuid = $uuid
    | .target.luks.partuuid = $partuuid
    | .target.luks.part = $part
    | .target.luks.label = "root"
    | .target.luks.mapper = $mapper
  '
  sync
  om_log INFO "LUKS ready: uuid=$uuid partuuid=$partuuid"
  return 0
}

migrate_open_target_luks() {
  local pass
  if cryptsetup status "$TGT_MAPPER" >/dev/null 2>&1; then
    TGT_DEV="/dev/mapper/$TGT_MAPPER"
    return 0
  fi
  [[ -b $TGT_LUKS_PART ]] || {
    om_error "The new LUKS partition $TGT_LUKS_PART is missing."
    return 1
  }
  ui_section "Unlock the new drive"
  printf '  The new drive was already formatted in an earlier run.\n'
  pass="$(ui_password "Passphrase for the new drive:")" || return 1
  if ! printf '%s' "$pass" | cryptsetup open --key-file - "$TGT_LUKS_PART" "$TGT_MAPPER" >>"$OM_LOG" 2>&1; then
    unset pass
    om_error "Could not open the existing LUKS container on $TGT_LUKS_PART."
    return 1
  fi
  unset pass
  TGT_DEV="/dev/mapper/$TGT_MAPPER"
  om_cleanup_add "cryptsetup status '$TGT_MAPPER' >/dev/null 2>&1 && cryptsetup close '$TGT_MAPPER'"
  return 0
}

# Re-establish ephemeral state (open mapper, mounts) after a reboot without
# repeating destructive steps that are already marked done.
migrate_prepare_target_for_resume() {
  if [[ "$(state_step_status luks)" == done ]]; then
    migrate_open_target_luks || return 1
  fi
  if [[ "$(state_step_status filesystems)" == done ]]; then
    migrate_mount_target_tree || return 1
  fi
  return 0
}

migrate_mount_opts() {
  local opts="$1" opt has_compress=0
  local -a out=(rw) arr=()
  IFS=, read -ra arr <<<"$opts"
  for opt in "${arr[@]}"; do
    case "$opt" in
      "" | defaults | ro | rw | subvol=* | subvolid=* | device=* | nofail | x-systemd.* | comment=*) continue ;;
      compress=*) has_compress=1; out+=("$opt") ;;
      *) out+=("$opt") ;;
    esac
  done
  ((has_compress)) || out+=("compress=zstd:3")
  printf '%s' "$(IFS=,; echo "${out[*]}")"
}

# Mount the target subvolume tree from state. Safe to call repeatedly; used both
# after creating the filesystems and when resuming after a reboot, where mounts
# and the LUKS mapper are gone but the data is already on disk.
migrate_mount_target_tree() {
  local name mount opts target_dir uuid
  local -a names=() mounts=() opts_list=()
  local i root_opts=""

  uuid="$(state_get_or '.target.btrfs.uuid' '')"
  if [[ -z $uuid ]]; then
    uuid="$(blkid -s UUID -o value "$TGT_DEV" 2>/dev/null || true)"
    [[ -n $uuid ]] && state_set_str '.target.btrfs.uuid' "$uuid"
  fi

  [[ -b "$TGT_DEV" ]] || {
    om_error "The target LUKS mapper is not open."
    return 1
  }

  while IFS='|' read -r name mount opts; do
    [[ -n $name ]] || continue
    names+=("$name")
    mounts+=("$mount")
    opts_list+=("$opts")
  done < <(jq -r '.source.subvolumes[] | "\(.name)|\(.mount)|\(.options // "")"' "$STATE_FILE")
  ((${#names[@]})) || {
    om_error "No target subvolumes are recorded in state."
    return 1
  }

  mkdir -p -- "$TGT_ROOT"
  if ! mountpoint -q "$TGT_ROOT"; then
    for i in "${!names[@]}"; do
      if [[ ${mounts[i]} == / ]]; then
        root_opts="$(migrate_mount_opts "${opts_list[i]}")"
        mount -o "subvol=${names[i]},$root_opts" "$TGT_DEV" "$TGT_ROOT" >>"$OM_LOG" 2>&1 || {
          om_error "Could not mount the new root subvolume."
          return 1
        }
        om_cleanup_add "mountpoint -q '$TGT_ROOT' && umount -R '$TGT_ROOT'"
        break
      fi
    done
  fi
  mountpoint -q "$TGT_ROOT" || {
    om_error "State has no usable root (/) btrfs entry."
    return 1
  }

  for i in "${!names[@]}"; do
    mount="${mounts[i]}"
    [[ $mount == / ]] && continue
    [[ $mount == /boot || $mount == /efi || $mount == /boot/efi ]] && continue
    target_dir="$TGT_ROOT$mount"
    mkdir -p -- "$target_dir"
    mountpoint -q "$target_dir" && continue
    mount -o "subvol=${names[i]},$(migrate_mount_opts "${opts_list[i]}")" \
      "$TGT_DEV" "$target_dir" >>"$OM_LOG" 2>&1 || {
      om_error "Could not mount subvolume ${names[i]} at $mount."
      return 1
    }
  done

  mkdir -p -- "$TGT_ROOT/boot"
  if ! mountpoint -q "$TGT_ROOT/boot"; then
    mount "$TGT_ESP_PART" "$TGT_ROOT/boot" >>"$OM_LOG" 2>&1 || {
      om_error "Could not mount the new EFI partition at /boot."
      return 1
    }
    om_cleanup_add "mountpoint -q '$TGT_ROOT/boot' && umount '$TGT_ROOT/boot'"
  fi

  state_set_str '.target.root.subvol' "$ROOT_SUBVOL"
  sync
  om_log INFO "target filesystems mounted at $TGT_ROOT"
  return 0
}

step_filesystems() {
  local name mount opts
  local -a names=() mounts=() opts_list=()

  if cryptsetup status "$TGT_MAPPER" >/dev/null 2>&1; then
    TGT_DEV="/dev/mapper/$TGT_MAPPER"
  fi
  [[ -b "$TGT_DEV" ]] || {
    om_error "The target LUKS mapper is not open."
    return 1
  }

  om_log INFO "mkfs.btrfs on $TGT_DEV"
  mkfs.btrfs -f -L omarchy "$TGT_DEV" >>"$OM_LOG" 2>&1 || {
    om_error "Could not create the btrfs filesystem."
    return 1
  }
  state_set_str '.target.btrfs.uuid' "$(blkid -s UUID -o value "$TGT_DEV" 2>/dev/null)"

  mkdir -p -- "$TGT_TOP"
  mount -o compress=zstd:3 "$TGT_DEV" "$TGT_TOP" >>"$OM_LOG" 2>&1 || {
    om_error "Could not mount the new btrfs filesystem."
    return 1
  }
  om_cleanup_add "mountpoint -q '$TGT_TOP' && umount '$TGT_TOP'"

  while IFS='|' read -r name mount opts; do
    [[ -n $name ]] || continue
    names+=("$name")
    mounts+=("$mount")
    opts_list+=("$opts")
    om_log INFO "btrfs subvolume create $TGT_TOP/$name"
    btrfs subvolume create "$TGT_TOP/$name" >>"$OM_LOG" 2>&1 || {
      om_error "Could not create subvolume $name."
      return 1
    }
  done < <(jq -r '.source.subvolumes[] | "\(.name)|\(.mount)|\(.options // "")"' "$STATE_FILE")
  ((${#names[@]})) || {
    om_error "No source subvolumes to create."
    return 1
  }

  umount "$TGT_TOP" >>"$OM_LOG" 2>&1 || true
  migrate_mount_target_tree
}

_migrate_progress_filter() {
  tr '\r' '\n' | awk '
    {
      if (match($0, /[0-9]+%/)) {
        printf "\r  copy %s", substr($0, RSTART, RLENGTH)
        fflush()
      }
    }
    END { printf "\r\033[K" }
  '
}

step_copy() {
  local name="$1" src dst mount rc
  local -a excludes=(/proc /sys /dev /run /tmp /mnt /media /lost+found /.snapshots /var/lib/omarchy-migration)
  local -a rsync_args=(-aHAXx --numeric-ids --delete --info=progress2 --no-inc-recursive)

  src="$SRC_TOP/$name"
  [[ -d $src ]] || {
    om_error "Source subvolume $name is missing."
    return 1
  }

  mount="$(jq -r --arg n "$name" '.source.subvolumes[] | select(.name==$n) | .mount' "$STATE_FILE" | head -n1)"
  [[ -n $mount ]] || {
    om_error "No mountpoint recorded for subvolume $name."
    return 1
  }
  if [[ $mount == / ]]; then
    dst="$TGT_ROOT"
  else
    dst="$TGT_ROOT$mount"
  fi
  mkdir -p -- "$dst"

  # Separate subvolumes are mounted as their own trees; never copy them twice.
  local other other_mount
  while IFS='|' read -r other other_mount; do
    [[ -n $other_mount ]] || continue
    [[ $other_mount == / ]] && continue
    [[ $other == "$name" ]] && continue
    excludes+=("$other_mount")
  done < <(jq -r '.source.subvolumes[] | "\(.name)|\(.mount)"' "$STATE_FILE")

  if [[ $mount == / ]]; then
    excludes+=(/boot)
    local swap_path
    swap_path="$(state_get_or '.source.swapfile.path' '')"
    [[ -n $swap_path ]] && excludes+=("$swap_path")
  fi

  # Nested subvolumes (snapper snapshots, distrobox homes, …) are excluded so
  # rsync does not cross into them through the same device.
  local nested rel
  while IFS= read -r nested; do
    [[ -n $nested ]] || continue
    case "$nested" in
      "$name"/*)
        rel="${nested#"$name"}"
        excludes+=("/$rel")
        ;;
    esac
  done < <(btrfs subvolume list -o "$src" 2>/dev/null | sed -n 's/.* path //p')

  local pattern
  while IFS= read -r pattern; do
    [[ -n $pattern ]] || continue
    excludes+=("$pattern")
  done < <(jq -r '.plan.excludes[]?' "$STATE_FILE")

  for pattern in "${excludes[@]}"; do
    rsync_args+=(--exclude="$pattern")
  done

  om_log INFO "rsync $name: ${rsync_args[*]} $src/ $dst/"
  if [[ -t 1 ]]; then
    set -o pipefail
    rsync "${rsync_args[@]}" "$src/" "$dst/" 2>&1 |
      tee -a "$OM_LOG" |
      _migrate_progress_filter
    rc=${PIPESTATUS[0]}
  else
    rsync "${rsync_args[@]}" "$src/" "$dst/" >>"$OM_LOG" 2>&1
    rc=$?
  fi

  if ((rc != 0 && rc != 24)); then
    om_error "rsync failed while copying $name (exit $rc). The log has the failing paths."
    return 1
  fi
  om_log INFO "copied subvolume $name (rsync exit $rc)"
  return 0
}

step_copy_esp() {
  local rc
  local -a args=(-a --delete --delete-excluded
    --exclude=/EFI/Linux
    --exclude=/omarchy-migration
    --exclude=/System Volume Information
    --exclude='/$RECYCLE.BIN')

  [[ -d "$SRC_ESP_MNT" ]] || {
    om_error "The source ESP is not mounted."
    return 1
  }
  om_log INFO "copying source ESP $SRC_ESP_MNT to $TGT_ROOT/boot"
  rsync "${args[@]}" "$SRC_ESP_MNT/" "$TGT_ROOT/boot/" >>"$OM_LOG" 2>&1
  rc=$?
  if ((rc != 0 && rc != 24)); then
    om_error "rsync failed while copying the EFI system partition (exit $rc)."
    return 1
  fi
  return 0
}

migrate_rewrite_uuids() {
  local old new file
  local -a files=()

  mapfile -t files < <(
    find "$TGT_ROOT/etc" -maxdepth 3 -type f \
      \( -name 'cmdline' -o -name 'fstab' -o -name 'crypttab' \
      -o -name '*.conf' -o -name 'limine' \) 2>/dev/null
  )
  [[ -f "$TGT_ROOT/etc/default/limine" ]] && files+=("$TGT_ROOT/etc/default/limine")
  # The copied ESP config is regenerated later, but rewrite it too so the
  # fallback Limine binary cannot keep pointing at the old drive.
  [[ -f "$TGT_ROOT/boot/limine.conf" ]] && files+=("$TGT_ROOT/boot/limine.conf")
  while IFS= read -r file; do
    [[ -n $file ]] && files+=("$file")
  done < <(find "$TGT_ROOT/boot/loader" -maxdepth 2 -type f -name '*.conf' 2>/dev/null)

  _replace() {
    old="$1" new="$2"
    [[ -n $old && -n $new && $old != "$new" ]] || return 0
    for file in "${files[@]}"; do
      [[ -f $file ]] || continue
      if grep -qF -- "$old" "$file" 2>/dev/null; then
        om_log INFO "rewrite $old -> $new in $file"
        sed -i "s/$old/$new/g" "$file"
      fi
    done
  }

  _replace "$(state_get_or '.source.luks.uuid' '')" "$(state_get_or '.target.luks.uuid' '')"
  _replace "$(state_get_or '.source.luks.partuuid' '')" "$(state_get_or '.target.luks.partuuid' '')"
  _replace "$(state_get_or '.source.root.uuid' '')" "$(state_get_or '.target.btrfs.uuid' '')"
  _replace "$(state_get_or '.source.esp.uuid' '')" "$(state_get_or '.target.esp.uuid' '')"
  _replace "$(state_get_or '.source.esp.partuuid' '')" "$(state_get_or '.target.esp.partuuid' '')"
}

migrate_fix_cmdline() {
  local cmdline="$TGT_ROOT/etc/kernel/cmdline"
  local limine="$TGT_ROOT/etc/default/limine"
  local new_partuuid root_subvol

  [[ -f $cmdline ]] || {
    om_error "The copied system has no /etc/kernel/cmdline."
    return 1
  }
  new_partuuid="$(state_get_or '.target.luks.partuuid' '')"
  root_subvol="$ROOT_SUBVOL"

  sed -i -E 's/[[:space:]]+resume=[^"[:space:]]+//g; s/[[:space:]]+resume_offset=[^"[:space:]]+//g' "$cmdline"
  if [[ -f $limine ]]; then
    sed -i -E 's/[[:space:]]+resume=[^"[:space:]]+//g; s/[[:space:]]+resume_offset=[^"[:space:]]+//g' "$limine"
  fi
  rm -f -- "$TGT_ROOT/etc/limine-entry-tool.d/resume.conf"

  if ! grep -qE 'cryptdevice=|rd\.luks\.name=' "$cmdline"; then
    om_warn "Source cmdline had no cryptdevice=; adding one for the new drive."
    printf ' cryptdevice=PARTUUID=%s:root root=/dev/mapper/root rootflags=subvol=%s rw rootfstype=btrfs\n' \
      "$new_partuuid" "$root_subvol" >>"$cmdline"
    if [[ -f $limine ]]; then
      printf '\nKERNEL_CMDLINE[default]+=" cryptdevice=PARTUUID=%s:root root=/dev/mapper/root rootflags=subvol=%s rw rootfstype=btrfs"\n' \
        "$new_partuuid" "$root_subvol" >>"$limine"
    fi
  fi

  if ! grep -qF -- "$new_partuuid" "$cmdline"; then
    om_error "The new LUKS PARTUUID did not make it into /etc/kernel/cmdline."
    return 1
  fi

  if [[ -f "$TGT_ROOT/etc/mkinitcpio.conf.d/omarchy_hooks.conf" ]]; then
    grep -q 'encrypt' "$TGT_ROOT/etc/mkinitcpio.conf.d/omarchy_hooks.conf" || {
      om_error "The source initramfs hooks do not include 'encrypt'."
      return 1
    }
  fi

  if [[ ! -f $limine ]]; then
    om_error "The copied system has no /etc/default/limine."
    return 1
  fi
  grep -q '^ESP_PATH=' "$limine" || printf '\nESP_PATH="/boot"\n' >>"$limine"
  return 0
}

migrate_install_tool() {
  local tool_root="$TGT_ROOT/usr/local/lib/omarchy-migrate"
  local users
  install -d -- "$tool_root" "$TGT_ROOT/usr/local/bin" "$TGT_ROOT/etc/systemd/system/multi-user.target.wants"
  cp -a -- "$OM_ROOT/bin" "$OM_ROOT/lib" "$OM_ROOT/VERSION" "$OM_ROOT/menu" "$OM_ROOT/systemd" "$tool_root/"
  install -m755 -- "$OM_ROOT"/bin/omarchy-migrate-* "$TGT_ROOT/usr/local/bin/"
  install -m644 -- "$OM_ROOT/systemd/omarchy-migrate-finalize.service" "$TGT_ROOT/etc/systemd/system/"
  ln -sf /etc/systemd/system/omarchy-migrate-finalize.service \
    "$TGT_ROOT/etc/systemd/system/multi-user.target.wants/omarchy-migrate-finalize.service"
  install -d -- "$TGT_ROOT/var/lib/omarchy-migration"

  users="$(menu_install_for_users "$TGT_ROOT")"
  om_log INFO "installed menu entry for $users user(s)"
  return 0
}

step_configure() {
  om_log INFO "generating target fstab"
  genfstab -U "$TGT_ROOT" >"$TGT_ROOT/etc/fstab" 2>>"$OM_LOG" || {
    om_error "genfstab failed for the new root."
    return 1
  }
  chmod 644 "$TGT_ROOT/etc/fstab"

  migrate_rewrite_uuids || return 1
  migrate_fix_cmdline || return 1
  migrate_install_tool || return 1

  # The copied fstab no longer matches anything; make sure it is the generated one.
  grep -qF -- "$(state_get_or '.target.btrfs.uuid' '')" "$TGT_ROOT/etc/fstab" || {
    om_error "The generated fstab does not reference the new btrfs UUID."
    return 1
  }
  sync
  return 0
}

step_swap() {
  local enabled size path offset
  enabled="$(state_get_or '.source.swapfile.enabled' 'false')"
  size="$(state_get_or '.source.swapfile.size' '0')"
  path="$(state_get_or '.source.swapfile.path' '/swap/swapfile')"
  rm -f -- "$TGT_ROOT/etc/limine-entry-tool.d/resume.conf"

  if [[ $enabled != true ]] || ((size <= 0)); then
    om_log INFO "no source swapfile; hibernation resume disabled"
    return 0
  fi

  mkdir -p -- "$TGT_ROOT$(dirname -- "$path")"
  if ! btrfs filesystem mkswapfile --size "$size" "$TGT_ROOT$path" >>"$OM_LOG" 2>&1; then
    om_warn "Could not recreate the hibernation swapfile. The system will boot without hibernation."
    return 0
  fi
  chmod 600 "$TGT_ROOT$path"

  offset="$(btrfs inspect-internal map-swapfile -r "$TGT_ROOT$path" 2>/dev/null || true)"
  if [[ -z $offset ]]; then
    om_warn "Could not compute the swapfile resume offset; hibernation will be unavailable."
    rm -f -- "$TGT_ROOT$path"
    return 0
  fi

  install -d -- "$TGT_ROOT/etc/limine-entry-tool.d"
  cat >"$TGT_ROOT/etc/limine-entry-tool.d/resume.conf" <<EOF
# Managed by omarchy-migrate. Recreated because the old swapfile cannot be copied.
KERNEL_CMDLINE[default]+=" resume=/dev/mapper/root resume_offset=$offset"
EOF
  printf '%s none swap defaults 0 0\n' "$path" >>"$TGT_ROOT/etc/fstab"

  state_jq --arg offset "$offset" --arg path "$path" --argjson size "$size" '
    .target.swapfile = {enabled: true, path: $path, size: $size, offset: $offset}
  '
  sync
  om_log INFO "recreated swapfile $path offset=$offset"
  return 0
}

migrate_chroot() {
  local root="$1"
  shift
  if om_have arch-chroot; then
    arch-chroot "$root" "$@"
    return
  fi

  mount --rbind /dev "$root/dev" >>"$OM_LOG" 2>&1 || return 1
  mount --rbind /sys "$root/sys" >>"$OM_LOG" 2>&1 || return 1
  mount --rbind /run "$root/run" >>"$OM_LOG" 2>&1 || return 1
  mount -t proc proc "$root/proc" >>"$OM_LOG" 2>&1 || return 1

  chroot "$root" "$@"
  local rc=$?

  umount -R "$root/run" >>"$OM_LOG" 2>&1 || true
  umount -R "$root/sys" >>"$OM_LOG" 2>&1 || true
  umount "$root/proc" >>"$OM_LOG" 2>&1 || true
  umount -R "$root/dev" >>"$OM_LOG" 2>&1 || true
  return "$rc"
}

step_initramfs() {
  om_log INFO "mkinitcpio -P in target"
  if ! migrate_chroot "$TGT_ROOT" mkinitcpio -P >>"$OM_LOG" 2>&1; then
    om_error "mkinitcpio failed. See the log for the failing hook."
    return 1
  fi

  local ukis
  ukis="$(find "$TGT_ROOT/boot/EFI/Linux" -maxdepth 1 -name '*.efi' 2>/dev/null | wc -l)"
  ((ukis > 0)) || {
    om_error "mkinitcpio produced no unified kernel images under /boot/EFI/Linux."
    return 1
  }
  [[ -f "$TGT_ROOT/boot/limine.conf" ]] || {
    om_error "limine-entry-tool did not produce /boot/limine.conf."
    return 1
  }
  sync
  om_log INFO "initramfs and $ukis UKI(s) generated"
  return 0
}

step_bootloader() {
  local fallback="" num new_partuuid efi
  if grep -q 'ENABLE_LIMINE_FALLBACK=yes' "$TGT_ROOT/etc/default/limine" 2>/dev/null; then
    fallback="--fallback"
  fi

  if om_is_uefi; then
    om_need efibootmgr
    om_log INFO "limine-install $fallback inside target"
    if ! migrate_chroot "$TGT_ROOT" limine-install $fallback >>"$OM_LOG" 2>&1; then
      om_warn "limine-install failed; falling back to a direct firmware entry."
    fi
    if [[ -x "$TGT_ROOT/usr/bin/limine-enroll-config" ]]; then
      migrate_chroot "$TGT_ROOT" limine-enroll-config >>"$OM_LOG" 2>&1 || true
    fi

    new_partuuid="$(state_get_or '.target.esp.partuuid' '')"
    num="$(efi_find_partuuid "$new_partuuid" | head -n1)"
    if [[ -z $num ]]; then
      num="$(efi_create_entry "$TGT_DISK" "$TGT_ESP_NUM" "Limine" '\EFI\limine\limine_x64.efi' || true)"
    fi
    [[ -n $num ]] || {
      om_error "The new drive has no UEFI boot entry."
      return 1
    }
    efi_set_order_first "$num" || om_warn "Could not update the firmware boot order."
    efi_set_bootnext "$num" || true
    state_set_str '.target.efi_bootnum' "$num"
    om_log INFO "UEFI entry $num points at the new drive"
  else
    om_log INFO "limine bios-install $TGT_DISK"
    if ! migrate_chroot "$TGT_ROOT" limine bios-install "$TGT_DISK" >>"$OM_LOG" 2>&1; then
      om_error "limine bios-install failed; the new drive will not boot on this firmware."
      return 1
    fi
    om_warn "Legacy BIOS: set $TGT_DISK first in the firmware boot order after rebooting."
  fi

  local efi_count
  efi_count="$(find "$TGT_ROOT/boot/EFI" -name '*.efi' 2>/dev/null | wc -l)"
  ((efi_count > 0)) || {
    om_error "No EFI binaries were installed on the new ESP."
    return 1
  }
  sync
  return 0
}

step_verify() {
  local failures=0
  _check() {
    if "$@"; then return 0; fi
    om_error "Verification failed: $*"
    failures=$((failures + 1))
  }

  _check test -f "$TGT_ROOT/etc/fstab"
  _check test -f "$TGT_ROOT/boot/limine.conf"
  _check test -x "$TGT_ROOT/usr/bin/omarchy"
  _check test -x "$TGT_ROOT/usr/local/bin/omarchy-migrate-drive"
  _check test -L "$TGT_ROOT/etc/systemd/system/multi-user.target.wants/omarchy-migrate-finalize.service"
  _check grep -qF -- "$(state_get_or '.target.btrfs.uuid' '')" "$TGT_ROOT/etc/fstab"
  _check grep -qF -- "$(state_get_or '.target.esp.uuid' '')" "$TGT_ROOT/etc/fstab"
  _check grep -qF -- "$(state_get_or '.target.luks.partuuid' '')" "$TGT_ROOT/etc/kernel/cmdline"
  _check cryptsetup isLuks "$TGT_LUKS_PART"

  local stale_luks
  stale_luks="$(state_get_or '.source.luks.partuuid' '')"
  if [[ -n $stale_luks ]] && grep -qF -- "$stale_luks" "$TGT_ROOT/boot/limine.conf" 2>/dev/null; then
    om_error "The generated Limine configuration still references the old LUKS partition."
    failures=$((failures + 1))
  fi

  local ukis
  ukis="$(find "$TGT_ROOT/boot/EFI/Linux" -maxdepth 1 -name '*.efi' 2>/dev/null | wc -l)"
  ((ukis > 0)) || {
    om_error "No unified kernel images on the new ESP."
    failures=$((failures + 1))
  }

  if om_is_uefi; then
    local num
    num="$(efi_find_partuuid "$(state_get_or '.target.esp.partuuid' '')" | head -n1)"
    [[ -n $num ]] || {
      om_error "No firmware entry points at the new ESP."
      failures=$((failures + 1))
    }
  fi

  ((failures == 0)) || return 1
  om_log INFO "verification passed"
  return 0
}

step_finalize_target() {
  local now srcpu tgtpu usbnum usblabel report
  now="$(om_now)"
  srcpu="$(state_get_or '.source.esp.partuuid' '')"
  tgtpu="$(state_get_or '.target.esp.partuuid' '')"
  usbnum="$(state_get_or '.usb.efi_bootnum' '')"
  usblabel="$(state_get_or '.usb.efi_label' 'Omarchy Migration USB')"

  state_jq --arg now "$now" --arg srcpu "$srcpu" --arg tgtpu "$tgtpu" \
    --arg usbnum "$usbnum" --arg usblabel "$usblabel" '
    .phase = "complete"
    | .completed_at = $now
    | .pending_finalize = true
    | .finalize = {
        pending: true,
        source_esp_partuuid: $srcpu,
        target_esp_partuuid: $tgtpu,
        usb_efi_bootnum: (if $usbnum == "" then null else $usbnum end),
        usb_label: $usblabel
      }
  '

  state_copy_to "$TGT_ROOT" || {
    om_error "Could not copy the completion state to the new drive."
    return 1
  }

  report="$TGT_ROOT/var/lib/omarchy-migration/migration-report.txt"
  cat >"$report" <<EOF
Omarchy drive migration
=======================
Run:        $(state_get '.run_id')
Started:    $(state_get '.created_at')
Completed:  $now
Source:     $(state_get '.source.disk') ($(state_get_or '.source.serial' 'unknown'))
Target:     $(state_get '.target.disk') ($(state_get_or '.target.serial' 'unknown'))
Root:       LUKS2 + btrfs, subvolume $ROOT_SUBVOL
Steps:      $(state_get '.step_order | length')
Log:        $OM_LOG
EOF
  chmod 644 "$report" 2>/dev/null || true

  ln -sf /etc/systemd/system/omarchy-migrate-finalize.service \
    "$TGT_ROOT/etc/systemd/system/multi-user.target.wants/omarchy-migrate-finalize.service"
  sync
  om_log INFO "completion state written to target"
  return 0
}

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------

migrate_cleanup() {
  sync 2>/dev/null || true
  local mnt
  for mnt in "$TGT_ROOT" "$TGT_TOP" "$SRC_ROOT" "$SRC_TOP"; do
    [[ -n $mnt && -d $mnt ]] || continue
    if mountpoint -q "$mnt"; then
      umount -R "$mnt" >>"$OM_LOG" 2>&1 || umount "$mnt" >>"$OM_LOG" 2>&1 || true
    fi
  done
  if [[ -n ${SRC_ESP_MNT:-} && $SRC_ESP_MNT != "$OM_STATE_MNT" ]]; then
    mountpoint -q "$SRC_ESP_MNT" && umount "$SRC_ESP_MNT" >>"$OM_LOG" 2>&1 || true
  fi
  if mountpoint -q "$OM_STATE_MNT"; then
    umount "$OM_STATE_MNT" >>"$OM_LOG" 2>&1 || true
  fi
  if [[ -n ${TGT_MAPPER:-} ]] && cryptsetup status "$TGT_MAPPER" >/dev/null 2>&1; then
    cryptsetup close "$TGT_MAPPER" >>"$OM_LOG" 2>&1 || true
  fi
  if [[ -n ${SRC_MAPPER:-} ]] && cryptsetup status "$SRC_MAPPER" >/dev/null 2>&1; then
    cryptsetup close "$SRC_MAPPER" >>"$OM_LOG" 2>&1 || true
  fi
}

migrate_complete() {
  local target phase pending
  phase="$(state_get_or '.phase' '')"
  pending="$(state_get_or '.pending_finalize' 'false')"
  target="$(state_get '.target.disk')"

  ui_success_panel "Migration complete" \
    "Omarchy was migrated to $target." \
    "$(om_is_uefi && printf 'The new drive is first in the boot order. ' || printf '')The first boot will remove the old firmware entries." \
    "" \
    "Source state: $STATE_FILE" \
    "Log:          $OM_LOG"

  if [[ $MIGRATION_TARGET_KIND == live ]]; then
    if ui_confirm "Reboot into the new drive now?" yes; then
      ui_note "Rebooting…"
      sync
      sleep 1
      systemctl reboot
      return 0
    fi
    ui_note "Run 'reboot' when ready. The new drive is already selected."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Live and host entry points
# ---------------------------------------------------------------------------

migrate_live() {
  local phase source_disk target_disk plan_json pending current

  om_init_runtime
  om_lock
  om_require_root
  ui_color_init
  MIGRATION_TARGET_KIND=live

  ui_banner "Migration tool"
  ui_note "Progress is stored on the source drive, so this USB can be recreated safely."

  # 1. Find an existing state (source ESP) or the plan seeded into this image.
  if ! migrate_discover_state; then
    ui_error_panel "No migration plan found" \
      "Neither the source ESP nor this USB contains a migration plan." \
      "Run omarchy-migrate-drive from the installed system first."
    return 1
  fi

  # 2. Resolve the two drives. Device names can change across reboots, so the
  #    recorded serial number is authoritative.
  if ! source_disk="$(migrate_resolve_source_disk)"; then
    source_disk="$(migrate_choose_source)" || return 1
  fi
  if ! target_disk="$(migrate_resolve_target_from_state)"; then
    target_disk="$(migrate_choose_target "$source_disk")" || return 1
  fi
  [[ $source_disk != "$target_disk" ]] || {
    ui_error_panel "Invalid selection" "The source and target are the same drive." "$OM_LOG"
    return 1
  }

  SRC_DISK="$source_disk"
  TGT_DISK="$target_disk"
  state_set_str '.source.disk' "$SRC_DISK"
  state_set_str '.target.disk' "$TGT_DISK"
  state_set_str '.target.serial' "$(om_disk_field "$TGT_DISK" SERIAL)"
  state_set_str '.target.model' "$(om_disk_field "$TGT_DISK" MODEL)"
  state_set_str '.target.size' "$(detect_size_bytes "$TGT_DISK")"
  state_save

  phase="$(state_get_or '.phase' 'prepared')"
  pending="$(state_get_or '.pending_finalize' 'false')"
  if [[ $phase == complete && $pending != true ]]; then
    ui_success_panel "Migration already complete" \
      "Run $(state_get '.run_id') finished on $(state_get_or '.completed_at' 'an earlier boot')." \
      "Boot the new drive ($(state_get '.target.disk')), or prepare a new plan with omarchy-migrate-drive."
    return 0
  fi

  # 3. Resume or prepare.
  if [[ $phase == migrating || $phase == failed ]]; then
    current="$(state_get_or '.failed_step' '')"
    [[ -z $current ]] && current="$(state_get_or '.current_step' 'the first unfinished step')"
    ui_section "Resume"
    ui_kv "Phase" "$phase"
    ui_kv "Next step" "$current"
    ui_kv "Source" "$(detect_disk_description "$source_disk")"
    ui_kv "Target" "$(detect_disk_description "$target_disk")"
    ui_confirm "Resume this migration where it stopped?" yes || return 1
  fi

  # 4. Unlock and mount the source read-only.
  ui_section "Unlocking the source"
  migrate_unlock_source || return 1
  migrate_mount_source || return 1
  migrate_persist_state_to_source "$source_disk"
  state_load
  migrate_ensure_source_analysis || return 1

  # 5. Target paths and plan.
  migrate_prepare_target_paths
  migrate_prepare_target_for_resume || return 1
  PLAN_SOURCE_ROOT="$SRC_ROOT"
  plan_json="$(state_get_or '.plan' '')"
  if [[ -z $plan_json || $plan_json == null ]]; then
    plan_json="$(plan_compute "$(state_get '.source')" "$TGT_DISK")"
  fi

  if state_should_run partition; then
    plan_json="$(plan_confirm_fit "$plan_json")" || {
      ui_error_panel "Target too small" "The selected drive cannot hold this Omarchy installation." "$OM_LOG"
      return 1
    }
    state_set_raw '.plan' "$plan_json"
    state_save
    migrate_confirm_erase "$TGT_DISK" || {
      ui_note "Cancelled. Nothing on the target was changed."
      return 1
    }
  else
    ui_note "Resuming after partitioning; the target will not be erased again."
  fi

  # 6. Register and run the steps.
  migrate_register_steps
  state_save
  migrate_run_steps || return 1
  state_save
  migrate_complete
}

# Running `migrate` from the installed system is only useful for status; the
# destructive work requires the source to be inactive.
migrate_host() {
  om_init_runtime
  om_require_root
  ui_banner "Migrate Omarchy"
  if om_is_live; then
    migrate_live
    return
  fi
  ui_error_panel "Boot the migration USB" \
    "The source drive is in use, so it cannot be copied safely." \
    "Run 'omarchy-migrate-drive prepare' to build the USB," \
    "then boot it to perform the migration."
  return 1
}
