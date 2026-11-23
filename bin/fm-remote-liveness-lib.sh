#!/usr/bin/env bash
# fm-remote-liveness-lib.sh - one remote second mate's liveness check and relaunch.
#
# Source this file and call:
#   fm_remote_secondmate_liveness <bin-dir> <spawn-bin-dir> <secondmate-id> <remote-host> <parent-status-file>
#
# This is the single owner of the remote liveness decision. It runs the remote
# readiness gate (bin/fm-remote-readiness-lib.sh), probes the endpoint with
# fm-remote-secondmate-control.sh state, confirms an alive endpoint's Herdr
# route, and relaunches through `fm-spawn.sh <id> --secondmate` only when the
# probe proves the endpoint dead or missing. Every other state - ambiguous,
# unreadable, unverified, alive on another backend, or a probe SSH could not
# complete - is left untouched, and the remote launch re-checks the endpoint
# under its own serialized job, so no caller can create a duplicate. A relaunch
# whose completion SSH left unknown (fm-spawn.sh exit 255) is unavailable, not
# failed: the launch may have landed, so the next check re-probes instead.
#
# Callers: the session-start sweep in bin/fm-bootstrap.sh, and the mid-session
# trigger in bin/fm-procevent-remote-reply.sh once the reply relay's transport
# recovers after an SSH failure. It prints nothing. Its one write: a check that
# ends alive or relaunched while the relay's `blocked [key=remote-liveness-<id>]`
# is still open in <parent-status-file>, per bin/fm-classify-lib.sh's fold,
# appends the matching `resolved` line, so a recovered second mate's blocker
# does not stay open; otherwise a successful check stays silent. It sets:
#   FM_REMOTE_LIVENESS_OUTCOME  alive|relaunched|skipped|unavailable|failed
#   FM_REMOTE_LIVENESS_MESSAGE  the one-line reason, without the
#                               "SECONDMATE_LIVENESS: secondmate <id>: " prefix
#   FM_REMOTE_LIVENESS_CAUSE    for relaunched, the state that justified it
# and returns 255 for unavailable (unknown remote completion: preserve the
# route), 1 for failed (readiness gap or relaunch failure), and 0 otherwise.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_LIVENESS_OUTCOME=
# shellcheck disable=SC2034
FM_REMOTE_LIVENESS_MESSAGE=
# shellcheck disable=SC2034
FM_REMOTE_LIVENESS_CAUSE=

_FM_REMOTE_LIVENESS_LIB_DIR=${BASH_SOURCE[0]%/*}

if ! declare -F fm_remote_readiness_ensure >/dev/null 2>&1; then
  # shellcheck source=bin/fm-remote-readiness-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-remote-readiness-lib.sh"
fi

fm_remote_liveness_set() { # <outcome> <message> [cause]
  # shellcheck disable=SC2034
  FM_REMOTE_LIVENESS_OUTCOME=$1
  # shellcheck disable=SC2034
  FM_REMOTE_LIVENESS_MESSAGE=$2
  # shellcheck disable=SC2034
  FM_REMOTE_LIVENESS_CAUSE=${3:-}
}

fm_remote_liveness_first_line() { # <text>; the first line with whitespace runs squeezed
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

fm_remote_liveness_resolve_blocker() { # <parent-status-file> <secondmate-id>
  local status_file=$1 key="remote-liveness-$2"
  [ -n "$status_file" ] && [ -f "$status_file" ] && [ ! -L "$status_file" ] || return 0
  if ! declare -F status_decision_open >/dev/null 2>&1; then
    # shellcheck source=bin/fm-classify-lib.sh
    . "$_FM_REMOTE_LIVENESS_LIB_DIR/fm-classify-lib.sh" || return 0
  fi
  status_decision_open "$status_file" "$key" || return 0
  printf 'resolved [key=%s]: %s\n' "$key" "$FM_REMOTE_LIVENESS_MESSAGE" >> "$status_file" || true
}

fm_remote_secondmate_liveness() { # <bin-dir> <spawn-bin-dir> <secondmate-id> <remote-host> <parent-status-file>
  local bin_dir=$1 spawn_dir=$2 id=$3 remote_host=$4 status_file=${5:-} rc out agent_state route_out remote_backend reason cause
  fm_remote_liveness_set '' ''
  rc=0
  fm_remote_readiness_ensure "$bin_dir" "$id" || rc=$?
  if [ "$rc" -eq 255 ]; then
    fm_remote_liveness_set unavailable "skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
    return 255
  fi
  if [ "$rc" -ne 0 ]; then
    reason=$(printf '%s\n' "$FM_REMOTE_READINESS_OUT" \
      | awk '/^check [^=]+=(fixable|human):|^action:|^error:/ { print; exit }')
    [ -n "$reason" ] || reason=$(fm_remote_liveness_first_line "$FM_REMOTE_READINESS_OUT")
    [ -n "$reason" ] || reason="unknown readiness failure"
    fm_remote_liveness_set failed "skipped: remote readiness failed on $remote_host: $reason"
    return 1
  fi
  if out=$("$bin_dir/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 255 ]; then
    fm_remote_liveness_set unavailable "skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
    return 255
  fi
  if [ "$rc" -ne 0 ]; then
    fm_remote_liveness_set skipped "skipped: remote endpoint probe unreadable on $remote_host"
    return 0
  fi
  agent_state=$(printf '%s\n' "$out" | tail -1)
  case "$agent_state" in
    alive)
      if route_out=$("$bin_dir/fm-on.sh" "$id" fm-remote-secondmate-control.sh route "$id" < /dev/null 2>/dev/null); then
        rc=0
      else
        rc=$?
      fi
      if [ "$rc" -eq 255 ]; then
        fm_remote_liveness_set unavailable "skipped: remote host unavailable or endpoint route unknown; route preserved on $remote_host"
        return 255
      fi
      if [ "$rc" -ne 0 ]; then
        fm_remote_liveness_set skipped "skipped: alive remote endpoint route is unreadable on $remote_host; inspect and migrate or retire it explicitly"
        return 0
      fi
      remote_backend=$(printf '%s\n' "$route_out" | sed -n 's/^backend=//p' | tail -1)
      if [ "$remote_backend" != herdr ]; then
        fm_remote_liveness_set skipped "skipped: alive remote endpoint is recorded on backend '${remote_backend:-missing}'; migrate or retire it explicitly"
        return 0
      fi
      fm_remote_liveness_set alive "remote secondmate $id already live (host=$remote_host)"
      ;;
    dead|missing)
      cause="remote endpoint $agent_state on its configured host"
      if out=$(FM_SPAWN_NO_GUARD=1 "$spawn_dir/fm-spawn.sh" "$id" --secondmate 2>&1); then
        fm_remote_liveness_set relaunched "relaunched after $cause (host=$remote_host)" "$cause"
      else
        rc=$?
        if [ "$rc" -eq 255 ]; then
          fm_remote_liveness_set unavailable "skipped: remote host unavailable or endpoint state unknown; route preserved on $remote_host"
          return 255
        fi
        fm_remote_liveness_set failed "respawn failed after $cause: $(fm_remote_liveness_first_line "$out")"
        return 1
      fi
      ;;
    ambiguous|unreadable|unverified)
      fm_remote_liveness_set skipped "skipped: remote endpoint state is $agent_state on $remote_host"
      ;;
    *) fm_remote_liveness_set skipped "skipped: remote endpoint returned an invalid state" ;;
  esac
  case "$FM_REMOTE_LIVENESS_OUTCOME" in
    alive|relaunched) fm_remote_liveness_resolve_blocker "$status_file" "$id" ;;
  esac
  return 0
}
