# Per-create Codex model override

**Date:** 2026-09-15
**Status:** Design

## Problem

TBD starts every Codex terminal with its `tbd` Codex profile and therefore
inherits the model from the user's Codex configuration. That shared default is
useful, but it cannot express a one-session choice. A user cannot keep one
long-lived terminal on a stronger model while leaving other terminals on the
configured default.

Claude already has a separate model concept in TBD: `ModelProfile.model` and
`WorktreeCreateParams.model` feed `ANTHROPIC_MODEL`. Reusing either for Codex
would conflate two agents with different configuration mechanisms.

## Goals

- Let `tbd terminal create --type codex --model <id>` select the model for that
  fresh Codex terminal.
- Let `tbd worktree create --codex-model <id>` select the model for the fresh
  primary terminal when that worktree's resolved primary agent is Codex.
- Preserve every existing command byte-for-byte when no override is supplied.
- Persist the requested model on the terminal row and show it as requested
  state in the UI; observed runtime remains hook/process evidence.
- Permit an explicit in-place live switch that preserves the terminal row,
  tmux window, and Codex thread, or fails closed before touching the pane.

## Non-goals

- Selecting Codex as the primary worktree agent. `--codex-model` modifies a
  Codex primary selected by the existing preference; it does not select the
  agent kind.
- Changing the model of `terminal.continueInCodex` unless the user explicitly
  chooses it in that action's picker.
- Validating model identifiers against a TBD-owned allowlist. Codex owns that
  vocabulary and reports unsupported values.
- Changing Claude model selection.

## Design

### CLI surface and validation

`TerminalCreate` gains an optional `--model <id>`. The option is valid only
when `--type codex` is explicit. Supplying it with `--type claude`, `--type
shell`, or no type fails argument validation before the CLI opens the daemon
socket. The error says that `--model` requires `--type codex`, that Claude
models come from TBD model profiles, and that shell terminals have no model.

`WorktreeCreate` gains an optional `--codex-model <id>`. Worktree creation
resolves its primary agent in the daemon, so the CLI cannot validate the agent
kind. The option does not alter that selection. The lifecycle consumes it only
in the `.codex` primary-spawn branch; Claude and shell primaries retain their
current behavior.

Both values remain opaque strings. TBD performs shell escaping but does not
normalize, alias, or verify the identifier.

### RPC and data flow

The CLI sends the terminal option as an optional `model` field on
`TerminalCreateParams`. It sends the worktree option as an optional
`codexModel` field on `WorktreeCreateParams`; the distinct name preserves the
existing Claude-only `model` field.

The terminal handler passes `params.model` only to its fresh `.codex` spawn and
stores it on the terminal row. The live model action uses the same row's
recorded Codex thread identity and a staged in-place respawn; a missing
identity, parked row, holder transport, stale snapshot, or failed preparation
is a refusal with the old pane untouched.
The worktree handler carries `params.codexModel` through
`completeCreateWorktree` and the existing pre-session phase, if present, to
the primary-terminal spawn. `spawnPrimaryTerminals` passes it only from the
`.codex` switch arm.

Both create RPC fields are optional and default to `nil` in their public
initializers. Older clients omit them, and newer daemons decode omission as
the current behavior. Older daemons ignore the additional JSON keys. No field
is written to the terminal, worktree, repository, profile, or config tables.

### Codex command construction

`CodexSpawnCommandBuilder` accepts an optional model override for fresh
launches. When present, it inserts these two arguments immediately after the
profile selection and before `--dangerously-bypass-approvals-and-sandbox`:

The first argument is `-c`. The second is the complete `model=<id>` assignment,
escaped as one shell argument.

Conceptually, a launch becomes:

```text
codex --profile tbd -c 'model=<id>' --dangerously-bypass-approvals-and-sandbox [prompt]
```

The implementation builds the complete `model=<id>` assignment and passes it
through `SystemPromptBuilder.shellEscape`. It does not interpolate the raw
identifier into the command. When the override is `nil`, the builder emits the
exact string it emits today, including executable quoting, detected profile
flag, argument order, and prompt placement.

Fresh `terminal create` and fresh Codex-primary `worktree create` call sites
pass the override. A live model switch passes the persisted thread ID to
`codex resume` and the selected model in the same command, then replaces the
existing tmux window in place. The row's requested model is updated before
launch under the replacement-incarnation fence; an RPC response is not
treated as observed runtime until the new process's hook evidence arrives.

### Documentation

The spawned `tbd` skill in `TBDSkillContent.swift` gains one sentence beside
the `terminal create --type codex` example. It documents `--model <id>` as a
one-terminal override and names `worktree create --codex-model <id>` as the
equivalent for a Codex-primary worktree. The skill continues to direct users
to command help for the complete flag list.

## Error handling

The terminal CLI rejects an override on Claude, shell, or an unspecified type
with a `ValidationError`; it never sends an incoherent request. Once accepted,
TBD treats the model identifier as Codex input. If Codex rejects it, the
terminal exposes Codex's own launch error through the existing spawn behavior.

Worktree creation does not fail merely because `--codex-model` accompanies a
non-Codex primary. The resolved primary kind is configuration-dependent, and
the option is scoped to the `.codex` branch rather than made into a second
agent-selection mechanism.

## Tests and verification

`CodexSpawnCommandBuilderTests` covers both branches introduced by the
optional value:

- A model containing shell-significant characters is appended as `-c
  model=<id>` in the required position and is escaped as one argument.
- An absent model produces a command byte-identical to the existing command.

CLI tests parse `TerminalCreate` and verify that `--model` is accepted with
`--type codex` and refused with both `--type claude` and `--type shell`. A
missing `--type` is refused by the same validation rule.

Implementation verification runs `scripts/swift-safe build` and the full
`scripts/test.sh` suite. The supported installed updater is separate: it must
build a clean released-source checkout, hand over the daemon, and prove one
daemon/app plus unchanged terminal row/window/thread identity. The updater
must not install this unmerged feature branch.

## Placement and rollout

This behavior belongs in the compiled CLI-to-daemon spawn path because only
that path has the per-create request, resolved terminal kind, and safe command
construction. A user-authored wrapper could add `-c` only by bypassing TBD's
normal Codex spawn and instrumentation.

No feature flag is warranted. The behavior requires an explicit create-time
option, performs no autonomous action, destroys no state, and leaves the
load-bearing spawn path unchanged when the option is absent. It creates no new
durable resource, so the reconciler doctrine does not apply.

## Alternatives considered

### Explicit optional RPC fields — chosen

Carry the one-shot value on the existing create requests and apply it at the
two fresh Codex spawn sites. This matches the lifetime of the user's choice,
keeps old clients compatible, and makes the no-override branch identical to
today.

### Reuse `ModelProfile.model` or `WorktreeCreateParams.model` — rejected

Those fields describe Claude routing and ultimately set `ANTHROPIC_MODEL`.
Codex uses its own `-c model=...` override. Reuse would make a Claude profile
silently control Codex and would leave `worktree create --model` ambiguous
between agents.

### Mutate Codex config or inject a shared environment value — rejected

Editing `tbd.config.toml`, `config.toml`, or shared spawn environment would
outlive one create request and affect unrelated terminals. Restoring the old
value would also introduce races between concurrent creates. A command-line
override has the required one-process lifetime without shared mutation.
