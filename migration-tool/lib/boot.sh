#!/usr/bin/env bash
# shellcheck shell=bash
#
# UEFI boot-entry management and first-boot finalisation.
#
# Limine itself is installed by Omarchy's limine-entry-tool inside the target
# chroot. This module only handles the firmware side: registering a one-shot
# entry for the migration USB, putting the new drive first, and removing stale
# entries after the new system has booted.

efi_entries() {
  efibootmgr 2>/dev/null | grep -E '^Boot[0-9A-Fa-f]{4}\*?[[:space:]]' || true
}

efi_entry_num() {
  local line="$1"
  printf '%s\n' "$line" | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p'
}

efi_entry_label() {
  local line="$1"
  printf '%s\n' "$line" | sed -E 's/^Boot[0-9A-Fa-f]{4}\*?[[:space:]]+//' | cut -f1
}

efi_entry_partuuid() {
  local line="$1"
  printf '%s\n' "$line" | grep -oE 'GPT,[0-9a-fA-F-]{36}' | head -n1 | cut -d, -f2
}

efi_entry_loader() {
  local line="$1"
  printf '%s\n' "$line" |
    sed -n -e 's/.*File(\([^)]*\)).*/\1/p' -e 's#.*)/\(\\.*\)$#\1#p'
}

efi_find_label() {
  local label="$1" line
  while IFS= read -r line; do
    [[ $(efi_entry_label "$line") == "$label" ]] && efi_entry_num "$line"
  done < <(efi_entries)
}

efi_find_partuuid() {
  local partuuid="$1" line
  [[ -n $partuuid ]] || return 0
  while IFS= read -r line; do
    [[ $(efi_entry_partuuid "$line") == "$partuuid" ]] && efi_entry_num "$line"
  done < <(efi_entries)
}

efi_delete_num() {
  local num="$1"
  [[ -n $num ]] || return 0
  om_log INFO "efibootmgr --delete-bootnum $num"
  efibootmgr --delete-bootnum --bootnum "$num" >>"$OM_LOG" 2>&1 || true
}

efi_delete_label() {
  local label="$1" num
  while IFS= read -r num; do
    efi_delete_num "$num"
  done < <(efi_find_label "$label")
}

efi_create_entry() {
  local disk="$1" partnum="$2" label="$3" loader="$4"
  local before after num

  # Replace an entry with the same label rather than piling up duplicates.
  efi_delete_label "$label" >/dev/null 2>&1 || true

  om_log INFO "efibootmgr --create --disk $disk --part $partnum --label '$label' --loader '$loader'"
  efibootmgr --create --disk "$disk" --part "$partnum" --label "$label" --loader "$loader" >>"$OM_LOG" 2>&1 || return 1
  num="$(efi_find_label "$label" | head -n1)"
  [[ -n $num ]] || return 1
  printf '%s\n' "$num"
}

efi_set_bootnext() {
  local num="$1"
  [[ -n $num ]] || return 1
  om_log INFO "efibootmgr --bootnext $num"
  efibootmgr --bootnext "$num" >>"$OM_LOG" 2>&1
}

efi_boot_order() {
  efibootmgr 2>/dev/null | sed -n 's/^BootOrder:[[:space:]]*//p' | head -n1
}

# Put $1 first while preserving the rest of the firmware order.
efi_set_order_first() {
  local num="$1" current rest
  [[ -n $num ]] || return 1
  current="$(efi_boot_order)"
  rest="$(printf '%s' "$current" | tr ',' '\n' | sed '/^$/d' | grep -vix "$num" | paste -sd, -)"
  if [[ -n $rest ]]; then
    om_log INFO "efibootmgr --bootorder $num,$rest"
    efibootmgr --bootorder "$num,$rest" >>"$OM_LOG" 2>&1
  else
    efibootmgr --bootorder "$num" >>"$OM_LOG" 2>&1
  fi
}

efi_partnum() {
  local part="$1"
  lsblk -no PARTN -- "$part" 2>/dev/null | head -n1 | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Migration USB one-shot boot
# ---------------------------------------------------------------------------

usb_efi_partition() {
  local disk="$1" part
  while IFS= read -r part; do
    [[ $(om_part_field "$part" FSTYPE) == vfat ]] && {
      printf '%s\n' "$part"
      return 0
    }
  done < <(om_partitions "$disk")
  return 1
}

# Create a firmware entry for the live USB and make it the next boot target.
# Prints the boot number.
usb_boot_once() {
  local disk="$1" label="Omarchy Migration USB"
  local part partnum num
  om_is_uefi || return 1
  om_need efibootmgr

  part="$(usb_efi_partition "$disk")" || om_die "No EFI partition found on $disk."
  partnum="$(efi_partnum "$part")"
  [[ -n $partnum ]] || om_die "Could not determine the EFI partition number on $disk."

  num="$(efi_create_entry "$disk" "$partnum" "$label" '\EFI\BOOT\BOOTX64.EFI')" ||
    om_die "Could not register the migration USB in the firmware."

  efi_set_bootnext "$num" || om_warn "Firmware refused BootNext; the USB was placed first in the boot order."
  efi_set_order_first "$num" || om_warn "Could not update the firmware boot order."

  om_log INFO "migration USB entry $num registered on $disk partition $partnum"
  printf '%s\n' "$num"
}

# ---------------------------------------------------------------------------
# First boot of the migrated system
# ---------------------------------------------------------------------------

_boot_state_file() {
  printf '/var/lib/omarchy-migration/state.json\n'
}

boot_finalize() {
  local state_file pending phase
  state_file="$(_boot_state_file)"
  [[ -f $state_file ]] || {
    om_info "No migrated-system state at $state_file; nothing to finalise."
    return 0
  }
  pending="$(jq -r '.pending_finalize // false' "$state_file" 2>/dev/null || echo false)"
  phase="$(jq -r '.phase // ""' "$state_file" 2>/dev/null || true)"
  if [[ $pending != true ]]; then
    om_info "Migration finalisation already complete (phase=$phase)."
    return 0
  fi

  om_init_runtime
  om_lock
  om_log INFO "finalising migration run $(jq -r '.run_id' "$state_file")"

  local new_partuuid source_partuuid temp_num temp_label
  new_partuuid="$(jq -r '.target.esp.partuuid // ""' "$state_file")"
  if [[ -z $new_partuuid ]] || ! blkid -t "PARTUUID=$new_partuuid" -o device >/dev/null 2>&1; then
    new_partuuid="$(blkid -s PARTUUID -o value "$(findmnt -no SOURCE -M /boot 2>/dev/null)" 2>/dev/null || true)"
  fi
  source_partuuid="$(jq -r '.source.esp.partuuid // ""' "$state_file")"
  temp_num="$(jq -r '.usb.efi_bootnum // ""' "$state_file")"
  temp_label="$(jq -r '.usb.efi_label // "Omarchy Migration USB"' "$state_file")"

  local removed=() num

  if om_is_uefi; then
    om_need efibootmgr

    # The live USB entry was only needed for one boot.
    [[ -n $temp_num ]] && efi_delete_num "$temp_num" && removed+=("usb:$temp_num")
    while IFS= read -r num; do
      [[ -n $num ]] || continue
      efi_delete_num "$num" && removed+=("usb-label:$num")
    done < <(efi_find_label "$temp_label")

    # Old source-drive entries would boot the old install and are now stale.
    if [[ -n $source_partuuid && $source_partuuid != "$new_partuuid" ]]; then
      while IFS= read -r num; do
        [[ -n $num ]] || continue
        efi_delete_num "$num" && removed+=("source:$num")
      done < <(efi_find_partuuid "$source_partuuid")
    fi

    # Make sure the new drive has a Limine entry, then put it first.
    local new_num
    new_num="$(efi_find_partuuid "$new_partuuid" | head -n1)"
    if [[ -z $new_num ]] && om_have limine-install; then
      limine-install >>"$OM_LOG" 2>&1 || true
      new_num="$(efi_find_partuuid "$new_partuuid" | head -n1)"
    fi
    if [[ -z $new_num ]]; then
      new_num="$(efi_find_label "Limine" | head -n1)"
    fi
    if [[ -n $new_num ]]; then
      efi_set_order_first "$new_num" || true
      efi_set_bootnext "$new_num" || true
    else
      om_warn "No Limine firmware entry was found after migration."
    fi
  else
    # Legacy BIOS boot order is firmware-specific. limine bios-install already
    # wrote the MBR; tell the user what remains.
    om_warn "Legacy BIOS boot order cannot be changed safely from Linux. Set the new drive first in the firmware if needed."
  fi

  # Remove the source ESP's resume state so booting the old drive later does not
  # offer to resume a migration that already finished. Best effort.
  if [[ -n $source_partuuid && $source_partuuid != "$new_partuuid" ]]; then
    local src_part src_mnt
    src_part="$(blkid -t "PARTUUID=$source_partuuid" -o device 2>/dev/null | head -n1)"
    if [[ -b $src_part ]]; then
      src_mnt="$(mktemp -d "$OM_RUN_DIR/source-esp.XXXXXX")"
      if mount -o rw "$src_part" "$src_mnt" >/dev/null 2>&1; then
        rm -f -- "$src_mnt/omarchy-migration/state.json"
        sync
        umount "$src_mnt" >/dev/null 2>&1 || true
      fi
      rmdir "$src_mnt" 2>/dev/null || true
    fi
  fi

  local now report
  now="$(om_now)"
  report="/var/lib/omarchy-migration/migration-report.txt"
  cat >"$report" <<EOF
Omarchy drive migration
=======================
Run:        $(jq -r '.run_id' "$state_file")
Completed:  $(jq -r '.completed_at // .updated_at' "$state_file")
Source:     $(jq -r '.source.disk' "$state_file") ($(jq -r '.source.serial // "unknown"' "$state_file"))
Target:     $(jq -r '.target.disk' "$state_file") ($(jq -r '.target.serial // "unknown"' "$state_file"))
Phase:      complete
Finalised:  $now
Removed firmware entries: ${removed[*]:-none}
EOF
  chmod 644 "$report" 2>/dev/null || true

  # Copy timezone configuration from source ESP to target system
  copy_timezone_from_source() {
    local source_esp="$1" target_root="$2" log_file="$3"
    
    # If called without mount point arguments, derive them for first boot scenario
    if [[ -z "$source_esp" && -n "${OM_LIVE:-}" ]]; then
      # Running on live USB during migrate_live - derive paths from current state
      source_esp="$(findmnt -no SOURCE -M /boot 2>/dev/null || true)"
      target_root="/run/live/mount/target"
    elif [[ -z "$source_esp" && -z "${OM_LIVE:-}" ]]; then
      # Running directly on target system during first boot - use standard mount points
      source_esp="$(findmnt -no SOURCE -M /boot 2>/dev/null || true)"
      target_root="/"
    fi
    
    if [[ -z "$source_esp" ]]; then
      om_log WARN "Cannot determine source ESP mount point; skipping timezone copy."
      return 1
    fi

    local source_etc="${source_esp}/etc"
    local target_etc="/etc"
    
    # Validate that source and target filesystems are mounted before proceeding
    if ! mountpoint -q "$target_root" >/dev/null 2>&1; then
      om_log WARN "Target root is not a mount point; skipping timezone copy."
      return 1
    fi
    
    if [[ ! -d "$source_esp" || ! -d "${source_etc}" ]]; then
      om_log WARN "Source ESP not available: $source_esp (etc: ${source_etc})"
      return 1
    fi

    om_log INFO "Copying timezone configuration from source to target..."
    
    local tzdata_source="${source_esp}/usr/share/zoneinfo"
    local tzdata_target="${target_root}/usr/share/zoneinfo"
    local sys_config_source="${source_etc}/timedate.conf"
    local sys_config_target="/etc/timedate.conf"
    
    # Copy tzdata if available
    if [[ -d "$tzdata_source" ]]; then
      om_log INFO "Source timezone data directory found: $tzdata_source"
      mkdir -p "$tzdata_target" 2>/dev/null || {
        om_log WARN "Cannot create timezone target directory: $tzdata_target"
        return 1
      }
      
      if rsync -a --no-owner --no-group "$tzdata_source/" "$tzdata_target/" >>"$log_file" 2>&1; then
        om_log INFO "Timezone data copied successfully"
      else
        om_log WARN "Partial timezone copy, using system default"
        return 1
      fi
    else
      om_log WARN "No timezone data found at $tzdata_source"
      return 1
    fi
    
    # Copy timedate.conf if available on source
    if [[ -r "$sys_config_source" ]]; then
      cp -n "$sys_config_source" "$sys_config_target" 2>/dev/null || {
        om_log WARN "Cannot copy timedate.conf from source: $sys_config_source"
      }
    fi
    
    return 0
  }

  # Execute timezone copy in target chroot after filesystems are created
  # During first boot, we're running directly on target - mount points are at their final locations
  local tz_success=true
  if ! copy_timezone_from_source "" "" "$OM_LOG"; then
    om_log WARN "Timezone configuration may differ from source system"
  fi

  local tmp="${state_file}.tmp.$$"
  jq -S --arg now "$now" --arg report "$report" '
    .pending_finalize = false
    | .phase = "complete"
    | .finalized_at = $now
    | .finalize = {done: true, at: $now, report: $report}
    | .updated_at = $now
  ' "$state_file" >"$tmp" && mv -f "$tmp" "$state_file"
  chmod 600 "$state_file" 2>/dev/null || true

  om_notify "Migration complete" "Omarchy is now running from $(jq -r '.target.disk' "$state_file")."
  om_log INFO "finalisation complete; removed: ${removed[*]:-none}"
  printf 'Migration finalised.\n'
  printf 'Report: %s\n' "$report"
}
