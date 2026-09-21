<!-- DRAFT — decision-dependent passages are marked [PENDING Qn]; replace with the human's answers before commit. -->
# Background-built updates — design

Updating TBD today takes two arduous steps: notice that `main` has moved, then
run `tbd update` in a terminal and wait several minutes while it compiles in
the foreground. This spec lets TBD build the new version in the background, in
a directory nothing is running from, and then offer a one-gesture swap to it,
with a one-command way back. It builds on
[`2026-09-04-automatic-version-updates-design.md`](2026-09-04-automatic-version-updates-design.md),
whose build identity, `UpdateChecker`, successor-first handover, and paced wake
it reuses unchanged.

## 1. What is wrong today

- **The build directory is the running installation.** `scripts/update.sh`
  builds in `~/tbd/updates/src/.build/<config>`, and the installed daemon is
  launched in place from that same directory
  (`scripts/restart-bundle-lib.sh`). The daemon's sibling helpers are found
  beside it: `HolderSpawner` looks for `TBDHolder` next to the running daemon,
  and replacement agent processes are handed the sibling `TBDCLI`. Any build in
  `src` — including `tbd update --dry-run`, documented as "installs nothing" —
  overwrites those files on disk under a live daemon. From then on, any daemon
  start that bypasses the handover (the app's poller after a crash, a login
  relaunch) runs the new code, and holder sessions spawn a `TBDHolder` from a
  different commit than the daemon talking to them.
- **Nothing can be staged.** Because building replaces the live binaries, the
  build and the swap cannot be separated in time. The swap is the only part
  that needs a human's attention; the build is the part that takes minutes.
- **The daemon cannot roll back without a rebuild.** Every update keeps the
  replaced app bundle at `previous/TBD.app`, but the previous daemon's binaries
  were overwritten by the build. Going back means re-checking-out an old commit
  and rebuilding.
- **The notice asks for a terminal.** The app's `UpdateNotice` says "Run tbd
  update in a terminal" and offers only Dismiss.
- **`auto` has no middle ground.** The existing modes are `off`, `check`
  (notice only), and `auto` (build and swap unattended). Nothing builds ahead
  and then waits for a yes.

## 2. Goals and non-goals

Goals:

- A build never writes to a directory a running daemon, holder, or CLI was
  launched from.
- When `main` moves and the operator has opted in, TBD builds the new version
  in the background, without competing with interactive builds or pushing the
  machine into swap, and then says it is ready.
- Installing a ready build is one gesture and takes seconds: the existing
  handover and paced wake, with no compile in the critical path.
- One command returns daemon, helpers, CLI, and app to the build that ran
  before, with no compile.
- The new autonomous behavior ships default-off.

Non-goals:

- Changing the handover, reconcile hardening, or wake pacing. They are the
  2026-09-04 design's and they hold.
- Release channels, tags, or downloadable binaries. Latest is still a commit
  on `main`.
- Installing without a gesture. That remains `auto`'s job and is unchanged.

## 3. Placement

Per [`docs/theory-placement.md`](../theory-placement.md): the procedure —
where builds live, when to build, how many to keep, how to promote and roll
back — is theory and lives in `scripts/update.sh`, editable without a rebuild.
The daemon keeps only what needs a long-lived process: the check timer it
already runs, and the decision to launch the script. The app gains a button
that runs the script; it computes nothing.

## 4. Build layout [PENDING Q3]

<!-- Recommended shape (Q3-A). If B is chosen, replace with a staging clone. -->

Each build lives in its own directory, keyed by commit:

```
~/tbd/updates/
  src/                  the update clone: fetch and checkout only, never run from
  builds/<sha>/         one build's products, identity sidecar, and app bundle
  current -> builds/<sha>    what is installed and running
  previous -> builds/<sha>   what ran before; the rollback target
  staged -> builds/<sha>     a completed build waiting for a yes (absent otherwise)
```

- **Building.** `update.sh` builds with `--scratch-path` pointing into a build
  directory of its own, never at `src/.build` and never at the directory
  `current` names, so no compile writes under a live process.
  <!-- Detail to settle during implementation: per-sha scratch paths lose
  SwiftPM's incremental cache. Option: one persistent scratch dir for
  compiling, then copy (APFS clone, `cp -c`) the finished products into
  builds/<sha>. Clonefile keeps the copy ~free. -->
- **A build is complete** only when every product in `RUNTIME_PRODUCTS`, the
  identity sidecar, and the signed app bundle are present; the script writes a
  `complete` marker last. A directory without the marker is a partial build
  and is never promoted.
- **Promotion** (install) points `staged`'s build at `current`, moves the old
  `current` to `previous`, installs the app bundle to `/Applications`, and runs
  the existing handover with the new daemon path.
- **Rollback** (`tbd update --rollback`) is promotion of `previous`: same
  handover, same wake, no compile.
- **Retention.** At most three build directories exist at once: `current`,
  `previous`, and one `staged` or in-progress build.

### Who reclaims orphans

`~/tbd/updates/` was exempt from the named-reconciler doctrine because every
entry was a fixed singleton. `builds/<sha>` is a new kind of durable resource
that *can* accumulate, so it needs an answer. [PENDING Q3 — recommended:]
`update.sh` prunes on every run, before it builds: any `builds/*` directory
not named by `current`, `previous`, or `staged` is removed, and partial builds
older than the running lock are removed. The cap is structural (three names),
so a run that dies mid-build leaves at most one extra directory, which the next
run removes. CLAUDE.md's exemption paragraph and `docs/updating.md` are
updated to say so.

## 5. Prebuilding [PENDING Q1, Q4, Q6]

<!-- Recommended shape: Q6-A new mode, Q1-A idle-gated via swift-safe, Q4-A one staged build. -->

- **The setting.** `update_mode` gains a value `prebuild`, between `check` and
  `auto`: check, build ahead, then wait for a gesture. The column is `TEXT` and
  already tri-state, so this is an enum case, not a migration. `Config` and
  `daemon.capabilities` already decode `updateMode` with `try?` and fall back
  to `Config.updateModeDefault`, so an older app or CLI talking to a newer
  daemon reads `prebuild` as `off` rather than failing to decode — its picker
  shows the wrong value until it is updated, which is acceptable because app
  and daemon update together. An older daemon reading a `prebuild` row
  resolves it the same way and does nothing. Default stays `off`.
- **Trigger.** In `prebuild` mode, when `UpdateChecker` finds the relation
  `behind`, no build is staged or in flight, and the latest commit has not
  already failed, it launches `update.sh --prebuild` detached, exactly as
  `auto` launches `--auto`.
- **Resource gate.** `--prebuild` builds only through `scripts/swift-safe`
  (so it queues behind every interactive build machine-wide) and [PENDING Q1]
  only when the machine is idle: no other swift-safe holder waiting, memory
  pressure normal, and swap use under a threshold set at the top of the
  script. When the gate fails it exits quietly; the next tick retries.
- **When `main` moves again** [PENDING Q4]: while a build is staged, no new
  prebuild starts. After the staged build is installed or discarded, the next
  tick builds the newest `main` once.

## 6. Offering the swap [PENDING Q2, Q5]

- **Surfaces.** When a build becomes staged, `update.sh` sends one
  `tbd notify` naming the commits, and `daemon.status`'s `update` field gains a
  `staged` commit (optional, so older clients still decode). The app's
  `UpdateNotice` then reads "TBD <short> is built and ready" with **Install
  now** and Dismiss. [PENDING Q2: banner, notify, or both.]
- **Install now** runs `update.sh --install-staged`: promotion (§4), the
  existing handover, [PENDING Q2] an app restart, and the paced wake. The
  button is the gesture; nothing installs without it.
- **Busy sessions** [PENDING Q5]: install proceeds immediately; the handover
  is already built not to park live sessions.
- `tbd update` with a build staged for the latest commit skips the compile and
  installs it; without one it behaves as today, building into `builds/`.

## 7. Failure handling

- A failed or interrupted prebuild leaves no `complete` marker; it is never
  staged, never offered, and removed by the next run's prune. The commit is
  recorded as attempted and not retried until `main` moves, as `auto` does.
- A failed install falls back exactly as today: restore the previous bundle,
  leave the old daemon running, exit non-zero, log it.
- `--dry-run` builds into `builds/` like any other run and so no longer
  touches the running installation.

## 8. Testing

- `scripts/update.test.sh` against a fake `tbd` and a fake build: the build
  never writes under the directory `current` names; a build without the
  `complete` marker is never staged or promoted; promotion and rollback move
  `current`/`previous` correctly; prune keeps exactly the named builds and
  removes partials; the resource gate's pass and fail branches.
- `UpdateChecker` with an injected clock: `prebuild` launches `--prebuild`
  once per commit, not while a build is staged, never `--auto`; `off`,
  `check`, and `auto` are unchanged.
- `UpdateMode` decoding: `prebuild` round-trips; an unknown value resolves to
  the default.
- `UpdateNotice`: the staged state renders the Install copy; every existing
  branch is unchanged.

## 9. Rollout

Ships with `off` as the default. Soak on one operator machine in `prebuild`.
The "Install now" button [PENDING: lands with the scripts, or after they soak].
Graduation, if ever, flips `Config.updateModeDefault`.

## 10. Rejected alternatives

- **A second fixed clone for staging.** Fixes the overwrite but not rollback:
  the previous daemon's binaries are still gone after a promotion.
- **Building in `src/.build` and copying out afterwards.** The copy is safe,
  but the compile itself still writes under the live daemon.
- **A compiled prebuild scheduler in the daemon.** Every change to when or how
  to build would need a rebuild of the thing being updated.

## 11. Decisions

[PENDING Q7 — the 2026-09-04 spec's §13 confirmations.]
