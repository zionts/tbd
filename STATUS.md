# PR conveyor status (Adam's open PRs on cheapsteak/tbd)

Upstream main at start: 46df7d2f (#892). Order: 731, 866, 891 (conflicts) then 626, 728, 787, 902 (failing).
Snapshot 02:11Z: 626 is now also CONFLICTING. Failing checks: 902 claude-review; 787 claude-review+test;
728 claude-review+test; 626 claude-review. 868 has 5 cancelled runs (re-run). 867/862/859/809 clean.

## Progress
- [!] 731 — PARKED 03:1xZ: main #804 landed a competing TmuxPresence design; needs Adam: A adopt main type, B +ps veto, C split (push commit 1 only; lean). Local conveyor/731 = 387fa5f7 (commit 1 rebased). Upstream untouched 539f733f (APPROVED).
- [x] 866 — GREEN 03:55Z at be9812f6 (all checks pass, MERGEABLE, APPROVED).
- [~] 891 — 03:55Z pushed d3ecb91b fixing all 3 review findings (bash 3.2 runs pass locally, CI moved to /bin/bash on macOS lint job); CI pending.
- [!] 626 — PARKED 03:40Z: design collision w/ #804 (TmuxTargetExistence vs TmuxPresence). Unique on main: Desk dup-spawn fix + recovery bound; PaneSendTarget.unverifiable. Options A re-express / B force (no) / C split into 2 new PRs (lean). HIGH still needs Adam (cap of 3). Prose fix drafted: delete spec lines 90-96. Upstream untouched ebaf1b9b.
- [~] 728 — d18db49f: claude-review REJECT round 2 (HIGH glued short flag -tSECRET; MED record heuristic in spec). 03:57Z worker fixing.
- [~] 787 — 04:1xZ pushed 9540f0fe (stderr drained to EOF before exit reported, 1s grandchild fallback on injected clock; real /bin/sh test x20); 23 passed, lint clean; CI pending.
- [~] 902 — 04:1xZ pushed 2565ad62 (paneOwnership tri-state; .unverifiable keeps at all 9 kill sites; refusal logs refused(target-mismatch)); 90 passed, lint clean; CI pending.
- [x] 868 — nothing to do (current-head checks green)

## Recon (02:20Z)
- 868: current-head checks all pass; the 5 cancelled runs are superseded older runs. Nothing to re-run. DONE.
- 626: claude-review REJECT (re-asserted, diff unchanged). HIGH = spec claims "Adam chose three on 2026-08-17" for the recovery cap; reviewer wants a human to confirm. NEEDS ADAM: did he choose 3? Also MEDIUM: spec narrates commit revision history (lines 91-96) -> rewrite; MEDIUM wakeTmuxSection fail-open (pre-existing, disclosed). Also now CONFLICTING.
- 728: review HIGH redactArguments leak on adjacent secret flags (RemoteProviderIdentity.swift:216). test fail = HolderLifecycleTests.theJobDoesNotInheritTheCreationLock alreadyHeld (likely flake/unrelated).
- 787: review MEDIUM stderr tail race in CodexSessionImporter finish(status:) (+MINOR: PR body omits stderr surfacing & cwd anchor). test fail = ArchivedWorktreeSearchTests debounce timeout (unrelated flake; run is from 09-14).
- 902: review MEDIUM paneStillBelongsTo fails open on probe timeout (TmuxManager.swift:1340) vs reconcile's keep-on-unknown; MINOR refusal logged as transportFailed.
