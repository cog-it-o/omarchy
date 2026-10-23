#!/usr/bin/env bash
# shellcheck shell=bash
#
# archiso profile for the Omarchy drive-migration medium.
#
# This is intentionally small: it boots straight into omarchy-migrate-live on
# tty1, shows the Omarchy Plymouth splash during boot, and contains everything
# needed to copy a LUKS/btrfs Omarchy installation to another drive offline.

iso_name="omarchy-migrate"
iso_label="OMARCHY_MIGRATE"
iso_publisher="Omarchy"
iso_application="Omarchy drive migration"
iso_version="0.1.0"
install_dir="arch"
buildmodes=('iso')
bootmodes=(
  'bios.syslinux'
  'uefi.systemd-boot'
)
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/etc/group"]="0:0:644"
  ["/etc/passwd"]="0:0:644"
  ["/root"]="0:0:750"
  ["/usr/local/bin/omarchy-migrate-drive"]="0:0:755"
  ["/usr/local/bin/omarchy-migrate-live"]="0:0:755"
  ["/usr/local/lib/omarchy-migrate"]="0:0:755"
)
