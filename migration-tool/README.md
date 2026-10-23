# Omarchy Migrate

Move an existing Omarchy installation to another drive without reinstalling.

`omarchy-migrate-drive` prepares a bootable USB from your running system, then
the USB boots into a small Arch-based live environment that copies the source
to the new drive. The source installation is never copied while it is in use.
Progress is stored on the source drive, not on the USB, so a failed run can
resume after a reboot even if the stick is lost or rewritten.

> **Status: 0.1.0 (v0.1).** Supported source layout: UEFI, LUKS2 + btrfs,
> Limine, and the standard Omarchy subvolumes (`@`, `@home`, `@pkg`, `@log`).
> Read [Limitations](#limitations) before using this on a production machine.

---

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Prepare the USB (host)](#prepare-the-usb-host)
- [Run the migration (live USB)](#run-the-migration-live-usb)
- [What gets copied](#what-gets-copied)
- [State and resume](#state-and-resume)
- [Backups](#backups)
- [First boot and finalize](#first-boot-and-finalize)
- [Command reference](#command-reference)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Limitations](#limitations)

---

## How it works

1. **Host planning.** On the installed system, the tool analyses the running
   installation (disk, ESP, LUKS container, btrfs subvolumes, used space,
   swapfile) and asks for the target drive and a new encryption passphrase.
   The plan is a snapshot taken at preparation time; data added afterwards is
   not accounted for.
2. **USB image.** It builds a custom archiso image containing the migration
   tool, a Plymouth splash, and a seed plan, then writes it to a USB stick with
   `dd`.
3. **Live migration.** Booting the USB auto-starts `omarchy-migrate-live` on
   tty1. It finds the source by disk serial, unlocks it read-only, repartitions
   and encrypts the target (after explicit confirmation), copies the
   subvolumes, regenerates boot artifacts in a chroot, verifies the result, and
   records completion on both drives.
4. **Finalize.** The target is set first in the firmware boot order. On the
   first boot from the new drive, a one-shot systemd unit removes the old
   source/USB firmware entries and clears the source resume state.

The actual copy is `rsync` from a read-only source mount to the target. The
source's LUKS container is unlocked and its btrfs subvolumes are mounted
read-only. The only writes to the old drive are the state file and backup
directory on its EFI system partition.

## Requirements

**Source system**

- Omarchy on UEFI firmware with Limine.
- LUKS2 full-disk encryption around btrfs. Unencrypted sources are rejected in
  v0.1.
- btrfs subvolumes. Nesting and Snapper are supported; snapshots are not
  copied.
- An EFI system partition mounted at `/boot` with at least a few hundred MiB
  free for state and backups.
- `limine`, `limine-install`, `mkinitcpio`, `cryptsetup`, `btrfs-progs`,
  `rsync`, `sgdisk`/`parted`, `efibootmgr`, and the usual Omarchy base system.

**Host build tools** (install these once):

```bash
sudo pacman -S --needed archiso squashfs-tools libisoburn mtools dosfstools gptfdisk
```

`install.sh` warns about missing build tools but does not install packages for
you.

**Target drive**

- At least as large as the source's used data plus 10%, the new ESP, and LUKS
  overhead. The tool computes the exact requirement before building the USB.
- Every partition on it is destroyed. You must type `ERASE` to confirm.

## Install

From this directory:

```bash
sudo ./install.sh
```

This installs:

- libraries and scripts under `/usr/local/lib/omarchy-migrate/`;
- `/usr/local/bin/omarchy-migrate-drive` and
  `/usr/local/bin/omarchy-migrate-live`;
- the first-boot service
  `/etc/systemd/system/omarchy-migrate-finalize.service`;
- a **Migrate Omarchy** entry in each user's
  `~/.config/omarchy/extensions/omarchy-menu.jsonc`.

The menu entry uses Omarchy's floating terminal:

```text
omarchy-launch-floating-terminal-with-presentation omarchy-migrate-drive
```

Other install modes:

```bash
./install.sh --menu-only    # add the menu entry for the current user only
sudo ./install.sh --no-menu # install binaries/service, leave menus alone
sudo ./install.sh --uninstall
```

You can also run the tool directly without the menu:

```bash
omarchy-migrate-drive
```

## Prepare the USB (host)

Run `omarchy-migrate-drive` and choose **Prepare a migration USB**, or run:

```bash
sudo omarchy-migrate-drive prepare
```

The host flow:

1. **Pick the target drive.** The source and the live USB are hidden from the
   list. The plan is checked for fit; if the drive is too small, the tool offers
   common cache/game/Trash/Downloads exclusions. You can decline and pick a
   larger drive.
2. **Choose the new LUKS passphrase.** It is used only for the target and is
   never written to disk. Use at least 8 characters.
3. **Plug in a USB stick.** The tool polls for hot-plug (default 180 seconds),
   shows the stick's model/size/serial, and asks you to confirm it. A stick can
   be preselected:

   ```bash
   sudo omarchy-migrate-drive prepare --device /dev/sdX
   ```

4. **Confirm erasure.** The stick is wiped and the ISO is written. This is the
   only destructive host step.
5. **Write and verify.** After `dd`, the tool verifies the ISO label and reads
   the embedded manifest back from the stick. A stale image is detected by
   fingerprint.
6. **Arm the boot order.** A temporary UEFI entry for the stick is created and
   selected with `BootNext`, so the next reboot enters the migration medium.
7. **Reboot.** The tool offers an immediate reboot.

A current prepared stick can be reused instead of rebuilding. Use `--rebuild`
to force a new image. `--no-reboot` suppresses the final reboot prompt.

Advanced options:

```bash
sudo omarchy-migrate-drive prepare --iso /path/to/omarchy-migrate.iso
sudo omarchy-migrate-drive prepare --timeout 600
```

`--iso` uses an already-built image; the manifest is still verified, and the
live payload must match the host version.

### What is on the stick

- Archiso live system with the migration tool and its libraries.
- A seed plan (`/usr/local/share/omarchy-migrate/seed-plan.json`) containing
  the source analysis, target identity and chosen target disk.
- Omarchy-themed Plymouth splash: the Omarchy logo with a smaller
  “Migration tool” line.
- A systemd unit that starts the migration on tty1 before getty, then leaves a
  root shell available if the run fails.
- The stick holds **no authoritative progress**. State is always read from the
  source ESP (or a target copy after completion).

## Run the migration (live USB)

Boot the stick. The splash is shown while the live system starts. On tty1 the
migration begins automatically and is hands-free except for:

- confirming a resume (when a previous attempt stopped);
- the target LUKS passphrase (typed twice, only on the first attempt);
- the explicit `ERASE` confirmation.

The live flow:

1. Find the migration state on the source ESP, or fall back to the seed plan on
   the USB.
2. Resolve the source and target by serial number/PARTUUID, so device names can
   change across reboots.
3. Unlock the source LUKS container and mount it read-only.
4. Partition the target: GPT, FAT32 ESP, LUKS2 root. The target is always
   repartitioned; on resume, completed destructive steps are not repeated.
5. Create btrfs subvolumes matching the source and mount the target tree.
6. Write a pre-migration backup, then copy each subvolume with `rsync`.
7. Regenerate `/etc/fstab`, kernel cmdline, crypttab, swapfile, initramfs, UKIs
   and the Limine configuration from inside the target.
8. Install/register Limine and a firmware entry for the new ESP, set the new
   drive first in the boot order, and select it with `BootNext`.
9. Verify the copied system and write completion state to the target.
10. Offer to reboot immediately.

Verbose command output is logged to `/var/log/omarchy-migrate.log` on the live
system (and to a per-run log on the host). The screen shows only step progress
and errors.

If a step fails, the tool stops immediately, records the failed step, and does
not retry in a loop. Press Enter to open a root shell for inspection, or reboot
and let the same USB resume. If you run `omarchy-migrate-live` manually,
`status` shows the saved state and `shell` opens a root shell.

## What gets copied

- Every btrfs subvolume listed in the source `/etc/fstab` whose UUID matches
  the source root filesystem, including `@`, `@home`, `@pkg`, `@log`.
- The source EFI system partition's `EFI/BOOT`, `EFI/limine`, `loader` and
  `limine.conf` (minus the generated UKIs and Limine binary, which are
  regenerated).

What is **not** copied:

- Snapper snapshots and nested btrfs subvolumes (for example
  `/.snapshots`, `~/.snapshots`).
- `/proc`, `/sys`, `/dev`, `/run`.
- The source ESP's `EFI/Linux` UKIs and `EFI/limine` binary, which are rebuilt
  for the new disk.
- `/var/lib/omarchy-migration` (the target's own state directory).
- On resume, no completed step is repeated. The copy step itself is
  idempotent: it uses `rsync --delete` against a freshly mounted target.

The target gets a **new** btrfs UUID, LUKS UUID, and PARTUUIDs. All references
in `/etc/fstab`, `/etc/crypttab`, `/etc/kernel/cmdline` and
`/etc/default/limine` are rewritten before the initramfs and bootloader are
generated.

## State and resume

Authoritative state:

```text
<source ESP>/omarchy-migration/state.json
```

Fallback (when the source has no writable ESP):

```text
<source root>/var/lib/omarchy-migration/state.json
```

On completion the state is mirrored to:

```text
<target root>/var/lib/omarchy-migration/state.json
```

The state file records:

- schema/version and run ID;
- source and target disk identity (serial, size, partitions, PARTUUIDs);
- LUKS and btrfs UUIDs;
- the plan (used bytes, required bytes, ESP size, fit, exclusions, swapfile);
- an ordered list of steps and each step's status, attempts and error;
- firmware/USB metadata needed for cleanup;
- backup location and completion timestamps.

Every step is marked `running` before it starts and `done` or `failed` after
it finishes. On the next run:

- `done` and `skipped` steps are not repeated;
- `failed`, `running` and `pending` steps run again;
- destructive steps (`partition`, `luks`, `filesystems`) are skipped only if
  they are already done; otherwise the target is repartitioned;
- the ephemeral setup (unlock, mounts) is recreated by
  `migrate_prepare_target_for_resume`.

State lives on the source, so rebuilding or losing the USB does not lose
progress. Prepare a new stick and boot it; it reads the same state.

## Backups

Before the target is touched, the live system writes a best-effort backup set
to `<source ESP>/omarchy-migration/backup/` (or
`/var/lib/omarchy-migration/backup/` when there is no ESP):

| File | Contents |
| --- | --- |
| `source-gpt.bin` | `sgdisk --backup` binary partition table backup |
| `source-gpt.txt` | Human-readable `sfdisk -d` partition dump |
| `source-luks-header.img` | LUKS2 header backup (`luksHeaderBackup`) |
| `source-boot-config.tar.gz` | `/etc/fstab`, crypttab, kernel cmdline, Limine and mkinitcpio config |
| `source-esp-boot.tar.gz` | ESP `EFI/Linux`, `EFI/limine`, `EFI/BOOT`, `loader`, `limine.conf` |
| `SHA256SUMS` | Checksums of the files above |

A backup failure is logged as a warning and does not stop the migration,
because the copy itself does not depend on these files. The LUKS header is the
one artifact that cannot be reconstructed from a successful copy; keep the
backup somewhere safe if the old drive will be reused or wiped later.

The backup directory contains key material (the LUKS header) and is created
with mode `0700`; the header file is mode `0600`. Do not copy it to untrusted
media.

## First boot and finalize

The last migration step sets the new ESP's Limine entry first and selects it
with `BootNext`. Reboot into the new drive.

On first boot, `omarchy-migrate-finalize.service` runs
`omarchy-migrate-drive finalize`, which:

- checks the target state and that it is running on the migrated system;
- refreshes the firmware entry for the new ESP if needed;
- puts the new drive first again;
- deletes stale source and migration-USB firmware entries;
- clears the source ESP's resume state when the old drive is still connected;
- sends an Omarchy notification (when a notification daemon is available);
- marks `.pending_finalize = false`.

The unit is enabled in the target. It is a one-shot, `Type=oneshot` service and
exits successfully even if individual cleanup actions are not possible.

## Command reference

### Host: `omarchy-migrate-drive`

```text
omarchy-migrate-drive                 interactive menu
omarchy-migrate-drive prepare         plan, build/write/verify the USB
omarchy-migrate-drive status          show the saved state
omarchy-migrate-drive verify          verify the prepared USB against the plan
omarchy-migrate-drive migrate         explain the live step (does not migrate)
omarchy-migrate-drive finalize        finish cleanup after first boot
omarchy-migrate-drive version
```

`prepare` options: `--iso PATH`, `--device /dev/X`, `--rebuild`,
`--no-reboot`, `--timeout SEC`.

### Live: `omarchy-migrate-live`

```text
omarchy-migrate-live                  start or resume (default)
omarchy-migrate-live migrate          same as above
omarchy-migrate-live status           show state found on connected drives
omarchy-migrate-live finalize         finish from the target
omarchy-migrate-live shell            root shell
```

### Environment variables

| Variable | Meaning |
| --- | --- |
| `OM_LOG` | Log file path (default `/var/log/omarchy-migrate.log` as root) |
| `OM_STATE_FILE` | Override the state path (host-side testing) |
| `OM_DEBUG=1` | Also print debug lines to stderr |
| `OM_ASSUME_YES=1` | Skip the `ERASE` confirmation (tests/automation only) |
| `OM_FORCE_STEP=all` | Re-run even completed steps (dangerous; debugging only) |
| `OM_LIVE=1` | Mark the process as running from the live medium |

## Troubleshooting

**The USB is not offered in the picker.**
It must be a USB-attached whole disk, not the source disk and not the live
disk. Check `lsblk -o NAME,SIZE,MODEL,TRAN,RM`. Some USB bridges report
`TRAN=usb` only after the stick settles.

**“The target is too small.”**
Pick a larger drive, or accept the offered exclusions on the live side. The
plan requires used data + 10%, the ESP (minimum 1 GiB, maximum 4 GiB), and
64 MiB of LUKS overhead.

**The migration failed at a step.**
The event and log path are shown. Read `/var/log/omarchy-migrate.log` on the
live system. The source state records `failed_step` and the error. Booting the
same USB again resumes at that step.

**I lost or overwrote the USB.**
Rebuild it with `sudo omarchy-migrate-drive prepare --rebuild`. The state on
the source ESP is authoritative; the new stick's seed plan is ignored when a
source state exists.

**The new drive does not boot.**
Boot the old drive or the USB, run `omarchy-migrate-live status` (or inspect
`/boot/omarchy-migration/state.json` on the source), and check the finalize
state. On UEFI, verify an entry points at the new ESP's
`\EFI\limine\limine_x64.efi`. The migration log on the target is
`/var/lib/omarchy-migration/migration-report.txt` and
`journalctl -u omarchy-migrate-finalize`.

**The old source entry is still in the firmware.**
Run `omarchy-migrate-drive finalize` from the new system. It is idempotent.

**Fingerprint reader/sudo prompt does not appear.**
The tool re-executes itself with `sudo` inside Omarchy's floating terminal.
Run it from a normal terminal if the presentation layer is unavailable.

## Development

```bash
./tests/run.sh
```

The test suite is offline and never touches a real disk. It checks shell
syntax, partition-path helpers, firmware-entry parsing, state transitions,
`/etc/fstab` subvolume parsing, plan maths, mount-option cleanup, menu JSONC
insertion, and manifest fingerprints.

Building a real ISO requires `archiso` and the other build tools listed above:

```bash
# The image is built on demand by:
sudo omarchy-migrate-drive prepare --device /dev/sdX
```

Internally the build copies `live/profile/`, adds `bin/`, `lib/`, the
Plymouth theme and the seed plan to the airootfs, then runs `mkarchiso`.
The profile uses systemd-boot for UEFI and syslinux for legacy BIOS boot.

Layout:

```text
bin/                  host and live entry points
lib/                  shared shell libraries (detection, state, boot, USB, UI)
live/profile/         archiso profile and live-system configuration
live/plymouth/        Omarchy-themed splash
menu/                 standalone menu fragment
systemd/              first-boot finalize unit
tests/                offline test suite
install.sh            system installer
```

## Limitations

- **v0.1 only supports LUKS2 + btrfs Omarchy sources.** Unencrypted btrfs,
  ext4, LVM, mdraid, and non-Limine bootloaders are rejected.
- **UEFI is the tested path.** Legacy BIOS installs get a bootable MBR via
  Limine, but firmware boot order is left to the user.
- **The target is always repartitioned.** There is no in-place clone or
  partition shrinking.
- **The source is read-only, but not untouched.** The state file and backup
  set are written to the source ESP.
- **No online migration.** The source and target must both be accessible from
  the live medium; the source must not be in use.
- **Snapshots are not migrated.** Snapper configuration may be copied as part
  of `/etc`, but snapshot subvolumes are skipped.
- **Swapfile is recreated, not copied.** The `resume_offset` changes and is
  recomputed on the target. Hibernation must be re-tested.
- **Boot artifacts are regenerated by the installed Omarchy tools.** A broken
  `mkinitcpio`/Limine configuration in the source will fail the migration
  rather than being repaired.
- **The ISO build is not hermetic.** It uses the host's Arch mirrors and
  `pacman` configuration; a network connection is required for the first build.
- **No GPG signature on the USB manifest.** Freshness is checked with a
  content fingerprint, not a signature.
- **The finalize notification depends on a running graphical session.** If it
  is unavailable, check the systemd unit and report file manually.
- **Only one migration at a time.** A runtime lock prevents concurrent runs.

---

Licensed under the MIT License; see [LICENSE](LICENSE).
