# Local patches (Sways1024 fork)

`patched` = upstream HEAD `833a9a2` (2026-08-07) plus twenty-eight fixes on ten branches:

| Branch | Upstream issues | Fix |
| --- | --- | --- |
| `fix/spawn-lifecycle` | [#1573](https://github.com/kunchenguid/firstmate/issues/1573)/[#1924](https://github.com/kunchenguid/firstmate/issues/1924), [#1913](https://github.com/kunchenguid/firstmate/issues/1913), [#1818](https://github.com/kunchenguid/firstmate/issues/1818) | Spawns lease their worktree (`treehouse get --lease --lease-holder fm-<id>`) and refuse a live sibling's checkout — closes the data-loss window. Aborted spawns kill their tmux window and release the lease. Crewmates share the project's Claude auto-memory store. |
| `fix/supervision-wakes` | [#1897](https://github.com/kunchenguid/firstmate/issues/1897), [#1769](https://github.com/kunchenguid/firstmate/issues/1769), [#1792](https://github.com/kunchenguid/firstmate/issues/1792), [#1033](https://github.com/kunchenguid/firstmate/issues/1033) | PRs closed without merging produce a needs-decision wake instead of stranding the task. The wedge detector re-consults the busy contract and progress signals before escalating. Stale busy records contradicted by later status-log lines classify unknown. no-mistakes workers drive their own validation run. |
| `fix/herdr-daily-use` | [#883](https://github.com/kunchenguid/firstmate/issues/883), [#1011](https://github.com/kunchenguid/firstmate/issues/1011), [#1571](https://github.com/kunchenguid/firstmate/issues/1571) (gap A) | Composer glyph stripping is locale-safe (literal patterns, not byte counts) — under `LC_ALL=C` an idle composer no longer reads pending forever, which was the root feeder of the away-mode deferral wedge on herdr. The herdr events probe and socket lookup no longer EPIPE-spam stderr on every watcher start. Every harness Resume row carries the launch's autonomy flags/env (claude gains a Resume row); stuck-crewmate-recovery requires flag-carrying resumes and adds the restore-to-clone trust-dialog hazard. |
| `fix/herdr-operability` | [#1912](https://github.com/kunchenguid/firstmate/issues/1912)-adjacent (dialogs), workspace-label collision | Claude's two first-launch dialogs are documented with their exact options: the workspace-trust prompt preselects "Yes", but the bypass-permissions prompt preselects **"No, exit"**, so the blind `--key Enter` the skill used to recommend killed the crewmate before it read its brief. Firstmate resolves its own herdr container by a recorded exact workspace id (`state/.herdr-home-workspace`) checked against this home's label, so a captain's personal workspace that herdr auto-labeled `firstmate` from its directory name is neither adopted nor able to refuse spawns. The label check is what bounds that record: herdr restarts its workspace-id counter when a session is deleted and recreated under the same name, and nothing invalidates the file, so an id-only record written before such a recreate could name the workspace the captain happened to open first and place workers into it. One residual is knowingly left open: where two workspaces share the label, no record at all refuses the spawn outright, while a record whose id herdr has since reassigned to the captain's same-labeled workspace resolves it and places a task tab there, which is strictly worse than no record. Trusting the record only as the sole label match would close that and remove the feature with it, since the record would then merely confirm what the label lookup already resolved. The record helpers in `bin/backends/herdr.sh` own the full contract, including the three bindings measured against herdr 0.8.0 and rejected, and a regression test pins the residual. Reading and writing that record are also quiet again: both suppressions sat after the redirection they were meant to cover, so an unreadable record printed a shell error on every container resolution and a read-only state directory printed one from a writer that is documented never to fail a spawn. |
| `fix/herdr-followups` | [#730](https://github.com/kunchenguid/firstmate/issues/730), [#1337](https://github.com/kunchenguid/firstmate/issues/1337), [#1571](https://github.com/kunchenguid/firstmate/issues/1571) (gap B), [#1575](https://github.com/kunchenguid/firstmate/issues/1575), [#1859](https://github.com/kunchenguid/firstmate/issues/1859), [#1912](https://github.com/kunchenguid/firstmate/issues/1912) | Lab helper places `--session` before a `--` child-argv delimiter (isolation no longer silently degrades; production wrapper hardened identically). Per-home workspace find+create serializes under a session+label mint lock, and the presentation-lock wait was raised 5s→30s (`FM_SPAWN_HERDR_PRESENTATION_LOCK_ATTEMPTS`) so concurrent abort cleanup serializes instead of falling back flat. Both landed only partly: the mint lock fell through to the unserialized path whenever its own lock was unusable, and the raise reached one of the four waiters. `fm/herdr-lock-fix-t2` below owns both contracts now. Journal retirement rides the confirmed-gone gate with a bounded reap settle — a pane that died before teardown no longer quarantines its journal forever. Aborted flat spawns close their orphan tab (herdr twin of the #1913 tmux fix). Respawns keep the task's recorded harness/model/effort, and when `config/crew-dispatch.json` is active a respawn now names the rules it did not consult instead of skipping the consultation backstop in silence; a bare respawn still cannot reproduce a raw launch command, because only its harness basename is ever recorded. Away-mode dedups an identical digest whose submit went unconfirmed, but only against evidence that the digest actually reached the captain: the marker is bound to the supervisor pane it was typed into, and a composer still holding unsent text while that digest awaits confirmation revokes it, whether or not the classifier could prove the composer's geometry. An unreadable composer defers without revoking, so the marker additionally expires after `FM_INJECT_DEDUP_UNREADABLE_MAX` 3 consecutive unreadable observations - enough to ride out a transient capture failure, and strictly bounded past that. The count, not a shorter clock, is what bounds this: in the case the guard exists for the earlier Enter landed, so the agent is mid-turn and every poll returns at the busy guard above both checks, and the duplicate only arrives at the next composer-empty poll once that turn ends, roughly one every 976s in the measured incident. A window short enough to bound an unreadable stretch would expire before that duplicate ever arrived and would cost the guard its purpose, whereas a busy pane is never an unreadable observation and so never spends the count. A re-discovered pane's empty composer, an Enter that was swallowed and then discarded, or a marker that outlived either bound therefore retypes the escalation rather than treating it as delivered and truncating the buffer, so the captain's only away-mode channel cannot lose a merge decision to a false positive. With these, `tests/fm-backend-herdr-presentation-e2e.test.sh` passes fully on herdr 0.8.0/protocol 19 for the first time on this machine. |
| `fm/herdr-takeover-fix-t1` | [#1912](https://github.com/kunchenguid/firstmate/issues/1912) | The herdr secondmate pane-takeover gate settles the pane before it answers, and refuses only when another program is running under the shell's **own** pid and process group — the one state only `exec` can produce. Two quick samples 0.3s apart could not see a shell rc that does pure-shell work and execs after them: the gate cleared the pane and the whole launch command, `--dangerously-skip-permissions` and all, was typed into whatever the rc exec'd, while the spawn printed success and recorded a second mate that was not running. In the other direction, any rc running an ordinary foreground command for longer than the sampling window (`nvm use`, a pyenv shell-out, a keychain lookup, a `sleep` throttle) put that command alone in the terminal's foreground group and aborted the spawn claiming a shell rc had exec'd it, when nothing had. Herdr reports a shell waiting at its prompt and a shell still running its rc identically, so the operating system's own process state is read as a second signal and the pane is cleared only once the shell has stopped executing; unreadable and ambiguous reads still proceed, and the wait is bounded (60 polls, ~8s, `FM_BACKEND_HERDR_PANE_SETTLE_POLLS`), against real panes that reached rest within 14 polls on a saturated machine. The refusal also moved ahead of metadata publication, so it no longer leaves a live pane and a `state/<id>.meta` describing a second mate that never launched for the next retry to collide with. |
| `fm/afk-marker-outlives-buffer-q9` | [#1859](https://github.com/kunchenguid/firstmate/issues/1859) | Every site that clears the away-mode delivery buffer now disarms the duplicate-digest marker in the same step - the return catch-up, a fresh away-session entry, and the launcher's transactional backup and rollback set. The marker asserts that one specific buffer was typed with an unconfirmed submit, and nothing removed it when that buffer went away, so it could survive the whole dedup window and then match a genuinely new escalation whose digest rendered identically, which an unchanged fleet does. That escalation was reported delivered without ever being typed, and the flush truncates the buffer on success, so nothing retried it and the captain's only away-mode channel lost the message in silence. Disarming is always the safe direction: a missing marker can cost a duplicate delivery, never a lost one. |
| `fm/herdr-lock-fix-t2` | [#730](https://github.com/kunchenguid/firstmate/issues/730) | The four waiters on the shared named-session presentation lock read one bound owned by `bin/backends/herdr.sh` instead of the 5s, 5s, 30s, and single-try values they had drifted to. Their common holder is a projected spawn, which holds the lock from the projected create through launch handoff - roughly 6.5s of projection calls plus `bin/fm-spawn.sh`'s unconditional 60-poll worktree-entry wait - so each of the short bounds expired mid-hold: a task kill refused its pane close and leaked the very orphan tab the flat-abort fix exists to prevent, and teardown of an *unrelated* task in the same session failed with "nothing was changed" for a reason that had nothing to do with that task. Shrinking the hold window instead, by releasing before the worktree wait, was measured and rejected: `spawn_abort_cleanup`'s focus-preserving projection cleanup is reachable from every line of that window, including the worktree-entry timeout itself, and today runs under the lock the spawn already holds - releasing earlier turns it into a second bounded re-acquire that can fail and strand the projection. Session-start cleanup deliberately keeps a short wait rather than the shared bound, because it runs once per candidate on the startup path and a skipped husk is retired at the next session start. Every expiry now names the holding pid and the lock's age; `fm_lock_try_acquire` set `FM_LOCK_HELD_PID` and all four sites discarded it, so a genuine wedge and healthy contention produced the identical single warning line. The workspace-mint lock no longer falls through to the unserialized find+create when its lock is unusable or stays contended - the namespace is a fixed `/tmp` path any other local uid can squat, and the no-`shasum`-or-`sha256sum` variant needs no attacker at all - which silently reopened #730 and left two same-labeled home workspaces that every later no-identity spawn refuses until a human deletes one; it refuses the spawn instead, naming the namespace and hashing-tool requirements. Relocating that namespace off `/tmp` was considered and not taken: it would not cover the missing-hashing-tool variant, and it splits lock identity across a fleet mid-upgrade. The mint lock shipped with no test coverage at all, which is why its degradation could regress silently; concurrent-spawn regression tests now pin exactly one workspace minted per home, verified non-vacuous against an unserialized control that mints two. The raised bound deliberately does NOT reach session start's blocking path: bootstrap's close of a dead secondmate's endpoint keeps the same short bound the session-start projection cleanup uses, so a live spawn holding the lock cannot stall startup. The flat-abort pane close no longer discards its own stderr either, so on the waiter most likely to be waiting the refusal names the holder instead of looking like a hang. |
| `fm/decision-resolve-key-broken-r2` | upstream defect, no issue filed | The open-decision listing states the key that answers every entry, `default` included, so answering a listed decision works again. It printed the key only when it was not `default`, while rendering the note verbatim in the very position a key token occupies: an unkeyed decision showed no key to copy at all, and a note beginning with its own `[key=...]` token - what a worker writes when it puts the token after the colon instead of before it, where `bin/fm-classify-lib.sh`'s decision-key grammar defines it - read as that decision's key. Firstmate copied the displayed token into `bin/fm-send.sh --resolve-key` and was refused against a decision the same listing had just shown as open, so the answer never reached the worker and the decision stayed open. The refusal itself was never the defect and is unchanged: `fm-send` validates against the one authoritative fold, and a mistyped, absent, or already-resolved key still stops before anything is typed. |
| `fm/reserved-key-fold-discard-r3` | [#1842](https://github.com/kunchenguid/firstmate/issues/1842) | `bin/fm-send.sh --resolve-key` refuses a key whose closing line the decision fold would discard, instead of checking only that the key is currently open. A key in a namespace `bin/fm-classify-lib.sh` reserves to the library that raises it (`pending-reply-*`) genuinely is open in that fold, so the open-set check accepted it - but the `answered:` line `fm-send` then appends does not speak that namespace's vocabulary, so the fold discarded the close. The answer reached the worker, `fm-send` exited 0, and the decision stayed open forever: the exact silent orphan the refusal exists to prevent, and the mirror image of the listing defect on `fm/decision-resolve-key-broken-r2`. The fold is the correct side of that disagreement and is unchanged. `bin/fm-pending-reply-lib.sh` owns both ends of such a decision and closes it only once the correlated report actually arrives, so honouring a foreign `answered:` close would retire a still-unresolved missed-report expectation from the captain's open listing and leave the durable record disagreeing with the ledger - strictly worse than leaving it open. The precheck puts the question to the fold's own rule rather than restating which namespaces are reserved, so the two cannot drift, and the refusal keeps its stop-before-sending bias. Answering such a mate is unaffected: resend without `--resolve-key` for that key and its owner closes the decision when the expectation resolves. |

Direct on `patched` (fork infrastructure, no upstream issue): PATCHES.md is
registered in `bin/fm-test-run.sh`'s changed-test map and in
`docs/documentation-audiences.json`, because `--changed` verification dies on
any unmapped/unclassified file — it previously aborted before selecting a
single test, so earlier "verified with --changed" runs never actually ran.
Both workflows in `.github/workflows/` now trigger on `patched` as well as `main`.
They triggered on `main` alone before, so pushes to `patched` and pull requests targeting `patched` were never covered, and adding `patched` closes exactly that gap and nothing more.
`patched` is added alongside `main` rather than replacing it, because these files are shared with upstream, where `main` really is the default branch: adding a branch that upstream does not have changes nothing for upstream and keeps the diff to one token per trigger list, whereas replacing `main` would disable upstream CI and conflict on every rebase.
This fork's default branch is now `patched`, changed deliberately on 2026-08-12.
`main` here tracks pristine upstream `833a9a2` and carries upstream's own default branch name.
Pull requests 1 and 2 were opened before that change and therefore target base `main`, which the old filter already matched, so the trigger lists are not what explains this fork having produced no workflow run to date.
The absence of runs is explained instead by the fork's workflows having gone unregistered until 2026-08-12: GitHub registers the workflows it finds on a repository's default branch, and while that branch was `main` sitting at pristine upstream, nothing was ever pushed there for it to notice.
Both workflows registered themselves once the default branch became `patched` and work was pushed to it, with no enablement step needed, and both are active from 2026-08-12.
Runs therefore reach `patched` pushes and `patched`-based pull requests only once this trigger change lands.

Verification lesson worth keeping: the first cut of the #1912 secondmate guard
reused the pane-CLOSE idle-shell proof, which demands a shell with no child
process. It refused legitimate spawns (two integration suites failed, and any
operator whose shell rc starts a persistent helper would have hit it). Only the
full `--changed` run against the upstream base caught it — the targeted per-fix
runs did not. Run the full changed set before trusting a herdr change.

Known pre-existing failure on this machine (reproduced at pristine upstream
`833a9a2`, not caused by our patches): `tests/fm-pi-watch-extension.test.sh`,
one case; likely Node 26 vs upstream's runtime — irrelevant unless Pi becomes
a crew harness. (The presentation e2e's abort-cleanup and journal-retirement
failures previously listed here are fixed by `fix/herdr-followups`.)

Environment-bound rather than load-sensitive: `tests/fm-afk-inject-e2e.test.sh`
and `tests/fm-afk-inject-herdr-e2e.test.sh` both fail with
`nohup: can't detach from console: Inappropriate ioctl for device` whenever the
suite runs from a shell with no controlling terminal, which is the normal case
for a crewmate agent pane.
Rerunning them alone does not clear them, because load is not the cause.
`nohup true` reproduces it directly in such a shell, and the tmux one never
loads the herdr adapter at all, so a herdr change is never the explanation.
Verify these two from an interactive terminal.

Load-sensitive under a full parallel `--changed` run, all five pass on an
unsaturated machine - rerun individually before investigating:
`tests/fm-vendor-auth-probe.test.sh` (wall-clock bound assertions; measured
312s against a 20s bound while the suite saturated the machine),
`tests/fm-watcher-lock.test.sh` (exit 124 - also fails when run immediately
after a real-herdr e2e, so let the machine settle),
`tests/fm-startup-network.test.sh` ("the worker never published" against a 30s
wait bound), `tests/fm-backend-herdr-presentation-e2e.test.sh` (real-herdr
lab timing), and `tests/fm-crew-state.test.sh` ("empty no-mistakes status
triggered extra lookups (0 calls)" - a status lookup the case expects is never
observed).
The crew-state numbers, all measured 2026-08-12: it failed at 52s while a
sibling agent's suite ran alongside a full `--changed` pass, passed in 509s
when the machine was still contended, and passed in 31s in an uncontended
`--changed` run.
Wall-clock alone is therefore the tell, not the verdict - judge it by whether
anything else was running, not by the duration.

Last full verification: 2026-08-12 on herdr 0.8.0 / protocol 19, run as
`bin/fm-test-run.sh --changed --base origin/main` - 112 test files, 1,939
assertions, one failure, the pre-existing Pi case. Every load-sensitive suite
listed above passed in that same run, so nothing there needed a rerun.

The live end-to-end shakedown on the real default herdr session was last run
2026-08-11 and has not been repeated since: spawn, trust dialogs, a real Claude
crewmate committing work, crew-state, guarded local merge, teardown through the
real landed-work gate, and complete cleanup with the captain's own workspace and
focus untouched.

## Standing captain rules (add to `data/captain.md` on first setup)

```
- treehouse, no-mistakes, and firstmate itself on this machine are PATCHED
  FORKS (github.com/Sways1024/{treehouse,no-mistakes,firstmate}, branch
  `patched`). The fork is canonical; upstream is never the source of truth.
  NEVER approve bootstrap install/upgrade/reinstall for any of them, and never
  run `treehouse update` or `no-mistakes update` — escalate to the captain
  instead. Their upstream version checks report our builds as older because the
  `-patched-<sha>` suffix is not understood; accepting one would replace the
  binary with plain upstream and drop treehouse's `--lease`/`--lease-holder`
  support that the spawn path depends on. The checks are disabled by
  TREEHOUSE_NO_UPDATE_CHECK=1 and NO_MISTAKES_NO_UPDATE_CHECK=1 in ~/.zshrc.
- `/updatefirstmate` is safe only because `origin` is our own fork. Never add or
  pull from a kunchenguid upstream remote, and never repoint origin at it.
  `origin/HEAD` must resolve to `origin/patched` so the worktree-tangle guard
  treats `patched` as this checkout's default branch. `patched` is the fork's
  GitHub default branch, so a clone made after 2026-08-12 already resolves it;
  an older clone still points at `main` and needs
  `git remote set-head origin patched`.
- Relay stays disabled. Remote secondmates stay disabled unless the captain
  sets them up in person.
```

This block is the authoritative copy; `data/captain.md` on each machine carries
the same text (it is gitignored, so it is set up per machine).

## Setup on a new Mac (order matters)

```sh
# 1. Prerequisites — BEFORE first firstmate launch, so bootstrap
#    never offers upstream installers for tools we patch:
#    herdr + jq are for the herdr runtime backend (herdr >= 0.8.0 required:
#    below it, presentation-space cleanup has a focus-steal defect and the
#    projection is floor-gated off; python3 comes with CLT and enables the
#    protocol-16 event push + workspace ordering).
brew install gh git tmux bash shellcheck go node herdr jq
gh auth login
npm install -g tasks-axi

# 2. Patched dependencies from our forks:
git clone -b patched https://github.com/Sways1024/treehouse.git ~/dev/treehouse
cd ~/dev/treehouse && go build -o treehouse . && cp treehouse /opt/homebrew/bin/
git clone -b patched https://github.com/Sways1024/no-mistakes.git ~/dev/no-mistakes
cd ~/dev/no-mistakes && make build && cp bin/no-mistakes /opt/homebrew/bin/
export NO_MISTAKES_TELEMETRY=0   # also put in ~/.zshrc

# 3. Firstmate itself:
git clone -b patched https://github.com/Sways1024/firstmate.git ~/dev/firstmate
cd ~/dev/firstmate

# 3b. Select the herdr runtime backend (our standing choice; tmux stays
#     installed as the verified fallback — write `tmux` here to revert):
mkdir -p config && printf 'herdr\n' > config/backend

# 3c. Point origin/HEAD at our canonical branch. Since 2026-08-12 `patched` is
#     the fork's GitHub default branch, so a fresh clone already resolves
#     origin/HEAD to it and this command is a harmless no-op; a clone made
#     before that date still points at `main` and needs it.
#     Without it the worktree-tangle guard resolves the default branch as
#     `main` and warns on every command that this checkout is "stranded" on
#     `patched` — which is where our work correctly lives. It feeds nothing but
#     that guard (bin/fm-tangle-lib.sh's fm_default_branch has exactly two
#     callers, both tangle checks), so sync and merge behavior are unaffected.
git remote set-head origin patched

# 3d. Silence both upstream update checks (put these in ~/.zshrc alongside
#     NO_MISTAKES_TELEMETRY=0). They offer plain upstream builds, which would
#     REPLACE our patched forks — dropping the treehouse `--lease` support
#     bin/fm-spawn.sh depends on. We never update these from upstream, so the
#     check has no upside and one keystroke of downside.
export TREEHOUSE_NO_UPDATE_CHECK=1
export NO_MISTAKES_NO_UPDATE_CHECK=1

# 4. Optional continuity from the old machine: copy data/, config/, .env
#    (NEVER state/ — it is machine-bound). Add the captain rules above
#    to data/captain.md.

# 5. Launch: run `claude` inside ~/dev/firstmate. AGENTS.md takes over.
```

Verify: `PATH="/opt/homebrew/bin:$PATH" bin/fm-test-run.sh --changed` (or `--all`, ~30+ min).

Note: if your user-level Claude settings include a Stop sound hook, scope it away
from this directory or it will chime on every supervision cycle.

## Keeping up with upstream

Fork is canonical (same policy as the other tools). Upstream moves very fast
(~100 PRs/fortnight); rebase only when needed:

```sh
git fetch origin && git checkout patched && git rebase origin/main
PATH="/opt/homebrew/bin:$PATH" bin/fm-test-run.sh --changed
```
