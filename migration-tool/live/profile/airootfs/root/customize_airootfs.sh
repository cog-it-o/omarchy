#!/usr/bin/env bash
# shellcheck shell=bash
#
# Runs inside the airootfs while mkarchiso builds the image.
set -euo pipefail

# The migration runs before tty1's getty, but getty still starts afterwards so
# a failed run leaves the user with a usable root shell.
systemctl enable omarchy-migrate-live.service
systemctl enable getty@tty1.service

# Passwordless root on a throwaway live medium. The migration itself already
# runs as root; this only makes recovery from a failed run frictionless.
passwd -d root >/dev/null 2>&1 || true

# Make the migration theme the default splash.
plymouth-set-default-theme omarchy-migrate >/dev/null 2>&1 || true

install -d -m 0700 /var/lib/omarchy-migration
chmod 0755 /usr/local/bin/omarchy-migrate-drive /usr/local/bin/omarchy-migrate-live 2>/dev/null || true

# The live medium is offline by design. Mask services that would otherwise
# wait for a network that is not there.
systemctl mask systemd-networkd-wait-online.service >/dev/null 2>&1 || true
systemctl mask NetworkManager-wait-online.service >/dev/null 2>&1 || true

exit 0
