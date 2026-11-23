#!/usr/bin/env bash
# fm-remote-systemd-lib.sh - Firstmate's systemd user units on a Linux remote account.
#
# Source this file. On Linux a remote second mate's account keeps its job
# worker and its fm-remote Herdr server alive across a reboot with two systemd
# USER units, the counterpart of the macOS launchd KeepAlive agents. This file
# is the single owner of how Firstmate reaches that account's user manager and
# publishes a unit there:
#
#   fm_remote_systemd_ctl <systemctl-args...>
#       systemctl --user, with XDG_RUNTIME_DIR=/run/user/<uid> when the caller's
#       bare environment carries none (every remote child runs under env -i).
#   fm_remote_systemd_available <account-home>
#       0 only when systemctl resolves, the user manager answers, and that
#       manager's own HOME is <account-home>. A unit file under any other HOME
#       would never be loaded, so a fixture account or a host without a user
#       manager falls back to the plain-process path instead of writing one.
#   fm_remote_systemd_unit_path <account-home> <unit>
#   fm_remote_systemd_unit_installed <account-home> <unit>
#   fm_remote_systemd_unit_matches <account-home> <unit> <expected-file>
#       The installed unit file is byte-identical to the rendered contract and
#       the manager reports it enabled.
#   fm_remote_systemd_publish <account-home> <unit> <rendered-file>
#       Atomically writes the unit, reloads the manager, and enables it for
#       default.target. It never starts, stops, or restarts the unit: each
#       caller owns when its process may be (re)started.
#   fm_remote_systemd_safe_value <value>
#       Refuses a path or value that cannot be embedded verbatim in a quoted
#       unit directive.
#   fm_remote_systemd_herdr_unit <session>
#       dev.firstmate.herdr.<session>.service, the unit that owns that session's
#       server when it is installed.
#
# Every function returns non-zero on any doubt and sets FM_REMOTE_SYSTEMD_ERROR
# to a one-line reason where a caller reports one.

# Consumed by the sourcing caller, so its assignments read as unused here.
# shellcheck disable=SC2034
FM_REMOTE_SYSTEMD_ERROR=

fm_remote_systemd_ctl() { # <systemctl-args...>
  local uid runtime
  uid=$(id -u 2>/dev/null) || return 1
  runtime=${XDG_RUNTIME_DIR:-/run/user/$uid}
  XDG_RUNTIME_DIR=$runtime systemctl --user "$@"
}

fm_remote_systemd_available() { # <account-home>
  local account_home=$1 manager_home
  command -v systemctl >/dev/null 2>&1 || return 1
  manager_home=$(fm_remote_systemd_ctl show-environment 2>/dev/null | sed -n 's/^HOME=//p' | head -1)
  [ -n "$manager_home" ] && [ -d "$manager_home" ] && [ -d "$account_home" ] || return 1
  [ "$(CDPATH='' cd -- "$manager_home" && pwd -P)" = "$(CDPATH='' cd -- "$account_home" && pwd -P)" ]
}

fm_remote_systemd_unit_dir() { # <account-home>
  printf '%s/.config/systemd/user\n' "$1"
}

fm_remote_systemd_unit_path() { # <account-home> <unit>
  printf '%s/%s\n' "$(fm_remote_systemd_unit_dir "$1")" "$2"
}

fm_remote_systemd_herdr_unit() { # <session>
  printf 'dev.firstmate.herdr.%s.service\n' "$1"
}

fm_remote_systemd_unit_installed() { # <account-home> <unit>
  local path
  path=$(fm_remote_systemd_unit_path "$1" "$2")
  [ -f "$path" ] && [ ! -L "$path" ]
}

fm_remote_systemd_unit_matches() { # <account-home> <unit> <expected-file>
  local path
  path=$(fm_remote_systemd_unit_path "$1" "$2")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  cmp -s "$path" "$3" || return 1
  [ "$(fm_remote_systemd_ctl is-enabled "$2" 2>/dev/null)" = enabled ]
}

fm_remote_systemd_safe_value() { # <value>
  case "$1" in
    ''|*[[:space:]]*|*'"'*|*"'"*|*\\*|*'%'*|*'$'*|*';'*) return 1 ;;
  esac
}

fm_remote_systemd_publish() { # <account-home> <unit> <rendered-file>
  local account_home=$1 unit=$2 rendered=$3 dir path tmp out
  FM_REMOTE_SYSTEMD_ERROR=
  dir=$(fm_remote_systemd_unit_dir "$account_home")
  path="$dir/$unit"
  if ! mkdir -p "$dir" 2>/dev/null || [ -L "$dir" ] || [ -L "$path" ]; then
    FM_REMOTE_SYSTEMD_ERROR="cannot create $dir safely"
    return 1
  fi
  if ! cmp -s "$rendered" "$path" 2>/dev/null; then
    tmp="$dir/.$unit.tmp.$$"
    if ! cp -- "$rendered" "$tmp" 2>/dev/null || ! chmod 0644 "$tmp" 2>/dev/null ||
      ! mv -f -- "$tmp" "$path" 2>/dev/null; then
      rm -f -- "$tmp"
      FM_REMOTE_SYSTEMD_ERROR="cannot publish $path"
      return 1
    fi
  fi
  if ! out=$(fm_remote_systemd_ctl daemon-reload 2>&1); then
    FM_REMOTE_SYSTEMD_ERROR="systemctl --user daemon-reload refused: ${out:-no diagnostic}"
    return 1
  fi
  if ! out=$(fm_remote_systemd_ctl enable "$unit" 2>&1); then
    FM_REMOTE_SYSTEMD_ERROR="systemctl --user enable $unit refused: ${out:-no diagnostic}"
    return 1
  fi
}
