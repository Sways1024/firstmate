#!/usr/bin/env bash
# tests/fm-watch-validation-cadence.test.sh - PROTOTYPE evidence for the
# fm-supervision-churn-audit scout report (claim 1).
#
# Baseline behaviour on fork/patched 4eb87a0 (see the existing
# tests/fm-watch-triage.test.sh case
# "consecutive wedge escalations on the same pane accumulate and demand deep
# inspection at the threshold"): a crew whose AUTHORITATIVE state is
# `working · source: run-step` - an actively running no-mistakes validation -
# is wedge-escalated every STALE_ESCALATE_SECS and reaches
# demand-deep-inspection after three rounds. wedge_timer_check deliberately
# never re-reads the crew state, so the run-step signal that already proved the
# crew healthy at classification time is never consulted again.
#
# These cases assert the prototype gate: the run-step read is re-consulted ONCE
# per escalation attempt (not per poll), a still-running validation is absorbed
# on the long VALIDATION_RESURFACE_SECS cadence instead of escalated, the wedge
# path still fires the moment the run stops being the reason for the quiet
# pane, and the long cadence still surfaces so a frozen pipeline cannot rot.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-validation-cadence-tests)

# Local copies of the three helpers tests/fm-watch-triage.test.sh defines for
# itself (this prototype suite deliberately does not edit that file).
wait_live() {  # <pid> [ticks]
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Prime a stale hash for <window> so the next poll goes through wedge_timer_check
# rather than first-sight classification (mirrors the existing wedge tests' Phase A).
prime_stale() {  # <state> <fakebin> <capture_file> <window> <out>
  local state=$1 fakebin=$2 capture_file=$3 window=$4 out=$5 pid
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_live "$pid" 30 || { reap "$pid"; fail "watcher exited on the priming round: $(cat "$out")"; }
  reap "$pid"
}

setup_case() {  # <name> <window> -> sets DIR STATE FAKEBIN OUT CAPTURE KEY
  DIR=$(make_case "$1"); STATE="$DIR/state"; FAKEBIN="$DIR/fakebin"
  OUT="$DIR/watch.out"; CAPTURE="$DIR/pane.txt"
  WINDOW=$2
  printf 'idle building output' > "$CAPTURE"
  printf 'window=%s\nkind=ship\n' "$WINDOW" > "$STATE/validating.meta"
  printf 'working: handed the branch to validation\n' > "$STATE/validating.status"
  local sig; sig=$(seen_sig "$STATE/validating.status")
  printf '%s' "$sig" > "$STATE/.seen-validating_status"
  KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
  printf '%s' "$(hash_text "idle building output")" > "$STATE/.hash-$KEY"
  printf '1\n' > "$STATE/.count-$KEY"
}

test_active_run_step_is_absorbed_not_wedge_escalated() {
  local pid
  setup_case validation-cadence-absorb "test:fm-validating"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_stale "$STATE" "$FAKEBIN" "$CAPTURE" "$WINDOW" "$OUT"

  # Backdate the wedge timer well past the escalation threshold.
  echo $(( $(date +%s) - 500 )) > "$STATE/.stale-since-$KEY"
  : > "$OUT"
  PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$CAPTURE" \
    FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_VALIDATION_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$OUT" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"
    fail "an actively-running validation was wedge-escalated instead of absorbed: $(cat "$OUT")"
  fi
  reap "$pid"
  [ ! -e "$STATE/.wedge-escalations-$KEY" ] \
    || fail "an actively-running validation incremented the wedge-escalation counter"
  grep -F "authoritative run-step working" "$STATE/.watch-triage.log" >/dev/null \
    || fail "no triage line recorded the run-step absorb: $(cat "$STATE/.watch-triage.log" 2>/dev/null)"
  unset FM_FAKE_CREW_STATE
  pass "an actively-running no-mistakes run absorbs the wedge escalation instead of firing it"
}

test_wedge_still_fires_once_the_run_stops_working() {
  local pid
  setup_case validation-cadence-still-wedges "test:fm-validating-stops"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_stale "$STATE" "$FAKEBIN" "$CAPTURE" "$WINDOW" "$OUT"

  # The run is no longer the reason the pane is quiet: the safety net must fire.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  echo $(( $(date +%s) - 500 )) > "$STATE/.stale-since-$KEY"
  : > "$OUT"
  PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$CAPTURE" \
    FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_VALIDATION_RESURFACE_SECS=999999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$OUT" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "the wedge safety net did not fire once the run stopped working: $(cat "$OUT")"
  grep -F "possible wedge, escalation 1" "$OUT" >/dev/null \
    || fail "expected the normal wedge escalation, got: $(cat "$OUT")"
  unset FM_FAKE_CREW_STATE
  pass "the wedge escalation still fires the moment an active run is no longer the reason for the quiet pane"
}

test_long_validation_cadence_still_resurfaces() {
  local pid
  setup_case validation-cadence-resurface "test:fm-validating-long"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  prime_stale "$STATE" "$FAKEBIN" "$CAPTURE" "$WINDOW" "$OUT"

  echo $(( $(date +%s) - 500 )) > "$STATE/.stale-since-$KEY"
  # A validation that has been quiet far longer than the long cadence.
  echo $(( $(date +%s) - 4000 )) > "$STATE/.wedge-escalations-$KEY.validating"
  : > "$OUT"
  PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$CAPTURE" \
    FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_VALIDATION_RESURFACE_SECS=3600 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$OUT" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "the long validation cadence never re-surfaced: $(cat "$OUT")"
  grep -F "background validation rechecked on a long cadence" "$OUT" >/dev/null \
    || fail "expected the long-cadence recheck reason, got: $(cat "$OUT")"
  grep -F "possible wedge" "$OUT" >/dev/null \
    && fail "the long-cadence recheck must not present itself as a wedge: $(cat "$OUT")"
  unset FM_FAKE_CREW_STATE
  pass "a validation quiet past the long cadence still surfaces once, as a recheck rather than a wedge"
}

test_active_run_step_is_absorbed_not_wedge_escalated
test_wedge_still_fires_once_the_run_stops_working
test_long_validation_cadence_still_resurfaces
