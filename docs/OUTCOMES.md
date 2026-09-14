# Outcomes and diagnostics

Phases report problems through the same interface: functions
return a **small outcome value** describing what happened, and the
**explanation travels through your diagnostic sink** — structured,
typed, and never printed by the library. There is no error-code soup to
`catch` and no string parsing; outcomes are for control flow, diagnostics
are for humans and tooling.

## Parse outcomes

`parseBorrowed`, `parseBorrowedIn`, and `parseAndValidate` report a
`ParseOutcome`. Fixed sessions use the same type and additionally support cancellation:

| Outcome | Meaning | Document? |
| --- | --- | --- |
| `.success` | The document parsed completely | Yes |
| `.cancelled` | A session was cancelled; never produced by one-shot parsing | No |
| `.invalid_syntax` | The input is malformed in any DOT dialect | No |
| `.unsupported_feature` | The parse stopped at a recognized-but-deferred DOT construct | No |
| `.resource_exhausted` | A caller-configured limit (e.g. `max_statements` or `max_attributes`) was reached; the input may still be valid | No |
| `.storage_failure` | Document storage could not hold the document | No |

`storage_failure` carries its own cause: `.out_of_memory` (allocator),
`.pool_exhausted` (a fixed pool filled — the diagnostic names the pool and
its capacity), `.statement_index_overflow`, `.attribute_index_overflow`,
`.edge_link_index_overflow`, `.ported_reference_index_overflow`, `.source_offset_overflow`
(source beyond the 4 GiB retained-range limit), or `.internal` (never
expected; a bug report is welcome). `.internal` currently has no corresponding
diagnostic; inspect the outcome even when the diagnostic bag is empty.

Chain storage failures use the existing WDP capacity diagnostic, with typed
resources `edge_chain_pool`, `edge_link_pool`, or `edge_link_index`.
A missing chain endpoint remains a syntax error, not a capacity failure.
The shipped chain feature no longer appears in `diagnostic.Feature`.

Ports likewise no longer have an unsupported-feature entry. Fixed-pool/index
failures use `ported_reference_pool` / `ported_reference_index` capacity
resources. Missing suffix IDs use the existing expected-set syntax diagnostics
with context `port_component`; EOF after a colon has a `suffix_started_here`
secondary span. This adds no new WDP code or raw message-string payload.

## Sessions: yield and cancellation

A yielded session has no terminal outcome (`SessionProgress.outcome == null`)
and `result()` is null. Yield is resumable, not a resource failure. Cancellation
is terminal and emits no failure diagnostic. A previously obtained failure or
successful commit is never replaced by later cancellation. See
[bounded execution](EXECUTION.md).

## Unsupported is not invalid

The distinction the taxonomy is built around:

- **`invalid_syntax`** means *no DOT dialect accepts this input*.
- **`unsupported_feature`** means *this is recognized DOT syntax that this
  library does not process yet*. The parse stopped at the construct's
  introducer, and the diagnostic names the exact feature as a typed enum
  (`Feature.subgraph`, `Feature.html_identifier`, …) that tooling can
  aggregate or test against.

An unsupported outcome is a **boundary, not a validity claim**: nothing at
or beyond the stopping point has been checked. And the classification is
grammar-aware — a deferred keyword in a position where it is not legal DOT
(`subgraph` as the document root) is plain `invalid_syntax`.

Basic attributes produce syntax errors for malformed supported forms.
`Feature` contains only currently deferred constructs; implemented features
have no unsupported-feature entry. Attribute failures reuse
`E.Parser.Syntax.003` / `031` with typed key/value/list contexts, expected
`=` / `]` vocabulary and a related opener at EOF. Capacity diagnostics identify
the attribute, assignment or attribute-statement pool, or the total
`max_attributes` limit.

## Parsing succeeds, validation judges

The parser is kind-agnostic: `digraph { a -- b; }` **parses** with
`.success`. Whether `--` is legal in a directed document is a *policy*
question, answered by `validate` (or the `parseAndValidate` one-shot):

```zig
var checked = dot.parseAndValidate(allocator, source, bag.sink(), .{});
// checked.outcome == .success        — structure was fine
// checked.documentValid() == false   — validation found violations
```

`ValidationResult.outcome` is `.completed { document_valid, violations }`
today. Bounded/cancellable validation is future work; outcomes for those
behaviors will be added when implemented. Validation reports **every** violation, in source order — it never
stops at the first.

## The diagnostic bag

Parsing is fail-fast and attempts at most one failure diagnostic. Retention
depends on the sink: a full bag, discard sink, or rejected delivery can leave
no retained entry, and `.internal` emits no diagnostic. Validation attempts
one diagnostic per violation. A
`FixedDiagnosticBag(N)` keeps the first `N` and counts the rest in
`omitted` — diagnostics are never silently dropped.

Each diagnostic carries a WDP identity, a source span, and **optional
typed details** (`Details.none` means no additional context). Details are
never pre-rendered strings. Wording belongs to renderers; the
out-of-the-box console renderer is one consumer of these payloads, and
your logger, LSP, or JSON emitter can be another via `DiagnosticSink`.

Current registry:

| Code | When | Details emitted by the library |
| --- | --- | --- |
| `E.Lexer.Byte.003` | A byte invalid at its location, including NUL inside quotes | `.invalid_byte` |
| `E.Lexer.Syntax.003` | `+` is not followed by a quoted identifier | `.expected_quote` (next byte, or null at EOF) |
| `E.Lexer.Syntax.031` | Input ended inside an unclosed lexical construct; span marks its opener | `.unterminated` (`.block_comment` or `.quoted_identifier`) |
| `E.Parser.Syntax.003` | Unexpected token | `.unexpected` |
| `E.Parser.Syntax.031` | Input ended before the document was complete | `.unexpected` |
| `E.Validation.Operator.002` | Edge operator does not match the graph kind | `.operator_mismatch` |
| `E.Profile.Feature.009` | Recognized-but-deferred DOT construct | `.unsupported_feature` |
| `E.Resource.Capacity.026` | A configured capacity was exhausted | `.capacity` when available, otherwise `.none` |
| `E.Resource.Memory.026` | Document memory was exhausted | `.none` |

This table describes library-produced diagnostics. `Diagnostic` is publicly
constructible: its separate `code` and `details` fields do not enforce these
pairings in the type system. Consumers must not assume every diagnostic has
non-empty details. Diagnostic enums describe this library version, not a
cross-version serialization format.

Sequence numbers and aliases are defined together in `diagnostic.Sequence`.
Registry entries select one definition; `Code.Info.sequence` and `.alias`
are derived from that pair. Neither field is retained in each diagnostic.

During experimental `0.x`, backward compatibility is not promised for diagnostic
codes, payload enums, source APIs or retained layouts. Obsolete entries are
removed rather than kept for replay. WDP conformance and unique, coherent
identities within the current registry are still tested. Identities follow
the Waddling Diagnostic Protocol version
0.1.0-draft at conformance Level 2 (Namespaced: structured codes, compact
IDs, and namespaces), with the part 6 sequence conventions and part 10
presentation palette as informative guidance.

## Delivery is never masked

If *your sink* fails while a diagnostic is being reported, the outcome
still describes the parse; the loss is surfaced separately as
`diagnostic_delivery == .failed`. One channel never hides the other.

## Byte-safe excerpts

Console source excerpts escape non-ASCII and non-printable bytes as `\xNN`
(tabs retain their existing presentation). Underlines account for those byte
escapes; diagnostic offsets and byte columns still refer to original input.
This avoids emitting input-supplied terminal control sequences and does not
require Unicode display-width tables. Each excerpt window contains at most
60 source bytes, which can expand to 240 cells before framing/tab expansion.
This presentation policy is separate from identifier decoding, which preserves
the actual value bytes.
