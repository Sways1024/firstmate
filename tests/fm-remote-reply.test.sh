#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" "$CLAIMS"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
# The recorded worker pid is the serving child, not its restart supervisor, so
# stopping that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -d "$TMP_ROOT/e2e/parent" ]; then
    FM_HOME="$TMP_ROOT/e2e/parent" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/e2e/claims" \
      "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fi
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"
: > "$REMOTE/state/parent-replies.status"
SOURCE_BEFORE="$TMP_ROOT/source-before"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_BEFORE"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

wait_for() {
  local path=$1
  for _ in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=0" "remote reply source was not armed at the empty cursor"

remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-one.out" 2>&1 &
RUNNER=$!
wait_for "$CLAIMS/$SID.claim" || fail "process-event runner never claimed the remote reply source"
printf 'done [corr=0123456789abcdef]: build verified (data/reply/report.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
wait "$RUNNER" || fail "remote reply source failed to capture its first delta"
RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null)
if [ -z "$RESULT" ]; then
  printf 'runner output:\n%s\n' "$(cat "$TMP_ROOT/start-one.out")" >&2
  fail "the remote reply delta was not durably captured"
fi
assert_grep 'done [corr=0123456789abcdef]' "$RESULT" "captured delta lost the correlated status line"
assert_grep "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue" "runner did not publish the normalized remote-reply event"
assert_no_grep 'build verified' "$PARENT/state/.wake-queue" "reply payload leaked into the event queue"
cmp -s "$SOURCE_BEFORE" "$REMOTE/state/parent-replies.status" \
  && fail "fixture did not append the expected source line"
SOURCE_AFTER="$TMP_ROOT/source-after"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_AFTER"
pass "a blocking non-destructive remote delta reaches durable process-event capture"

# The runner applies a captured result through this adapter itself, so the reply
# is already mirrored, acknowledged, and the next source re-armed before any
# handler runs. That is the primary guarantee; assert it before exercising the
# handler's own path below.
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" \
  "the captured reply was not applied to the parent status stream at capture"
assert_present "$PARENT/state/procevent-inbox/$SID.1.handled" \
  "the applied capture was left unacknowledged"
assert_present "$PARENT/state/procevent/$SID.source" \
  "applying the capture left the relay unarmed for the next delta"
[ "$(cat "$PARENT/state/procevent-inbox/$SID.1.via-status" 2>/dev/null)" = ios.status ] \
  || fail "a clean automatic apply was not recorded as announced via the parent status log"
pass "a captured delta is applied, acknowledged, re-armed, and recorded as announced via its status log"

# Now the handler's own retry path, from the state a crash between applying and
# acknowledging leaves behind: the acknowledgement is gone and re-arming fails.
rm -f "$PARENT/state/procevent-inbox/$SID.1.handled"
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
set +e
remote_env "$ADAPTER" handle ios 1 "$RESULT" > "$TMP_ROOT/handle-arm-fail.out" 2>&1
handle_arm_rc=$?
set -e
[ "$handle_arm_rc" -ne 0 ] || fail "reply handling acknowledged a result whose re-arm failed"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "failed re-arm lost the ingested reply"
assert_grep 'ingested: ios appended=0' "$TMP_ROOT/handle-arm-fail.out" "failed re-arm did not replay the committed reply"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$reconcile_out" 'published=1' "failed re-arm did not leave the result eligible for retry"
out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "retried reply ingest was not idempotent"
assert_contains "$out" 'handled: remote-reply-ios 1' "captured generation was not acknowledged"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "parent status did not receive the correlated reply"
assert_grep 'data/remote-secondmates/ios/data/reply/report.md' "$PARENT/state/ios.status" "remote document pointer was not rewritten locally"
cmp -s "$REMOTE/data/reply/report.md" "$PARENT/data/remote-secondmates/ios/data/reply/report.md" \
  || fail "the path-confined remote document copy is not byte-identical"
cmp -s "$SOURCE_AFTER" "$REMOTE/state/parent-replies.status" \
  || fail "handling consumed or rewrote the remote append-only log"
expected_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$expected_offset" "$PARENT/state/remote-replies/ios.cursor" "reply cursor did not advance to the committed delta"
pass "ingest appends one validated line, fetches its document, and advances the cursor"

out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "replayed result was not deduplicated"
assert_contains "$out" 'already-handled: remote-reply-ios 1' "replayed generation was not acknowledged idempotently"
[ "$(grep -cF 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replayed ingest duplicated the parent status line"
pass "replayed capture has one deduplicated append and one durable handling identity"

printf 'working [corr=1111111111111111]: second generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "second reply generation was not captured"
RESULT_TWO="$PARENT/state/procevent-inbox/$SID.2.result"
# The runner already applied and acknowledged this capture. Drop that genuine
# acknowledgement and put an unsafe one in its place, so the handler's refusal
# to trust a non-regular marker stays under test.
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
ln -s "$TMP_ROOT/missing-handled-marker" "$PARENT/state/procevent-inbox/$SID.2.handled"
set +e
remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO" > "$TMP_ROOT/handle-two-unacked.out" 2>&1
handle_two_rc=$?
set -e
[ "$handle_two_rc" -ne 0 ] || fail "second generation acknowledged through an unsafe handled marker"
assert_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" "unacknowledged generation was not ingested"
printf 'done [corr=2222222222222222]: third generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "third reply generation was not captured"
RESULT_THREE="$PARENT/state/procevent-inbox/$SID.3.result"
remote_env "$ADAPTER" handle ios 3 "$RESULT_THREE" >/dev/null \
  || fail "third reply generation was not handled"
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
out=$(remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO")
assert_contains "$out" 'ingested: ios appended=0' "earlier generation did not replay from its durable ingestion receipt"
assert_contains "$out" 'handled: remote-reply-ios 2' "earlier generation remained unacknowledged after later cursor advancement"
[ "$(grep -cF 'working [corr=1111111111111111]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "earlier generation replay duplicated its parent status"
pass "later generations cannot invalidate an unacknowledged ingested result"

# The channel mirrors the remote mate's content-bearing status lines at most once
# while omitting blank separators. A remote mate's own progress line and a NEWLY
# raised needs-decision carry no corr= by charter contract, and a delta carrying
# them alongside a correlated answer must ingest whole: every content-bearing
# line reaches the parent stream, the new decision reaches the parent's
# open-decision fold, the correlated line still settles its pending-reply record,
# and the cursor advances so the channel cannot wedge on a line it once refused.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
PENDING_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'audit the release chain')
[ -n "$PENDING_CORR" ] || fail "could not create the parent pending-reply record"
fm_pending_reply_mark_delivered "$PARENT/state" "$PENDING_CORR" \
  || fail "could not mark the pending-reply request delivered"
{
  printf 'working [key=version-audit]: family --version audit complete (data/reply/report.md)\n'
  printf 'needs-decision [key=rough-cut-version]: implement --version or retire the tool\n'
  printf 'done [corr=%s]: release chain audited\n' "$PENDING_CORR"
} >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the mirrored status stream was not captured"
RESULT_FOUR="$PARENT/state/procevent-inbox/$SID.4.result"
remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR" > "$TMP_ROOT/handle-mirror.out" 2>&1 \
  || fail "an uncorrelated status line stopped the delta: $(cat "$TMP_ROOT/handle-mirror.out")"
assert_grep 'working [key=version-audit]' "$PARENT/state/ios.status" "an uncorrelated progress line never reached the parent stream"
assert_grep 'needs-decision [key=rough-cut-version]' "$PARENT/state/ios.status" "a newly raised remote decision never reached the parent stream"
assert_grep "done [corr=$PENDING_CORR]" "$PARENT/state/ios.status" "the correlated answer sharing the delta was lost"
mirror_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$mirror_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past an uncorrelated line"
pass "the remote status and decision model mirrors and the cursor advances"

# The newly raised decision must be indistinguishable from a local mate's, so the
# shared fold - not this adapter - decides it is open.
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
OPEN=$(status_open_decisions "$PARENT/state/ios.status")
printf '%s' "$OPEN" | grep -q '^rough-cut-version	needs-decision	' \
  || fail "the remote mate's new decision did not surface as open to the parent: $OPEN"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$PENDING_CORR" phase)" = resolved ] \
  || fail "the correlated answer in the same delta did not settle its pending-reply record"
pass "a remote mate's new decision folds open exactly as a local mate's does"

# Ingesting the same generation again is idempotent: no duplicated lines and no
# cursor movement, so a replay can never wedge or double-count the stream.
remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR" >/dev/null 2>&1 || true
[ "$(grep -cF 'needs-decision [key=rough-cut-version]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replaying the mirrored delta duplicated the new decision"
assert_grep "offset=$mirror_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "replaying the mirrored delta moved the cursor"
pass "a replayed mirrored delta is idempotent in both the stream and the cursor"

# Bytes crossing a machine boundary are normalized, never dropped: a control
# character cannot make the parent's status file unsafe and cannot stop the
# stream either.
printf 'blocked [key=ctl]: escape \033[31mhere\033[0m bell \007 caf\xc3\xa9 end\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the control-character line was not captured"
RESULT_FIVE="$PARENT/state/procevent-inbox/$SID.5.result"
remote_env "$ADAPTER" handle ios 5 "$RESULT_FIVE" >/dev/null 2>&1 \
  || fail "a control character stopped the stream"
assert_grep 'blocked [key=ctl]: escape ?[31mhere' "$PARENT/state/ios.status" \
  "the control-character line was not mirrored in normalized form"
[ -z "$(LC_ALL=C tr -d '\11\12\40-\176\200-\377' < "$PARENT/state/ios.status")" ] \
  || fail "a control byte reached the parent status file"
assert_grep "$(printf 'caf\xc3\xa9 end')" "$PARENT/state/ios.status" \
  "normalization mangled a UTF-8 note a local secondmate could have written"
ctl_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$ctl_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a control-character line"
pass "transported control bytes are normalized in place and never stop the stream"

printf 'status=delta\n' >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the header-collision line was not captured"
RESULT_SIX="$PARENT/state/procevent-inbox/$SID.6.result"
remote_env "$ADAPTER" handle ios 6 "$RESULT_SIX" >/dev/null 2>&1 \
  || fail "a payload protocol-field name stopped the stream"
assert_grep 'status=delta' "$PARENT/state/ios.status" \
  "the payload protocol-field line did not reach the parent stream"
collision_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$collision_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a payload protocol-field line"
pass "payload protocol-field names cannot collide with transport metadata"

printf 'working [key=nul-byte]: before\000after\n' >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the NUL-bearing line was not captured"
RESULT_SEVEN="$PARENT/state/procevent-inbox/$SID.7.result"
remote_env "$ADAPTER" handle ios 7 "$RESULT_SEVEN" >/dev/null 2>&1 \
  || fail "a NUL byte stopped the stream"
assert_grep 'working [key=nul-byte]: before?after' "$PARENT/state/ios.status" \
  "the NUL byte was not normalized in place"
nul_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$nul_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a NUL-bearing line"
pass "NUL bytes are normalized in place before shell line processing"

printf '# Retryable remote answer\n' > "$REMOTE/data/reply/retry.md"
printf 'done [key=retry-document]: retry local storage (data/reply/retry.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
# Obstruct local document storage BEFORE the capture, so the runner's own
# automatic application fails for real. That is the documented fallback: a
# capture whose application does not complete stays unacknowledged and
# uncommitted, and the handler finishes it once storage recovers.
retry_destination="$PARENT/data/remote-secondmates/ios/data/reply/retry.md"
retry_decoy="$TMP_ROOT/retry-decoy.md"
printf 'local decoy\n' > "$retry_decoy"
ln -s "$retry_decoy" "$retry_destination"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the retryable document line was not captured"
RESULT_EIGHT="$PARENT/state/procevent-inbox/$SID.8.result"
assert_absent "$PARENT/state/procevent-inbox/$SID.8.handled" \
  "a capture whose automatic application failed was acknowledged anyway"
assert_absent "$PARENT/state/procevent-inbox/$SID.8.via-status" \
  "a capture whose automatic application failed was recorded as announced via the status log"
retry_cursor_before=$(cat "$PARENT/state/remote-replies/ios.cursor")
set +e
remote_env "$ADAPTER" handle ios 8 "$RESULT_EIGHT" > "$TMP_ROOT/handle-local-document-failure.out" 2>&1
local_document_rc=$?
set -e
[ "$local_document_rc" -ne 0 ] || fail "local document storage failure committed the delta"
assert_grep 'could not store referenced remote document' "$TMP_ROOT/handle-local-document-failure.out" \
  "local document storage failure was misclassified as remote refusal"
[ "$(cat "$PARENT/state/remote-replies/ios.cursor")" = "$retry_cursor_before" ] \
  || fail "local document storage failure advanced the cursor"
assert_no_grep 'done [key=retry-document]' "$PARENT/state/ios.status" \
  "local document storage failure mirrored an undelivered line"
assert_no_grep 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "local document storage failure raised a permanent remote refusal"
rm -f "$retry_destination"
remote_env "$ADAPTER" handle ios 8 "$RESULT_EIGHT" >/dev/null \
  || fail "the document delta did not succeed after local storage recovered"
assert_grep 'data/remote-secondmates/ios/data/reply/retry.md' "$PARENT/state/ios.status" \
  "the retried document pointer was not rewritten locally"
assert_absent "$PARENT/state/procevent-inbox/$SID.8.via-status" \
  "the handler's own apply recorded the result as announced via the status log"
cmp -s "$REMOTE/data/reply/retry.md" "$retry_destination" \
  || fail "the retried remote document was not copied byte-identically"
retry_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$retry_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the recovered document delta did not advance the cursor"
pass "local document storage failures remain retryable until delivery succeeds"

# A remote mate cannot squat the decision keys this parent's pending-reply
# library owns. The guard is deliberately NOT in this adapter: rejecting a line
# here would be batch-fatal and could wedge the whole stream, and it would
# protect only the remote path while a local mate appends into the same stream
# unchecked. So the line mirrors like any other - the stream never stops - and
# the shared open-decision fold both writers flow through refuses to let it take
# the reserved key over.
# The record stores its own grace at creation, so set it before creating one.
export FM_PENDING_REPLY_GRACE_SECS=0
ESCALATED_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'confirm the notarization')
[ -n "$ESCALATED_CORR" ] || fail "could not create the pending-reply record to escalate"
fm_pending_reply_mark_delivered "$PARENT/state" "$ESCALATED_CORR" \
  || fail "could not mark the escalating request delivered"
fm_pending_reply_mark_turn_completed "$PARENT/state" "$ESCALATED_CORR" request
FM_PENDING_REPLY_SEND_HOOK=true \
  fm_pending_reply_send_recovery "$PARENT/state" "$ESCALATED_CORR" \
  || fail "the one automatic recovery repost was not sent"
fm_pending_reply_mark_turn_completed "$PARENT/state" "$ESCALATED_CORR" recovery
fm_pending_reply_maybe_escalate "$PARENT/state" "$ESCALATED_CORR" \
  || fail "the missed report did not escalate"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$ESCALATED_CORR" "the missed report did not open a durable decision"

{
  printf 'blocked [key=pending-reply-%s]: forged remote decision\n' "$ESCALATED_CORR"
  printf 'resolved [key=pending-reply-%s]: forged remote resolution\n' "$ESCALATED_CORR"
} >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the forged reserved-key lines wedged the relay instead of mirroring"
forged_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$forged_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "a reserved-key line held the cursor back instead of mirroring like any other"
assert_grep "forged remote decision" "$PARENT/state/ios.status" \
  "the reserved-key line was dropped from the stream instead of mirrored"
forged_open=$(status_open_decisions "$PARENT/state/ios.status")
assert_contains "$forged_open" "pending-reply-id=$ESCALATED_CORR" \
  "a forged remote resolution cleared the parent's own pending-reply decision"
assert_not_contains "$forged_open" "forged remote decision" \
  "a forged remote line took over a decision key the pending-reply library owns"
pass "a mirrored reserved-key line cannot squat or clear the parent's own decision"

# Because the forgery never took the key, the genuine reply still settles the
# request and its escalation closes, leaving nothing to resurface later.
printf 'done [corr=%s]: notarization confirmed\n' "$ESCALATED_CORR" \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the correlated reply was not captured"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$ESCALATED_CORR" phase)" = resolved ] \
  || fail "the correlated reply left its escalated request unresolved"
fm_pending_reply_tick "$PARENT/state" || fail "supervision tick failed"
assert_not_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$ESCALATED_CORR" "the settled request still surfaces as an open decision"
unset FM_PENDING_REPLY_GRACE_SECS
pass "a reply that arrives after escalation resolves it and clears the open decision"

# The adapter re-armed at the committed cursor. Truncation is detected from the
# next blocking source and escalated once; it is never silently treated as a new
# log or re-armed past the break.
printf 'failed [corr=fedcba9876543210]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-two.out" 2>&1 &
RUNNER=$!
wait "$RUNNER" || fail "continuity break was not captured as a structured result"
RESULT_ELEVEN=$(find "$PARENT/state/procevent-inbox" -name "$SID.11.result" -print -quit)
[ -n "$RESULT_ELEVEN" ] || fail "continuity break produced no durable result"
[ "$(remote_env "$ADAPTER" classify "$RESULT_ELEVEN")" = continuity-broken ] \
  || fail "truncated source was not classified as a continuity break"
set +e
remote_env "$ADAPTER" handle ios 11 "$RESULT_ELEVEN" > "$TMP_ROOT/handle-nine.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "continuity handling returned an unexpected status: $handle_rc"
assert_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "continuity break did not escalate"
assert_absent "$PARENT/state/procevent/$SID.source" "continuity break was re-armed without an operator rebase"
assert_absent "$PARENT/state/procevent-inbox/$SID.11.via-status" \
  "a continuity break was recorded as announced via the status log"
remote_env "$ADAPTER" ingest ios "$RESULT_ELEVEN" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "continuity replay duplicated the escalation"
pass "truncation is detected, escalated once, and not silently rebased"

rm -f "$PARENT/state/procevent-inbox/$SID.11.handled"
if remote_env "$ADAPTER" retire ios > "$TMP_ROOT/retire-pending.out" 2>&1; then
  fail "remote reply retirement accepted an unhandled captured result"
fi
assert_grep 'unhandled captured result' "$TMP_ROOT/retire-pending.out" \
  "remote reply retirement did not explain its pending-result refusal"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "refused retirement left the reply source running past its pending-result check"
remote_env "$ADAPTER" handle ios 11 "$RESULT_ELEVEN" >/dev/null 2>&1 || [ "$?" -eq 3 ] \
  || fail "pending continuity result could not be acknowledged after retirement refusal"
touch "$PARENT/state/remote-replies/ios.transport-lost" "$PARENT/state/remote-replies/ios.liveness-checked" \
  "$PARENT/state/remote-replies/ios.liveness-relaunched"
remote_env "$ADAPTER" retire ios >/dev/null
assert_absent "$PARENT/state/remote-replies/ios.cursor" "adapter retirement left its cursor"
assert_absent "$PARENT/state/remote-replies/ios.transport-lost" "adapter retirement left its transport-lost marker"
assert_absent "$PARENT/state/remote-replies/ios.liveness-checked" "adapter retirement left its liveness clock"
assert_absent "$PARENT/state/remote-replies/ios.liveness-relaunched" "adapter retirement left its relaunch counter"
pass "remote reply retirement quiesces and refuses unhandled captured results"

# --- mid-session liveness: the relay's recovery after SSH failure ----------
# A copied code root with stub fm-on.sh and fm-spawn.sh isolates the relaunch
# decision: the stubs answer the readiness doctor, the endpoint state probe, and
# the delta poll from scenario files, and log every remote call and spawn.
LROOT="$TMP_ROOT/liveness-root"
LHOME="$TMP_ROOT/liveness-home"
LIVE="$TMP_ROOT/liveness-scenario"
mkdir -p "$LROOT" "$LHOME/state" "$LHOME/data" "$LIVE"
cp -R "$ROOT/bin" "$LROOT/bin"
printf 'fixture\n' > "$LROOT/AGENTS.md"
cat > "$LROOT/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf 'on %s\n' "$*" >> "$FM_FAKE_LIVE/calls.log"
[ ! -f "$FM_FAKE_LIVE/host-down" ] || exit 255
case "$2" in
  fm-remote-doctor.sh)
    if [ -f "$FM_FAKE_LIVE/readiness-gap" ]; then
      printf 'check linger=human: lingering is not enabled for fm\n'
      exit 1
    fi
    printf 'ok: remote second-mate readiness confirmed on this host\n'
    ;;
  fm-remote-secondmate-control.sh)
    case "$3" in
      state)
        [ ! -f "$FM_FAKE_LIVE/probe-rc" ] || exit "$(cat "$FM_FAKE_LIVE/probe-rc")"
        cat "$FM_FAKE_LIVE/state"
        ;;
      route) printf 'backend=herdr\n' ;;
    esac
    ;;
  fm-remote-delta-read.sh) exit "$(cat "$FM_FAKE_LIVE/poll-rc" 2>/dev/null || printf 75)" ;;
esac
SH
cat > "$LROOT/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >> "$FM_FAKE_LIVE/calls.log"
[ ! -f "$FM_FAKE_LIVE/spawn-fail" ] || { printf 'remote host-local secondmate launch failed\n' >&2; exit 1; }
[ ! -f "$FM_FAKE_LIVE/spawn-unknown" ] || { printf 'error: remote secondmate is unavailable or launch completion is unknown\n' >&2; exit 255; }
[ ! -f "$FM_FAKE_LIVE/spawn-revives" ] || printf 'alive\n' > "$FM_FAKE_LIVE/state"
SH
chmod +x "$LROOT/bin/fm-on.sh" "$LROOT/bin/fm-spawn.sh"
printf 'kind=secondmate\nwindow=2ndmate-ios\nremote_host=remote-mac\nharness=claude\n' > "$LHOME/state/ios.meta"
MARKER="$LHOME/state/remote-replies/ios.transport-lost"

live_source() { # runs one relay source pass; sets LIVE_RC
  : > "$LIVE/calls.log"
  set +e
  FM_HOME="$LHOME" FM_ROOT_OVERRIDE="$LROOT" FM_FAKE_LIVE="$LIVE" \
    FM_REMOTE_REPLY_LIVENESS_SECONDS="${LIVE_INTERVAL:-86400}" \
    "$LROOT/bin/fm-procevent-remote-reply.sh" source ios > "$LIVE/source.out" 2>&1
  LIVE_RC=$?
  set -e
}
spawn_count() { grep -c '^spawn ' "$LIVE/calls.log" || true; }

printf 'dead\n' > "$LIVE/state"
printf '255\n' > "$LIVE/poll-rc"
live_source
[ "$LIVE_RC" -eq 255 ] || fail "a failed poll did not keep its SSH status: $LIVE_RC"
assert_present "$MARKER" "an SSH failure did not mark the relay transport as lost"
assert_no_grep 'fm-remote-secondmate-control.sh' "$LIVE/calls.log" "a healthy relay probed liveness before any SSH failure"

touch "$LIVE/host-down"
live_source
[ "$LIVE_RC" -eq 255 ] || fail "recovery against an unreachable host did not report unknown transport: $LIVE_RC"
assert_present "$MARKER" "an unreachable host cleared the transport-lost marker"
assert_no_grep 'fm-remote-delta-read.sh' "$LIVE/calls.log" "the relay polled before the host answered"
[ "$(spawn_count)" -eq 0 ] || fail "a relaunch ran while the host was unreachable"
pass "an SSH failure arms recovery, and an unreachable host keeps it armed without relaunching"

rm -f "$LIVE/host-down"
printf '75\n' > "$LIVE/poll-rc"
live_source
[ "$LIVE_RC" -eq 75 ] || fail "the poll did not resume after recovery: $LIVE_RC"
assert_grep 'on ios fm-remote-doctor.sh' "$LIVE/calls.log" "recovery skipped the readiness gate"
assert_grep 'on ios fm-remote-secondmate-control.sh state ios' "$LIVE/calls.log" "recovery skipped the endpoint state probe"
[ "$(spawn_count)" -eq 1 ] || fail "a dead endpoint was not relaunched exactly once"$'\n'"$(cat "$LIVE/calls.log")"
assert_grep 'spawn ios --secondmate' "$LIVE/calls.log" "recovery did not relaunch through the secondmate spawn"
[ "$(grep -n '^spawn ' "$LIVE/calls.log" | cut -d: -f1)" -lt "$(grep -n 'fm-remote-delta-read.sh' "$LIVE/calls.log" | cut -d: -f1)" ] \
  || fail "the poll resumed before the relaunch decision"
assert_absent "$MARKER" "a completed recovery left the transport-lost marker"
live_source
[ "$(spawn_count)" -eq 0 ] || fail "a healthy relay relaunched again on the next poll"
assert_no_grep 'fm-remote-doctor.sh' "$LIVE/calls.log" "a healthy relay reran the readiness gate"
pass "once the host answers, a dead remote second mate is relaunched once and the poll resumes"

for endpoint_state in alive missing ambiguous unreadable unverified; do
  printf '%s\n' "$endpoint_state" > "$LIVE/state"
  touch "$MARKER"
  live_source
  case "$endpoint_state" in
    missing) [ "$(spawn_count)" -eq 1 ] || fail "a missing endpoint was not relaunched" ;;
    *) [ "$(spawn_count)" -eq 0 ] || fail "recovery relaunched an endpoint whose state was $endpoint_state" ;;
  esac
  assert_absent "$MARKER" "recovery kept its marker after a $endpoint_state probe"
done
pass "recovery relaunches only a dead or missing endpoint and never duplicates a live or uncertain one"

: > "$LHOME/state/ios.status"
printf 'dead\n' > "$LIVE/state"
touch "$LIVE/spawn-unknown" "$MARKER"
live_source
rm -f "$LIVE/spawn-unknown"
[ "$LIVE_RC" -eq 255 ] || fail "a relaunch whose completion is unknown resumed the poll: $LIVE_RC"
[ "$(spawn_count)" -eq 1 ] || fail "a dead endpoint was not relaunched before its completion went unknown"
assert_no_grep 'fm-remote-delta-read.sh' "$LIVE/calls.log" "the relay polled after a relaunch whose completion is unknown"
assert_present "$MARKER" "a relaunch whose completion is unknown disarmed recovery"
assert_no_grep 'remote-liveness-ios' "$LHOME/state/ios.status" "a relaunch whose completion is unknown was escalated as a failure"
printf 'alive\n' > "$LIVE/state"
live_source
[ "$LIVE_RC" -eq 75 ] || fail "the poll did not resume once the landed launch was found alive: $LIVE_RC"
[ "$(spawn_count)" -eq 0 ] || fail "recovery relaunched a launch that had landed"
assert_absent "$MARKER" "recovery stayed armed after finding the landed launch alive"
assert_no_grep 'remote-liveness-ios' "$LHOME/state/ios.status" "finding the landed launch alive raised a blocker"
pass "a relaunch whose completion is unknown keeps recovery armed without a blocker, and a landed launch clears it silently"

printf 'dead\n' > "$LIVE/state"
touch "$LIVE/spawn-fail" "$MARKER"
live_source
touch "$MARKER"
live_source
rm -f "$LIVE/spawn-fail"
[ "$(grep -cF 'blocked [key=remote-liveness-ios]: remote secondmate ios was not recovered' "$LHOME/state/ios.status")" -eq 1 ] \
  || fail "a failed relaunch was not escalated exactly once"
assert_grep 'respawn failed after remote endpoint dead on its configured host' "$LHOME/state/ios.status" \
  "the relaunch escalation did not carry its cause"
touch "$LIVE/readiness-gap" "$MARKER"
live_source
rm -f "$LIVE/readiness-gap"
[ "$(grep -c '^blocked \[key=remote-liveness-ios\]' "$LHOME/state/ios.status")" -eq 1 ] \
  || fail "a later outage raised a second liveness blocker while the first was still open"
printf 'resolved [key=remote-liveness-ios]: relaunched by hand\n' >> "$LHOME/state/ios.status"
touch "$LIVE/spawn-fail" "$MARKER"
live_source
rm -f "$LIVE/spawn-fail"
[ "$(grep -cF 'blocked [key=remote-liveness-ios]: remote secondmate ios was not recovered' "$LHOME/state/ios.status")" -eq 2 ] \
  || fail "a later outage failing the same way after the blocker was resolved raised no new blocker"
pass "the liveness blocker is raised once per outage and never again while it is still open"
: > "$LHOME/state/ios.status"
touch "$LIVE/readiness-gap" "$MARKER"
live_source
rm -f "$LIVE/readiness-gap"
[ "$(spawn_count)" -eq 0 ] || fail "recovery relaunched past a readiness gap"
assert_grep 'remote readiness failed on remote-mac: check linger=human:' "$LHOME/state/ios.status" \
  "a readiness gap during recovery was not escalated with its check"
assert_absent "$MARKER" "an escalated recovery kept retrying on every poll"
pass "a failed relaunch or readiness gap during recovery is escalated once instead of retried every poll"

# liveness_blocker_open: the shared decision fold's own reading of the blocker.
liveness_blocker_open() {
  bash -c '. "$1" && status_decision_open "$2" "$3"' _ "$ROOT/bin/fm-classify-lib.sh" \
    "$LHOME/state/ios.status" remote-liveness-ios
}
resolved_count() { grep -c '^resolved \[key=remote-liveness-ios\]' "$LHOME/state/ios.status" || true; }
liveness_blocker_open || fail "the readiness-gap blocker this case starts from is not open"
printf 'dead\n' > "$LIVE/state"
touch "$MARKER"
live_source
[ "$(spawn_count)" -eq 1 ] || fail "a dead endpoint behind an open blocker was not relaunched"
! liveness_blocker_open || fail "a relaunch that recovered the second mate left its liveness blocker open"
[ "$(resolved_count)" -eq 1 ] || fail "the recovering relaunch did not resolve its blocker exactly once"
touch "$LIVE/spawn-fail" "$MARKER"
live_source
rm -f "$LIVE/spawn-fail"
liveness_blocker_open || fail "a later failed relaunch did not raise a new blocker"
printf 'alive\n' > "$LIVE/state"
touch "$MARKER"
live_source
[ "$(spawn_count)" -eq 0 ] || fail "recovery relaunched an alive endpoint"
! liveness_blocker_open || fail "finding the second mate alive left its liveness blocker open"
[ "$(resolved_count)" -eq 2 ] || fail "finding the second mate alive did not resolve its blocker exactly once"
touch "$MARKER"
live_source
[ "$(resolved_count)" -eq 2 ] || fail "a successful check with no open blocker wrote a resolution"
pass "a later check that relaunches the second mate or finds it alive resolves an open liveness blocker, and is silent otherwise"

# --- mid-session liveness: a Herdr crash behind a healthy SSH link ---------
# No poll fails here, so the relay's own periodic endpoint probe is the only
# trigger. LIVE_INTERVAL=0 makes every source pass due once the clock started.
STAMP="$LHOME/state/remote-replies/ios.liveness-checked"
state_probes() { grep -c 'fm-remote-secondmate-control.sh state ios' "$LIVE/calls.log" || true; }
: > "$LHOME/state/ios.status"
rm -f "$MARKER" "$STAMP" "$LIVE/probe-rc"
printf '75\n' > "$LIVE/poll-rc"
printf 'dead\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
[ "$LIVE_RC" -eq 75 ] || fail "the first healthy pass did not poll: $LIVE_RC"
assert_present "$STAMP" "the first healthy pass did not start the liveness clock"
[ "$(state_probes)" -eq 0 ] || fail "the first healthy pass probed a second mate that was just launched or checked"
pass "the first healthy relay pass only starts the liveness clock"

LIVE_INTERVAL=0 live_source
[ "$LIVE_RC" -eq 75 ] || fail "the poll did not run after a healthy-link relaunch: $LIVE_RC"
[ "$(spawn_count)" -eq 1 ] || fail "a dead endpoint behind a healthy link was not relaunched once"$'\n'"$(cat "$LIVE/calls.log")"
assert_grep 'on ios fm-remote-doctor.sh' "$LIVE/calls.log" "the healthy-link relaunch skipped the readiness gate"
[ "$(grep -n '^spawn ' "$LIVE/calls.log" | cut -d: -f1)" -lt "$(grep -n 'fm-remote-delta-read.sh' "$LIVE/calls.log" | cut -d: -f1)" ] \
  || fail "the poll ran before the healthy-link relaunch decision"
assert_absent "$MARKER" "a healthy-link relaunch armed the lost-transport path"
assert_no_grep 'remote-liveness-ios' "$LHOME/state/ios.status" "a successful healthy-link relaunch wrote to the status stream"
printf 'alive\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
printf 'missing\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 1 ] || fail "a missing endpoint behind a healthy link was not relaunched"
pass "a dead or missing endpoint behind a healthy SSH link is relaunched through the shared check before the poll"

printf 'dead\n' > "$LIVE/state"
live_source
[ "$(state_probes)" -eq 0 ] || fail "the relay probed again inside its liveness interval"
[ "$(spawn_count)" -eq 0 ] || fail "the relay relaunched inside its liveness interval"
pass "the healthy-link probe runs at most once per liveness interval"

for endpoint_state in alive ambiguous unreadable unverified bogus; do
  printf '%s\n' "$endpoint_state" > "$LIVE/state"
  LIVE_INTERVAL=0 live_source
  [ "$(state_probes)" -eq 1 ] || fail "the healthy-link check did not probe exactly once for $endpoint_state"
  [ "$(spawn_count)" -eq 0 ] || fail "the healthy-link check relaunched an endpoint whose state was $endpoint_state"
  assert_no_grep 'fm-remote-doctor.sh' "$LIVE/calls.log" "a $endpoint_state probe with no open blocker ran the full check"
  [ "$LIVE_RC" -eq 75 ] || fail "a $endpoint_state probe kept the poll from running: $LIVE_RC"
done
printf 'dead\n' > "$LIVE/state"
printf '1\n' > "$LIVE/probe-rc"
LIVE_INTERVAL=0 live_source
rm -f "$LIVE/probe-rc"
[ "$(spawn_count)" -eq 0 ] || fail "the healthy-link check relaunched past an unreadable probe"
[ "$LIVE_RC" -eq 75 ] || fail "an unreadable probe kept the poll from running: $LIVE_RC"
pass "the healthy-link check leaves alive, ambiguous, unreadable, and unknown states alone"

touch "$LIVE/host-down"
LIVE_INTERVAL=0 live_source
[ "$LIVE_RC" -eq 255 ] || fail "an unreachable host did not keep the poll's SSH status: $LIVE_RC"
[ "$(spawn_count)" -eq 0 ] || fail "the healthy-link check relaunched while the host was unreachable"
assert_present "$MARKER" "an unreachable host did not arm the lost-transport path"
rm -f "$LIVE/host-down"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 1 ] || fail "the lost-transport path did not take over once the host answered"
assert_absent "$MARKER" "the lost-transport path kept its marker after recovering"
[ "$(state_probes)" -eq 1 ] || fail "the healthy-link probe ran on top of the lost-transport check"
pass "an unreachable host keeps the lost-transport path, which runs the check alone"

: > "$LHOME/state/ios.status"
total_spawns=0
touch "$LIVE/spawn-fail"
for _ in 1 2 3; do
  LIVE_INTERVAL=0 live_source
  total_spawns=$((total_spawns + $(spawn_count)))
done
rm -f "$LIVE/spawn-fail"
[ "$total_spawns" -eq 1 ] || fail "a failing healthy-link relaunch was attempted $total_spawns times in one outage"
[ "$(grep -cF 'blocked [key=remote-liveness-ios]: remote secondmate ios was not recovered after its endpoint was found dead while its host stayed reachable' "$LHOME/state/ios.status")" -eq 1 ] \
  || fail "a failed healthy-link relaunch was not escalated exactly once"$'\n'"$(cat "$LHOME/state/ios.status")"
liveness_blocker_open || fail "the healthy-link escalation is not open in the decision fold"
pass "a failed healthy-link relaunch is attempted once per outage and escalated once"

printf 'alive\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 0 ] || fail "finding the second mate alive behind an open blocker relaunched it"
! liveness_blocker_open || fail "finding the second mate alive left the healthy-link blocker open"
[ "$(resolved_count)" -eq 1 ] || fail "finding the second mate alive did not resolve its blocker exactly once"
LIVE_INTERVAL=0 live_source
[ "$(resolved_count)" -eq 1 ] || fail "a later alive probe with no open blocker wrote a resolution"
assert_no_grep 'fm-remote-doctor.sh' "$LIVE/calls.log" "a later alive probe with no open blocker ran the full check"
pass "an alive probe resolves a still-open liveness blocker and is silent otherwise"

printf 'dead\n' > "$LIVE/state"
touch "$LIVE/spawn-fail"
LIVE_INTERVAL=0 live_source
rm -f "$LIVE/spawn-fail"
liveness_blocker_open || fail "a new outage's failed relaunch did not raise a new blocker"
printf 'resolved [key=remote-liveness-ios]: fixed the host by hand\n' >> "$LHOME/state/ios.status"
touch "$LIVE/spawn-revives"
total_spawns=0
for _ in 1 2 3; do
  LIVE_INTERVAL=0 live_source
  total_spawns=$((total_spawns + $(spawn_count)))
done
rm -f "$LIVE/spawn-revives"
[ "$total_spawns" -eq 1 ] || fail "repeated healthy-link triggers relaunched $total_spawns times instead of once"
[ "$(grep -c '^blocked \[key=remote-liveness-ios\]' "$LHOME/state/ios.status")" -eq 2 ] \
  || fail "a relaunch after the captain resolved the blocker raised another blocker"
pass "a resolved blocker allows one more relaunch, and repeated triggers never duplicate a revived second mate"

RELAUNCHED="$LHOME/state/remote-replies/ios.liveness-relaunched"
died_again_count() { grep -cF 'blocked [key=remote-liveness-ios]: remote secondmate ios died again after its relaunch' "$LHOME/state/ios.status" || true; }
: > "$LHOME/state/ios.status"
printf 'dead\n' > "$LIVE/state"
total_spawns=0
for pass_number in 1 2 3 4; do
  LIVE_INTERVAL=0 live_source
  total_spawns=$((total_spawns + $(spawn_count)))
  [ "$LIVE_RC" -eq 75 ] || fail "pass $pass_number on a second mate that died again kept the poll from running: $LIVE_RC"
  if [ "$pass_number" -gt 1 ]; then
    assert_no_grep 'fm-remote-doctor.sh' "$LIVE/calls.log" "pass $pass_number on a second mate that died again ran the full check"
  fi
done
[ "$total_spawns" -eq 1 ] || fail "a second mate dead again after its healthy-link relaunch was relaunched $total_spawns times"
[ "$(died_again_count)" -eq 1 ] || fail "a second mate dead again after its relaunch was not escalated exactly once"$'\n'"$(cat "$LHOME/state/ios.status")"
[ "$(grep -c '^blocked \[key=remote-liveness-ios\]' "$LHOME/state/ios.status")" -eq 1 ] \
  || fail "further dead probes raised another liveness blocker"
assert_grep 'died again after its relaunch (endpoint dead while its host stayed reachable)' "$LHOME/state/ios.status" \
  "the died-again escalation did not name the endpoint state"
liveness_blocker_open || fail "the died-again escalation is not open in the decision fold"
pass "a second mate dead again after a healthy-link relaunch is relaunched once and escalated once"

printf 'resolved [key=remote-liveness-ios]: fixed the login by hand\n' >> "$LHOME/state/ios.status"
total_spawns=0
for _ in 1 2 3; do
  LIVE_INTERVAL=0 live_source
  total_spawns=$((total_spawns + $(spawn_count)))
done
[ "$total_spawns" -eq 1 ] || fail "a resolved died-again blocker allowed $total_spawns relaunches instead of one"
[ "$(died_again_count)" -eq 2 ] || fail "a second mate dead again after the resolved blocker's relaunch was not escalated once more"
liveness_blocker_open || fail "the second died-again escalation is not open in the decision fold"
pass "resolving a died-again blocker by hand allows exactly one more relaunch"

printf 'alive\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 0 ] || fail "finding the second mate alive behind a died-again blocker relaunched it"
! liveness_blocker_open || fail "finding the second mate alive left the died-again blocker open"
[ "$(resolved_count)" -eq 2 ] || fail "finding the second mate alive did not resolve the died-again blocker exactly once"
assert_absent "$RELAUNCHED" "finding the second mate alive left the relaunch counter set"
printf 'dead\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 1 ] || fail "a new outage after an alive probe was not relaunched once"
assert_present "$RELAUNCHED" "a successful healthy-link relaunch was not counted"
printf 'alive\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
assert_absent "$RELAUNCHED" "an alive probe with no open blocker left the relaunch counter set"
printf 'dead\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 1 ] || fail "a second mate found alive after its relaunch was not relaunched on its next outage"
[ "$(died_again_count)" -eq 2 ] || fail "a second mate found alive after its relaunch was escalated as dying again"
! liveness_blocker_open || fail "a relaunch after an alive probe left a liveness blocker open"
pass "an alive probe resolves the died-again blocker and resets the bound, so a new outage relaunches once again"

: > "$LHOME/state/ios.status"
printf 'alive\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
printf 'dead\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 1 ] || fail "the healthy-link relaunch this case starts from did not run"
assert_present "$RELAUNCHED" "the healthy-link relaunch this case starts from was not counted"
touch "$LIVE/spawn-fail" "$MARKER"
LIVE_INTERVAL=0 live_source
rm -f "$LIVE/spawn-fail"
assert_grep 'blocked [key=remote-liveness-ios]: remote secondmate ios was not recovered after its host became reachable again' \
  "$LHOME/state/ios.status" "the lost-transport path did not raise its liveness blocker"
liveness_blocker_open || fail "the lost-transport blocker is not open in the decision fold"
printf 'resolved [key=remote-liveness-ios]: fixed the host by hand\n' >> "$LHOME/state/ios.status"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 1 ] || fail "a hand-resolved lost-transport blocker did not allow exactly one more relaunch"$'\n'"$(cat "$LHOME/state/ios.status")"
[ "$(died_again_count)" -eq 0 ] || fail "a relaunch counted before a lost-transport blocker was escalated as dying again"
! liveness_blocker_open || fail "the relaunch after a hand-resolved lost-transport blocker left a blocker open"
pass "a lost-transport blocker carries the bound alone, so resolving it by hand allows exactly one more relaunch"

: > "$LHOME/state/ios.status"
touch "$RELAUNCHED"
printf 'blocked [key=remote-liveness-ios]: raised by another liveness check\n' >> "$LHOME/state/ios.status"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 0 ] || fail "a dead probe behind an open liveness blocker relaunched"
assert_absent "$RELAUNCHED" "a dead probe behind an open liveness blocker kept the relaunch counter"
printf 'resolved [key=remote-liveness-ios]: fixed by hand\n' >> "$LHOME/state/ios.status"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 1 ] || fail "a hand-resolved blocker raised while a relaunch was counted did not allow one more relaunch"
[ "$(died_again_count)" -eq 0 ] || fail "a hand-resolved blocker raised while a relaunch was counted was followed by a died-again blocker"
pass "any open liveness blocker clears the relaunch counter, so its hand resolution allows one more relaunch"

: > "$LHOME/state/ios.status"
printf 'alive\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
{
  printf 'blocked [key=remote-liveness-ios]: an earlier outage\n'
  printf 'working: progress that mentions [key=remote-liveness-ios] in passing\n'
  printf 'resolved [key=remote-liveness-ios]: fixed by hand\n'
  printf 'needs-decision [key=other-question]: an unrelated open decision\n'
  printf 'working: unrelated progress\n'
} >> "$LHOME/state/ios.status"
LIVE_INTERVAL=0 live_source
assert_no_grep 'fm-remote-doctor.sh' "$LIVE/calls.log" "an alive probe over a resolved earlier blocker ran the full check"
printf 'dead\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 1 ] || fail "a dead probe over a resolved earlier blocker was not relaunched"
{
  printf 'blocked [key=remote-liveness-ios]: raised again\n'
  printf 'working: later unrelated progress\n'
  printf 'resolved [key=other-question]: answered\n'
} >> "$LHOME/state/ios.status"
liveness_blocker_open || fail "the shared fold does not read the reopened blocker as open"
LIVE_INTERVAL=0 live_source
[ "$(spawn_count)" -eq 0 ] || fail "a dead probe relaunched behind a blocker reopened after resolved history"
printf 'alive\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
assert_grep 'on ios fm-remote-doctor.sh' "$LIVE/calls.log" "an alive probe behind a reopened blocker skipped the full check"
! liveness_blocker_open || fail "an alive probe left a blocker reopened after resolved history open"
[ "$(resolved_count)" -eq 2 ] || fail "an alive probe did not resolve a blocker reopened after resolved history exactly once"
pass "a resolved earlier blocker and unrelated decisions in the history do not change the liveness outcome"

mv "$LHOME/state/ios.meta" "$LHOME/state/ios.meta.saved"
printf 'kind=secondmate\nremote_host=remote-mac\nharness=claude\n' > "$LHOME/state/ios.meta"
printf 'dead\n' > "$LIVE/state"
LIVE_INTERVAL=0 live_source
[ "$(state_probes)" -eq 0 ] || fail "the healthy-link check probed a second mate with no launched endpoint record"
mv "$LHOME/state/ios.meta.saved" "$LHOME/state/ios.meta"
pass "the healthy-link check keeps the session-start sweep's launched-record scope"

# --- one wake per update ----------------------------------------------------
# End to end through the real runner, adapter, fake SSH, and watcher: a clean
# delta reaches firstmate as exactly one wake - the second mate's own status
# wake, as a local second mate's would - while a continuity break, a remote
# document that could not be fetched, and a delta that added no new line still
# arrive as their own process-event wake carrying the result's identity.
E2E="$TMP_ROOT/e2e"
EP="$E2E/parent"
ER="$E2E/remote"
ECLAIMS="$E2E/claims"
mkdir -p "$EP/data" "$EP/state" "$ER/state" "$ER/data/reply" "$ECLAIMS"
cat > "$EP/data/secondmates.md" <<EOF
- mac - Mac delivery (host: remote-mac; root: $ROOT; home: $ER; scope: Mac work; projects: alpha; added 2026-11-26)
EOF
: > "$ER/state/parent-replies.status"
e2e_env() {
  FM_HOME="$EP" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$ECLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}
ESID=$(e2e_env "$ADAPTER" source-id mac)
# Start the watcher itself as the background job, never a wrapper around it, so
# its pid is the one these helpers wait on and stop.
e2e_watch_start() {  # <out>; sets E2E_WATCH_PID
  FM_HOME="$EP" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$ECLAIMS" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
    FM_REMOTE_REPLY_WAIT_SECONDS=10 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$1" 2>/dev/null &
  E2E_WATCH_PID=$!
}
e2e_watch_stop() {
  kill "$E2E_WATCH_PID" 2>/dev/null || true
  wait "$E2E_WATCH_PID" 2>/dev/null || true
}
# One watcher cycle; it must exit on its own with one wake.
e2e_watch_once() {  # <out>
  local i=0
  e2e_watch_start "$1"
  while kill -0 "$E2E_WATCH_PID" 2>/dev/null && [ "$i" -lt 200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$E2E_WATCH_PID" 2>/dev/null; then
    e2e_watch_stop
    return 1
  fi
  wait "$E2E_WATCH_PID"
}
# A watcher that must stay quiet for <ticks> tenths of a second.
e2e_watch_quiet() {  # <out> <ticks>
  local i=0
  e2e_watch_start "$1"
  while [ "$i" -lt "$2" ]; do
    kill -0 "$E2E_WATCH_PID" 2>/dev/null || { wait "$E2E_WATCH_PID" 2>/dev/null; return 1; }
    sleep 0.1
    i=$((i + 1))
  done
  e2e_watch_stop
  kill -0 "$E2E_WATCH_PID" 2>/dev/null && fail "the quiet watcher outlived its stop"
  return 0
}
# Stop any runner a watcher's reconcile started, so the next remote append is
# captured exactly once, by e2e_capture.
e2e_quiesce() { e2e_env "$ROOT/bin/fm-procevent.sh" retire "$ESID" >/dev/null 2>&1 || true; }
e2e_capture() {
  e2e_env "$ADAPTER" arm mac >/dev/null || return 1
  e2e_env "$ROOT/bin/fm-procevent.sh" start "$ESID" >/dev/null 2>&1
}
e2e_drain() { e2e_env "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null; }

{
  printf 'needs-decision [key=mac-signing]: approve the signing identity\n'
  printf 'working: notarizing the build\n'
} >> "$ER/state/parent-replies.status"
e2e_capture || fail "the clean delta was not captured"
assert_present "$EP/state/procevent-inbox/$ESID.1.handled" "the clean delta was not applied at capture"
assert_grep "procevent remote-reply $ESID 1" "$EP/state/.wake-queue" \
  "the runner no longer published the clean delta's own wake at capture"
e2e_watch_once "$E2E/watch-clean.out" || fail "the clean delta never woke firstmate: $(cat "$E2E/watch-clean.out")"
[ "$(cat "$E2E/watch-clean.out")" = "signal: $EP/state/mac.status" ] \
  || fail "a clean remote update did not arrive as exactly one status wake: $(cat "$E2E/watch-clean.out")"
e2e_drain > "$E2E/drain-clean.out"
assert_no_grep "procevent:$ESID:1" "$E2E/drain-clean.out" "the clean delta's process-event wake still reached firstmate"
assert_grep 'OPEN DECISIONS' "$E2E/drain-clean.out" "the buried remote decision was not listed by the wake that carried it"
assert_grep '[key=mac-signing] needs-decision: approve the signing identity' "$E2E/drain-clean.out" \
  "the remote decision above a later progress line was not readable from the wake"
assert_grep 'working: notarizing the build' "$EP/state/mac.status" "the mirrored lines are not in the status log the wake names"
e2e_watch_quiet "$E2E/watch-clean-again.out" 30 \
  || fail "the clean delta woke firstmate a second time: $(cat "$E2E/watch-clean-again.out")"
pass "a clean remote update wakes firstmate once, as the second mate's status wake, with every line readable"

e2e_quiesce
printf 'done [key=missing-doc]: see data/reply/missing.md\n' >> "$ER/state/parent-replies.status"
e2e_capture || fail "the delta with an unfetchable document was not captured"
assert_grep 'blocked [key=remote-reply-document-mac]' "$EP/state/mac.status" \
  "the unfetchable document was not escalated"
assert_absent "$EP/state/procevent-inbox/$ESID.2.via-status" \
  "a delta with an unfetchable document was recorded as announced via the status log"
e2e_watch_once "$E2E/watch-doc.out" || fail "the unfetchable document never woke firstmate"
[ "$(cat "$E2E/watch-doc.out")" = "check: process-event result captured: procevent:$ESID:2" ] \
  || fail "an unfetchable document did not wake firstmate with the result's identity: $(cat "$E2E/watch-doc.out")"
e2e_drain >/dev/null
pass "a remote document that could not be fetched still wakes firstmate with the result's identity"

# The status wake for that escalation follows, as before; settle it so the
# next case starts from a quiet watcher.
e2e_watch_once "$E2E/watch-doc-status.out" || fail "the document escalation never woke firstmate"
e2e_drain >/dev/null

e2e_quiesce
printf 'needs-decision [key=mac-signing]: approve the signing identity\n' >> "$ER/state/parent-replies.status"
e2e_capture || fail "the delta that repeats an existing line was not captured"
assert_present "$EP/state/procevent-inbox/$ESID.3.handled" "the repeating delta was not applied at capture"
assert_absent "$EP/state/procevent-inbox/$ESID.3.via-status" \
  "a delta that added no new line was recorded as announced via the status log"
e2e_watch_once "$E2E/watch-dup.out" || fail "a delta that added no new line never woke firstmate"
[ "$(cat "$E2E/watch-dup.out")" = "check: process-event result captured: procevent:$ESID:3" ] \
  || fail "a delta that added no new line did not keep its own wake: $(cat "$E2E/watch-dup.out")"
e2e_drain >/dev/null
pass "a delta that added no new status line keeps its own process-event wake"

# Output the runner bounds is truncated before capture, so its committed payload
# digest no longer matches and the adapter refuses to apply it.
e2e_quiesce
printf 'done [key=oversized]: %s\n' "$(printf 'x%.0s' $(seq 1 400))" >> "$ER/state/parent-replies.status"
FM_PROCEVENT_MAX_OUTPUT_BYTES=420 e2e_capture || fail "the oversized delta was not captured"
assert_absent "$EP/state/procevent-inbox/$ESID.4.handled" "a bounded, truncated capture was acknowledged"
assert_absent "$EP/state/procevent-inbox/$ESID.4.via-status" \
  "a bounded, truncated capture was recorded as announced via the status log"
assert_no_grep 'done [key=oversized]' "$EP/state/mac.status" "a truncated capture was mirrored into the status log"
e2e_watch_once "$E2E/watch-oversized.out" || fail "the bounded oversized output never woke firstmate"
[ "$(cat "$E2E/watch-oversized.out")" = "check: process-event result captured: procevent:$ESID:4" ] \
  || fail "bounded oversized output did not wake firstmate with the result's identity: $(cat "$E2E/watch-oversized.out")"
e2e_drain >/dev/null
pass "bounded oversized output still wakes firstmate with the result's identity"

e2e_quiesce
printf 'failed: the remote log was replaced\n' > "$ER/state/parent-replies.status"
e2e_capture || fail "the continuity break was not captured"
assert_grep 'blocked [key=remote-reply-continuity-mac]' "$EP/state/mac.status" "the continuity break was not escalated"
assert_absent "$EP/state/procevent-inbox/$ESID.5.via-status" \
  "a continuity break was recorded as announced via the status log"
e2e_watch_once "$E2E/watch-continuity.out" || fail "the continuity break never woke firstmate"
[ "$(cat "$E2E/watch-continuity.out")" = "check: process-event result captured: procevent:$ESID:5" ] \
  || fail "a continuity break did not wake firstmate with the result's identity: $(cat "$E2E/watch-continuity.out")"
pass "a continuity break still wakes firstmate with the result's identity"

echo "ALL TESTS PASSED"
