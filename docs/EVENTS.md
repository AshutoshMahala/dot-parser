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
| `identifier`, `statement_head`, `document_name`, `subgraph_name` | Opt-in early observations for outlines; see below |
| `token_preview`, `token_preview_end` | Independently opt-in raw token prefixes at EOF and metered pauses |
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
With begin notifications enabled, a statement abort always follows its delivered
begin. The statement-abort span is only the known failed prefix (possibly zero
length at terminal cleanup, including syntax failure); it excludes a closing
brace owned by the enclosing scope. `skipped` supplies the full synchronized
region later.

Transactions can nest: an edge statement can contain a subgraph endpoint whose
body emits its own statements. Child commits survive a later parent-statement
abort. Conversely, a locally completed surrounding statement can contain skipped
child syntax; its commit does not certify child completeness or validation.
Observe scope boundaries and child aborts if you need that distinction.

Comments can arrive before the header, after the outer `}`, or during quoted
concatenation lookahead. They do not belong to statement transactions. A failure
after pre-header comment delivery can produce document abort without a header.
No callbacks follow document abort or successful document commit.

With early observations enabled, a complete document name can also arrive
before `begin_document`. Token previews can likewise arrive before a header,
even for input that never becomes DOT. Failure after either observation produces
document abort, even if the opening `{` never arrives.

`onEvent` returns `.proceed` or `.stop`, or a consumer-defined error. The result
distinguishes `.event_stopped` and `.event_failure` from syntax, diagnostic and
nesting-storage failures. No consumer error is relabeled as out-of-memory.

## Outline while typing

Declare this on your consumer, using the **same** `onEvent`/`onAbort` interface:

```zig
pub const observations = dot.events.Observations.early; // default .none
```

The declaration must be `pub`: a private declaration is not visible to the
parser's cross-module contract and behaves like an omitted selection. Removed public
`wants_early_events` / `wants_token_previews` declarations are compile errors;
there are no compatibility aliases.

This exposes recognized names before a statement completes. For example,
`graph { alpha [label="unfinished` delivers `identifier` for `alpha` and a
`statement_head` of `.node`, but no `commit_node`. An editor can retain that
observation as a provisional outline entry while still reporting the syntax
error. Ordinary consumers receive neither of these extra callbacks.
The shared `Event` type gains these four early-observation tags and the two
preview tags below even when the consumer opts out: existing exhaustive switches
must handle all six or add `else => {}`.

| Event | Payload and timing |
| --- | --- |
| `identifier` | `owner`, complete typed `name`, and `role`: `.statement_start`, `.edge_right` or `.edge_link`. Port suffixes are separate existing `ported_reference` events. |
| `statement_head` | `owner`, first-token `start`, and recognized `kind`: `.node`, `.edge`, `.assignment`, `.graph_attributes`, `.node_attributes`, `.edge_attributes` or `.subgraph`. At most once per statement occurrence. |
| `document_name` | Complete `name`, `kind`, `strict`, `keyword_span` and `source_info`, before the document's opening brace. |
| `subgraph_name` | Complete `name`, `keyword_span`, `owner` and endpoint `role`, before its opening brace. No `ScopeId` is allocated until the body opens. |

A statement-leading identifier is not yet necessarily a node: `a` can become
`a = value` or `a -> b`. The head refines its role when syntax establishes it:
`[` identifies a node, `=` an assignment, and the first edge operator an edge.
A bare node gets its head at a valid statement boundary. At EOF, `graph { a`
exposes the identifier but does not guess the statement's eventual kind.
A named subgraph may later become an edge endpoint; its standalone `.subgraph`
head is emitted only after its body and non-edge lookahead are recognized.

Correlate observations with later events using `owner` and source spans; do not
create a second node when the matching commit arrives. Names use original byte
coordinates and borrow the unchanged input. `document_name.source_info` makes
encoding available even before `begin_document`. IDs remain local to one parse,
not stable identities across edits.

These are provisional facts, not commits, repairs or a partial document tree.
Commits still certify completed statements, not observations. Opting into either
early events or previews also tracks statement ownership when begin notifications
and statement recovery are disabled, so those consumers can now receive a
statement abort followed by document abort. An outline may deliberately keep an
aborted observation marked provisional; an atomic graph/index must discard it.
Complete lexical names qualify for `identifier.fromName(source, name)`, even when their
enclosing statement fails. Unfinished input is not guessed into a name. The
separate preview opt-in below exposes raw prefixes, not trusted identifiers.

There is no event queue, additional nesting frame or parser-owned outline.
Enabled callbacks each consume a separate dispatch credit and obey existing
cancellation polling, including a pause between a head and its commit.
Callback execution is still consumer work. Metering units and cancellation
intervals do not change. The opt-in does not enable `retention.partial` or alter
syntax acceptance/recovery.

### Unfinished-token previews

For raw prefixes as well as complete names, independently declare:

```zig
pub const observations = dot.events.Observations.previews;
// Use Observations.all for both early names/heads and previews.
// Or select individual kinds:
// pub const observations: dot.events.Observations = .{
//     .identifier = true, .token_preview = true,
// };
```

The same `onEvent` receives these Unreleased events:

| Event | Meaning |
| --- | --- |
| `token_preview` | `span`, `kind`, `reason` (`pause` or `eof`), known grammar `context`, current `scope`, optional `owner` and `source_info` |
| `token_preview_end` | Retire the preview at `start`: a lexical `token` completed, or the prefix was `rejected`. Token completion is not grammar acceptance. |

At actual EOF, `graph { "serv` exposes `"serv` with kind `quoted` and context
`statement_start`, then reports the ordinary unterminated-string failure and
aborts. Quoted, HTML-like and concatenated expressions are supported at EOF.
While a session is scanning, previews can additionally describe `word` and
`numeral` prefixes. A word might become a keyword; even a closed quoted operand
can still acquire a concatenated suffix. This slice does not preview comments,
operators or whitespace as separate previews. Concatenation spans include their
internal glue, but trailing trivia after `+` does not extend a prefix or trigger
whitespace-only updates. Comment retention remains a separate option.

Spans include their written delimiters and borrow original bytes. They may end
inside a UTF-8 scalar or escape; they are **not** valid input for
`identifier.fromName`: their type is `Span`, not `Name`. No decoding, extra source scan, inferred closing
delimiter, diagnostic suppression or repaired tree is involved. Native one-shot
EOF previews keep original UTF-16/32 byte offsets and encoding metadata; native
sessions remain unavailable.

Contexts include document/subgraph names, statement starts, right/link edge
endpoints, attribute keys/values, assignment values and ports. Ambiguous
lookahead and recovery use `unknown`. An owner is absent until an actual
statement occurrence has begun: a prefix alone does not allocate a statement
or scope identity. In separator-free DOT, a new statement's prefix does not
belong to the preceding statement while its commit awaits lookahead. Ownership
does not require enabling begin notifications or early events. Use the source
start to correlate updates, not the spelling.

Replace a previous preview at the same start with each update. Retire it on
`token_preview_end`; a document abort abandons all remaining previews without
extra end callbacks. An editor may deliberately keep an EOF preview marked
provisional after abort, just like early name observations. Reset starts a new
parse identity space. Never merge these observations into committed syntax.

Each preview/update/end attempt consumes its own dispatch credit. At a metered
pause, the parser snapshots only already-consumed bytes, **without reading
ahead**, and queues at most one update. If scanning exhausted the budget, the
callback waits for the next positive-budget `advance()` before scanning resumes.
`Progress.phase` is `dispatch` while that update is queued; a one-credit call can
deliver it. `advance(0)` emits nothing (existing cancellation polling still
applies). Unchanged prefixes are not repeatedly emitted, and a one-credit
session always makes progress rather than spending every credit on snapshots.

Pause previews depend on budget partition and scanner backend; their sequence
is not a token stream or a stable outline. A `run()` does not pause to manufacture
previews. Consumer stop/failure and cancellation keep their existing terminal
semantics; a queued preview may never be delivered if the operation is stopped.
Cancellation abandons the observation, not a scanner failure already found:
that finding is reported first. An unrecoverable failure remains `invalid_syntax`;
if recovery was possible, cancellation stops it with the finding retained.
This includes ambiguous-numeral findings held behind a token-end preview.
An event consumer returning `.stop` is a different boundary: if it stops on an
EOF preview, the pending syntax finding has not yet been delivered. `reset()`
and `deinit()` use cancellation cleanup and can deliver a pending finding to
the old diagnostic sink; keep that sink alive and clear reusable bags after reset.
Callback work remains caller work. Enabling previews adds fixed-size state and
callback work, but no parser allocation, source copy or nesting-frame growth.
Disabled profiles compile that state, scanner-boundary bookkeeping and dispatch
out. Compare costs with
`zig build bench-previews -Doptimize=fast`.

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

## Indexing recognized names

The raw `identifier.hash`/`eql` helpers check the spelling each time because they
also accept arbitrary caller input. When an event already identifies a complete
identifier, a consumer can skip that check without retaining a `Document`:

```zig
// Inside a UTF-8 consumer's onEvent:
.commit_node => |node| {
    const name = dot.identifier.fromName(self.source, node.value.identifier);
    const hash = name.hash() catch unreachable; // UTF-8 preserves raw bytes.
    // Store name/hash in your index; use name.eql(other) on hash matches.
},
```

`fromName` accepts a `dot.Name` issued by parsing or `identifier.check`, not
arbitrary bytes or a `Span`.
Names have the same eight-byte layout as spans; `.span()` exposes coordinates
for diagnostics and `.slice(source)` returns original spelling. Events use
`Name` for `identifier.name`, document/subgraph names, node identifiers,
attribute keys/values, ports and link identifiers. Edge `left`/`right` can also
represent scope introducers, so use `edge.leftName()` / `edge.rightName()`;
they return null for scoped endpoints. Begins, heads, keywords, skipped regions
and previews remain spans and cannot accidentally enter this API.

Keep the producing source unchanged and use its encoding. This is type safety
against accidental misuse, not protection from deliberate forging or supplying
another buffer. Zig struct literals and record helpers are not a security
boundary: constructing a `Name` or `Parsed` manually does not validate it.
An out-of-source range panics in every build mode; same-sized stale input or a
wrong encoding cannot be detected from the handle. It represents complete
identifier spelling, not Unicode validity, statement acceptance or node identity.
For arbitrary spans, explicitly call
`try identifier.check(source, span)` to obtain a checked `Name`, or use the
existing checked byte helpers. For native input,
select `identifier.ForEncoding(actual)` from the document-begin encoding
(or `document_name.source_info` for an early header name).
Those native helpers can reject malformed encoding: propagate `InvalidIdentifier`
through a fallible callback instead of treating it as unreachable.

When the encoding is selected at runtime, dispatch once on the source metadata:

```zig
fn nameHash(source: []const u8, name: dot.Name, actual: dot.InputEncoding) !u64 {
    return switch (actual) {
        inline else => |encoding| dot.identifier.ForEncoding(encoding)
            .fromName(source, name).hash(),
    };
}
```

Use `begin_document.source_info.encoding` (or the early document-name metadata)
for `actual`. `check` verifies a standalone identifier spelling; it does not
establish the identifier's role or acceptance in the surrounding document.
No event fields, parser storage or allocations are added; index memory belongs to the consumer.
Hashing/comparison in callbacks is consumer work, not parser-session credits.

`zig build bench-identifiers -Doptimize=fast` compares the checked and
trusted paths in an event-only name index, with source generation and identical
table reservation outside timing. It reports parse-plus-index time, decimal
MB/s and index storage. Use `safe` or `small` for those modes.

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
Optional compile-time declarations select callback work:
`wants_begin_statement = false` omits begin notifications, and
`recover_statements = false` ends output at the first syntax rejection while
the grammar may continue collecting diagnostics. Both default to true for user
consumers. `observations: dot.events.Observations` selects optional observations.
Its fields are `identifier`, `statement_head`, `document_name`, `subgraph_name`
and `token_preview`; all default to false. Preview retirement is always paired
with preview delivery. The `.early`, `.previews`, `.all` and `.none` constants
are convenient selections, not separate machinery. Names, heads and previews
share one internal scheduling/dispatch continuation and abort-delivery flag;
only previews need a snapshot. Unselected kinds have no callback or work credit.
Selection is independent of begin notifications. None changes the
profile's syntax/recovery policy.
The `parser_retention` namespace is reserved for internal document bookkeeping,
not a consumer hook. Unrelated methods named `continuesAfterError` or
`retainThrough` have no effect on event delivery.

One-shot event profiles support compiled native source encodings and original
byte offsets. Native resumable sessions, event-driven validation, simultaneous
library-tree plus public-event output, and composed label execution through
this event-only API are not implemented. Use an outer-only DOT profile here;
ordinary [composition](LABELS.md) remains separate.
