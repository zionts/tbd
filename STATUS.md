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
- 731 worker (paused): build + lint pass at e0f7b54e, tests not run. NO ps-veto follow-up: a global `ps` check can't target a per-repo server, so it would turn nearly every real .absent into unknown and stall reclaim — that revises #804's theory (needs spec: pin TMUX_TMPDIR or match the server by socket path). Draft 731 body at scratchpad/pr731-body.md explains the deferral + the #902 overlap. The TMUX_TMPDIR drift bug is still live on main (the classifier reads "No such file" as .absent).
- CORRECTION 728: pushed ae102196 (tested, 1375 passed) just before pause; MERGEABLE. claude-review REJECT: HIGH `-Token` case-sensitive miss; MED looksLikeSecret misses all-alpha/<20/>500. After resume: fix HIGH + test, document MED limits in spec. #912 removed session-header provider caption (dropped hunk; toolbar provider name = design choice, not done).

## Resume 17:56Z (10:56 PT): ONE build at a time, globally
Build slot queue: 728 (holding now) -> tbd-update diagnosis build -> 626-desk tests -> 731 tests.
- 728: fixing -Token case-insensitivity + documenting looksLikeSecret limits in spec.
- tbd update diagnosis: agent investigating (no builds until granted). Lead: #891 (unmerged) is the sqlite3.h fix; Sendable on global Logger maybe SDK-version.
- Release pipeline: per CLAUDE.md, a new feature needs brainstormed spec w/ Adam answering Qs. Agent drafting spec + open questions (no code, no PR, no build) at ~/Desktop/proj/tbd-release-pipeline.
- 18:00Z tbd update ROOT CAUSE: nix dev-shell SDKROOT leak -> nix MacOSX14.4.sdk (no sqlite3.h; Logger not Sendable there). #891 fixes both. First failure was swift-safe 1800s slot timeout (our builds). Proposed: real update from clean login shell = the verification; offered slot after 728.
- 18:03Z VP: runs tbd update from its session (clean shell) once I send "slot free" after 728's run; conveyor holds until "update done". #891 goes to Adam as the dev-shell fix. Approved follow-up: update.sh keeps full build log + prints first errors (diagnosis agent, shell-only, branch tbd/update-keep-build-log). Release spec: send Qs to VP; no waiver.
- 18:07Z release-pipeline spec draft: ~/Desktop/proj/tbd-release-pipeline, branch tbd/release-pipeline 01c3c676 (local only). 8 Qs sent to VP for Adam (recs: 1a opt-in default-off, 2b tested-only, 3a rolling prerelease N=20, 4c auto/4b manual attestation, 5a arm64, 6b, 7b, 8a). Key facts: TBD.app must be assembled + signed locally; ship 6 products + resource bundles; update clone stays checked out. Waiting on Adam's answers.
- 18:24Z sent 'slot free' to VP; conveyor holding for 'update done'.
- 728 local 7b93c35e (-Token case-insensitive; spec limits) broke gluedNonAlias test via Go-style over-redaction; chose (a) accept over-redaction + spec sentence. Awaiting go after update.
- 19:06Z (12:06 PT) update done (VP: 1eadc926 -> df0f384a). Adam accepted all release recs (1a,2b,3a,4c/4b,5a,6b,7b,8a|8c). Build queue: 728 (go) -> 626-desk -> 731; release-pipeline tiny SwiftPM symlink check needs a slot too.
- #914 (update.sh keeps build log + first errors, 75 = slot timeout) GREEN at f1548822, claude-review APPROVE.
- 19:12Z release pipeline BLOCKER to Adam: installed app's Bundle.module resolves only via compile-time absolute path (bundles in Contents/Resources, bundleURL = app root) -> CI-built app fatalErrors (icons, MarkdownStylesheet, Highlightr). Options A compiled resolver + Highlightr fork (lean) / B /Users/Shared fixed path / C ship non-app products only / D binary patch. PR held.
- 19:15Z VP: B, D out; plan C now (ship non-app products; TBDApp builds locally), A as follow-up, unless Adam objects. Worker preparing the C-scoped PR (not opened) + A sketch on a separate branch.
- 19:27Z 728 pushed 078c288b (tested); CI looping. Slot -> release symlink check (tiny), then 626-desk, then 731. Release C-scope ready locally at 1106318e (harness 282 ok, shellcheck/actionlint/swiftlint clean); A sketch 20bb5974 on tbd/bundle-module-relocatable.
- 19:3xZ symlink check: 8a holds (SwiftPM replaces foreign .build/release link, writes nothing into target; cold + warm). Slot -> 626-desk tests.
- 19:4xZ 728 on upstream 078c288b (1376 passed) REJECT round: bare KEY=value not key-checked; fix 15324cb2 local, queued after 626-desk. Queue: 626-desk (running) -> 728 -> 731.
- 19:5xZ 626-desk tests PASSED (52 tests, 4bbd69cc); worker pushing + opening PR. Slot -> 728 (15324cb2).
- 19:34Z #915 opened (Desk fix + bound of 3) head 4bbd69cc, CI pending; #626 parked w/ note -> #915 + #731.
- 19:5xZ #915 REJECT: HIGH person name 'Adam' in public files (my brief's error) -> 'the repository owner'; MED first spawn uncounted -> wording 'three replacements after first spawn (<=4 sessions)', no behavior change. Wording-only push, CI verifies.
- 19:47Z 728 pushed 15324cb2 (tested), CI pending. 915 at 3cff9a81 (wording fixes), CI pending. Slot -> 731.
- 19:55Z 728 4th REJECT (pin heuristic limits; narrow claim) -> 39cdb5b8 tests/docs, queued after 731. Stop rule: next heuristic gap -> Adam decides (a) keep closing / (b) accept stated limits / (c) simplify argv display (lean c).
- 19:58Z VP pre-decided: next heuristic gap on 728 -> (c) show command + first arg only, redact rest, heuristic removed; trade stated in PR body; Adam can object before merge.
- 20:0xZ 915 REJECT: budget reset even when archive throws -> fix 41c8b9f7 (+trigger test, him->them). Build queue: 731 (running) -> 728 (39cdb5b8) -> 915 (41c8b9f7).
- 20:17Z #731 GREEN at e0f7b54e (628 passed; all checks + claude-review pass; CLEAN). No ps-veto follow-up (needs spec). Slot -> 728, then 915.
- 20:34Z 728 on 39cdb5b8 (1378 passed) REJECT HIGH non-heuristic: withFreshestAgentAxis drops pendingQuestion -> fix 9ff8cd0d local. Slot -> 915 (41c8b9f7), then 728.
- 21:00Z 915 41c8b9f7 passed locally (53 tests), pushing. Slot -> 728 (9ff8cd0d).
- 21:15Z 915 REJECT on 41c8b9f7: HIGH hibernated replacement wedges gate 2 -> fix e7134488 (+ fail-closed tests), queued after 728. MEDIUM attribution: asked VP for Adam's one-line comment on #915; fallback drop attribution.

## 23:04Z (16:04 PT) after the 2:25–4:00 PM usage wall
MERGED 21:53Z: #731 e0f7b54e, #891 d3ecb91b, #787 6180156d.
CONFLICTING now: #866 be9812f6, #902 119acec7 (vs #731 paneSendProbe), #914 f1548822 (also REVIEW_REQUIRED), #915 41c8b9f7 (local fix 48c63367 untested). #728 39cdb5b8 mergeable, local fix 9ff8cd0d untested. No workers alive, no builds.
Next: 902 rebase -> 915 rebase+test -> 728 rebase+test; 866 + 914 mechanical rebases between.
- 23:1xZ VP decisions: open release PR now as held DRAFT (BLOCKED BY Adam's app-bundle choice; C then A) — agent rebasing onto main (post-#891) + opening, no local swift; 915: drop attribution (fallback), state 3 as design's choice. Running: 902 rebase+build (slot), 914 shell rebase.
- 23:30Z #916 release pipeline opened as held DRAFT, head a0df122c, CI green (claude-review skipped while draft).
- Wed Sep 23 23:30:34 UTC 2026: #916 marked ready (fleet rule: never draft; hold = BLOCKED BY line + no auto-merge). Stamps must be literal date -u.
