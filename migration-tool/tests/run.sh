#!/usr/bin/env bash
# shellcheck shell=bash
#
# Offline tests for omarchy-migrate.
#
# These tests never touch a real disk. They exercise the pure helpers, the
# state machine and the plan maths, plus static syntax checks for every script.
#
#   ./tests/run.sh
#
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export OM_ROOT="$ROOT"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/omarchy-migrate-test.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT

export OM_LOG="$TEST_TMP/test.log"
export OM_RUN_DIR="$TEST_TMP/run"
export OM_STATE_FILE="$TEST_TMP/state.json"
export NO_COLOR=1
mkdir -p -- "$OM_RUN_DIR"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '       %s\n' "$2"
}

check_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    ok "$label"
  else
    fail "$label" "expected [$expected], got [$actual]"
  fi
}

check_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ $haystack == *"$needle"* ]]; then
    ok "$label"
  else
    fail "$label" "missing [$needle] in [$haystack]"
  fi
}

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/ui.sh
source "$ROOT/lib/ui.sh"
# shellcheck source=../lib/state.sh
source "$ROOT/lib/state.sh"
# shellcheck source=../lib/detect.sh
source "$ROOT/lib/detect.sh"
# shellcheck source=../lib/boot.sh
source "$ROOT/lib/boot.sh"
# shellcheck source=../lib/menu.sh
source "$ROOT/lib/menu.sh"
# shellcheck source=../lib/migrate.sh
source "$ROOT/lib/migrate.sh"
# shellcheck source=../lib/usb.sh
source "$ROOT/lib/usb.sh"

printf '\nSyntax\n'
while IFS= read -r -d '' file; do
  if bash -n "$file" 2>"$TEST_TMP/syntax.err"; then
    ok "${file#"$ROOT/"}"
  else
    fail "${file#"$ROOT/"}" "$(head -n3 "$TEST_TMP/syntax.err")"
  fi
done < <(find "$ROOT" -type f \( -name '*.sh' -o -path "$ROOT/bin/*" -o -name 'profiledef.sh' \) -print0)

printf '\nCommon helpers\n'
check_eq "sda partition path" "/dev/sda1" "$(om_part_path /dev/sda 1)"
check_eq "nvme partition path" "/dev/nvme0n1p1" "$(om_part_path /dev/nvme0n1 1)"
check_eq "mmc partition path" "/dev/mmcblk0p2" "$(om_part_path /dev/mmcblk0 2)"
check_eq "human bytes" "1.0KiB" "$(om_human_bytes 1024)"
check_eq "uuid shape" "36" "$(om_uuid | tr -d '\n' | wc -c)"

printf '\nFirmware entry parsing\n'
line='Boot0000* Limine	HD(1,GPT,79c9cb33-94d2-4384-9488-457827cf1ebf,0x800,0x400000)/\EFI\limine\limine_x64.efi'
check_eq "entry number" "0000" "$(efi_entry_num "$line")"
check_eq "entry label" "Limine" "$(efi_entry_label "$line")"
check_eq "entry PARTUUID" "79c9cb33-94d2-4384-9488-457827cf1ebf" "$(efi_entry_partuuid "$line")"
check_eq "entry loader" '\EFI\limine\limine_x64.efi' "$(efi_entry_loader "$line")"

printf '\nState machine\n'
state_host_prepare
state_init '{"disk":"/dev/sda","serial":"S1"}' \
  '{"disk":"/dev/sdb","serial":"S2"}' \
  '{"fit":"full"}' prepared
check_eq "state exists" "1" "$([[ -f $STATE_FILE ]] && echo 1 || echo 0)"
state_jq --arg value "hello world" '.custom = $value'
check_eq "state_jq options-first" "hello world" "$(state_get '.custom')"
state_register_steps alpha beta
check_eq "first step should run" "1" "$(state_should_run alpha && echo 1 || echo 0)"
state_step_begin alpha
check_eq "running status" "running" "$(state_step_status alpha)"
state_step_done alpha
check_eq "done status" "done" "$(state_step_status alpha)"
check_eq "done step skipped" "0" "$(state_should_run alpha && echo 1 || echo 0)"
state_step_fail beta "boom"
check_eq "failed phase" "failed" "$(state_get '.phase')"
check_eq "failed step" "beta" "$(state_get '.failed_step')"
check_eq "failed step reruns" "1" "$(state_should_run beta && echo 1 || echo 0)"
state_jq '.phase = "complete"'
state_step_done beta
check_eq "complete phase is preserved" "complete" "$(state_get '.phase')"

printf '\nfstab subvolume parsing\n'
cat >"$TEST_TMP/fstab" <<'EOF'
# comment
UUID=11111111-2222-3333-4444-555555555555 / btrfs rw,noatime,compress=zstd,subvol=@ 0 0
UUID=11111111-2222-3333-4444-555555555555 /home btrfs rw,noatime,compress=zstd,subvol=@home 0 0
UUID=11111111-2222-3333-4444-555555555555 /var/log btrfs rw,noatime,compress=zstd,subvol=@log 0 0
UUID=99999999-2222-3333-4444-555555555555 /mnt/other btrfs rw,subvol=@other 0 0
/dev/sda1 /boot vfat rw,noatime 0 2
EOF
subvols="$(detect_fstab_subvolumes "$TEST_TMP/fstab" "11111111-2222-3333-4444-555555555555")"
check_eq "root subvolume first" "@|/|rw,noatime,compress=zstd,subvol=@" "$(sed -n '1p' <<<"$subvols")"
check_eq "home subvolume" "@home|/home|rw,noatime,compress=zstd,subvol=@home" "$(sed -n '2p' <<<"$subvols")"
check_eq "log subvolume" "@log|/var/log|rw,noatime,compress=zstd,subvol=@log" "$(sed -n '3p' <<<"$subvols")"
check_eq "unrelated btrfs ignored" "3" "$(wc -l <<<"$subvols")"

printf '\nPlan maths\n'
detect_size_bytes() { printf '200000000000\n'; }
source_json='{"used_bytes":10737418240,"esp":{"size":536870912},"swapfile":{"enabled":false},"subvolumes":[{"name":"@","mount":"/"}]}'
plan="$(plan_compute "$source_json" /dev/fake)"
check_eq "required bytes (10 GiB + 10%)" "11811160064" "$(jq -r '.required_bytes' <<<"$plan")"
check_eq "comfortable fit" "full" "$(jq -r '.fit' <<<"$plan")"
check_eq "esp is at least 1 GiB" "1073741824" "$(jq -r '.esp_size_bytes' <<<"$plan")"

detect_size_bytes() { printf '12000000000\n'; }
plan="$(plan_compute "$source_json" /dev/fake)"
check_eq "too small" "too_small" "$(jq -r '.fit' <<<"$plan")"

printf '\nMount options\n'
opts="$(migrate_mount_opts 'rw,noatime,compress=zstd,subvol=@,ro')"
check_eq "subvol stripped" "rw,noatime,compress=zstd" "$opts"
opts="$(migrate_mount_opts 'defaults')"
check_eq "compression added" "rw,compress=zstd:3" "$opts"

printf '\nMenu insertion\n'
menu_file="$TEST_TMP/menu.jsonc"
cat >"$menu_file" <<'EOF'
{
  // keep this comment
  "system.about": {"label":"About"}
}
EOF
menu_install_into_file "$menu_file"
menu_install_into_file "$menu_file"
check_eq "entry inserted once" "1" "$(grep -c '"system.migrate-drive"' "$menu_file")"
check_contains "comment preserved" "keep this comment" "$(cat "$menu_file")"
check_contains "previous entry got a comma" '"system.about": {"label":"About"},' "$(cat "$menu_file")"
if python3 - "$menu_file" <<'PY'
import json
import sys

text = open(sys.argv[1], encoding="utf-8").read()
lines = [line for line in text.splitlines() if not line.strip().startswith("//")]
json.loads("\n".join(lines))
PY
then
  ok "resulting file is valid JSON"
else
  fail "resulting file is valid JSON"
fi

printf '\nManifest freshness\n'
manifest="$(jq -n --arg fp "$(om_fingerprint)" '{version:"test", fingerprint:$fp}')"
if usb_manifest_is_current "$manifest"; then ok "current manifest accepted"; else fail "current manifest accepted"; fi
manifest="$(jq -n '{version:"test", fingerprint:"nope"}')"
if usb_manifest_is_current "$manifest"; then fail "stale manifest rejected"; else ok "stale manifest rejected"; fi

printf '\nSummary: %d passed, %d failed\n\n' "$PASS" "$FAIL"
((FAIL == 0))
