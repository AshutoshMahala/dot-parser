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
The standalone [string checker](#standalone-string-validation) also has
sessions, with its own kind of steps.

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
- handing one finished item to the document (or to your
  [event callback](EVENTS.md))

A few rules make budgets predictable:

- A budget of N never does more than N steps.
- A budget of 1 always makes progress, even inside a long comment.
- `advance(0)` does no work. It only notices a cancel request.
- Running out of credits is a pause, not an error.
- However you split the budget across calls, the result is the same.

Credits measure work, not time. They don't count the time spent inside your
own callbacks (your diagnostic sink, your cancel check, your event callbacks).
DOT and markup validation, decoding names and printing diagnostics are
separate steps and aren't metered. The standalone string checker meters its
own checks; see [below](#standalone-string-validation).

## Standalone string validation

> **Unreleased.** Not in 0.5.0.

The `string_processor` module's `Profile` has sessions too. It uses the same
`.policy.execution` settings (`metering`, `cancellation` and
`cancellation_interval`, all off or `1` by default) and the same calls:
`Session.init`, `advance`, `run`, `result`, `cancel`, `reset` and `deinit`.

Unlike DOT and markup, here the checking itself runs in steps: the encoding
check, the built-in checks and your own `State`/`step` checks all stay within
the budget. No allocator or buffers are needed. With run-time settings,
`advance` returns an error union and gives `error.MeteringDisabled` when
metering is off.

A string session has its own budget. It isn't counted in the budget of a DOT
or markup session. [String sessions](STRINGS.md#metering-cancellation-and-sessions)
explains what a credit buys there, how to write a resumable check, and how
long the input must stay alive.

## Checking progress

`advance` returns a `SessionProgress`:

| Field | Meaning |
| --- | --- |
| `outcome` | `null` while paused; the final outcome once finished |
| `work_used` | credits spent in this call |
| `phase` | where the parser paused: `.scan` (reading input), `.grammar` (a token is waiting for its grammar step), `.dispatch` (a finished item is waiting to be stored or handed to your callback) or `.terminal` (finished) |
| `source_frontier` | how far into the input the parser has looked, in bytes. Looking at the end of the input costs a credit but doesn't move it. |
| `completed_statements` | statements finished so far |
| `completed_pairs` | `key=value` pairs finished so far, including `key = value` statements |
| `syntax_errors` | syntax errors found so far |
| `warnings` | warnings found so far |
| `accepted_deviations` | [lenient](POLICIES.md#lenient-syntax) mistakes accepted so far |
| `diagnostic_delivery` | `.failed` if a diagnostic couldn't be handed to your sink, otherwise `.complete` |
| `diagnostic_stop` | why diagnostics stopped (for example, `.requested` when the bag [asked to stop](ERRORS.md#where-diagnostics-go)), or `null` |

The counts show progress only. If an error later throws away part of a
statement, the counts already include it. The document itself is never
readable before the session has finished.

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

What you get after a cancel:

- The outcome is `.cancelled` and, by default, there is no document.
- Cancelling adds no diagnostic of its own, and it never throws away a
  finding the parser had already made. Errors and warnings found before the
  cancel still reach your bag and are counted.
- If one of those findings is an error and `on_error` is `.fail_fast`, the
  outcome is `.invalid_syntax` instead.
- If parsing had already finished, a late cancel doesn't replace its result.

With [DOT](EDITORS.md#keep-the-finished-part-of-a-dot-file) or
[markup partial results](EDITORS.md#keep-the-finished-part-of-markup) turned on,
a cancelled parse can instead return the part recognised before
the cancel. Keeping it costs no extra scanning or allocation.

The same `.cancellation` option works on the one-call functions
(`parseAndValidate` and others) when the profile turns cancellation on.

The check is a plain function call. There are no threads, signals or timers
inside the library. If another thread sets your flag, make it an atomic.

### Calling the session from a callback

While your cancel check, diagnostic sink or event callback runs, the session
is in the middle of a step. So there are rules for what that code may do:

- (unreleased) A cancel check may call its own session's `cancel()` and then
  return `false`. The session stops as cancelled before another work step or
  credit is spent, just as if the check had returned `true`. This works for
  DOT and markup sessions, and for
  [IR](IR.md#small-steps-and-cancelling) and [string](STRINGS.md) sessions.
- No callback may call `advance`, `run`, `reset` or `deinit` on the session
  that is running.
- Your diagnostic sink and event callbacks must not call the session at all.
  To stop from there, return `.stop`. A sink that stops gives the outcome
  `.diagnostic_stopped`; see [writing your own sink](ERRORS.md#writing-your-own-sink).
- Don't call `cancel()` from inside an allocator the session is using, and
  don't call one session from two threads at the same time. To cancel from
  another thread, set a flag that your cancel check reads.

### Cancellation interval

> **Unreleased.** Not in 0.5.0, which always checks before every step.

Calling the cancel check before every step can cost noticeable time. Both
parsers accept `execution.cancellation_interval` to call it less often. It is
the most **work steps** between two calls, at least `1`, and `1` by default:

```zig
const Parser = dot.Profile(.{ .policy = .{ .execution = .{
    .metering = true,
    .cancellation = true,
    .cancellation_interval = 64,
} } }); // markup.Profile accepts the same execution settings
```

A larger interval costs less time but notices a cancel later. A work step is
the same unit a credit pays for. That is not a fixed number of bytes: one step
of the scalar scanner looks at one character unit (one byte in UTF-8, two in
UTF-16, four in UTF-32), one step of the block scanner can cover up to 64 of
them, and grammar, storing and recovery steps look at none. So the interval is
**not a byte count or a time limit**. It doesn't change what a credit buys or
the block size.

- Every `advance` and `run` call checks on entry, even `advance(0)`. So with
  small budgets the check runs more often than the interval says.
- `advance(N)` still spends at most N credits, whatever the interval. A pause
  needs no cancel request, and the next call carries on normally.
- An error or a successful end found in a step wins over a cancel noticed
  later. A finished session doesn't call the check again. `session.cancel()`
  still stops the session at once.
- With fixed settings the interval is built into the code. With run-time
  settings it is checked and fixed when the session starts or is reset, and
  stays the same across pauses. If a `reset` has an invalid interval, the
  session keeps its current parse.
- `0` is invalid, even when cancellation is off. With fixed settings it is a
  compile error. A run-time patch returns `error.InvalidCancellationInterval`
  before reading any input, allocating, or calling your check.
- The interval applies to parsing and to `measure`, including DOT
  [event-only parsing](EVENTS.md). Markup validation keeps its own fixed
  checking points and isn't metered. A label checker used during DOT parsing
  follows its own execution settings.

A run-time patch can set it per session (this works with `markup.Profile`
too):

```zig
const Runtime = dot.Profile(.{ .runtime_policy = true, .policy = .{
    .execution = .{ .metering = true, .cancellation = true },
} });
var session = try Runtime.Session.init(source, .{ .document = storage.storage() }, bag.sink(), .{
    .policy = .{ .execution = .{ .cancellation_interval = 64 } },
    .cancellation = .{ .context = &request, .is_requested = Request.poll },
});
defer session.deinit();
```

## Rules while a session is paused

- Keep the source, the buffers, the bag and the cancel context alive and at
  the same address.
- Don't read the buffers until the session has finished.
- You may move the session value between calls, but don't copy it and use
  both copies.
- Call `deinit()` when you abandon a session. It never frees your buffers.
- `session.reset(source, sink, options)` starts a new parse in the same
  buffers. Documents from the earlier parse become invalid.
- `reset` and `deinit` end an unfinished parse first. For an
  [event session](EVENTS.md#sessions-and-encodings) with token previews on, that
  can still deliver one finding the old parse had already made, to the old
  bag. If you reuse that bag, clear it after `reset`.
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

Calling `advance` on a session without metering is a compile error. With
run-time settings, `advance` returns an error union instead, and gives
`error.MeteringDisabled` when the call's settings turn metering off.

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

On aarch64 macOS, scalar state is 64 bytes in `debug` and `safe` builds and
56 bytes in `fast` and `small` builds. Block state is 152 bytes in all four. A
[layout test](../tests/layouts.zig) checks these numbers. They can differ on
other targets; see [type sizes](PERFORMANCE.md#type-sizes) and use `@sizeOf`
for your own build.

```zig
const Parser = dot.Profile(.{ .policy = .{ .scanner = .block } });
```

Measured numbers are in [Performance](PERFORMANCE.md).

## In the markup parser

Markup sessions follow everything above, with the same calls (`advance`,
`run`, `cancel`, `reset`, `result`, `deinit`) and the same rules while paused:

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
  label processor has no `Session`. Neither has one with
  [string rules](POLICIES.md#string-rules-for-attribute-values) turned on
  (unreleased).

## Measuring the cost

> **Unreleased.** Not in 0.5.0.

Two benchmarks compare the cost of sessions. Build them with
`-Doptimize=fast` (or `safe`). Input and buffers are prepared before timing,
and validation isn't timed.

- `zig build bench-metering -Doptimize=fast` compares a normal parse with
  budgets of 1, 64 and 4096, cancellation intervals 1 and 64, and run-time
  settings, for both scanners, on dense syntax and on long ASCII and Unicode
  text. It reports credits, cancel-check calls and session sizes.
- `zig build bench-cancellation -Doptimize=fast` compares intervals 1, 4, 16,
  64 and 256 on both scanners and both parsers, with fixed and run-time
  settings, with and without metering. It reports speed, cancel-check calls,
  credits and session sizes.

The default interval stays `1`. A larger one isn't always faster.

## Not available yet

- Validation in steps, or cancellation during DOT validation. Markup validation
  can already be cancelled at fixed points, but isn't metered.
- Checking HTML-like labels in steps.
- Feeding input in pieces. The whole input must be in memory before parsing
  starts.
- A total budget across calls. `advance(n)` limits one call. If you keep
  calling it, keep your own running total.
- Sessions for UTF-16 and UTF-32 input.

See the [roadmap](ROADMAP.md).

## Examples

- [bounded.zig](../examples/bounded.zig): a budget loop, then cancelling a
  session
- [policies.zig](../examples/policies.zig): a session whose scanner and checks
  are chosen at run time
- [string_processor.zig](../examples/string_processor.zig): among other
  string checks, a string session run in small budgets

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.
