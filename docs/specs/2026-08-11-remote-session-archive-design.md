# Archiving finished remote sessions

## Problem

A remote provider's session inventory only grows. Every session TBD has ever
seen on a provider keeps a row in the sidebar for as long as that provider
keeps listing it, and a provider that retains its history — the common case,
since the log of a finished session is the reason to keep it — lists finished
sessions forever. The sidebar becomes a scrollback of everything the user has
ever run, with the two sessions they are actually working in buried inside it.

TBD already has the mechanism to hide a row: `remote.dismiss` sets
`remote_session.dismissed`, `RemoteSessionStore.upsert` never clears it, and
every session list filters dismissed rows out. What is missing is any way to
reach that mechanism for a finished session.

The row menu (`RemoteSessionActionMenu.items`) offers `Dismiss` only when a row
is `gone` — absent from the provider's last two `list` snapshots. A provider
that keeps reporting its finished sessions never produces a `gone` row, so on
such a provider `Dismiss` is unreachable by construction. The one affordance
that clears the sidebar is gated on the one condition that provider will never
satisfy.

A field measurement on one provider found 50 rows in terminal state `exited`
against 2 `running`, none of them `gone`, none dismissible.

## Design

### Data model

Unchanged. No migration, no new column, no feature flag. The design reuses
`remote_session.dismissed`, whose durability is already established: `upsert`
writes `payload`, `state`, `agentState`, `lastSeen`, `missingCount` and `gone`,
and deliberately does not touch `dismissed`, so a dismissal survives every
later snapshot that keeps reporting the session.

### What counts as sweepable

One predicate, evaluated daemon-side:

```
dismissed = 0
AND (state = 'exited' OR gone = 1)
AND pinnedAt IS NULL
```

- **`exited` or `gone`.** Both mean finished, by different evidence: `exited` is
  the provider's own report of a terminated process, `gone` is TBD's inference
  from two consecutive snapshots that omitted the row. A sweep that covered
  only one would leave the other needing a second, differently-shaped cleanup
  gesture for the same user intent.
- **Never `unknown`.** `RemoteSessionPayload.projectedForStaleSnapshot` demotes
  a non-terminal row to `unknown` when its provider stops producing a fresh
  inventory. `unknown` means "we cannot currently tell", not "finished".
  Sweeping it would hide live sessions during a provider outage — the moment
  the user most needs to see them.
- **Never pinned.** A pin is an explicit request to keep a row in front of the
  user, and dismissal drops pins (`remote.dismiss` clears `pinnedAt` in the
  same statement, so a hidden row cannot strand an invisible pin). Sweeping a
  pinned row would therefore destroy state the user asked for, silently, in
  bulk. A pinned finished session stays; the user can still dismiss it
  individually, which unpins it as an explicit single act.

The bulk statement does not need to write `pinnedAt = NULL` the way single
dismissal does: every row it selects already has a null pin.

### New verb: `remote.dismissExited`

```
remote.dismissExited { provider: String } -> { dismissed: Int }
```

Handled in `RPCRouter+RemoteHandlers`, implemented as one method on
`RemoteSessionStore` that runs a single `UPDATE` carrying the predicate above
and returns `db.changesCount`. It broadcasts a session-list delta once when
that count is non-zero, matching how `dismiss`, `markGone` and `setPinned`
already return "did anything change" so the handler can skip a pointless UI
broadcast.

Selection happens inside the daemon, against the mirror, rather than in the
app against a list it fetched earlier. That matters for three reasons:

- **It cannot race the poller.** An app-side loop sweeps whatever it last
  rendered. Between the user's click and the last call in the loop, a poll can
  land and change what is finished — dismissing a session that just started, or
  missing one that just exited. A daemon-side predicate reads current truth.
- **It is one actuation, not many.** The append-only actuation log records what
  the daemon did. Fifty rows of `remote.dismiss` describe a loop; one row of
  `remote.dismissExited` describes the act the user performed.
- **It is one broadcast.** An app-side loop produces a UI delta per call, so
  the sidebar animates fifty removals.

The returned count is the number of rows the daemon actually changed, which
may differ from the count the app showed in its confirmation if a poll landed
in between. The app reports the returned number, not the number it predicted.

### Row menu

`RemoteSessionActionMenu.items` gains a third branch, between the existing
`gone` branch and the live branch, for a row whose terminal state is `exited`:

- `Rename…`, `Attach`, `View Log` — kept, still gated as they are on a live
  row (`Rename…` on a fresh snapshot, `Attach` and `View Log` on their declared
  capabilities). All three read or annotate a session that has already run, and
  a finished session's log is usually the reason to keep the row at all, so
  this branch must not collapse to the inspection-free shape the `gone` branch
  uses.
- `Copy Session ID`, and the pin toggle — kept, as in every branch. Both are
  purely local and need no provider verb.
- `Stop` and `Send Text…` — dropped, for one reason: both drive a process the
  provider has already reported as terminated, so both are requests it can only
  refuse. Following the composition's established rule, an action that cannot
  succeed is omitted rather than shown disabled.
- `Dismiss` — added, after a divider, as the branch's destructive tail, in the
  slot `Stop` occupies on a live row.

The `gone` and live branches are unchanged. `items` is already a pure function
with no AppKit or SwiftUI dependency, so the new branch is directly unit
testable.

Because the terminal state now selects the branch, `items` takes the row's
state as a parameter. It keeps the existing `gone` flag as a separate argument
rather than folding both into one enum: `gone` is TBD's own bookkeeping about
whether the provider still reports the row, and `state` is the provider's claim
about the process. They are independent axes — a `gone` row carries whatever
state it last reported — and the `gone` branch wins when both apply, because a
row the provider no longer reports cannot answer a session verb whatever its
last known state was.

### Bulk entry points

Two, both provider-scoped, both reaching the same verb:

- **The Provider Desk.** `RemoteProviderDeskSummary` already computes the
  per-provider terminal counts the desk displays, including `exited` and
  `gone`, so the desk can state the number and offer the action that acts on
  it in the same place. A desk that shows a count of finished sessions without
  offering to clear them is a report about a problem it declines to fix.
- **The provider's sidebar header context menu.** `RemoteProviderHeaderRow` has
  no `contextMenu` today and gains one. This is the fast path — the user's
  complaint is about the sidebar, so the fix should be reachable from it
  without a navigation first.

Both are provider-scoped rather than section-scoped. A session whose
`meta["repo"]` resolved to a registered repo renders inside that repo's
section, not under the provider header, so a header-scoped sweep would clear
only the unmatched remainder while leaving most of the sidebar untouched — an
action whose effect depends on repo-resolution the user cannot see. Scoping to
the provider means the count shown and the rows removed agree, wherever those
rows happen to render.

Both spell the action "Clear Finished Sessions", with the sweepable count in
parentheses. "Finished" rather than "Exited" because the predicate covers
`gone` rows too, and a label naming only one of the two states would understate
what the action removes.

The action confirms before acting, naming the same count and stating that
pinned sessions are kept. The confirmation exists because there is no
un-dismiss verb — dismissal is not reversible through any UI surface — and
because the act is bulk. A single `Dismiss` stays unconfirmed, as it is today.

## Rejected alternatives

- **Automatically dismissing finished sessions past some age.** This acts
  without a user gesture and mutates persisted state, so it would require a
  default-off `config` column, a migration, and a soak — and it would decide on
  the user's behalf that a session old enough is a session unwanted. Age does
  not imply that. The manual sweep gives the same relief with no new
  configuration to get wrong and nothing that acts on its own.
- **Folding finished rows behind a collapsible group in the sidebar.** Purely
  presentational, nothing mutated, nothing hidden permanently. Rejected because
  it addresses only one surface: the rows remain in every list, count, and
  keyboard traversal, and each additional surface would need its own collapse.
  Dismissal already means "out of my sight" everywhere, and is the mechanism
  the schema was built around.
- **Looping the existing `remote.dismiss` from the app.** No new verb, smallest
  diff. Rejected for the race, the actuation-log noise, and the per-row
  broadcast described above.
- **An undo toast instead of a confirmation.** Lower friction, but it needs a
  second new verb to un-dismiss, and the ids it would restore live only in app
  memory, so the undo dies with an app restart while the dismissal does not.
  A confirmation covers irreversibility without introducing a recovery path
  that is itself unreliable.

## Feature-flag exemption

`CLAUDE.md` requires a default-off flag for behavior that mutates persisted
state. This ships without one, deliberately.

Every write here requires an explicit user gesture and passes a confirmation
naming its blast radius. Nothing runs on a timer, sweeps in the background, or
acts on the user's behalf. The sweep applies the semantics of `remote.dismiss`
— already an ungated user action — to a selection rather than a single row, and
the selection excludes exactly the rows a user has marked as wanted. This is
the "small additive UI" exemption in the same section, and the flag it would
otherwise add would gate a confirmed user action against nothing, then need a
migration to graduate and a second change to delete.

## Testing

- `RemoteSessionActionMenu.items` — the new `exited` branch: `Dismiss` present
  and destructive, `Stop` and `Send Text…` absent even when the provider
  declares `send`, the remaining inspection verbs still gated as on a live row,
  the pin toggle present in both polarities. The `gone` branch still wins for a
  row that is both `gone` and last-reported `exited`. The live branch is
  unchanged, including that it still offers `Stop` and `Send Text…` and still
  offers no `Dismiss`.
- `RemoteSessionStore` — the sweep dismisses `exited` and `gone` rows, skips
  pinned rows, skips already-dismissed rows, leaves `running` and `unknown`
  rows alone, is scoped to the named provider, and returns the number of rows
  it changed. Sweeping when nothing qualifies returns zero and reports no
  change, so the handler skips the broadcast.
- The durability property that the whole design rests on, pinned explicitly: a
  snapshot that still reports a dismissed session does not resurrect it.
- `RemoteProviderDeskSummary` already has count tests; the desk's new action
  reads those counts rather than recomputing, so no second counting path is
  introduced or tested.
