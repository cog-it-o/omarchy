#!/usr/bin/env bash
# shellcheck shell=bash
#
# Drive, source-system and media detection.
#
# Every function that returns data writes it to stdout. Logging goes to the
# log file, never stdout, so callers can capture results safely.

: "${ESP_GUID:=c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
: "${EF_SYSTEM_BOOT_GUID:=0xef}"
: "${LUKS_FSTYPE:=crypto_LUKS}"
: "${MIGRATION_ISO_LABEL:=OMARCHY_MIGRATE}"
: "${MIGRATION_PAYLOAD_LABEL:=OMARCHY-MIGR}"

detect_disks() {
  lsblk -dpno NAME 2>/dev/null |
    sed 's/[[:space:]]*$//' |
    grep -E '^/dev/(sd|hd|vd|nvme|mmcblk|xv)' |
    grep -vE '/(loop|zram|ram|sr)[0-9]*$' ||
    true
}

detect_is_disk() {
  [[ -b $1 ]] && [[ $(lsblk -dno TYPE -- "$1" 2>/dev/null | head -n1 | tr -d '[:space:]') == disk ]]
}

detect_size_bytes() {
  lsblk -bno SIZE -- "$1" 2>/dev/null | head -n1 | tr -d '[:space:]'
}

detect_disk_is_usb() {
  local disk="$1" tran rm
  tran="$(om_disk_field "$disk" TRAN)"
  rm="$(om_disk_field "$disk" RM)"
  [[ $tran == usb || $rm == 1 ]]
}

detect_disk_is_removable() {
  [[ $(om_disk_field "$1" RM) == 1 ]]
}

detect_nodes_of_disk() {
  lsblk -nrpo NAME -- "$1" 2>/dev/null
}

detect_disk_is_mounted() {
  local disk="$1" node swap
  while IFS= read -r node; do
    [[ -n $node ]] || continue
    if findmnt -rn -S "$node" -o TARGET 2>/dev/null | grep -q .; then
      return 0
    fi
  done < <(detect_nodes_of_disk "$disk")

  while IFS= read -r swap; do
    [[ -n $swap ]] || continue
    swap="$(om_trim "$swap")"
    [[ -n $swap ]] || continue
    while IFS= read -r node; do
      [[ $node == "$swap" ]] && return 0
    done < <(detect_nodes_of_disk "$disk")
  done < <(swapon --show=NAME --noheadings 2>/dev/null)
  return 1
}

detect_mounted_nodes_of_disk() {
  local disk="$1" node
  while IFS= read -r node; do
    [[ -n $node ]] || continue
    findmnt -rn -S "$node" -o TARGET,SOURCE 2>/dev/null
  done < <(detect_nodes_of_disk "$disk")
}

detect_current_source_disk() {
  local source
  source="$(findmnt -no SOURCE / 2>/dev/null)" || return 1
  [[ -n $source ]] || return 1
  source="${source%%\[*}"
  om_parent_disk "$source"
}

detect_live_usb_disk() {
  local source
  for source in /run/archiso/bootmnt /run/archiso/img_dev; do
    if findmnt -rn -M "$source" -o SOURCE >/dev/null 2>&1; then
      source="$(findmnt -no SOURCE -M "$source")"
      om_parent_disk "$source" && return 0
    fi
  done
  # Only treat a labelled migration medium as the live disk when this
  # process is actually running from it. On an installed system a stick with
  # the same label is just a prepared (possibly stale) migration USB and must
  # remain selectable for rebuilding.
  if om_is_live; then
    source="$(blkid -L "$MIGRATION_ISO_LABEL" -o device 2>/dev/null | head -n1)"
    [[ -n $source ]] && {
      om_parent_disk "$source"
      return
    }
  fi
  return 1
}

detect_esp_partitions() {
  local disk="$1" part fstype parttype mnt
  while IFS= read -r part; do
    [[ -n $part ]] || continue
    fstype="$(om_part_field "$part" FSTYPE)"
    parttype="$(om_part_field "$part" PARTTYPE)"
    mnt="$(findmnt -rn -S "$part" -o TARGET 2>/dev/null | head -n1)"
    if [[ $fstype == vfat ]] && {
      # Match by ESP UUID or EF System Boot type (0xef hex)
      [[ ${parttype,,} == "$ESP_GUID" ]] ||
      [[ ${parttype,,} == "${EF_SYSTEM_BOOT_GUID,,}" ]] ||
      [[ $mnt == /boot || $mnt == /efi || $mnt == /boot/efi ]] ||
      [[ $(om_part_field "$part" LABEL) =~ ^(EFI|SYSTEM|ESP) ]]
    }; then
      printf '%s\n' "$part"
    fi
  done < <(om_partitions "$disk")
}

detect_luks_partitions() {
  local disk="$1" part
  while IFS= read -r part; do
    [[ -n $part ]] || continue
    [[ $(om_part_field "$part" FSTYPE) == "$LUKS_FSTYPE" ]] && printf '%s\n' "$part"
  done < <(om_partitions "$disk")
}

detect_part_json() {
  local part="$1"
  jq -n \
    --arg part "$part" \
    --arg size "$(detect_size_bytes "$part")" \
    --arg fstype "$(om_part_field "$part" FSTYPE)" \
    --arg label "$(om_part_field "$part" LABEL)" \
    --arg uuid "$(om_part_field "$part" UUID)" \
    --arg partuuid "$(om_part_field "$part" PARTUUID)" \
    --arg parttype "$(om_part_field "$part" PARTTYPE)" \
    --arg mount "$(findmnt -rn -S "$part" -o TARGET 2>/dev/null | head -n1)" \
    '{part: $part, size: ($size | tonumber? // 0), fstype: $fstype, label: $label,
      uuid: $uuid, partuuid: $partuuid, parttype: $parttype, mount: $mount}'
}

detect_disk_json() {
  local disk="$1"
  jq -n \
    --arg disk "$disk" \
    --arg size "$(detect_size_bytes "$disk")" \
    --arg model "$(om_disk_field "$disk" MODEL)" \
    --arg serial "$(om_disk_field "$disk" SERIAL)" \
    --arg tran "$(om_disk_field "$disk" TRAN)" \
    --arg rm "$(om_disk_field "$disk" RM)" \
    --arg pttype "$(om_disk_field "$disk" PTTYPE)" \
    --argjson usb "$(detect_disk_is_usb "$disk" && echo true || echo false)" \
    '{disk: $disk, size: ($size | tonumber? // 0), model: $model, serial: $serial,
      tran: $tran, removable: ($rm == "1"), usb: $usb, pttype: $pttype}'
}

detect_disk_description() {
  local disk="$1" size model serial usb
  size="$(om_human_bytes "$(detect_size_bytes "$disk")")"
  model="$(om_disk_field "$disk" MODEL)"
  serial="$(om_disk_field "$disk" SERIAL)"
  usb=""
  detect_disk_is_usb "$disk" && usb=" (USB)"
  printf '%s  %s  %s%s' "$disk" "$size" "${model:-unknown model}${serial:+ · $serial}" "$usb"
}

# Disks that look like an Omarchy source: an ESP plus a LUKS container.
detect_source_like_disks() {
  local disk live
  live="$(detect_live_usb_disk 2>/dev/null || true)"
  while IFS= read -r disk; do
    [[ -n $disk ]] || continue
    [[ -n $live && $disk == "$live" ]] && continue
    [[ -n $(detect_esp_partitions "$disk" | head -n1) ]] || continue
    [[ -n $(detect_luks_partitions "$disk" | head -n1) ]] || continue
    printf '%s\n' "$disk"
  done < <(detect_disks)
}

detect_target_candidates() {
  local disk source live
  source="$(detect_current_source_disk 2>/dev/null || true)"
  live="$(detect_live_usb_disk 2>/dev/null || true)"
  while IFS= read -r disk; do
    [[ -n $disk ]] || continue
    [[ -n $source && $disk == "$source" ]] && continue
    [[ -n $live && $disk == "$live" ]] && continue
    (($(detect_size_bytes "$disk" 2>/dev/null || echo 0) >= 2 * 1024 * 1024 * 1024)) || continue
    printf '%s\n' "$disk"
  done < <(detect_disks)
}

detect_resolve_disk() {
  local serial="$1" model="$2" size="$3" hint="${4:-}"
  local disk matches=()

  if [[ -n $hint && -b $hint ]]; then
    printf '%s\n' "$hint"
    return 0
  fi

  if [[ -n $serial ]]; then
    while IFS= read -r disk; do
      [[ $(om_disk_field "$disk" SERIAL) == "$serial" ]] && matches+=("$disk")
    done < <(detect_disks)
    ((${#matches[@]} == 1)) && {
      printf '%s\n' "${matches[0]}"
      return 0
    }
  fi

  if [[ -n $model && -n $size ]]; then
    while IFS= read -r disk; do
      [[ $(detect_size_bytes "$disk") == "$size" ]] || continue
      [[ $(om_disk_field "$disk" MODEL) == "$model" ]] && matches+=("$disk")
    done < <(detect_disks)
    ((${#matches[@]} == 1)) && {
      printf '%s\n' "${matches[0]}"
      return 0
    }
  fi

  return 1
}

detect_wait_for_usb() {
  local timeout="${1:-180}"
  local before after new
  local -i waited=0
  before="$(detect_disks | while read -r d; do detect_disk_is_usb "$d" && echo "$d"; done | sort)"
  while ((waited < timeout)); do
    sleep 1
    waited+=1
    after="$(detect_disks | while read -r d; do detect_disk_is_usb "$d" && echo "$d"; done | sort)"
    new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')"
    if [[ -n $new ]]; then
      printf '%s\n' "$new"
      return 0
    fi
    if ((waited % 5 == 0)); then
      printf 'Waiting for a USB drive… %ss\r' "$waited" >&2
    fi
  done
  printf '\n' >&2
  return 1
}

# ---------------------------------------------------------------------------
# Source analysis
# ---------------------------------------------------------------------------

# Parse the btrfs subvolume mounts from an fstab file. Filters by the root
# filesystem UUID when one is supplied so unrelated btrfs disks are ignored.
# Output: subvol|mountpoint|options (root first).
detect_fstab_subvolumes() {
  local fstab="$1" root_uuid="${2:-}" spec mnt fstype opts dump pass subvol root_line="" lines=()
  [[ -r $fstab ]] || return 1

  while read -r spec mnt fstype opts dump pass; do
    [[ -n ${spec:-} ]] || continue
    [[ $spec == \#* ]] && continue
    [[ $fstype == btrfs ]] || continue
    if [[ -n $root_uuid ]]; then
      [[ $spec == *"$root_uuid"* || $spec == /dev/mapper/* || $spec == /dev/dm-* ]] || continue
    fi
    subvol=""
    local -a optarr=()
    IFS=, read -ra optarr <<<"$opts"
    local opt
    for opt in "${optarr[@]}"; do
      case "$opt" in
        subvol=*) subvol="${opt#subvol=}" ;;
        subvolid=*) [[ $opt == subvolid=5 ]] && subvol="__TOPLEVEL__" ;;
      esac
    done
    subvol="${subvol#/}"
    [[ -n $subvol ]] || subvol="__DEFAULT__"
    lines+=("$subvol|$mnt|$opts")
    [[ $mnt == / ]] && root_line="$subvol|$mnt|$opts"
  done <"$fstab"

  [[ -n $root_line ]] && printf '%s\n' "$root_line"
  local line
  for line in "${lines[@]}"; do
    [[ $line == "$root_line" ]] && continue
    printf '%s\n' "$line"
  done
}

detect_used_bytes() {
  local root="$1"
  df -B1 --output=used "$root" 2>/dev/null | tail -n1 | tr -d '[:space:]'
}

detect_root_subvol() {
  local mount="$1"
  findmnt -no OPTIONS -M "$mount" 2>/dev/null |
    tr ',' '\n' | sed -n 's/^subvol=//p' | sed 's#^/##' | head -n1
}

detect_swapfile_json() {
  local root="$1"
  local fstab="$root/etc/fstab"
  local spec mnt fstype opts dump pass path="" size=0 offset=""
  [[ -r $fstab ]] || {
    jq -n '{enabled: false}'
    return
  }
  while read -r spec mnt fstype opts dump pass; do
    [[ $spec == \#* ]] && continue
    [[ $fstype == swap ]] || continue
    case "$spec" in
      /dev/* | UUID=* | LABEL=* | PARTUUID=* | /dev/mapper/*) continue ;;
    esac
    path="$spec"
    break
  done <"$fstab"

  if [[ -n $path ]]; then
    [[ -f "$root$path" ]] && size="$(stat -c %s "$root$path" 2>/dev/null || echo 0)"
    offset="$(btrfs inspect-internal map-swapfile -r "$root$path" 2>/dev/null || true)"
  fi

  jq -n --arg path "$path" --arg size "$size" --arg offset "$offset" \
    '{enabled: ($path != ""), path: $path, size: ($size | tonumber? // 0), offset: $offset}'
}

# Analyse the currently running system. No unlock needed: this runs on the
# source system with /, /boot and the mapper already active.
detect_source_analysis_host() {
  local disk esp luks root_source root_parent root_uuid root_subvol root_opts
  local fstab model serial size loader uefi mapped

  disk="$(detect_current_source_disk)" || return 1
  esp="$(detect_esp_partitions "$disk" | head -n1)"

  root_source="$(findmnt -no SOURCE /)"
  root_source="${root_source%%\[*}"
  root_parent="$(om_parent_disk "$root_source" 2>/dev/null || true)"
  luks=""
  if [[ $(om_part_field "$root_source" FSTYPE 2>/dev/null) == "$LUKS_FSTYPE" ]]; then
    luks="$root_source"
  elif [[ -n $root_parent && $(om_parent_disk "$root_parent" 2>/dev/null) == "$disk" ]]; then
    # /dev/mapper/root -> /dev/sda2
    [[ $(om_part_field "$root_parent" FSTYPE) == "$LUKS_FSTYPE" ]] && luks="$root_parent"
  fi
  if [[ -z $luks ]]; then
    luks="$(detect_luks_partitions "$disk" | head -n1)"
  fi

  root_uuid="$(findmnt -no UUID / 2>/dev/null || true)"
  root_subvol="$(detect_root_subvol /)"
  root_opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
  fstab="/etc/fstab"
  loader=""
  [[ -f /etc/default/limine ]] && loader="limine"
  uefi=false
  om_is_uefi && uefi=true

  local esp_json luks_json
  if [[ -n $esp ]]; then esp_json="$(detect_part_json "$esp")"; else esp_json="null"; fi
  if [[ -n $luks ]]; then luks_json="$(detect_part_json "$luks")"; else luks_json="null"; fi

  local subvols_json
  subvols_json="$(detect_fstab_subvolumes "$fstab" "$root_uuid" |
    while IFS='|' read -r sv mnt opts; do
      [[ -n $sv ]] || continue
      jq -n --arg name "$sv" --arg mount "$mnt" --arg options "$opts" \
        '{name: $name, mount: $mount, options: $options}'
    done | jq -s .)"

  jq -n \
    --arg disk "$disk" \
    --arg size "$(detect_size_bytes "$disk")" \
    --arg model "$(om_disk_field "$disk" MODEL)" \
    --arg serial "$(om_disk_field "$disk" SERIAL)" \
    --arg root_uuid "$root_uuid" \
    --arg root_subvol "$root_subvol" \
    --arg root_opts "$root_opts" \
    --arg root_source "$root_source" \
    --arg used "$(detect_used_bytes /)" \
    --arg loader "$loader" \
    --argjson uefi "$uefi" \
    --argjson esp "$esp_json" \
    --argjson luks "$luks_json" \
    --argjson subvolumes "$subvols_json" \
    --argjson swapfile "$(detect_swapfile_json /)" \
    --arg machine_id "$(cat /etc/machine-id 2>/dev/null || true)" \
    --arg os_name "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-Omarchy}")" \
    '{
      disk: $disk,
      size: ($size | tonumber? // 0),
      model: $model,
      serial: $serial,
      root: {uuid: $root_uuid, subvol: $root_subvol, options: $root_opts, source: $root_source},
      used_bytes: ($used | tonumber? // 0),
      esp: $esp,
      luks: $luks,
      subvolumes: $subvolumes,
      swapfile: $swapfile,
      boot: {loader: $loader, uefi: $uefi},
      machine_id: $machine_id,
      os_name: $os_name
    }'
}

# Analyse an unlocked source mounted at the btrfs top level.
# Arguments: source top mount, root subvolume name.
detect_source_analysis_mounted() {
  local top="$1" root_subvol="$2"
  local root="$top/$root_subvol"
  local fstab="$root/etc/fstab"
  local root_uuid root_opts subvols_json loader uefi

  [[ -d $root ]] || return 1
  root_uuid="$(blkid -s UUID -o value "$(findmnt -no SOURCE "$root" 2>/dev/null)" 2>/dev/null || true)"
  # The fs UUID is the same for the top-level mount; take it from there.
  root_uuid="$(blkid -s UUID -o value "$(findmnt -no SOURCE "$top")" 2>/dev/null || true)"
  root_opts="$(findmnt -no OPTIONS -M "$root" 2>/dev/null || true)"
  loader=""
  [[ -f "$root/etc/default/limine" ]] && loader="limine"
  uefi=false
  om_is_uefi && uefi=true

  subvols_json="$(detect_fstab_subvolumes "$fstab" "$root_uuid" |
    while IFS='|' read -r sv mnt opts; do
      [[ -n $sv ]] || continue
      jq -n --arg name "$sv" --arg mount "$mnt" --arg options "$opts" \
        '{name: $name, mount: $mount, options: $options}'
    done | jq -s .)"

  # Fall back to the live mount table when fstab has no btrfs root entry.
  if [[ $(jq 'length' <<<"$subvols_json") == 0 ]]; then
    subvols_json="$(jq -n --arg name "$root_subvol" --arg mount "/" --arg options "" \
      '[{name: $name, mount: $mount, options: $options}]')"
  fi

  jq -n \
    --arg root_uuid "$root_uuid" \
    --arg root_subvol "$root_subvol" \
    --arg root_opts "$root_opts" \
    --arg used "$(detect_used_bytes "$top")" \
    --arg loader "$loader" \
    --argjson uefi "$uefi" \
    --argjson subvolumes "$subvols_json" \
    --argjson swapfile "$(detect_swapfile_json "$root")" \
    --arg machine_id "$(cat "$root/etc/machine-id" 2>/dev/null || true)" \
    --arg os_name "$(. "$root/etc/os-release" 2>/dev/null && printf '%s' "${PRETTY_NAME:-Omarchy}")" \
    '{
      root: {uuid: $root_uuid, subvol: $root_subvol, options: $root_opts},
      used_bytes: ($used | tonumber? // 0),
      subvolumes: $subvolumes,
      swapfile: $swapfile,
      boot: {loader: $loader, uefi: $uefi},
      machine_id: $machine_id,
      os_name: $os_name
    }'
}

# ---------------------------------------------------------------------------
# Media containing state or a ready migration payload
# ---------------------------------------------------------------------------

# Read our manifest out of an archiso ISO partition. Prints the JSON or nothing.
_detect_iso_manifest() {
  local part="$1"
  (
    local iso_mnt sq_mnt sfs manifest
    iso_mnt="$(mktemp -d "${OM_RUN_DIR:-/tmp}/iso.XXXXXX")" || exit 1
    sq_mnt="$(mktemp -d "${OM_RUN_DIR:-/tmp}/squash.XXXXXX")" || {
      rmdir "$iso_mnt"
      exit 1
    }
    cleanup_iso() {
      mountpoint -q "$sq_mnt" && umount "$sq_mnt" >/dev/null 2>&1
      mountpoint -q "$iso_mnt" && umount "$iso_mnt" >/dev/null 2>&1
      rmdir "$sq_mnt" "$iso_mnt" 2>/dev/null
    }
    trap cleanup_iso EXIT

    mount -o ro "$part" "$iso_mnt" >/dev/null 2>&1 || exit 1
    sfs="$(find "$iso_mnt" -maxdepth 4 \( -name 'airootfs.sfs' -o -name 'airootfs.erofs' \) -print -quit 2>/dev/null)"
    [[ -n $sfs ]] || exit 1
    mount -o loop,ro "$sfs" "$sq_mnt" >/dev/null 2>&1 || exit 1
    manifest="$sq_mnt/usr/local/share/omarchy-migrate/manifest.json"
    [[ -r $manifest ]] || exit 1
    jq -c . "$manifest" 2>/dev/null
  )
}

_detect_payload_manifest() {
  local part="$1"
  (
    local mnt manifest
    mnt="$(mktemp -d "${OM_RUN_DIR:-/tmp}/payload.XXXXXX")" || exit 1
    cleanup_payload() {
      mountpoint -q "$mnt" && umount "$mnt" >/dev/null 2>&1
      rmdir "$mnt" 2>/dev/null
    }
    trap cleanup_payload EXIT
    mount -o ro "$part" "$mnt" >/dev/null 2>&1 || exit 1
    manifest="$mnt/omarchy-migrate/manifest.json"
    [[ -r $manifest ]] || exit 1
    jq -c . "$manifest" 2>/dev/null
  )
}

# Scan every USB disk for a migration ISO or payload partition.
detect_existing_migration_usbs() {
  local disk part label fstype manifest_json
  while IFS= read -r disk; do
    [[ -n $disk ]] || continue
    detect_disk_is_usb "$disk" || continue
    while IFS= read -r part; do
      [[ -n $part ]] || continue
      label="$(om_part_field "$part" LABEL)"
      fstype="$(om_part_field "$part" FSTYPE)"
      manifest_json=""

      if [[ $fstype == iso9660 && ( $label == "$MIGRATION_ISO_LABEL" || $label == "$MIGRATION_ISO_LABEL"_* ) ]]; then
        manifest_json="$(_detect_iso_manifest "$part" 2>/dev/null || true)"
      elif [[ $label == "$MIGRATION_PAYLOAD_LABEL" ]]; then
        manifest_json="$(_detect_payload_manifest "$part" 2>/dev/null || true)"
      fi

      if [[ -n $manifest_json ]]; then
        jq -n \
          --arg disk "$disk" \
          --arg part "$part" \
          --arg size "$(detect_size_bytes "$disk")" \
          --arg model "$(om_disk_field "$disk" MODEL)" \
          --arg serial "$(om_disk_field "$disk" SERIAL)" \
          --argjson manifest "$manifest_json" \
          '{disk: $disk, part: $part, size: ($size | tonumber? // 0), model: $model,
            serial: $serial, manifest: $manifest}'
      fi
    done < <(om_partitions "$disk")
  done < <(detect_disks)
}

# Find ESPs that carry an omarchy-migration state file. Prints one JSON object
# per ESP. Used by the live tool before the source is unlocked.
detect_state_esps() {
  local disk part mnt state_json live
  live="$(detect_live_usb_disk 2>/dev/null || true)"
  while IFS= read -r disk; do
    [[ -n $disk ]] || continue
    [[ -n $live && $disk == "$live" ]] && continue
    while IFS= read -r part; do
      [[ -n $part ]] || continue
      mnt="$(mktemp -d "${OM_RUN_DIR:-/tmp}/esp.XXXXXX")" || continue
      if mount -o ro "$part" "$mnt" >/dev/null 2>&1; then
        if [[ -r "$mnt/omarchy-migration/state.json" ]]; then
          state_json="$(jq -c . "$mnt/omarchy-migration/state.json" 2>/dev/null || true)"
          if [[ -n $state_json ]]; then
            jq -n \
              --arg disk "$disk" \
              --arg part "$part" \
              --argjson state "$state_json" \
              '{disk: $disk, part: $part, state: $state}'
          fi
        fi
        umount "$mnt" >/dev/null 2>&1 || true
      fi
      rmdir "$mnt" 2>/dev/null || true
    done < <(detect_esp_partitions "$disk")
  done < <(detect_disks)
}
