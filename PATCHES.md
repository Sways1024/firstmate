# Local patches (Sways1024 fork)

`patched` = upstream HEAD `833a9a2` (2026-08-07) plus seven fixes on two branches:

| Branch | Upstream issues | Fix |
| --- | --- | --- |
| `fix/spawn-lifecycle` | [#1573](https://github.com/kunchenguid/firstmate/issues/1573)/[#1924](https://github.com/kunchenguid/firstmate/issues/1924), [#1913](https://github.com/kunchenguid/firstmate/issues/1913), [#1818](https://github.com/kunchenguid/firstmate/issues/1818) | Spawns lease their worktree (`treehouse get --lease --lease-holder fm-<id>`) and refuse a live sibling's checkout — closes the data-loss window. Aborted spawns kill their tmux window and release the lease. Crewmates share the project's Claude auto-memory store. |
| `fix/supervision-wakes` | [#1897](https://github.com/kunchenguid/firstmate/issues/1897), [#1769](https://github.com/kunchenguid/firstmate/issues/1769), [#1792](https://github.com/kunchenguid/firstmate/issues/1792), [#1033](https://github.com/kunchenguid/firstmate/issues/1033) | PRs closed without merging produce a needs-decision wake instead of stranding the task. The wedge detector re-consults the busy contract and progress signals before escalating. Stale busy records contradicted by later status-log lines classify unknown. no-mistakes workers drive their own validation run. |

## Standing captain rules (add to `data/captain.md` on first setup)

```
- treehouse and no-mistakes on this machine are PATCHED FORKS
  (github.com/Sways1024/{treehouse,no-mistakes}, branch `patched`).
  NEVER approve bootstrap install/upgrade/reinstall for either tool —
  escalate to the captain instead.
- Relay stays disabled. Remote secondmates stay disabled unless the captain
  sets them up in person.
```

## Setup on a new Mac (order matters)

```sh
# 1. Prerequisites — BEFORE first firstmate launch, so bootstrap
#    never offers upstream installers for tools we patch:
brew install gh git tmux bash shellcheck go node
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
