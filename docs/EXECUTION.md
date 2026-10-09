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

Both parsers have sessions that work the same way. The examples here use DOT;
the markup differences are in [the markup parser](#in-the-markup-parser).

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

Credits measure work, not time. They don't count time spent in your own
callbacks (your diagnostic sink, your cancel check). Validation, decoding and
rendering are separate steps and aren't metered at all.

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
function that returns `true` when the work should stop. The session calls it
before every step:

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

With [DOT](READING_DOCUMENTS.md#partial-results-for-editors) or
[markup partial results](MARKUP.md#partial-results-for-editors) turned on
(unreleased), a cancelled parse can instead return the part recognised before
the cancel. Keeping it costs no extra scanning or allocation.

The same `.cancellation` option works on the one-call functions
(`parseAndValidate` and others) when the profile turns cancellation on.

The check is a plain function call. There are no threads, signals or timers
inside the library. If another thread sets your flag, make it an atomic.

## Rules while a session is paused

- Keep the source, the buffers, the bag and the cancel context alive and at
  the same address.
- Don't read the buffers until the session has finished.
- You may move the session value between calls, but don't copy it and use
  both copies.
- Call `deinit()` when you abandon a session. It never frees your buffers.
- `session.reset(source, sink, options)` starts a new parse in the same
  buffers. Documents from the earlier parse become invalid.
- After a terminal result publishes a document, `session.validate(sink, .{})`
  validates it. A partial document reports incomplete representation coverage;
  validation is not metered.

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

- Validation in steps, or validation that can be cancelled.
- Checking HTML-like labels in steps.
- Feeding input in pieces. The whole input must be in memory before parsing
  starts.
- A total budget across calls. `advance(n)` limits one call. If you keep
  calling it, keep your own running total.

See the [roadmap](ROADMAP.md).
