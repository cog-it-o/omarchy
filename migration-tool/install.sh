#!/usr/bin/env bash
# shellcheck shell=bash
#
# Install omarchy-migrate on an Omarchy system.
#
#   sudo ./install.sh              system install + menu entry for every user
#   ./install.sh --menu-only       add the menu entry for the current user only
#   sudo ./install.sh --uninstall  remove the system install and menu entries
#
set -uo pipefail

_self="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
OM_ROOT="$(cd -- "$(dirname -- "$_self")" && pwd)"
export OM_ROOT

LIB_DIR="/usr/local/lib/omarchy-migrate"
BIN_DIR="/usr/local/bin"
UNIT_DIR="/etc/systemd/system"
UNIT="omarchy-migrate-finalize.service"

MODE=install
MENU_ONLY=0
NO_MENU=0

orig_args=("$@")

usage() {
  cat <<'EOF'
Usage: install.sh [OPTIONS]

  --menu-only    Only add the Omarchy menu entry for the current user.
  --no-menu      Install the tool and service, but do not touch menu files.
  --uninstall    Remove the installed tool, service and menu entries.
  -h, --help     Show this help.
EOF
}

while (($#)); do
  case "$1" in
    --menu-only) MENU_ONLY=1 ;;
    --no-menu) NO_MENU=1 ;;
    --uninstall) MODE=uninstall ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ((MENU_ONLY == 0)) && [[ $EUID -ne 0 ]]; then
  exec sudo -E -- "$_self" "${orig_args[@]}"
fi

# shellcheck source=lib/common.sh
source "$OM_ROOT/lib/common.sh"
# shellcheck source=lib/menu.sh
source "$OM_ROOT/lib/menu.sh"
export OM_LOG="${OM_LOG:-/var/log/omarchy-migrate-install.log}"
touch -- "$OM_LOG" 2>/dev/null || OM_LOG="${TMPDIR:-/tmp}/omarchy-migrate-install.log"

menu_for_current_user() {
  local file="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  install -d -- "$(dirname -- "$file")"
  if menu_install_into_file "$file"; then
    printf '  Added "Migrate Omarchy" to %s\n' "$file"
  else
    printf '  Could not update %s. See menu/omarchy-menu.jsonc.\n' "$file" >&2
  fi
}

menu_for_all_users() {
  local count
  count="$(menu_install_for_users "" 2>/dev/null)"
  printf '  Added the menu entry for %s user(s).\n' "${count:-0}"
}

remove_menu_lines() {
  local file
  for file in /home/*/.config/omarchy/extensions/omarchy-menu.jsonc \
    /root/.config/omarchy/extensions/omarchy-menu.jsonc; do
    [[ -f $file ]] || continue
    python3 - "$file" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

out = [line for line in lines if '"system.migrate-drive"' not in line]
# A trailing comma may now dangle before the closing brace.
for i in range(len(out) - 1, -1, -1):
    if out[i].strip() == "}":
        for j in range(i - 1, -1, -1):
            stripped = out[j].strip()
            if not stripped or stripped.startswith("//"):
                continue
            if stripped.endswith(",") and not stripped.endswith("{,"):
                out[j] = out[j].rstrip().rstrip(",") + "\n"
            break
        break

with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(out)
PY
    printf '  Removed the menu entry from %s\n' "$file"
  done
}

check_deps() {
  local missing=() cmd
  for cmd in mkarchiso mksquashfs xorriso mkfs.fat mcopy gum jq python3 \
    cryptsetup btrfs parted sgdisk rsync efibootmgr limine-install; do
    command -v -- "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    printf '\n  Optional build/runtime commands not found: %s\n' "${missing[*]}"
    printf '  Install the build tools with:\n'
    printf '    sudo pacman -S --needed archiso squashfs-tools libisoburn mtools dosfstools gptfdisk\n'
    printf '  The migration itself only needs the tools already present on Omarchy.\n\n'
  fi
}

install_system() {
  printf 'Installing omarchy-migrate %s\n' "$OM_VERSION"

  install -d -m 0755 -- "$LIB_DIR" "$BIN_DIR"
  rm -rf -- "$LIB_DIR/bin" "$LIB_DIR/lib" "$LIB_DIR/live" \
    "$LIB_DIR/menu" "$LIB_DIR/systemd"
  cp -a -- "$OM_ROOT/bin" "$OM_ROOT/lib" "$OM_ROOT/live" \
    "$OM_ROOT/menu" "$OM_ROOT/systemd" "$LIB_DIR/"
  install -m 0644 -- "$OM_ROOT/VERSION" "$LIB_DIR/VERSION"
  [[ -f $OM_ROOT/README.md ]] && install -m 0644 -- "$OM_ROOT/README.md" "$LIB_DIR/README.md"
  [[ -f $OM_ROOT/LICENSE ]] && install -m 0644 -- "$OM_ROOT/LICENSE" "$LIB_DIR/LICENSE"

  chmod 0755 -- "$LIB_DIR/bin/omarchy-migrate-drive" "$LIB_DIR/bin/omarchy-migrate-live"
  chmod 0755 -- "$LIB_DIR/live/profile/profiledef.sh"
  chmod 0755 -- "$LIB_DIR/live/profile/airootfs/root/customize_airootfs.sh"

  ln -sfn -- "$LIB_DIR/bin/omarchy-migrate-drive" "$BIN_DIR/omarchy-migrate-drive"
  ln -sfn -- "$LIB_DIR/bin/omarchy-migrate-live" "$BIN_DIR/omarchy-migrate-live"

  install -m 0644 -- "$OM_ROOT/systemd/$UNIT" "$UNIT_DIR/$UNIT"
  systemctl daemon-reload
  systemctl enable "$UNIT" >/dev/null

  printf '  Installed to %s\n' "$LIB_DIR"
  printf '  Installed %s and %s\n' "$BIN_DIR/omarchy-migrate-drive" "$UNIT_DIR/$UNIT"
}

uninstall_system() {
  printf 'Removing omarchy-migrate\n'
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_DIR/$UNIT"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f -- "$BIN_DIR/omarchy-migrate-drive" "$BIN_DIR/omarchy-migrate-live"
  rm -rf -- "$LIB_DIR"
  if ((NO_MENU == 0)); then
    remove_menu_lines
  fi
  printf '  Removed.\n'
}

if ((MENU_ONLY == 1)); then
  menu_for_current_user
  exit 0
fi

if [[ $MODE == uninstall ]]; then
  uninstall_system
  exit 0
fi

install_system
if ((NO_MENU == 0)); then
  menu_for_all_users
fi
check_deps

cat <<'EOF'

Done. Open the Omarchy menu and choose "Migrate Omarchy", or run:

  omarchy-migrate-drive

The tool will ask you to plug in a USB stick, erase it, write the migration
image, and record the plan on this machine. Boot the stick to perform the
actual copy; this drive is only read from.
EOF
