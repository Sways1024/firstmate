#!/usr/bin/env bash
# tests/fm-spawn-worktree-adopt.test.sh - respawn worktree adoption regressions
# for bin/fm-spawn.sh.
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
#   - refusal to adopt while the task's own recorded endpoint is still alive;
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

# pool_json <path> <status> [holder]: one pool record in the shape
# `treehouse status --json` emits, nested `processes` array included, so the
# parser under test is fed the real record shape rather than a flattened one.
pool_json() {
  local path=$1 status=$2 holder=${3:-}
  if [ -n "$holder" ]; then
    printf '[{"name":"1","path":"%s","status":"%s","lease_id":"deadbeef","lease_holder":"%s","holder_gone":true,"processes":[{"pid":4321,"name":"zsh"}]}]\n' \
      "$path" "$status" "$holder"
  else
    printf '[{"name":"1","path":"%s","status":"%s","processes":[]}]\n' "$path" "$status"
  fi
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

# (d) The task's own endpoint is still alive. Adopting would put a second agent
# in a checkout an agent is already working in, so the spawn must not adopt.
# The recorded endpoint lives in a different session from the one this spawn
# creates its window in, which is what keeps the unrelated duplicate-window
# refusal out of the way and leaves the liveness precondition as the only thing
# deciding the outcome.
test_live_own_endpoint_refuses_adoption() {
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
  expect_code 0 "$status" "a live-endpoint task should still lease normally: $out"
  assert_not_contains "$out" "re-entering its own recorded worktree" \
    "a task whose own endpoint is alive must never adopt its recorded worktree"
  assert_grep "get --lease --lease-holder fm-$id" "$TREEHOUSE_LOG" \
    "a live-endpoint task did not fall back to the lease path"
  pass "a task whose own endpoint is still alive never adopts its recorded worktree"
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
test_live_own_endpoint_refuses_adoption
test_abort_never_returns_an_adopted_lease
test_sibling_ownership_still_refuses_an_adopted_path

echo "# all fm-spawn-worktree-adopt tests passed"
