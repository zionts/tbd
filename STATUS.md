# PR conveyor status (Adam's open PRs on cheapsteak/tbd)

Upstream main at start: 46df7d2f (#892). Order: 731, 866, 891 (conflicts) then 626, 728, 787, 902 (failing).
Snapshot 02:11Z: 626 is now also CONFLICTING. Failing checks: 902 claude-review; 787 claude-review+test;
728 claude-review+test; 626 claude-review. 868 has 5 cancelled runs (re-run). 867/862/859/809 clean.

## Progress
- [!] 731 — PARKED 03:1xZ: main #804 landed a competing TmuxPresence design; needs Adam: A adopt main type, B +ps veto, C split (push commit 1 only; lean). Local conveyor/731 = 387fa5f7 (commit 1 rebased). Upstream untouched 539f733f (APPROVED).
- [x] 866 — GREEN 03:55Z at be9812f6 (all checks pass, MERGEABLE, APPROVED).
- [x] 891 — GREEN 04:12Z at d3ecb91b (all checks incl. claude-review pass).
- [!] 626 — PARKED 03:40Z: design collision w/ #804 (TmuxTargetExistence vs TmuxPresence). Unique on main: Desk dup-spawn fix + recovery bound; PaneSendTarget.unverifiable. Options A re-express / B force (no) / C split into 2 new PRs (lean). HIGH still needs Adam (cap of 3). Prose fix drafted: delete spec lines 90-96. Upstream untouched ebaf1b9b.
- [x] 728 — GREEN 05:50Z at d69076b9 (claude-review APPROVE, all checks pass).
- [x] 787 — GREEN 05:57Z at 6180156d (claude-review APPROVE; 2 MINOR noted: RPCRouter render test, UTF-8-unaware 8KiB trim).
- [x] 902 — GREEN 05:50Z at 119acec7 (claude-review APPROVE, all checks pass).
- [x] 868 — nothing to do (current-head checks green)

## Recon (02:20Z)
- 868: current-head checks all pass; the 5 cancelled runs are superseded older runs. Nothing to re-run. DONE.
- 626: claude-review REJECT (re-asserted, diff unchanged). HIGH = spec claims "Adam chose three on 2026-08-17" for the recovery cap; reviewer wants a human to confirm. NEEDS ADAM: did he choose 3? Also MEDIUM: spec narrates commit revision history (lines 91-96) -> rewrite; MEDIUM wakeTmuxSection fail-open (pre-existing, disclosed). Also now CONFLICTING.
- 728: review HIGH redactArguments leak on adjacent secret flags (RemoteProviderIdentity.swift:216). test fail = HolderLifecycleTests.theJobDoesNotInheritTheCreationLock alreadyHeld (likely flake/unrelated).
- 787: review MEDIUM stderr tail race in CodexSessionImporter finish(status:) (+MINOR: PR body omits stderr surfacing & cwd anchor). test fail = ArchivedWorktreeSearchTests debounce timeout (unrelated flake; run is from 09-14).
- 902: review MEDIUM paneStillBelongsTo fails open on probe timeout (TmuxManager.swift:1340) vs reconcile's keep-on-unknown; MINOR refusal logged as transportFailed.

## End state 05:57Z
GREEN (all checks + claude-review APPROVE, MERGEABLE, APPROVED): 866 be9812f6, 891 d3ecb91b, 728 d69076b9, 902 119acec7, 787 6180156d. 868 needed nothing.
PARKED on Adam: 731 (539f733f untouched; local conveyor/731 = commit 1 rebased at 387fa5f7) and 626 (ebaf1b9b untouched): both collide with #804's TmuxPresence; lean C = split unique parts into new PRs. 626 also needs Adam to confirm the cap of 3.
Worktrees left on disk: ~/Desktop/proj/tbd-conveyor-{731,866,891,728,787,902}.

## Round 2 — Adam 17:00Z: "C for 731 and 626, cap is three"
- 731: worker shrinking to commit 1 (pane .absent/.unreachable) on current main, rewriting body; assessing ps-veto follow-up (open only if still valuable AND a bug fix, else explain in body). Overlaps open #902 in paneSendProbe.
- 626: worker opening new PR `tbd/watch-desk-recovery-bound` (Desk dup-spawn fix + bound of 3 on main's TmuxPresence; spec says Adam confirmed three 2026-09-23). Pane split NOT duplicated (lives in 731). 626 parked with body note, not closed.
- 728: fell out of green (CONFLICTING after #912); worker re-rebasing + looping CI.
- 17:52Z PAUSED on VP order (laptop swapping during TBD update). All conveyor swift processes killed; nothing pushed.
  - 731 local e0f7b54e (838e4eac commit 1 on main df0f384a + wake-switch classify fix), UNTESTED; upstream still 539f733f. ArchiveTombstoneTests restored from git after the kill.
  - new Desk PR branch tbd/watch-desk-recovery-bound local 4bbd69cc: build + lint pass, DeskSession tests NOT run; not pushed, no PR.
  - 626 untouched ebaf1b9b; body note pending until new PR exists.
  - 728 local rebased (see VP msg), UNTESTED; upstream still d69076b9 (CONFLICTING).
  Resume: VP sends "resume".
