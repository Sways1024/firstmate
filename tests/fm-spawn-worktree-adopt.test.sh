#!/usr/bin/env bash
# tests/fm-spawn-worktree-adopt.test.sh - regressions for what a respawn does
# with the PREVIOUS worker's record in bin/fm-spawn.sh: whether it may launch at
# all, whether it re-enters the recorded worktree, and what of that record it
# carries forward.
#
# `treehouse get` never re-issues a slot that is already leased, not even to the
# holder that leased it, so a respawn of a task whose worktree is still leased
# under fm-<id> used to be handed a DIFFERENT slot: the dead worker's branch and
# uncommitted work were left stranded in the old one while its replacement
# started in an empty checkout. bin/fm-spawn.sh now re-enters the task's own
# recorded worktree when - and only when - it can prove that is safe.
#
# Covers, with a fake tmux/treehouse world and real isolated git worktrees:
#   - adoption when every precondition holds: no new lease is taken, the pane
#     only cd's in, and the worktree's branch and uncommitted work survive;
#   - fallback to the ordinary lease when the task has no metadata, even while
#     the pool reports a slot held under this task's holder (a fresh task must
#     never inherit a slot on the holder name alone);
#   - fallback when the recorded path is leased to some other holder;
#   - refusal to launch a second agent for a task id whose own recorded endpoint
#     is still alive in ANOTHER session, or whose read failed;
#   - a backend with no liveness surface at all still respawning, because the
#     absence of a reading is not evidence of a live worker;
#   - post-spawn metadata (a recorded PR, a Relay request binding) surviving the
#     metadata rewrite an adopting respawn performs;
#   - the abort path leaving an adopted worktree's lease untouched, because
#     `treehouse return --force` cleans and resets the worktree it releases;
#   - the sibling-ownership refusal still firing against an adopted path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-adopt)

# Fake tmux: same shape as tests/fm-spawn-worktree-ownership.test.sh - new-window
# prints a stable id, kill-window is observable, list-windows reports
# FM_FAKE_WINDOW_LIST, and the pane-path/pane-command queries answer from
# FM_FAKE_PANE_PATH/FM_FAKE_PANE_COMMAND.
# Fake treehouse additionally answers `status --json` from
# FM_FAKE_TREEHOUSE_STATUS_JSON, which is what the adoption path reads to prove
# the recorded worktree is still leased to this task.
make_adopt_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_tty}"*) exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    # Session-scoped, unlike the ownership suite's fake: the live-endpoint case
    # needs a task whose RECORDED endpoint is alive in one session while the
    # session this spawn creates its own window in has no such window, so the
    # duplicate-window refusal cannot mask the adoption decision under test.
    # `-a` (whole-server inventory) is never scoped.
    ses=
    scoped=1
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -a) scoped=0; shift ;;
        -t) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    # An inventory read that fails with an unrecognized message is how a real
    # tmux reports a transient problem, and it classifies the endpoint
    # `unreadable` rather than gone. Scoped to one session so the spawn's own
    # session still answers normally.
    if [ "$scoped" = 1 ] && [ -n "${FM_FAKE_WINDOW_LIST_UNREADABLE_SESSION:-}" ] \
       && [ "$ses" = "$FM_FAKE_WINDOW_LIST_UNREADABLE_SESSION" ]; then
      printf 'lost server\n' >&2
      exit 1
    fi
    if [ "$scoped" = 1 ] && [ -n "${FM_FAKE_WINDOW_LIST_SESSION:-}" ] \
       && [ "$ses" != "$FM_FAKE_WINDOW_LIST_SESSION" ]; then
      exit 0
    fi
    [ -z "${FM_FAKE_WINDOW_LIST:-}" ] || printf '%s\n' "$FM_FAKE_WINDOW_LIST"
    exit 0
    ;;
  new-window) printf '%s\n' "${FM_FAKE_WINDOW_ID:-@51}"; exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf 'kill-window %s\n' "${3:-}" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  exit 0
fi
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
if [ "${1:-}" = status ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_STATUS_JSON:-[]}"
  exit 0
fi
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_WT:-}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_adopt_case <name> <id> builds a home, a primary project with TWO real
# linked worktrees (the task's recorded one and a spare the pool can hand out as
# a fresh lease), and the fake toolchain. Echoes a |-joined record.
make_adopt_case() {
  local name=$1 id=$2 case_dir home proj wt spare fakebin
  mkdir -p "$TMP_ROOT/$name"
  # Physical paths throughout: fm-spawn.sh resolves and records the worktree
  # physically, and the macOS temp root is a symlink, so raw $TMPDIR paths would
  # make every path assertion below compare two spellings of the same directory.
  case_dir=$(cd "$TMP_ROOT/$name" && pwd -P)
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  spare="$case_dir/spare"
  fakebin=$(make_adopt_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git -C "$proj" worktree add --quiet -b "spare-$name" "$spare"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$spare|$fakebin"
}

read_adopt_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR SPARE_DIR FAKEBIN_DIR <<EOF
$1
EOF
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  TMUX_LOG="$CASE_DIR/tmux.log"
  : > "$TREEHOUSE_LOG"
  : > "$TMUX_LOG"
}

# pool_json <path> <status> [holder]: a two-slot pool in the shape
# `treehouse status --json` emits, nested `processes` arrays included, so the
# spawn reads real record shapes rather than a flattened single record. Slot 2
# is the free spare the pool would hand out on a fallback lease.
pool_json() {
  local path=$1 status=$2 holder=${3:-} first
  if [ -n "$holder" ]; then
    first=$(printf '{"name":"1","path":"%s","status":"%s","lease_id":"deadbeef","lease_holder":"%s","holder_gone":true,"processes":[{"pid":4321,"name":"zsh"}]}' \
      "$path" "$status" "$holder")
  else
    first=$(printf '{"name":"1","path":"%s","status":"%s","processes":[]}' "$path" "$status")
  fi
  printf '[%s,{"name":"2","path":"%s","status":"free","processes":[]}]\n' "$first" "$SPARE_DIR"
}

# write_task_meta <id> <worktree>: the metadata a previous worker left behind,
# in the legacy tmux shape (window= names the endpoint fm-<id>).
write_task_meta() {
  local id=$1 wt=$2
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
}

run_adopt_spawn() {  # <id> [extra env as VAR=val words]
  local id=$1
  shift
  env "$@" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_TREEHOUSE_LOG="$TREEHOUSE_LOG" FM_FAKE_TMUX_LOG="$TMUX_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# (a) Every precondition holds: the task's recorded worktree is still leased to
# fm-<id>, its endpoint is gone, and the path is a real isolated worktree root.
# The respawn re-enters it, takes no new lease, and leaves it byte for byte as
# the dead worker left it.
test_adopts_recorded_worktree() {
  local rec id out status marker head_before head_after
  id=adopt-happy-a1
  rec=$(make_adopt_case adopt-happy "$id")
  read_adopt_record "$rec"
  write_task_meta "$id" "$WT_DIR"
  marker="$WT_DIR/round-five-unlanded"
  printf 'five rounds of review fixes\n' > "$marker"
  git -C "$WT_DIR" add round-five-unlanded
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)

  out=$(run_adopt_spawn "$id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" leased "fm-$id")" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$WT_DIR")
  status=$?
  expect_code 0 "$status" "respawn into an adoptable recorded worktree should succeed: $out"
  assert_contains "$out" "spawned $id" "adopting respawn did not report success"
  assert_contains "$out" "re-entering its own recorded worktree $WT_DIR" \
    "adopting respawn did not print a notice naming the adopted worktree"
  assert_no_grep "get --lease" "$TREEHOUSE_LOG" \
    "adopting respawn must not lease a second pool slot"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "adopting respawn did not record the adopted worktree"
  assert_present "$marker" "adoption must not remove the worker's uncommitted work"
  assert_grep "five rounds of review fixes" "$marker" \
    "adoption must not rewrite the worker's uncommitted work"
  head_after=$(git -C "$WT_DIR" rev-parse HEAD)
  [ "$head_before" = "$head_after" ] || fail "adoption moved the adopted worktree's HEAD"
  [ "$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)" = "wt-adopt-happy" ] \
    || fail "adoption changed the adopted worktree's branch"
  [ -n "$(git -C "$WT_DIR" status --porcelain)" ] \
    || fail "adoption reset the adopted worktree's index"
  pass "a respawn re-enters its own leased worktree without leasing or touching anything"
}

# (b) A task with no metadata is a fresh task and must lease normally, even
# though the pool happens to report a slot held under this task's own holder
# name. The holder name alone is never adoption evidence: only the task's own
# recorded worktree= is.
test_no_metadata_falls_back_to_lease() {
  local rec id out status
  id=adopt-fresh-b2
  rec=$(make_adopt_case adopt-fresh "$id")
  read_adopt_record "$rec"

  out=$(run_adopt_spawn "$id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" leased "fm-$id")" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$SPARE_DIR")
  status=$?
  expect_code 0 "$status" "a fresh task should lease normally: $out"
  assert_grep "get --lease --lease-holder fm-$id" "$TREEHOUSE_LOG" \
    "a task with no metadata did not take the ordinary lease path"
  assert_not_contains "$out" "re-entering its own recorded worktree" \
    "a task with no metadata must never adopt a worktree"
  assert_grep "worktree=$SPARE_DIR" "$HOME_DIR/state/$id.meta" \
    "fresh task did not record the freshly leased worktree"
  pass "a task with no metadata leases normally even while the pool holds a same-named lease"
}

# (c) The recorded path is leased to somebody else - returned and re-issued, or
# never this task's. Not ours to re-enter: lease a fresh slot instead.
test_foreign_lease_falls_back_to_lease() {
  local rec id out status
  id=adopt-foreign-c3
  rec=$(make_adopt_case adopt-foreign "$id")
  read_adopt_record "$rec"
  write_task_meta "$id" "$WT_DIR"

  out=$(run_adopt_spawn "$id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" leased "fm-some-other-task")" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$SPARE_DIR")
  status=$?
  expect_code 0 "$status" "a foreign-held recorded path should fall back to a lease: $out"
  assert_grep "get --lease --lease-holder fm-$id" "$TREEHOUSE_LOG" \
    "a recorded path leased to another holder did not fall back to the lease path"
  assert_not_contains "$out" "re-entering its own recorded worktree" \
    "a recorded path leased to another holder must never be adopted"
  assert_grep "worktree=$SPARE_DIR" "$HOME_DIR/state/$id.meta" \
    "fallback spawn did not record the freshly leased worktree"
  pass "a recorded worktree leased to another holder is never adopted"
}

# (c2) The recorded path is not leased at all (the pool reports it free), so
# nothing binds it to this task and the spawn leases normally.
test_unleased_recorded_path_falls_back() {
  local rec id out status
  id=adopt-unleased-c4
  rec=$(make_adopt_case adopt-unleased "$id")
  read_adopt_record "$rec"
  write_task_meta "$id" "$WT_DIR"

  out=$(run_adopt_spawn "$id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" free)" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$SPARE_DIR")
  status=$?
  expect_code 0 "$status" "an unleased recorded path should fall back to a lease: $out"
  assert_grep "get --lease --lease-holder fm-$id" "$TREEHOUSE_LOG" \
    "an unleased recorded path did not fall back to the lease path"
  assert_not_contains "$out" "re-entering its own recorded worktree" \
    "an unleased recorded path must never be adopted"
  pass "a recorded worktree the pool no longer reports as leased is never adopted"
}

# (d) THE cross-session duplicate. The task's own recorded endpoint is alive in
# session `legacy`, while firstmate has since restarted and this spawn resolves
# session `firstmate`. tmux's own duplicate protection is a window-name
# collision check against only the session just resolved, so it sees nothing,
# and the sibling-ownership guard refuses only when a DIFFERENT task records the
# worktree. Without the task's own endpoint reading, a second agent launched
# against the live one.
test_live_own_endpoint_refuses_duplicate_launch() {
  local rec id out status
  id=adopt-live-d5
  rec=$(make_adopt_case adopt-live "$id")
  read_adopt_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=legacy:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_adopt_spawn "$id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" leased "fm-$id")" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$SPARE_DIR" \
    FM_FAKE_WINDOW_LIST="fm-$id" FM_FAKE_WINDOW_LIST_SESSION=legacy \
    FM_FAKE_PANE_COMMAND=codex)
  status=$?
  expect_code 1 "$status" \
    "a task whose own endpoint is alive in another session must refuse to launch a second agent: $out"
  assert_contains "$out" "already records an endpoint that is alive" \
    "the duplicate-launch refusal did not name the live recorded endpoint"
  assert_contains "$out" "legacy:fm-$id" \
    "the duplicate-launch refusal did not name the endpoint to inspect"
  assert_not_contains "$out" "spawned $id" \
    "a refused duplicate launch must never report a spawn"
  assert_no_grep "get --lease" "$TREEHOUSE_LOG" \
    "a refused duplicate launch must not lease a pool slot"
  assert_grep "window=legacy:fm-$id" "$HOME_DIR/state/$id.meta" \
    "a refused duplicate launch must leave the live worker's record intact"
  pass "a task whose own endpoint is alive in another session refuses a second launch"
}

# (d2) The same refusal on a readable surface whose read FAILED. A transient
# inventory failure is not evidence the previous worker is gone, and a false
# "gone" is the one verdict that puts two agents on one task, so an unreadable
# endpoint refuses exactly as a live one does. Distinct from a backend with no
# liveness surface at all, which (d3) pins as still launching.
test_unreadable_own_endpoint_refuses_duplicate_launch() {
  local rec id out status
  id=adopt-unreadable-d6
  rec=$(make_adopt_case adopt-unreadable "$id")
  read_adopt_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=legacy:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_adopt_spawn "$id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" leased "fm-$id")" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$SPARE_DIR" \
    FM_FAKE_WINDOW_LIST_UNREADABLE_SESSION=legacy)
  status=$?
  expect_code 1 "$status" \
    "an unreadable recorded endpoint must refuse to launch a second agent: $out"
  assert_contains "$out" "already records an endpoint that is unreadable" \
    "the duplicate-launch refusal did not name the unreadable recorded endpoint"
  assert_no_grep "get --lease" "$TREEHOUSE_LOG" \
    "a refused duplicate launch must not lease a pool slot"
  pass "a recorded endpoint that cannot be read refuses a second launch"
}

# (d3) A backend with NO liveness surface at all reads `unverified`, which is the
# absence of a reading rather than a failed one. Refusing on it would make every
# respawn on that backend impossible without making any of them safer, so those
# spawns keep the behavior they have today: no adoption (that still demands
# proof the endpoint is gone), and an ordinary fresh lease.
test_unverified_backend_still_respawns() {
  local rec id out status
  id=adopt-unverified-d7
  rec=$(make_adopt_case adopt-unverified "$id")
  read_adopt_record "$rec"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "backend=zellij" \
    "zellij_session=old" \
    "zellij_tab_id=1" \
    "zellij_pane_id=2"

  out=$(run_adopt_spawn "$id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" leased "fm-$id")" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$SPARE_DIR")
  status=$?
  expect_code 0 "$status" \
    "a recorded endpoint on a backend with no liveness surface should still respawn: $out"
  assert_contains "$out" "spawned $id" "the respawn did not report success"
  assert_not_contains "$out" "refusing to launch a second agent" \
    "the absence of a liveness surface must never read as evidence of a live worker"
  assert_not_contains "$out" "re-entering its own recorded worktree" \
    "an unproven endpoint must never adopt its recorded worktree"
  assert_grep "get --lease --lease-holder fm-$id" "$TREEHOUSE_LOG" \
    "the respawn did not fall back to the ordinary lease path"

  # Non-vacuity control: the same recorded endpoint on a backend that DOES
  # classify liveness refuses. Only the backend= line differs, so the guard is
  # provably reached here and it is the missing liveness surface, not an
  # unresolvable endpoint, that let the launch through above.
  local control control_id control_out control_status
  control_id=adopt-unverified-control-d7
  control=$(make_adopt_case adopt-unverified-control "$control_id")
  read_adopt_record "$control"
  fm_write_meta "$HOME_DIR/state/$control_id.meta" \
    "window=fm-$control_id" \
    "endpoint_task_id=$control_id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  control_out=$(run_adopt_spawn "$control_id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" leased "fm-$control_id")" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$SPARE_DIR")
  control_status=$?
  expect_code 1 "$control_status" \
    "the control endpoint on a liveness-classifying backend should refuse: $control_out"
  assert_contains "$control_out" "refusing to launch a second agent" \
    "the control did not exercise the duplicate-launch guard, so the unverified case proves nothing"
  pass "a recorded endpoint on a backend with no liveness surface still respawns and leases"
}

# (d4) A legitimate recovery respawn - endpoint confidently gone, worktree still
# leased to this task - carries the previous worker's post-spawn bindings across
# the metadata rewrite. Those fields are written AFTER a spawn by other tools and
# cannot be regenerated from this invocation: bin/fm-teardown.sh's landed-work
# test and bin/fm-review-diff.sh both read pr=, and a promised final public reply
# is recovered only from the Relay request binding. The rewrite used to drop them
# silently, because the merge poll binds elsewhere and kept running. Also the
# end-to-end proof that this exact path still adopts and launches.
test_respawn_preserves_pr_and_relay_bindings() {
  local rec id out status meta
  id=adopt-preserve-d8
  rec=$(make_adopt_case adopt-preserve "$id")
  read_adopt_record "$rec"
  meta="$HOME_DIR/state/$id.meta"
  fm_write_meta "$meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "herdr_pane_id=pane-from-a-previous-backend" \
    "pr=https://github.com/example/repo/pull/4242" \
    "pr_head=1f2e3d4c5b6a7988990a1b2c3d4e5f6071829304" \
    "x_request=req-77aa" \
    "x_request_ts=1755000000" \
    "x_followups=2" \
    "x_platform=x" \
    "x_reply_max_chars=280"

  out=$(run_adopt_spawn "$id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" leased "fm-$id")" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$WT_DIR")
  status=$?
  expect_code 0 "$status" "a legitimate recovery respawn should adopt and launch: $out"
  assert_contains "$out" "spawned $id" "the recovery respawn did not report success"
  assert_contains "$out" "re-entering its own recorded worktree $WT_DIR" \
    "the recovery respawn did not adopt the recorded worktree"
  assert_grep "pr=https://github.com/example/repo/pull/4242" "$meta" \
    "the respawn dropped the recorded PR, which teardown's landed-work test and review both read"
  assert_grep "pr_head=1f2e3d4c5b6a7988990a1b2c3d4e5f6071829304" "$meta" \
    "the respawn dropped the recorded PR head"
  assert_grep "x_request=req-77aa" "$meta" \
    "the respawn dropped the Relay request, losing a promised public reply"
  assert_grep "x_request_ts=1755000000" "$meta" "the respawn dropped the Relay request timestamp"
  assert_grep "x_followups=2" "$meta" "the respawn dropped the Relay follow-up count"
  assert_grep "x_platform=x" "$meta" "the respawn dropped the Relay platform"
  assert_grep "x_reply_max_chars=280" "$meta" "the respawn dropped the Relay reply limit"
  # An allowlist, not a blanket copy-through: a field this invocation does not
  # regenerate and did not bind - a previous backend's endpoint identity - must
  # not survive, because carrying it would describe an endpoint that is gone.
  assert_no_grep "pane-from-a-previous-backend" "$meta" \
    "the respawn carried a stale endpoint identity across the rewrite"
  [ "$(grep -c '^pr=' "$meta")" = 1 ] || fail "the respawn recorded pr= more than once"
  pass "a recovery respawn adopts, launches, and keeps the PR and Relay bindings it did not regenerate"
}

# (e) THE safety property. An adopted worktree's lease was not acquired by this
# invocation, so the abort path must never return it: `treehouse return --force`
# terminates processes, cleans, and resets the worktree it releases, which is
# exactly the unlanded work adoption exists to preserve. A fake `sleep` collapses
# the 60-poll entry wait so the abort is observable in-test.
test_abort_never_returns_an_adopted_lease() {
  local rec id out status marker
  id=adopt-abort-e6
  rec=$(make_adopt_case adopt-abort "$id")
  read_adopt_record "$rec"
  write_task_meta "$id" "$WT_DIR"
  marker="$WT_DIR/round-five-unlanded"
  printf 'five rounds of review fixes\n' > "$marker"
  cat > "$FAKEBIN_DIR/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$FAKEBIN_DIR/sleep"

  out=$(run_adopt_spawn "$id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" leased "fm-$id")" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$PROJ_DIR" FM_FAKE_WINDOW_ID=@79)
  status=$?
  expect_code 1 "$status" "a pane that never enters the adopted worktree should abort"
  assert_contains "$out" "did not enter the adopted worktree" \
    "the entry timeout lost its adopted-worktree error"
  assert_grep "kill-window @79" "$TMUX_LOG" \
    "abort cleanup did not kill the exact created window id"
  assert_no_grep "return --force" "$TREEHOUSE_LOG" \
    "abort cleanup returned an ADOPTED lease (a forced return resets the worktree and destroys the work adoption exists to preserve)"
  assert_present "$marker" "an aborted adopting spawn must not touch the worktree's uncommitted work"
  assert_absent "$HOME_DIR/state/$id.meta.new" "aborted spawn must not leave partial metadata"
  pass "an aborted adopting spawn never returns the lease it did not acquire"
}

# (f) The sibling-ownership guard still runs against an adopted path: another
# live task recording the same worktree refuses the launch, and the refusal
# still repairs nothing and still returns no lease.
test_sibling_ownership_still_refuses_an_adopted_path() {
  local rec id out status marker
  id=adopt-sibling-f7
  rec=$(make_adopt_case adopt-sibling "$id")
  read_adopt_record "$rec"
  write_task_meta "$id" "$WT_DIR"
  fm_write_meta "$HOME_DIR/state/incumbent.meta" \
    "window=firstmate:fm-incumbent" \
    "endpoint_task_id=incumbent" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  marker="$WT_DIR/incumbent-unlanded"
  printf 'unlanded work\n' > "$marker"

  out=$(run_adopt_spawn "$id" \
    FM_FAKE_TREEHOUSE_STATUS_JSON="$(pool_json "$WT_DIR" leased "fm-$id")" \
    FM_FAKE_TREEHOUSE_WT="$SPARE_DIR" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_WINDOW_LIST=fm-incumbent FM_FAKE_PANE_COMMAND=codex)
  status=$?
  expect_code 1 "$status" "adopting a live sibling's recorded worktree should refuse"
  assert_contains "$out" "live task incumbent already records as its worktree" \
    "the sibling-ownership refusal did not fire against the adopted path"
  assert_present "$marker" "the refusal must not touch the incumbent's uncommitted work"
  assert_no_grep "return --force" "$TREEHOUSE_LOG" \
    "the sibling refusal must never return an adopted lease"
  assert_not_contains "$out" "is left held (holder fm-$id)" \
    "an adopted lease must never be reported as one this spawn acquired"
  assert_grep "kill-window" "$TMUX_LOG" \
    "the sibling refusal did not remove the created tmux window"
  pass "the sibling-ownership refusal still fires against an adopted worktree"
}

test_adopts_recorded_worktree
test_no_metadata_falls_back_to_lease
test_foreign_lease_falls_back_to_lease
test_unleased_recorded_path_falls_back
test_live_own_endpoint_refuses_duplicate_launch
test_unreadable_own_endpoint_refuses_duplicate_launch
test_unverified_backend_still_respawns
test_respawn_preserves_pr_and_relay_bindings
test_abort_never_returns_an_adopted_lease
test_sibling_ownership_still_refuses_an_adopted_path

echo "# all fm-spawn-worktree-adopt tests passed"
