# DOT events

> **Unreleased.**

Use events when you want your own index, outline or graph instead of the
library's `Document`. The same DOT grammar and policies drive both paths.
Bind a consumer type at compile time; there is no runtime registry.
The input is still one contiguous borrowed buffer; events stream output, not
input chunks.

```zig
const Consumer = struct {
    nodes: u32 = 0,

    pub fn onEvent(self: *@This(), event: dot.events.Event) error{}!dot.events.Action {
        switch (event) {
            .commit_node => self.nodes += 1,
            else => {},
        }
        return .proceed;
    }

    pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
};

const Streaming = dot.Profile(.{}).Events(Consumer); // or dot.Events(Consumer)
var consumer: Consumer = .{};
const result = Streaming.parse(allocator, source, &consumer, bag.sink(), .{});
```

The allocator backs temporary nesting frames only. `parseIn(source, scratch,
&consumer, diagnostics, options)` uses caller-owned `FixedParseScratch` instead,
with no parser allocation. Neither path allocates document pools or buffers a
whole statement. Consumer work and allocations remain the consumer's responsibility.
Unused events add no callbacks or transaction state to ordinary fixed-policy
parsing with partial retention off.

## What arrives

| Event | Meaning |
| --- | --- |
| `begin_document` | A complete supported DOT header was recognized |
| `begin_statement` | A tentative statement starts, with its owner and source span |
| `attribute`, `edge_link`, `ported_reference` | Completed pieces of that still-tentative statement |
| `begin_scope`, `end_scope` | A subgraph body opens or its actual closing brace is read |
| `commit_*` | That statement's own envelope completed, with a typed `.value` (see below) |
| `skipped` | A failed/unrecognized region was skipped to a synchronization boundary |
| `comment` | A complete comment, only with `retention.comments` enabled |
| `end_document` | Whole-document syntax commit attempt; successful acknowledgment finishes parsing |

Commit cases are flat event tags, not another tagged union inside an event:

| Event | `.value` |
| --- | --- |
| `commit_node` | `Node` |
| `commit_edge`, `commit_edge_chain` | `Edge` (the first edge for a chain) |
| `commit_subgraph` | `ScopeId` for a standalone subgraph statement |
| `commit_assignment` | `Attribute` key/value pair |
| `commit_attribute_statement` | `AttributeStatement` target and keyword |

Every commit also carries `.owner`. A consumer interested only in nodes can
ignore the remaining cases, as in the example.

`onAbort` receives either `.statement` (discard that statement's tentative work)
or `.document` (abandon all still-open work). Abort cannot fail. It does not
undo external changes or edit the source. Stage changes until the relevant
commit if atomic output is required. A failing/stopping commit callback is
followed by abort, not successful acceptance.
The statement-abort span is only the known failed prefix (possibly zero length
on an operational stop); `skipped` supplies the full synchronized region later.

Transactions can nest: an edge statement can contain a subgraph endpoint whose
body emits its own statements. Child commits survive a later parent-statement
abort. Conversely, a locally completed surrounding statement can contain skipped
child syntax; its commit does not certify child completeness or validation.
Observe scope boundaries and child aborts if you need that distinction.

Comments can arrive before the header, after the outer `}`, or during quoted
concatenation lookahead. They do not belong to statement transactions. A failure
after pre-header comment delivery can produce document abort without a header.
No callbacks follow document abort or successful document commit.

`onEvent` returns `.proceed` or `.stop`, or a consumer-defined error. The result
distinguishes `.event_stopped` and `.event_failure` from syntax, diagnostic and
nesting-storage failures. No consumer error is relabeled as out-of-memory.

## Recovery and retained output

With `.on_error = .collect`, a recoverable error aborts the current statement,
reports a skipped range, then delivers later statements. `.fail_fast` stops at
the first error. An unterminated quote/comment or an operational stop still ends
the parse. Recovery never makes rejected input successful: the document aborts
at the end, with the actual syntax outcome and factual error count preserved.

These choices do not enable the library's partial tree. That separate opt-in is
`retention.partial`; see [editor results](EDITORS.md#keep-the-finished-part-of-a-dot-file).
Event-only consumers decide which completed work to keep themselves.

All spans borrow the original source, in bytes. Event statement/reference IDs
identify written occurrences, not unique graph nodes: statement IDs are opening
byte offsets, scope IDs are one-based opening-order occurrences (root is zero),
and reference IDs are zero-based qualified-reference occurrences. The `port`,
`left_scope` and `right_scope` integer fields carry the respective occurrence
IDs. They are not arbitrary array indexes; use the document's checked views to
access retained storage. `dot.ScopeId` and `dot.events.ScopeId` are the same
type. IDs are not renumbered when a statement aborts.
Source must remain alive and unchanged for any retained spans.
`begin_document.source_info` and the terminal result carry the selected source
encoding/BOM information, so native consumers need not infer it from spans.

## Sessions and encodings

```zig
const Streaming = dot.Profile(.{ .policy = .{
    .execution = .{ .metering = true },
} }).Events(Consumer);
var frames: Streaming.FixedParseScratch(.{ .nesting = 32 }) = .{};
var session = Streaming.Session.init(source, frames.storage(), &consumer, bag.sink(), .{});
defer session.deinit();
while (session.result() == null) _ = session.advance(4096);
```

The consumer and scratch must outlive the session. Callbacks must not reenter
the active driver, reuse its scratch or mutate source bytes. Normal callbacks
have separate work credits, just like grammar/scanner work; caller callback
execution and infallible abort cleanup are not time-metered. Pauses preserve
event ordering without replaying delivered callbacks. `run`, `cancel`, `result`
and `reset` follow the document-session lifecycle. Runtime policy is selected
once at initialization/reset; invalid reset leaves the current session intact.

The parser keeps no event list. If your consumer retains complete `Event`
values, budget `@sizeOf(dot.events.Event)` per entry; an index can instead keep
only the spans and IDs it needs. Event layouts are not a stable binary ABI.

## The same contract inside the library

The parser calls `onEvent`/`onAbort` directly for our document builders, the
sizing sink and your consumer. No adapter translates a private vocabulary into
the public one. Scope/reference IDs are assigned by the parser, not returned
as builder-owned pool handles. `begin_scope` includes the suspended edge prefix
when the scope is an edge endpoint, so a consumer needs no private parser state.

Most consumers need only the two callbacks shown above. Advanced consumers may
declare a private `ScopeContext` type with infallible
`suspendScope(*Self) ScopeContext` and `restoreScope(*Self, ScopeContext) void`.
After an accepted scope-begin callback, the parser saves that context in typed
scratch; after an accepted scope-end callback it restores it. Our builders use
this for reservations, without exposing them in events or adding a second
stack. Terminal abort abandons open contexts without synthesizing closes.
Context is copied saved state, not transferred resource ownership: keep owned
resources in the consumer so `onAbort` can clean up without scope-close calls.
Continuation hooks share their scope event's dispatch credit; their execution,
like `onEvent`, is consumer work outside the parser's metering.

Use the bound profile's `ParseScratch`/`FixedParseScratch` for fixed event
storage: its frame type includes only that consumer's context. Ordinary
consumers have no private context, so their nesting frames are smaller than
tree-builder frames. No extra allocation or identity lookup table is needed.
Two optional compile-time declarations select callback work:
`wants_begin_statement = false` omits begin notifications, and
`recover_statements = false` ends output at the first syntax rejection while
the grammar may continue collecting diagnostics. Both default to true for user
consumers; neither changes the profile's syntax/recovery policy.

One-shot event profiles support compiled native source encodings and original
byte offsets. Native resumable sessions, event-driven validation, simultaneous
library-tree plus public-event output, and composed label execution through
this event-only API are not implemented. Use an outer-only DOT profile here;
ordinary [composition](LABELS.md) remains separate.
