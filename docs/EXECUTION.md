# Parsing in small steps

Normally a parse runs until it is done. That is fine for most programs. But
some programs can't afford to stop for long: a UI thread, a game loop, a
server handling many requests, or a microcontroller with a watchdog timer. A
huge or hostile file could keep the parser busy for too long.

A **session** lets you parse a little at a time. Each call gets a budget of
**credits**, where one credit is one tiny step, such as looking at one byte.
When the budget runs out, the session pauses and remembers exactly where it
was. Call it again and it carries on. The final result is the same as parsing
in one call.

If you don't need this, ignore this page. Sessions are compiled out of
programs that don't use them.

DOT and markup have sessions that work the same way. The examples here use DOT;
the markup differences are in [the markup parser](#in-the-markup-parser).
The standalone [string validator](#standalone-string-validation) also supports
resumption, using its own bounded validation steps.

## The basic loop

```zig
var storage: dot.FixedDocumentStorage(.{
    .statements = 32, .nodes = 32, .edges = 16, .attributes = 32,
}) = .{};
var bag: dot.FixedDiagnosticBag(4) = .{};

var session = dot.BoundedSession.init(source, .{ .document = storage.storage() }, bag.sink(), .{});
defer session.deinit();

while (true) {
    const progress = session.advance(64); // spend at most 64 credits
    if (progress.outcome != null) break; // finished
    // Not finished yet: go do other work, then come back.
}

const parsed = session.result().?;
if (parsed.outcome == .success) {
    const document = parsed.document.?;
    _ = document;
}
```

Sessions use [fixed buffers](MEMORY.md#option-3-fixed-buffers-no-allocator)
only. With an allocator, growing a list could copy a lot of data in what
should be one small step.

The [bounded example](../examples/bounded.zig) runs this loop and shows
cancelling.

## What a credit buys

One credit pays for one of these:

- looking at one byte of input (or one 64-byte block, with the
  [block scanner](#two-scanners))
- one step of the grammar
- adding one item to the document

A few rules make budgets predictable:

- A budget of N never does more than N steps.
- A budget of 1 always makes progress, even inside a long comment.
- `advance(0)` does no work. It only notices a cancel request.
- Running out of credits is a pause, not an error.
- However you split the budget across calls, the result is the same.

**Unreleased optimization:** a metered scalar scanner can handle several ordinary bytes in a
tight loop. Each examined byte still costs its own credit; scanning stops at
the first boundary and never looks beyond the budget or the next cancellation
poll. This is an optimization, not a larger credit unit. One-credit calls and
the block scanner keep their existing accounting, with no extra session storage.

Credits measure work, not time. They don't count time spent in your own
callbacks (your diagnostic sink, your cancel check). DOT/markup validation,
explicit decoding and rendering are separate steps and aren't metered.
The standalone string processor has its own metered validation steps described
[below](#standalone-string-validation).

To compare execution costs on dense syntax and long ASCII/Unicode text, run
`zig build bench-metering -Doptimize=ReleaseFast` (or `ReleaseSafe`). It reports
default parsing, budgets 1/64/4096, cancellation intervals 1/64 and runtime
policies for both scanners. Input and fixed pools are prepared before timing;
results include credits, poll counts and session sizes. Validation is not timed.

## Standalone string validation

> **Unreleased.**

`string_processor.Profile` uses the same `.policy.execution` fields (`metering`,
`cancellation`, positive `cancellation_interval`), default-off features, and
`Session.init/advance/run/result/cancel/reset/deinit` lifecycle. Unlike DOT and
markup, its content validation itself is resumable: encoding, built-in checks
and custom `State`/`step` validators all advance within the budget. No allocator
or fixed pools are needed. With runtime policies, `advance` needs `try` and can
return `MeteringDisabled`. See [string execution](STRINGS.md#metering-cancellation-and-sessions)
for its credit units, custom contract, borrowed lifetimes and preparation costs.
This does not yet connect string work to a parent DOT/markup session budget.

## Checking progress

`advance` returns a `SessionProgress`:

| Field | Meaning |
| --- | --- |
| `outcome` | `null` while paused; the final outcome once finished |
| `work_used` | credits spent in this call |
| `source_frontier` | how far into the input the parser has looked |
| `completed_statements` | statements accepted so far |
| `syntax_errors` | syntax errors found so far |

Once finished, `session.result()` returns the full result. Calling `advance`
again after that does nothing and keeps the result.

`session.run()` finishes the rest in one go.

## Cancelling

There are two ways to stop a session early.

**Call `session.cancel()`** between calls. This always works.

**Give it a cancel check.** Turn on `execution.cancellation` and pass a
function that returns `true` when the work should stop. By default, the session
calls it before every step:

```zig
const Request = struct {
    stop: bool = false,
    fn poll(context: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.stop;
    }
};

const Session = dot.Profile(.{ .policy = .{ .execution = .{
    .metering = true,
    .cancellation = true,
} } }).Session;

var request: Request = .{};
var session = Session.init(source, .{ .document = storage.storage() }, bag.sink(), .{
    .cancellation = .{ .context = &request, .is_requested = Request.poll },
});
defer session.deinit();
```

A cancelled parse ends with `outcome == .cancelled`, no document, and no
diagnostic. If the parse had already finished, a late cancel doesn't replace
its result.

With [DOT](EDITORS.md#keep-the-finished-part-of-a-dot-file) or
[markup partial results](EDITORS.md#keep-the-finished-part-of-markup) turned on,
a cancelled parse can instead return the part recognised before
the cancel. Keeping it costs no extra scanning or allocation.

The same `.cancellation` option works on the one-call functions
(`parseAndValidate` and others) when the profile turns cancellation on.

The check is a plain function call. There are no threads, signals or timers
inside the library. If another thread sets your flag, make it an atomic.

### Cancellation interval

> **Unreleased.** The 0.5.0 release always uses interval 1.

Both parsers accept `execution.cancellation_interval`, a positive `u32`, default
`1`. It limits the number of existing **work steps** between callback checks:

```zig
const Parser = dot.Profile(.{ .policy = .{ .execution = .{
    .metering = true,
    .cancellation = true,
    .cancellation_interval = 64,
} } }); // markup.Profile accepts the same execution settings
```

Larger intervals reduce polling overhead but can notice cancellation later.
The minimum multiplier is **1 for both scanners**, not 64 for the block scanner.
Scalar lexical steps examine one source code unit; block steps classify or
process windows of up to 64 units. UTF-8 units are bytes; UTF-16/32 units are
two/four bytes. Classification, token processing, grammar, output and recovery
also consume steps, so the interval is **not an exact byte count or time limit**.
It does not change block width, work-credit costs, or charge callbacks by time.

- Every active `advance`/`run` call checks on entry, including `advance(0)`.
  Small caller budgets can therefore cause more frequent checks than requested.
- `advance(N)` still spends at most N credits, even when the interval is larger.
  Pausing needs no cancellation request; the next call resumes normally.
- A concrete failure or successful commit still takes precedence over a later
  cancellation check. Finished sessions do not poll again; `cancel()` remains
  immediate and terminal.
- Fixed profiles specialize the interval at compile time. Runtime-enabled
  profiles validate and resolve it once at initialization/reset; it stays fixed
  across yields. An invalid reset preserves the existing session.
- `0` is invalid even when cancellation is disabled. Fixed baselines fail to
  compile; runtime patches return `error.InvalidCancellationInterval` before
  reading input, allocating storage or calling the cancellation hook.
- The interval applies to parsing and measurement, including event-only DOT
  execution. Markup validation keeps its existing safe-point checks; those
  passes are not work-metered. Inner processors use their own execution policy.

Runtime override example (also valid with `markup.Profile`):

```zig
const Runtime = dot.Profile(.{ .runtime_policy = true, .policy = .{
    .execution = .{ .metering = true, .cancellation = true },
} });
var session = try Runtime.Session.init(source, memory, bag.sink(), .{
    .policy = .{ .execution = .{ .cancellation_interval = 64 } },
    .cancellation = hook,
});
defer session.deinit();
```

Use `zig build bench-cancellation -Doptimize=ReleaseFast` (or `ReleaseSafe`) to
compare intervals 1, 4, 16, 64 and 256 on both scanners and both parsers, with
fixed/runtime policies and metering on/off. The benchmark reports throughput,
callback counts, credits and session sizes; source/pool allocation is outside
timing. Interval 1 remains the default, not a claim that larger is always faster.

## Rules while a session is paused

- Keep the source, the buffers, the bag and the cancel context alive and at
  the same address.
- Don't read the buffers until the session has finished.
- You may move the session value between calls, but don't copy it and use
  both copies.
- Call `deinit()` when you abandon a session. It never frees your buffers.
- `session.reset(source, sink, options)` starts a new parse in the same
  buffers. Documents from the earlier parse become invalid.
- Once the session has finished with a document, `session.validate(sink, .{})`
  validates it. Validation doesn't use credits. For an
  [unfinished document](EDITORS.md#keep-the-finished-part-of-a-dot-file),
  it also reports that part of the file wasn't checked.

## Choosing the session type

| Type | Use it for |
| --- | --- |
| `dot.BoundedSession` | budgets, no cancel check |
| `dot.Profile(.{ .policy = .{ .execution = .{ .metering = true, .cancellation = true } } }).Session` | budgets and a cancel check |
| `dot.Profile(.{ .policy = .{ .execution = .{ .cancellation = true } } }).Session` | a cancel check without budgets; call `run()` |

Calling `advance` on a session without metering is a compile error.

## Two scanners

The *scanner* is the part that reads raw bytes. Both parsers have two, and in
each parser they give exactly the same results. The numbers below are for the
DOT parser:

- **`.scalar`** (default) reads one byte at a time. It is the faster choice for
  ordinary files, uses less memory, and works the same on every target.
- **`.block`** reads 64 bytes at a time using vector instructions. It does
  better when you run sessions with very small budgets (2 to 4 times faster
  at one credit per call), or when files are mostly very long names, strings
  or comments. It is slower on targets without vector instructions, such as
  plain wasm32.

On aarch64 macOS with Zig 0.16.0, scalar state is 64 bytes in Debug/ReleaseSafe
and 56 bytes in ReleaseFast/ReleaseSmall. Block state is 152 bytes in all four
modes. They can differ on other targets; see [type sizes](PERFORMANCE.md#type-sizes)
and use `@sizeOf` for your own build.

```zig
const Parser = dot.Profile(.{ .policy = .{ .scanner = .block } });
```

Measured numbers are in [Performance](PERFORMANCE.md).

## In the markup parser

Markup sessions follow everything above, with the same calls (`advance`,
`run`, `cancel`, `reset`, `result`) and the same rules while paused:

```zig
var session = markup.BoundedSession.init(source, .{
    .document = nodes.storage(),
    .scratch = frames.storage(),
}, bag.sink(), .{});
defer session.deinit();
while (session.advance(64).outcome == null) {}
```

The differences:

- A markup credit also pays for comparing one byte of a closing tag's name, and
  for each step of searching back for a matching open tag after an error.
- The memory to pass is described in
  [the markup parser's memory](MEMORY.md#in-the-markup-parser).
- Checking labels during DOT parsing runs to completion. A DOT profile with a
  label processor has no `Session`.

## Examples

- [bounded.zig](../examples/bounded.zig): a budget loop, then cancelling a
  session
- [policies.zig](../examples/policies.zig): a session whose scanner and checks
  are chosen at run time

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.

## Not available yet

- Validation in steps, or cancellation during DOT validation. Markup validation
  already checks cancellation at safe points, without work-credit metering.
- Checking HTML-like labels in steps.
- Feeding input in pieces. The whole input must be in memory before parsing
  starts.
- A total budget across calls. `advance(n)` limits one call. If you keep
  calling it, keep your own running total.

See the [roadmap](ROADMAP.md).
