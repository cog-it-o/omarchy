#!/usr/bin/env bash
# shellcheck shell=bash
#
# Omarchy menu integration.
#
# Omarchy loads exactly one user extension file:
#   ~/.config/omarchy/extensions/omarchy-menu.jsonc
# It is JSONC, so we insert a single new top-level key without rewriting the
# user's comments or other entries.

: "${MENU_KEY:=system.migrate-drive}"

menu_entry_line() {
  printf '%s' '"system.migrate-drive": {"icon":"󰋊","label":"Migrate Omarchy","action":"omarchy-launch-floating-terminal-with-presentation omarchy-migrate-drive","description":"Move this Omarchy installation to another drive","when":"omarchy-cmd-present omarchy-migrate-drive"}'
}

menu_standalone_json() {
  cat <<'EOF'
{
  // Omarchy drive migration.
  // Add this file's contents to ~/.config/omarchy/extensions/omarchy-menu.jsonc
  // or run install.sh, which inserts it for every user automatically.
  "system.migrate-drive": {"icon":"󰋊","label":"Migrate Omarchy","action":"omarchy-launch-floating-terminal-with-presentation omarchy-migrate-drive","description":"Move this Omarchy installation to another drive","when":"omarchy-cmd-present omarchy-migrate-drive"}
}
EOF
}

# Insert the entry into an existing JSONC object, preserving comments.
menu_install_into_file() {
  local file="$1"
  om_have python3 || {
    om_warn "python3 is required to update $file"
    return 1
  }

  python3 - "$file" "$(menu_entry_line)" <<'PY'
import sys

path, entry = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
except FileNotFoundError:
    text = ""

if '"system.migrate-drive"' in text:
    sys.exit(0)

if not text.strip():
    text = "{\n}\n"

lines = text.splitlines()
close_index = None
for i in range(len(lines) - 1, -1, -1):
    if lines[i].strip() == "}":
        close_index = i
        break

if close_index is None:
    sys.exit("no top-level closing brace found")

last_significant = None
for i in range(close_index - 1, -1, -1):
    stripped = lines[i].strip()
    if not stripped or stripped.startswith("//"):
        continue
    last_significant = i
    break

if last_significant is not None:
    stripped = lines[last_significant].rstrip()
    if not stripped.endswith((",", "{")):
        lines[last_significant] = stripped + ","

lines.insert(close_index, "  " + entry)
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
PY
}

# Install the menu entry for every human user in a root filesystem.
# Arguments: root prefix ("" or "/" for the running system), optional passwd file
menu_install_for_users() {
  local root="${1:-}" count=0
  local passwd="${2:-$root/etc/passwd}"
  local line name uid gid gecos home shell home_dir target_user

  [[ -r $passwd ]] || return 0

  while IFS=: read -r name _ uid gid gecos home shell; do
    [[ $uid =~ ^[0-9]+$ ]] || continue
    ((uid >= 1000)) || continue
    [[ $home == /home/* || $home == /root ]] || continue

    if [[ -n $root ]]; then
      home_dir="$root$home"
      target_user="$name"
    else
      home_dir="$home"
      target_user="$name"
    fi
    [[ -d $home_dir ]] || continue

    local ext_dir="$home_dir/.config/omarchy/extensions"
    local file="$ext_dir/omarchy-menu.jsonc"
    if [[ -n $root ]]; then
      mkdir -p -- "$ext_dir"
    else
      install -d -o "$target_user" -g "$gid" -- "$ext_dir" 2>/dev/null || mkdir -p -- "$ext_dir"
    fi

    if menu_install_into_file "$file"; then
      if [[ -n $root ]]; then
        chown -R "$uid:$gid" -- "$home_dir/.config/omarchy" 2>/dev/null || true
      else
        chown "$uid:$gid" -- "$file" 2>/dev/null || true
      fi
      count=$((count + 1))
      om_log INFO "installed Omarchy menu entry for $name ($file)"
    fi
  done <"$passwd"

  printf '%s\n' "$count"
}
