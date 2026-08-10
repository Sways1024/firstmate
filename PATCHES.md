# Local patches (Sways1024 fork)

`patched` = upstream HEAD `833a9a2` (2026-08-07) plus eighteen fixes on five branches:

| Branch | Upstream issues | Fix |
| --- | --- | --- |
| `fix/spawn-lifecycle` | [#1573](https://github.com/kunchenguid/firstmate/issues/1573)/[#1924](https://github.com/kunchenguid/firstmate/issues/1924), [#1913](https://github.com/kunchenguid/firstmate/issues/1913), [#1818](https://github.com/kunchenguid/firstmate/issues/1818) | Spawns lease their worktree (`treehouse get --lease --lease-holder fm-<id>`) and refuse a live sibling's checkout — closes the data-loss window. Aborted spawns kill their tmux window and release the lease. Crewmates share the project's Claude auto-memory store. |
| `fix/supervision-wakes` | [#1897](https://github.com/kunchenguid/firstmate/issues/1897), [#1769](https://github.com/kunchenguid/firstmate/issues/1769), [#1792](https://github.com/kunchenguid/firstmate/issues/1792), [#1033](https://github.com/kunchenguid/firstmate/issues/1033) | PRs closed without merging produce a needs-decision wake instead of stranding the task. The wedge detector re-consults the busy contract and progress signals before escalating. Stale busy records contradicted by later status-log lines classify unknown. no-mistakes workers drive their own validation run. |
| `fix/herdr-daily-use` | [#883](https://github.com/kunchenguid/firstmate/issues/883), [#1011](https://github.com/kunchenguid/firstmate/issues/1011), [#1571](https://github.com/kunchenguid/firstmate/issues/1571) (gap A) | Composer glyph stripping is locale-safe (literal patterns, not byte counts) — under `LC_ALL=C` an idle composer no longer reads pending forever, which was the root feeder of the away-mode deferral wedge on herdr. The herdr events probe and socket lookup no longer EPIPE-spam stderr on every watcher start. Every harness Resume row carries the launch's autonomy flags/env (claude gains a Resume row); stuck-crewmate-recovery requires flag-carrying resumes and adds the restore-to-clone trust-dialog hazard. |
| `fix/herdr-operability` | [#1912](https://github.com/kunchenguid/firstmate/issues/1912)-adjacent (dialogs), workspace-label collision | Claude's two first-launch dialogs are documented with their exact options: the workspace-trust prompt preselects "Yes", but the bypass-permissions prompt preselects **"No, exit"**, so the blind `--key Enter` the skill used to recommend killed the crewmate before it read its brief. Firstmate resolves its own herdr container by a recorded exact workspace id (`state/.herdr-home-workspace`) instead of the mutable label, so a captain's personal workspace that herdr auto-labeled `firstmate` from its directory name is neither adopted nor able to refuse spawns. |
| `fix/herdr-followups` | [#730](https://github.com/kunchenguid/firstmate/issues/730), [#1337](https://github.com/kunchenguid/firstmate/issues/1337), [#1571](https://github.com/kunchenguid/firstmate/issues/1571) (gap B), [#1575](https://github.com/kunchenguid/firstmate/issues/1575), [#1859](https://github.com/kunchenguid/firstmate/issues/1859), [#1912](https://github.com/kunchenguid/firstmate/issues/1912) | Lab helper places `--session` before a `--` child-argv delimiter (isolation no longer silently degrades; production wrapper hardened identically). Per-home workspace find+create serializes under a session+label mint lock (no duplicate-workspace race). Presentation-lock wait raised 5s→30s (`FM_SPAWN_HERDR_PRESENTATION_LOCK_ATTEMPTS`) so concurrent abort cleanup actually serializes instead of falling back flat. Journal retirement rides the confirmed-gone gate with a bounded reap settle — a pane that died before teardown no longer quarantines its journal forever. Herdr secondmate spawns refuse only on positive evidence that a non-shell took the pane over (two agreeing samples; unreadable or ambiguous reads proceed); aborted flat spawns close their orphan tab (herdr twin of the #1913 tmux fix). Respawns keep the task's recorded harness/model/effort. Away-mode dedups an identical digest whose submit went unconfirmed. With these, `tests/fm-backend-herdr-presentation-e2e.test.sh` passes fully on herdr 0.8.0/protocol 19 for the first time on this machine. |

Direct on `patched` (fork infrastructure, no upstream issue): PATCHES.md is
registered in `bin/fm-test-run.sh`'s changed-test map and in
`docs/documentation-audiences.json`, because `--changed` verification dies on
any unmapped/unclassified file — it previously aborted before selecting a
single test, so earlier "verified with --changed" runs never actually ran.

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

Load-sensitive under a full parallel `--changed` run, all three pass solo on an
idle machine — rerun individually before investigating:
`tests/fm-vendor-auth-probe.test.sh` (wall-clock bound assertions; measured
312s against a 20s bound while the suite saturated the machine),
`tests/fm-watcher-lock.test.sh` (exit 124), and
`tests/fm-backend-herdr-presentation-e2e.test.sh` (real-herdr lab timing).

Last full verification: 2026-08-10 on herdr 0.8.0 / protocol 19 —
111 test files, 1,905 assertions green; the only failures were the
pre-existing Pi case and the two load artifacts above.

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
  `origin/HEAD` is set locally to `origin/patched` so the worktree-tangle guard
  treats `patched` as this checkout's default branch; that is a per-machine
  local ref, not something a clone carries.
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

# 3c. Point origin/HEAD at our canonical branch. This is a LOCAL git ref, so it
#     does not travel with the clone and must be set on every machine.
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
