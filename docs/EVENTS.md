# DOT events

> **Unreleased.** Not in 0.5.0.

Normally the parser builds a `Document` for you. With *events*, it calls your
code instead, as it reads: "a node statement finished", "a subgraph opened",
and so on. Use this to build your own index, outline or graph without the
library's document storage. The same DOT grammar and settings apply either way.

The type that receives the events is your *consumer*. You bind it at compile
time; there is no run-time registry. The source must still be in one buffer:
events stream the output, not the input.

To receive these events while building the library's semantic graph, use
`IR.FromEvents(Dot).Observe(Consumer)` with a required `.observer` instance.
The [IR guide](IR.md#build-an-outline-alongside-the-graph) describes its ownership,
coverage, work accounting and typed stop/error behavior.

## Quick start

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
if (result.outcome != .success) {
    // bag holds the diagnostics; result.outcome says why parsing ended.
}
```

- `parse` reads the whole source. The allocator is used only for temporary
  nesting frames, one per open subgraph.
- `parseIn` uses storage you provide instead, and the parser allocates nothing:

  ```zig
  var frames: Streaming.FixedParseScratch(.{ .nesting = 16 }) = .{};
  const result = Streaming.parseIn(source, frames.storage(), &consumer, bag.sink(), .{});
  ```

  More open subgraphs than `nesting` ends the parse with `storage_failure`.
- Neither builds document storage or buffers a whole statement. What your
  consumer stores, and any allocation it does, is up to you.
- Diagnostics go to an ordinary DOT diagnostic sink, as with `Document`
  parsing.
- On a default profile, `parse` and `parseIn` return the result directly.
  Runtime-policy profiles, and profiles that compile anything other than UTF-8
  alone, return an error union ([encodings](#sessions-and-encodings)).
- Ordinary `Document` parsing (with `retention.partial` off) gets no extra
  callbacks or statement tracking from this API.

## Writing a consumer

A consumer needs two methods:

| Method | Meaning |
| --- | --- |
| `pub fn onEvent(self: *Self, event: dot.events.Event) E!dot.events.Action` | Receives each event. Return `.proceed` to continue or `.stop` to end the parse. `E` is any error set you like; returning an error also ends the parse. |
| `pub fn onAbort(self: *Self, abort: dot.events.Abort) void` | Tells you to throw away unfinished work. It can't fail. |

It may also declare:

| Declaration | Default | Meaning |
| --- | --- | --- |
| `pub const wants_begin_statement = false;` | `true` | Skip `begin_statement` events (one fewer callback per statement) |
| `pub const recover_statements = false;` | `true` | End your output at the first syntax error: the document aborts. Without this, the parser [recovers](#recovering-from-errors) and keeps delivering later statements. The parser may still collect later diagnostics either way. |
| `pub const observations: dot.events.Observations = ...;` | `.none` | Extra names, previews or delimiter events for editors; see [outline while typing](#outline-while-typing) |
| `pub const statement_extents = true;` | `false` | Fill `commit_*.extent` with the completed statement's byte span |
| `pub const coverage = true;` | `false` | Add `coverage` to the bound result type |
| `ScopeContext`, `suspendScope`, `restoreScope` | none | State saved per subgraph; see [per-scope state](#advanced-per-scope-state) |

- Declarations must be `pub`. A private declaration is invisible to the parser
  and behaves as if it were missing.
- `wants_begin_statement`, `recover_statements`, `statement_extents` and
  `coverage` must be `bool` constants,
  and `observations` must have type `dot.events.Observations`; anything else is
  a compile error.
- A misspelled name (for example `observation` or `recover_statement`) is
  ignored silently. Check the spelling.
- Don't declare anything named `parser_retention`: the library uses that name
  for its own document builders. Other methods, such as `continuesAfterError`
  or `retainThrough`, have no effect on events.
- The `Event` union always has every tag, including the optional ones you don't
  select. An exhaustive `switch` must handle them all, or use `else => {}`.

## What arrives

| Event | Meaning |
| --- | --- |
| `begin_document` | A complete DOT header was read, up to its `{` |
| `begin_statement` | A statement starts. It is *tentative*: it can still be rejected. |
| `attribute`, `edge_link`, `ported_reference` | Pieces of the still-tentative statement: an `a=b` pair, one more `-> x` step of an edge chain, or a `name:port` reference |
| `begin_scope`, `end_scope` | A subgraph body opens, or its closing `}` is read |
| `commit_*` | The statement finished (next table) |
| `skipped` | After a syntax error, the parser skipped this region to the next statement boundary |
| `comment` | A complete comment. Only with `retention.comments` on. |
| `delimiter` | An actual brace or bracket, recognized or skipped during recovery. Only with `observations.delimiter` on. |
| `identifier`, `statement_head`, `document_name`, `subgraph_name` | Optional early observations; see [outline while typing](#outline-while-typing) |
| `token_preview`, `token_preview_end` | Optional raw text of an unfinished token; see [previews](#unfinished-token-previews) |
| `end_document` | The whole document is about to be accepted. If you return `.proceed`, parsing has succeeded. |

Each commit is its own event tag, with an `.owner`, a typed `.value` and an
optional `.extent` (null unless `statement_extents` is selected):

| Event | `.value` |
| --- | --- |
| `commit_node` | `Node`: `identifier`, optional `port` |
| `commit_edge`, `commit_edge_chain` | `Edge`: the first edge of the statement (`a -> b` of `a -> b -> c`; later steps came as `edge_link`) |
| `commit_subgraph` | The `ScopeId` of a standalone subgraph statement |
| `commit_assignment` | `Attribute`: the `key` and `value` of `key = value` |
| `commit_attribute_statement` | `AttributeStatement`: the `target` (`graph`, `node` or `edge`) and its `keyword_span` |

The other payloads:

| Event | Payload |
| --- | --- |
| `begin_document` | `kind` (`undigraph` or `digraph`), `strict`, `keyword_span`, `name_span` (optional), `retain_comments`, `source_info` |
| `begin_statement` | `owner`, `start` (the first token) |
| `attribute` | `owner`, `pair` (`key`, `value`) |
| `edge_link` | `owner`, `link` (`operator`, `operator_span`, `right`, `right_port`) |
| `ported_reference` | `owner`, `id`, `reference` (`identifier`, `first`, optional `second`) |
| `begin_scope` | `id`, `parent`, `statement`, `start`, optional `name`, `role` (`left`, `right` or `link`). For a subgraph used as an edge endpoint, also the `edge` written so far and the chain's `link_operator`. |
| `end_scope` | `id`, `close` (the `}`) |
| `skipped` | `span`, `scope` |
| `comment` | a `dot.Comment` |
| `delimiter` | `span`, `kind`, `side`, `scope`, `skipped` |
| `end_document` | nothing |

`Edge` has `left`, `left_scope`, `left_port`, `operator`, `operator_span`,
`right`, `right_scope` and `right_port`. An endpoint can be a subgraph, so
`left` and `right` are plain spans; use `edge.leftName()` and
`edge.rightName()` to get a name, or null for a subgraph endpoint.

A consumer that only wants nodes can ignore everything else, as in the quick
start.

## Statements: begin, commit and abort

A statement's pieces arrive before the parser knows the statement is good. It
then ends in one of two ways:

- a `commit_*` event: the statement's own syntax is complete;
- `onAbort(.{ .statement = ... })`: throw away that statement's pieces.

`onAbort(.{ .document = reason })` means: throw away all still-open work. Abort
can't fail. It doesn't undo changes you already made elsewhere, and it never
edits the source. If you need all-or-nothing output, stage changes until the
matching commit (or until `end_document` for the whole document).

The rules:

- If `onEvent` returns `.stop` or an error, an abort follows. That includes a
  stop on a commit or on `end_document`: it is never treated as acceptance.
- With begin notifications on, you only get a statement abort for a statement
  whose `begin_statement` you received.
- A statement abort's `span` covers the part of the statement read so far, up to
  the token that failed. It never includes a `}` that belongs to the enclosing
  scope. At final cleanup (a stop, cancellation or unrecoverable error), the
  span is empty. A later `skipped` event gives the whole region that was
  skipped.
- Statements nest: an edge can contain a subgraph endpoint whose body has its
  own statements. Commits inside it stay valid if the outer statement aborts
  later. And a statement can commit even though a child statement inside it
  was skipped: its commit says nothing about its children, and it is not
  validation. Watch scope events and child aborts if you need that difference.
- Comments are not part of any statement. They can arrive before the header,
  after the final `}`, or while the parser looks ahead for a `+` after a quoted
  string.
- Comments, a `document_name` observation or a token preview can arrive before
  `begin_document`. If parsing fails after any of them, you get a document abort
  even though the header (or its `{`) never arrived.
- Nothing arrives after a document abort or after a successful `end_document`.

| Abort reason | Cause |
| --- | --- |
| `invalid_syntax` | A syntax error |
| `unsupported_feature` | Input the profile rejects as unsupported (such as HTML-like strings with `markup = .none`) |
| `resource_exhausted` | A configured limit was reached |
| `cancelled` | Cancellation |
| `diagnostic_stopped` | The diagnostic sink asked to stop or failed |
| `sink_stopped`, `sink_failure` | Your `onEvent` returned `.stop` or an error |
| `scratch_failure` | No room for another nesting frame |
| `processor_stopped` | Not used by event parsing |

## Recovering from errors

- With `.on_error = .collect` (the default), a recoverable syntax error aborts
  the current statement, reports a `skipped` region, and then later statements
  are delivered as usual.
- `.fail_fast` stops at the first error.
- An unterminated quote or comment, a limit, or a stop still ends the parse.
- Recovery never makes rejected input succeed. The document aborts at the end,
  and the result keeps the real outcome and the true error count.
- These settings don't turn on the library's partial tree. That is
  `retention.partial`; see
  [editor results](EDITORS.md#keep-the-finished-part-of-a-dot-file). With
  events, you decide which finished work to keep.

### Results

| Bound `Streaming.Result` field | Meaning |
| --- | --- |
| `outcome` | Why parsing ended (next table) |
| `completion` | `.complete` if the parser reached the end of the input (also after recovered errors), otherwise `.incomplete` |
| `syntax_errors` | Syntax errors found |
| `accepted_deviations` | Non-standard spellings the policy accepted |
| `warnings` | Warnings reported |
| `diagnostic_delivery` | `.failed` if handing a diagnostic to the sink failed |
| `diagnostic_stop` | Why the diagnostic sink stopped, if it did |
| `source_info` | The encoding and BOM information used |
| `coverage` | Only with `Consumer.coverage = true`: `retained_end` and `root_closed` (see below) |

Without the coverage selection, `Streaming.Result` is `dot.events.Result` and
has no `coverage` field. Sessions use the same selected result type, including
`Streaming.Progress.result`.

`coverage.retained_end` is the end of the source region accounted for by
accepted syntax and reported skips, using the same retention boundaries as a
partial `Document`. It is **not** the scanner's lookahead position. Successful
parsing covers `source.len`; recovery can also reach that end while reporting
invalid syntax. Inside an unfinished statement the boundary can stop earlier,
even after attribute or identifier events. `root_closed` records whether the
grammar accepted the root's actual `}`. Neither field claims validity. Both
start at zero/false and stop updating after the consumer's document abort.

| `outcome` | Meaning |
| --- | --- |
| `success` | The document parsed and your consumer accepted `end_document` |
| `invalid_syntax` | Syntax errors, recovered or not |
| `unsupported_feature` | The profile rejected an unsupported construct |
| `resource_exhausted` | A configured limit was reached |
| `cancelled` | Cancelled by a hook or `cancel()` |
| `diagnostic_stopped` | The diagnostic sink stopped |
| `event_stopped` | Your `onEvent` returned `.stop` |
| `event_failure` | Your `onEvent` returned an error (kept as is, whatever its name) |
| `storage_failure` | Nesting frames ran out: `out_of_memory` or `pool_exhausted` |

Consumer errors are never relabelled as out-of-memory or storage failures.

### Positions and IDs

- All spans and names are byte ranges in the original source, also for UTF-16
  and UTF-32 input.
- `Owner` is `{ statement, scope }`: the statement an event belongs to and the
  scope it is in.
- A `StatementId` is the byte offset where the statement starts. A `ScopeId`
  counts subgraph bodies in the order they open, starting at 1; the root is 0
  (`.root`). A `ReferenceId` counts `name:port` references from 0 in the order
  they appear.
- `Node.port`, `Edge.left_port`, `Edge.right_port` and `Link.right_port` hold
  reference IDs. `Edge.left_scope` and `Edge.right_scope` hold scope IDs.
- IDs name written occurrences, not unique graph nodes: two statements that
  mention `a` have different IDs. They belong to one parse (they are not stable
  across edits), are not renumbered when a statement aborts, and are not
  indexes into any storage.
- `dot.ScopeId` and `dot.events.ScopeId` are the same type.
- Keep the source alive and unchanged for as long as you keep spans or names.
- `begin_document.source_info` and `result.source_info` carry the encoding and
  BOM information, so you don't need to infer it from spans.

## Outline while typing

> **Unreleased.** Not in 0.5.0.

An editor wants an outline while the user is still typing, before statements
finish. Declare this on your consumer, which keeps the same
`onEvent`/`onAbort` methods:

```zig
pub const observations = dot.events.Observations.early; // default .none
```

The parser then also sends *observations*: early, provisional facts about names
it has completely read. For example, `graph { alpha [label="unfinished`
delivers `identifier` for `alpha` and a `statement_head` of `.node`, but no
`commit_node`. An editor can show that as a provisional outline entry while
still reporting the syntax error. Consumers that don't opt in get none of these
callbacks.

| `Observations` | Selects |
| --- | --- |
| `.none` (default) | nothing |
| `.early` | `identifier`, `statement_head`, `document_name` and `subgraph_name` |
| `.previews` | `token_preview` (see [previews](#unfinished-token-previews)) |
| `.all` | all of the above, plus `delimiter` |

You can also set the fields yourself:

```zig
pub const observations: dot.events.Observations = .{
    .identifier = true, .token_preview = true,
};
```

The fields are `identifier`, `statement_head`, `document_name`,
`subgraph_name`, `token_preview` and `delimiter`, all `false` by default. The constants are
just shorthand. The choice is independent of `wants_begin_statement` and
doesn't change syntax or recovery.

| Event | Payload and timing |
| --- | --- |
| `identifier` | `owner`, complete `name`, and `role`: `.statement_start`, `.edge_right` or `.edge_link`. Port suffixes still come as `ported_reference`. |
| `statement_head` | `owner`, `start` (the first token) and `kind`: `.node`, `.edge`, `.assignment`, `.graph_attributes`, `.node_attributes`, `.edge_attributes` or `.subgraph`. At most once per statement. |
| `document_name` | `name`, `kind`, `strict`, `keyword_span` and `source_info`, before the document's `{` |
| `subgraph_name` | `name`, `keyword_span`, `owner` and endpoint `role`, before the subgraph's `{`. No `ScopeId` exists until the body opens. |

How the head is decided:

- A name at the start of a statement is not yet a node: `a` can become
  `a = value` or `a -> b`. The head comes once the syntax shows which: `[` means
  a node, `=` an assignment, the first edge operator an edge.
- A bare node gets its head at a valid statement boundary. At the end of input,
  `graph { a` gives the identifier but no head: the parser doesn't guess.
- A named subgraph may still turn out to be an edge endpoint. Its `.subgraph`
  head comes only after its body and the following token show it stands alone.

Using observations correctly:

- Match observations with later events by `owner` and spans. Don't create a
  second node when the commit arrives.
- Names are original byte ranges that borrow the unchanged input.
  `document_name.source_info` tells you the encoding before `begin_document`.
  IDs belong to one parse, not stable across edits.
- Observations are provisional. They are not commits, repairs or a partial
  tree. Commits still mean finished statements.
- Selecting an early-name or preview observation makes the parser track statements even when begin
  notifications and statement recovery are off, so such consumers can get a
  statement abort followed by a document abort. Delimiters alone don't enable
  statement tracking; neither do extent or coverage selections.
- An outline may keep an aborted observation, marked provisional. An
  all-or-nothing graph or index must throw it away.
- A complete name can be used with `identifier.fromName(source, name)` even when
  its statement fails. Unfinished input is never guessed into a name. For raw
  unfinished text, use [previews](#unfinished-token-previews); they are not
  trusted names.

Costs:

- No event queue, extra nesting frame or parser-owned outline.
- In a [session](#sessions-and-encodings), each delivered observation costs one
  credit and is subject to cancellation polling, including the pause
  between a head and its commit. Unselected kinds cost nothing. Credit units and
  poll intervals don't change.
- Time spent in your callbacks is yours.
- It doesn't turn on `retention.partial`.

### Delimiters and completed declaration ranges

For folding and symbol ranges, select the facts you need:

```zig
pub const observations: dot.events.Observations = .{
    .identifier = true, .delimiter = true,
};
pub const statement_extents = true;
pub const coverage = true;
```

`delimiter` carries `span`, `kind` (`.brace` or `.bracket`), `side` (`.open` or
`.close`), `scope` and `skipped`:

| Role | `scope` | `skipped` |
| --- | --- | --- |
| Recognized `{` or `}`, including a closer used during recovery | The opened/closed scope; the root is `.root` | `false` |
| Recognized attribute-list `[` or `]` | Enclosing graph/subgraph | `false` |
| Brace/bracket passed over as skipped syntax | Enclosing recognized scope; no pairing is promised | `true` |

Opening braces follow `begin_document`/`begin_scope`; closing braces precede
`end_scope`. Root closers are reported even when errors prevent `end_document`.
These are two views of one boundary: don't count a delimiter and `end_scope` as
two closures. Attribute lists don't acquire scope IDs. Empty and repeated lists
each report their brackets.

Each reported delimiter is an actual token, with no duplicate replay. Punctuation inside comments,
strings or HTML-like identifiers is not a DOT delimiter. An accepted `[` stays
accepted if a later attribute is malformed, but a `]` skipped after abandoning
that list has `skipped = true`. No closing token is invented at EOF. Fail-fast,
cancellation and sink stops still stop delivery. To observe later boundaries
after syntax errors, keep `recover_statements = true` and use `on_error = .collect`.

Every `commit_*` has `extent: ?Span`. It is null unless `statement_extents` is
selected. A populated extent starts at `@backingInt(commit.owner.statement)` and
ends just after the last statement token. It includes ports, all attribute
lists and interior trivia, but excludes trailing trivia, the optional semicolon
and the containing scope's `}`. A standalone subgraph's own `}` is included.
For `a:p [] /* gap */ [x=y];`, the extent is `a:p [] /* gap */ [x=y]`.
Rejected statements have no commit or completed extent; early names can still
support a provisional outline entry.

All spans use bytes in the original encoding. These selections add fixed-size
state, with no source rescan, event queue or extra nesting storage. Each
delimiter callback costs one dispatch credit. Extents and coverage add no
callbacks or credits. Disabled selections compile out independently. `.all`
selects delimiters too, but does not enable extents or coverage.

### Unfinished-token previews

> **Unreleased.** Not in 0.5.0.

A *preview* is the raw text of a token the user is still typing, such as
`"serv` before the closing quote. Select it on its own or together with early
observations:

```zig
pub const observations = dot.events.Observations.previews;
// or .all for early observations, previews and delimiters together
```

The same `onEvent` receives:

| Event | Payload |
| --- | --- |
| `token_preview` | `span`, `kind`, `reason` (`.pause` or `.eof`), `context`, the current `scope`, an optional `owner`, and `source_info` |
| `token_preview_end` | `start` (of the preview it ends) and `reason`: `.token` (the token finished; that doesn't mean the grammar accepted it) or `.rejected` (the text failed) |

| Field | Values |
| --- | --- |
| `kind` | `word`, `numeral`, `quoted`, `html` or `concatenation` |
| `context` | `document_name`, `subgraph_name`, `statement_start`, `edge_right`, `edge_link`, `attribute_key`, `attribute_value`, `assignment_value`, `port`, or `unknown` (the parser can't tell yet, or is recovering from an error) |

When previews arrive:

- At the real end of the input, for an unfinished quoted string, HTML-like
  string or concatenation, in both `parse` and sessions. For example,
  `graph { "serv` gives `"serv` with kind `quoted` and context
  `statement_start`, then the usual unterminated-string error, then the abort.
- In a metered [session](#sessions-and-encodings), also at a pause: when a call
  to `advance` runs out of budget in the middle of a token. Pause previews can
  also show `word` and `numeral` text. A word may still turn out to be a
  keyword, and a closed quoted string may still get a `+` suffix.
- Pause previews depend on how you split the budget and on the scanner, so they
  are not a token stream or a stable outline. `run()` and one-shot `parse` never
  pause just to produce previews.
- Comments, operators and whitespace get no previews of their own (comments
  come as `comment` events when `retention.comments` is on). A concatenation's
  span includes the glue inside it, but whitespace or comments after a trailing
  `+` don't extend it or cause updates.

Using previews:

- Each update replaces the earlier preview with the same `start`. A
  `token_preview_end` retires it. A document abort retires all remaining
  previews, with no end events. An editor may keep an end-of-input preview,
  marked provisional, after the abort.
- Never merge previews into committed syntax.
- Spans include the written delimiters, borrow the original bytes, and may end
  in the middle of a character or an escape. They are `Span`, not `Name`, so
  `identifier.fromName` won't take them.
- Nothing is decoded, scanned again, closed by guessing, hidden from the
  diagnostics or repaired.
- UTF-16 and UTF-32 previews at the end of input keep byte offsets and encoding
  information. (There are no UTF-16/32 event sessions, so no pause previews
  for them.)
- `owner` is absent until a statement has actually begun; a preview never
  creates a statement or scope ID. In DOT without separators (`a b`), the next
  statement's text doesn't belong to the statement before it, even while that
  one waits to see the next token before committing. Owners work without begin
  notifications or early observations.
- Match updates by `start`, not by the text. `reset()` starts a new parse; IDs
  don't carry over.

Credits and timing in sessions:

- Each preview, update and end costs one credit.
- At a pause, the parser looks only at bytes it has already read, **without
  reading ahead**, and queues at most one update. If scanning used up the
  budget, the update waits for the next `advance` with a positive budget.
  Meanwhile `Progress.phase` is `.dispatch`, and a 1-credit call delivers it.
- `advance(0)` delivers nothing (cancellation is still checked).
- An unchanged prefix is not sent again, and a session with a budget of 1 still
  makes progress rather than spending every credit on previews.

Stops and cancellation:

- A queued preview may never arrive if the parse stops first.
- `cancel()`, or a cancellation hook, drops the preview but not a scanner error
  already found behind it: that finding is reported first. If the error can't
  be recovered from (such as an unterminated string at the end of input), the
  outcome stays `invalid_syntax`. If recovery was possible, the outcome is
  `cancelled` and the finding is kept. This includes an ambiguous-numeral
  finding waiting behind a `token_preview_end`.
- Stopping from your consumer is different. If `onEvent` returns `.stop` or an
  error on a `token_preview` or `token_preview_end`, a finding the scanner has
  found but not yet reported (such as the unterminated-string error after an
  end-of-input preview) is not delivered.
- `reset()` and `deinit()` clean up like `cancel()`, so they can deliver such a
  pending finding to the **old** diagnostic sink. Keep that sink alive until
  then, and clear a reused bag after `reset()`.

Costs: previews add fixed-size state and callback work, but no parser
allocation, source copy or extra nesting frames. Profiles without previews
compile that state, the scanner bookkeeping and the extra callbacks out.
Compare with `zig build bench-previews -Doptimize=fast`; measurements are in
[performance](PERFORMANCE.md#unfinished-token-previews).

## Indexing recognized names

> **Unreleased.** Not in 0.5.0.

To build a name index, you hash and compare identifiers. The general helpers
`dot.identifier.hash` and `dot.identifier.eql` accept any bytes, so they check
the spelling every time. When an event already hands you a complete
identifier, you can skip that check without keeping a `Document`:

```zig
// Inside a UTF-8 consumer's onEvent:
.commit_node => |node| {
    const name = dot.identifier.fromName(self.source, node.value.identifier);
    const hash = name.hash() catch unreachable; // UTF-8 keeps raw bytes; no error.
    // Store name/hash in your index; use name.eql(other) when hashes match.
},
```

- `dot.Name` is a typed handle for a complete identifier. Events use it for
  `identifier.name`, document and subgraph names, node identifiers, attribute
  keys and values, ports and link targets. Begins, heads, keywords, skipped
  regions and previews stay plain `Span`s, so they can't be passed by mistake.
  Edge endpoints are spans too; `edge.leftName()` and `edge.rightName()` give a
  `Name`, or null for a subgraph endpoint.
- `fromName(source, name)` accepts only a `Name` issued by parsing or by
  `identifier.check`, never arbitrary bytes or a `Span`. It returns a
  `dot.identifier.Parsed` with `hash()` and `eql()` that skip re-checking.
- A `Name` has the same 8-byte layout as a span. `.span()` gives its
  coordinates for diagnostics, and `.slice(source)` its original spelling.

Limits of the guarantee:

- Use the `Name` with the unchanged source that produced it, in its encoding.
  The type prevents accidents; it doesn't stop deliberate forging or a
  different buffer. Building a `Name` or `Parsed` by hand doesn't validate it.
- A `Name` outside the source panics in every build mode. A same-sized changed
  source, or the wrong encoding, can't be detected.
- It means "complete identifier spelling". It doesn't mean valid Unicode, an
  accepted statement or a unique node.

For an arbitrary span, call `try dot.identifier.check(source, span)` to get a
checked `Name` (or use the checked byte helpers). `check` verifies the spelling
of one identifier on its own; it says nothing about its role or acceptance in
the document.

For UTF-16 or UTF-32 input, use `dot.identifier.ForEncoding(actual)`, with
`actual` taken from `begin_document.source_info.encoding` (or
`document_name.source_info` for an early header name). Those helpers decode the
text and can reject malformed encoding, so pass `InvalidIdentifier` on through
a fallible callback instead of treating it as unreachable. When the encoding is
chosen at run time, switch on it once:

```zig
fn nameHash(source: []const u8, name: dot.Name, actual: dot.InputEncoding) !u64 {
    return switch (actual) {
        inline else => |encoding| dot.identifier.ForEncoding(encoding)
            .fromName(source, name).hash(),
    };
}
```

No event fields, parser storage or allocations are added. The index's memory is
yours, and hashing and comparing in callbacks is your work, not parser credits.

`zig build bench-identifiers -Doptimize=fast` compares the checked and trusted
paths in an event-only name index. Building the source and reserving the table
happen outside the timing. It reports parse-plus-index time, MB/s (decimal) and
index storage. Use `-Doptimize=safe` or `small` for those modes. Measurements
are in [performance](PERFORMANCE.md#names-outline-events-and-previews).

## Sessions and encodings

A *session* parses in steps: each `advance(budget)` call does at most `budget`
*credits* of work and returns, so you can interleave parsing with other work.
Turn on metering in the profile:

```zig
const Streaming = dot.Profile(.{ .policy = .{
    .execution = .{ .metering = true },
} }).Events(Consumer);
var frames: Streaming.FixedParseScratch(.{ .nesting = 32 }) = .{};
var session = Streaming.Session.init(source, frames.storage(), &consumer, bag.sink(), .{});
defer session.deinit();
while (session.result() == null) _ = session.advance(4096);
```

| Session method | What it does |
| --- | --- |
| `Session.init(source, frames, &consumer, diagnostics, options)` | Prepares a session. Settings are fixed here (runtime profiles return an error union). |
| `advance(budget)` | At most `budget` credits of work. Needs metering: a compile error on fixed profiles without it, `error.MeteringDisabled` on runtime ones. |
| `run()` | Runs to the end |
| `result()` | `null` until finished |
| `cancel()` | Stops now. If the consumer had received anything, it gets its aborts. |
| `reset(source, &consumer, diagnostics, options)` | Starts again on the same frames. Invalid new settings leave the current session untouched. |
| `deinit()` | The same as `cancel()` |

| `Progress` field | Meaning |
| --- | --- |
| `phase` | `scan`, `grammar`, `dispatch` (an event is waiting to be delivered) or `terminal` |
| `work_used` | Credits used by this call |
| `source_frontier` | How far the scanner has read, in bytes |
| `completed_statements`, `completed_pairs` | Statements and attribute pairs finished so far |
| `result` | The final result, once there is one |

Sessions follow the same lifecycle as document sessions (see
[parsing in small steps](EXECUTION.md)):

- The consumer and the frames must outlive the session.
- Each delivered event costs one credit, like a grammar or scanning step.
  `onAbort` calls cost none. Credits don't bound the time your callbacks take.
- Pauses keep event order. Delivered events are never replayed.

**Callbacks and re-entry:**

- `onEvent`, `onAbort`, `suspendScope` and `restoreScope` must not call any
  method of the session (or parse) that is calling them, not even `cancel()`.
  They must not reuse its frames or change the source. To stop from `onEvent`,
  return `.stop` or an error.
- A cancellation hook may call `cancel()` on its own session. The session then
  ends as `cancelled`, whichever value the hook returns. The hook must not call
  `advance`, `run`, `reset` or `deinit`.

| Option | When it exists | Meaning |
| --- | --- | --- |
| `policy` | `runtime_policy = true` | Settings for this parse or session |
| `cancellation` | runtime profiles, or when `execution.cancellation` is on | An optional borrowed hook |
| `encoding` | profiles that compile anything other than UTF-8 alone | The input's encoding. `null` uses a byte-order mark if there is one, otherwise UTF-8 (or ASCII). |

**Encodings.** Profiles that compile only UTF-8 (the default) have `parse`,
`parseIn` and `Session`. Profiles whose `source_encodings` is anything else
(including ASCII-only, `&.{}`) have `parse` and `parseIn` only. Those take
`options.encoding` and return an error union for input encoding errors. A hook
that already asks to stop gives the `cancelled` outcome before anything is
read, as it does for UTF-8.
Events still report original byte offsets. There is no event `Session` for
these profiles yet.

**Memory.** The parser keeps no event list. If you keep whole `Event` values,
budget `@sizeOf(dot.events.Event)` per entry; an index can keep just the spans
and IDs it needs. Event layouts are not a stable binary format.

## Advanced: per-scope state

Most consumers need only `onEvent` and `onAbort`. If you want to save some of
your own state when a subgraph opens and get it back when it closes, declare:

```zig
const Depth = struct {
    depth: u32 = 0,

    pub const ScopeContext = u32; // any type of yours
    pub fn suspendScope(self: *@This()) ScopeContext {
        const outer = self.depth;
        self.depth += 1;
        return outer;
    }
    pub fn restoreScope(self: *@This(), outer: ScopeContext) void {
        self.depth = outer;
    }

    pub fn onEvent(_: *@This(), _: dot.events.Event) error{}!dot.events.Action {
        return .proceed;
    }
    pub fn onAbort(_: *@This(), _: dot.events.Abort) void {}
};
```

- After your `onEvent` accepts a `begin_scope`, the parser calls
  `suspendScope` and stores the value in that subgraph's nesting frame. After
  you accept the matching `end_scope`, it calls `restoreScope` with it. No
  second stack is used.
- Both must be infallible.
- On a document abort, saved values are dropped; no `restoreScope` or
  `end_scope` is made up.
- The saved value is a copy, not a handed-over resource. Keep anything you own
  in the consumer itself, so `onAbort` can clean up without scope-close calls.
- These calls share their scope event's credit. Their time, like `onEvent`'s,
  is your work.
- Use the bound profile's `ParseScratch` / `FixedParseScratch`: its frame size
  includes only your `ScopeContext`. Consumers without one have smaller frames
  than the library's own document builder.

The library's document builders use this same event interface, including this
hook. Scope and reference IDs come from the parser, not from any builder's
storage, and `begin_scope` already carries the edge written so far, so a
consumer never needs the parser's private state.

## What events don't do

- **No validation.** Only parsing settings apply: syntax choices, limits,
  `on_error`, comment retention, `markup` (`.none` or `.passthrough`),
  `diagnostics`, and the lexical `validation.ambiguous_numeral` check. The checks
  `parseAndValidate` runs on a finished `Document` don't run on events.
- **No `Document` at the same time.** You get events or the library's tree,
  not both from one parse.
- **No child processors.** Profiles with a markup processor or with active
  [string routes](STRINGS.md#attribute-processing-in-dot-and-markup) have no
  `Events`; use a DOT profile without them. [Labels](LABELS.md) work through the
  ordinary document APIs.
- **No event sessions for profiles that compile anything other than UTF-8
  alone**, so no pause previews for UTF-16 or UTF-32 input (see
  [encodings](#sessions-and-encodings)).

## Examples

There is no example program for events yet. These files contain working
consumers:

- [bench/identifiers.zig](../bench/identifiers.zig): an event-only parse that
  builds a name index with `identifier.fromName`, using `parseIn` with fixed
  frames
- [bench/previews.zig](../bench/previews.zig): a consumer that selects
  `.token_preview` and counts previews in sessions with different budgets
- [bench/event_boundaries.zig](../bench/event_boundaries.zig): delimiter and
  commit-metadata consumers, with credit totals and session sizes;
  run `zig build bench-event-boundaries -Doptimize=fast` for a CSV comparison
- [tests/events.zig](../tests/events.zig): recovery, aborts, stops, sessions at
  every budget, native encodings and per-scope state
- [tests/early_events.zig](../tests/early_events.zig) and
  [tests/token_previews.zig](../tests/token_previews.zig): observations and
  previews
- [tests/event_boundaries.zig](../tests/event_boundaries.zig): exact extents,
  recognized/skipped delimiters, retained coverage and stop boundaries

For names in a `Document` instead, see
[identifiers.zig](../examples/identifiers.zig).
