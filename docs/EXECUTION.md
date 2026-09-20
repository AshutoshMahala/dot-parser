# Bounded parsing and cancellation

Use `BoundedSession` when parsing must share execution time cooperatively with
other work. It uses caller-owned fixed pools and allocates nothing. Input is a
complete, immutable byte slice; yielding is not a request for more input.

```zig
var storage: dot.FixedDocumentStorage(.{
    .statements = 32, .nodes = 32, .edges = 16, .attributes = 32,
}) = .{};
var bag: dot.FixedDiagnosticBag(4) = .{};
var session = dot.BoundedSession.init(source, .{ .document = storage.storage() }, bag.sink(), .{});
defer session.deinit();

while (true) {
    const progress = session.advance(64);
    if (progress.outcome != null) break;
    // Return to your event loop or do other application work here.
}
const parsed = session.result().?;
if (parsed.outcome == .success) {
    const document = parsed.document.?;
    // Traverse or validate the committed syntax document.
    _ = document;
}
```

The [runnable example](../examples/bounded.zig) demonstrates both budgeting and
cancellation. `parseBorrowedIn` remains the simplest fixed-storage one-shot API.

## What a credit means

One credit buys one lexical step, one fixed-size grammar transition, or one
normal event attempt, including begin and commit. These are separate
operations. A lexical step is one source-byte/EOF examination with the scalar
scanner; with the opt-in block scanner it is the classification of one
64-byte block or one bounded advance inside it
(see [scanner backends](#scanner-backends)).
A budget of N permits at most N such steps; unused credits are not carried
forward. One credit can advance an uncancelled, nonterminal
session even inside a long comment or quoted identifier.

`advance(0)` does no normal work. It yields, or observes cancellation and performs
terminal cleanup. Exhausting a call's budget is not `.resource_exhausted`.
That outcome still means a configured statement/pair/nesting limit was reached; full
pools still produce `.storage_failure` with a diagnostic.

Credits do not bound CPU instructions or wall-clock time. User diagnostic and
cancellation hooks are callouts; their execution time is excluded. Terminal
housekeeping can attempt one diagnostic and one internal cleanup abort without
another credit. With `Policy.recovery = .statements`, each recovered
syntax error and each lexical warning is one more diagnostic callout attached
to the microstep that found it; the abort still happens once. Validation, identifier decoding, and rendering are separate,
unbudgeted operations. There is no OS clock, scheduler, thread, or hidden worker.

## Progress and completion

`advance` returns `SessionProgress`:

- `phase`: scan, grammar, dispatch, or terminal.
- `source_frontier`: one past the highest byte offset examined, including
  lookahead; zero before any byte read. EOF costs work but does not move it.
  It is monotonic but is not a count of accepted source bytes; the block
  scanner moves it a whole 64-byte block at a time.
- `completed_statements` and `completed_pairs`: accepted syntax events, not
  reservations. A yielded attribute list can have pairs but no completed owner.
  A chain counts as one statement when its owner is accepted, not once per
  operator. Continuations can be staged before this count changes. A subgraph
  counts when its closing event succeeds; entry reserves its order slot but does
  not increment this counter. Nested child statements can complete first.
- `work_used`: credits spent in this call, not a lifetime total.
- `outcome`: null while yielded, otherwise the terminal ParseOutcome.
- `diagnostic_delivery`: whether failure diagnostics reached their sink.

`result()` is null while parsing. Once terminal, it returns FixedParseResult;
the document exists only on success. Progress counts can describe output later
discarded on failure or cancellation. No partial document is published.
Successful parsing does not imply semantic validation succeeded.

Each chain continuation gets its own grammar transition and event credit;
there is no unbudgeted loop over a whole chain inside parsing. Fixed pools
bound chain owners and continuation records separately. Neither
`max_statements` nor a per-call budget is a total chain-length limit.

Each qualified node reference also has a separately charged `portedReference`
event that stages one record. It increments neither completed statements nor
pairs. Both suffix components and intervening trivia can yield/cancel, including
after either colon. The parser may retain and replay a lookahead token to finish
the suffix and its owner; each replay charges grammar work, without rescanning
the token. Reserve `ported_references` capacity separately from statement/link
capacities. No staged port record becomes a public partial document.

Each subgraph entry and exit has a separate normal callback credit. Opening a
scope pushes one fixed scratch frame in its grammar transition; accepting the
exit pops one frame. A standalone scope completes in a separate charged callback
once lookahead rules out an edge operator. An endpoint scope does not increment
completed statements; its final edge/chain owner does. Entering a right endpoint
stages at most one generalized owner/link and saves an existing node-only prefix
by range, never copying it. There is no unbudgeted loop over ancestors or descendants.
Cancellation clears logical frame length without unwinding recursively, emits
no synthetic per-scope close callbacks, and publishes no partial document.
`max_nesting` (root depth 0) is a terminal policy limit, independent of per-call
credits and the caller's `FixedParseScratch` capacity. Pass document pools and
scratch separately in the `ParseMemory` bundle; [example](../examples/subgraphs.zig).

Scope iterators, like validation and identifier decoding, are separate
unbudgeted operations. A recursive view means “include descendants,” not use
recursive function calls.

`run()` finishes the remaining parse without returning intermediate yields.
Repeated advance, run, cancel, and result calls after termination preserve
the result. They perform no more scans, polls, diagnostics or lifecycle events.

## Optional cancellation

```zig
const Session = dot.Profile(.{ .policy = .{ .execution = .{
    .metering = true, .cancellation = true,
} } }).Session;
var session = Session.init(source, .{ .document = storage.storage() }, bag.sink(), .{
    .cancellation = .{ .context = &request, .is_requested = Request.poll },
});
defer session.deinit();
```

`Request.poll` has type `fn (?*anyopaque) bool`: true requests cancellation.
The hook and its context are caller-owned. A null hook never requests it.
Polling occurs at entry and before every next microstep, including each source
examination, with at most N + 1 polls per call for N steps. No polling occurs after a
terminal result. Hooks must not fail or reenter the session. Threads/signals may
request cancellation through a caller-designed adapter, but that adapter owns
synchronization and signal safety. A plain shared flag is not automatically safe.

Cancellation produces `.cancelled`, no document, and no failure diagnostic.
Staged output is discarded. A concrete syntax/storage failure already obtained
wins over a later request; successful commit also wins immediately. A request
observed before commit prevents commit.

`session.cancel()` provides immediate terminal cleanup even when polling is
disabled. `deinit()` calls that cleanup for unfinished work; neither frees the
caller's pools. Use it when abandoning a yielded parse rather than just dropping
the value.

## Independent features and lifetime

`Profile(.{ .policy = .{ .execution = .{ .metering = false, .cancellation = true } } }).Session`
supports cancellable run without work counters. With metering disabled in a fixed
profile, advance is a compile error. With cancellation disabled in a fixed
profile (the default), hook storage and checks compile out. Runtime profiles
retain the cancellable alternative. Explicit cancel cleanup remains available
in every configuration.

Profiles default to unmetered execution; `dot.BoundedSession` is the named
metered preset. Runtime-enabled profiles accept the same execution settings at
init/reset. They select a driver once and dispatch only at call boundaries;
`advance` returns `error.MeteringDisabled` without work when the selected runtime
policy is unmetered. [Policies](POLICIES.md) covers the full API.

Keep source bytes, pools, nesting scratch, diagnostic context and cancellation context alive at stable addresses
across yields. Do not inspect/mutate the pools while parsing or copy a live
session into a second owner. Moving it between calls is supported; calls must
not overlap or reenter. A completed document borrows source/pools, not the session.

`reset(source, diagnostics, options)` cancels unfinished work and starts a new
parse using the same pools. It invalidates all previous document views into
those pools; retire those views before reuse. Cancellation/abort clears logical
lengths, not the underlying bytes: it is not a secure-erasure facility.
Runtime reset verifies configuration first; rejection leaves the old session
and views intact. Each successful reset inherits the compiled baseline, not
the previous operation's overrides. Source/scanner/execution/limits remain
fixed across yields. Session `validate(diagnostics)` and `interpretation()` use
the latched graph policy after success, as explicit unbudgeted operations.

## Scanner backends

Two lexers implement the same scanner interface and produce identical tokens,
spans, diagnostics, fixes and warnings; the choice only changes speed, state
size and what a lexical credit buys. The default is the scalar scanner, which
examines one byte per credit and keeps 56 B of state; measured on Apple
silicon it is the faster of the two on every ordinary workload, run to
completion or at ordinary budgets. The block scanner classifies 64-byte
blocks with vector compares and extracts tokens from the resulting bit masks;
it keeps 160 B of state, and because one credit classifies 64 bytes it needs
2–6x fewer credits for the same input and resumes more cheaply, so it wins
when sessions run on very small budgets (2–4x at one credit per call) or the
input is dominated by long identifiers, strings or comments (numbers in the
[changelog](../CHANGELOG.md)). These are the recorded pre-migration measurements;
the policy refactor still needs standard-machine remeasurement. Select a backend
in the profile:

```zig
const Parser = dot.Profile(.{ .policy = .{ .scanner = .block } });
```

`Parser.baseline.scanner` reports the compiled baseline. Runtime-enabled profiles
may override it per operation/reset. Fixed session storage follows the selected
backend; runtime session storage holds the largest selectable driver plus a tag.
Measure the containing struct. Direct lexical consumers can use
`dot.lexer.For(.block)`; `dot.lexer.Lexer` and
`dot.Profile(.{}).baseline.scanner` describe the scalar default.

See [ownership](OWNERSHIP.md), [measured costs](BASELINES.md), and the precise
[execution contract](architecture/EXECUTION_CONTRACT.md). Public pull events,
chunked input, total-operation work limits and bounded validation remain
outside this slice; statement-boundary recovery is available through the policy.
