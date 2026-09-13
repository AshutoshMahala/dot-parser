# Bounded parsing and cancellation

Use `BoundedSession` when parsing must share execution time cooperatively with
other work. It uses caller-owned fixed pools and allocates nothing. Input is a
complete, immutable byte slice; yielding is not a request for more input.

```zig
var storage: dot.FixedDocumentStorage(.{
    .statements = 32, .nodes = 32, .edges = 16, .attributes = 32,
}) = .{};
var bag: dot.FixedDiagnosticBag(4) = .{};
var session = dot.BoundedSession.init(source, storage.storage(), bag.sink(), .{});
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

One credit buys one source-byte/EOF examination, one fixed-size grammar
transition, or one normal event attempt, including begin and commit. These are
separate operations. A budget of N permits at most N such steps; unused credits
are not carried forward. One credit can advance an uncancelled, nonterminal
session even inside a long comment or quoted identifier.

`advance(0)` does no normal work. It yields, or observes cancellation and performs
terminal cleanup. Exhausting a call's budget is not `.resource_exhausted`.
That outcome still means a configured statement/pair limit was reached; full
pools still produce `.storage_failure` with a diagnostic.

Credits do not bound CPU instructions or wall-clock time. User diagnostic and
cancellation hooks are callouts; their execution time is excluded. Terminal
housekeeping can attempt one diagnostic and one internal cleanup abort without
another credit. Validation, identifier decoding, and rendering are separate,
unbudgeted operations. There is no OS clock, scheduler, thread, or hidden worker.

## Progress and completion

`advance` returns `SessionProgress`:

- `phase`: scan, grammar, dispatch, or terminal.
- `source_frontier`: one past the highest byte offset examined, including
  lookahead; zero before any byte read. EOF costs work but does not move it.
  It is monotonic but is not a count of accepted source bytes.
- `completed_statements` and `completed_pairs`: accepted syntax events, not
  reservations. A yielded attribute list can have pairs but no completed owner.
- `work_used`: credits spent in this call, not a lifetime total.
- `outcome`: null while yielded, otherwise the terminal ParseOutcome.
- `diagnostic_delivery`: whether failure diagnostics reached their sink.

`result()` is null while parsing. Once terminal, it returns FixedParseResult;
the document exists only on success. Progress counts can describe output later
discarded on failure or cancellation. No partial document is published.
Successful parsing does not imply semantic validation succeeded.

`run()` finishes the remaining parse without returning intermediate yields.
Repeated advance, run, cancel, and result calls after termination preserve
the result. They perform no more scans, polls, diagnostics or lifecycle events.

## Optional cancellation

```zig
const Session = dot.FixedSession(.{ .cancellation = true });
var session = Session.init(source, storage.storage(), bag.sink(), .{
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

`FixedSession(.{ .metering = false, .cancellation = true })` supports cancellable
run without work counters. With metering disabled, advance is a compile
error. With cancellation disabled (the default), hook storage and checks compile
out. Explicit cancel cleanup remains available in every configuration.

Keep source bytes, pools, diagnostic context and cancellation context alive at stable addresses
across yields. Do not inspect/mutate the pools while parsing or copy a live
session into a second owner. Moving it between calls is supported; calls must
not overlap or reenter. A completed document borrows source/pools, not the session.

`reset(source, diagnostics, options)` cancels unfinished work and starts a new
parse using the same pools. It invalidates all previous document views into
those pools; retire those views before reuse. Cancellation/abort clears logical
lengths, not the underlying bytes: it is not a secure-erasure facility.

See [ownership](OWNERSHIP.md), [measured costs](BASELINES.md), and the precise
[execution contract](architecture/EXECUTION_CONTRACT.md). Public pull events,
chunked input, recovery, total-operation work limits and bounded validation
remain outside this slice.
