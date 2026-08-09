#!/usr/bin/env bash
# tests/fm-spawn-worktree-ownership.test.sh - worktree ownership regressions
# for bin/fm-spawn.sh (issues #1573, #1924).
#
# Covers, with a fake tmux/treehouse world and real isolated git worktrees:
#   - lease-based worktree acquisition: when the fake treehouse's `get --help`
#     advertises --lease, the SPAWN SCRIPT runs
#     `treehouse get --lease --lease-holder fm-<id>` and cd's the pane into the
#     leased path, so the pool durably records the owner (#1924);
#   - the loud fallback to the historical pane-typed bare `treehouse get` when
#     the installed treehouse lacks --lease;
#   - the sibling-ownership guard: a spawn refuses a worktree another LIVE
#     task's state/<id>.meta already records, keeps its just-acquired lease
#     held to shield the incumbent, and does not repair anything (#1573).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-ownership)

# Fake tmux: new-window prints a stable window id, kill-window and the
# pane-path query are observable, and list-windows reports FM_FAKE_WINDOW_LIST
# so a sibling's recorded window can classify as present. The pane-path query
# returns FM_FAKE_PANE_PATH; '#{pane_current_command}' returns
# FM_FAKE_PANE_COMMAND so a listed sibling window reads as a live agent.
make_ownership_fakebin() {
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
    [ -z "${FM_FAKE_WINDOW_LIST:-}" ] || printf '%s\n' "$FM_FAKE_WINDOW_LIST"
    exit 0
    ;;
  new-window) printf '%s\n' "${FM_FAKE_WINDOW_ID:-@41}"; exit 0 ;;
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
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_WT:-}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_ownership_case <name> <id> builds a home, a primary project with a real
# linked worktree, and the fake toolchain. Echoes a |-joined record.
make_ownership_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_ownership_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_ownership_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
  TREEHOUSE_LOG="$CASE_DIR/treehouse.log"
  TMUX_LOG="$CASE_DIR/tmux.log"
  : > "$TREEHOUSE_LOG"
  : > "$TMUX_LOG"
}

run_ownership_spawn() {  # <id> [extra env as VAR=val words before --]
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

# (a) A lease-capable treehouse makes the SCRIPT acquire the worktree with the
# task-id holder, and the pane just enters the leased path.
test_lease_get_uses_task_holder() {
  local rec id out status
  id=own-lease-a1
  rec=$(make_ownership_case lease-get "$id")
  read_ownership_record "$rec"

  out=$(run_ownership_spawn "$id" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_WT="$WT_DIR" \
    FM_FAKE_PANE_PATH="$WT_DIR")
  status=$?
  expect_code 0 "$status" "lease-based spawn should succeed: $out"
  assert_contains "$out" "spawned $id" "lease-based spawn did not report success"
  assert_grep "get --lease --lease-holder fm-$id" "$TREEHOUSE_LOG" \
    "spawn did not run treehouse get --lease with the fm-<task-id> holder"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the leased worktree"
  assert_not_contains "$out" "lacks --lease" \
    "lease-capable spawn wrongly printed the fallback warning"
  pass "a lease-capable treehouse is driven by the script with holder fm-<task-id>"
}

# (b) Without --lease support the spawn falls back to the pane-typed bare get,
# with a loud warning, and the script itself never runs treehouse get.
test_fallback_without_lease_warns() {
  local rec id out status
  id=own-fallback-b2
  rec=$(make_ownership_case lease-fallback "$id")
  read_ownership_record "$rec"

  out=$(run_ownership_spawn "$id" FM_FAKE_PANE_PATH="$WT_DIR")
  status=$?
  expect_code 0 "$status" "fallback spawn should succeed: $out"
  assert_contains "$out" "lacks --lease" \
    "fallback spawn did not warn that the pool cannot record ownership"
  assert_no_grep "get --lease" "$TREEHOUSE_LOG" \
    "fallback spawn must not run a lease get from the script"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "fallback spawn did not record the pane-settled worktree"
  pass "a treehouse without --lease falls back to the pane-typed get with a loud warning"
}

# (c) A worktree recorded by another LIVE task's meta is refused, nothing is
# repaired, and the just-acquired lease is kept held to shield the incumbent.
test_sibling_ownership_refusal() {
  local rec id out status marker
  id=own-sibling-c3
  rec=$(make_ownership_case sibling-guard "$id")
  read_ownership_record "$rec"
  fm_write_meta "$HOME_DIR/state/incumbent.meta" \
    "window=firstmate:fm-incumbent" \
    "endpoint_task_id=incumbent" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  marker="$WT_DIR/uncommitted-incumbent-edit"
  printf 'unlanded work\n' > "$marker"

  out=$(run_ownership_spawn "$id" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_WT="$WT_DIR" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_WINDOW_LIST=fm-incumbent FM_FAKE_PANE_COMMAND=codex)
  status=$?
  expect_code 1 "$status" "spawn into a live sibling's worktree should refuse"
  assert_contains "$out" "live task incumbent already records as its worktree" \
    "refusal did not name the incumbent task"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn must not record meta"
  assert_present "$marker" "refusal must not touch the incumbent's uncommitted work"
  assert_contains "$out" "is left held (holder fm-$id)" \
    "sibling refusal did not report keeping the acquired lease held"
  assert_no_grep "return --force $WT_DIR" "$TREEHOUSE_LOG" \
    "sibling refusal must NOT return the lease (a forced return would reset the incumbent's checkout)"
  pass "a live sibling's recorded worktree is refused, unrepaired, with the shielding lease kept held"
}

# (c2) A DEAD sibling's stale meta must not block a legitimate reuse: the fake
# session lists no fm-incumbent window, so the endpoint is authoritatively
# missing and the spawn proceeds.
test_dead_sibling_does_not_block() {
  local rec id out status
  id=own-deadsib-c4
  rec=$(make_ownership_case sibling-dead "$id")
  read_ownership_record "$rec"
  fm_write_meta "$HOME_DIR/state/incumbent.meta" \
    "window=firstmate:fm-incumbent" \
    "endpoint_task_id=incumbent" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_ownership_spawn "$id" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_WT="$WT_DIR" \
    FM_FAKE_PANE_PATH="$WT_DIR")
  status=$?
  expect_code 0 "$status" "a dead sibling's stale meta must not block reuse: $out"
  assert_contains "$out" "spawned $id" "reuse over a dead sibling did not report success"
  pass "a dead sibling's stale meta does not block a legitimate worktree reuse"
}

test_lease_get_uses_task_holder
test_fallback_without_lease_warns
test_sibling_ownership_refusal
test_dead_sibling_does_not_block

echo "# all fm-spawn-worktree-ownership tests passed"
