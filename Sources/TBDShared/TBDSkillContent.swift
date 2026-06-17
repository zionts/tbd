import Foundation

/// Canonical content for the `tbd` skill. Single source of truth used by two
/// daemon writers at startup:
/// - `SkillFileWriter` → `~/Library/Application Support/TBD/skill/SKILL.md`
///   (env-var fallback referenced by `TBD_PROMPT_CONTEXT` for non–Claude-Code
///   harnesses)
/// - `PluginDirWriter` → `~/Library/Application Support/TBD/plugin/skills/tbd/SKILL.md`
///   (loaded into TBD-spawned Claude sessions via `--plugin-dir`, where the
///   skill registers as `tbd:tbd`)
/// - `CodexPluginWriter` → `$CODEX_HOME/plugins/cache/tbd/tbd/local/skills/tbd/SKILL.md`
///   (loaded into TBD-spawned Codex sessions through the `tbd` profile plugin)
public enum TBDSkillContent {

    public static let body: String = """
---
name: tbd
description: Drive TBD (a macOS worktree + terminal manager). Use when the user asks to create a worktree, spawn a Claude, Codex, or shell session in another tab, send input to a terminal, read terminal output, link to a worktree, or send a UI notification — or whenever running inside a TBD-managed terminal (TBD_WORKTREE_ID env var is set).
---

# TBD

TBD is a macOS app that manages git worktrees and terminal tabs (Claude Code, Codex, or shell). Sessions running inside a TBD-managed terminal have `TBD_WORKTREE_ID` set in env.

## When to use this skill

- The user asks to spawn an agent, create a new worktree, send a message to another terminal, or notify the UI.
- You're running inside TBD (`TBD_WORKTREE_ID` is set) and need to coordinate with the user's other tabs.

## Discovering current commands

Always run `tbd <subcommand> --help` for current flags — flag detail is not duplicated here. Top-level commands: `tbd worktree`, `tbd terminal`, `tbd channel`, `tbd link`, `tbd notify`.

## Common workflows

### Spawn a new agent tab in the current worktree

New sessions you spawn start with NO conversation history. Brief them like a colleague who just walked into the room.

```bash
tbd terminal create "$TBD_WORKTREE_ID" --type claude --prompt-file - <<'EOF'
Goal, what you've ruled out, file paths/lines, enough surrounding context
that the new session can make judgment calls rather than follow narrow steps.
EOF
```

Use `--type codex` to spawn Codex instead of Claude:

```bash
tbd terminal create "$TBD_WORKTREE_ID" --type codex --prompt-file - <<'EOF'
Goal, what you've ruled out, file paths/lines, enough surrounding context
that the new session can make judgment calls rather than follow narrow steps.
EOF
```

### Create a new worktree with an initial task

```bash
tbd worktree create --prompt-file - <<'EOF'
briefing here
EOF
```

**Where the new branch starts:** `tbd worktree create` always bases the new branch on the repo's **default branch from origin**, never on the caller's branch. It best-effort `git fetch`es, then branches off `origin/<default>` (e.g. `origin/main`), falling back to the local `<default>` only if the remote ref is missing. `--position` (child/sibling/root) controls only where the worktree sits in the UI tree — never the git base. So a worker spawned from a feature branch still starts clean off `origin/main`; to build on unmerged work, land that work on the default branch first (then rebase the new worktree onto it).

### Orchestrate a team: spawn children with a role + brief (the orchestration spine)

This is the core fan-out workflow. When you're orchestrating, spawn each unit
of work as a **child** worktree and hand it a task **brief**. Workers spawned
this way become siblings of each other and children of you, the orchestrator.

```bash
tbd worktree create --position child --role worker --brief-file - <<'EOF'
task-specific brief here
EOF
```

Three knobs:

- **`--position`** places the worktree in the UI tree — it does NOT affect the
  git base (every worktree still branches off the default branch; see above).
  - `child` (default) nests under the caller — use this to fan out workers under yourself.
  - `sibling` spawns a peer alongside you — use only when you're *already* a worker
    under some parent and want a peer, not a child of yourself.
  - `root` forces a top-level worktree.
- **`--role orchestrator|worker`** tags the team role.
- **`--brief <text>` / `--brief-file <path>`** (use `-` for stdin) supplies the
  task brief, appended to the spawned session's system prompt.

TBD injects fixed, human-curated operating rules into every spawned child (and
any worktree given a `--role`) so the team keeps single-owner discipline. You
can't edit those rules — they're load-bearing. They tell each agent:

- **Single owner:** every worktree owns its own work. Make decisions, approvals,
  and questions with the human IN YOUR OWN worktree — never route decisions up to
  the parent. As an orchestrator you coordinate and keep awareness; you do NOT
  make product decisions or edit code for children — spawn a child to own the work.
- **Coordinate, don't escalate:** share status and surface blockers over the team
  channel (`tbd channel post`, below) as typed awareness — not by pushing
  decisions up or down the tree.

### Reparent a worktree

Move an existing worktree under a different orchestrator, or promote a child
to top-level. `--index` is optional and defaults to the end of the destination
sibling group.

```bash
tbd worktree reparent <worktree> --parent <name-or-id> [--index N]
tbd worktree reparent <worktree> --root [--index N]
```

### Send input to an existing terminal / read its output

```bash
tbd terminal send --terminal <id> --text "..." [--submit]
tbd terminal output <id> [--lines N]
```

### Pin / unpin a terminal

Pin a terminal to keep it docked and quickly reachable; unpin to remove it from the dock.

```bash
tbd terminal pin <id>
tbd terminal unpin <id>
```

### Pull the user's attention to a worker's tab

Use when an orchestrator wants the user to look at a specific child tab (e.g. a
worker needs input). Default is a **soft push** — a banner + an unread mark on
that worktree; the user lands on the tab when they choose to look. It does NOT
steal focus.

```bash
tbd terminal focus --terminal <id> [--message "..."]
```

Add `--activate` ONLY when the user has explicitly asked to be taken there — it
foregrounds the app and switches to the tab immediately, interrupting whatever
they're doing:

```bash
tbd terminal focus --terminal <id> --activate
```

Get `<id>` from `tbd terminal list <worktree>` or the output of `tbd terminal create`.

### Notify the TBD UI

```bash
tbd notify --type {response_complete|error|task_complete|attention_needed} --message "..."
```

### Coordinate over the team channel

A parent worktree and all its descendants share one append-only, ordered
message channel (the "team" = the root worktree of the subtree). Use it to
coordinate across agents — post status, surface blockers, announce PRs.

```bash
# Post a typed message (sender = TBD_WORKTREE_ID). --type defaults to note.
tbd channel post --type start    "Starting work on the migration"
tbd channel post --type blocker  "Blocked on schema review"
tbd channel post --type pr       "Opened PR #123"
tbd channel post --type done     "Finished and merged"
tbd channel post --type learning "GRDB re-runs renamed migrations; use addColumnIfMissing"
tbd channel post                 "free-form note"

# Read the shared thread (any team member sees the same messages).
tbd channel tail [--limit N] [--since <messageID>] [--json]
```

Types: `start`, `blocker`, `pr`, `done`, `learning`, `note`. Messages are
append-only — they can't be edited or deleted.

### Get a deep link to a worktree

```bash
tbd link [<worktree>]   # no arg = current
```

## Briefing requirements when spawning sessions

Always include:
- What you're trying to accomplish.
- What you've already tried or ruled out.
- Relevant file paths with line numbers.
- Enough context for the new session to make judgment calls, not just follow narrow steps.

Use `--prompt-file -` with a heredoc to avoid shell escaping issues.

## Env vars set in TBD-managed terminals

- `TBD_WORKTREE_ID` — current worktree UUID.
- `TBD_PROMPT_CONTEXT` — short context hint confirming you're inside a TBD-managed session. The full `tbd` skill is loaded by your harness when supported; other harnesses may fall back to reading `~/Library/Application Support/TBD/skill/SKILL.md`.
- `TBD_PROMPT_INSTRUCTIONS` — per-repo custom instructions (if configured).

## Outside a TBD terminal

If `TBD_WORKTREE_ID` isn't set, run `tbd worktree list` to find an ID, or `tbd worktree create` to make one. The CLI works from any shell on the same machine as the TBD daemon.
"""

}
