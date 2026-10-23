#!/usr/bin/env bash
# shellcheck shell=bash
#
# Host-side USB preparation: pick a stick, build the archiso image, write it,
# verify it and arm a one-shot boot.

: "${USB_DISK:=}"
: "${USB_ISO:=}"
: "${USB_MANIFEST:=}"
: "${USB_REUSED:=0}"

usb_require_build_deps() {
  local missing=()
  local cmd
  for cmd in mkarchiso mksquashfs xorriso mkfs.fat mcopy losetup mount umount dd sync partprobe blkid jq; do
    om_have "$cmd" || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    om_die "Cannot build the migration image. Missing: ${missing[*]}
Install the build tools with: sudo pacman -S --needed archiso squashfs-tools libisoburn mtools dosfstools"
  fi
}

usb_files_json() {
  local root="${1:-$OM_ROOT}"
  (
    cd -- "$root" || exit 1
    find bin lib live menu systemd -type f -print0 2>/dev/null |
      sort -z |
      while IFS= read -r -d '' file; do
        printf '%s  %s\n' "$(sha256sum "$file" | awk '{print $1}')" "$file"
      done | jq -R -s 'split("\n") | map(select(length > 0) | {
        hash: (split("  ")[0]),
        path: (split("  ")[1])
      })'
  )
}

usb_manifest_json() {
  local built_at="${1:-$(om_now)}"
  jq -n \
    --arg name "omarchy-migrate" \
    --arg version "$OM_VERSION" \
    --arg fingerprint "$(om_fingerprint)" \
    --arg built_at "$built_at" \
    --arg host "$(cat /etc/hostname 2>/dev/null || hostname 2>/dev/null || echo unknown)" \
    --argjson files "$(usb_files_json)" \
    '{
      schema: 1,
      name: $name,
      version: $version,
      fingerprint: $fingerprint,
      built_at: $built_at,
      built_on: $host,
      iso_label: "OMARCHY_MIGRATE",
      files: $files
    }'
}

usb_manifest_is_current() {
  local manifest_json="$1" expected
  expected="$(om_fingerprint)"
  [[ $(jq -r '.fingerprint // ""' <<<"$manifest_json") == "$expected" ]]
}

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

usb_candidates() {
  local source live disk
  source="$(detect_current_source_disk 2>/dev/null || true)"
  live="$(detect_live_usb_disk 2>/dev/null || true)"
  while IFS= read -r disk; do
    [[ -n $disk ]] || continue
    detect_disk_is_usb "$disk" || continue
    [[ -n $source && $disk == "$source" ]] && continue
    [[ -n $live && $disk == "$live" ]] && continue
    printf '%s\n' "$disk"
  done < <(detect_disks)
}

usb_unmount_disk() {
  local disk="$1" node
  while IFS= read -r node; do
    [[ -n $node ]] || continue
    if findmnt -rn -S "$node" -o TARGET >/dev/null 2>&1; then
      om_log INFO "unmounting $node"
      umount "$node" >>"$OM_LOG" 2>&1 || om_die "Could not unmount $node. Close anything using it and try again."
    fi
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$node"; then
      swapoff "$node" >>"$OM_LOG" 2>&1 || om_die "Could not disable swap on $node."
    fi
  done < <(detect_nodes_of_disk "$disk")
}

# Sets USB_DISK. Returns 1 if the user cancelled.
usb_select() {
  local timeout="${1:-180}" disks=() descriptions=() selected
  while :; do
    mapfile -t disks < <(usb_candidates)
    if ((${#disks[@]})); then
      break
    fi
    ui_warn "No USB drive detected."
    printf '  Plug in the USB drive you want to turn into the Omarchy migration tool.\n'
    printf '  Waiting up to %ss (Ctrl-C to cancel)…\n' "$timeout"
    if detect_wait_for_usb "$timeout" >/dev/null; then
      sleep 1
      continue
    fi
    return 1
  done

  local disk
  for disk in "${disks[@]}"; do
    descriptions+=("$(detect_disk_description "$disk")")
  done

  selected="$(ui_choose "Select the USB drive to erase and prepare" "${descriptions[@]}")" || return 1
  USB_DISK="${selected%%[[:space:]]*}"
  [[ -n $USB_DISK && -b $USB_DISK ]] || return 1
  return 0
}

usb_confirm_erase() {
  local disk="$1" answer
  ui_section "Destructive action"
  printf '  The following drive will be completely erased:\n\n'
  printf '    %s\n\n' "$(detect_disk_description "$disk")"
  if [[ -n $(findmnt -rn -S "$disk" -o TARGET 2>/dev/null) ]]; then
    printf '  Some partitions are currently mounted; they will be unmounted.\n'
  fi
  if [[ ${OM_ASSUME_YES:-0} == 1 ]]; then
    return 0
  fi
  printf '  Type %s to continue: ' "$(_c "1;$UI_ERR" "ERASE")"
  IFS= read -r answer || return 1
  [[ $answer == ERASE ]]
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

usb_build_iso() {
  usb_require_build_deps
  om_require_root

  local build_root="${OM_BUILD_DIR:-/var/tmp/omarchy-migrate-build}"
  local profile="$build_root/profile"
  local work="$build_root/work"
  local out="$build_root/out"
  local manifest seed_plan

  om_info "building migration ISO in $build_root"
  rm -rf -- "$work" "$out" "$profile"
  mkdir -p -- "$profile" "$out"

  # Base archiso profile (boot modes, packages, plymouth, autostart).
  cp -a -- "$OM_ROOT/live/profile/." "$profile/"

  # Payload used both inside the live system and for host-side freshness checks.
  install -d -- "$profile/airootfs/usr/local/lib/omarchy-migrate"
  cp -a -- "$OM_ROOT/bin" "$OM_ROOT/lib" "$OM_ROOT/VERSION" "$OM_ROOT/menu" "$OM_ROOT/systemd" \
    "$profile/airootfs/usr/local/lib/omarchy-migrate/"
  install -d -- "$profile/airootfs/usr/local/bin"
  install -m755 -- "$OM_ROOT"/bin/omarchy-migrate-* "$profile/airootfs/usr/local/bin/"

  # Plymouth theme.
  install -d -- "$profile/airootfs/usr/share/plymouth/themes/omarchy-migrate"
  cp -a -- "$OM_ROOT"/live/plymouth/. "$profile/airootfs/usr/share/plymouth/themes/omarchy-migrate/"

  manifest="$(usb_manifest_json)"
  install -d -- "$profile/airootfs/usr/local/share/omarchy-migrate"
  printf '%s\n' "$manifest" >"$profile/airootfs/usr/local/share/omarchy-migrate/manifest.json"

  # Seed plan lets the live tool recover if the state file is unavailable.
  if state_exists; then
    seed_plan="$(jq -S '{
      schema, run_id, tool_version, tool_fingerprint, phase,
      created_at, source, target, plan, options
    }' "$STATE_FILE")"
    printf '%s\n' "$seed_plan" >"$profile/airootfs/usr/local/share/omarchy-migrate/seed-plan.json"
  fi

  om_log INFO "running mkarchiso"
  printf '\n  Building the live image. This downloads packages on first use and can take several minutes.\n\n'
  if ! mkarchiso -v -w "$work" -o "$out" "$profile" >>"$OM_LOG" 2>&1; then
    om_error "mkarchiso failed."
    printf '  See %s for details.\n' "$OM_LOG"
    return 1
  fi

  USB_ISO="$(find "$out" -maxdepth 1 -name 'omarchy-migrate-*.iso' -printf '%T@ %p\n' |
    sort -n | tail -n1 | cut -d' ' -f2-)"
  [[ -n $USB_ISO && -f $USB_ISO ]] || {
    om_error "The build finished but no ISO was produced."
    return 1
  }
  printf '\n  Built %s (%s)\n' "$USB_ISO" "$(om_human_bytes "$(stat -c %s "$USB_ISO")")"
  om_log INFO "built ISO $USB_ISO"
  return 0
}

# ---------------------------------------------------------------------------
# Write and verify
# ---------------------------------------------------------------------------

usb_write_iso() {
  local disk="$1" iso="$2" iso_size disk_size
  om_require_root
  [[ -f $iso ]] || om_die "ISO not found: $iso"
  detect_disk_is_usb "$disk" || om_die "$disk is not a USB drive."

  iso_size="$(stat -c %s "$iso")"
  disk_size="$(detect_size_bytes "$disk")"
  ((disk_size > iso_size)) || om_die "The USB drive is smaller than the image."

  usb_unmount_disk "$disk"

  om_log INFO "wipefs $disk"
  wipefs -a -- "$disk" >>"$OM_LOG" 2>&1 || true

  printf '\n  Writing %s to %s…\n' "$(basename "$iso")" "$disk"
  if [[ -t 2 ]]; then
    dd if="$iso" of="$disk" bs=4M conv=fsync status=progress oflag=direct \
      2> >(tee -a "$OM_LOG" >&2) ||
      {
        # Some USB bridges reject O_DIRECT; retry without it.
        om_warn "Direct I/O failed; retrying without it."
        dd if="$iso" of="$disk" bs=4M conv=fsync status=progress \
          2> >(tee -a "$OM_LOG" >&2) ||
          om_die "Writing the image to $disk failed."
      }
  else
    dd if="$iso" of="$disk" bs=4M conv=fsync status=progress oflag=direct >>"$OM_LOG" 2>&1 ||
      dd if="$iso" of="$disk" bs=4M conv=fsync status=progress >>"$OM_LOG" 2>&1 ||
      om_die "Writing the image to $disk failed."
  fi
  sync
  partprobe "$disk" >>"$OM_LOG" 2>&1 || true
  udevadm settle --timeout=30 >>"$OM_LOG" 2>&1 || true
  om_log INFO "wrote $iso to $disk"
}

# Sets USB_MANIFEST. Fails when the written image cannot be identified.
usb_verify_written() {
  local disk="$1" part manifest_json
  part="$(blkid -L "$MIGRATION_ISO_LABEL" -o device 2>/dev/null | while read -r p; do
    om_parent_disk "$p" 2>/dev/null | grep -qx "$disk" && printf '%s\n' "$p"
  done | head -n1)"

  if [[ -z $part ]]; then
    # Allow the firmware/label scan a moment to catch up.
    sleep 2
    part="$(blkid -L "$MIGRATION_ISO_LABEL" -o device 2>/dev/null | while read -r p; do
      om_parent_disk "$p" 2>/dev/null | grep -qx "$disk" && printf '%s\n' "$p"
    done | head -n1)"
  fi
  [[ -n $part ]] || {
    om_error "The written USB does not expose the $MIGRATION_ISO_LABEL volume."
    return 1
  }

  manifest_json="$(_detect_iso_manifest "$part" 2>/dev/null || true)"
  [[ -n $manifest_json ]] || {
    om_error "Could not read the migration manifest back from $disk."
    return 1
  }
  USB_MANIFEST="$manifest_json"
  if ! usb_manifest_is_current "$manifest_json"; then
    om_error "The payload on the USB does not match this version of the tool."
    return 1
  fi
  om_log INFO "verified migration USB on $disk ($part)"
  return 0
}

# ---------------------------------------------------------------------------
# Reuse an already prepared stick
# ---------------------------------------------------------------------------

# Sets USB_DISK/USB_MANIFEST when a current stick is chosen.
usb_find_ready() {
  local candidates_json count selected manifest_json
  candidates_json="$(detect_existing_migration_usbs | jq -s '.')"
  count="$(jq 'length' <<<"$candidates_json")"
  ((count > 0)) || return 1

  local -a descriptions=() entries=()
  local i entry marker
  for ((i = 0; i < count; i++)); do
    entry="$(jq -c ".[$i]" <<<"$candidates_json")"
    marker="stale"
    usb_manifest_is_current "$(jq -c '.manifest' <<<"$entry")" && marker="current"
    descriptions+=("$(jq -r '"\(.disk)  version \(.manifest.version // "unknown")  \(.manifest.fingerprint // "no fingerprint")"' <<<"$entry") (${marker})")
    entries+=("$entry")
  done

  if ((count == 1)); then
    selected="0"
  else
    local chosen_line
    chosen_line="$(ui_choose "A prepared migration USB was found. Which one?" "${descriptions[@]}")" || return 1
    for i in "${!descriptions[@]}"; do
      [[ ${descriptions[i]} == "$chosen_line" ]] && selected="$i"
    done
    [[ -n $selected ]] || return 1
  fi

  entry="${entries[selected]}"
  manifest_json="$(jq -c '.manifest' <<<"$entry")"
  USB_DISK="$(jq -r '.disk' <<<"$entry")"
  USB_MANIFEST="$manifest_json"
  USB_REUSED=1

  if usb_manifest_is_current "$manifest_json"; then
    ui_note "Using the existing image on $USB_DISK (version $(jq -r '.version' <<<"$manifest_json"))."
    return 0
  fi

  ui_warn "The image on $USB_DISK was built from a different version of this tool."
  if ui_confirm "Rebuild it with the current version?" yes; then
    USB_REUSED=0
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

usb_store_metadata() {
  local disk="$1" label="$2"
  local json
  json="$(jq -n \
    --arg device "$disk" \
    --arg disk "$disk" \
    --arg serial "$(om_disk_field "$disk" SERIAL)" \
    --arg model "$(om_disk_field "$disk" MODEL)" \
    --arg size "$(detect_size_bytes "$disk")" \
    --arg iso "${USB_ISO:-}" \
    --arg label "$label" \
    --arg version "$(jq -r '.version' <<<"$USB_MANIFEST")" \
    --arg fingerprint "$(jq -r '.fingerprint' <<<"$USB_MANIFEST")" \
    --arg built_at "$(jq -r '.built_at' <<<"$USB_MANIFEST")" \
    '{device: $device, disk: $disk, serial: $serial, model: $model,
      size: ($size | tonumber? // 0), iso: $iso, label: $label,
      version: $version, fingerprint: $fingerprint, built_at: $built_at,
      efi_label: "Omarchy Migration USB"}')"
  state_set_raw '.usb' "$json"
}

# Interactive host preparation. Returns 0 when the USB is ready (whether or not
# the user chose to reboot immediately).
usb_prepare() {
  local iso_override="" device_override="" no_reboot=0 rebuild=0 timeout=180
  while (($#)); do
    case "$1" in
      --iso) iso_override="$2"; shift 2 ;;
      --device) device_override="$2"; shift 2 ;;
      --no-reboot) no_reboot=1; shift ;;
      --rebuild) rebuild=1; shift ;;
      --timeout) timeout="$2"; shift 2 ;;
      -h | --help)
        cat <<'EOF'
Usage: omarchy-migrate-drive prepare [options]

  --iso PATH        Use an already built omarchy-migrate ISO
  --device /dev/X   Preselect the USB drive
  --rebuild         Ignore a ready USB and rebuild it
  --no-reboot       Do not offer to reboot at the end
  --timeout SEC     How long to wait for a USB to be plugged in (default 180)
EOF
        return 0
        ;;
      *) om_die "Unknown prepare option: $1" ;;
    esac
  done

  om_init_runtime
  om_lock
  om_require_root
  ui_color_init

  USB_ISO=""
  USB_MANIFEST=""
  USB_REUSED=0

  ui_banner "Prepare a migration USB"
  printf '  This prepares a bootable Omarchy migration USB and records the plan on\n'
  printf '  this machine. Nothing on this machine is erased.\n'

  # 1. Source analysis (the running system).
  ui_section "Source system"
  local source_json
  source_json="$(detect_source_analysis_host)" || om_die "Could not analyse the running Omarchy system."
  printf '  %s\n' "$(jq -r '"\(.os_name) on \(.disk) · \(.used_bytes | floor / 1073741824 | floor) GiB used"' <<<"$source_json")"
  if [[ $(jq -r '.boot.loader' <<<"$source_json") != limine ]]; then
    om_warn "No /etc/default/limine found. This tool expects an Omarchy Limine system."
  fi

  # 2. Target drive. Re-ask when the chosen drive is demonstrably too small.
  local target_disk target_json plan_json
  while :; do
    if [[ -n ${OM_TARGET_DISK:-} ]]; then
      target_disk="$OM_TARGET_DISK"
    else
      target_disk="$(host_select_target "$source_json")" || return 1
    fi
    [[ -b $target_disk ]] || om_die "No such block device: $target_disk"
    [[ $target_disk != "$(jq -r '.disk' <<<"$source_json")" ]] ||
      om_die "The target cannot be the drive Omarchy is running from."

    target_json="$(detect_disk_json "$target_disk")"
    plan_json="$(plan_compute "$source_json" "$target_disk")"
    if plan_json="$(plan_confirm_fit "$plan_json")"; then
      break
    fi
    ui_warn "This target cannot hold the migration."
    [[ -n ${OM_TARGET_DISK:-} ]] && return 1
    ui_confirm "Choose a different target drive?" yes || return 1
  done

  # 3. Existing state safety.
  STATE_FILE="$(state_host_file)"
  if state_exists; then
    local old_phase
    old_phase="$(jq -r '.phase // "unknown"' "$STATE_FILE")"
    if [[ $old_phase == complete ]]; then
      ui_warn "A completed migration state already exists for this machine."
    elif [[ $old_phase == migrating || $old_phase == failed ]]; then
      ui_warn "An unfinished migration state exists ($old_phase)."
    fi
    if ! ui_confirm "Start a fresh migration plan and replace the saved state?" no; then
      ui_note "Keeping the existing state."
      return 1
    fi
  fi

  state_host_prepare
  state_init "$source_json" "$target_json" "$plan_json" "prepared"

  # 4. Reuse a ready stick unless asked to rebuild.
  local need_build=1
  if ((rebuild == 0)) && [[ -z $iso_override ]]; then
    if usb_find_ready; then
      if usb_manifest_is_current "$USB_MANIFEST"; then
        need_build=0
      else
        ui_warn "A migration USB was found, but it is from an older version of the tool."
        ui_note "Rebuilding it so the live system matches this installation."
        need_build=1
      fi
    fi
  fi

  # 5. Select/build/write.
  if ((need_build == 1)); then
    if [[ -n $device_override ]]; then
      USB_DISK="$device_override"
      [[ -b $USB_DISK ]] || om_die "No such block device: $USB_DISK"
      detect_disk_is_usb "$USB_DISK" || om_die "$USB_DISK is not a USB drive."
    else
      usb_select "$timeout" || {
        ui_note "Cancelled."
        return 1
      }
    fi
    usb_confirm_erase "$USB_DISK" || {
      ui_note "Cancelled."
      return 1
    }
    usb_unmount_disk "$USB_DISK"

    if [[ -n $iso_override ]]; then
      [[ -f $iso_override ]] || om_die "ISO not found: $iso_override"
      USB_ISO="$iso_override"
      ui_note "Using the supplied ISO: $USB_ISO"
    else
      usb_build_iso || return 1
    fi

    usb_write_iso "$USB_DISK" "$USB_ISO" || return 1
    ui_note "Verifying the written image…"
    usb_verify_written "$USB_DISK" || return 1
  fi

  USB_MANIFEST="${USB_MANIFEST:-$(usb_manifest_json)}"
  usb_store_metadata "$USB_DISK" "$MIGRATION_ISO_LABEL"
  state_set_str '.phase' "prepared"
  state_save

  ui_success_panel "USB ready" \
    "Drive:  $USB_DISK" \
    "Image:  $(jq -r '.version' <<<"$USB_MANIFEST")" \
    "Status: plan saved on $(state_get '.source.disk')" \
    "Next:   boot the USB to migrate, or run this again later to reselect it"

  if ((no_reboot == 0)); then
    if ui_confirm "Proceed with the migration now? This reboots into the USB." yes; then
      if om_is_uefi; then
        local bootnum
        bootnum="$(usb_boot_once "$USB_DISK" || true)"
        if [[ -n $bootnum ]]; then
          state_set_str '.usb.efi_bootnum' "$bootnum"
          state_save
        fi
      else
        ui_warn "This machine is not in UEFI mode. Reboot and select the USB in the firmware boot menu."
      fi
      ui_note "Rebooting…"
      sync
      sleep 1
      systemctl reboot
      return 0
    fi
    ui_note "You can start the migration later by booting the USB drive."
  fi
  return 0
}
