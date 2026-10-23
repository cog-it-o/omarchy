#!/usr/bin/env bash
# shellcheck shell=bash
#
# Omarchy-flavoured terminal UI.
#
# All animated/blocking widgets go through gum when it is available (the
# Omarchy desktop and the live image both ship it). Plain read/select fallbacks
# keep the tool usable over a serial console or in tests.

: "${UI_ACCENT:=38;5;111}"
: "${UI_OK:=38;5;114}"
: "${UI_WARN:=38;5;214}"
: "${UI_ERR:=38;5;203}"
: "${UI_MUTED:=38;5;245}"
: "${UI_TEXT:=38;5;252}"

_UI_HAVE_COLOR=0
ui_color_init() {
  if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    _UI_HAVE_COLOR=1
  fi
}

_c() {
  local code="$1"
  shift
  if [[ $_UI_HAVE_COLOR == 1 ]]; then
    printf '\033[%sm%s\033[0m' "$code" "$*"
  else
    printf '%s' "$*"
  fi
}

ui_clear() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[3J\033[H'
  fi
}

ui_banner() {
  local subtitle="${1:-Drive migration}"
  ui_color_init
  ui_clear
  printf '\n'
  if [[ $_UI_HAVE_COLOR == 1 ]]; then
    printf '\033[%sm' "$UI_ACCENT"
  fi
  cat <<'LOGO'
  ██████╗ ███╗   ███╗ █████╗ ██████╗  ██████╗██╗  ██╗██╗   ██╗
 ██╔═══██╗████╗ ████║██╔══██╗██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝
 ██║   ██║██╔████╔██║███████║██████╔╝██║     ███████║ ╚████╔╝
 ██║   ██║██║╚██╔╝██║██╔══██║██╔══██╗██║     ██╔══██║  ╚██╔╝
 ╚██████╔╝██║ ╚═╝ ██║██║  ██║██║  ██║╚██████╗██║  ██║   ██║
  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝
LOGO
  if [[ $_UI_HAVE_COLOR == 1 ]]; then
    printf '\033[0m'
  fi
  printf '  %s\n' "$(_c "$UI_MUTED" "$subtitle")"
  printf '  %s\n\n' "$(_c "$UI_MUTED" "────────────────────────────────────────────────────────────")"
}

ui_section() {
  printf '\n  %s\n' "$(_c "1;$UI_ACCENT" "$*")"
}

ui_note() {
  printf '  %s\n' "$(_c "$UI_MUTED" "$*")"
}

ui_warn() {
  printf '  %s %s\n' "$(_c "1;$UI_WARN" "!")" "$*"
}

ui_kv() {
  printf '  %s %s\n' "$(_c "$UI_MUTED" "$1:")" "$2"
}

ui_step_begin() {
  local index="$1" total="$2" label="$3"
  printf '\n  %s %s\n' "$(_c "1;$UI_ACCENT" "[$index/$total]")" "$label"
}

ui_step_ok() {
  local label="${1:-}"
  printf '  %s %s\n' "$(_c "$UI_OK" "✔")" "$(_c "$UI_MUTED" "${label:-done}")"
}

ui_step_skip() {
  local label="$1"
  printf '  %s %s\n' "$(_c "$UI_MUTED" "•")" "$(_c "$UI_MUTED" "$label (already done)")"
}

ui_progress() {
  [[ -t 1 ]] || return 0
  printf '\r  %s %s' "$(_c "$UI_ACCENT" "…")" "$1"
}

ui_progress_done() {
  [[ -t 1 ]] || return 0
  printf '\r\033[K'
}

ui_wait_enter() {
  local prompt="${1:-Press Enter to continue}"
  printf '\n  %s ' "$(_c "$UI_MUTED" "$prompt")"
  IFS= read -r _ || true
}

ui_confirm() {
  local prompt="$1" default="${2:-no}"
  if [[ -t 0 && -t 1 ]] && om_have gum; then
    if [[ $default == yes ]]; then
      gum confirm --default --affirmative "Yes" --negative "No" "$prompt"
    else
      gum confirm --affirmative "Yes" --negative "No" "$prompt"
    fi
    return
  fi

  local suffix="[y/N]" answer
  [[ $default == yes ]] && suffix="[Y/n]"
  printf '  %s %s ' "$prompt" "$suffix" >&2
  IFS= read -r answer || return 1
  case "${answer:-}" in
    y | Y | yes | YES | true) return 0 ;;
    n | N | no | NO | false) return 1 ;;
    "") [[ $default == yes ]] ;;
    *) return 1 ;;
  esac
}

# ui_choose <header> <option>...
# Prints the selected option on stdout. UI is drawn on stderr by gum, so the
# caller can safely capture the result.
ui_choose() {
  local header="$1"
  shift
  (($#)) || return 1

  if [[ -t 0 && -t 1 ]] && om_have gum; then
    printf '%s\n' "$@" | gum choose --header "$header" --height 12 \
      --cursor.foreground "#7aa2f7" --header.foreground "#7aa2f7"
    return
  fi

  local -a opts=("$@")
  local i choice
  printf '\n  %s\n' "$header" >&2
  for i in "${!opts[@]}"; do
    printf '    %d) %s\n' "$((i + 1))" "${opts[i]}" >&2
  done
  printf '  Select [1-%d]: ' "${#opts[@]}" >&2
  IFS= read -r choice || return 1
  [[ $choice =~ ^[0-9]+$ ]] || return 1
  ((choice >= 1 && choice <= ${#opts[@]})) || return 1
  printf '%s\n' "${opts[choice - 1]}"
}

# ui_choose_multi <header> <option>...
# Prints one selected option per line.
ui_choose_multi() {
  local header="$1"
  shift
  (($#)) || return 1

  if [[ -t 0 && -t 1 ]] && om_have gum; then
    printf '%s\n' "$@" | gum choose --no-limit --header "$header" --height 16 \
      --cursor.foreground "#7aa2f7" --header.foreground "#7aa2f7"
    return
  fi

  local -a opts=("$@")
  local i list choice
  printf '\n  %s (comma separated numbers, empty for none)\n' "$header" >&2
  for i in "${!opts[@]}"; do
    printf '    %d) %s\n' "$((i + 1))" "${opts[i]}" >&2
  done
  printf '  Select: ' >&2
  IFS= read -r list || return 1
  for choice in ${list//,/ }; do
    [[ $choice =~ ^[0-9]+$ ]] || continue
    ((choice >= 1 && choice <= ${#opts[@]})) || continue
    printf '%s\n' "${opts[choice - 1]}"
  done
}

ui_input() {
  local prompt="$1" default="${2:-}"
  if [[ -t 0 && -t 1 ]] && om_have gum; then
    if [[ -n $default ]]; then
      gum input --prompt "$prompt " --value "$default"
    else
      gum input --prompt "$prompt "
    fi
    return
  fi
  local value
  printf '  %s ' "$prompt" >&2
  IFS= read -r value || return 1
  printf '%s\n' "${value:-$default}"
}

ui_password() {
  local prompt="$1" value
  printf '  %s ' "$prompt" >&2
  if [[ -t 0 ]]; then
    IFS= read -rs value || return 1
    printf '\n' >&2
  else
    IFS= read -r value || return 1
  fi
  printf '%s' "$value"
}

ui_error_panel() {
  local title="$1" message="$2" log="${3:-$OM_LOG}"
  printf '\n'
  printf '  %s\n' "$(_c "1;$UI_ERR" "┌─ $title ─────────────────────────────────────────────")"
  local line
  while IFS= read -r line; do
    printf '  %s %s\n' "$(_c "$UI_ERR" "│")" "$line"
  done <<<"$message"
  printf '  %s\n' "$(_c "1;$UI_ERR" "└──────────────────────────────────────────────────────")"
  printf '  %s %s\n' "$(_c "$UI_MUTED" "Full log:")" "$log"
}

ui_success_panel() {
  local title="$1"
  shift
  printf '\n'
  printf '  %s\n' "$(_c "1;$UI_OK" "┌─ $title ─────────────────────────────────────────────")"
  local line
  for line in "$@"; do
    printf '  %s %s\n' "$(_c "$UI_OK" "│")" "$line"
  done
  printf '  %s\n' "$(_c "1;$UI_OK" "└──────────────────────────────────────────────────────")"
}
